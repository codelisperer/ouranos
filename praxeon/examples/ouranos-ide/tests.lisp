;;;; tests.lisp --- the Ouranos IDE example, driven through its routes (#1218).
;;;;
;;;; No window and no browser are opened. Most tests call the Clack application directly, with
;;;; the request body already cached. The last one starts a real server on 127.0.0.1, makes
;;;; requests with dexador, and stops the server. The agent uses the stub provider, or a
;;;; provider defined here that waits until the test lets it go on, so no model is called and
;;;; no key is read.
;;;;
;;;; A REPL input and an agent's turn run as background jobs. A request that starts one answers
;;;; before the job has ended, so a test waits for the job through hyperion/desktop-ui/jobs and
;;;; then reads the window's transcript. No test waits by asking the page again.

(cl:defpackage #:praxeon/examples/ouranos-ide/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:ide #:praxeon/examples/ouranos-ide)
                    (#:ui #:hyperion/desktop-ui)
                    (#:jobs #:hyperion/desktop-ui/jobs)
                    (#:http #:hyperion/http)
                    (#:srv #:hyperion/server)
                    (#:ports #:hyperion/test-ports)
                    (#:llm #:praxeon/llm)
                    (#:repl #:cons/coalton-repl))
  (:export #:run-tests))

(cl:in-package #:praxeon/examples/ouranos-ide/tests)

(def-suite ouranos-ide :description "The Ouranos IDE proof of concept (#1218).")
(in-suite ouranos-ide)

(defun run-tests () (run! 'ouranos-ide))

(defun %stop-jobs (desktop)
  "Cancel every job of DESKTOP's windows that is still running, and wait for its threads."
  (dolist (job (jobs:desktop-jobs desktop))
    (jobs:cancel-job job)
    (jobs:wait-job job :timeout 20)))

(defmacro %with-ide ((app desktop &key provider) &body body)
  "BODY with DESKTOP bound to a new desktop holding the five windows and APP to its
application. PROVIDER, when given, is the agent's provider. The REPL session is new. Afterwards
every job the desktop's windows started is stopped, and the database file is deleted. SETF and
not LET for the session, because a job evaluates on a thread of its own."
  (let ((old (gensym "OLD")))
    `(let* ((,old ide::*session*)
            (,desktop (ui:make-desktop :title "Ouranos IDE"))
            (,app nil))
       (declare (ignorable ,desktop ,app))
       (setf ide::*session* (repl:make-session))
       (unwind-protect
            (progn (ide:build-desktop :desktop ,desktop :provider ,provider)
                   (setf ,app (ide:make-app ,desktop))
                   ,@body)
         (%stop-jobs ,desktop)
         (ide::delete-database)
         (ignore-errors (delete-package (repl:session-package-name ide::*session*)))
         (setf ide::*session* ,old)))))

(defun %get (app path)
  (let ((response (funcall app (list :request-method :get :path-info path))))
    (values (apply #'concatenate 'string (third response)) (first response))))

(defun %post (app path &rest fields)
  "The body and status of POST PATH with the form FIELDS (name value ...), url-encoded."
  (let* ((body (format nil "~{~A=~A~^&~}" (mapcar #'quri:url-encode fields)))
         (response (funcall app (http:cache-body-string
                                 (list :request-method :post :path-info path) body))))
    (values (apply #'concatenate 'string (third response)) (first response))))

(defun %transcript (desktop id)
  "The transcript of the window ID, newest first."
  (ui:window-datum (ui:find-window desktop id) :transcript))

(defun %settle (desktop id)
  "Wait for the job of the newest item in the window ID's transcript, and return the item."
  (let ((item (first (%transcript desktop id))))
    (unless (jobs:wait-job (ide::item-job item) :timeout 60)
      (error "The job of the newest item in window ~A did not end within 60 seconds." id))
    item))

(defun %eval (app desktop language input &optional (id "repl"))
  "Send INPUT to the REPL window ID, wait for its job, and return the entry's record
(INSPECT-REPL-ENTRY), its HTML as rendered after the job ended, and the request's answer."
  (let* ((answer (%post app (format nil "/window/~A/action/eval" id)
                        "language" language "input" input))
         (entry (%settle desktop id)))
    (values (ide:inspect-repl-entry entry)
            (ide::%entry-html (ui:find-window desktop id) entry)
            answer)))

(defun %records (desktop id)
  "The records of the REPL window ID's entries, oldest first."
  (reverse (mapcar #'ide:inspect-repl-entry (%transcript desktop id))))

(defvar *gate* nil
  "A semaphore that an input sent to the REPL window waits on, so the test decides when the
evaluation goes on. Set with SETF, because the evaluation runs on another thread.")

(defparameter +wait-at-the-gate+
  "(progn (sb-thread:wait-on-semaphore praxeon/examples/ouranos-ide/tests::*gate*) :through)"
  "A Lisp-mode input that waits on *GATE* and then returns :THROUGH.")

(defmacro %with-gate (() &body body)
  "BODY with *GATE* a new semaphore. Afterwards it is signalled enough times to let any
evaluation still waiting on it go on."
  `(progn
     (setf *gate* (sb-thread:make-semaphore))
     (unwind-protect (progn ,@body)
       (sb-thread:signal-semaphore *gate* 10))))

(defmacro %recording-changes ((calls) &body body)
  "BODY with UI:WINDOW-CHANGED replaced by a function that pushes the window's id onto the
list CALLS names. The definition is put back afterwards."
  (let ((original (gensym "ORIGINAL")) (lock (gensym "LOCK")))
    `(let ((,original (fdefinition 'ui:window-changed))
           (,lock (sb-thread:make-mutex))
           (,calls '()))
       (unwind-protect
            (progn
              (setf (fdefinition 'ui:window-changed)
                    (lambda (window)
                      (sb-thread:with-mutex (,lock) (push (ui:window-id window) ,calls))))
              ,@body)
         (setf (fdefinition 'ui:window-changed) ,original)))))

;;; --- the page ----------------------------------------------------------------------------

(test the-page-shows-the-five-windows
  (%with-ide (app desktop)
    (multiple-value-bind (body status) (%get app "/")
      (is (= 200 status))
      (dolist (id '("repl" "clock" "chart" "agent" "inspector"))
        (is (search (format nil "data-window=~A" id) (remove #\" body)) "window ~A is missing" id))
      (is (search "ide-clock" body) "the IDE's own styles are on the page"))
    (is (equal '("repl" "clock" "chart" "agent" "inspector")
               (getf (ui:inspect-desktop desktop) :windows)))))

;;; --- the REPL window ---------------------------------------------------------------------

(test a-coalton-definition-persists-to-the-next-input
  (%with-ide (app desktop)
    (multiple-value-bind (record html) (%eval app desktop "coalton" "(define (triple x) (* 3 x))")
      (is (eq :definition (getf record :kind)))
      (is (search "defined" html) "rendered: ~A" html))
    (multiple-value-bind (record html) (%eval app desktop "coalton" "(triple 14)")
      (is (equal "42" (getf record :value)))
      (is (search "42" html) "rendered: ~A" html))
    (is (equal '(:definition :value)
               (mapcar (lambda (e) (getf e :kind)) (%records desktop "repl"))))
    (is (search "(triple 14)" (%get app "/window/repl/body"))
        "the body rendered later holds the transcript")))

(test a-coalton-type-error-is-shown-and-the-repl-goes-on
  (%with-ide (app desktop)
    (multiple-value-bind (record html) (%eval app desktop "coalton" "(+ 1 \"two\")")
      (is (eq :error (getf record :kind)))
      (is (search "ou-error" html)))
    (is (equal "3" (getf (%eval app desktop "coalton" "(+ 1 2)") :value)))))

(test an-input-that-would-end-the-process-is-refused-in-both-languages
  (%with-ide (app desktop)
    (dolist (language '("coalton" "lisp"))
      (multiple-value-bind (record html) (%eval app desktop language "(sb-ext:exit)")
        (is (eq :error (getf record :kind)))
        (is (search "was not evaluated" html) "~A rendered: ~A" language html)))))

(test redefining-a-window-from-the-repl-changes-its-next-body
  "The claim of the proof of concept: a DEFUN sent to the REPL window, over the same routes
the page uses, changes what another window shows, with no restart and no change to the window."
  (%with-ide (app desktop)
    (let ((original (fdefinition 'ide:render-clock))
          (ide::*now* (lambda () (encode-universal-time 5 4 3 2 1 2027 0))))
      (unwind-protect
           (progn
             (is (search "03:04:05" (%get app "/window/clock/body")))
             (let ((record (%eval app desktop "lisp"
                                  "(defun render-clock (window) (declare (ignore window)) \"<p>the clock was redefined</p>\")")))
               (is (search "RENDER-CLOCK" (getf record :value)) "the record: ~S" record))
             (is (string= "<p>the clock was redefined</p>" (%get app "/window/clock/body")))
             (is (search "the clock was redefined" (%get app "/")) "and on the whole page")
             (is (search "RENDER-CLOCK"
                         (getf (ui:inspect-window (ui:find-window desktop "clock")) :render))
                 "the window's record still names the same symbol"))
        (setf (fdefinition 'ide:render-clock) original))
      (is (search "03:04:05" (%get app "/window/clock/body")) "restored for the other tests"))))

(test a-window-can-be-added-from-the-repl
  (%with-ide (app desktop)
    (let ((old ide:*desktop*))
      ;; SETF and not LET: the input is evaluated on a job's thread, which sees the global value.
      (setf ide:*desktop* desktop)
      (unwind-protect
           (%eval app desktop "lisp"
                  "(defun render-note (window) (declare (ignore window)) \"<p>a new window</p>\") (ui:open-window *desktop* \"note\" :title \"Note\" :render 'render-note)")
        (setf ide:*desktop* old)))
    (is (string= "<p>a new window</p>" (%get app "/window/note/body")))
    (is (= 6 (length (ui:desktop-windows desktop))))))

;;; --- the REPL window: an input runs as a job ----------------------------------------------

(test an-input-is-answered-at-once-and-its-value-is-shown-when-its-job-ends
  (%with-ide (app desktop)
    (%with-gate ()
      (let* ((answer (%post app "/window/repl/action/eval" "language" "lisp"
                            "input" +wait-at-the-gate+))
             (entry (first (%transcript desktop "repl")))
             (record (ide:inspect-repl-entry entry)))
        (is (eq :running (getf record :kind)) "the request returned while the input was running")
        (is (search "id=win-repl-entry-1" (remove #\" answer)) "answered: ~A" answer)
        (is (search "Cancel" answer) "the running entry has a Cancel button")
        (is (search (format nil "hx-vals=\"{&quot;cancel&quot;: &quot;~D&quot;}\"" (getf record :job))
                    answer)
            "which sends the job's id: ~A" answer)
        (is (search "Cancel" (%get app "/window/repl/body")))
        (sb-thread:signal-semaphore *gate*)
        (%settle desktop "repl")
        (let ((record (ide:inspect-repl-entry entry)))
          (is (eq :value (getf record :kind)))
          (is (equal ":THROUGH" (getf record :value))))
        (let ((body (%get app "/window/repl/body")))
          (is (search ":THROUGH" body))
          (is (null (search "Cancel" body)) "an entry that has ended has no Cancel button"))))))

(test what-a-lisp-input-prints-is-kept-apart-from-its-value
  (%with-ide (app desktop)
    (multiple-value-bind (record html)
        (%eval app desktop "lisp" "(progn (princ \"printed by the input\") (+ 3 4))")
      (is (equal "printed by the input" (getf record :output)))
      (is (equal "7" (getf record :value)))
      (is (search "printed by the input" html)))))

(test a-lisp-error-is-shown-and-the-repl-goes-on
  (%with-ide (app desktop)
    (multiple-value-bind (record html) (%eval app desktop "lisp" "(error \"deliberately broken\")")
      (is (eq :error (getf record :kind)))
      (is (search "deliberately broken" (getf record :message)))
      (is (search "ou-error" html)))
    (is (eq :error (getf (%eval app desktop "lisp" "(unbalanced") :kind))
        "an input that cannot be read is an error too")
    (is (equal "3" (getf (%eval app desktop "lisp" "(+ 1 2)") :value)))))

(test an-endless-lisp-input-is-cancelled-from-the-page-and-the-repl-goes-on
  (%with-ide (app desktop)
    (setf *gate* (sb-thread:make-semaphore))
    (%post app "/window/repl/action/eval" "language" "lisp" "input"
           "(progn (sb-thread:signal-semaphore praxeon/examples/ouranos-ide/tests::*gate*) (loop))")
    (let* ((entry (first (%transcript desktop "repl")))
           (job (ide::item-job entry)))
      (is (sb-thread:wait-on-semaphore *gate* :timeout 20) "the input reached its loop")
      (is (eq :running (jobs:job-status job)))
      (let ((answer (%post app "/window/repl/action/eval"
                           "cancel" (princ-to-string (jobs:job-id job)))))
        (is (search "was cancelled" answer) "answered: ~A" answer)
        (is (search "id=win-repl-entry-1" (remove #\" answer))
            "the answer is the entry, to be swapped over the running one")
        (is (null (search "hx-post" answer)) "with no Cancel button"))
      (is (jobs:wait-job job :timeout 20) "the evaluation's thread ended")
      (is (not (jobs:job-thread-alive-p job)))
      (is (eq :cancelled (jobs:job-status job)))
      (is (eq :cancelled (getf (ide:inspect-repl-entry entry) :kind))))
    (is (equal "3" (getf (%eval app desktop "lisp" "(+ 1 2)") :value)))
    (is (= 2 (length (%transcript desktop "repl"))))
    (is (search "no evaluation with that job id"
                (%post app "/window/repl/action/eval" "cancel" "0")))))

(test a-coalton-input-is-cancelled-and-the-session-evaluates-again
  "cons/coalton-repl evaluates on its own thread, so this is the job's :ON-STOP at work."
  (%with-ide (app desktop)
    (%post app "/window/repl/action/eval" "language" "coalton"
           "input" "(lisp (-> Integer) () (cl:sleep 60) 1)")
    (let* ((entry (first (%transcript desktop "repl")))
           (job (ide::item-job entry))
           (session ide::*session*)
           (worker (loop repeat 1000
                         thereis (repl::session-worker session)
                         do (sleep 0.01))))
      (is-true worker "the Coalton evaluation started, on cons/coalton-repl's own thread")
      (%post app "/window/repl/action/eval" "cancel" (princ-to-string (jobs:job-id job)))
      (is (jobs:wait-job job :timeout 20))
      (is (eq :cancelled (getf (ide:inspect-repl-entry entry) :kind))
          "the record: ~S" (ide:inspect-repl-entry entry))
      (is (and worker
               (loop repeat 1000
                     thereis (not (sb-thread:thread-alive-p worker))
                     do (sleep 0.01)))
          "that thread was stopped too, which the job's interrupt alone does not do"))
    (is (equal "3" (getf (%eval app desktop "coalton" "(+ 1 2)") :value))
        "the session is not left busy")))

(test a-lisp-input-past-the-time-limit-is-stopped
  (%with-ide (app desktop)
    (let ((ide:*eval-time-limit* 0.3))
      (multiple-value-bind (record html) (%eval app desktop "lisp" "(loop)")
        (is (eq :timed-out (getf record :kind)))
        (is (search "the time limit" html) "rendered: ~A" html)))
    (is (not (jobs:job-thread-alive-p (ide::item-job (first (%transcript desktop "repl"))))))
    (is (= 20 ide:*eval-time-limit*) "the default limit, which Lisp mode now has too")))

(test a-second-input-while-one-is-running-is-refused
  (%with-ide (app desktop)
    (%with-gate ()
      (%post app "/window/repl/action/eval" "language" "lisp" "input" +wait-at-the-gate+)
      (let ((answer (%post app "/window/repl/action/eval" "language" "lisp" "input" "(+ 1 2)")))
        (is (search "Not evaluated" answer) "answered: ~A" answer)
        (is (search "still running" answer)))
      (is (= 1 (length (%transcript desktop "repl"))) "the refused input is not in the transcript")
      (is (= 1 (length (jobs:window-jobs (ui:find-window desktop "repl"))))
          "and no job was started for it")
      (sb-thread:signal-semaphore *gate*)
      (%settle desktop "repl")
      (is (equal "3" (getf (%eval app desktop "lisp" "(+ 1 2)") :value))
          "once the first has ended, the next input is evaluated")
      (is (= 2 (length (%transcript desktop "repl")))))))

(test two-repl-windows-keep-separate-transcripts
  (%with-ide (app desktop)
    (ui:open-window desktop "repl-two" :title "REPL 2" :render 'ide:render-repl
                                       :actions '(("eval" . ide:repl-eval)))
    (%with-gate ()
      (%post app "/window/repl/action/eval" "language" "lisp" "input" +wait-at-the-gate+)
      (is (equal "\"in window two\""
                 (getf (%eval app desktop "lisp" "\"in window two\"" "repl-two") :value))
          "the second window evaluates while the first is busy")
      (sb-thread:signal-semaphore *gate*)
      (%settle desktop "repl"))
    (is (equal (list +wait-at-the-gate+)
               (mapcar (lambda (e) (getf e :input)) (%records desktop "repl"))))
    (is (equal '("\"in window two\"")
               (mapcar (lambda (e) (getf e :input)) (%records desktop "repl-two"))))
    (let ((one (remove #\" (%get app "/window/repl/body")))
          (two (remove #\" (%get app "/window/repl-two/body"))))
      (is (search "id=win-repl-transcript" one))
      (is (search "hx-target=#win-repl-transcript" one))
      (is (search "id=win-repl-entry-1" one))
      (is (search "id=win-repl-two-transcript" two))
      (is (search "hx-target=#win-repl-two-transcript" two)
          "the second window's form adds to its own transcript")
      (is (search "id=win-repl-two-entry-1" two))
      (is (null (search "win-repl-transcript" two)))
      (is (null (search "in window two" one)))
      (is (null (search "id=ide-" (concatenate 'string one two)))
          "no element id is the same in every window"))))

(test a-repl-window-keeps-only-its-most-recent-entries
  (%with-ide (app desktop)
    (let ((ide:*transcript-limit* 3))
      (dotimes (i 5) (%eval app desktop "lisp" (princ-to-string i))))
    (is (equal '("2" "3" "4") (mapcar (lambda (e) (getf e :input)) (%records desktop "repl"))))
    (is (equal '(3 4 5) (mapcar (lambda (e) (getf e :number)) (%records desktop "repl")))
        "an entry keeps its number, and so its element id, when older ones are dropped")))

(test a-repl-job-tells-its-window-that-it-changed
  (%with-ide (app desktop)
    (%recording-changes (calls)
      (%eval app desktop "lisp" "(+ 1 2)")
      (is (member "repl" calls :test #'string=)))))

(test a-repl-entry-is-a-class-instance-that-holds-its-job
  (%with-ide (app desktop)
    (%eval app desktop "lisp" "(+ 1 2)")
    (let ((entry (first (%transcript desktop "repl"))))
      (is (typep (class-of entry) 'standard-class) "not a structure, so it can be redefined")
      (is (typep (ide::item-job entry) 'jobs:job)))))

(test the-input-fields-are-marked-to-be-kept-when-a-body-is-pushed
  "The page keeps an element that has an id and data-ou-preserve when it replaces a window's
body. The transcript must not be inside such an element, or pushed output would not show."
  (%with-ide (app desktop)
    (%eval app desktop "lisp" "(+ 1 2)")
    (let ((repl (remove #\" (%get app "/window/repl/body")))
          (agent (remove #\" (%get app "/window/agent/body"))))
      (is (search "id=win-repl-input" repl) "the REPL's textarea: ~A" repl)
      (is (search "data-ou-preserve=1" repl))
      (is (search "id=win-agent-input" agent) "the agent's input: ~A" agent)
      (is (search "data-ou-preserve=1" agent))
      (is (= 1 (count-if (lambda (i) (string= "data-ou-preserve" repl :start2 i :end2 (+ i 16)))
                         (loop for i from 0 to (- (length repl) 16) collect i)))
          "only the textarea is kept")
      (is (< (search "id=win-repl-transcript" repl) (search "id=win-repl-entry-1" repl)
             (search "<form" repl) (search "id=win-repl-input" repl))
          "the transcript and its entries come before the form, outside the kept element"))))

;;; --- the agent window: a turn runs as a job ------------------------------------------------

(defclass gated-provider (llm:provider)
  ((gate :initform (sb-thread:make-semaphore) :reader provider-gate)
   (entered :initform (sb-thread:make-semaphore) :reader provider-entered))
  (:documentation "A provider that calls no model. COMPLETE signals ENTERED, waits on GATE, and
then answers, so a test can hold a turn in the middle."))

(defmethod llm:complete ((p gated-provider) messages
                         &key system tools max-tokens temperature tool-choice)
  (declare (ignore messages system tools max-tokens temperature tool-choice))
  (sb-thread:signal-semaphore (provider-entered p))
  (sb-thread:wait-on-semaphore (provider-gate p))
  (llm:make-completion :stop-reason :end :text "the gated provider's answer"))

(test a-turn-runs-as-a-job-and-a-second-turn-is-refused-while-it-runs
  (let ((provider (make-instance 'gated-provider)))
    (%with-ide (app desktop :provider provider)
      (unwind-protect
           (let ((answer (%post app "/window/agent/action/say" "text" "first question")))
             (is (search "first question" answer) "answered at once with the user's bubble")
             (is (search "Working on it." answer))
             (is (search "Cancel" answer) "and a Cancel button: ~A" answer)
             (is (sb-thread:wait-on-semaphore (provider-entered provider) :timeout 20)
                 "the turn reached the provider on the job's thread")
             (let ((turn (first (%transcript desktop "agent"))))
               (is (eq :running (getf (ide:inspect-agent-turn turn) :kind)))
               (let ((refused (%post app "/window/agent/action/say" "text" "second question")))
                 (is (search "Not sent" refused) "answered: ~A" refused))
               (is (= 1 (length (%transcript desktop "agent")))
                   "the refused turn is not in the transcript")
               (sb-thread:signal-semaphore (provider-gate provider))
               (%settle desktop "agent")
               (is (equal "the gated provider's answer"
                          (getf (ide:inspect-agent-turn turn) :reply)))))
        (sb-thread:signal-semaphore (provider-gate provider) 10))
      (%post app "/window/agent/action/say" "text" "third question")
      (%settle desktop "agent")
      (is (= 2 (length (%transcript desktop "agent")))
          "once the first turn has ended, the next is accepted"))))

(test a-turn-is-cancelled-from-the-page
  (let ((provider (make-instance 'gated-provider)))
    (%with-ide (app desktop :provider provider)
      (%recording-changes (calls)
        (%post app "/window/agent/action/say" "text" "a question never answered")
        (is (sb-thread:wait-on-semaphore (provider-entered provider) :timeout 20))
        (let* ((turn (first (%transcript desktop "agent")))
               (job (ide::item-job turn))
               (answer (%post app "/window/agent/action/say"
                              "cancel" (princ-to-string (jobs:job-id job)))))
          (is (search "The turn was cancelled." answer) "answered: ~A" answer)
          (is (null (search "hx-post" answer)) "with no Cancel button")
          (is (jobs:wait-job job :timeout 20) "the turn's thread ended")
          (is (not (jobs:job-thread-alive-p job)))
          (is (eq :cancelled (getf (ide:inspect-agent-turn turn) :kind)))
          (is (member "agent" calls :test #'string=) "the agent's window was told"))
        (is (search "no turn with that job id"
                    (%post app "/window/agent/action/say" "cancel" "0")))))))

;;; --- the clock ---------------------------------------------------------------------------

(test the-clock-shows-the-time-it-reads-and-asks-again-each-second
  (%with-ide (app desktop)
    (let ((ide::*now* (lambda () (encode-universal-time 59 58 23 31 12 2026 0))))
      (let ((body (%get app "/window/clock/body")))
        (is (search "23:58:59" body))
        (is (search "2026-12-31 UTC" body))))
    (is (search "every 1s" (%get app "/window/clock")))))

;;; --- the chart ---------------------------------------------------------------------------

(test the-chart-is-drawn-from-the-rows-sqlite-returns
  (%with-ide (app desktop)
    (is (equal '(("aion" . 4) ("cons" . 4) ("mnemosyne" . 9) ("elenchon" . 8)
                 ("hyperion" . 8) ("praxeon" . 7))
               (ide:chart-rows)))
    (is (probe-file ide::*database-path*) "the rows came from a file on disk")
    (let ((body (%get app "/window/chart/body")))
      (is (search "<svg" body))
      (is (= 6 (count-if (lambda (i) (string= "<rect" body :start2 i :end2 (+ i 5)))
                         (loop for i from 0 to (- (length body) 5) collect i)))
          "one bar per row")
      (is (search "mnemosyne" body))
      (is (search "width=\"180\"" body) "the longest name, nine letters, has the full width")
      (is (search "width=\"80\"" body) "a four-letter name has four ninths of it"))))

(test the-chart-follows-the-database
  "A row inserted after the first render is in the next one, so the chart reads the database
on every render and holds no copy."
  (%with-ide (app desktop)
    (is (null (search "hermes" (%get app "/window/chart/body"))))
    (mnemosyne/conn:with-connection (c (ide::%backend))
      (mnemosyne/query:run c '(:insert-into "frameworks"
                               :values ((:position 7 :name "hermes" :letters 6)))
                           :dialect :sqlite))
    (is (search "hermes" (%get app "/window/chart/body")))))

;;; --- the agent ---------------------------------------------------------------------------

(test the-agent-answers-from-the-stub-provider
  (%with-ide (app desktop)
    (multiple-value-bind (body status)
        (%post app "/window/agent/action/say" "text" "which windows are open?")
      (is (= 200 status))
      (is (search "which windows are open?" body) "the user's bubble"))
    (let* ((turn (%settle desktop "agent"))
           (record (ide:inspect-agent-turn turn))
           (html (ide::%turn-html (ui:find-window desktop "agent") turn)))
      (is (eq :reply (getf record :kind)))
      (is (search "stub provider" (getf record :reply)) "the agent's reply: ~A" record)
      (is (search "inspector" (getf record :reply)) "the stub names the windows shown")
      (is (search "stub provider" html))
      (is (search "id=win-agent-turn-1" (remove #\" html)))
      (is (null (search "Cancel" html)) "a turn that has ended has no Cancel button"))
    (is (typep (actor-provider) 'ide:stub-provider))
    (is (= 1 (length (%transcript desktop "agent"))) "one turn holds both sides")
    (let ((body (%get app "/window/agent/body")))
      (is (search "which windows are open?" body) "the body rendered later holds the conversation")
      (is (search "stub provider" body))
      (is (search "id=win-agent-chat" (remove #\" body)))
      (is (search "hx-target=#win-agent-chat" (remove #\" body))))
    (is (= 2 (length (praxeon/actor:agent-history ide::*agent*)))
        "the turn went through praxeon's loop, which recorded both messages")))

(defun actor-provider () (praxeon/actor:agent-provider ide::*agent*))

(test the-agent-has-a-means-that-reads-the-desktop
  (%with-ide (app desktop)
    (ui:dispatch-event desktop "chart" hyperion/desktop-ui/state:close-event)
    (let ((answer (praxeon/actor:act ide::*agent* "list_windows" (make-hash-table :test 'equal))))
      (is (search "Windows: repl, clock, chart, agent, inspector." answer))
      (is (search "Shown: repl, clock, agent, inspector." answer)))))

;;; --- the inspector -----------------------------------------------------------------------

(test the-inspector-shows-a-window-s-record-and-its-data-without-the-objects-in-it
  (%with-ide (app desktop)
    (%post app "/window/clock/event" "type" "move" "x" "333" "y" "44")
    (let ((body (%post app "/window/inspector/action/select" "target" "clock")))
      (is (search "333" body))
      (is (search "RENDER-CLOCK" body)))
    (%eval app desktop "coalton" "(+ 1 2)")
    (let ((body (%post app "/window/inspector/action/select" "target" "repl")))
      (is (search "REPL-ENTRY" body) "a transcript entry is shown by its type")
      (is (null (search "(+ 1 2)" body)) "and not by its contents"))))

;;; --- over HTTP ---------------------------------------------------------------------------

(defun %status (thunk)
  "The status THUNK's request ended with, whether dexador returned or signalled."
  (handler-case (nth-value 1 (funcall thunk))
    (dex:http-request-failed (e) (dex:response-status e))))

(test the-ide-serves-over-http-on-loopback-and-refuses-a-post-from-another-origin
  (%with-ide (app desktop)
    (let* ((port nil)
           (handler (ports:call-with-port
                     (lambda (candidate)
                       (setf port candidate)
                       (srv:start app :server :hunchentoot :port candidate :host "127.0.0.1"
                                      :request-guard :same-origin :log nil))))
           (base (format nil "http://127.0.0.1:~D" port)))
      (unwind-protect
           (progn
             (multiple-value-bind (body status) (dex:get (format nil "~A/" base) :keep-alive nil)
               (is (= 200 status))
               (is (search "Ouranos IDE" body)))
             (is (search "ide-clock" (dex:get (format nil "~A/window/clock/body" base) :keep-alive nil)))
             (is (search "htmx" (dex:get (format nil "~A/" base) :keep-alive nil)) "the page loads htmx")
             (is (search "(* 6 7)"
                         (dex:post (format nil "~A/window/repl/action/eval" base) :keep-alive nil
                                   :headers `(("Origin" . ,base))
                                   :content '(("language" . "coalton") ("input" . "(* 6 7)"))))
                 "a POST from the page's own origin is accepted, and answered with the entry")
             (%settle desktop "repl")
             (is (search "42" (dex:get (format nil "~A/window/repl/body" base) :keep-alive nil))
                 "and evaluated: the body fetched after the job ended holds the value")
             (is (= 403 (%status
                         (lambda ()
                           (dex:post (format nil "~A/window/repl/action/eval" base) :keep-alive nil
                                     :headers '(("Origin" . "http://example.test"))
                                     :content '(("language" . "lisp") ("input" . "(+ 1 2)"))))))
                 "a POST from another origin is refused")
             (is (= 403 (%status
                         (lambda ()
                           (dex:post (format nil "~A/window/repl/action/eval" base) :keep-alive nil
                                     :content '(("language" . "lisp") ("input" . "(+ 1 2)"))))))
                 "and so is a POST that names no origin")
             (is (= 1 (length (%transcript desktop "repl")))
                 "neither refused POST started an evaluation"))
        (srv:stop handler)
        (is (ports:await-released port) "the server stopped")))))
