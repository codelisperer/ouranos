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
;;;; the tree is SBCL-only by design (AGENTS.md) and this file wants CONDITION-WAIT and
;;;; WAITQUEUE, which is where the two idioms differ most. Most of the tree uses `bt:', so
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

(defstruct (pool (:constructor %make-pool) (:conc-name pool-))
  "A fixed set of worker threads draining a bounded FIFO of thunks."
  (name "aion-pool" :type string)
  (size 0 :type unsigned-byte)
  (threads nil)
  (queue nil)              ; head of the FIFO, a list of thunks in order
  (tail nil)               ; last cons of QUEUE, so enqueue is O(1)
  (depth 0 :type unsigned-byte)
  (limit 0 :type unsigned-byte)
  (running 0 :type unsigned-byte)
  (on-error #'%log-job-error)
  (stopping nil)
  (lock (sb-thread:make-mutex :name "aion-pool"))
  (wake (sb-thread:make-waitqueue)))

(defun pool-queued (pool)
  "How many jobs are waiting -- not counting those already running."
  (sb-thread:with-mutex ((pool-lock pool)) (pool-depth pool)))

(defun pool-busy (pool)
  "How many workers are currently inside a job."
  (sb-thread:with-mutex ((pool-lock pool)) (pool-running pool)))

(defun pool-workers (pool)
  "How many workers the pool has."
  (pool-size pool))

(defun pool-capacity (pool)
  "The most jobs the pool will hold at once: its workers plus its queue limit.

CAPACITY IS SIZE + LIMIT, not the limit alone, and that is what keeps a queue-limit of 0 a
useful setting rather than \"accept nothing ever\", which is a footgun that reads exactly
like it. The guarantee the number buys: NO JOB IS ACCEPTED UNLESS A WORKER IS FREE OR THE
QUEUE HAS ROOM FOR IT."
  (+ (pool-size pool) (pool-limit pool)))

(defun %next-job (pool)
  "Wait for and remove the next job, or NIL when the pool is stopping and drained.
Caller must NOT hold the lock."
  (sb-thread:with-mutex ((pool-lock pool))
    (loop
      (cond ((pool-queue pool)
             (let ((job (pop (pool-queue pool))))
               (unless (pool-queue pool) (setf (pool-tail pool) nil))
               (decf (pool-depth pool))
               (incf (pool-running pool))
               (return job)))
            ((pool-stopping pool) (return nil))
            (t (sb-thread:condition-wait (pool-wake pool) (pool-lock pool)))))))

(defun %finish-job (pool)
  (sb-thread:with-mutex ((pool-lock pool))
    (decf (pool-running pool))
    (sb-thread:condition-broadcast (pool-wake pool))))

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

(defun %worker (pool)
  "One worker's whole life: take a job, run it, never die of it."
  (loop
    (let ((job (%next-job pool)))
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
  (let ((pool (%make-pool :name name :limit queue-limit :size size :on-error on-error)))
    (setf (pool-threads pool)
          (loop for i below size
                ;; THREAD-LIFETIME: independent -- a worker is created once and then
                ;; serves many unrelated callers. Inheriting the context bound at pool
                ;; construction would stamp that one correlation id onto every request the
                ;; worker ever handles: present, plausible and wrong, which is worse than
                ;; the absent field it replaces (#430).
                collect (sb-thread:make-thread
                         (lambda () (%worker pool))
                         :name (format nil "~A-~D" name i))))
    pool))

(defun try-submit (pool thunk)
  "Queue THUNK, returning T. Return NIL -- immediately, without blocking -- when the queue
is at its limit or the pool is stopping.

NEVER BLOCKS. The caller may be an event loop's own thread, where waiting would stall every
other connection; see the file header. A NIL is a decision the caller has to make, and for
a server that decision is 503."
  (sb-thread:with-mutex ((pool-lock pool))
    (cond
      ((pool-stopping pool) nil)
      ((>= (+ (pool-depth pool) (pool-running pool)) (pool-capacity pool)) nil)
      (t
       (let ((cell (list thunk)))
         (if (pool-tail pool)
             (setf (cdr (pool-tail pool)) cell)
             (setf (pool-queue pool) cell))
         (setf (pool-tail pool) cell))
       (incf (pool-depth pool))
       (sb-thread:condition-notify (pool-wake pool))
       t))))

(defun stop-pool (pool)
  "Stop accepting work, let the queue drain, and join every worker. Idempotent.

DRAINS RATHER THAN ABANDONS: a job already queued was accepted, and a pool that accepted
work and then dropped it on shutdown would make graceful shutdown a lie."
  (sb-thread:with-mutex ((pool-lock pool))
    (setf (pool-stopping pool) t)
    (sb-thread:condition-broadcast (pool-wake pool)))
  (dolist (thread (pool-threads pool))
    (ignore-errors (sb-thread:join-thread thread :default nil)))
  (setf (pool-threads pool) nil)
  pool)
