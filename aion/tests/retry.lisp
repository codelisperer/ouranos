;;;; retry.lisp --- aion/retry: the schedule, the runner's restarts, Retry-After, the deadline (#79).
;;;;
;;;; No test sleeps or draws a random number: *SLEEP-FUNCTION* records the waits instead of
;;;; waiting, and *RANDOM-FUNCTION* returns a fixed value.

(cl:defpackage #:aion/retry/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:r #:aion/retry))
  (:export #:run-tests))

(in-package #:aion/retry/tests)

(def-suite retry :description "Retry policy as data, and the runner.")
(in-suite retry)

(defun run-tests ()
  (let ((results (run 'retry)))
    (explain! results)
    (unless (results-status results) (error "aion/retry tests failed"))))

(define-condition flaky (error)
  ((transience :initarg :transience :initform :transient :reader flaky-transience)
   (asked :initarg :asked :initform nil :reader flaky-asked))
  (:report "a flaky failure"))

(defmethod r:transience ((c flaky)) (flaky-transience c))
(defmethod r:retry-after ((c flaky)) (flaky-asked c))

(define-condition fatal (error) () (:report "a fatal failure"))

(defmacro with-recorded-waits ((waits-var &key (random 0.5)) &body body)
  "Run BODY with the runner's waits pushed onto WAITS-VAR instead of slept, and the jitter's
random value fixed at RANDOM."
  `(let ((,waits-var '()))
     (let ((r::*sleep-function* (lambda (s) (push s ,waits-var)))
           (r::*random-function* (lambda () ,random)))
       ,@body)))

(defun failing (n &rest initargs)
  "A thunk that signals a FLAKY made with INITARGS on each of its first N calls, then returns
the values :OK and the number of calls. The second value is how many calls there were."
  (let ((calls 0))
    (values (lambda ()
              (incf calls)
              (if (<= calls n)
                  (apply #'error 'flaky initargs)
                  (values :ok calls)))
            (lambda () calls))))

;;; --- the policy and its schedule --------------------------------------------------------

(test retry-delay-doubles-up-to-max-delay-without-jitter
  (let ((p (r:make-retry-policy :base-delay 0.5 :multiplier 2 :max-delay 3 :jitter :none
                                :max-attempts 10)))
    (is (equal '(0.5 1.0 2.0 3 3 3)
               (loop for attempt from 2 to 7 collect (r:retry-delay p attempt 0.9)))
        "attempt 2 waits BASE-DELAY, each later one twice the last, capped at MAX-DELAY")
    (is (= 3 (r:retry-delay p 1000 0.9)) "a very late attempt is still capped, and fast")))

(test retry-delay-applies-full-and-equal-jitter-to-the-computed-delay
  (let ((full (r:make-retry-policy :base-delay 4 :jitter :full))
        (equal (r:make-retry-policy :base-delay 4 :jitter :equal)))
    (is (= 1 (r:retry-delay full 2 0.25)) "full: the delay times the random value")
    (is (= 0 (r:retry-delay full 2 0)))
    (is (= 2.5 (r:retry-delay equal 2 0.25)) "equal: half, plus half times the random value")
    (is (= 2 (r:retry-delay equal 2 0)))))

(test a-policy-is-checked-when-it-is-made
  (signals type-error (r:make-retry-policy :max-attempts 0))
  (signals type-error (r:make-retry-policy :base-delay -1))
  (signals type-error (r:make-retry-policy :multiplier 0.5))
  (signals type-error (r:make-retry-policy :jitter :some))
  (signals type-error (r:make-retry-policy :deadline 0))
  (signals type-error (r:make-retry-policy :name :llm))
  (is (r:retry-policy-p (r:make-retry-policy)) "the defaults make a policy"))

;;; --- the runner -------------------------------------------------------------------------

(test a-transient-failure-is-retried-and-the-body-s-values-come-back
  (with-recorded-waits (waits)
    (multiple-value-bind (thunk calls) (failing 2)
      (let ((p (r:make-retry-policy :max-attempts 4 :base-delay 1 :jitter :none)))
        (is (equal '(:ok 3) (multiple-value-list (r:call-with-retry p thunk)))
            "every value of the successful attempt is returned")
        (is (= 3 (funcall calls)))
        (is (equal '(1 2) (reverse waits)) "it waited before each retry, doubling")))))

(test a-failure-that-is-not-retryable-propagates-at-once
  (with-recorded-waits (waits)
    (let ((calls 0))
      (signals fatal
        (r:with-retry ((r:make-retry-policy :max-attempts 5))
          (incf calls)
          (error 'fatal)))
      (is (= 1 calls))
      (is (null waits)))
    (multiple-value-bind (thunk calls) (failing 5 :transience :unknown)
      (signals flaky (r:call-with-retry (r:make-retry-policy :max-attempts 5) thunk))
      (is (= 1 (funcall calls)) ":UNKNOWN is not retried by the default, TRANSIENT-P"))
    (multiple-value-bind (thunk calls) (failing 2 :transience :unknown)
      (is (eq :ok (r:call-with-retry (r:make-retry-policy :max-attempts 5
                                                          :retryable #'r:transient-or-unknown-p)
                                     thunk))
          "and is retried by TRANSIENT-OR-UNKNOWN-P")
      (is (= 3 (funcall calls))))))

(test retryable-may-be-a-list-of-condition-types
  (with-recorded-waits (waits)
    (let ((calls 0))
      (is (eq :ok (r:with-retry ((r:make-retry-policy :max-attempts 3 :retryable '(fatal)))
                    (if (< (incf calls) 2) (error 'fatal) :ok))))
      (is (= 2 calls)))))

(test when-the-attempts-are-used-the-original-condition-propagates-with-retry-still-available
  (with-recorded-waits (waits)
    (multiple-value-bind (thunk calls) (failing 3)
      (let* ((p (r:make-retry-policy :max-attempts 3 :jitter :none))
             (seen nil)
             (calls-when-seen nil)
             (result (handler-bind ((flaky (lambda (c)
                                             (setf seen c calls-when-seen (funcall calls))
                                             ;; By hand, as a handler or the debugger would.
                                             (invoke-restart 'r:retry))))
                       (r:call-with-retry p thunk))))
        (is (typep seen 'flaky) "the caller's handler saw the original condition, not a wrapper")
        (is (eql 3 calls-when-seen) "only after the policy's three attempts had all failed")
        (is (= 4 (funcall calls)))
        (is (eq :ok result) "and the RETRY restart ran the body a fourth time")
        (is (= 2 (length waits)) "the policy waited twice; the retry by hand did not wait")))))

(test a-handler-can-give-up-or-retry-now-on-retry-scheduled
  (with-recorded-waits (waits)
    (multiple-value-bind (thunk calls) (failing 3)
      (signals flaky
        (handler-bind ((r:retry-scheduled (lambda (c) (declare (ignore c)) (invoke-restart 'r:give-up))))
          (r:call-with-retry (r:make-retry-policy :max-attempts 5) thunk)))
      (is (= 1 (funcall calls)) "GIVE-UP: no retry")
      (is (null waits)))
    (multiple-value-bind (thunk calls) (failing 2)
      (let ((scheduled '()))
        (is (eq :ok (handler-bind ((r:retry-scheduled
                                     (lambda (c)
                                       (push (list (r:retry-scheduled-attempt c)
                                                   (type-of (r:retry-scheduled-condition c)))
                                             scheduled)
                                       (invoke-restart 'r:retry-now))))
                      (r:call-with-retry (r:make-retry-policy :max-attempts 5) thunk))))
        (is (= 3 (funcall calls)))
        (is (equal '((2 flaky) (3 flaky)) (reverse scheduled))
            "RETRY-SCHEDULED names the attempt about to start and the failure")
        (is (null waits) "RETRY-NOW: no wait")))))

(test a-nested-with-retry-does-not-take-the-outer-ones-restart
  (with-recorded-waits (waits)
    (let ((outer 0) (inner 0))
      (signals flaky
        (r:with-retry ((r:make-retry-policy :max-attempts 2 :jitter :none))
          (incf outer)
          (r:with-retry ((r:make-retry-policy :max-attempts 3 :jitter :none))
            (incf inner)
            (error 'flaky))))
      (is (= 2 outer) "the outer body ran its two attempts")
      (is (= 6 inner) "and each ran the inner body three times"))))

;;; --- Retry-After and the deadline -------------------------------------------------------

(test retry-after-is-a-floor-on-the-wait
  (with-recorded-waits (waits)
    (multiple-value-bind (thunk calls) (failing 1 :asked 7)
      (is (eq :ok (r:call-with-retry (r:make-retry-policy :base-delay 1 :jitter :none :max-delay 30)
                                     thunk)))
      (is (= 2 (funcall calls)))
      (is (equal '(7) waits) "the server's 7 s, not the computed 1 s"))
    (setf waits '())
    (multiple-value-bind (thunk calls) (failing 1 :asked 1)
      (r:call-with-retry (r:make-retry-policy :base-delay 4 :jitter :none) thunk)
      (is (= 2 (funcall calls)))
      (is (equal '(4) waits) "the computed delay when it is longer than the server's"))))

(test a-retry-after-longer-than-max-delay-stops-the-retrying
  (with-recorded-waits (waits)
    (multiple-value-bind (thunk calls) (failing 1 :asked 60)
      (signals flaky (r:call-with-retry (r:make-retry-policy :max-delay 30 :max-attempts 5) thunk))
      (is (= 1 (funcall calls)) "no second attempt")
      (is (null waits) "and no wait"))))

(test no-retry-starts-past-the-deadline
  (with-recorded-waits (waits)
    (multiple-value-bind (thunk calls) (failing 1)
      (signals flaky (r:call-with-retry (r:make-retry-policy :base-delay 5 :jitter :none
                                                             :deadline 2 :max-attempts 5)
                                        thunk))
      (is (= 1 (funcall calls)) "a 5 s wait would end past a 2 s deadline")
      (is (null waits)))
    (multiple-value-bind (thunk calls) (failing 1)
      (is (eq :ok (r:call-with-retry (r:make-retry-policy :base-delay 1 :jitter :none
                                                          :deadline 2 :max-attempts 5)
                                     thunk)))
      (is (= 2 (funcall calls)) "control: a 1 s wait fits"))))

(test parse-retry-after-reads-seconds-and-http-dates
  (let ((now (encode-universal-time 0 49 8 6 11 1994 0)))
    (is (eql 120 (r:parse-retry-after "120")))
    (is (eql 0 (r:parse-retry-after "0")))
    (is (eql 37 (r:parse-retry-after "Sun, 06 Nov 1994 08:49:37 GMT" now)))
    (is (eql 0 (r:parse-retry-after "Sun, 06 Nov 1994 08:48:00 GMT" now)) "a date in the past is 0")
    (is (eql 120 (r:parse-retry-after (format nil "~C120 " #\Tab))) "tabs and spaces around it")
    (dolist (bad '(nil "" "-5" "1.5" "soon" "Sunday, 06-Nov-94 08:49:37 GMT"
                   "Sun Nov  6 08:49:37 1994" "Sun, 06 Nov 1994 25:49:37 GMT"
                   "Sun, 06 Nov 94 08:49:37 GMT"))
      (is (null (r:parse-retry-after bad now)) "~S is not a Retry-After" bad))))

;;; --- a thread that must not block -------------------------------------------------------

(test with-retry-refuses-to-start-on-a-thread-that-must-not-block
  (let ((aion/dynamic:*blocking-forbidden* "an aion/uv loop")
        (calls 0))
    (let ((c (handler-case (progn (r:with-retry ((r:make-retry-policy :max-attempts 3))
                                    (incf calls))
                                  nil)
               (r:retry-would-block (e) e))))
      (is (typep c 'r:retry-would-block))
      (is (= 0 calls) "before the first attempt")
      (is (search "an aion/uv loop" (princ-to-string c))))
    (is (eql 1 (r:with-retry ((r:make-retry-policy :max-attempts 1)) (incf calls)))
        "a policy with one attempt never waits, so it may run there")))

;;; --- review of #974 ---------------------------------------------------------------------

(test the-jitter-is-seeded-in-each-process-not-in-the-image
  ;; A state made when the system loads would be saved by SAVE-LISP-AND-DIE, and every process
  ;; started from the image would draw the same jitter.
  (is (member 'r::%forget-random-state sb-ext:*init-hooks*)
      "an image that starts drops the state it was saved with")
  (r::%forget-random-state)
  (is (null r::*random-state-for-jitter*) "control: no state until the first draw")
  (let ((x (r::%random-unit)))
    (is (and (realp x) (<= 0 x) (< x 1)))
    (is (random-state-p r::*random-state-for-jitter*) "the first draw seeds it")))

(defmacro with-captured-log ((stream) &body body)
  "Run BODY with the log at :INFO going to STREAM, then put back the appenders, level and layout
that were there before. As hermes/tests/blob.lisp does."
  (let ((appenders (gensym "APPENDERS")) (level (gensym "LEVEL")) (layout (gensym "LAYOUT")))
    `(let ((,appenders (copy-list (log4cl:logger-appenders log4cl:*root-logger*)))
           (,level (log4cl:logger-log-level log4cl:*root-logger*))
           (,layout aion/log:*layout*))
       (unwind-protect
            (progn (aion/log:setup :env :dev :level :info :stream ,stream)
                   ,@body)
         (log4cl:remove-all-appenders log4cl:*root-logger*)
         (dolist (appender ,appenders)
           (log4cl:add-appender log4cl:*root-logger* appender))
         (log4cl:set-log-level log4cl:*root-logger* ,level)
         (setf aion/log:*layout* ,layout)))))

(defun %log-of (policy thunk)
  "The log lines CALL-WITH-RETRY writes for POLICY and THUNK, whose failure is ignored."
  (let ((out (make-string-output-stream)))
    (with-recorded-waits (waits)
      (declare (ignorable waits))
      (with-captured-log (out)
        (ignore-errors (r:call-with-retry policy thunk))))
    (get-output-stream-string out)))

(test each-retry-and-each-retry-not-taken-is-logged-at-info
  (let ((log (%log-of (r:make-retry-policy :name "billing" :max-attempts 2 :jitter :none
                                           :base-delay 1)
                      (failing 5))))
    (is (search "retrying" log))
    (is (search "policy=billing" log))
    (is (search "wait-ms=1000" log))
    (is (search "reason=attempts" log) "running out of attempts says so: ~A" log))
  (let ((log (%log-of (r:make-retry-policy :max-delay 30) (failing 1 :asked 60))))
    (is (search "retry-after longer than max-delay" log))
    (is (search "retry-after-s=60" log) "with the server's value: ~A" log)))

(test a-retry-after-that-would-end-past-the-deadline-stops-the-retrying
  (with-recorded-waits (waits)
    (multiple-value-bind (thunk calls) (failing 1 :asked 5)
      (signals flaky (r:call-with-retry (r:make-retry-policy :base-delay 0.1 :jitter :none
                                                             :max-delay 30 :deadline 2)
                                        thunk))
      (is (= 1 (funcall calls)) "the server's 5 s would end past the 2 s deadline")
      (is (null waits))))
  (let ((log (%log-of (r:make-retry-policy :base-delay 0.1 :max-delay 30 :deadline 2)
                      (failing 1 :asked 5))))
    (is (search "reason=deadline" log))
    (is (search "retry-after-s=5" log) "the log line carries the server's value: ~A" log)))
