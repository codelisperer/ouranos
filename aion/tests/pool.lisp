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
           ;; Words, not bits: four threads write it at once, and two writes to bits of one
           ;; word can lose one (#512's review measured it about once in 6,000 rounds).
           (accepted (make-array n :element-type 'sb-ext:word :initial-element 0))
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
it. The hook holds the submitter at exactly that point, and the submitter is released only
after both workers have seen STOPPING and decided whether to exit, so a broken pool's workers
have exited by then however slowly the machine runs (#520)."
  (let* ((at-the-point (sb-thread:make-semaphore))
         (go-on (sb-thread:make-semaphore))
         (armed (list t))
         (ran (list 0))
         (decided (list nil))
         (p (pool:make-pool :size 2 :queue-limit 4 :name "rsv")))
    (setf aion/pool::*%after-reserve*
          (lambda ()
            (when (sb-ext:compare-and-swap (car armed) t nil)
              (sb-thread:signal-semaphore at-the-point)
              (sb-thread:wait-on-semaphore go-on :timeout 10)))
          aion/pool::*%after-stop-check*
          (lambda (leave)
            (declare (ignore leave))
            (when (%thread-named-p-prefix "rsv-")
              (sb-ext:atomic-push sb-thread:*current-thread* (car decided)))))
    (unwind-protect
         (let ((submitter (sb-thread:make-thread
                           (lambda ()
                             (pool:try-submit p (lambda () (sb-ext:atomic-incf (car ran)))))
                           :name "pool reserve submitter")))
           (is (sb-thread:wait-on-semaphore at-the-point :timeout 10))
           (let ((stopper (sb-thread:make-thread (lambda () (pool:stop-pool p) :stopped)
                                                 :name "pool reserve stopper")))
             (is-true (wait-until (lambda () (= 2 (length (remove-duplicates (car decided)))))
                                  :timeout 10)
                      "both workers saw STOPPING and decided whether to exit")
             (sb-thread:signal-semaphore go-on)
             (is (equal '(t :stopped)
                        (aion/test-threads:join-all (list submitter stopper) :timeout 10)))
             (is (= 1 (car ran)) "the job whose place was reserved ran ~D times" (car ran))))
      (setf aion/pool::*%after-reserve* nil
            aion/pool::*%after-stop-check* nil)
      (pool:stop-pool p))))

;;; --- the three races #512's review forced (comment 5940402609) ------------------------

(defstruct (%gate (:constructor %make-gate ()))
  (arrive (sb-thread:make-semaphore)) (release (sb-thread:make-semaphore)) (armed (list t)))

(defun %hold (gate)
  "Hold the calling thread once: signal that it arrived, then wait to be released."
  (when (sb-ext:compare-and-swap (car (%gate-armed gate)) t nil)
    (sb-thread:signal-semaphore (%gate-arrive gate))
    (sb-thread:wait-on-semaphore (%gate-release gate) :timeout 20)))

(defun %arrived-p (gate) (sb-thread:wait-on-semaphore (%gate-arrive gate) :timeout 10))
(defun %release (gate) (sb-thread:signal-semaphore (%gate-release gate)))
(defun %thread-named-p (name) (equal name (sb-thread:thread-name sb-thread:*current-thread*)))
(defun %thread-named-p-prefix (prefix)
  (let ((name (sb-thread:thread-name sb-thread:*current-thread*)))
    (and name (eql 0 (search prefix name)))))
(defun %seconds () (/ (get-internal-real-time) internal-time-units-per-second))

(test a-wake-up-meant-for-a-worker-that-took-another-job-is-passed-on
  "Workers A and B. A's second look takes job X while B's finds nothing and B waits. Job Y's
submitter claims A, still marked idle in the moment before A takes itself back, and wakes it.
A runs X, so the wake-up must reach B, or Y waits behind X while B sleeps. X here waits for Y
to start, as a job that waits on another would; Y must start at once, not when X gives up."
  (let ((empty-a (%make-gate)) (empty-b (%make-gate))
        (pushed-b (%make-gate)) (found-a (%make-gate))
        (b-waiting (sb-thread:make-semaphore)) (b-armed (list t))
        (y-started (list nil)) (x-saw (list :unset)))
    (setf aion/pool::*%after-empty-look*
          (lambda () (cond ((%thread-named-p "lw-0") (%hold empty-a))
                           ((%thread-named-p "lw-1") (%hold empty-b))))
          aion/pool::*%after-push*
          (lambda (w) (declare (ignore w)) (when (%thread-named-p "lw-1") (%hold pushed-b)))
          aion/pool::*%after-second-look-found*
          (lambda (w) (declare (ignore w)) (when (%thread-named-p "lw-0") (%hold found-a)))
          ;; Signalled, not held: B goes on into its wait. Y is submitted only after this, so
          ;; B's second look has already found the queue empty and cannot take Y itself (#520).
          aion/pool::*%before-wait*
          (lambda (w)
            (declare (ignore w))
            (when (and (%thread-named-p "lw-1") (sb-ext:compare-and-swap (car b-armed) t nil))
              (sb-thread:signal-semaphore b-waiting))))
    (unwind-protect
         (with-pool (p :size 2 :queue-limit 4 :name "lw")
           (is (and (%arrived-p empty-a) (%arrived-p empty-b)) "both workers at their first look")
           (is (pool:try-submit p (lambda ()
                                    (let ((deadline (+ (%seconds) 3)))
                                      (loop until (or (car y-started) (> (%seconds) deadline))
                                            do (sleep 0.001))
                                      (setf (car x-saw)
                                            (if (car y-started) :y-started :gave-up))))))
           (%release empty-b)
           (is (%arrived-p pushed-b) "B pushed itself")
           (%release empty-a)
           (is (%arrived-p found-a) "A's second look took X")
           (%release pushed-b)
           (is-true (sb-thread:wait-on-semaphore b-waiting :timeout 10)
                    "B's second look found nothing and B is about to wait")
           (let ((submitted (%seconds)))
             (is (pool:try-submit p (lambda () (setf (car y-started) (%seconds)))))
             (%release found-a)
             (is (wait-until (lambda () (car y-started)) :timeout 2)
                 "Y did not start within 2 s: it waited behind X while B slept")
             (when (car y-started)
               (is (< (- (car y-started) submitted) 1)))
             (is (wait-until (lambda () (not (eq :unset (car x-saw)))) :timeout 5))
             (is (eq :y-started (car x-saw)))))
      (setf aion/pool::*%after-empty-look* nil
            aion/pool::*%after-push* nil
            aion/pool::*%after-second-look-found* nil
            aion/pool::*%before-wait* nil))))

(test a-refused-submitter-holds-no-place
  "Capacity 1, taken by a running job. A submitter is refused, and held just after its refusal.
The job finishes, so the place is free; another submitter must be accepted, not refused by a
place the held refusal still counted."
  (let ((refused (%make-gate)) (blocker (sb-thread:make-semaphore)) (ran (list nil)))
    (setf aion/pool::*%on-refusal* (lambda () (%hold refused)))
    (unwind-protect
         (with-pool (p :size 1 :queue-limit 0)
           (is (pool:try-submit p (lambda () (sb-thread:wait-on-semaphore blocker :timeout 10))))
           (is-true (wait-until (lambda () (= 1 (pool:pool-busy p)))))
           (let ((refusal (sb-thread:make-thread (lambda () (pool:try-submit p (lambda () nil)))
                                                 :name "pool held refusal")))
             (is (%arrived-p refused) "the refused submitter reached its refusal")
             (sb-thread:signal-semaphore blocker)
             (is-true (wait-until (lambda () (zerop (pool:pool-busy p)))))
             (setf aion/pool::*%on-refusal* nil)
             (is (pool:try-submit p (lambda () (setf (car ran) t)))
                 "refused while the pool had a free place")
             (%release refused)
             (is (null (aion/test-threads:join refusal)))
             (is-true (wait-until (lambda () (car ran))))))
      (setf aion/pool::*%on-refusal* nil))))

(test stop-pool-called-from-one-of-its-own-jobs-returns
  "As on main, for 1, 2 and 4 workers: the job that calls STOP-POOL does not wait for itself,
and the other workers do not wait for it either."
  (dolist (size '(1 2 4))
    (let* ((p (pool:make-pool :size size :queue-limit 4))
           (returned (sb-thread:make-semaphore)))
      (is (pool:try-submit p (lambda () (pool:stop-pool p) (sb-thread:signal-semaphore returned))))
      ;; Stopped again only when the job's call returned: if it hangs, a second STOP-POOL
      ;; would hang this test run with it, where a failed check reports it. The result is
      ;; kept in a variable because IS returns true whether or not its check passed.
      (let ((ok (sb-thread:wait-on-semaphore returned :timeout 10)))
        (is-true ok "~D workers: STOP-POOL called from a job did not return" size)
        (when ok (pool:stop-pool p))))))

;;; --- #520: stopping and submitting at once, and STOP-POOL called by several jobs ------

(test a-submitter-paused-anywhere-while-the-pool-stops-loses-no-accepted-job
  "A submitter submits until the pool refuses it after STOP-POOL was called. In each of 500
trials it is paused for up to 2 ms, by an interrupt that lands at whatever point it has
reached, just as STOP-POOL starts. Every job TRY-SUBMIT accepted must have run once STOP-POOL
and the submitter have returned. A pool that read STOPPING before reserving a place loses a job
when the pause falls between the read and the reservation (#520).

The queue limit is large so that the submitter is rarely refused and spends its time on the
path that reserves a place. On macOS, that pool lost a job in 119 of 1,000 trials at this
limit, and in 3 of 300 at a limit of 8."
  (let ((trials 500) (lost-trials 0) (stuck-trials 0))
    (dotimes (trial trials)
      (let* ((p (pool:make-pool :size 2 :queue-limit 4096))
             (accepted (list 0)) (ran (list 0)) (stop-called (list nil))
             (submitter
               (sb-thread:make-thread
                (lambda ()
                  (loop
                    (if (pool:try-submit p (lambda () (sb-ext:atomic-incf (car ran))))
                        (sb-ext:atomic-incf (car accepted))
                        (if (car stop-called) (return :done) (sb-thread:thread-yield)))))
                :name "pool paused submitter")))
        (sleep (random 0.0005))
        (ignore-errors
         (sb-thread:interrupt-thread submitter (lambda () (sleep (random 0.002)))))
        (setf (car stop-called) t)
        (pool:stop-pool p)
        (if (eq :done (ignore-errors (aion/test-threads:join submitter :timeout 10)))
            (unless (= (car accepted) (car ran)) (incf lost-trials))
            (incf stuck-trials))))
    (is (= 0 lost-trials) "~D of ~D trials lost an accepted job" lost-trials trials)
    (is (= 0 stuck-trials) "~D of ~D trials' submitters did not finish" stuck-trials trials)))

(test two-jobs-calling-stop-pool-at-once-both-return
  "For 2 and 4 workers, two jobs that are running at the same time both call STOP-POOL. At least
one of the two calls sees the other's flag and skips that worker, so it returns, its job
finishes, and the other call's join of its worker returns too. Before #520 each call joined the
other's worker and neither returned."
  (dolist (size '(2 4))
    (let* ((p (pool:make-pool :size size :queue-limit 4))
           (arrived (sb-thread:make-semaphore)) (both (sb-thread:make-semaphore))
           (returned (sb-thread:make-semaphore)))
      (dotimes (i 2)
        (is (pool:try-submit p (lambda ()
                                 (sb-thread:signal-semaphore arrived)
                                 (sb-thread:wait-on-semaphore both :timeout 10)
                                 (pool:stop-pool p)
                                 (sb-thread:signal-semaphore returned)))))
      (is-true (and (sb-thread:wait-on-semaphore arrived :timeout 10)
                    (sb-thread:wait-on-semaphore arrived :timeout 10))
               "~D workers: both jobs started" size)
      (sb-thread:signal-semaphore both 2)
      ;; As in the test above it, stopped again only when both calls returned, so a deadlock
      ;; fails this check instead of hanging the run.
      (let ((ok (and (sb-thread:wait-on-semaphore returned :timeout 10)
                     (sb-thread:wait-on-semaphore returned :timeout 10))))
        (is-true ok "~D workers: two jobs calling STOP-POOL at once did not both return" size)
        (when ok (pool:stop-pool p))))))

(test stop-pool-from-outside-waits-for-a-worker-whose-job-stopped-the-pool
  "One worker. Its job calls STOP-POOL with three jobs queued behind it, which the worker runs
before it exits. A later STOP-POOL from outside the pool must return only after those three
have run; before #520 it returned at once, and they started afterwards."
  (let* ((p (pool:make-pool :size 1 :queue-limit 4))
         (go-on (sb-thread:make-semaphore)) (job-stopped (sb-thread:make-semaphore))
         (ran (list 0)))
    (is (pool:try-submit p (lambda ()
                             (sb-thread:wait-on-semaphore go-on :timeout 10)
                             (pool:stop-pool p)
                             (sb-thread:signal-semaphore job-stopped))))
    (dotimes (i 3)
      (is (pool:try-submit p (lambda () (sleep 0.05) (sb-ext:atomic-incf (car ran))))))
    (sb-thread:signal-semaphore go-on)
    (is-true (sb-thread:wait-on-semaphore job-stopped :timeout 10))
    (let ((stopper (sb-thread:make-thread (lambda () (pool:stop-pool p) (car ran))
                                          :name "pool outside stopper")))
      (is (eql 3 (aion/test-threads:join stopper :timeout 10))
          "STOP-POOL from outside returned before the queued jobs had run"))))
