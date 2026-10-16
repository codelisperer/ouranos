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

(define-condition job-exists (error)
  ((key :initarg :key :reader job-exists-key))
  (:report (lambda (c s)
             (format s "aion/schedule: a stored job named ~S already exists. Pass :REPLACE T to SCHEDULE-ONCE to replace it."
                     (job-exists-key c)))))

(define-condition unreadable-job-args (error)
  ((args :initarg :args :reader unreadable-job-args-args))
  (:report (lambda (c s)
             (format s "aion/schedule: a one-off job's arguments must be data that can be written and read back (numbers, strings, symbols, lists), and ~S cannot."
                     (unreadable-job-args-args c)))))

(define-condition unreadable-job (error)
  ((key :initarg :key :reader unreadable-job-key)
   (reason :initarg :reason :reader unreadable-job-reason))
  (:report (lambda (c s)
             (format s "aion/schedule: the stored job ~S cannot be read back from its store (~A)."
                     (unreadable-job-key c) (unreadable-job-reason c)))))

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
   ;; The keys of the jobs this instance is starting or running, from admission until the run
   ;; finishes. A key here is admitted to no second run, whatever triggered it.
   (claimed :initform (make-hash-table :test #'equal) :reader %claimed)
   ;; The thread of STOP's last lease renewal, which may outlive the STOP that started it.
   (renewal :initform nil :accessor %renewal)
   (reported :initform (make-hash-table :test #'equal) :reader %reported)
   (lock :initform (sb-thread:make-mutex :name "aion/schedule scheduler") :reader %lock)
   (idle :initform (sb-thread:make-waitqueue :name "aion/schedule idle") :reader %idle)
   (tick-lock :initform (sb-thread:make-mutex :name "aion/schedule tick") :reader %tick-lock)
   (created-at :initarg :created-at :reader %created-at)
   (stopping :initform nil :accessor %stopping)
   ;; Runs between admission and their entry in RUNNING, so STOP waits for them too.
   (starting :initform 0 :accessor %starting)
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

(defun scheduler-stopping-p (scheduler)
  "True once STOP has begun on SCHEDULER. A driver refuses to start then."
  (%stopping scheduler))

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
from now. A stored job that could not be read back is written again, which recovers it. Returns
NAME."
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
            ;; Unchanged: nothing to write. A row the store could not read back is never
            ;; unchanged, because writing it again is how it is recovered.
            ((and (not (stored-job-unreadable old))
                  (equal schedule (stored-job-schedule old))
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

(defun schedule-once (scheduler function-name &key at args key replace)
  "Store a one-off run of the registered job function FUNCTION-NAME, due at the instant AT, with
ARGS, and return its key. ARGS must be data that can be written and read back, because they are
stored; anything else signals UNREADABLE-JOB-ARGS. The job is removed from the store once it has
run and completed; after a failed run it stays, not due, for an operator to run again.

KEY names the job; without it, a fresh key is made. When a job named KEY exists, signals
JOB-EXISTS, unless REPLACE is true: then the job is replaced, and a run of the old one still
going finishes without removing the replacement."
  (check-type function-name string)
  (check-type at (integer 0))
  (unless (%with-lock (scheduler) (gethash function-name (%functions scheduler)))
    (error 'unknown-job :key function-name :what "registered job function"))
  (unless (%readable-p args) (error 'unreadable-job-args :args args))
  (let ((key (or key (format nil "~A/~A" function-name (%new-id))))
        (now (scheduler-clock-now scheduler)))
    (unless (store-put-job (scheduler-store scheduler)
                           (make-stored-job :key key :function-name function-name
                                            :schedule (list :once at) :args args :next-due at
                                            :updated-at now)
                           :replace replace)
      (error 'job-exists :key key))
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
  "Hand THUNK to DISPATCH. Returns NIL when it was accepted, or the reason it was not, as text for
the run log."
  (handler-case
      (cond ((eq dispatch :inline) (funcall thunk) nil)
            ((eq dispatch :pool) (if (pool:try-submit (%ensure-pool scheduler) thunk)
                                     nil
                                     "the worker pool refused the run"))
            ((funcall dispatch thunk) nil)
            (t "the worker pool refused the run"))
    (error (e) (%clip (format nil "the dispatcher signalled ~S: ~A" (type-of e) (%report-of e))))))

(defun %finish (scheduler context job outcome counts error)
  (let ((store (scheduler-store scheduler))
        (key (run-key context))
        (now (scheduler-clock-now scheduler)))
    (unwind-protect
         (handler-case
             (progn
               ;; A one-off that completed is removed by the same store step that checks the
               ;; lease is still this run's, so a late finish never removes another run's job,
               ;; and that the job is still the one this run started from, so a finish never
               ;; removes a job DEFINE-JOB or SCHEDULE-ONCE put in its place meanwhile.
               (unless (store-finish store key (scheduler-holder scheduler) (run-id context)
                                     :now now :outcome outcome :counts counts :error error
                                     :remove-job (and (eq :once (first (stored-job-schedule job)))
                                                      (member outcome '(:completed
                                                                        :completed-with-errors))
                                                      job))
                 (log:warn "aion/schedule: a run finished after its lease was taken over"
                           :job key :run-id (run-id context)))
               (when (%keep-runs scheduler)
                 (store-prune-runs store :key key :keep (%keep-runs scheduler))))
           (error (e)
             (log:exception e "aion/schedule: a run's outcome could not be stored"
                            :job key :run-id (run-id context))))
      (%with-lock (scheduler)
        (when (equal (run-id context) (gethash key (%running scheduler)))
          (remhash key (%running scheduler))
          (remhash key (%claimed scheduler)))
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

(defun %copy-data (value)
  "A copy of VALUE that shares no conses, strings or vectors with it. Other objects are shared."
  (typecase value
    (cons (let* ((head (list nil)) (tail head))
            (loop for rest = value then (cdr rest)
                  while (consp rest)
                  do (setf tail (setf (cdr tail) (list (%copy-data (car rest)))))
                  finally (setf (cdr tail) (%copy-data rest)))
            (cdr head)))
    (string (copy-seq value))
    (vector (let ((copy (copy-seq value)))
              (if (eq t (array-element-type value)) (map-into copy #'%copy-data copy) copy)))
    (t value)))

(defun %admit (scheduler key &key wait)
  "Admit a run of job KEY: count it as starting, so STOP waits for it, and claim KEY, so no second
run of it starts here until this one has finished. Returns true, or NIL and the id of the run
this instance already has of KEY. While that run is still starting it has no id yet: with WAIT,
%ADMIT waits until it has started, and returns its id, or until it did not start, and then tries
to claim KEY again; without WAIT it returns NIL and NIL. Signals SCHEDULER-STOPPED when STOP has
begun. Checked under the scheduler's lock, which STOP takes to set its flag."
  (%with-lock (scheduler)
    (loop
      (when (%stopping scheduler) (error 'scheduler-stopped))
      (let ((run (gethash key (%running scheduler))))
        (cond ((not (gethash key (%claimed scheduler)))
               (setf (gethash key (%claimed scheduler)) t)
               (incf (%starting scheduler))
               (return t))
              ((or run (not wait)) (return (values nil run)))
              ;; %START-RUN broadcasts on %IDLE both when the run starts and when it does not.
              (t (sb-thread:condition-wait (%idle scheduler) (%lock scheduler))))))))

(defun %start-run (scheduler job trigger &key expected-due (expected-run :any) next-due
                                             scheduled-for args (dispatch (%dispatch scheduler))
                                             wait)
  "Take JOB's lease and start a run with TRIGGER. Returns the run id; or NIL when the lease was not
this instance's to take; or NIL and the id of this instance's own run of JOB when it has one
already, which may have outlived its lease. Every trigger comes through here, so that check
covers scheduled runs, retries and operator calls alike. WAIT is %ADMIT's, for a caller that
needs the id of a run that is still starting. Signals SCHEDULER-STOPPED once STOP has begun.

The run gets its own copy of ARGS, so a job function that changes its arguments changes neither
the stored job nor the JOB that %FINISH compares with the stored job."
  (let ((key (stored-job-key job)))
    (multiple-value-bind (admitted local-run) (%admit scheduler key :wait wait)
      (unless admitted (return-from %start-run (values nil local-run)))
      (let ((starting t))
        (unwind-protect
             (let* ((function (%with-lock (scheduler)
                                (gethash (stored-job-function-name job) (%functions scheduler))))
                    (now (scheduler-clock-now scheduler))
                    (run-id (%new-id))
                    (run (store-acquire (scheduler-store scheduler) key
                                        (scheduler-holder scheduler)
                                        :now now
                                        :until (+ now (scheduler-lease-seconds scheduler))
                                        :expected-due expected-due :expected-run expected-run
                                        :next-due next-due :run-id run-id :trigger trigger
                                        :scheduled-for scheduled-for :args args)))
               (when run
                 (let ((context (%make-run-context
                                 :id run-id :key key :trigger trigger
                                 :scheduled-for scheduled-for
                                 :local-date (and scheduled-for
                                                  (%local-date-of-slot (stored-job-schedule job)
                                                                       scheduled-for))
                                 :args (%copy-data args) :scheduler scheduler)))
                   ;; From here the claim is the run's, and %FINISH gives it up.
                   (%with-lock (scheduler)
                     (setf (gethash key (%running scheduler)) run-id
                           starting nil)
                     (decf (%starting scheduler))
                     (sb-thread:condition-broadcast (%idle scheduler)))
                   (log:info "aion/schedule: a run started" :job key :run-id run-id
                                                            :trigger trigger)
                   (let ((refused (%submit scheduler
                                           (lambda () (%execute scheduler context function job))
                                           dispatch)))
                     (when refused (%finish scheduler context job :failed nil refused))))
                 run-id))
          (when starting
            (%with-lock (scheduler)
              (remhash key (%claimed scheduler))
              (decf (%starting scheduler))
              (sb-thread:condition-broadcast (%idle scheduler)))))))))

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

(defun %runnable-here-p (scheduler job)
  "True when this instance could run JOB: it was read back, its function is registered here, and
its schedule is usable. Reports the first failure once."
  (cond ((stored-job-unreadable job)
         (%report-once scheduler job "aion/schedule: a stored job cannot be read back from its store")
         nil)
        ((not (%with-lock (scheduler)
                (gethash (stored-job-function-name job) (%functions scheduler))))
         (%report-once scheduler job "aion/schedule: a stored job names no registered function")
         nil)
        (t (%usable-schedule-p scheduler job))))

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
      (when (%keep-runs scheduler)
        (store-prune-runs store :key (stored-job-key job) :keep (%keep-runs scheduler)))
      (log:info "aion/schedule: a run was skipped, because the previous one is still going"
                :job (stored-job-key job)))))

(defun %consider (scheduler job now)
  "Start a run of JOB if it is this instance's to run at NOW. Returns the run id or NIL."
  (let ((key (stored-job-key job))
        (due (stored-job-next-due job)))
    (cond
      ((not (%runnable-here-p scheduler job)) nil)
      ((%running-locally-p scheduler key)
       (when (and due (<= due now)) (%skip scheduler job now))
       nil)
      ((not (%lease-free-p job now)) nil)
      ;; The lease has expired and still names a run: its instance died mid-run.
      ((stored-job-current-run job)
       ;; EXPECTED-RUN is the abandoned run this tick read, so if another instance has retried
       ;; it since, this acquire changes nothing. The retry gets the abandoned run's slot and
       ;; arguments, which RUN-NOW may have given.
       (let ((old (store-run (scheduler-store scheduler) (stored-job-current-run job))))
         (cond
           ;; A slot gets one retry. A retry whose instance died too is abandoned and not tried
           ;; again, so a job that kills its process cannot take down instance after instance.
           ;; The job's next due time is already the following slot, and stays.
           ((and old (eq :retry (job-run-trigger old)))
            (when (store-abandon (scheduler-store scheduler) key
                                 :now now :expected-run (stored-job-current-run job))
              (log:warn "aion/schedule: a retried run was abandoned too, and is not retried again"
                        :job key :run-id (stored-job-current-run job)))
            nil)
           (t
            (%start-run scheduler job :retry :expected-due due
                                             :expected-run (stored-job-current-run job)
                                             :next-due :keep
                                             :scheduled-for (and old (job-run-scheduled-for old))
                                             :args (if old (job-run-args old) (stored-job-args job)))))))
      ((and due (<= due now))
       (%start-run scheduler job (if (< due (%created-at scheduler)) :catch-up :schedule)
                   :expected-due due :expected-run nil
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
              for id = (unless (%stopping scheduler)
                         (handler-case (%consider scheduler job now)
                           (scheduler-stopped () nil)
                           (error (e)
                             (log:exception e "aion/schedule: a job could not be started"
                                            :job (stored-job-key job))
                             nil)))
              when id collect id)))))

(defun next-wake (scheduler)
  "Seconds until a driver should tick again: when the earliest job falls due or a lease another
instance holds expires, but at least 1 and at most a third of the lease, so this instance's
leases are renewed in time and jobs written by other instances are noticed."
  (let* ((cap (max 1 (floor (scheduler-lease-seconds scheduler) 3)))
         (now (scheduler-clock-now scheduler))
         ;; A job this instance cannot run counts for nothing here: its due time stays in the
         ;; past, and counting it would make the driver tick every second until someone
         ;; removed it.
         (jobs (remove-if-not (lambda (job) (%runnable-here-p scheduler job))
                              (handler-case (store-jobs (scheduler-store scheduler))
                                (error () (return-from next-wake cap))))))
    (when (null jobs) (return-from next-wake cap))
    (max 1 (min cap
                (loop for job in jobs
                      for until = (stored-job-lease-until job)
                      for due = (stored-job-next-due job)
                      minimize (cond ((and due (%running-locally-p scheduler (stored-job-key job)))
                                      ;; Its next slot falls due during its own run, and is
                                      ;; skipped then, not when the run has ended.
                                      (- due now))
                                     ((and (stored-job-lease-holder job) until (>= until now))
                                      (- (1+ until) now))
                                     ((stored-job-current-run job) 0)
                                     ((stored-job-next-due job) (- (stored-job-next-due job) now))
                                     (t cap)))))))

;;; --- run now -------------------------------------------------------------------------------

(defun %job-for-run-now (scheduler key)
  (when (%stopping scheduler) (error 'scheduler-stopped))
  (let ((job (store-job (scheduler-store scheduler) key)))
    (unless job (error 'unknown-job :key key))
    (when (stored-job-unreadable job)
      (error 'unreadable-job :key key :reason (stored-job-unreadable job)))
    (unless (%with-lock (scheduler)
              (gethash (stored-job-function-name job) (%functions scheduler)))
      (error 'unknown-job :key (stored-job-function-name job) :what "registered job function"))
    job))

(defun run-now (scheduler key &key (args nil args-p))
  "Run the stored job KEY now, off its schedule, through the same lease and run log; its next due
time does not change. Returns (VALUES run-id :STARTED), or (VALUES the-current-run-id
:ALREADY-RUNNING) when an instance holds its lease or this instance is still running the job,
even past its lease. When a run of KEY is still starting on this instance, RUN-NOW waits until
it has started and returns its id, or until it did not start and then tries itself. The run
happens on the pool; poll (STORE-RUN store run-id) for its outcome. ARGS replace the stored
arguments for this run."
  (let ((job (%job-for-run-now scheduler key)))
    (multiple-value-bind (id local-run)
        (%start-run scheduler job :run-now :expected-due :any :next-due :keep
                    :args (if args-p args (stored-job-args job)) :wait t)
      (if id
          (values id :started)
          (values (or local-run
                      (let ((now-job (store-job (scheduler-store scheduler) key)))
                        (and now-job (stored-job-current-run now-job))))
                  :already-running)))))

(defun run-job (scheduler key &key (args nil args-p))
  "As RUN-NOW, but run the job on the calling thread and return its finished JOB-RUN, or NIL when
an instance holds its lease or this instance is still running the job."
  (let* ((job (%job-for-run-now scheduler key))
         (id (%start-run scheduler job :run-now :expected-due :any :next-due :keep
                         :args (if args-p args (stored-job-args job)) :dispatch :inline
                         :wait t)))
    (and id (store-run (scheduler-store scheduler) id))))

;;; --- stopping ------------------------------------------------------------------------------

(defun %wait (queue mutex seconds)
  "Wait on QUEUE for at most SECONDS, and return holding MUTEX. SBCL's CONDITION-WAIT may return
from a timeout without taking MUTEX back (its documentation says so, and on Windows it does);
leaving the caller's WITH-MUTEX to release a mutex it does not hold signals an error."
  (unless (sb-thread:condition-wait queue mutex :timeout seconds)
    (unless (sb-thread:holding-mutex-p mutex)
      (sb-thread:grab-mutex mutex))))

(defun %busy-p (scheduler)
  (%with-lock (scheduler)
    (or (plusp (%starting scheduler)) (plusp (hash-table-count (%running scheduler))))))

(defun %renewing-p (scheduler)
  (let ((thread (%with-lock (scheduler) (%renewal scheduler))))
    (and thread (sb-thread:thread-alive-p thread))))

(defun %renew-within (scheduler seconds)
  "Renew this instance's leases, waiting at most SECONDS for the store. A database renewal can wait
far longer than a STOP's timeout, for a pooled connection or a lock, so it runs on a thread of its
own. One still going when SECONDS run out is left to finish, and the next call waits for it
instead of starting a second."
  (let ((thread (%with-lock (scheduler)
                  (let ((old (%renewal scheduler)))
                    (if (and old (sb-thread:thread-alive-p old))
                        old
                        (setf (%renewal scheduler)
                              ;; THREAD-LIFETIME: independent. It ends when the store call
                              ;; returns, which may be after the STOP that started it.
                              (sb-thread:make-thread
                               (lambda () (%renew-leases scheduler (scheduler-clock-now scheduler)))
                               :name "aion/schedule renewal")))))))
    (sb-thread:join-thread thread :timeout seconds :default nil)))

(defparameter +renewal-margin+ 1/20
  "The least time, in seconds, a STOP must have left of its timeout to start a lease renewal
(#728).")

(defun stop (scheduler &key (timeout 30))
  "Stop SCHEDULER: start no more runs, make STOP-REQUESTED-P true, stop its driver, and wait for
the runs in progress to finish, renewing their leases meanwhile. All of it within TIMEOUT
seconds. Returns :STOPPED, or (VALUES :TIMED-OUT keys) naming the jobs still running; KEYS is
empty when it was the driver, or a lease renewal, that did not end in time, and a later STOP
waits for it again. A renewal an earlier STOP left going is waited for too, because it still
uses the store, even when no run is left. Runs
still going keep their leases, which expire once the process has gone, and another instance
then runs them again."
  (let ((deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
    (flet ((left () (/ (- deadline (get-internal-real-time)) internal-time-units-per-second))
           (running-keys ()
             (%with-lock (scheduler)
               (loop for k being the hash-keys of (%running scheduler) collect k))))
      (%with-lock (scheduler) (setf (%stopping scheduler) t))
      (let ((driver-stop (shiftf (scheduler-driver-stop scheduler) nil)))
        (when (and driver-stop (not (funcall driver-stop (max 0.001 (left)))))
          (setf (scheduler-driver-stop scheduler) driver-stop)
          (return-from stop (values :timed-out (running-keys)))))
      ;; TICK starts nothing once STOPPING is set, and renews nothing either, so the drain
      ;; renews the leases itself, every third of the lease, until its runs have finished. A
      ;; renewal is skipped once less than +RENEWAL-MARGIN+ of the timeout is left, and waited
      ;; for only until the timeout passes. A timed wait can return a little before its
      ;; timeout, by a spurious wakeup or a coarse timer, and without the margin the drain
      ;; then started a renewal it had no time left to wait for (#728).
      (let ((slice (max 1 (floor (scheduler-lease-seconds scheduler) 3))))
        (loop while (and (%busy-p scheduler) (plusp (left)))
              do (%with-lock (scheduler)
                   (when (%busy-p scheduler)
                     (%wait (%idle scheduler) (%lock scheduler) (min slice (left)))))
                 (when (and (%busy-p scheduler) (> (left) +renewal-margin+))
                   (%renew-within scheduler (left)))))
      (let ((renewal (%with-lock (scheduler) (%renewal scheduler))))
        (when (and renewal (sb-thread:thread-alive-p renewal))
          (sb-thread:join-thread renewal :timeout (max 0.001 (left)) :default nil)))
      (let ((still (running-keys)))
        (cond ((or still (%busy-p scheduler) (%renewing-p scheduler)) (values :timed-out still))
              (t (when (and (%own-pool scheduler) (%pool scheduler))
                   (pool:stop-pool (%pool scheduler)))
                 :stopped))))))

;;; --- the driver slot ----------------------------------------------------------------------

(defun reserve-driver (scheduler)
  "For a driver's START: take SCHEDULER's driver slot before the first tick, under the lock STOP
takes to set its flag. A STOP that begins while the driver is still starting then finds the slot
taken, and waits, within its timeout, for the driver to say whether it started, instead of
finding no driver and returning while one is about to start. Signals SCHEDULER-STOPPED once
STOP has begun, and an error when the scheduler has a driver.

Returns a function the driver calls exactly once: with its own stop function (of SECONDS,
returning true once the driver has ended) when it has started, or with NIL when it has not, which
frees the slot. A driver that finds SCHEDULER-STOPPING-P true after its first tick starts
nothing and calls it with NIL."
  (let ((settled (sb-thread:make-semaphore :name "aion/schedule driver settled"))
        (stopper (list nil))
        (placeholder nil))
    (setf placeholder
          (lambda (seconds)
            (let ((start (get-internal-real-time)))
              (when (sb-thread:wait-on-semaphore settled :timeout seconds)
                ;; Signalled again, so a later STOP that calls this after a timeout finds it so.
                (sb-thread:signal-semaphore settled)
                (or (null (car stopper))
                    (funcall (car stopper)
                             (max 0.001 (- seconds (/ (- (get-internal-real-time) start)
                                                      internal-time-units-per-second)))))))))
    (%with-lock (scheduler)
      (when (%stopping scheduler) (error 'scheduler-stopped))
      (when (scheduler-driver-stop scheduler)
        (error "aion/schedule: this scheduler already has a driver."))
      (setf (scheduler-driver-stop scheduler) placeholder))
    (lambda (driver-stop)
      (setf (car stopper) driver-stop)
      (unless driver-stop
        (%with-lock (scheduler)
          (when (eq placeholder (scheduler-driver-stop scheduler))
            (setf (scheduler-driver-stop scheduler) nil))))
      (sb-thread:signal-semaphore settled))))

;;; --- the thread driver (ruling R1) ---------------------------------------------------------

(defun start (scheduler)
  "Tick SCHEDULER once on the calling thread, then from a thread of its own until STOP: sleep
until NEXT-WAKE, or until DEFINE-JOB, SCHEDULE-ONCE or RUN-NOW wakes it, then tick. The first
tick is the caller's so that when START returns, the jobs due at that moment have been started.
When STOP begins during that first tick, no thread is started. Needs nothing beyond SBCL's
threads; for a libuv timer instead, see aion/schedule/uv. Returns SCHEDULER."
  (let ((settle (reserve-driver scheduler))
        (settled nil)
        (mutex (sb-thread:make-mutex :name "aion/schedule driver"))
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
      (unwind-protect
           (progn
             (setf (scheduler-wake-function scheduler) #'wake)
             (tick-once)
             (unless (scheduler-stopping-p scheduler)
               ;; THREAD-LIFETIME: independent. The driver runs for the scheduler's whole life
               ;; and must not carry the request context of whatever thread called START.
               (let ((thread
                       (sb-thread:make-thread
                        (lambda ()
                          (loop until (sb-thread:with-mutex (mutex) done)
                                do (let ((delay (handler-case (next-wake scheduler)
                                                  (error () (max 1 (floor (scheduler-lease-seconds
                                                                           scheduler)
                                                                          3))))))
                                     (sb-thread:with-mutex (mutex)
                                       ;; A loop, because a wait may also return when nothing
                                       ;; woke it.
                                       (loop with deadline = (+ (get-internal-real-time)
                                                                (* delay
                                                                   internal-time-units-per-second))
                                             for left = (/ (- deadline (get-internal-real-time))
                                                           internal-time-units-per-second)
                                             until (or woken done (not (plusp left)))
                                             do (%wait queue mutex left))
                                       (setf woken nil))
                                     (unless (sb-thread:with-mutex (mutex) done)
                                       (tick-once)))))
                        :name "aion/schedule driver")))
                 (setf settled t)
                 (funcall settle
                          ;; Ends the driver; true once its thread has ended, within SECONDS.
                          (lambda (seconds)
                            (sb-thread:with-mutex (mutex)
                              (setf done t)
                              (sb-thread:condition-broadcast queue))
                            (setf (scheduler-wake-function scheduler) nil)
                            (sb-thread:join-thread thread :timeout seconds :default nil)
                            (not (sb-thread:thread-alive-p thread))))
                 (log:info "aion/schedule: started" :holder (scheduler-holder scheduler)
                                                    :driver :thread))))
        (unless settled
          (setf (scheduler-wake-function scheduler) nil)
          (funcall settle nil))))
    scheduler))
