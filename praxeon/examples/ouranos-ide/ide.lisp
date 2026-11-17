;;;; ide.lisp --- the Ouranos IDE proof of concept: six windows in one SBCL image (#1218).
;;;;
;;;; A desktop (hyperion/desktop-ui) with these windows:
;;;;
;;;;   repl       a REPL. In Coalton mode an input goes to cons/coalton-repl, whose session keeps
;;;;              definitions between inputs. In Lisp mode an input is read and evaluated in
;;;;              this package, which is how a window is redefined while the desktop runs.
;;;;              Each input runs as a background job, which can be cancelled.
;;;;   clock      the time, which the server sends to the page again every second.
;;;;   chart      a bar chart of a SQLite query made through mnemosyne, sent again every five.
;;;;   agent      a praxeon agent. With no provider given it uses STUB-PROVIDER, which answers
;;;;              from the image and calls no model. Each turn runs as a background job.
;;;;   inspector  hyperion/desktop-ui's inspector, which shows any window's record.
;;;;   editor     a CodeMirror 6 code editor whose text is evaluated by Coalton's mine/runtime
;;;;              server in a child SBCL, as a background job. See editor.lisp.
;;;;
;;;; The page does not poll. It opens GET /events once, and hyperion/desktop-ui sends it what
;;;; changed: a window opened from the REPL with UI:OPEN-WINDOW appears without a reload.
;;;;
;;;; It lives in praxeon because it needs praxeon, the rightmost framework it uses.
;;;;
;;;; It is served by hyperion/server-uv, hyperion's own HTTP server, which runs on libuv. Build
;;;; libuv once, from the root of the tree:
;;;;   sbcl --script scripts/build-libuv.lisp
;;;; A libuv installed on the system also works. To serve it with another backend, load that
;;;; backend's Clack handler and pass its name to START, e.g. :server :hunchentoot.
;;;;
;;;; Run it from a REPL:
;;;;   (asdf:load-system :praxeon/examples/ouranos-ide)
;;;;   (praxeon/examples/ouranos-ide:start)          ; then open http://127.0.0.1:27190/
;;;;   (praxeon/examples/ouranos-ide:stop)
;;;; or in a native window, which blocks until the window closes:
;;;;   (praxeon/examples/ouranos-ide:native-window)
;;;;
;;;; THIS EVALUATES WHAT THE PAGE SENDS. The REPL window runs code in this process, as any
;;;; REPL does. START binds 127.0.0.1 only and turns on hyperion's same-origin guard, so a page
;;;; from another site cannot post to it. It has no login. Do not bind it to another address.

(cl:defpackage #:praxeon/examples/ouranos-ide
  (:use #:cl)
  (:local-nicknames (#:ui #:hyperion/desktop-ui)
                    (#:srv #:hyperion/server)
                    (#:hlog #:hyperion/logging)
                    (#:desk #:hyperion/desktop)
                    (#:jobs #:hyperion/desktop-ui/jobs)
                    (#:repl #:cons/coalton-repl)
                    (#:be #:mnemosyne/backend)
                    (#:conn #:mnemosyne/conn)
                    (#:query #:mnemosyne/query)
                    (#:llm #:praxeon/llm)
                    (#:actor #:praxeon/actor)
                    (#:chat #:praxeon/chat-ui)
                    (#:rt #:praxeon/examples/ouranos-ide/runtime)
                    (#:static #:hyperion/static)
                    (#:spin #:spinneret))
  (:export #:*desktop* #:*port* #:*workers*
           #:make-app #:build-desktop #:start #:stop #:native-window
           #:stub-provider
           #:render-repl #:repl-eval #:repl-cancel #:render-clock #:render-chart
           #:render-agent #:agent-say #:agent-cancel
           #:chart-rows #:inspect-repl-entry #:inspect-agent-turn
           #:*eval-time-limit* #:*turn-time-limit* #:*transcript-limit*
           #:render-editor #:editor-eval #:editor-cancel #:inspect-editor-entry
           #:editor-directory #:editor-bundle-path #:+editor-bundle+ #:+editor-url+
           #:runtime-ready-p #:stop-runtime #:coalton-runs
           #:*editor-time-limit* #:*runtime-start-limit*))

(cl:in-package #:praxeon/examples/ouranos-ide)

;;; A window calls these through their symbols, so a DEFUN typed into the REPL window
;;; replaces them. NOTINLINE keeps the compiler from fixing a call to the old definition.
(declaim (notinline render-repl repl-eval repl-cancel render-clock render-chart
                    render-agent agent-say agent-cancel
                    chart-rows inspect-repl-entry inspect-agent-turn))

(defvar *desktop* (ui:make-desktop :title "Ouranos IDE")
  "The IDE's desktop. One per image.")

(defparameter *port* 27190
  "The port START listens on. Not a common development port.")

(defparameter +editor-bundle+ "ouranos-editor.min.js"
  "The file name of the editor window's script bundle, in EDITOR-DIRECTORY (editor.lisp).")

(defparameter +editor-url+ "/ide/editor/ouranos-editor.min.js"
  "The path the IDE serves the editor's bundle at. MAKE-APP adds it to the page's scripts.")

;;; --- shared by the REPL and the agent windows --------------------------------------------

(defparameter *transcript-limit* 200
  "How many REPL entries, or agent turns, a window keeps. The oldest are dropped.")

(defvar *ide-lock* (sb-thread:make-mutex :name "ouranos-ide")
  "Held while a window's transcript is checked for a running job and a new one is started, so
two requests that arrive together cannot both start one.")

(defgeneric item-job (item)
  (:documentation "The job behind ITEM, a REPL entry or an agent's turn."))

(defun %field (parameters name)
  (cdr (assoc name parameters :test #'string=)))

(defun %dom-id (window &rest parts)
  "An element id inside WINDOW's body. It starts with the window's own element id, so two
windows that use the same render function never share an id."
  (format nil "win-~A~{-~A~}" (ui:window-id window) parts))

(defun %add-to-transcript (window item)
  "Put ITEM at the front of WINDOW's transcript, which is kept newest first, and cut the
transcript to *TRANSCRIPT-LIMIT* items. The existing list is extended and cut in place, not
copied."
  (let* ((transcript (cons item (ui:window-datum window :transcript)))
         (last-kept (nthcdr (1- *transcript-limit*) transcript)))
    (when last-kept (setf (cdr last-kept) nil))
    (setf (ui:window-datum window :transcript) transcript)
    item))

(defun %next-number (window)
  "The next number for an entry or a turn in WINDOW, counting from 1."
  (setf (ui:window-datum window :count) (1+ (ui:window-datum window :count 0))))

(defun %notice-html (text)
  (spin:with-html-string (:div :class "ide-entry" (:pre :class "ou-error" text))))

(defun %cancel-button (window element-id action job)
  "A button that posts the job's id to WINDOW's ACTION, `cancel', as the form field `cancel',
and replaces the element ELEMENT-ID with the answer."
  (spin:with-html-string
    (:button :type "button" :class "ide-cancel"
             :hx-post (format nil "/window/~A/action/~A" (ui:window-id window) action)
             :hx-vals (format nil "{\"cancel\": \"~D\"}" (jobs:job-id job))
             :hx-target (format nil "#~A" element-id) :hx-swap "outerHTML"
             "Cancel")))

(defun %find-by-job (window parameters)
  "The item of WINDOW's transcript whose job has the id in the form field `cancel', or NIL.
Only this window's own jobs are looked at, so one window cannot cancel another's."
  (let ((id (ignore-errors (parse-integer (or (%field parameters "cancel") "")))))
    (and id (find id (ui:window-datum window :transcript)
                  :key (lambda (item) (jobs:job-id (item-job item)))))))

(defun %running-item (window)
  "The item of WINDOW's transcript whose job is still running, or NIL."
  (find-if (lambda (item) (jobs:job-running-p (item-job item)))
           (ui:window-datum window :transcript)))

;;; --- the REPL window ---------------------------------------------------------------------
;;;
;;; An input is evaluated as a job (hyperion/desktop-ui/jobs), not in the request. The request
;;; adds an entry to the window's transcript and answers at once with the entry as it is then:
;;; running, with a Cancel button. The entry holds the job and is rendered from it each time,
;;; so a later render shows the output so far, and then the value, the error, or that it was
;;; cancelled or ran out of time.
;;;
;;; ONE EVALUATION AT A TIME PER WINDOW. An input sent while the window's last one is still
;;; running is refused: nothing is evaluated, nothing is added to the transcript, and the
;;; answer says to wait or cancel. It is not queued. cons/coalton-repl answers a second input
;;; to a busy session the same way.

(defvar *session* (repl:make-session "OURANOS-IDE-REPL")
  "The Coalton session behind the REPL windows. Its package keeps what an input defines. Every
REPL window uses this one session.")

(defparameter *eval-time-limit* 20
  "Seconds an evaluation may run, in either language, before it is stopped. NIL for no limit.
Read when an input is sent.")

(defclass repl-entry ()
  ((number :initarg :number :reader repl-entry-number
           :documentation "1 for the window's first input, 2 for the next. Used in the entry's element id.")
   (language :initarg :language :reader repl-entry-language
             :documentation ":COALTON or :LISP.")
   (input :initarg :input :reader repl-entry-input)
   (job :initarg :job :reader item-job
        :documentation "The job evaluating the input. Its function returns a property list with :KIND, :VALUE, :TYPE and :MESSAGE."))
  (:documentation "One input to a REPL window. What came of it is read from its job."))

(defun inspect-repl-entry (entry)
  "ENTRY as a property list, for the inspector, a REPL and the tests. :KIND is :RUNNING while
the job runs, then :VALUE, :DEFINITION or :ERROR from the evaluation, or :CANCELLED or
:TIMED-OUT. :OUTPUT is what the input has printed so far. :JOB is the job's id."
  (let* ((job (item-job entry))
         (result (jobs:job-result job)))
    (append
     (list :number (repl-entry-number entry) :language (repl-entry-language entry)
           :input (repl-entry-input entry) :job (jobs:job-id job)
           :output (jobs:job-output job))
     (ecase (jobs:job-status job)
       (:running (list :kind :running :value nil :type nil :message nil))
       (:done (list :kind (getf result :kind) :value (getf result :value)
                    :type (getf result :type) :message (getf result :message)))
       (:failed (list :kind :error :value nil :type nil
                      :message (jobs:job-error-text job)))
       (:cancelled (list :kind :cancelled :value nil :type nil
                         :message "The evaluation was cancelled."))
       (:timed-out (list :kind :timed-out :value nil :type nil
                         :message (format nil "The evaluation was stopped after ~A second~:P, the time limit."
                                          (jobs:job-time-limit job))))))))

(defun %coalton-entry (session input)
  "Evaluate INPUT as Coalton in SESSION and describe the result as a property list. This is
the function of a Coalton entry's job."
  (let* ((result (repl:eval-input session input))
         (kind (repl:result-kind result)))
    (if (eq kind :exit-requested)
        (list :kind :error
              :message "The input asks to end the process, and was not evaluated.")
        (list :kind kind :value (repl:result-value result) :type (repl:result-type result)
              :message (repl:result-message result)))))

(defun %lisp-entry (input)
  "Read every form of INPUT in *PACKAGE*, evaluate them in order, and describe the last value
as a property list. This is the function of a Lisp entry's job, so what the forms print goes
to the job's output, and an error they signal ends the job as failed. A form that would end
the process is refused, by the same test the Coalton engine uses."
  (let ((forms (with-input-from-string (in input)
                 (loop for form = (read in nil in)
                       until (eq form in)
                       collect form))))
    (if (repl:process-ending-p forms)
        (list :kind :error
              :message "The input asks to end the process, and was not evaluated.")
        (let ((value nil))
          (dolist (form forms) (setf value (eval form)))
          (list :kind :value :value (prin1-to-string value)
                :type (princ-to-string (type-of value)))))))

(defun %start-entry (window language input)
  "Start the job that evaluates INPUT and add its entry to WINDOW's transcript.

Coalton: cons/coalton-repl evaluates on a thread of its own, which the job's interrupt does
not reach, so the job's :ON-STOP calls CANCEL-EVALUATION, and the job's thread is given a
second to return by itself. For the same reason what a Coalton input prints is not captured."
  (let* ((session *session*)
         (job (ecase language
                (:lisp
                 (jobs:start-job (lambda () (%lisp-entry input))
                                 :window window :name "REPL input, Lisp"
                                 :time-limit *eval-time-limit*
                                 :bindings (list (cons '*package*
                                                       (find-package '#:praxeon/examples/ouranos-ide)))))
                (:coalton
                 (jobs:start-job (lambda () (%coalton-entry session input))
                                 :window window :name "REPL input, Coalton"
                                 :time-limit *eval-time-limit*
                                 :on-stop (lambda () (repl:cancel-evaluation session))
                                 :stop-grace 1)))))
    (%add-to-transcript window (make-instance 'repl-entry :number (%next-number window)
                                                          :language language :input input
                                                          :job job))))

(defun %entry-html (window entry)
  (let* ((record (inspect-repl-entry entry))
         (element-id (%dom-id window "entry" (getf record :number)))
         (output (getf record :output)))
    (spin:with-html-string
      (:div :class "ide-entry" :id element-id
        (:div (:span :class "ide-prompt" (if (eq (getf record :language) :lisp) "cl>" "λ"))
              (:code (getf record :input)))
        (when (plusp (length output))
          (:div :class "ide-out" (:code output)))
        (ecase (getf record :kind)
          (:running
           (:div :class "ide-out"
             (:span :class "ide-type" "running ")
             (:raw (%cancel-button window element-id "cancel" (item-job entry)))))
          (:value
           (:div :class "ide-out"
             (:code (getf record :value))
             (when (getf record :type)
               (:span :class "ide-type" " : " (getf record :type)))))
          (:definition
           (:div :class "ide-out" "defined " (:code (getf record :message))))
          ((:error :cancelled :timed-out)
           (:pre :class "ou-error" (getf record :message))))))))

(defun repl-cancel (window parameters)
  "The REPL window's action `cancel'. Cancel the evaluation whose job id is in the form field
`cancel', if it belongs to WINDOW, and answer with its entry's HTML."
  (let ((entry (%find-by-job window parameters)))
    (cond (entry
           (jobs:cancel-job (item-job entry))
           (%entry-html window entry))
          (t (%notice-html "This window has no evaluation with that job id.")))))

(defun repl-eval (window parameters)
  "The REPL window's action `eval'. The form field `input' is the source and `language' is
coalton or lisp. A job is started to evaluate it, an entry is added to the window's
transcript, and the answer is the entry's HTML while it is running. If the window's last input
is still running, the new one is refused: nothing is started or stored, and the answer says
so. A running evaluation is cancelled through the action `cancel' (REPL-CANCEL)."
  (let ((input (or (%field parameters "input") ""))
        (language (if (equal "lisp" (%field parameters "language")) :lisp :coalton))
        (entry nil))
    (sb-thread:with-mutex (*ide-lock*)
      (unless (%running-item window)
        (setf entry (%start-entry window language input))))
    (if entry
        (%entry-html window entry)
        (%notice-html "Not evaluated: this window's last input is still running. Wait for it, or cancel it."))))

(defun render-repl (window)
  "The REPL window's body: the transcript so far, oldest first, then the input form."
  (let ((transcript-id (%dom-id window "transcript"))
        (entries (mapcar (lambda (entry) (%entry-html window entry))
                         (reverse (ui:window-datum window :transcript)))))
    (spin:with-html-string
      (:div :id transcript-id (dolist (html entries) (:raw html)))
      (:form :hx-post (format nil "/window/~A/action/eval" (ui:window-id window))
             :hx-target (format nil "#~A" transcript-id) :hx-swap "beforeend"
             :hx-on--after-request "this.reset()"
        (:select :name "language"
          (:option :value "coalton" "Coalton")
          (:option :value "lisp" "Lisp"))
        ;; The id and data-ou-preserve tell the page to keep this element, with what is typed
        ;; in it, when the window's body is replaced by a push. The transcript is outside it.
        (:textarea :name "input" :rows 3 :spellcheck "false"
                   :id (%dom-id window "input") :data-ou-preserve "1"
                   :placeholder "(+ 1 2)")
        (:button :type "submit" "Evaluate")))))

;;; --- the clock window --------------------------------------------------------------------

(defvar *now* 'get-universal-time
  "The function the clock reads the time from. A test binds it to a fixed time.")

(defun render-clock (window)
  "The clock window's body: the time and the date, in UTC. The window's refresh interval is
one second, so the desktop's timer sends this to the connected pages every second."
  (declare (ignore window))
  (multiple-value-bind (second minute hour day month year) (decode-universal-time (funcall *now*) 0)
    (spin:with-html-string
      (:p :class "ide-clock" (format nil "~2,'0D:~2,'0D:~2,'0D" hour minute second))
      (:p :class "ide-date" (format nil "~4,'0D-~2,'0D-~2,'0D UTC" year month day)))))

;;; --- the chart window --------------------------------------------------------------------

(defvar *database-path* nil
  "The SQLite file the chart reads, or NIL before ENSURE-DATABASE has made one.")

(defparameter +frameworks+ '("aion" "cons" "mnemosyne" "elenchon" "hyperion" "praxeon")
  "The seed data: the six frameworks in dependency order. The chart shows the length of each name.")

(defun %backend () (be:make-sqlite *database-path*))

(defun ensure-database ()
  "Make a SQLite file in the temporary directory, with one table of the frameworks and the
length of each name, unless this image has made one already. Returns its path."
  (or *database-path*
      (let ((path (namestring
                   (merge-pathnames (format nil "ouranos-ide-~36R.db"
                                            (+ (* (get-universal-time) 1000000)
                                               (mod (get-internal-real-time) 1000000)))
                                    (uiop:temporary-directory)))))
        (setf *database-path* path)
        (conn:with-connection (c (%backend))
          (conn:exec c "CREATE TABLE frameworks (position INTEGER PRIMARY KEY, name TEXT NOT NULL, letters INTEGER NOT NULL)")
          (loop for name in +frameworks+
                for position from 1
                do (query:run c (list :insert-into "frameworks"
                                      :values (list (list :position position :name name
                                                          :letters (length name))))
                              :dialect :sqlite)))
        path)))

(defun delete-database ()
  "Delete the SQLite file ENSURE-DATABASE made, if any."
  (when *database-path*
    (ignore-errors (delete-file *database-path*))
    (setf *database-path* nil)))

(defun %column (row key)
  "The value of column KEY in ROW, a property list, whatever case the driver gave the name."
  (loop for (k v) on row by #'cddr
        when (string-equal (symbol-name k) (symbol-name key)) do (return v)))

(defun chart-rows ()
  "The chart's data: a list of (NAME . LETTERS), in dependency order, read from SQLite."
  (conn:with-connection (c (%backend))
    (mapcar (lambda (row) (cons (%column row :name) (%column row :letters)))
            (query:fetch c '(:select (:name :letters) :from ("frameworks") :order-by (:position))
                         :dialect :sqlite))))

(defun render-chart (window)
  "The chart window's body: one horizontal bar per row of CHART-ROWS, drawn as SVG. The
window's refresh interval is five seconds, so a change in the database shows on the connected
pages within five seconds."
  (declare (ignore window))
  (let* ((rows (chart-rows))
         (largest (max 1 (reduce #'max rows :key #'cdr :initial-value 0)))
         (row-height 24))
    (spin:with-html-string
      (:p :class "ide-caption" "Letters in each framework's name, from SQLite through mnemosyne.")
      (:raw
       (with-output-to-string (svg)
         (format svg "<svg class=\"ide-chart\" width=\"300\" height=\"~D\" role=\"img\">"
                 (* row-height (length rows)))
         (loop for (name . letters) in rows
               for y from 0 by row-height
               ;; NAME is escaped; the numbers are integers this function computed.
               do (format svg "<text x=\"0\" y=\"~D\">~A</text><rect x=\"90\" y=\"~D\" width=\"~D\" height=\"16\" fill=\"#4a72b0\"><title>~D</title></rect><text x=\"~D\" y=\"~D\">~D</text>"
                          (+ y 14) (spin:escape-string name) y
                          (round (* 180 letters) largest) letters
                          (+ 96 (round (* 180 letters) largest)) (+ y 14) letters))
         (format svg "</svg>"))))))

;;; --- the agent window --------------------------------------------------------------------

(defclass stub-provider (llm:provider)
  ((desktop :initarg :desktop :reader stub-desktop))
  (:documentation "A provider that calls no model. It answers from the image: it repeats what
was said and names the windows that are open. Used when START is given no provider."))

(defmethod llm:complete ((p stub-provider) messages
                         &key system tools max-tokens temperature tool-choice)
  (declare (ignore system tools max-tokens temperature tool-choice))
  (let* ((last-content (llm:content (car (last messages))))
         (said (if (stringp last-content) last-content "something that was not text")))
    (llm:make-completion
     :stop-reason :end
     :text (format nil "This is the stub provider, so no model was called. You said: ~A. The windows shown are: ~{~A~^, ~}."
                   said (getf (ui:inspect-desktop (stub-desktop p)) :shown)))))

(defvar *agent* nil
  "The praxeon agent behind the agent window. BUILD-DESKTOP makes it.")

(defun %make-agent (desktop provider)
  "An agent on PROVIDER with one means, list_windows, which reports DESKTOP's windows."
  (let ((agent (actor:make-agent
                :name "ide" :provider provider
                :system-prompt "You are the assistant inside the Ouranos IDE, a desktop of windows running in one SBCL image. Answer briefly.")))
    (actor:register-means
     agent "list_windows" "Lists the ids of the IDE's windows, and which of them are shown."
     (lambda (arguments)
       (declare (ignore arguments))
       (let ((record (ui:inspect-desktop desktop)))
         (format nil "Windows: ~{~A~^, ~}. Shown: ~{~A~^, ~}."
                 (getf record :windows) (getf record :shown)))))
    agent))

(defparameter *turn-time-limit* 300
  "Seconds one turn of the agent may run before it is stopped. NIL for no limit. Read when a
turn is started.")

(defvar *running-turn* nil
  "NIL, or a cons of an agent and the job running its latest turn.")

(defclass agent-turn ()
  ((number :initarg :number :reader agent-turn-number)
   (text :initarg :text :reader agent-turn-text
         :documentation "What the user said.")
   (job :initarg :job :reader item-job
        :documentation "The job running the turn. Its function returns the agent's answer, a string."))
  (:documentation "One exchange in an agent window. The agent's side is read from its job."))

(defun inspect-agent-turn (turn)
  "TURN as a property list. :KIND is :RUNNING while the turn's job runs, then :REPLY, :ERROR,
:CANCELLED or :TIMED-OUT. :REPLY is the text shown as the agent's side. :JOB is the job's id."
  (let* ((job (item-job turn))
         (status (jobs:job-status job)))
    (list :number (agent-turn-number turn) :text (agent-turn-text turn) :job (jobs:job-id job)
          :kind (ecase status
                  (:running :running) (:done :reply) (:failed :error)
                  (:cancelled :cancelled) (:timed-out :timed-out))
          :reply (ecase status
                   (:running "Working on it.")
                   (:done (jobs:job-result job))
                   (:failed (format nil "The turn failed: ~A" (jobs:job-error-text job)))
                   (:cancelled "The turn was cancelled.")
                   (:timed-out (format nil "The turn was stopped after ~A second~:P, the time limit."
                                       (jobs:job-time-limit job)))))))

(defun %agent-busy-p (agent)
  (and *running-turn* (eq agent (car *running-turn*))
       (jobs:job-running-p (cdr *running-turn*))))

(defun %start-turn (window agent text)
  "Start the job that runs one turn of AGENT on TEXT and add the turn to WINDOW's transcript.
The job's :ON-STOP calls praxeon's CANCEL-TURN, which closes a streaming model call, and the
job's thread is given two seconds to end the turn by itself before it is interrupted."
  (let* ((cancel (actor:make-turn-cancel))
         (job (jobs:start-job (lambda () (or (actor:run-turn agent text :cancel cancel) ""))
                              :window window :name "agent turn"
                              :time-limit *turn-time-limit*
                              :on-stop (lambda () (actor:cancel-turn cancel))
                              :stop-grace 2)))
    (setf *running-turn* (cons agent job))
    (%add-to-transcript window (make-instance 'agent-turn :number (%next-number window)
                                                          :text text :job job))))

(defun %turn-html (window turn)
  "The chat bubbles for TURN: the user's, then the agent's. While the turn runs, the agent's
bubble says so and a Cancel button follows it."
  (let* ((record (inspect-agent-turn turn))
         (element-id (%dom-id window "turn" (getf record :number)))
         (user (chat:user-bubble (getf record :text)))
         (assistant (chat:assistant-bubble "ide" (getf record :reply))))
    (spin:with-html-string
      (:div :class "ide-turn" :id element-id
        (:raw user)
        (:raw assistant)
        (when (eq (getf record :kind) :running)
          (:raw (%cancel-button window element-id "cancel" (item-job turn))))))))

(defun agent-cancel (window parameters)
  "The agent window's action `cancel'. Cancel the turn whose job id is in the form field
`cancel', if it belongs to WINDOW, and answer with the turn's HTML."
  (let ((turn (%find-by-job window parameters)))
    (cond (turn
           (jobs:cancel-job (item-job turn))
           (%turn-html window turn))
          (t (%notice-html "This window has no turn with that job id.")))))

(defun agent-say (window parameters)
  "The agent window's action `say'. A job is started that runs one turn of the agent on the
form field `text', the turn is added to the window's transcript, and the answer is its HTML
while it is running. An error in the turn is shown as the agent's answer, so a provider that
fails does not break the window. A running turn is cancelled through the action `cancel'
(AGENT-CANCEL).

One turn at a time per agent: while the agent's last turn is still running, a new one is
refused. Nothing is started or stored, and the answer says so."
  (let ((text (or (%field parameters "text") ""))
        (agent *agent*)
        (turn nil))
    (sb-thread:with-mutex (*ide-lock*)
      (unless (%agent-busy-p agent)
        (setf turn (%start-turn window agent text))))
    (if turn
        (%turn-html window turn)
        (%notice-html "Not sent: the agent's last turn is still running. Wait for it, or cancel it."))))

(defun render-agent (window)
  "The agent window's body: the conversation so far, oldest first, then the input form."
  (let ((chat-id (%dom-id window "chat"))
        (turns (mapcar (lambda (turn) (%turn-html window turn))
                       (reverse (ui:window-datum window :transcript)))))
    (spin:with-html-string
      (:div :id chat-id (dolist (html turns) (:raw html)))
      (:form :hx-post (format nil "/window/~A/action/say" (ui:window-id window))
             :hx-target (format nil "#~A" chat-id) :hx-swap "beforeend"
             :hx-on--after-request "this.reset()"
        ;; Kept across a pushed body, as the REPL's textarea is.
        (:input :type "text" :name "text" :placeholder "Ask the agent" :autocomplete "off"
                :id (%dom-id window "input") :data-ou-preserve "1")
        (:button :type "submit" "Send")))))

;;; --- the desktop and the server ----------------------------------------------------------

(defparameter *css*
  ".ide-entry{margin-bottom:.6rem;font-family:ui-monospace,Consolas,monospace;font-size:12px}.ide-entry code{white-space:pre-wrap}.ide-prompt{color:#4a72b0;font-weight:600;margin-right:.4rem}.ide-out{margin-left:1.2rem}.ide-type{color:#57606a}.ou-body form{display:flex;gap:.4rem;align-items:flex-start;margin-top:.4rem}.ou-body textarea,.ou-body input[type=text]{flex:1;font:12px ui-monospace,Consolas,monospace}.ide-clock{font:600 34px ui-monospace,Consolas,monospace;margin:.2rem 0}.ide-date,.ide-caption{color:#57606a;margin:0 0 .4rem}.ide-chart text{font:12px ui-monospace,Consolas,monospace}.message{margin:0 0 .5rem;border:1px solid #d5dae2;border-radius:5px}.message-header{padding:.1rem .5rem;background:#7a8699;color:#fff;font-size:12px}.message-header p,.message-body p{margin:0}.message.px-user .message-header{background:#4a72b0}.message-body{padding:.3rem .5rem}.ide-editor{height:220px;border:1px solid #d5dae2;border-radius:4px;overflow:hidden}.ide-editor-bar{align-items:center}"
  "The IDE windows' own styles, added to hyperion/desktop-ui's.")

(defun build-desktop (&key provider (desktop *desktop*))
  "Put the six windows on DESKTOP, replacing any with the same ids, make the database and
the agent, and return DESKTOP. PROVIDER is a praxeon/llm:provider for the agent; with none,
the agent uses STUB-PROVIDER and calls no model.

The clock and the chart have a refresh interval. The desktop's timer sends their bodies to the
connected pages on that schedule; the page does not ask."
  (ensure-database)
  (setf *agent* (%make-agent desktop (or provider (make-instance 'stub-provider :desktop desktop))))
  (ui:open-window desktop "repl" :title "REPL" :render 'render-repl
                                 :actions '(("eval" . repl-eval) ("cancel" . repl-cancel))
                                 :x 20 :y 20 :width 460 :height 360)
  (ui:open-window desktop "clock" :title "Clock" :render 'render-clock :refresh 1
                                  :x 500 :y 20 :width 240 :height 130)
  (ui:open-window desktop "chart" :title "Chart" :render 'render-chart :refresh 5
                                  :x 500 :y 170 :width 340 :height 230)
  (ui:open-window desktop "agent" :title "Agent" :render 'render-agent
                                  :actions '(("say" . agent-say) ("cancel" . agent-cancel))
                                  :x 20 :y 400 :width 460 :height 300)
  (ui:open-inspector desktop :x 860 :y 20 :width 380 :height 460 :target "clock")
  ;; The editor's runtime is started by its first evaluation, not here.
  (ui:open-window desktop "editor" :title "Editor" :render 'render-editor
                                   :actions '(("eval" . editor-eval) ("cancel" . editor-cancel))
                                   :x 500 :y 420 :width 600 :height 420)
  desktop)

(defun make-app (&optional (desktop *desktop*))
  "DESKTOP as a Clack application, with the IDE's styles added to the desktop's and the
editor's script added to the page's. Both are bound around each request, because the page
reads them when it is rendered. GET +EDITOR-URL+ answers with the editor's bundle."
  (let ((app (ui:make-app desktop)))
    (lambda (env)
      (if (and (eq :get (getf env :request-method))
               (equal +editor-url+ (getf env :path-info)))
          (%serve-bundle env)
          (let ((ui:*css* (concatenate 'string ui:*css* *css*))
                (ui:*page-scripts* (append ui:*page-scripts* (list +editor-url+))))
            (funcall app env))))))

(defvar *handler* nil "The running server, or NIL.")

(defun %logged-quietly (app)
  "APP with hyperion's request logging around it, and every path counted as a quiet one: a
request that succeeds is logged at :trace, which the default log level does not print, and a
request that signals an error is still logged with its backtrace. START uses this in place of
HYPERION/SERVER:START's own logging, which prints a line at :info for every request. The IDE
is started from a REPL in a terminal, and those lines made the REPL hard to type into. To see
every request, set the log level to :trace."
  (let ((logged (hlog:wrap app))
        (every-path (list (constantly t))))
    (lambda (env)
      (let ((hlog:*quiet-paths* every-path))
        (funcall logged env)))))

(defparameter *workers* 16
  "How many threads run the IDE's request handlers when it is served by hyperion/server-uv.

Each page that is open holds one of them for as long as it is open, because its GET /events
stream is written by the thread that ran it. A POST or GET from any page needs a free one as
well. hyperion/server's default for :uv is 2, so two open pages would hold both and every
other request would wait in the pool's queue until a page closed. 16 leaves room for many
pages and their requests. With more pages open than this, the requests past it wait. The other
backends are given nothing: Hunchentoot runs each connection on a thread of its own.")

(defun %workers-for (server workers)
  "WORKERS for SERVER, or NIL for Hunchentoot, which would ignore them with a warning."
  (if (eq server :hunchentoot) nil workers))

(defun start (&key (port *port*) provider (server (srv:default-server)) (workers *workers*))
  "Build the desktop and serve it on 127.0.0.1:PORT. Returns the server's handler. Open
http://127.0.0.1:PORT/ in a browser to use it. PROVIDER is passed to BUILD-DESKTOP.

SERVER is the backend, passed to HYPERION/SERVER:START. Its default is
HYPERION/SERVER:DEFAULT-SERVER, which is hyperion/server-uv when libuv loads, and which the
environment variable HYPERION_SERVER overrides. The example depends on hyperion/server-uv; to
use another backend, load its Clack handler and pass its name, e.g. :server :hunchentoot.
WORKERS is how many handler threads :uv gets; see *WORKERS*.

The server refuses a request whose Host is not this address, and a POST that did not come
from its own page, because the REPL window evaluates what it is sent.

Requests that succeed are not printed in the terminal; see %LOGGED-QUIETLY."
  (when *handler* (stop))
  (build-desktop :provider provider)
  (setf *handler* (srv:start (%logged-quietly (make-app))
                             :server server :port port :host "127.0.0.1"
                             :workers (%workers-for server workers)
                             :request-guard :same-origin :log nil)))

(defun stop ()
  "End the pages' event streams and the desktop's timer, stop the server START started,
delete the chart's database file, and kill the editor's runtime.

The streams are ended first, so each one finishes as a complete response and gives its
handler thread back before the server stops. Stopping the server first closed their
connections under them, and on :uv each stream then failed to write and was logged as an
error."
  (ui:stop-desktop *desktop*)
  (when *handler*
    (srv:stop *handler*)
    (setf *handler* nil))
  (delete-database)
  (stop-runtime)
  t)

(defun native-window (&key provider (server (srv:default-server)) (workers *workers*))
  "Build the desktop and show it in a native window through hyperion/desktop:run-app, which
blocks until the window is closed. SERVER and WORKERS are as for START. The tests do not call
this, because it opens a window."
  (build-desktop :provider provider)
  (unwind-protect
       (desk:run-app (make-app) :title "Ouranos IDE" :width 1280 :height 800
                                :server server :workers (%workers-for server workers))
    (ui:stop-desktop *desktop*)
    (delete-database)
    (stop-runtime)))
