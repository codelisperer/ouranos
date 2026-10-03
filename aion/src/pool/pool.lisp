;;;; pool.lisp --- a bounded worker pool: N threads, a queue with a limit, and a refusal
;;;;
;;;; Generic concurrency infra, no HTTP and no libuv. hyperion's native server runs request
;;;; handlers on one of these so that a slow handler stops blocking every other connection;
;;;; mnemosyne's Postgres wire will want the same substrate.
;;;;
;;;; THE QUEUE IS BOUNDED AND A FULL POOL REFUSES. Both halves are the decision.
;;;;
;;;;   Unbounded would be the default nobody chose -- the same shape ADR-0016 rejected for
;;;;   streams. Work accumulates, latency climbs, memory grows, and nothing anywhere
;;;;   reports a fault: the operator sees "the app is slow" and goes looking at the wrong
;;;;   component.
;;;;
;;;;   Blocking the submitter when full would be worse HERE than unbounded, which is why
;;;;   TRY-SUBMIT refuses instead. The submitter is the event loop's thread. Blocking it
;;;;   stops accepting connections, stops reading sockets, stops timers -- one slow handler
;;;;   would take down every other connection, which is the exact defect the pool exists to
;;;;   fix, reintroduced by the mechanism meant to fix it.
;;;;
;;;; A JOB THAT SIGNALS IS REPORTED, NOT SWALLOWED. It used to be discarded, on the reasoning
;;;; that a failing job is "the caller's to report" -- but the caller cannot: TRY-SUBMIT
;;;; returned T and is long gone, and there is no future and no result channel. A discarded
;;;; error is a worse version of the defect two paragraphs up. An unbounded queue produces an
;;;; UNATTRIBUTABLE symptom; a swallowed error produces a MISSING one, and the operator does
;;;; not even get "the app is slow" to go looking with. See %REPORT-JOB-ERROR.
;;;;
;;;; SB-THREAD DIRECTLY, not bordeaux-threads, and it is deliberate rather than an oversight:
;;;; the tree is SBCL-only by design (AGENTS.md), and this file wants SBCL's atomics, its
;;;; memory barrier and SB-CONCURRENCY's lock-free queue (#466), which bordeaux-threads does
;;;; not offer. Most of the tree uses `bt:', so
;;;; whoever next moves code between here and, say, hyperion/channel should expect to
;;;; translate rather than assume a slip.
;;;;
;;;; So TRY-SUBMIT returns NIL and the caller decides. For a server that is 503, which is
;;;; true, actionable and arrives immediately.
;;;;
;;;; A WORKER NEVER DIES OF A JOB. Every job runs inside a handler, because a pool that
;;;; loses a thread per failing job degrades silently to nothing -- and the last thread
;;;; dies during the incident that is already going badly.

(cl:in-package #:aion/pool)

(defparameter *default-size* 8
  "Workers in a pool whose size is not given.

Fixed rather than derived from the core count. Handlers in this stack are dominated by IO
-- a database round trip, an LLM call -- so the useful concurrency is not the number of
cores, and a machine-dependent default would make a server's behaviour differ between
development and production for reasons nobody chose.")

(defparameter *default-queue-limit* 256
  "Jobs a pool will hold beyond those running, before TRY-SUBMIT refuses.

A queue exists to absorb bursts, not to store a backlog: work waiting far longer than a
client will wait is work that should have been refused when it arrived, while the refusal
was still useful.

The pool's CAPACITY is its worker count plus this. WHAT IS GUARANTEED IS THIS: no job is
accepted unless a worker is free or the queue has room for it. So a limit of 0 means
anything accepted has a worker waiting for it -- not \"nothing is ever queued\", which is
not quite true (with every worker busy, jobs briefly sit in the queue and are picked up as
workers free) and is a weaker promise than the real one.")

(defun %log-job-error (condition pool)
  "The default ON-ERROR: say that a job died, which pool it died in, and what KIND of
condition it was.

THE CONDITION'S TYPE, NOT ITS REPORT. A condition's message is the most useful field here
and is exactly the one we may not log: it routinely interpolates the value that caused it --
a bind parameter, a prompt, a path -- and the logging rule is counts, ids and types, never
payloads. An operator gets the type, the pool and a count; the payload is a debugger's job,
not a log's.

A WARN rather than an ERROR level: the pool is fine, the job is not."
  (log:warn "aion/pool: a job signalled and was discarded"
            :pool (pool-name pool)
            :condition (type-of condition)))

;;; --- the queue and its counts (#466) --------------------------------------------------
;;;
;;; NO POOL MUTEX ON THE SUBMIT PATH. Waking a worker still signals that worker's own semaphore,
;;; which has a lock inside it, but while the pool runs normally only the one submitter that
;;; claimed the worker and the worker itself take that lock; see below. Once the pool is
;;; stopping, STOP-POOL, every worker that finishes a job, and every submitter refused because
;;; the pool is stopping wake every worker and take it too. Every request a server-uv loop
;;; dispatches comes through TRY-SUBMIT, and with several loops they all used to serialise on
;;; one mutex, which each job then took twice more (taken by a worker, finished). #466 measured
;;; four loops at about 87,000 requests/s through the pool against about 101,000 with handlers
;;; run on the loops, and the profile put the contended waits on that lock.
;;;
;;; So the queue is SB-CONCURRENCY's lock-free FIFO, and the counts are atomic words:
;;;   OUTSTANDING  jobs accepted and not yet finished, queued or running. TRY-SUBMIT reserves
;;;                a place with ATOMIC-INCF before it enqueues, and gives it back when the
;;;                pool is full or stopping, so OUTSTANDING never passes the capacity.
;;;   RUNNING      jobs a worker is inside.
;;;
;;; EACH WORKER SLEEPS ON ITS OWN SEMAPHORE, AND A SUBMITTER WAKES ONE IDLE WORKER. A first
;;; version had every idle worker wait on one shared semaphore. The jobs a server sends are
;;; short, so workers are idle most of the time and nearly every submit signalled it; the
;;; contention moved from the pool's lock to the semaphore's own lock, and four loops served no
;;; more than before (#466). With one semaphore per worker, a wake-up involves one submitter
;;; and one worker.
;;;
;;; IDLE is a lock-free stack of the workers that are idle. A worker that finds the queue empty
;;; marks itself :IDLE, pushes itself onto IDLE, then looks at the queue again, and only then
;;; waits. A submitter enqueues first and then pops IDLE until it claims a worker, by changing
;;; that worker's state from :IDLE to :WOKEN with COMPARE-AND-SWAP, and signals the worker's
;;; semaphore. Either the worker's second look finds the job, or the submitter finds the
;;; worker on IDLE; with both orders covered, no job waits for a worker that is asleep.
;;;
;;; A worker whose second look finds a job takes itself back with the same COMPARE-AND-SWAP,
;;; from :IDLE to :BUSY, and leaves its entry on IDLE; a submitter that pops such an entry
;;; finds the state is not :IDLE and pops the next. When the submitter wins instead, its signal
;;; is already on the worker's semaphore and only makes that worker's next wait return at once,
;;; to look at the queue again.

(defstruct (%worker-state (:constructor %make-worker-state ()))
  "One worker's wake-up: its state, :BUSY, :IDLE or :WOKEN, and its own semaphore. Also its
thread, and STOPPING-POOL, true while a job on this worker is inside STOP-POOL; see there."
  (state :busy)
  (wake (sb-thread:make-semaphore :name "aion-pool worker"))
  (thread nil)
  (stopping-pool nil))

(defstruct (pool (:constructor %make-pool) (:conc-name pool-))
  "A fixed set of worker threads draining a bounded FIFO of thunks."
  (name "aion-pool" :type string)
  (size 0 :type unsigned-byte)
  (threads nil)
  (queue (sb-concurrency:make-queue :name "aion-pool"))
  (outstanding 0 :type sb-ext:word)
  (running 0 :type sb-ext:word)
  (idle nil)                      ; a lock-free stack of %WORKER-STATEs, see above
  (wakes nil)                     ; every worker's %WORKER-STATE
  (limit 0 :type unsigned-byte)
  (%capacity 0 :type fixnum)      ; SIZE + LIMIT, computed once in MAKE-POOL; see POOL-CAPACITY
  (on-error #'%log-job-error)
  (stopping nil))

(defun pool-queued (pool)
  "How many jobs are waiting -- not counting those already running. Exact when the pool is
quiet; while jobs are being submitted and taken it is a reading of two counters that are
changing, as any answer to this question is."
  (max 0 (- (pool-outstanding pool) (pool-running pool))))

(defun pool-busy (pool)
  "How many workers are currently inside a job."
  (pool-running pool))

(defun pool-workers (pool)
  "How many workers the pool has."
  (pool-size pool))

(defun pool-capacity (pool)
  "The most jobs the pool will hold at once: its workers plus its queue limit.

CAPACITY IS SIZE + LIMIT, not the limit alone, and that is what keeps a queue-limit of 0 a
useful setting rather than \"accept nothing ever\", which is a footgun that reads exactly
like it. The guarantee the number buys: NO JOB IS ACCEPTED UNLESS A WORKER IS FREE OR THE
QUEUE HAS ROOM FOR IT."
  (pool-%capacity pool))

(sb-ext:defglobal *%after-empty-look* nil
  "NIL, or a function a worker calls after it finds the queue empty and before it counts
itself idle. FOR TESTS ONLY: it lets a test hold a worker at the one point where a job
submitted next would be missed without the worker's second look at the queue.")

(sb-ext:defglobal *%after-reserve* nil
  "NIL, or a function TRY-SUBMIT calls after it has reserved a place and before it enqueues.
FOR TESTS ONLY: it lets a test hold a submitter at the one point where a pool that stops would
lose the job if its workers exited with a place still reserved.

Both hooks are global variables, not special ones, so reading one is a plain load: TRY-SUBMIT
reads *%AFTER-RESERVE* on every job, and a special variable's value would first be looked up
in the thread's own bindings.")

(sb-ext:defglobal *%after-push* nil
  "NIL, or a function of the worker's %WORKER-STATE that a worker calls after it has pushed
itself onto IDLE and before its second look. FOR TESTS ONLY, like the hooks above.")

(sb-ext:defglobal *%after-second-look-found* nil
  "NIL, or a function of the worker's %WORKER-STATE that a worker calls when its second look
has found a job, before it takes itself back off IDLE. FOR TESTS ONLY: a submitter that claims
this worker in that moment has its wake-up passed on, which is what a test holds open here.")

(sb-ext:defglobal *%on-refusal* nil
  "NIL, or a function TRY-SUBMIT calls when it refuses a full pool, before it returns NIL. FOR
TESTS ONLY: a refusal holds no place in the pool, and a test holds a refused submitter here to
show that another submitter is still accepted when a place frees.")

(sb-ext:defglobal *%after-stop-check* nil
  "NIL, or a function a worker calls after it has found the pool stopping and decided whether
to exit, with T when it will exit and NIL when it stays. FOR TESTS ONLY: a test that needs a
broken pool's workers to have exited waits for each worker's decision here, instead of
sleeping for a time that a loaded machine can exceed (#520).")

(sb-ext:defglobal *%before-wait* nil
  "NIL, or a function of the worker's %WORKER-STATE that a worker calls when its second look
has found nothing, just before it waits on its semaphore. FOR TESTS ONLY: a test that needs a
worker to be past its second look waits for it here, instead of sleeping (#520).")

(defun %wake-all (pool)
  "Wake every worker, so each can see the pool is stopping and drained."
  (dolist (w (pool-wakes pool))
    (sb-thread:signal-semaphore (%worker-state-wake w))))

(defun %push-idle (pool w)
  (loop for top = (pool-idle pool)
        until (eq top (sb-ext:compare-and-swap (pool-idle pool) top (cons w top)))))

(defun %wake-one (pool)
  "Claim one idle worker and signal it; do nothing when none is idle."
  (loop
    (let ((top (pool-idle pool)))
      (when (null top) (return))
      (when (eq top (sb-ext:compare-and-swap (pool-idle pool) top (cdr top)))
        (let ((w (car top)))
          (when (eq :idle (sb-ext:compare-and-swap (%worker-state-state w) :idle :woken))
            (sb-thread:signal-semaphore (%worker-state-wake w))
            (return)))))))

(defun %next-job (pool w)
  "Wait for and remove the next job, or NIL when the pool is stopping and drained. W is this
worker's %WORKER-STATE."
  (let ((queue (pool-queue pool)))
    (loop
      (multiple-value-bind (job found) (sb-concurrency:dequeue queue)
        (when found
          (sb-ext:atomic-incf (pool-running pool))
          (return job)))
      ;; A STOPPING POOL'S WORKER LEAVES once nothing is queued or reserved: OUTSTANDING is
      ;; no more than RUNNING, the jobs other workers are inside. Those jobs do not need this
      ;; worker, and counting them would keep it waiting on a job that called STOP-POOL
      ;; itself, which then never returns (#512's review). OUTSTANDING is read before RUNNING:
      ;; a job that finishes between the two reads lowers OUTSTANDING after RUNNING was read
      ;; higher, and only ever makes this worker stay, never leave early.
      ;;
      ;; STOPPING before OUTSTANDING, with a barrier between, pairs with the ordering of
      ;; TRY-SUBMIT's reservation before its read of STOPPING: a submitter that did not see
      ;; STOPPING made its reservation visible to a worker that does. The barrier between
      ;; OUTSTANDING and RUNNING keeps the two loads in that order, which arm64 does not do on
      ;; its own. These two and STOP-POOL's are the barriers the design needs. The others
      ;; follow an atomic read-modify-write, which already orders later accesses on arm64
      ;; (LDADDAL, and a successful CASAL) and on x86-64 (a LOCK-prefixed instruction), so
      ;; they are kept only as statements of intent; #512's review checked this.
      (when (pool-stopping pool)
        (let ((leave (progn (sb-thread:barrier (:memory))
                            (let ((outstanding (pool-outstanding pool)))
                              (sb-thread:barrier (:memory))
                              (<= outstanding (pool-running pool))))))
          (when *%after-stop-check* (funcall *%after-stop-check* leave))
          (when leave (return nil))))
      (when *%after-empty-look* (funcall *%after-empty-look*))
      ;; Become findable BEFORE the second look, so a submitter that enqueues after the look
      ;; finds this worker on IDLE and wakes it.
      (setf (%worker-state-state w) :idle)
      (%push-idle pool w)
      (when *%after-push* (funcall *%after-push* w))
      (sb-thread:barrier (:memory))
      (multiple-value-bind (job found) (sb-concurrency:dequeue queue)
        (cond (found
               (when *%after-second-look-found* (funcall *%after-second-look-found* w))
               ;; Take this worker back. If a submitter claimed it first, that submitter
               ;; enqueued a job of its own and woke this worker for it, and this worker is
               ;; about to run another. So pass the wake-up on to the next idle worker, or the
               ;; submitter's job waits behind this one while an idle worker sleeps (#512's
               ;; review). The signal left on this worker's semaphore only makes its next wait
               ;; return at once.
               (unless (eq :idle (sb-ext:compare-and-swap (%worker-state-state w) :idle :busy))
                 (%wake-one pool))
               (setf (%worker-state-state w) :busy)
               (sb-ext:atomic-incf (pool-running pool))
               (return job))
              (t
               (when *%before-wait* (funcall *%before-wait* w))
               (sb-thread:wait-on-semaphore (%worker-state-wake w))
               (setf (%worker-state-state w) :busy)))))))

(defun %finish-job (pool)
  "Count a job as finished. When the pool is stopping, wake every worker, so each can see
whether anything is left and exit if not. RUNNING is lowered before OUTSTANDING, so a worker
that reads the two between the decrements sees OUTSTANDING the higher and stays."
  (sb-ext:atomic-decf (pool-running pool))
  (sb-ext:atomic-decf (pool-outstanding pool))
  (sb-thread:barrier (:memory))
  (when (pool-stopping pool)
    (%wake-all pool)))

(defun %report-job-error (pool condition)
  "Tell someone that a job died -- and never let the telling kill the worker.

THIS USED TO BE `(error (e) nil)', with a comment calling a failing job \"the caller's to
report\". THE CALLER CANNOT REPORT IT. TRY-SUBMIT returned T and is long gone by the time
the thunk runs: there is no future, no result channel and no hook, so a job that signalled
disappeared completely -- no log line, no counter, nothing.

That is this file's own argument against unbounded queues turned on itself. The header
rejects a queue without a limit because \"nothing anywhere reports a fault\" and the operator
is left with \"the app is slow\" and the wrong component to look at. A discarded error is
worse than an unattributable symptom: it is a MISSING one, and the operator does not even
get \"slow\" to go looking with. It lands hardest where this pool is aimed -- a job dying on
every third database connection reads as an intermittent network.

THE HANDLER IS ITSELF WRAPPED, and that is not defensiveness. ON-ERROR is caller-supplied
code running on a worker thread; a reporter that signals would kill the worker, so the pool
would lose a thread every time it tried to tell you it had lost a job. Silence about the
silence."
  (handler-case (funcall (pool-on-error pool) condition pool)
    (error () nil)))

(defun %worker (pool w)
  "One worker's whole life: take a job, run it, never die of it. W is its %WORKER-STATE."
  (loop
    (let ((job (%next-job pool w)))
      (unless job (return))
      (unwind-protect
           (handler-case (funcall job)
             (error (e) (%report-job-error pool e)))
        (%finish-job pool)))))

(defun make-pool (&key (size *default-size*) (queue-limit *default-queue-limit*)
                       (name "aion-pool") (on-error #'%log-job-error))
  "Start a pool of SIZE workers holding at most QUEUE-LIMIT waiting jobs.

ON-ERROR is called with (CONDITION POOL) when a job signals, and defaults to an aion/log
warn naming the pool and the condition's TYPE -- never its report, which routinely
interpolates the payload that caused it. See %REPORT-JOB-ERROR for why a default that says
nothing was the wrong answer, and why a reporter that signals still cannot kill a worker."
  (check-type size (integer 1))
  (check-type queue-limit (integer 0))
  (let ((pool (%make-pool :name name :limit queue-limit :size size :on-error on-error
                          :%capacity (+ size queue-limit))))
    (setf (pool-wakes pool) (loop repeat size collect (%make-worker-state)))
    (setf (pool-threads pool)
          (loop for i below size
                for w in (pool-wakes pool)
                ;; THREAD-LIFETIME: independent -- a worker is created once and then
                ;; serves many unrelated callers. Inheriting the context bound at pool
                ;; construction would stamp that one correlation id onto every request the
                ;; worker ever handles: present, plausible and wrong, which is worse than
                ;; the absent field it replaces (#158).
                collect (let ((w w)) (sb-thread:make-thread
                                      (lambda () (%worker pool w))
                                      :name (format nil "~A-~D" name i)))))
    ;; Before MAKE-POOL returns, so before any job can call STOP-POOL and look for its worker.
    (loop for w in (pool-wakes pool)
          for thread in (pool-threads pool)
          do (setf (%worker-state-thread w) thread))
    pool))

(defun try-submit (pool thunk)
  "Queue THUNK, returning T. Return NIL -- immediately, without blocking -- when the queue
is at its limit or the pool is stopping.

NEVER WAITS FOR A JOB OR A WORKER, AND TAKES NO POOL MUTEX (#466). It can still be held up
briefly in two places. Waking an idle worker signals that worker's own semaphore, whose lock,
while the pool runs normally, only the claiming submitter and that worker take. Once the pool
is stopping, more threads take it: STOP-POOL, every worker that finishes a job, and every
submitter refused because the pool is stopping all wake every worker. And SB-CONCURRENCY:ENQUEUE
retries while another thread that is enqueuing sits between its compare-and-swap and its
store of the new tail, so a submitter whose fellow submitter lost the processor at that point
spins until it runs again. Neither waits on work. The caller may be an event loop's own thread,
where waiting would stall every other connection; see the file header. A NIL is a decision
the caller has to make, and for a server that decision is 503.

THE PLACE IS RESERVED BEFORE THE STOPPING CHECK. A submitter that checked STOPPING first
could pass the check, lose the processor while STOP-POOL ran and every worker found nothing
left, and then enqueue a job no worker would ever take. Reserved first, the job counts in
OUTSTANDING before STOPPING is read, and a worker does not exit while OUTSTANDING is above
RUNNING, which a reserved job that is not yet queued always makes it.

A FULL POOL REFUSES WITHOUT TAKING A PLACE, so a refusal never makes another submitter see the
pool fuller than it is."
  ;; RESERVE WITHOUT EVER PASSING THE CAPACITY. An increment that was taken back after it saw
  ;; a full pool counted, until it was taken back, against a submitter that came in between,
  ;; which was refused while a place was free (#512's review). The compare-and-swap raises
  ;; OUTSTANDING only from a value below the capacity, so a refusal holds no place at all.
  (let ((capacity (pool-%capacity pool)))
    (declare (fixnum capacity))
    (loop
      (let ((current (pool-outstanding pool)))
        (when (>= current capacity)
          (when *%on-refusal* (funcall *%on-refusal*))
          (return-from try-submit nil))
        (when (eql current (sb-ext:compare-and-swap (pool-outstanding pool) current (1+ current)))
          (return)))))
  ;; The reservation is visible before STOPPING is read; see %NEXT-JOB's exit check. The
  ;; compare-and-swap above already orders it on arm64 and x86-64; the barrier says so here.
  (sb-thread:barrier (:memory))
  (cond ((pool-stopping pool)
         ;; Give the place back, and wake every worker so each sees it is gone.
         (sb-ext:atomic-decf (pool-outstanding pool))
         (sb-thread:barrier (:memory))
         (%wake-all pool)
         nil)
        (t
         (when *%after-reserve* (funcall *%after-reserve*))
         (sb-concurrency:enqueue thunk (pool-queue pool))
         (sb-thread:barrier (:memory))
         (%wake-one pool)
         t)))

(defun stop-pool (pool)
  "Stop accepting work, let the queue drain, and join every worker. Idempotent.

DRAINS RATHER THAN ABANDONS: a job already queued was accepted, and a pool that accepted
work and then dropped it on shutdown would make graceful shutdown a lie. A worker exits once
nothing is queued or reserved, so a job reserved in the moment STOPPING was set still runs.

CALLED FROM ONE OF THE POOL'S OWN JOBS, it returns, as it always has. It does not join the
worker it runs on. That worker goes on to run every job still queued behind the calling job,
and exits after the last of them. The other workers do not wait for the calling job, which
only its own worker needs.

SEVERAL JOBS MAY CALL IT AT ONCE. A call from a job does not join a worker whose own job is
also inside STOP-POOL, because those two calls would each wait for the other's worker to exit
(#520). It joins every other worker, so it returns once they have drained the queue, or, if
the only workers left are ones it skipped, as soon as it has woken them.

A CALL FROM OUTSIDE THE POOL JOINS EVERY WORKER, including one whose job called STOP-POOL
earlier, so when it returns no job is running and none will start (#520)."
  (let ((self (find sb-thread:*current-thread* (pool-wakes pool) :key #'%worker-state-thread)))
    ;; SELF's flag is stored, and a barrier passed, before any other worker's flag is read. Of
    ;; two jobs calling at once, at least one therefore sees the other's flag and skips that
    ;; worker, so no two calls wait on each other's worker.
    (when self (setf (%worker-state-stopping-pool self) t))
    (unwind-protect
         (progn
           (setf (pool-stopping pool) t)
           ;; Required: STOPPING, and SELF's flag, must be visible before the workers are woken
           ;; to read STOPPING, and before this call reads the other workers' flags.
           (sb-thread:barrier (:memory))
           (%wake-all pool)
           (dolist (w (pool-wakes pool))
             (unless (or (eq w self) (and self (%worker-state-stopping-pool w)))
               (ignore-errors (sb-thread:join-thread (%worker-state-thread w) :default nil)))))
      (when self (setf (%worker-state-stopping-pool self) nil))))
  pool)
