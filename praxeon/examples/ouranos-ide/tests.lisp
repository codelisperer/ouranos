;;;; tests.lisp --- the Ouranos IDE example, driven through its routes (#1218).
;;;;
;;;; No window and no browser are opened. Most tests call the Clack application directly, with
;;;; the request body already cached. Some start a real server on 127.0.0.1 and stop it: they
;;;; make requests with dexador or over a socket of their own, and read GET /events over a
;;;; socket. The server is hyperion/server-uv, which START uses by default.
;;;; The agent uses the stub provider, or a provider defined here that waits until the test
;;;; lets it go on, so no model is called and no key is read.
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
                    (#:uv #:hyperion/server-uv)
                    (#:ports #:hyperion/test-ports)
                    (#:llm #:praxeon/llm)
                    (#:repl #:cons/coalton-repl)
                    (#:rt #:praxeon/examples/ouranos-ide/runtime)
                    (#:router #:hyperion/router)
                    (#:assets #:hyperion/assets)
                    ;; The headless browser helpers of hyperion's asset tests.
                    (#:smoke #:hyperion/assets/tests))
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
  "BODY with DESKTOP bound to a new desktop holding the six windows and APP to its
application. PROVIDER, when given, is the agent's provider. The REPL session is new. Afterwards
every job the desktop's windows started is stopped, the database file is deleted, and the
editor's runtime is killed if a test started one. SETF and not LET for the session, because a
job evaluates on a thread of its own."
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
         (ide:stop-runtime)
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

(test the-page-shows-the-six-windows
  (%with-ide (app desktop)
    (multiple-value-bind (body status) (%get app "/")
      (is (= 200 status))
      (dolist (id '("repl" "clock" "chart" "agent" "inspector" "editor"))
        (is (search (format nil "data-window=~A" id) (remove #\" body)) "window ~A is missing" id))
      (is (search "ide-clock" body) "the IDE's own styles are on the page")
      (is (search (format nil "<script src=~A" ide:+editor-url+) (remove #\" body))
          "the page loads the editor's bundle"))
    (is (equal '("repl" "clock" "chart" "agent" "inspector" "editor")
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
    (is (= 7 (length (ui:desktop-windows desktop))))))

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
      (let ((answer (%post app "/window/repl/action/cancel"
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
                (%post app "/window/repl/action/cancel" "cancel" "0")))))

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
      (%post app "/window/repl/action/cancel" "cancel" (princ-to-string (jobs:job-id job)))
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

(test cancel-is-an-action-of-its-own-on-the-repl-and-agent-windows
  (%with-ide (app desktop)
    (is (equal '("eval" "cancel")
               (mapcar #'car (ui:window-actions (ui:find-window desktop "repl")))))
    (is (equal '("say" "cancel")
               (mapcar #'car (ui:window-actions (ui:find-window desktop "agent")))))
    (%with-gate ()
      (let ((running (%post app "/window/repl/action/eval" "language" "lisp"
                            "input" +wait-at-the-gate+)))
        (is (search "/window/repl/action/cancel" running)
            "the Cancel button posts to the action cancel: ~A" running))
      (let* ((job (ide::item-job (first (%transcript desktop "repl"))))
             (id (princ-to-string (jobs:job-id job))))
        (is (search "Not evaluated" (%post app "/window/repl/action/eval" "cancel" id))
            "eval no longer reads the field cancel, so this is a second input and is refused")
        (is (eq :running (jobs:job-status job)) "and the job is still running")
        (is (search "was cancelled" (%post app "/window/repl/action/cancel" "cancel" id)))
        (is (jobs:wait-job job :timeout 20))
        (is (eq :cancelled (jobs:job-status job)))))))

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
        (is (search "/window/agent/action/cancel"
                    (%post app "/window/agent/action/say" "text" "a question never answered"))
            "the running turn's Cancel button posts to the action cancel")
        (is (sb-thread:wait-on-semaphore (provider-entered provider) :timeout 20))
        (let* ((turn (first (%transcript desktop "agent")))
               (job (ide::item-job turn))
               (answer (%post app "/window/agent/action/cancel"
                              "cancel" (princ-to-string (jobs:job-id job)))))
          (is (search "The turn was cancelled." answer) "answered: ~A" answer)
          (is (null (search "hx-post" answer)) "with no Cancel button")
          (is (jobs:wait-job job :timeout 20) "the turn's thread ended")
          (is (not (jobs:job-thread-alive-p job)))
          (is (eq :cancelled (getf (ide:inspect-agent-turn turn) :kind)))
          (is (member "agent" calls :test #'string=) "the agent's window was told"))
        (is (search "no turn with that job id"
                    (%post app "/window/agent/action/cancel" "cancel" "0")))))))

;;; --- the clock ---------------------------------------------------------------------------

(test the-clock-shows-the-time-it-reads-and-has-a-one-second-refresh-interval
  (%with-ide (app desktop)
    (let ((ide::*now* (lambda () (encode-universal-time 59 58 23 31 12 2026 0))))
      (let ((body (%get app "/window/clock/body")))
        (is (search "23:58:59" body))
        (is (search "2026-12-31 UTC" body))))
    (is (= 1 (ui:window-refresh (ui:find-window desktop "clock")))
        "the desktop's timer pushes the body every second; the page does not ask")
    (is (null (search "every 1s" (%get app "/window/clock"))))))

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
      (is (search "Windows: repl, clock, chart, agent, inspector, editor." answer))
      (is (search "Shown: repl, clock, agent, inspector, editor." answer)))))

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

(defun %raw-status (port host method path &key headers body (timeout 10))
  "Send one request to 127.0.0.1:PORT over a socket of its own, with HOST as its Host header,
HEADERS (an alist) and BODY (a string), and return the status of the answer, or NIL when no
status line arrived within TIMEOUT seconds. The answer is read on a thread so that a request
the server never answers cannot hold up the test, and the socket is closed afterwards."
  (let* ((socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp))
         (stream nil)
         (reader nil))
    (unwind-protect
         (progn
           (sb-bsd-sockets:socket-connect socket #(127 0 0 1) port)
           (setf stream (sb-bsd-sockets:socket-make-stream socket :input t :output t
                                                                  :external-format :utf-8
                                                                  :buffering :full))
           (format stream "~A ~A HTTP/1.1~C~CHost: ~A~C~CConnection: close~C~C"
                   method path #\Return #\Newline host #\Return #\Newline #\Return #\Newline)
           (loop for (name . value) in headers
                 do (format stream "~A: ~A~C~C" name value #\Return #\Newline))
           (when body
             (format stream "Content-Length: ~D~C~C"
                     (length (sb-ext:string-to-octets body :external-format :utf-8))
                     #\Return #\Newline))
           (format stream "~C~C" #\Return #\Newline)
           (when body (write-string body stream))
           (finish-output stream)
           (setf reader
                 ;; INTERRUPTS: a test thread, started from the test body, which has no
                 ;; interrupt deferred.
                 ;; THREAD-LIFETIME: scoped -- it reads one line, and the socket is closed below.
                 (sb-thread:make-thread
                  (lambda ()
                    (ignore-errors
                     (let ((line (read-line stream nil)))
                       (and line (> (length line) 12)
                            (parse-integer line :start 9 :end 12 :junk-allowed t)))))
                  :name "ouranos-ide test request reader"))
           (sb-thread:join-thread reader :default nil :timeout timeout))
      (ignore-errors (sb-bsd-sockets:socket-close socket))
      (when (and reader (sb-thread:thread-alive-p reader))
        (ignore-errors (sb-thread:join-thread reader :default nil :timeout 2))))))

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
                       (srv:start app :port candidate :host "127.0.0.1"
                                      :request-guard :same-origin :log nil))))
           (base (format nil "http://127.0.0.1:~D" port)))
      (unwind-protect
           (progn
             (is (uv:server-p handler) "the server is hyperion/server-uv, the default backend")
             (is (eql 200 (%raw-status port (format nil "127.0.0.1:~D" port) "GET" "/")))
             (is (eql 403 (%raw-status port (format nil "example.test:~D" port) "GET" "/"))
                 "a request whose Host is not this server's is refused")
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

;;; --- the push feed, over HTTP ------------------------------------------------------------

(defun render-note (window)
  (format nil "<p>note ~A</p>" (ui:window-datum window :text "empty")))

(defun %desktop-threads (desktop)
  "The names of the live threads named for DESKTOP."
  (let ((title (ui:desktop-title desktop)))
    (loop for thread in (sb-thread:list-all-threads)
          for name = (sb-thread:thread-name thread)
          when (and name (search "desktop-ui" name) (search title name)) collect name)))

(defun %read-events (port)
  "Send GET /events to the server on PORT over a socket of its own and read the answer on a
thread. Returns three values: a function of no arguments that returns the text read so far,
with `<end>' added once the server has ended the stream; the reading thread; and the socket."
  (let* ((socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp))
         (lock (sb-thread:make-mutex :name "ouranos-ide test events"))
         (read-so-far (make-string-output-stream))
         (stream nil))
    (sb-bsd-sockets:socket-connect socket #(127 0 0 1) port)
    (setf stream (sb-bsd-sockets:socket-make-stream socket :input t :output t
                                                           :external-format :utf-8
                                                           :buffering :none))
    ;; Connection: close, so that the server closes the connection when it ends the stream and
    ;; the reader sees the end instead of a connection kept open for a next request.
    (format stream "GET /events HTTP/1.1~C~CHost: 127.0.0.1:~D~C~CAccept: text/event-stream~C~CConnection: close~C~C~C~C"
            #\Return #\Newline port #\Return #\Newline #\Return #\Newline #\Return #\Newline
            #\Return #\Newline)
    (finish-output stream)
    (values
     (lambda ()
       (sb-thread:with-mutex (lock)
         (let ((text (get-output-stream-string read-so-far)))
           (write-string text read-so-far)
           text)))
     ;; INTERRUPTS: a test thread, started from the test body, which has no interrupt deferred.
     ;; THREAD-LIFETIME: scoped -- it reads the child's output until the stream ends.
     (sb-thread:make-thread
      (lambda ()
        (ignore-errors
         (loop for line = (read-line stream nil)
               while line
               do (sb-thread:with-mutex (lock)
                    (write-line (string-right-trim '(#\Return) line) read-so-far))))
        (sb-thread:with-mutex (lock) (write-string "<end>" read-so-far))
        :returned)
      :name "ouranos-ide test events reader")
     socket)))

(defun %await (text needle &key (start 0) (timeout 10))
  "Wait until NEEDLE appears in what the function TEXT returns, at or after START. Returns
its position, or NIL after TIMEOUT seconds."
  (let ((deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
    (loop
      (let ((found (search needle (funcall text) :start2 start)))
        (when found (return found)))
      (when (> (get-internal-real-time) deadline) (return nil))
      (sleep 0.02))))

(test the-page-of-the-ide-has-no-polling-attribute
  (%with-ide (app desktop)
    (let ((page (%get app "/")))
      (is (search "data-window=clock" (remove #\" page)))
      (is (null (search "hx-trigger=every" (remove #\" page))))
      (is (null (search "every 1s" page)) "the clock and the inspector do not ask each second")
      (is (null (search "every 5s" page)) "the chart does not ask every five")
      (is (search "EventSource" page) "the page opens the event stream instead"))
    (is (null (search "every" (%get app "/window/clock"))))
    (is (null (search "every" (%get app "/window/inspector"))))
    (is (= 1 (getf (ui:inspect-window (ui:find-window desktop "clock")) :refresh))
        "the clock still has its interval, which the server's timer uses")))

(test start-does-not-log-a-request-that-succeeds
  ;; HYPERION/LOGGING:WRAP logs a successful request at :info unless the path is a quiet one,
  ;; and then at :trace. So the question is whether the path is quiet while the app runs.
  (let* ((quiet-inside :not-called)
         (app (lambda (env)
                (setf quiet-inside (hyperion/logging:quiet-path-p (getf env :path-info)))
                (list 200 '() '("ok"))))
         (env (list :request-method :get :path-info "/window/clock/body")))
    (let ((response (funcall (ide::%logged-quietly app) env)))
      (is (= 200 (first response)))
      (is (getf (second response) :x-request-id) "the request still gets its id"))
    (is (eq t (and quiet-inside t)) "under START's wrapper every path is a quiet one")
    (funcall app env)
    (is (null quiet-inside) "and without the wrapper this path is not, so it would be logged")
    (is (null (hyperion/logging:quiet-path-p "/window/clock/body"))
        "the wrapper changed nothing for other apps in the image")))

(defun %check-event-stream (server)
  "Start the IDE with SERVER, read GET /events over a socket, and check what it pushes and
that STOP ends the timer and the stream."
  (%with-ide (app desktop)
    (let* ((ide:*desktop* desktop)
           (port nil)
           (text nil) (reader nil) (socket nil))
      (unwind-protect
           (progn
             (ports:call-with-port
              (lambda (candidate) (setf port candidate) (ide:start :port candidate :server server)))
             (is (eq (eq server :uv) (uv:server-p ide::*handler*))
                 "START used the backend it was given: ~S" server)
             (is (null (%desktop-threads desktop)) "no page is connected, so no timer thread")
             (multiple-value-setq (text reader socket) (%read-events port))
             (is (%await text "text/event-stream") "the answer is an event stream")
             (is (%await text ": connected"))
             (sleep 0.3)
             (is (equal '("desktop-ui timer: Ouranos IDE") (%desktop-threads desktop))
                 "one timer thread while a page is connected")
             ;; A window opened from the REPL, with a page connected.
             (let ((mark (length (funcall text)))
                   (note nil))
               (setf note (ui:open-window desktop "note" :title "Note" :render 'render-note
                                                         :x 30 :y 40))
               (is (%await text "data: window note 360x240 left:30px;top:40px" :start mark)
                   "the page is told about the window without a reload")
               (is (%await text "data: html win-note-body" :start mark))
               (is (%await text "data: <p>note empty</p>" :start mark))
               ;; A change made outside a request, as a job would make it.
               (setf mark (length (funcall text)))
               (setf (ui:window-datum note :text) "from a job")
               (ui:window-changed note)
               (is (%await text "data: <p>note from a job</p>" :start mark)
                   "window-changed pushes the new body")
               ;; A close posted by a page.
               (setf mark (length (funcall text)))
               (let ((base (format nil "http://127.0.0.1:~D" port)))
                 (dex:post (format nil "~A/window/note/event" base) :keep-alive nil
                           :headers `(("Origin" . ,base)) :content '(("type" . "close"))))
               (is (%await text "data: remove note" :start mark) "a close removes the window")
               ;; The clock's refresh interval, with no request and no call.
               (setf mark (length (funcall text)))
               (let ((first (%await text "data: html win-clock-body" :start mark)))
                 (is-true first "the timer pushes the clock's body")
                 (is (%await text "data: html win-clock-body" :start (if first (1+ first) mark))
                     "and pushes it again a second later"))))
        (ide:stop)
        (when port
          (is (ports:await-released port) "the port is released"))
        (is (null (%desktop-threads desktop)) "no thread named for the desktop is left")
        (is (zerop (ui:desktop-subscribers desktop)) "no stream is being written")
        (when reader
          (is (eq :returned (sb-thread:join-thread reader :default :still-reading :timeout 5))
              "the server ended the page's stream")
          (is (search "<end>" (funcall text)))
          (when (sb-thread:thread-alive-p reader) (sb-thread:terminate-thread reader)))
        (when socket (ignore-errors (sb-bsd-sockets:socket-close socket)))))))

(test the-event-stream-pushes-changes-over-http-and-stop-ends-the-timer-and-the-streams
  (is (eq :uv (srv:default-server)) "with no HYPERION_SERVER set, START's default is :uv")
  (%check-event-stream :uv))

;;; --- open event streams do not hold up other requests --------------------------------------
;;;
;;; Each page's GET /events is written by one of server-uv's handler threads for as long as
;;; the page is open. With too few threads, a few open pages hold all of them and every other
;;; request waits in the pool's queue. START gives :uv *WORKERS* threads for this reason.

(defun %post-with-streams-open (streams &rest start-args)
  "Start the IDE with START-ARGS, open STREAMS GET /events streams and wait until the server
has started writing each one, then post an evaluation from the page's origin. Returns the
status of the POST's answer, or NIL when none came within two seconds, and as a second value
how many streams the server was writing when the POST was sent."
  (%with-ide (app desktop)
    (let ((ide:*desktop* desktop)
          (port nil)
          (readers '()))
      (unwind-protect
           (progn
             (ports:call-with-port
              (lambda (candidate)
                (setf port candidate)
                (apply #'ide:start :port candidate start-args)))
             (dotimes (i streams)
               (multiple-value-bind (text reader socket) (%read-events port)
                 (push (list text reader socket) readers)))
             ;; A stream the pool has not started yet sends nothing, so wait for the ones that
             ;; can start, up to a deadline, and count what the server is writing.
             (loop with deadline = (+ (get-internal-real-time) (* 3 internal-time-units-per-second))
                   until (or (= streams (ui:desktop-subscribers desktop))
                             (> (get-internal-real-time) deadline))
                   do (sleep 0.02))
             (let ((writing (ui:desktop-subscribers desktop))
                   (base (format nil "http://127.0.0.1:~D" port)))
               (values (%raw-status port (format nil "127.0.0.1:~D" port)
                                    "POST" "/window/repl/action/eval"
                                    :headers `(("Origin" . ,base)
                                               ("Content-Type" . "application/x-www-form-urlencoded"))
                                    :body "language=lisp&input=%28%2B+1+2%29"
                                    :timeout 2)
                       writing)))
        (ide:stop)
        (loop for (nil reader socket) in readers
              do (ignore-errors (sb-bsd-sockets:socket-close socket))
                 (unless (eq :returned (sb-thread:join-thread reader :default nil :timeout 5))
                   (ignore-errors (sb-thread:terminate-thread reader))))
        (when port (ports:await-released port))))))

(test a-post-is-answered-while-three-pages-hold-event-streams-open
  (multiple-value-bind (status writing) (%post-with-streams-open 3)
    (is (= 3 writing) "the server was writing all three streams")
    (is (eql 200 status) "the POST was answered within two seconds: ~S" status)))

(test control-with-two-workers-three-open-streams-leave-a-post-unanswered
  ;; The same requests with hyperion/server's default for :uv, two handler threads. Two of
  ;; the streams hold both, and the third stream and the POST wait in the queue. Without this
  ;; control the test above would pass on a server that never runs out of threads.
  (multiple-value-bind (status writing) (%post-with-streams-open 3 :workers 2)
    (is (= 2 writing) "two streams were written, and the third waited for a thread")
    (is (null status) "the POST was not answered within two seconds: ~S" status)))

;;; --- the editor window: the committed bundle ---------------------------------------------

(defun %file-octets (path)
  "The bytes of the file at PATH. The count READ-SEQUENCE returns is checked against the
length, so a short read is an error and not a truncated digest."
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let* ((octets (make-array (file-length in) :element-type '(unsigned-byte 8)))
           (read (read-sequence octets in)))
      (unless (= read (length octets))
        (error "Read ~D of ~D bytes of ~A." read (length octets) path))
      octets)))

(defun %recorded-sha256 ()
  "The first word of editor/ouranos-editor.min.js.sha256, which build.sh writes."
  (let ((text (uiop:read-file-string
               (merge-pathnames "ouranos-editor.min.js.sha256" (ide:editor-directory)))))
    (subseq text 0 (position-if (lambda (c) (member c '(#\Space #\Tab #\Newline #\Return))) text))))

(test the-committed-editor-bundle-matches-its-recorded-sha256
  ;; build.sh writes the bundle and its SHA-256 together. A bundle edited by hand, or rebuilt
  ;; without committing the new SHA-256, or the reverse, fails here.
  (let ((recorded (%recorded-sha256))
        (actual (ironclad:byte-array-to-hex-string
                 (ironclad:digest-sequence :sha256 (%file-octets (ide:editor-bundle-path))))))
    (is (= 64 (length recorded)) "the record is one SHA-256 in hexadecimal: ~S" recorded)
    (is (string= recorded actual)
        "editor/ouranos-editor.min.js has SHA-256 ~A, and editor/ouranos-editor.min.js.sha256 records ~A. Run editor/build.sh and commit both."
        actual recorded)))

(test the-ide-serves-the-editor-bundle-and-nothing-else-from-its-directory
  (%with-ide (app desktop)
    (let ((response (funcall app (list :request-method :get :path-info ide:+editor-url+))))
      (is (= 200 (first response)))
      (is (search "javascript" (getf (second response) :content-type)))
      (is (equal "no-cache" (getf (second response) :cache-control)))
      (let ((body (third response)))
        (is (streamp body) "the body is the open file")
        (when (streamp body)
          (let* ((expected (%file-octets (ide:editor-bundle-path)))
                 (served (make-array (length expected) :element-type '(unsigned-byte 8)))
                 (read (unwind-protect (read-sequence served body) (close body))))
            (is (= read (length expected)))
            (is (equalp expected served) "the bytes served are the committed bundle's")))))
    (dolist (path '("/ide/editor/package.json" "/ide/editor/ouranos-editor.min.js.sha256"
                    "/ide/editor/src/editor.js" "/ide/editor/../ide.lisp"))
      (is (= 404 (nth-value 1 (%get app path))) "~A is not served" path))))

;;; --- the editor window: its body and its actions -----------------------------------------

(test the-editor-body-holds-a-kept-editor-element-and-the-evaluate-form
  (%with-ide (app desktop)
    (let ((body (remove #\" (%get app "/window/editor/body"))))
      (is (search "data-ou-editor=1" body) "the element the page builds the editor in")
      (is (search "id=win-editor-code" body))
      (is (search "data-ou-preserve=1" body) "kept when the body is pushed")
      (is (search "data-ou-editor-form=win-editor-form" body) "it names the form that evaluates")
      (is (search "hx-post=/window/editor/action/eval" body))
      (is (search "hx-target=#win-editor-results" body))
      (is (search "type=hidden name=input" body) "the field the page fills with the text")
      (is (search "type=hidden name=buffer" body))
      (is (search "Mod-Enter" body)))
    (is (equal '(("eval" . "PRAXEON/EXAMPLES/OURANOS-IDE::EDITOR-EVAL")
                 ("cancel" . "PRAXEON/EXAMPLES/OURANOS-IDE::EDITOR-CANCEL"))
               (getf (ui:inspect-window (ui:find-window desktop "editor")) :actions)))))

(test empty-editor-input-is-refused-without-starting-a-job-or-a-runtime
  (%with-ide (app desktop)
    (let ((answer (%post app "/window/editor/action/eval" "language" "coalton"
                         "input" (format nil "  ~%") "buffer" "")))
      (is (search "Nothing to evaluate" answer))
      (is (null (%transcript desktop "editor")))
      (is (null (jobs:window-jobs (ui:find-window desktop "editor"))))
      (is-false (ide:runtime-ready-p)))))

(defun %editor-eval (app desktop language input &key (buffer input))
  "Send INPUT to the editor window, wait for its job, and return the entry's record and the
request's answer. The first evaluation starts the runtime, so the wait is long."
  (let* ((answer (%post app "/window/editor/action/eval"
                        "language" language "input" input "buffer" buffer))
         (entry (first (%transcript desktop "editor"))))
    (unless (and entry (jobs:wait-job (ide::item-job entry) :timeout 400))
      (error "The editor's evaluation of ~S did not end within 400 seconds." input))
    (values (ide:inspect-editor-entry entry) answer)))

(test the-editor-evaluates-in-the-coalton-runtime-and-a-cancel-stops-it
  ;; One runtime for the whole test, because starting one takes seconds.
  (%with-ide (app desktop)
    (%recording-changes (calls)
      (let ((record (%editor-eval app desktop "coalton" "(+ 1 2)")))
        (is (eq :value (getf record :kind)) "~S" record)
        (is (equal '("3") (getf record :values)))
        (is (search "Starting the Coalton runtime" (getf record :output))
            "the first evaluation reports the runtime's start")
        (is (member "editor" calls :test #'string=)
            "the job's end tells the editor window, which pushes its body"))
      (is-true (ide:runtime-ready-p))
      (is (equal "(+ 1 2)" (ui:window-datum (ui:find-window desktop "editor") :buffer)))
      ;; A declaration and its definition are compiled together, and stay in the runtime for
      ;; the next evaluation.
      (let ((record (%editor-eval app desktop "coalton"
                                  (format nil "(declare editor-inc (Integer -> Integer))~%(define (editor-inc x) (+ x 1))"))))
        (is (eq :definition (getf record :kind)) "~S" record)
        (is (null (search "Starting" (getf record :output))) "the runtime is reused"))
      (let ((record (%editor-eval app desktop "coalton" "(editor-inc 41)")))
        (is (equal '("42") (getf record :values)) "~S" record))
      ;; Definitions and then an expression in one buffer: the value is the expression's.
      (let ((record (%editor-eval app desktop "coalton"
                                  (format nil ";; twice~%(declare editor-twice (Integer -> Integer))~%(define (editor-twice x) (* 2 x))~%~%(editor-twice (editor-inc 20))"))))
        (is (eq :value (getf record :kind)) "~S" record)
        (is (equal '("42") (getf record :values))))
      ;; A type error in a definition has a diagnostic at its place in the evaluated text.
      (let* ((text (format nil "(+ 1 1)~%(declare editor-bad (Integer -> Integer))~%(define (editor-bad x) (+ x \"a\"))"))
             (at (search "\"a\"" text))
             (record (%editor-eval app desktop "coalton" text))
             (diagnostic (first (getf record :diagnostics))))
        (is (eq :error (getf record :kind)) "~S" record)
        (is (eql at (getf diagnostic :start)) "~S" diagnostic)
        (is (eql (+ at 3) (getf diagnostic :end)))
        (is (search "mismatch" (string-downcase (getf diagnostic :summary)))))
      ;; Lisp mode evaluates Common Lisp in the runtime's CL-USER, with what it prints.
      (let ((record (%editor-eval app desktop "lisp" "(progn (princ \"hello\") (values 1 :two))")))
        (is (equal '("1" ":TWO") (getf record :values)) "~S" record)
        (is (search "hello" (getf record :printed))))
      ;; A type error comes back as an error, with the runtime's report of it.
      (let ((record (%editor-eval app desktop "coalton" "(editor-inc \"a\")")))
        (is (eq :error (getf record :kind)) "~S" record)
        (is (search "mismatch" (string-downcase (format nil "~S" record)))))
      ;; An endless evaluation: a second one is refused while it runs, then a cancel stops it.
      (let* ((answer (%post app "/window/editor/action/eval" "language" "lisp" "input" "(loop)"))
             (entry (first (%transcript desktop "editor")))
             (job (ide::item-job entry)))
        (is (search "Cancel" answer) "the running entry has a Cancel button")
        (is (search "Not evaluated" (%post app "/window/editor/action/eval"
                                           "language" "lisp" "input" "(+ 1 1)"))
            "a second evaluation is refused while one runs")
        ;; Let the runtime start the request, so the interrupt reaches it.
        (loop repeat 100 until (rt:runtime-busy-p ide::*runtime*) do (sleep 0.05))
        (let ((answer (%post app "/window/editor/action/cancel"
                             "cancel" (princ-to-string (jobs:job-id job)))))
          (is (search "cancelled" answer)))
        (is-true (jobs:wait-job job :timeout 20))
        (is (eq :cancelled (getf (ide:inspect-editor-entry entry) :kind)))
        (is-false (jobs:job-thread-alive-p job) "the job's thread ended"))
      ;; The same runtime answers afterwards, so the interrupt ended the evaluation only.
      (let* ((runtime ide::*runtime*)
             (record (%editor-eval app desktop "lisp" "(+ 1 2)")))
        (is (equal '("3") (getf record :values)) "~S" record)
        (is (eq runtime ide::*runtime*) "the runtime was not restarted")
        (ide:stop-runtime)
        (is-false (rt:runtime-alive-p runtime) "STOP-RUNTIME ended the child")
        (is-false (ide:runtime-ready-p))))))

(test coalton-text-is-split-into-runs-of-definitions-and-of-other-forms
  (flet ((runs (text)
           (mapcar (lambda (run) (list (first run) (subseq text (second run) (third run))))
                   (ide:coalton-runs text))))
    (is (null (runs "")))
    (is (null (runs (format nil "  ; only a comment~%#| and a block |#  "))))
    (is (equal '((:expressions "(+ 1 2)")) (runs " (+ 1 2) ")))
    (is (equal '((:definitions "(declare f (Integer -> Integer))
(define (f x) x)")
                 (:expressions "(f 1)"))
               (runs (format nil "(declare f (Integer -> Integer))~%(define (f x) x)~%~%(f 1)"))))
    (is (equal '((:expressions "(f 1)") (:definitions "(coalton:define-type T (T1))"))
               (runs "(f 1) (coalton:define-type T (T1))"))
        "a package prefix and any define- form count as definitions")
    (is (equal '((:definitions "(define s \"a ) ; ( string\")")
                 (:expressions "(g #\\( #\\Space)"))
               (runs (format nil "(define s \"a ) ; ( string\")~%; (define ignored)~%(g #\\( #\\Space)")))
        "parentheses in strings, comments and character literals do not count")
    (is (equal '((:expressions "(unclosed (form")) (runs "(unclosed (form"))
        "an unclosed form runs to the end")))

;;; --- the editor bundle in a headless browser ---------------------------------------------
;;;
;;; The tests above check the bundle's bytes and the HTML around it. This one checks that the
;;; bundle, run by a browser, builds the editor and fills the form. It reuses the headless
;;; browser helpers of hyperion/assets/tests, which run Chrome or Edge with --dump-dom and no
;;; window, and SKIPS WHEN NO BROWSER IS FOUND, as those tests do. The page is not the IDE's
;;; desktop page, because that page keeps GET /events open, and the browser's virtual time
;;; does not advance while a request is pending. It is the editor window's body on a page of
;;; its own, with a route that answers the evaluate form with what it was sent.

(defparameter +browser-doc+ (format nil "(defun f (x)~%  \"s\" (+ x 1))")
  "The editor's starting text in the browser test.")

(defun %editor-test-page (desktop)
  "A page holding the editor window's body, htmx and the bundle. When it has loaded, its script
selects (+ x 1), presses Mod-Enter in the editor, then puts the cursor after the last closing
parenthesis and clicks Evaluate."
  (let* ((window (ui:find-window desktop "editor"))
         (from (search "(+ x 1)" +browser-doc+))
         (to (+ from (length "(+ x 1)"))))
    (setf (ui:window-datum window :buffer) +browser-doc+)
    (format nil "<!doctype html>
<html><head><meta charset=\"utf-8\">
<script src=\"~A\" defer></script><script src=\"~A\" defer></script></head>
<body><div id=\"win-editor-body\">~A</div>
<script>
window.addEventListener('load', function () {
  var host = document.getElementById('win-editor-code');
  var view = window.OuranosEditor.viewOf(host);
  var mac = /Mac/.test(navigator.platform);
  view.dispatch({selection: {anchor: ~D, head: ~D}});
  view.contentDOM.dispatchEvent(new KeyboardEvent('keydown',
    {key: 'Enter', bubbles: true, cancelable: true, metaKey: mac, ctrlKey: !mac}));
  setTimeout(function () {
    view.dispatch({selection: {anchor: view.state.doc.length}});
    document.querySelector('#win-editor-form button[type=submit]').click();
  }, 300);
});
</script></body></html>"
            (assets:url :htmx) ide:+editor-url+ (ide:render-editor window) from to)))

(defun %editor-test-app (desktop)
  (router:to-app
   (router:router
    (assets:mount)
    (router:route :get "/" (lambda (env) (declare (ignore env))
                             (list 200 '(:content-type "text/html; charset=utf-8")
                                   (list (%editor-test-page desktop)))))
    (router:route :get ide:+editor-url+ (lambda (env) (ide::%serve-bundle env)))
    (router:route :post "/window/editor/action/eval"
                  (lambda (env)
                    (let ((fields (http:form-alist (or (http:body-string env) ""))))
                      (flet ((field (name) (or (cdr (assoc name fields :test #'string=)) "")))
                        (list 200 '(:content-type "text/html; charset=utf-8")
                              (list (format nil "<pre class=\"echo\">input=[~A] buffer=[~A]</pre>"
                                            (spinneret:escape-string (field "input"))
                                            (spinneret:escape-string (field "buffer"))))))))))))

(test the-bundle-builds-the-editor-in-a-browser-and-fills-the-form
  (let ((browser (aion/cdp:find-browser)))
    (if (null browser)
        (skip "No Chrome or Edge was found; set OURANOS_BROWSER to run this test.")
        (%with-ide (app desktop)
          (let* ((port nil)
                 (handler (ports:call-with-port
                           (lambda (p)
                             (prog1 (srv:start (%editor-test-app desktop)
                                               :port p :host "127.0.0.1" :log nil)
                               (setf port p))))))
            (unwind-protect
                 ;; --dump-dom's output has CRLF line endings on Windows, and the text this test
                 ;; looks for has a line break in it, so CRLF is read as LF first (#1220). The
                 ;; form posts the text with LF on every platform.
                 (let ((dom (%lf-line-endings
                             (smoke::%run-browser browser (format nil "http://127.0.0.1:~D/" port)))))
                   (is (search "cm-editor" dom) "the bundle built an editor")
                   (is (search "id=\"win-editor-code\"" dom))
                   (is (= 2 (%count "class=\"cm-line" dom)) "one element per line of the text")
                   (is (search "class=\"ͼ" dom) "the Lisp text is highlighted")
                   (is (search "cm-matchingBracket" dom)
                       "the parenthesis matching the one before the cursor is marked")
                   (is (search "input=[(+ x 1)] buffer=[" dom)
                       "Mod-Enter sent the selection, and the whole text as the buffer")
                   (is (search (format nil "input=[~A] buffer=[~A]" +browser-doc+ +browser-doc+) dom)
                       "Evaluate with nothing selected sent the whole text"))
              (ignore-errors (srv:stop handler))
              (is (ports:await-released port))))))))

(defun %lf-line-endings (text)
  "TEXT with every CR that comes before an LF removed."
  (with-output-to-string (out)
    (loop for i from 0 below (length text)
          for c = (char text i)
          unless (and (char= c #\Return) (< (1+ i) (length text))
                      (char= (char text (1+ i)) #\Linefeed))
            do (write-char c out))))

(defun %count (needle text)
  "How many times NEEDLE appears in TEXT."
  (loop with count = 0
        for at = (search needle text) then (search needle text :start2 (1+ at))
        while at do (incf count)
        finally (return count)))
