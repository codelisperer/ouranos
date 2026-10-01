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

(defun run-many (pool n)
  "Submit N counting jobs to POOL as fast as it accepts them, retrying each refusal, and
return how many ran. Gives up after ten seconds in all, so a pool that stops accepting fails
the test instead of hanging it."
  (let ((ran (list 0))
        (deadline (+ (get-internal-real-time) (* 10 internal-time-units-per-second))))
    (dotimes (i n)
      (loop until (or (pool:try-submit pool (lambda () (sb-ext:atomic-incf (car ran))))
                      (> (get-internal-real-time) deadline))))
    (wait-until (lambda () (= n (car ran))) :timeout 10)
    (car ran)))

(test every-accepted-job-runs-when-submissions-race-the-workers
  ;; The wake-up path under a steady stream of submissions (#430): a job must never sit in the
  ;; queue while every worker waits. A queue limit of 0 keeps the pool at capacity, so jobs are
  ;; accepted exactly as workers free, from both the waiting and the running side; a limit of
  ;; 64 lets the queue fill and drain.
  (with-pool (p :size 4 :queue-limit 0)
    (is (= 20000 (run-many p 20000))))
  (with-pool (p :size 4 :queue-limit 64)
    (is (= 20000 (run-many p 20000)))))

(test idle-workers-wake-for-every-burst
  ;; A job submitted while every worker is asleep must wake one (#430). Each round waits until
  ;; no job is queued or running and gives the workers a moment to reach their wait, then
  ;; submits a burst of four and waits for all four. The test above cannot see a lost wake-up:
  ;; there, one worker that never sleeps keeps draining the queue.
  (with-pool (p :size 4 :queue-limit 8)
    (let ((ran (list 0)) (stalled nil))
      (dotimes (round 200)
        (wait-until (lambda () (and (zerop (pool:pool-busy p)) (zerop (pool:pool-queued p)))))
        (sleep 0.001)
        (dotimes (i 4)
          (unless (pool:try-submit p (lambda () (sb-ext:atomic-incf (car ran))))
            (setf stalled round)))
        (unless (wait-until (lambda () (= (car ran) (* 4 (1+ round)))) :timeout 2)
          (setf stalled round)
          (return)))
      (is (null stalled) "round ~A: a job was refused, or not picked up by an idle worker"
          stalled)
      (is (= 800 (car ran))))))

;;; --- every job, exactly once, with no lock on the submit path (#466) ------------------

(defun %submit-range (pool runs from below deadline)
  "Submit one job for each index from FROM below BELOW, each counting its run in RUNS,
retrying while POOL refuses. Return :SUBMITTED, or :GAVE-UP once DEADLINE, an internal real
time, has passed, so a submitter facing a stalled or stopped pool does not retry forever."
  (loop for i from from below below
        do (let ((i i))
             (loop until (pool:try-submit pool (lambda () (sb-ext:atomic-incf (aref runs i))))
                   do (when (> (get-internal-real-time) deadline)
                        (return-from %submit-range :gave-up))
                      (sb-thread:thread-yield))))
  :submitted)

(test every-job-runs-exactly-once-when-four-threads-submit-at-once
  "Four threads submit 20,000 jobs each, at once, retrying when refused. Each job counts its
own run in its own slot, so a job lost shows as a 0 and a job run twice as a 2. After the pool
drains, every slot is exactly 1."
  (let* ((per-thread 20000) (threads 4) (n (* per-thread threads))
         (runs (make-array n :element-type 'sb-ext:word :initial-element 0))
         (p (pool:make-pool :size 8 :queue-limit 64))
         ;; One deadline for every submitter's retries: past it a submitter gives up instead
         ;; of retrying forever against a pool that has stalled or stopped.
         (deadline (+ (get-internal-real-time) (* 60 internal-time-units-per-second))))
    (unwind-protect
         (let ((done (aion/test-threads:join-all
                      (loop for k below threads
                            collect (let ((k k))
                                      (sb-thread:make-thread
                                       (lambda ()
                                         (%submit-range p runs (* k per-thread)
                                                        (* (1+ k) per-thread) deadline))
                                       :name "pool stress submitter")))
                      :timeout 90)))
           (is (every (lambda (d) (eq d :submitted)) done) "submitters: ~S" done))
      (pool:stop-pool p))
    (is (= 0 (count 0 runs)) "~D jobs never ran" (count 0 runs))
    (is (= 0 (count-if (lambda (x) (> x 1)) runs)) "~D jobs ran more than once"
        (count-if (lambda (x) (> x 1)) runs))
    (is (= n (reduce #'+ runs)))))

(test a-job-accepted-while-the-pool-stops-still-runs
  "Submitters race STOP-POOL. Every job TRY-SUBMIT accepted runs exactly once, and every job it
refused never runs: shutdown drains what was accepted, even in the moment STOPPING is set."
  (dotimes (round 20)
    (let* ((per-thread 2000) (threads 4) (n (* per-thread threads))
           (runs (make-array n :element-type 'sb-ext:word :initial-element 0))
           (accepted (make-array n :element-type 'bit :initial-element 0))
           (p (pool:make-pool :size 4 :queue-limit 32))
           (submitters
             (loop for k below threads
                   collect (let ((k k))
                             (sb-thread:make-thread
                              (lambda ()
                                (loop for i from (* k per-thread) below (* (1+ k) per-thread)
                                      do (let ((i i))
                                           (when (pool:try-submit
                                                  p (lambda () (sb-ext:atomic-incf (aref runs i))))
                                             (setf (aref accepted i) 1))))
                                :submitted)
                              :name "pool stop-race submitter")))))
      (sleep 0.0005)
      (let ((stopper (sb-thread:make-thread (lambda () (pool:stop-pool p) :stopped)
                                            :name "pool stop-race stopper")))
        (let ((done (aion/test-threads:join-all (cons stopper submitters) :timeout 30)))
          (is (every (lambda (d) (member d '(:stopped :submitted))) done)
              "round ~D: ~S" round done)))
      (let ((lost (loop for i below n count (and (= 1 (aref accepted i)) (/= 1 (aref runs i)))))
            (ghost (loop for i below n count (and (= 0 (aref accepted i)) (/= 0 (aref runs i))))))
        (is (= 0 lost) "round ~D: ~D accepted jobs did not run exactly once" round lost)
        (is (= 0 ghost) "round ~D: ~D refused jobs ran" round ghost)))))

(test a-job-submitted-as-a-worker-goes-idle-is-not-missed
  "A worker finds the queue empty; before it counts itself idle, a job is submitted. The
submitter sees no idle worker and does not signal, so the job is found only by the worker's
second look at the queue. The hook holds the worker at exactly that point."
  (let* ((at-the-point (sb-thread:make-semaphore))
         (go-on (sb-thread:make-semaphore))
         (armed (list t))
         (ran (sb-thread:make-semaphore)))
    (setf aion/pool::*%after-empty-look*
          (lambda ()
            (when (sb-ext:compare-and-swap (car armed) t nil)
              (sb-thread:signal-semaphore at-the-point)
              (sb-thread:wait-on-semaphore go-on :timeout 10))))
    (unwind-protect
         (with-pool (p :size 1 :queue-limit 4)
           (is (sb-thread:wait-on-semaphore at-the-point :timeout 10)
               "the worker never reached the point between its two looks")
           (is (pool:try-submit p (lambda () (sb-thread:signal-semaphore ran))))
           (sb-thread:signal-semaphore go-on)
           (is (sb-thread:wait-on-semaphore ran :timeout 5)
               "the job submitted between the worker's two looks never ran"))
      (setf aion/pool::*%after-empty-look* nil))))

(test a-place-reserved-when-the-pool-stops-is-not-lost
  "A submitter has reserved a place but not yet enqueued its job when STOP-POOL runs. The
workers must not exit while a place is reserved, so the job runs and STOP-POOL returns after
it. The hook holds the submitter at exactly that point."
  (let* ((at-the-point (sb-thread:make-semaphore))
         (go-on (sb-thread:make-semaphore))
         (armed (list t))
         (ran (list 0))
         (p (pool:make-pool :size 2 :queue-limit 4)))
    (setf aion/pool::*%after-reserve*
          (lambda ()
            (when (sb-ext:compare-and-swap (car armed) t nil)
              (sb-thread:signal-semaphore at-the-point)
              (sb-thread:wait-on-semaphore go-on :timeout 10))))
    (unwind-protect
         (let ((submitter (sb-thread:make-thread
                           (lambda ()
                             (pool:try-submit p (lambda () (sb-ext:atomic-incf (car ran)))))
                           :name "pool reserve submitter")))
           (is (sb-thread:wait-on-semaphore at-the-point :timeout 10))
           (let ((stopper (sb-thread:make-thread (lambda () (pool:stop-pool p) :stopped)
                                                 :name "pool reserve stopper")))
             ;; Give a broken pool's workers time to see STOPPING and an empty queue, and exit.
             (sleep 0.2)
             (sb-thread:signal-semaphore go-on)
             (is (equal '(t :stopped)
                        (aion/test-threads:join-all (list submitter stopper) :timeout 10)))
             (is (= 1 (car ran)) "the job whose place was reserved ran ~D times" (car ran))))
      (setf aion/pool::*%after-reserve* nil)
      (pool:stop-pool p))))
