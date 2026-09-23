;;;; pool.lisp --- aion/pool: FIFO order, the bound, the refusal, and shutdown.

(cl:defpackage #:aion/pool/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:pool #:aion/pool))
  (:export #:run-tests))

(in-package #:aion/pool/tests)

(def-suite pool :description "A bounded worker pool.")
(in-suite pool)

(defun run-tests ()
  (let ((results (run 'pool)))
    (explain! results)
    (unless (results-status results) (error "aion/pool tests failed"))))

(defmacro with-pool ((var &rest args) &body body)
  `(let ((,var (pool:make-pool ,@args)))
     (unwind-protect (progn ,@body) (pool:stop-pool ,var))))

(defun wait-until (test &key (timeout 5))
  "Poll TEST until true or TIMEOUT seconds pass; return whether it became true.
Polling rather than a fixed sleep: a fixed sleep is either slower than it needs to be or
flaky on a loaded machine, and usually both."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      (when (funcall test) (return t))
      (when (> (get-internal-real-time) deadline) (return nil))
      (sleep 0.005))))

(test work-actually-runs-on-another-thread
  (with-pool (p :size 2)
    (let ((here sb-thread:*current-thread*)
          (there (list nil)))
      (is-true (pool:try-submit p (lambda () (setf (car there) sb-thread:*current-thread*))))
      (is-true (wait-until (lambda () (car there))))
      (is (not (eq here (car there))) "a pool that ran jobs inline would be no pool"))))

(test jobs-run-in-submission-order-on-one-worker
  (with-pool (p :size 1)
    (let ((seen (list nil)))
      (dotimes (i 20) (let ((i i)) (pool:try-submit p (lambda () (push i (car seen))))))
      (is-true (wait-until (lambda () (= 20 (length (car seen))))))
      (is (equal (loop for i below 20 collect i) (reverse (car seen)))
          "a FIFO, not a stack -- the enqueue is at the tail"))))

(test a-full-queue-refuses-rather-than-growing
  ;; The decision, as a test. Not "it queues a lot" -- it has a limit and says no.
  (let ((gate (sb-thread:make-semaphore)))
    (with-pool (p :size 1 :queue-limit 3)
      (unwind-protect
           (progn
             ;; occupy the single worker so nothing drains
             (is-true (pool:try-submit p (lambda () (sb-thread:wait-on-semaphore gate))))
             (is-true (wait-until (lambda () (= 1 (pool:pool-busy p)))))
             (is-true (pool:try-submit p (lambda () nil)))
             (is-true (pool:try-submit p (lambda () nil)))
             (is-true (pool:try-submit p (lambda () nil)))
             (is (= 3 (pool:pool-queued p)))
             (is (null (pool:try-submit p (lambda () nil)))
                 "the fourth is REFUSED -- immediately, not queued and not waited for"))
        (sb-thread:signal-semaphore gate 10)))))

(test refusal-does-not-block-the-submitter
  ;; The submitter may be an event loop's own thread, where blocking stalls every
  ;; connection the loop owns -- the exact defect a pool exists to fix.
  (let ((gate (sb-thread:make-semaphore)))
    (with-pool (p :size 1 :queue-limit 0)
      (unwind-protect
           (progn
             (is-true (pool:try-submit p (lambda () (sb-thread:wait-on-semaphore gate))))
             (is-true (wait-until (lambda () (= 1 (pool:pool-busy p)))))
             (let ((start (get-internal-real-time)))
               (is (null (pool:try-submit p (lambda () nil))))
               (is (< (- (get-internal-real-time) start)
                      (* 1 internal-time-units-per-second))
                   "returned at once rather than waiting for capacity")))
        (sb-thread:signal-semaphore gate 10)))))

(test a-worker-survives-a-job-that-signals
  ;; A pool that lost a thread per failing job would degrade to nothing during exactly the
  ;; incident that was already going badly.
  (with-pool (p :size 1)
    (let ((after (list nil)))
      (pool:try-submit p (lambda () (error "this job is broken")))
      (pool:try-submit p (lambda () (setf (car after) :ran)))
      (is-true (wait-until (lambda () (car after)))
               "the worker took the next job after one signalled"))))

(test stopping-drains-what-was-accepted
  ;; Accepting work and then dropping it on shutdown would make graceful shutdown a lie.
  ;; ATOMIC-INCF, not INCF: two workers incrementing one place is a lost update, and a
  ;; test that raced would accuse the pool of dropping work it had actually run.
  (let ((done (cons 0 nil))
        (p (pool:make-pool :size 2 :queue-limit 100)))
    (dotimes (i 30) (pool:try-submit p (lambda () (sb-ext:atomic-incf (car done)))))
    (pool:stop-pool p)
    (is (= 30 (car done)) "every accepted job ran before stop returned")))

(test a-stopped-pool-accepts-nothing
  (let ((p (pool:make-pool :size 1)))
    (pool:stop-pool p)
    (is (null (pool:try-submit p (lambda () nil))))))

(test stopping-twice-is-harmless
  (let ((p (pool:make-pool :size 1)))
    (pool:stop-pool p)
    (finishes (pool:stop-pool p))))

(test the-pool-reports-its-shape
  (with-pool (p :size 3 :queue-limit 7)
    (is (= 3 (pool:pool-workers p)))
    (is (= 0 (pool:pool-queued p)))))

(test a-size-of-zero-is-refused
  (signals error (pool:make-pool :size 0)))

;;; --- a job that dies must be reported, not merely survived ------------------
;;;
;;; A-WORKER-SURVIVES-A-JOB-THAT-SIGNALS asserts the pool is still there. Nothing asserted
;;; that anyone FINDS OUT, which is the half that matters at 3am. The old handler discarded
;;; the condition on the reasoning that a failing job was "the caller's to report" -- but
;;; TRY-SUBMIT returned T and is long gone by the time the thunk runs, so that sentence
;;; described nobody. A swallowed error is worse than the unattributable latency this file's
;;; header rejects an unbounded queue for: it is a MISSING symptom rather than a misleading
;;; one.

(test a-job-that-signals-reaches-on-error
  (let ((seen (list nil))
        (done (sb-thread:make-semaphore)))
    (let ((pool (pool:make-pool :size 1
                                :on-error (lambda (c p)
                                            (setf (car seen) (list (type-of c)
                                                                   (pool:pool-name p)))
                                            (sb-thread:signal-semaphore done)))))
      (unwind-protect
           (progn
             (is-true (pool:try-submit pool (lambda () (error 'simple-error
                                                              :format-control "boom"))))
             (is-true (sb-thread:wait-on-semaphore done :timeout 5) "ON-ERROR must be called")
             (is (equal '(simple-error "aion-pool") (car seen))
                 "with the condition and the pool that lost the job"))
        (pool:stop-pool pool)))))

(test a-failing-on-error-cannot-kill-the-worker
  "ON-ERROR is caller-supplied code running on a worker thread. A reporter that signals would
cost the pool a thread every time it tried to say it had lost a job -- silence about the
silence, and the pool degrading fastest during the incident that was already going badly."
  (let ((ran (sb-thread:make-semaphore))
        (pool (pool:make-pool :size 1
                              :on-error (lambda (c p) (declare (ignore c p))
                                          (error "the reporter is broken too")))))
    (unwind-protect
         (progn
           (pool:try-submit pool (lambda () (error "boom")))
           (pool:try-submit pool (lambda () (sb-thread:signal-semaphore ran)))
           (is-true (sb-thread:wait-on-semaphore ran :timeout 5)
                    "the worker took the NEXT job, so it survived its own reporter"))
      (pool:stop-pool pool))))

(test a-pool-nobody-configured-still-reports-and-still-works
  "The DEFAULT is the whole point -- the old behaviour was a default that said nothing, and
every pool in the tree is built without an :ON-ERROR. Two assertions, because either alone
is satisfied by the bug: that a reporter exists at all, and that the default path actually
RUNS without taking the worker down with it."
  (let ((ran (sb-thread:make-semaphore))
        (pool (pool:make-pool :size 1)))
    (unwind-protect
         (progn
           (is-true (functionp (aion/pool::pool-on-error pool))
                    "a reporter is installed without anyone asking for one")
           (pool:try-submit pool (lambda () (error "boom")))
           (pool:try-submit pool (lambda () (sb-thread:signal-semaphore ran)))
           (is-true (sb-thread:wait-on-semaphore ran :timeout 5)
                    "the default reporter ran and the worker took the next job"))
      (pool:stop-pool pool))))
