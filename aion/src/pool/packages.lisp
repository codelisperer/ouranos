;;;; packages.lisp --- aion/pool

(cl:defpackage #:aion/pool
  (:use #:cl)
  (:local-nicknames (#:log #:aion/log))
  (:documentation
   "A bounded worker pool: a fixed set of threads draining a FIFO with a limit.

    TRY-SUBMIT never blocks -- it queues and returns T, or refuses with NIL when the queue
    is full. Refusing is the decision: unbounded queueing is the policy nobody chooses,
    and blocking the submitter is worse still when the submitter is an event loop's thread,
    because one slow job then stalls every connection the loop owns. The caller turns a
    NIL into whatever its protocol says -- for an HTTP server, 503.

    A worker never dies of a job; a pool that lost a thread per failing job would degrade
    to nothing during exactly the incident that was already going badly. But it does not
    die QUIETLY either: a job that signals reaches MAKE-POOL's :ON-ERROR, which defaults to
    an aion/log warn naming the pool and the condition's type. Discarding it was the older
    behaviour and the wrong one -- the submitter is long gone by the time the job runs, so
    \"the caller will report it\" described nobody.")
  (:export #:pool #:pool-p #:make-pool #:try-submit #:stop-pool
           ;; POOL-NAME is exported because ON-ERROR is handed the pool and the first thing
           ;; a reporter wants is which pool lost the job -- an accessor the caller cannot
           ;; reach makes the argument useless.
           #:pool-name #:pool-workers #:pool-queued #:pool-busy #:pool-capacity
           #:*default-size* #:*default-queue-limit*))
