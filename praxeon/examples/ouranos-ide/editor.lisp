;;;; editor.lisp --- the IDE's code editor window, evaluated by Coalton's mine/runtime (#1218).
;;;;
;;;; The window holds a CodeMirror 6 editor, built in the page by the script in
;;;; editor/ouranos-editor.min.js, which editor/build.sh bundles from editor/src/editor.js. The
;;;; bundle is committed, and the IDE serves it from the example's directory at +EDITOR-URL+,
;;;; so running the IDE needs no Node. The tests check the bundle against the SHA-256 recorded
;;;; beside it.
;;;;
;;;; Evaluate (the button, or Mod-Enter in the editor) posts the selection, or the whole buffer
;;;; when nothing is selected, to the window's action `eval'. That starts a job, as the REPL
;;;; window does, and the job sends the text to the Coalton runtime: a second SBCL running the
;;;; evaluation server of `mine`, Coalton's terminal IDE, through the client in
;;;; runtime/client.lisp. The request answers at once with the entry while it runs, with a
;;;; Cancel button; when the job ends, hyperion/desktop-ui pushes the window's new body to the
;;;; page through GET /events. The editor's element is marked data-ou-preserve, so the push
;;;; keeps the editor, its text, its undo history and its focus. Nothing polls.
;;;;
;;;; ONE RUNTIME, STARTED ON FIRST USE. The first evaluation starts the runtime, which takes
;;;; seconds, or a few minutes the first time after Coalton or SBCL changed, because the child
;;;; then compiles mine/runtime. Later evaluations reuse it, so a definition stays defined
;;;; between them. STOP and STOP-RUNTIME kill it. Every editor window uses the same runtime,
;;;; and one evaluation runs at a time across all of them.
;;;;
;;;; The code runs in the child process, not in the IDE's image: a Lisp-mode evaluation there
;;;; cannot redefine the IDE's windows, which the REPL window's Lisp mode is for. A form that
;;;; ends the child ends only the child, and the next evaluation starts a new one.

(cl:in-package #:praxeon/examples/ouranos-ide)

(declaim (notinline render-editor editor-eval editor-cancel inspect-editor-entry))

;;; --- the bundle --------------------------------------------------------------------------

;;; +EDITOR-BUNDLE+ and +EDITOR-URL+ are in ide.lisp, because MAKE-APP there reads them.

(defun editor-directory ()
  "The directory holding the editor's bundle, its recorded SHA-256 and its sources."
  (asdf:system-relative-pathname "praxeon/examples/ouranos-ide" "examples/ouranos-ide/editor/"))

(defun editor-bundle-path ()
  "The path of the committed editor bundle."
  (merge-pathnames +editor-bundle+ (editor-directory)))

(defun %serve-bundle (env)
  "The response to GET +EDITOR-URL+: the bundle file, through hyperion/static. The file name is
this constant, never a path from the request, so no other file in the directory can be asked
for. Served with no-cache, so a browser asks again, with the file's ETag, and a rebuilt bundle
is picked up."
  (or (static:file-response (editor-directory) +editor-bundle+
                            :env env :cache-control "no-cache")
      (list 404 '(:content-type "text/plain; charset=utf-8")
            (list "The editor bundle is missing. Run praxeon/examples/ouranos-ide/editor/build.sh."))))

;;; --- the runtime -------------------------------------------------------------------------

(defvar *runtime* nil
  "The Coalton runtime the editor windows evaluate in, or NIL before the first evaluation.")

(defvar *runtime-lock* (sb-thread:make-mutex :name "ouranos-ide-editor-runtime")
  "Held while the runtime is started, so two evaluations cannot both start one.")

(defparameter *runtime-start-limit* 300
  "Seconds the runtime may take to start. The first start after a Coalton or SBCL change
compiles mine/runtime in the child, which is the slow case.")

(defparameter *editor-time-limit* 60
  "Seconds an editor evaluation may run, not counting the runtime's start, before it is
stopped. NIL for no limit. Read when the evaluation is sent.")

(defun runtime-ready-p ()
  "True when the editor's runtime is started and its child process is alive."
  (let ((runtime *runtime*))
    (and runtime (rt:runtime-alive-p runtime))))

(defun %ensure-runtime ()
  "The editor's runtime, started first when there is none or its child has exited. Called on
an evaluation's job thread, so what it prints is shown in the entry."
  (sb-thread:with-mutex (*runtime-lock*)
    (if (runtime-ready-p)
        *runtime*
        (let ((old *runtime*))
          (setf *runtime* nil)
          (when old (ignore-errors (rt:runtime-stop old)))
          (format t "Starting the Coalton runtime, a second SBCL that loads mine/runtime. The first start after Coalton or SBCL changed compiles it, which takes a few minutes.~%")
          (let ((runtime (rt:start-runtime :timeout *runtime-start-limit*)))
            (format t "The runtime started in ~,1F seconds.~%" (rt:runtime-start-seconds runtime))
            (setf *runtime* runtime))))))

(defun stop-runtime ()
  "Kill the editor's runtime, if one is running. Definitions made in it are lost; the next
evaluation starts a new one. The lock is not taken, so this does not wait for a start in
progress."
  (let ((runtime *runtime*))
    (setf *runtime* nil)
    (when runtime (ignore-errors (rt:runtime-stop runtime)))
    t))

(defun %interrupt-runtime ()
  "Stop the evaluation the runtime is running. This is an editor job's :ON-STOP. The runtime
refuses an interrupt for a request it has not started yet, so this tries for up to a second.
If the runtime is still busy after that, it is killed, and the next evaluation starts a new
one. When the job is stopped while the runtime is starting, there is no request: the job's
thread is then interrupted, and START-RUNTIME kills the child it was starting."
  (let ((runtime *runtime*))
    (when (and runtime (rt:runtime-alive-p runtime))
      (unless (loop repeat 20
                    thereis (ignore-errors (rt:runtime-interrupt runtime :timeout 2))
                    while (rt:runtime-busy-p runtime)
                    do (sleep 0.05))
        (when (rt:runtime-busy-p runtime)
          (stop-runtime))))))

(defun %printed-values (reply)
  "The values of an evaluation's REPLY, each as the runtime printed it: a list of strings. The
server sends them as the text of (:VALUES (string ...)). Text in any other shape is returned
whole, as the only element. The text is read with *READ-EVAL* off."
  (let* ((value (rt:reply-value reply))
         (form (and (stringp value)
                    (ignore-errors
                     (with-standard-io-syntax
                       (let ((*read-eval* nil)
                             (*package* (find-package '#:keyword)))
                         (read-from-string value)))))))
    (cond ((and (consp form) (eq :values (first form)) (listp (second form))
                (every #'stringp (second form)))
           (second form))
          ((stringp value) (list value))
          (t (list (prin1-to-string value))))))

;;; --- splitting Coalton text into definitions and expressions -----------------------------
;;;
;;; The runtime's :eval request wraps each Coalton form on its own, so a DECLARE and the DEFINE
;;; it belongs to, sent together, arrive in two separate COALTON-TOPLEVEL forms and the
;;; declaration is reported as having no definition. Its :compile-string request wraps a run
;;; of definitions in one COALTON-TOPLEVEL, but returns no value. So Coalton text is split into
;;; runs of top-level forms: a run of definitions is compiled together, and a run of anything
;;; else is evaluated, in the order they appear. Lisp text is evaluated whole.

(defparameter +coalton-definition-heads+
  '("declare" "define" "define-type" "define-struct" "define-class" "define-instance"
    "define-type-alias" "define-exception" "define-resumption" "repr" "monomorphize"
    "inline" "noinline" "specialize" "derive" "lisp-toplevel")
  "The first symbols, in lower case and without a package prefix, of the top-level forms that
are compiled in one COALTON-TOPLEVEL with their neighbours. Any other symbol starting with
\"define-\" counts too.")

(defun %delimiter-p (char)
  (or (member char '(#\( #\) #\" #\; #\' #\` #\,))
      (member char '(#\Space #\Tab #\Newline #\Return #\Page))))

(defun %skip-gap (text i)
  "The index of the next character of TEXT at or after I that is not whitespace or inside a
comment, or the length of TEXT."
  (let ((n (length text)))
    (loop
      (cond ((>= i n) (return n))
            ((member (char text i) '(#\Space #\Tab #\Newline #\Return #\Page)) (incf i))
            ((char= (char text i) #\;)
             (setf i (or (position #\Newline text :start i) n)))
            ((and (char= (char text i) #\#) (< (1+ i) n) (char= (char text (1+ i)) #\|))
             (setf i (%skip-block-comment text i)))
            (t (return i))))))

(defun %skip-block-comment (text i)
  "The index just after the #| ... |# comment that starts at I, which may nest, or the length
of TEXT when it is not closed."
  (let ((n (length text)) (depth 0))
    (loop
      (cond ((>= i n) (return n))
            ((and (char= (char text i) #\#) (< (1+ i) n) (char= (char text (1+ i)) #\|))
             (incf depth) (incf i 2))
            ((and (char= (char text i) #\|) (< (1+ i) n) (char= (char text (1+ i)) #\#))
             (decf depth) (incf i 2)
             (when (zerop depth) (return i)))
            (t (incf i))))))

(defun %form-end (text i)
  "The index just after the form that starts at I in TEXT. Strings, character literals and
comments are skipped as wholes, so a parenthesis inside them does not count. An unclosed form
runs to the end of TEXT."
  (let ((n (length text)) (depth 0))
    (loop
      (when (>= i n) (return n))
      (let ((c (char text i)))
        (cond ((member c '(#\' #\` #\,)) (incf i))
              ((char= c #\() (incf depth) (incf i))
              ((char= c #\))
               (incf i)
               (when (<= (decf depth) 0) (return i)))
              ((char= c #\")
               (incf i)
               (loop while (and (< i n) (char/= (char text i) #\"))
                     do (incf i (if (char= (char text i) #\\) 2 1)))
               (incf i)
               (when (zerop depth) (return (min i n))))
              ((char= c #\;)
               (setf i (or (position #\Newline text :start i) n)))
              ((and (char= c #\#) (< (1+ i) n) (char= (char text (1+ i)) #\|))
               (setf i (%skip-block-comment text i)))
              ((and (char= c #\#) (< (1+ i) n) (char= (char text (1+ i)) #\\))
               ;; A character literal: #\( is one character, #\Space a name.
               (incf i 3)
               (loop while (and (< i n) (not (%delimiter-p (char text i)))) do (incf i))
               (when (zerop depth) (return (min i n))))
              ((member c '(#\Space #\Tab #\Newline #\Return #\Page)) (incf i))
              (t
               (loop while (and (< i n) (not (%delimiter-p (char text i)))) do (incf i))
               (when (zerop depth) (return i))))))))

(defun %form-head (text start)
  "The first symbol of the list that starts at START in TEXT, in lower case and without a
package prefix, or NIL when the form there is not a list or starts with something else."
  (when (char= #\( (char text start))
    (let* ((from (%skip-gap text (1+ start)))
           (to (or (position-if #'%delimiter-p text :start from) (length text))))
      (when (< from to)
        (let ((token (string-downcase (subseq text from to))))
          (subseq token (1+ (or (position #\: token :from-end t) -1))))))))

(defun %definition-head-p (head)
  (and head
       (or (member head +coalton-definition-heads+ :test #'string=)
           (eql 0 (search "define-" head)))))

(defun coalton-runs (text)
  "TEXT's top-level forms grouped into runs, in order: a list of (KIND START END), where KIND
is :DEFINITIONS for a run of Coalton definitions (see +COALTON-DEFINITION-HEADS+) and
:EXPRESSIONS for a run of other forms, and START and END are character offsets into TEXT."
  (let ((runs '()) (i 0))
    (loop
      (setf i (%skip-gap text i))
      (when (>= i (length text)) (return))
      (let* ((end (%form-end text i))
             (kind (if (%definition-head-p (%form-head text i)) :definitions :expressions)))
        (if (and runs (eq kind (first (first runs))))
            (setf (third (first runs)) end)
            (push (list kind i end) runs))
        (setf i end)))
    (nreverse runs)))

;;; --- an evaluation ----------------------------------------------------------------------

(defun %diagnostics (reply offset)
  "REPLY's diagnostics as property lists, with OFFSET added to their positions, so they count
from the start of the whole text that was sent and not of one run of it."
  (mapcar (lambda (d)
            (flet ((shift (n) (and (integerp n) (+ n offset))))
              (list :severity (rt:diagnostic-severity d)
                    :summary (rt:diagnostic-summary d)
                    :label (rt:diagnostic-label d)
                    :start (shift (rt:diagnostic-start d))
                    :end (shift (rt:diagnostic-end d)))))
          (rt:reply-diagnostics reply)))

(defun %runtime-evaluation (input language timeout)
  "Evaluate INPUT in the runtime, starting the runtime first if needed, and describe the
outcome as a property list. This is the function of an editor entry's job.

LANGUAGE :LISP evaluates the whole of INPUT in CL-USER as Common Lisp. :COALTON splits INPUT
into runs (COALTON-RUNS) and sends them in order, in COALTON-USER: a run of definitions is
compiled together, and a run of other forms is evaluated, each form wrapped for Coalton. The
first run that fails ends the evaluation. The values are those of the last run evaluated;
:KIND is :DEFINITION when the last run was definitions. TIMEOUT bounds the wait for each reply."
  (let ((runtime (%ensure-runtime))
        (printed (make-string-output-stream))
        (diagnostics '())
        (result-values nil)
        (kind :value))
    (flet ((send (run-kind start end)
             (let* ((text (subseq input start end))
                    (reply (ecase run-kind
                             (:lisp (rt:runtime-eval runtime text :package "CL-USER" :coalton nil
                                                                  :timeout timeout))
                             (:expressions (rt:runtime-eval runtime text :package "COALTON-USER"
                                                                         :coalton t :timeout timeout))
                             (:definitions (rt:runtime-compile-string runtime text
                                                                      :package "COALTON-USER"
                                                                      :position start
                                                                      :timeout timeout)))))
               (write-string (rt:reply-output reply) printed)
               (setf diagnostics
                     (append diagnostics
                             ;; compile-string counts from POSITION already.
                             (%diagnostics reply (if (eq run-kind :definitions) 0 start))))
               (cond ((eq :ok (rt:reply-status reply))
                      (if (eq run-kind :definitions)
                          (setf kind :definition result-values nil)
                          (setf kind :value result-values (%printed-values reply)))
                      nil)
                     (t (or (rt:reply-condition reply)
                            (princ-to-string (rt:reply-value reply))))))))
      (let ((failure (if (eq language :lisp)
                         (send :lisp 0 (length input))
                         (loop for (run-kind start end) in (coalton-runs input)
                               thereis (send run-kind start end)))))
        (list :kind (if failure :error kind)
              :values (and (not failure) result-values)
              :printed (get-output-stream-string printed)
              :diagnostics diagnostics
              :message failure)))))

;;; --- the entries -------------------------------------------------------------------------

(defclass editor-entry ()
  ((number :initarg :number :reader editor-entry-number)
   (language :initarg :language :reader editor-entry-language
             :documentation ":COALTON or :LISP.")
   (input :initarg :input :reader editor-entry-input
          :documentation "The text that was evaluated: the selection, or the whole buffer.")
   (job :initarg :job :reader item-job
        :documentation "The job evaluating the input. Its function is %RUNTIME-EVALUATION."))
  (:documentation "One evaluation from an editor window. What came of it is read from its job."))

(defvar *editor-job* nil
  "The job of the latest editor evaluation, in any editor window, or NIL.")

(defun inspect-editor-entry (entry)
  "ENTRY as a property list. :KIND is :RUNNING while the job runs, then :VALUE, :DEFINITION
(the last run of Coalton definitions compiled; see %RUNTIME-EVALUATION) or :ERROR from the
runtime, or :ERROR when the job itself failed (for example, the runtime did not start), or
:CANCELLED or :TIMED-OUT. :VALUES are the printed values, :PRINTED what the evaluated code
printed in the runtime, :DIAGNOSTICS the runtime's diagnostics as property lists, and :OUTPUT
what the job printed here, which is where the runtime's start is reported."
  (let* ((job (item-job entry))
         (result (jobs:job-result job)))
    (append
     (list :number (editor-entry-number entry) :language (editor-entry-language entry)
           :input (editor-entry-input entry) :job (jobs:job-id job)
           :output (jobs:job-output job))
     (ecase (jobs:job-status job)
       (:running (list :kind :running :values nil :printed "" :diagnostics nil :message nil))
       (:done (list :kind (getf result :kind) :values (getf result :values)
                    :printed (getf result :printed) :diagnostics (getf result :diagnostics)
                    :message (getf result :message)))
       (:failed (list :kind :error :values nil :printed "" :diagnostics nil
                      :message (jobs:job-error-text job)))
       (:cancelled (list :kind :cancelled :values nil :printed "" :diagnostics nil
                         :message "The evaluation was cancelled."))
       (:timed-out (list :kind :timed-out :values nil :printed "" :diagnostics nil
                         :message (format nil "The evaluation was stopped after ~A second~:P, the time limit."
                                          (jobs:job-time-limit job))))))))

(defun %start-editor-entry (window language input)
  "Start the job that evaluates INPUT in the runtime, and add its entry to WINDOW's transcript.
The job's time limit is *EDITOR-TIME-LIMIT*, plus *RUNTIME-START-LIMIT* when the runtime is
not running yet, because the job starts it first."
  (let* ((limit (and *editor-time-limit*
                     (+ *editor-time-limit* (if (runtime-ready-p) 0 *runtime-start-limit*))))
         (timeout (if limit (+ limit 30) 86400))
         (job (jobs:start-job (lambda () (%runtime-evaluation input language timeout))
                              :window window :name "editor evaluation"
                              :time-limit limit
                              :on-stop '%interrupt-runtime
                              :stop-grace 2)))
    (setf *editor-job* job)
    (%add-to-transcript window (make-instance 'editor-entry :number (%next-number window)
                                                            :language language :input input
                                                            :job job))))

(defun %editor-entry-html (window entry)
  (let* ((record (inspect-editor-entry entry))
         (element-id (%dom-id window "entry" (getf record :number)))
         (output (getf record :output))
         (printed (getf record :printed)))
    (spin:with-html-string
      (:div :class "ide-entry" :id element-id
        (:div (:span :class "ide-prompt" (if (eq (getf record :language) :lisp) "cl>" "λ"))
              (:code (getf record :input)))
        (when (plusp (length output))
          (:div :class "ide-out ide-type" (:code output)))
        (when (plusp (length printed))
          (:div :class "ide-out" (:code printed)))
        (ecase (getf record :kind)
          (:running
           (:div :class "ide-out"
             (:span :class "ide-type" "running ")
             (:raw (%cancel-button window element-id "cancel" (item-job entry)))))
          (:value
           (:div :class "ide-out"
             (dolist (value (getf record :values))
               (:div (:code value)))))
          (:definition
           (:div :class "ide-out ide-type" "compiled and loaded"))
          ((:error :cancelled :timed-out)
           (:pre :class "ou-error" (getf record :message))))
        (dolist (d (getf record :diagnostics))
          (:pre :class "ou-error"
            (format nil "~(~A~): ~A~@[~%~A~]~@[~%characters ~D to ~D of the evaluated text~]"
                    (getf d :severity) (getf d :summary) (getf d :label)
                    (getf d :start) (getf d :end))))))))

;;; --- the window's actions and body -------------------------------------------------------

(defun %editor-busy-p ()
  (and *editor-job* (jobs:job-running-p *editor-job*)))

(defun editor-cancel (window parameters)
  "The editor window's action `cancel'. Cancel the evaluation whose job id is in the form
field `cancel', if it belongs to WINDOW, and answer with its entry's HTML."
  (let ((entry (%find-by-job window parameters)))
    (cond (entry
           (jobs:cancel-job (item-job entry))
           (%editor-entry-html window entry))
          (t (%notice-html "This window has no evaluation with that job id.")))))

(defun editor-eval (window parameters)
  "The editor window's action `eval'. The form field `input' is the text to evaluate, which the
page sets to the selection or the whole buffer; `buffer' is the whole buffer, kept in the
window so a page loaded later shows it; `language' is coalton or lisp. A job is started that
evaluates the input in the runtime, an entry is added to the window's transcript, and the
answer is the entry's HTML while it runs.

One evaluation at a time across every editor window, because they share one runtime. While
one runs, a new one is refused: nothing is started or stored, and the answer says so. Empty
input is refused the same way."
  (let ((input (or (%field parameters "input") ""))
        (language (if (equal "lisp" (%field parameters "language")) :lisp :coalton))
        (entry nil)
        (busy nil))
    (setf (ui:window-datum window :buffer) (or (%field parameters "buffer") input)
          (ui:window-datum window :language) language)
    (when (plusp (length (string-trim '(#\Space #\Tab #\Newline #\Return) input)))
      (sb-thread:with-mutex (*ide-lock*)
        (if (%editor-busy-p)
            (setf busy t)
            (setf entry (%start-editor-entry window language input)))))
    (cond (entry (%editor-entry-html window entry))
          (busy (%notice-html "Not evaluated: the last evaluation is still running. Wait for it, or cancel it."))
          (t (%notice-html "Nothing to evaluate: the buffer is empty.")))))

(defun render-editor (window)
  "The editor window's body: the element the page builds the editor in, the form that
evaluates, and the results, newest first.

The editor's element is marked data-ou-preserve, so a pushed body keeps it, and the editor in
it. Its data-ou-editor-doc is the buffer as it was at the last evaluation, which is the text a
newly loaded page starts with. The form's hidden fields are filled by the page's script just
before it is sent."
  (let ((results-id (%dom-id window "results"))
        (form-id (%dom-id window "form"))
        (language (ui:window-datum window :language :coalton))
        (entries (mapcar (lambda (entry) (%editor-entry-html window entry))
                         (ui:window-datum window :transcript))))
    (spin:with-html-string
      (:div :class "ide-editor" :id (%dom-id window "code")
            :data-ou-preserve "1" :data-ou-editor "1" :data-ou-editor-form form-id
            :data-ou-editor-doc (ui:window-datum window :buffer ""))
      (:form :id form-id :class "ide-editor-bar"
             :hx-post (format nil "/window/~A/action/eval" (ui:window-id window))
             :hx-target (format nil "#~A" results-id) :hx-swap "afterbegin"
        (:select :name "language"
          (:option :value "coalton" :selected (eq language :coalton) "Coalton")
          (:option :value "lisp" :selected (eq language :lisp) "Lisp"))
        (:input :type "hidden" :name "input")
        (:input :type "hidden" :name "buffer")
        (:button :type "submit" "Evaluate")
        (:span :class "ide-type" "Mod-Enter evaluates the selection, or the whole buffer."))
      (:div :id results-id (dolist (html entries) (:raw html))))))
