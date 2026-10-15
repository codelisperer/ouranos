;;;; scheduler.lisp --- the scheduler: registration, TICK, run-now, stop, and the thread driver (#689).
;;;;
;;;; HOW A SLOT RUNS ONCE ACROSS INSTANCES. Every instance's TICK reads the store and, for a job
;;;; whose next due time has passed, asks the store for the lease with STORE-ACQUIRE. That is a
;;;; compare-and-set: it succeeds only when the lease is free or expired and the next due time is
;;;; still the one this instance read, and it advances the next due time in the same step. So
;;;; the first instance to ask runs the slot, and every other instance then reads a job that is
;;;; not due.
;;;;
;;;; WHAT HAPPENS WHEN AN INSTANCE DIES MID-RUN. While a run is in progress, the scheduler that
;;;; started it renews its lease on every tick, and the drivers tick at least every third of the
;;;; lease. When the instance dies the renewals stop, the lease expires, and the next tick on
;;;; another instance finds a job whose expired lease still names a run. It marks that run
;;;; :ABANDONED and runs the job again with trigger :RETRY (ruling R2 on #689). So a run is
;;;; at-least-once when an instance dies: a job must tolerate running twice.
;;;;
;;;; CLOCKS. Lease times come from the instances' clocks (ruling R3). An instance whose clock is
;;;; ahead of another's sees that instance's lease expire early, by the difference. With the
;;;; lease renewed every third of its length, a difference below about a third of the lease
;;;; (100 seconds at the default of 300) never lets a live run's lease expire. Keep the
;;;; instances' clocks synchronised.

(in-package #:aion/schedule)

(define-condition scheduler-stopped (error) ()
  (:report "aion/schedule: the scheduler has been stopped and starts no more runs."))

(define-condition unknown-job (error)
  ((key :initarg :key :reader unknown-job-key)
   (what :initarg :what :initform "stored job" :reader %unknown-job-what))
  (:report (lambda (c s)
             (format s "aion/schedule: there is no ~A named ~S."
                     (%unknown-job-what c) (unknown-job-key c)))))

(define-condition unreadable-job-args (error)
  ((args :initarg :args :reader unreadable-job-args-args))
  (:report (lambda (c s)
             (format s "aion/schedule: a one-off job's arguments must be data that can be written and read back (numbers, strings, symbols, lists), and ~S cannot."
                     (unreadable-job-args-args c)))))

(defparameter *error-text-limit* 1000
  "The longest error text a run keeps. The log line keeps only the condition's type.")

(defparameter *item-error-summaries* 10
  "How many NOTE-ITEM-ERROR summaries a run keeps; the count includes them all.")

(defclass scheduler ()
  ((store :initarg :store :reader scheduler-store)
   (clock :initarg :clock :reader %clock)
   (holder :initarg :holder :reader scheduler-holder)
   (lease-seconds :initarg :lease-seconds :reader scheduler-lease-seconds)
   (pool :initarg :pool :accessor %pool)
   (pool-size :initarg :pool-size :reader %pool-size)
   (own-pool :initform nil :accessor %own-pool)
   (dispatch :initarg :dispatch :reader %dispatch)
   (keep-runs :initarg :keep-runs :reader %keep-runs)
   (functions :initform (make-hash-table :test #'equal) :reader %functions)
   (running :initform (make-hash-table :test #'equal) :reader %running)
   (reported :initform (make-hash-table :test #'equal) :reader %reported)
   (lock :initform (sb-thread:make-mutex :name "aion/schedule scheduler") :reader %lock)
   (idle :initform (sb-thread:make-waitqueue :name "aion/schedule idle") :reader %idle)
   (tick-lock :initform (sb-thread:make-mutex :name "aion/schedule tick") :reader %tick-lock)
   (created-at :initarg :created-at :reader %created-at)
   (stopping :initform nil :accessor %stopping)
   (wake-function :initform nil :accessor scheduler-wake-function)
   (driver-stop :initform nil :accessor scheduler-driver-stop))
  (:documentation "Runs the jobs in a JOB-STORE when they fall due. See MAKE-SCHEDULER."))

(defun %new-id () (values (clock:new-id)))

(defun make-scheduler (store &key (clock #'get-universal-time) (lease-seconds 300) pool
                                  (pool-size 2) (dispatch :pool) keep-runs holder)
  "A scheduler over STORE.

CLOCK is a function of no arguments returning universal time, or a MANUAL-CLOCK; it is the only
clock the scheduler and its store read. LEASE-SECONDS is how long a run's lease lasts between
renewals; it is renewed every third of that. POOL is an aion/pool pool to run jobs on; without
one, the scheduler makes its own of POOL-SIZE workers when it first needs it, so a long job
cannot occupy the workers that serve requests. DISPATCH is :POOL, :INLINE (run each job on the
thread that started it, for tests), or a function that takes a thunk and returns true when it
accepted it. KEEP-RUNS, when given, keeps only that many newest runs of each job. HOLDER names
this instance in leases and runs; it defaults to the host name and a fresh id."
  (check-type lease-seconds (integer 3))
  (check-type keep-runs (or null (integer 1)))
  (make-instance 'scheduler
                 :store store :clock clock :lease-seconds lease-seconds :pool pool
                 :pool-size pool-size :dispatch dispatch :keep-runs keep-runs
                 :holder (or holder (format nil "~A/~A" (or (machine-instance) "host") (%new-id)))
                 :created-at (clock-now clock)))

(defun scheduler-clock-now (scheduler) (clock-now (%clock scheduler)))

(defmacro %with-lock ((scheduler) &body body)
  `(sb-thread:with-recursive-lock ((%lock ,scheduler)) ,@body))

(defun %wake (scheduler)
  (let ((f (scheduler-wake-function scheduler)))
    (when f (funcall f))))

;;; --- registration ------------------------------------------------------------------------

(defun %initial-due (schedule now)
  (if (eq (first schedule) :once) (second schedule) (values (next-due schedule now))))

(defun define-job (scheduler name function &key schedule)
  "Register FUNCTION as the job function NAME. With SCHEDULE, also store a job keyed NAME on that
schedule.

A stored job with the same schedule keeps its next due time, so a slot that passed while no
instance was running is still due, and runs once (catch-up). A changed schedule starts again
from now. Returns NAME."
  (check-type name string)
  (check-type function (or function symbol))
  (when schedule (check-schedule schedule))
  (%with-lock (scheduler) (setf (gethash name (%functions scheduler)) function))
  (when schedule
    (let* ((store (scheduler-store scheduler))
           (now (scheduler-clock-now scheduler))
           (old (store-job store name)))
      (cond ((null old)
             (store-put-job store (make-stored-job :key name :function-name name
                                                   :schedule schedule
                                                   :next-due (%initial-due schedule now)
                                                   :updated-at now)))
            ((and (equal schedule (stored-job-schedule old))
                  (equal name (stored-job-function-name old))))
            (t
             (store-put-job store (make-stored-job
                                   :key name :function-name name :schedule schedule
                                   :next-due (if (equal schedule (stored-job-schedule old))
                                                 (stored-job-next-due old)
                                                 (%initial-due schedule now))
                                   :updated-at now)
                            :replace t)))))
  (%wake scheduler)
  name)

(defun %readable-p (args)
  (handler-case (equal args (read-data (write-data args)))
    (error () nil)))

(defun schedule-once (scheduler function-name &key at args key)
  "Store a one-off run of the registered job function FUNCTION-NAME, due at the instant AT, with
ARGS, and return its key. ARGS must be data that can be written and read back, because they are
stored; anything else signals UNREADABLE-JOB-ARGS. The job is removed from the store once it has
run and completed; after a failed run it stays, not due, for an operator to run again."
  (check-type function-name string)
  (check-type at (integer 0))
  (unless (%with-lock (scheduler) (gethash function-name (%functions scheduler)))
    (error 'unknown-job :key function-name :what "registered job function"))
  (unless (%readable-p args) (error 'unreadable-job-args :args args))
  (let ((key (or key (format nil "~A/~A" function-name (%new-id))))
        (now (scheduler-clock-now scheduler)))
    (store-put-job (scheduler-store scheduler)
                   (make-stored-job :key key :function-name function-name
                                    :schedule (list :once at) :args args :next-due at
                                    :updated-at now))
    (%wake scheduler)
    key))

;;; --- the run context ---------------------------------------------------------------------

(defstruct (run-context (:conc-name run-) (:constructor %make-run-context))
  "What a job function receives as its first argument."
  id key trigger scheduled-for local-date args scheduler
  (errors 0) (summaries '())
  (lock (sb-thread:make-mutex :name "aion/schedule run")))

(defun note-item-error (context summary)
  "Record that one item of this run failed, with SUMMARY, a short string that names the item and
what went wrong. The run goes on, and finishes as :COMPLETED-WITH-ERRORS (ruling R4 on #689).
Safe to call from any thread."
  (sb-thread:with-mutex ((run-lock context))
    (incf (run-errors context))
    (when (< (length (run-summaries context)) *item-error-summaries*)
      (push (princ-to-string summary) (run-summaries context))))
  nil)

(defun stop-requested-p (context)
  "True once the scheduler is stopping. A long job may poll it and end early."
  (and (%stopping (run-scheduler context)) t))

(defun %clip (text)
  (if (> (length text) *error-text-limit*) (subseq text 0 *error-text-limit*) text))

(defun %report-of (condition)
  (handler-case (princ-to-string condition)
    (error () "(the condition's report signalled)")))

(defun %counts (result key)
  (cond ((null result) nil)
        ((and (listp result)
              (let ((n (ignore-errors (list-length result))))
                (and n (evenp n)))
              (loop for (k v) on result by #'cddr always (and (keywordp k) (realp v))))
         result)
        (t (log:warn "aion/schedule: a job returned something other than a plist of counts"
                     :job key :type (type-of result))
           nil)))

;;; --- starting and finishing a run ----------------------------------------------------------

(defun %ensure-pool (scheduler)
  (%with-lock (scheduler)
    (or (%pool scheduler)
        (setf (%own-pool scheduler) t
              (%pool scheduler) (pool:make-pool :size (%pool-size scheduler)
                                                :name "aion-schedule")))))

(defun %submit (scheduler thunk dispatch)
  "Hand THUNK to DISPATCH; true when it was accepted."
  (cond ((eq dispatch :inline) (funcall thunk) t)
        ((eq dispatch :pool) (pool:try-submit (%ensure-pool scheduler) thunk))
        (t (funcall dispatch thunk))))

(defun %finish (scheduler context job outcome counts error)
  (let ((store (scheduler-store scheduler))
        (key (run-key context))
        (now (scheduler-clock-now scheduler)))
    (unwind-protect
         (handler-case
             (progn
               (unless (store-finish store key (scheduler-holder scheduler) (run-id context)
                                     :now now :outcome outcome :counts counts :error error)
                 (log:warn "aion/schedule: a run finished after its lease was taken over"
                           :job key :run-id (run-id context)))
               (when (and (eq :once (first (stored-job-schedule job)))
                          (member outcome '(:completed :completed-with-errors)))
                 (store-remove-job store key))
               (when (%keep-runs scheduler)
                 (store-prune-runs store :key key :keep (%keep-runs scheduler))))
           (error (e)
             (log:exception e "aion/schedule: a run's outcome could not be stored"
                            :job key :run-id (run-id context))))
      (%with-lock (scheduler)
        (when (equal (run-id context) (gethash key (%running scheduler)))
          (remhash key (%running scheduler)))
        (sb-thread:condition-broadcast (%idle scheduler))))
    (log:info "aion/schedule: a run finished" :job key :run-id (run-id context)
                                              :outcome outcome)
    outcome))

(defun %execute (scheduler context function job)
  (let ((outcome :failed) (counts nil) (error nil))
    (log:with-context (:job (run-key context) :run-id (run-id context))
      (handler-case
          (let ((result (apply function context (run-args context))))
            (setf counts (%counts result (run-key context)))
            (let ((n (run-errors context)))
              (if (plusp n)
                  (setf outcome :completed-with-errors
                        error (%clip (format nil "~D item error~:P: ~{~A~^; ~}"
                                             n (reverse (run-summaries context)))))
                  (setf outcome :completed))))
        (error (e)
          (setf error (%clip (format nil "~S: ~A" (type-of e) (%report-of e))))
          (log:warn "aion/schedule: a job signalled" :job (run-key context)
                                                     :run-id (run-id context)
                                                     :condition (type-of e)))))
    (%finish scheduler context job outcome counts error)))

(defun %start-run (scheduler job trigger &key expected-due next-due scheduled-for args
                                             (dispatch (%dispatch scheduler)))
  "Take JOB's lease and start a run with TRIGGER. Returns the run id, or NIL when the lease was
not this instance's to take."
  (let* ((key (stored-job-key job))
         (function (%with-lock (scheduler)
                     (gethash (stored-job-function-name job) (%functions scheduler))))
         (now (scheduler-clock-now scheduler))
         (run-id (%new-id))
         (run (store-acquire (scheduler-store scheduler) key (scheduler-holder scheduler)
                             :now now :until (+ now (scheduler-lease-seconds scheduler))
                             :expected-due expected-due :next-due next-due :run-id run-id
                             :trigger trigger :scheduled-for scheduled-for)))
    (when run
      (let ((context (%make-run-context
                      :id run-id :key key :trigger trigger :scheduled-for scheduled-for
                      :local-date (and scheduled-for
                                       (%local-date-of-slot (stored-job-schedule job)
                                                            scheduled-for))
                      :args args :scheduler scheduler)))
        (%with-lock (scheduler) (setf (gethash key (%running scheduler)) run-id))
        (log:info "aion/schedule: a run started" :job key :run-id run-id :trigger trigger)
        (unless (%submit scheduler (lambda () (%execute scheduler context function job)) dispatch)
          (%finish scheduler context job :failed nil "the worker pool refused the run")))
      run-id)))

;;; --- TICK ----------------------------------------------------------------------------------

(defun %report-once (scheduler job reason)
  (let ((key (stored-job-key job)))
    (unless (%with-lock (scheduler) (shiftf (gethash key (%reported scheduler)) t))
      (log:warn reason :job key :function (stored-job-function-name job)))))

(defun %usable-schedule-p (scheduler job)
  (handler-case (progn (check-schedule (stored-job-schedule job)) t)
    (error ()
      (%report-once scheduler job "aion/schedule: a stored job's schedule cannot be read")
      nil)))

(defun %running-locally-p (scheduler key)
  (%with-lock (scheduler) (nth-value 1 (gethash key (%running scheduler)))))

(defun %skip (scheduler job now)
  "JOB fell due while its previous run on this instance was still going: record a :SKIPPED run
and move the next due time past now."
  (let* ((due (stored-job-next-due job))
         (next (next-due (stored-job-schedule job) now :previous due))
         (store (scheduler-store scheduler)))
    (when (store-advance store (stored-job-key job) :expected-due due :next-due next)
      (store-record-run store (make-job-run :id (%new-id) :job-key (stored-job-key job)
                                            :holder (scheduler-holder scheduler)
                                            :trigger :schedule :scheduled-for due
                                            :started-at now :finished-at now
                                            :outcome :skipped))
      (log:info "aion/schedule: a run was skipped, because the previous one is still going"
                :job (stored-job-key job)))))

(defun %consider (scheduler job now)
  "Start a run of JOB if it is this instance's to run at NOW. Returns the run id or NIL."
  (let ((key (stored-job-key job))
        (due (stored-job-next-due job)))
    (cond
      ((not (%with-lock (scheduler)
              (gethash (stored-job-function-name job) (%functions scheduler))))
       (%report-once scheduler job "aion/schedule: a stored job names no registered function")
       nil)
      ((not (%usable-schedule-p scheduler job)) nil)
      ((%running-locally-p scheduler key)
       (when (and due (<= due now)) (%skip scheduler job now))
       nil)
      ((not (%lease-free-p job now)) nil)
      ;; The lease has expired and still names a run: its instance died mid-run.
      ((stored-job-current-run job)
       (let ((old (store-run (scheduler-store scheduler) (stored-job-current-run job))))
         (%start-run scheduler job :retry :expected-due due :next-due :keep
                                          :scheduled-for (and old (job-run-scheduled-for old))
                                          :args (stored-job-args job))))
      ((and due (<= due now))
       (%start-run scheduler job (if (< due (%created-at scheduler)) :catch-up :schedule)
                   :expected-due due
                   :next-due (values (next-due (stored-job-schedule job) now :previous due))
                   :scheduled-for due :args (stored-job-args job)))
      (t nil))))

(defun %renew-leases (scheduler now)
  (loop for (key . run-id) in (%with-lock (scheduler)
                                (loop for k being the hash-keys of (%running scheduler)
                                        using (hash-value v)
                                      collect (cons k v)))
        do (handler-case
               (unless (store-renew (scheduler-store scheduler) key (scheduler-holder scheduler)
                                    run-id (+ now (scheduler-lease-seconds scheduler)))
                 (log:warn "aion/schedule: a running job's lease was lost" :job key
                                                                           :run-id run-id))
             (error (e)
               (log:exception e "aion/schedule: a lease could not be renewed" :job key)))))

(defun tick (scheduler)
  "Renew the leases of this instance's runs, then start every stored job that is due and is this
instance's to run. Returns the ids of the runs started. A driver calls this; so can a test."
  (unless (%stopping scheduler)
    (sb-thread:with-mutex ((%tick-lock scheduler))
      (let ((now (scheduler-clock-now scheduler)))
        (%renew-leases scheduler now)
        (loop for job in (store-jobs (scheduler-store scheduler))
              for id = (handler-case (%consider scheduler job now)
                         (error (e)
                           (log:exception e "aion/schedule: a job could not be started"
                                          :job (stored-job-key job))
                           nil))
              when id collect id)))))

(defun next-wake (scheduler)
  "Seconds until a driver should tick again: when the earliest job falls due or a lease another
instance holds expires, but at least 1 and at most a third of the lease, so this instance's
leases are renewed in time and jobs written by other instances are noticed."
  (let* ((cap (max 1 (floor (scheduler-lease-seconds scheduler) 3)))
         (now (scheduler-clock-now scheduler))
         (jobs (handler-case (store-jobs (scheduler-store scheduler))
                 (error () (return-from next-wake cap)))))
    (max 1 (min cap
                (loop for job in jobs
                      initially (when (null jobs) (return cap))
                      for until = (stored-job-lease-until job)
                      minimize (cond ((and (stored-job-lease-holder job) until (>= until now))
                                      (- (1+ until) now))
                                     ((stored-job-current-run job) 0)
                                     ((stored-job-next-due job) (- (stored-job-next-due job) now))
                                     (t cap)))))))

;;; --- run now -------------------------------------------------------------------------------

(defun %job-for-run-now (scheduler key)
  (when (%stopping scheduler) (error 'scheduler-stopped))
  (let ((job (store-job (scheduler-store scheduler) key)))
    (unless job (error 'unknown-job :key key))
    (unless (%with-lock (scheduler)
              (gethash (stored-job-function-name job) (%functions scheduler)))
      (error 'unknown-job :key (stored-job-function-name job) :what "registered job function"))
    job))

(defun run-now (scheduler key &key (args nil args-p))
  "Run the stored job KEY now, off its schedule, through the same lease and run log; its next due
time does not change. Returns (VALUES run-id :STARTED), or (VALUES the-current-run-id
:ALREADY-RUNNING) when an instance holds its lease. The run happens on the pool; poll
(STORE-RUN store run-id) for its outcome. ARGS replace the stored arguments for this run."
  (let* ((job (%job-for-run-now scheduler key))
         (id (%start-run scheduler job :run-now :expected-due :any :next-due :keep
                         :args (if args-p args (stored-job-args job)))))
    (if id
        (values id :started)
        (values (let ((now-job (store-job (scheduler-store scheduler) key)))
                  (and now-job (stored-job-current-run now-job)))
                :already-running))))

(defun run-job (scheduler key &key (args nil args-p))
  "As RUN-NOW, but run the job on the calling thread and return its finished JOB-RUN, or NIL when
an instance holds its lease."
  (let* ((job (%job-for-run-now scheduler key))
         (id (%start-run scheduler job :run-now :expected-due :any :next-due :keep
                         :args (if args-p args (stored-job-args job)) :dispatch :inline)))
    (and id (store-run (scheduler-store scheduler) id))))

;;; --- stopping ------------------------------------------------------------------------------

(defun %wait (queue mutex seconds)
  "Wait on QUEUE for at most SECONDS, and return holding MUTEX. SBCL's CONDITION-WAIT may return
from a timeout without taking MUTEX back (its documentation says so, and on Windows it does);
leaving the caller's WITH-MUTEX to release a mutex it does not hold signals an error."
  (unless (sb-thread:condition-wait queue mutex :timeout seconds)
    (unless (sb-thread:holding-mutex-p mutex)
      (sb-thread:grab-mutex mutex))))

(defun stop (scheduler &key (timeout 30))
  "Stop SCHEDULER: stop its driver, start no more runs, make STOP-REQUESTED-P true, and wait up to
TIMEOUT seconds for the runs in progress to finish. Returns :STOPPED, or (VALUES :TIMED-OUT keys)
naming the jobs still running. Those keep their leases, which expire once the process has gone,
and another instance then runs them again."
  (setf (%stopping scheduler) t)
  (let ((driver-stop (shiftf (scheduler-driver-stop scheduler) nil)))
    (when driver-stop (funcall driver-stop)))
  (let ((deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
    (%with-lock (scheduler)
      (loop for left = (/ (- deadline (get-internal-real-time)) internal-time-units-per-second)
            while (and (plusp (hash-table-count (%running scheduler))) (plusp left))
            do (%wait (%idle scheduler) (%lock scheduler) left)))
    (let ((still (%with-lock (scheduler)
                   (loop for k being the hash-keys of (%running scheduler) collect k))))
      (cond (still (values :timed-out still))
            (t (when (and (%own-pool scheduler) (%pool scheduler))
                 (pool:stop-pool (%pool scheduler)))
               :stopped)))))

;;; --- the thread driver (ruling R1) ---------------------------------------------------------

(defun start (scheduler)
  "Tick SCHEDULER once on the calling thread, then from a thread of its own until STOP: sleep
until NEXT-WAKE, or until DEFINE-JOB, SCHEDULE-ONCE or RUN-NOW wakes it, then tick. The first
tick is the caller's so that when START returns, the jobs due at that moment have been started.
Needs nothing beyond SBCL's threads; for a libuv timer instead, see aion/schedule/uv. Returns
SCHEDULER."
  (when (%stopping scheduler) (error 'scheduler-stopped))
  (when (scheduler-driver-stop scheduler) (error "aion/schedule: this scheduler already has a driver."))
  (let ((mutex (sb-thread:make-mutex :name "aion/schedule driver"))
        (queue (sb-thread:make-waitqueue :name "aion/schedule driver"))
        (woken nil)
        (done nil))
    (flet ((wake ()
             (sb-thread:with-mutex (mutex)
               (setf woken t)
               (sb-thread:condition-broadcast queue)))
           (tick-once ()
             (handler-case (tick scheduler)
               (error (e) (log:exception e "aion/schedule: a tick failed")))))
      (setf (scheduler-wake-function scheduler) #'wake)
      (tick-once)
      ;; THREAD-LIFETIME: independent. The driver runs for the scheduler's whole life and must
      ;; not carry the request context of whatever thread happened to call START.
      (let ((thread
              (sb-thread:make-thread
               (lambda ()
                 (loop until (sb-thread:with-mutex (mutex) done)
                       do (let ((delay (handler-case (next-wake scheduler)
                                         (error () (max 1 (floor (scheduler-lease-seconds
                                                                  scheduler)
                                                                 3))))))
                            (sb-thread:with-mutex (mutex)
                              ;; A loop, because a wait may also return when nothing woke it.
                              (loop with deadline = (+ (get-internal-real-time)
                                                       (* delay internal-time-units-per-second))
                                    for left = (/ (- deadline (get-internal-real-time))
                                                  internal-time-units-per-second)
                                    until (or woken done (not (plusp left)))
                                    do (%wait queue mutex left))
                              (setf woken nil))
                            (unless (sb-thread:with-mutex (mutex) done)
                              (tick-once)))))
               :name "aion/schedule driver")))
        (setf (scheduler-driver-stop scheduler)
              (lambda ()
                (sb-thread:with-mutex (mutex)
                  (setf done t)
                  (sb-thread:condition-broadcast queue))
                (setf (scheduler-wake-function scheduler) nil)
                (sb-thread:join-thread thread :default nil))))
      (log:info "aion/schedule: started" :holder (scheduler-holder scheduler) :driver :thread)
      scheduler)))
