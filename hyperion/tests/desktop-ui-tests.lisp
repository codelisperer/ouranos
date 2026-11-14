;;;; desktop-ui-tests.lisp --- hyperion/desktop-ui: state, windows, inspector, routes, jobs (#1218).
;;;;
;;;; No server and no window are started. The job tests start threads, and each waits for its
;;;; threads to end. The routes are called as a Clack application, with
;;;; the request body already cached, the way the Coalton REPL example's tests call theirs.

(cl:defpackage #:hyperion/desktop-ui/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:ui #:hyperion/desktop-ui)
                    (#:state #:hyperion/desktop-ui/state)
                    (#:jobs #:hyperion/desktop-ui/jobs)
                    (#:job-status #:hyperion/desktop-ui/job-status)
                    (#:http #:hyperion/http))
  (:export #:run-tests))

(cl:in-package #:hyperion/desktop-ui/tests)

(def-suite desktop-ui :description "hyperion/desktop-ui: a desktop of floating windows (#1218).")
(in-suite desktop-ui)

(defun run-tests () (run! 'desktop-ui))

;;; --- helpers -----------------------------------------------------------------------------

(defun %fields (s)
  "The six fields of a state, as a list."
  (list (state:state-x s) (state:state-y s) (state:state-width s) (state:state-height s)
        (state:state-z s) (state:state-shown? s)))

(defun %get (app path)
  "The status and body of GET PATH."
  (let ((response (funcall app (list :request-method :get :path-info path))))
    (values (first response) (apply #'concatenate 'string (third response)) (second response))))

(defun %post (app path &rest fields)
  "The status, body and headers of POST PATH with the form FIELDS (name value ...)."
  (let* ((body (format nil "~{~A=~A~^&~}" fields))
         (response (funcall app (http:cache-body-string
                                 (list :request-method :post :path-info path) body))))
    (values (first response) (apply #'concatenate 'string (third response)) (second response))))

(defun body-one (window)
  (declare (ignore window))
  "<p>first definition</p>")

(defun body-failing (window)
  (declare (ignore window))
  (error "deliberately broken"))

(defun echo-action (window parameters)
  (setf (ui:window-datum window :said) (cdr (assoc "text" parameters :test #'string=)))
  (format nil "<p>heard ~A</p>" (ui:window-datum window :said)))

(defun %desktop ()
  "A desktop with two windows: `one' at 10,20 and `two' at 300,40."
  (let ((d (ui:make-desktop :title "Test desktop")))
    (ui:open-window d "one" :title "One" :render 'body-one :x 10 :y 20 :width 200 :height 100
                            :actions '(("echo" . echo-action)) :data (list :count 3))
    (ui:open-window d "two" :title "Two" :render 'body-one :x 300 :y 40 :refresh 5)
    d))

;;; --- the Coalton core --------------------------------------------------------------------

(test apply-event-computes-the-next-state
  (let ((s (state:make-state 10 20 200 100 1)))
    (is (equal '(10 20 200 100 1 t) (%fields s)))
    (is (equal '(55 66 200 100 1 t) (%fields (state:apply-event (state:move-event 55 66) s))))
    (is (equal '(10 20 400 300 1 t) (%fields (state:apply-event (state:resize-event 400 300) s))))
    (is (equal '(10 20 200 100 7 t) (%fields (state:apply-event (state:raise-event 7) s))))
    (is (equal '(10 20 200 100 1 nil) (%fields (state:apply-event state:close-event s))))
    (is (equal '(10 20 200 100 1 t)
               (%fields (state:apply-event state:open-event
                                           (state:apply-event state:close-event s)))))
    (is (equal '(10 20 200 100 1 t) (%fields s)) "the original state is unchanged")))

(test apply-event-keeps-a-window-on-the-desktop-and-above-the-minimum-size
  (let ((s (state:make-state 10 20 200 100 5)))
    (is (equal '(0 0) (subseq (%fields (state:apply-event (state:move-event -30 -1) s)) 0 2)))
    (is (equal (list state:minimum-width state:minimum-height)
               (subseq (%fields (state:apply-event (state:resize-event 1 1) s)) 2 4)))
    (is (= 5 (state:state-z (state:apply-event (state:raise-event 2) s)))
        "a raise to a lower z leaves the window where it is")
    (is (equal (list 0 0 state:minimum-width state:minimum-height 1 t)
               (%fields (state:make-state -5 -5 0 0 1)))
        "MAKE-STATE holds a new window to the same limits")))

(test an-event-names-itself-and-lists-its-numbers
  (is (equal '(:name "move" :arguments (3 4)) (ui:inspect-event (state:move-event 3 4))))
  (is (equal '(:name "resize" :arguments (30 40)) (ui:inspect-event (state:resize-event 30 40))))
  (is (equal '(:name "raise" :arguments (9)) (ui:inspect-event (state:raise-event 9))))
  (is (equal '(:name "close" :arguments ()) (ui:inspect-event state:close-event)))
  (is (equal '(:name "open" :arguments ()) (ui:inspect-event state:open-event))))

;;; --- windows and events ------------------------------------------------------------------

(test a-new-window-is-placed-above-the-others
  (let ((d (%desktop)))
    (is (equal '("one" "two") (getf (ui:inspect-desktop d) :windows)))
    (is (= 1 (getf (ui:inspect-window (ui:find-window d "one")) :z)))
    (is (= 2 (getf (ui:inspect-window (ui:find-window d "two")) :z)))
    (is (= 2 (getf (ui:inspect-desktop d) :top-z)))
    (signals error (ui:open-window d "Not Valid" :render 'body-one))))

(test opening-a-window-with-an-existing-id-replaces-it
  (let ((d (%desktop)))
    (ui:open-window d "one" :title "One again" :render 'body-one)
    (is (equal '("two" "one") (getf (ui:inspect-desktop d) :windows)))
    (is (string= "One again" (ui:window-title (ui:find-window d "one"))))))

(test dispatch-event-changes-the-window-and-records-the-event
  (let ((d (%desktop)))
    (ui:dispatch-event d "one" (state:move-event 70 80))
    (ui:dispatch-event d "one" (ui:event-from-parameters d '(("type" . "raise"))))
    (let ((record (ui:inspect-window (ui:find-window d "one"))))
      (is (= 70 (getf record :x)))
      (is (= 80 (getf record :y)))
      (is (= 3 (getf record :z)) "raised above window two, which was at 2")
      (is (equal '((:name "raise" :arguments (3)) (:name "move" :arguments (70 80)))
                 (getf record :events))
          "newest first"))
    (signals ui:unknown-window (ui:dispatch-event d "absent" state:close-event))))

(test a-window-keeps-only-its-most-recent-events
  (let ((d (%desktop)) (ui:*event-history* 3))
    (dotimes (i 5) (ui:dispatch-event d "one" (state:move-event i i)))
    (is (equal '((4 4) (3 3) (2 2))
               (mapcar (lambda (e) (getf e :arguments))
                       (getf (ui:inspect-window (ui:find-window d "one")) :events))))))

(test event-from-parameters-refuses-what-it-does-not-understand
  (let ((d (%desktop)))
    (is (equal '(:name "move" :arguments (5 6))
               (ui:inspect-event
                (ui:event-from-parameters d '(("type" . "move") ("x" . "5") ("y" . "6.5"))))))
    (signals ui:bad-event (ui:event-from-parameters d '(("type" . "explode"))))
    (signals ui:bad-event (ui:event-from-parameters d '(("type" . "move") ("x" . "5"))))
    (signals ui:bad-event
      (ui:event-from-parameters d '(("type" . "move") ("x" . "abc") ("y" . "1"))))))

;;; --- inspecting --------------------------------------------------------------------------

(test inspect-window-returns-plain-data
  (let* ((d (%desktop))
         (record (ui:inspect-window (ui:find-window d "one"))))
    (is (equal '(:id "one" :title "One" :x 10 :y 20 :width 200 :height 100 :z 1
                 :visibility :shown)
               (subseq record 0 16)))
    (is (search "BODY-ONE" (getf record :render)))
    (is (equal "echo" (car (first (getf record :actions)))))
    (is (equal '(:count 3) (getf record :data)))
    (is (null (getf record :refresh)))
    (is (= 5 (getf (ui:inspect-window (ui:find-window d "two")) :refresh)))))

(test inspect-window-shows-an-object-in-the-data-by-its-type-only
  (let* ((d (%desktop))
         (w (ui:find-window d "one")))
    (setf (ui:window-datum w :held) (make-hash-table))
    (setf (ui:window-datum w :text) (make-string 300 :initial-element #\a))
    (let ((data (getf (ui:inspect-window w) :data)))
      (is (search "HASH-TABLE" (getf data :held)))
      (is (stringp (getf data :held)) "the object itself is not in the record")
      (is (= 123 (length (getf data :text))) "a long string is cut to 120 characters and ..."))))

(test inspect-desktop-lists-shown-windows
  (let ((d (%desktop)))
    (ui:dispatch-event d "two" state:close-event)
    (is (equal '(:title "Test desktop" :windows ("one" "two") :shown ("one") :top-z 2)
               (ui:inspect-desktop d)))))

;;; --- rendering and redefinition ----------------------------------------------------------

(test a-window-renders-with-its-position-and-its-body
  (let* ((d (%desktop))
         (html (ui:render-window (ui:find-window d "one"))))
    (is (search "id=win-one" (remove #\" html)))
    (is (search "left:10px;top:20px;width:200px;height:100px;z-index:1" html))
    (is (search "<p>first definition</p>" html))
    (is (null (search "every" html)) "no refresh interval, so no polling")
    (is (search "every 5s" (ui:render-window (ui:find-window d "two"))))))

(test redefining-a-render-function-changes-the-next-render
  (let* ((d (%desktop))
         (w (ui:find-window d "one"))
         (original (fdefinition 'body-one)))
    (unwind-protect
         (progn
           (is (search "first definition" (ui:render-window-body w)))
           ;; What a DEFUN typed at a REPL does: the symbol gets a new function. The
           ;; window holds the symbol, so nothing about the window is touched.
           (setf (fdefinition 'body-one)
                 (lambda (window) (format nil "<p>second definition of ~A</p>" (ui:window-id window))))
           (is (search "second definition of one" (ui:render-window-body w)))
           (is (null (search "first definition" (ui:render-window-body w))))
           (is (search "second definition of two"
                       (nth-value 1 (%get (ui:make-app d) "/window/two/body")))
               "an application made before the redefinition serves the new body"))
      (setf (fdefinition 'body-one) original))))

(test redefining-a-desktop-ui-entry-point-reaches-its-compiled-callers
  "RENDER-WINDOW calls RENDER-WINDOW-BODY, and both are declared NOTINLINE. Replacing
RENDER-WINDOW-BODY must change what the already compiled RENDER-WINDOW returns."
  (let* ((d (%desktop))
         (w (ui:find-window d "one"))
         (original (fdefinition 'ui:render-window-body)))
    (unwind-protect
         (progn
           (setf (fdefinition 'ui:render-window-body)
                 (lambda (window) (declare (ignore window)) "<p>replaced entry point</p>"))
           (is (search "replaced entry point" (ui:render-window w))))
      (setf (fdefinition 'ui:render-window-body) original))
    (is (search "first definition" (ui:render-window w)))))

(test an-error-in-a-render-function-is-shown-in-that-window-only
  (let ((d (%desktop)))
    (ui:open-window d "broken" :title "Broken" :render 'body-failing)
    (multiple-value-bind (status body) (%get (ui:make-app d) "/")
      (is (= 200 status))
      (is (search "deliberately broken" body))
      (is (search "first definition" body) "the other windows still render"))))

;;; --- the routes --------------------------------------------------------------------------

(test the-page-holds-every-shown-window-and-the-dock
  (let* ((d (%desktop))
         (app (ui:make-app d)))
    (ui:dispatch-event d "two" state:close-event)
    (multiple-value-bind (status body) (%get app "/")
      (is (= 200 status))
      (is (search "data-window=one" (remove #\" body)))
      (is (null (search "data-window=two" (remove #\" body))) "a closed window is not on the page")
      (is (search "ou-dock" body))
      (is (search "Test desktop" body))
      (is (search "pointerdown" body) "the script is on the page")
      (is (null (search "<" (ui:client-js))) "the script has no angle bracket")
      (is (null (search ">" (ui:client-js)))))))

(test the-event-route-moves-raises-closes-and-opens
  (let* ((d (%desktop))
         (app (ui:make-app d)))
    (is (= 204 (%post app "/window/one/event" "type" "move" "x" "111" "y" "222")))
    (is (search "left:111px;top:222px" (nth-value 1 (%get app "/window/one"))))
    (is (= 204 (%post app "/window/one/event" "type" "resize" "width" "500" "height" "400")))
    (is (search "width:500px;height:400px" (nth-value 1 (%get app "/window/one"))))
    (multiple-value-bind (status body) (%post app "/window/one/event" "type" "raise")
      (is (= 200 status))
      (is (string= "3" body) "the new z, for the page to apply"))
    (multiple-value-bind (status body headers) (%post app "/window/one/event" "type" "close")
      (is (= 200 status))
      (is (string= "" body) "an empty body, which the page swaps over the window")
      (is (equal "ou-dock" (getf headers :hx-trigger))))
    (is (equal '("two") (getf (ui:inspect-desktop d) :shown)))
    (is (search "ou-hidden" (nth-value 1 (%get app "/dock"))) "the dock offers to open it again")
    (multiple-value-bind (status body) (%post app "/window/one/event" "type" "open")
      (is (= 200 status))
      (is (search "left:111px;top:222px" body) "it comes back where it was"))
    (is (equal '("one" "two") (getf (ui:inspect-desktop d) :shown)))))

(test the-event-route-answers-404-and-400
  (let ((app (ui:make-app (%desktop))))
    (is (= 404 (%post app "/window/absent/event" "type" "close")))
    (is (= 400 (%post app "/window/one/event" "type" "explode")))
    (is (= 400 (%post app "/window/one/event" "type" "move" "x" "1")))
    (is (= 404 (%get app "/window/absent")))
    (is (= 404 (%get app "/window/absent/body")))))

(test an-action-is-called-with-the-window-and-the-form
  (let* ((d (%desktop))
         (app (ui:make-app d)))
    (multiple-value-bind (status body) (%post app "/window/one/action/echo" "text" "hello")
      (is (= 200 status))
      (is (string= "<p>heard hello</p>" body)))
    (is (string= "hello" (ui:window-datum (ui:find-window d "one") :said)))
    (is (= 404 (%post app "/window/one/action/absent")))
    (is (= 404 (%post app "/window/two/action/echo")) "window two has no actions")))

(test a-window-added-after-the-application-was-made-is-served
  (let* ((d (%desktop))
         (app (ui:make-app d)))
    (ui:open-window d "late" :title "Late" :render 'body-one)
    (is (= 200 (%get app "/window/late")))
    (is (search "data-window=late" (remove #\" (nth-value 1 (%get app "/")))))))

;;; --- the inspector window ----------------------------------------------------------------

(test the-inspector-shows-the-record-of-the-window-it-is-pointed-at
  (let* ((d (%desktop))
         (app (ui:make-app d)))
    (ui:open-inspector d)
    (let ((body (nth-value 1 (%get app "/window/inspector/body"))))
      (is (search "the desktop" body))
      (is (search "top-z" body) "with no target it shows the desktop's own record"))
    (multiple-value-bind (status body) (%post app "/window/inspector/action/select" "target" "one")
      (is (= 200 status))
      (is (search "BODY-ONE" body))
      (is (search "<th>x<td>10<" (remove #\Space (remove #\Newline body)))))
    (%post app "/window/one/event" "type" "move" "x" "640" "y" "480")
    (let ((body (nth-value 1 (%post app "/window/inspector/action/record"))))
      (is (search "640" body) "the next poll shows the move")
      (is (search "480" body))
      (is (search "move" body) "and the event that caused it"))
    (is (string= "one" (ui:window-datum (ui:find-window d "inspector") :target)))
    (is (search "INSPECTOR-SELECT"
                (nth-value 1 (%post app "/window/inspector/action/select" "target" "inspector")))
        "the inspector can inspect itself")))

;;; --- a render function that runs out of stack ---------------------------------------------

(defun %lose-on-corruption-address ()
  "The address of the SBCL runtime's variable lose_on_corruption_p, or NIL when the runtime
does not let it be found."
  (sb-sys:find-foreign-symbol-address "lose_on_corruption_p"))

(defmacro %with-recoverable-stack-exhaustion (&body body)
  "BODY with SBCL signalling STORAGE-CONDITION when a thread runs out of stack, whatever the
image was started with. `sbcl --script', which is how the gate runs, implies
--lose-on-corruption, and with that SBCL ends the process when the stack runs out, so no
handler runs. That switch is the runtime variable lose_on_corruption_p: BODY runs with it 0,
and it is put back afterwards. Where the variable cannot be found the test is skipped."
  (let ((address (gensym "ADDRESS")) (sap (gensym "SAP")) (old (gensym "OLD")))
    `(let ((,address (%lose-on-corruption-address)))
       (if (null ,address)
           (skip "lose_on_corruption_p was not found in this runtime")
           (let* ((,sap (sb-sys:int-sap ,address))
                  (,old (sb-sys:signed-sap-ref-32 ,sap 0)))
             (unwind-protect
                  (progn (setf (sb-sys:signed-sap-ref-32 ,sap 0) 0)
                         ,@body)
               (setf (sb-sys:signed-sap-ref-32 ,sap 0) ,old)))))))

(defun %descend (n)
  "Recurse without end. The addition after the call keeps the call from being a tail call."
  (1+ (%descend (1+ n))))

(defun body-too-deep (window)
  (declare (ignore window))
  (format nil "<p>~D</p>" (%descend 0)))

(test a-render-function-that-runs-out-of-stack-is-shown-in-that-window-only
  "The renders run on a thread made for them. After a thread has run out of stack once, SBCL
does not always protect its stack's guard page again, and a second exhaustion on that thread
could then end the process; the test runner's own thread is kept clear of that."
  (%with-recoverable-stack-exhaustion
    (let ((d (%desktop)))
      (ui:open-window d "deep" :title "Deep" :render 'body-too-deep)
      (destructuring-bind (body status page &rest headers)
          ;; THREAD-LIFETIME: independent -- joined on the next line.
          (sb-thread:join-thread
           (sb-thread:make-thread
            (lambda ()
              (cons (ui:render-window-body (ui:find-window d "deep"))
                    (multiple-value-list (%get (ui:make-app d) "/"))))
            :name "desktop-ui test, deep render"))
        (declare (ignore headers))
        (is (search "ou-error" body))
        (is (search "stack exhausted" body) "the body says what happened: ~A" body)
        (is (= 200 status))
        (is (search "stack exhausted" page))
        (is (search "first definition" page) "the other windows still render")))))

;;; --- jobs: the Coalton core ---------------------------------------------------------------

(defun %status-after (&rest events)
  "The name of the status a new job has after EVENTS, applied in order."
  (job-status:status-name
   (reduce (lambda (status event) (job-status:next-status event status))
           events :initial-value job-status:initial-status)))

(test next-status-moves-a-running-job-and-leaves-an-ended-one
  (is (string= "running" (%status-after)))
  (is (not (job-status:status-ended? job-status:initial-status)))
  (is (string= "done" (%status-after job-status:return-event)))
  (is (string= "failed" (%status-after job-status:error-event)))
  (is (string= "cancelled" (%status-after job-status:cancel-event)))
  (is (string= "timed-out" (%status-after job-status:time-limit-event)))
  (is (job-status:status-ended?
       (job-status:next-status job-status:cancel-event job-status:initial-status)))
  (is (string= "cancelled" (%status-after job-status:cancel-event job-status:return-event))
      "a job cancelled first stays cancelled when its function returns afterwards")
  (is (string= "done" (%status-after job-status:return-event job-status:cancel-event))
      "and a job that returned first stays done")
  (is (string= "timed-out" (%status-after job-status:time-limit-event job-status:error-event))))

;;; --- jobs: the shell ----------------------------------------------------------------------

(defun %wait-until (predicate &optional (seconds 10))
  "Call PREDICATE every 10 ms until it returns true or SECONDS have passed. Returns its value."
  (loop with deadline = (+ (get-internal-real-time) (* seconds internal-time-units-per-second))
        for value = (funcall predicate)
        until (or value (> (get-internal-real-time) deadline))
        do (sleep 0.01)
        finally (return value)))

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

(test a-job-runs-on-its-own-thread-with-the-bindings-it-was-given
  (let* ((caller sb-thread:*current-thread*)
         (job (jobs:start-job (lambda ()
                                (list (eq caller sb-thread:*current-thread*)
                                      (package-name *package*)))
                              :name "a test job"
                              :bindings (list (cons '*package* (find-package :keyword))))))
    (is (jobs:wait-job job :timeout 10))
    (is (eq :done (jobs:job-status job)))
    (is (equal '(nil "KEYWORD") (jobs:job-result job))
        "it ran on another thread, with *PACKAGE* bound to the package passed in")
    (is (not (jobs:job-running-p job)))
    (is (not (jobs:job-thread-alive-p job)))
    (is (integerp (jobs:job-ended job)))
    (is (eq job (jobs:find-job (jobs:job-id job))))))

(test a-job-s-output-is-captured-while-it-runs
  (let* ((gate (sb-thread:make-semaphore))
         (d (%desktop))
         (w (ui:find-window d "one")))
    (%recording-changes (calls)
      (let ((job (jobs:start-job (lambda ()
                                   (format t "before the gate~%")
                                   (sb-thread:wait-on-semaphore gate)
                                   (write-string "after the gate")
                                   :finished)
                                 :window w)))
        (unwind-protect
             (progn
               (is (%wait-until (lambda () (search "before the gate" (jobs:job-output job)))))
               (is (eq :running (jobs:job-status job)) "the output is there before the job ends")
               (is (%wait-until (lambda () (member "one" calls :test #'string=)))
                   "the window was told while the job was still running")
               (is (null (search "after the gate" (jobs:job-output job)))))
          (sb-thread:signal-semaphore gate))
        (is (jobs:wait-job job :timeout 10))
        (is (eq :done (jobs:job-status job)))
        (is (eq :finished (jobs:job-result job)))
        (is (string= (format nil "before the gate~%after the gate") (jobs:job-output job)))))))

(test window-changed-is-called-when-a-job-ends-and-not-for-every-write
  (let* ((d (%desktop))
         (w (ui:find-window d "two")))
    (%recording-changes (calls)
      (let ((quiet (jobs:start-job (lambda () 1) :window w)))
        (is (jobs:wait-job quiet :timeout 10))
        (is (equal '("two") calls) "a job that prints nothing tells its window once, at the end"))
      (setf calls '())
      (let ((noisy (jobs:start-job (lambda () (dotimes (i 5000) (format t "line ~D~%" i)))
                                   :window w)))
        (is (jobs:wait-job noisy :timeout 30))
        (is (eq :done (jobs:job-status noisy)))
        (is (search "line 4999" (jobs:job-output noisy)))
        (is (<= 1 (length calls)))
        (is (<= (length calls) (+ 2 (ceiling (jobs:job-seconds noisy) jobs:*change-interval*)))
            "5000 writes told the window ~D times in ~F seconds"
            (length calls) (jobs:job-seconds noisy))))
    (let ((job (jobs:start-job (lambda () 1))))
      (is (jobs:wait-job job :timeout 10) "a job with no window runs too"))))

(test a-job-whose-function-signals-is-failed
  (let ((job (jobs:start-job (lambda () (princ "said this first") (error "deliberately broken")))))
    (is (jobs:wait-job job :timeout 10))
    (is (eq :failed (jobs:job-status job)))
    (is (search "deliberately broken" (jobs:job-error-text job)))
    (is (typep (jobs:job-condition job) 'simple-error))
    (is (null (jobs:job-result job)))
    (is (string= "said this first" (jobs:job-output job)) "the output before the error is kept")))

(test a-job-that-runs-out-of-stack-is-failed
  (%with-recoverable-stack-exhaustion
    (let ((job (jobs:start-job (lambda () (%descend 0)))))
      (is (jobs:wait-job job :timeout 30))
      (is (eq :failed (jobs:job-status job)))
      (is (typep (jobs:job-condition job) 'storage-condition)
          "a STORAGE-CONDITION, which is not an ERROR")
      (is (search "stack exhausted" (jobs:job-error-text job))))))

(test a-job-in-an-endless-loop-is-cancelled-and-its-thread-ends
  (let* ((d (%desktop))
         (w (ui:find-window d "one"))
         (entered (sb-thread:make-semaphore))
         (cleaned-up nil))
    (%recording-changes (calls)
      (let ((job (jobs:start-job (lambda ()
                                   (unwind-protect
                                        (progn (sb-thread:signal-semaphore entered) (loop))
                                     (setf cleaned-up t)))
                                 :window w)))
        (is (sb-thread:wait-on-semaphore entered :timeout 10) "the function is running")
        (is (jobs:job-thread-alive-p job))
        (is (eq :running (jobs:job-status job)))
        (is (eq t (jobs:cancel-job job)))
        (is (eq :cancelled (jobs:job-status job)))
        (is (jobs:wait-job job :timeout 10) "the thread ended")
        (is (not (jobs:job-thread-alive-p job)))
        (is (eq :cancelled (jobs:job-status job)) "and the status is still cancelled")
        (is-true cleaned-up "the function's cleanup form ran")
        (is (null (jobs:job-result job)))
        (is (integerp (jobs:job-ended job)))
        (is (member "one" calls :test #'string=) "the window was told")
        (is (null (jobs:cancel-job job)) "cancelling a job that has ended does nothing")))))

(test a-job-past-its-time-limit-is-timed-out
  (let ((job (jobs:start-job (lambda () (loop)) :time-limit 0.3)))
    (is (jobs:wait-job job :timeout 10))
    (is (eq :timed-out (jobs:job-status job)))
    (is (not (jobs:job-thread-alive-p job)))
    (is (<= 0.3 (jobs:job-seconds job) 5)))
  (let ((job (jobs:start-job (lambda () :quick) :time-limit 30)))
    (is (jobs:wait-job job :timeout 10) "a job inside its limit is not kept waiting for it")
    (is (eq :done (jobs:job-status job)))))

(test on-stop-is-called-before-the-interrupt-and-the-grace-period-is-waited
  (let* ((stop (sb-thread:make-semaphore))
         (entered (sb-thread:make-semaphore))
         (stopped-by nil)
         (job (jobs:start-job (lambda ()
                                (sb-thread:signal-semaphore entered)
                                (sb-thread:wait-on-semaphore stop)
                                (setf stopped-by :on-stop)
                                :returned)
                              :on-stop (lambda () (sb-thread:signal-semaphore stop))
                              :stop-grace 5)))
    (is (sb-thread:wait-on-semaphore entered :timeout 10) "the function is running")
    (is (eq t (jobs:cancel-job job)))
    (is (jobs:wait-job job :timeout 10))
    (is (eq :on-stop stopped-by) "the function left because ON-STOP let it, not by the interrupt")
    (is (eq :cancelled (jobs:job-status job)))
    (is (null (jobs:job-result job)) "what it returned after the cancel is not kept")))

(test a-job-inside-without-interrupts-is-cancelled-on-record-before-its-thread-ends
  (let* ((entered (sb-thread:make-semaphore))
         (job (jobs:start-job
               (lambda ()
                 (sb-sys:without-interrupts
                   (sb-thread:signal-semaphore entered)
                   (let ((until (+ (get-internal-real-time)
                                   (* 1 internal-time-units-per-second))))
                     (loop while (< (get-internal-real-time) until))))
                 (loop)))))
    (is (sb-thread:wait-on-semaphore entered :timeout 10))
    (is (eq t (jobs:cancel-job job)))
    (is (eq :cancelled (jobs:job-status job)))
    (is (jobs:job-thread-alive-p job)
        "the interrupt waits for the function to leave WITHOUT-INTERRUPTS")
    (is (eq t (getf (jobs:inspect-job job) :thread-alive)))
    (is (jobs:wait-job job :timeout 10) "it is taken once the function leaves that form")
    (is (not (jobs:job-thread-alive-p job)))))

(test inspect-job-returns-plain-data
  (let* ((d (%desktop))
         (w (ui:find-window d "one"))
         (job (jobs:start-job (lambda () (princ "some output") (make-hash-table))
                              :window w :name "inspected" :time-limit 30)))
    (is (jobs:wait-job job :timeout 10))
    (let ((record (jobs:inspect-job job)))
      (is (equal (list :id (jobs:job-id job) :name "inspected" :window "one" :status :done
                       :output "some output" :output-length 11 :output-truncated nil)
                 (subseq record 0 14)))
      (is (stringp (getf record :result)) "the object itself is not in the record")
      (is (search "HASH-TABLE" (getf record :result)))
      (is (null (getf record :error)))
      (is (integerp (getf record :started)))
      (is (integerp (getf record :ended)))
      (is (floatp (getf record :seconds)))
      (is (= 30 (getf record :time-limit)))
      (is (null (getf record :thread-alive))))))

(test a-job-keeps-at-most-the-output-limit
  (let ((job (jobs:start-job (lambda () (write-string "0123456789abcdef") (write-char #\g))
                             :bindings (list (cons 'jobs:*output-limit* 10)))))
    (is (jobs:wait-job job :timeout 10))
    (is (string= "0123456789" (jobs:job-output job)))
    (is (eq t (getf (jobs:inspect-job job) :output-truncated)))))

(test jobs-are-listed-by-window-and-by-desktop
  (let* ((d (%desktop))
         (other (%desktop))
         (one (jobs:start-job (lambda () 1) :window (ui:find-window d "one")))
         (two (jobs:start-job (lambda () 2) :window (ui:find-window d "two")))
         (elsewhere (jobs:start-job (lambda () 3) :window (ui:find-window other "one"))))
    (dolist (job (list one two elsewhere)) (is (jobs:wait-job job :timeout 10)))
    (is (equal (list two one) (jobs:desktop-jobs d)) "newest first, this desktop's only")
    (is (equal (list one) (jobs:window-jobs (ui:find-window d "one"))))
    (is (equal (list elsewhere) (jobs:desktop-jobs other)))
    (is (member one (jobs:all-jobs)))))

(test the-image-forgets-the-oldest-ended-jobs
  (let* ((jobs:*job-history* 3)
         (d (%desktop))
         (w (ui:find-window d "one"))
         (made (loop repeat 6
                     collect (let ((job (jobs:start-job (lambda () 1) :window w)))
                               (jobs:wait-job job :timeout 10)
                               job))))
    (is (<= (length (jobs:window-jobs w)) 4)
        "three ended jobs are kept, and the one registered last")
    (is (eq (sixth made) (first (jobs:window-jobs w))))
    (is (null (jobs:find-job (jobs:job-id (first made)))))))
