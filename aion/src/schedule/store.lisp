;;;; store.lisp --- the job store protocol, and the in-memory store (#689).
;;;;
;;;; A store keeps each job's schedule, next due time and lease, and a log of its runs. Several
;;;; scheduler instances may share one store; the lease is how only one of them runs a slot.
;;;; The store never reads a clock: every method that needs the time is given NOW, so that the
;;;; instances' injected clocks are the only clocks (ruling R3 on #689).

(in-package #:aion/schedule)

(defstruct stored-job
  "A job as the store keeps it. KEY is unique; FUNCTION-NAME names the registered function that
runs it; ARGS are a one-off job's arguments. NEXT-DUE is NIL when nothing is due (a one-off that
has run). LEASE-HOLDER and LEASE-UNTIL are the lease; CURRENT-RUN is the run holding it.
UNREADABLE is NIL, or the reason a database store could not read the job's schedule or arguments
back; the scheduler then reports the job once and leaves it alone."
  (key "" :type string)
  (function-name "" :type string)
  schedule args next-due lease-holder lease-until current-run (updated-at 0) unreadable)

(defstruct job-run
  "One run of a job. TRIGGER is :SCHEDULE, :CATCH-UP, :RETRY or :RUN-NOW. OUTCOME is :RUNNING,
:COMPLETED, :COMPLETED-WITH-ERRORS, :FAILED, :SKIPPED or :ABANDONED. COUNTS is the plist the job
returned; ERROR is a string. ARGS are the arguments the run was started with, which a retry of it
reuses."
  (id "" :type string)
  (job-key "" :type string)
  holder trigger scheduled-for started-at finished-at outcome counts error args)

(defclass job-store () ()
  (:documentation "Where a scheduler keeps its jobs, their leases and their runs."))

(defgeneric store-jobs (store)
  (:documentation "Every stored job, as fresh STORED-JOB structures."))

(defgeneric store-job (store key)
  (:documentation "The stored job KEY, or NIL."))

(defgeneric store-put-job (store job &key replace)
  (:documentation "Write JOB's schedule, function name, arguments and next due time, leaving any
lease alone. Without REPLACE, only when no job has JOB's key. Returns true when it wrote."))

(defgeneric store-remove-job (store key)
  (:documentation "Remove the job KEY. Its runs stay. Returns true when there was one."))

(defgeneric store-acquire (store key holder &key now until expected-due expected-run next-due
                                                 run-id trigger scheduled-for args)
  (:documentation "Take the lease on job KEY for HOLDER until UNTIL and start a run, as one
atomic step, or return NIL and change nothing.

The lease is taken only when it is free or expired at NOW (its LEASE-UNTIL is before NOW), only
when the job's NEXT-DUE equals EXPECTED-DUE, and only when its CURRENT-RUN equals EXPECTED-RUN
(NIL for none); either may be :ANY, the default for EXPECTED-RUN. NEXT-DUE becomes the new next
due time, unless it is :KEEP. A run the expired lease still names is marked :ABANDONED, finished
at NOW. Returns the new :RUNNING JOB-RUN, with id RUN-ID and arguments ARGS."))

(defgeneric store-abandon (store key &key now expected-run)
  (:documentation "When the lease on job KEY has expired at NOW and its CURRENT-RUN is still
EXPECTED-RUN, mark that run :ABANDONED, finished at NOW, and free the lease without starting a
run; the job's NEXT-DUE is left as it is. One atomic step. Returns true when it changed."))

(defgeneric store-advance (store key &key expected-due next-due)
  (:documentation "Set job KEY's next due time to NEXT-DUE when it is EXPECTED-DUE, without
touching its lease. Returns true when it changed."))

(defgeneric store-renew (store key holder run-id until)
  (:documentation "Extend the lease on job KEY to UNTIL when HOLDER holds it for RUN-ID. Returns
true when it did; NIL means the lease is no longer this run's."))

(defgeneric store-finish (store key holder run-id &key now outcome counts error remove-job)
  (:documentation "Finish run RUN-ID at NOW with OUTCOME, COUNTS and ERROR, and release the lease
on job KEY when HOLDER still holds it for that run. REMOVE-JOB is NIL or the STORED-JOB the run
was started from: when it is given, and the stored job's function name, schedule and arguments
are still that job's, the job is removed instead of released, in the same step. So a job whose
lease has passed to another run is never removed, and neither is a job that was replaced while
the run was going (DEFINE-JOB turning a one-off into a recurring job, say): that one is released
and kept. The run is finished either way. Returns true when the lease was still this run's."))

(defgeneric store-record-run (store run)
  (:documentation "Add RUN, which holds no lease (a :SKIPPED run). Returns RUN."))

(defgeneric store-runs (store key &key limit)
  (:documentation "Job KEY's runs, newest first, at most LIMIT of them when LIMIT is given."))

(defgeneric store-run (store run-id)
  (:documentation "The run RUN-ID, or NIL."))

(defgeneric store-prune-runs (store &key key before keep)
  (:documentation "Delete finished runs: those started before BEFORE, and those beyond the newest
KEEP of each job. KEY limits it to one job. A run still :RUNNING is never deleted. Returns how
many were deleted."))

;;; --- text forms for a database -----------------------------------------------------------

(defun write-data (value)
  "VALUE as text that READ-DATA reads back as an EQUAL value, or NIL for NIL. Signals an error
when VALUE cannot be written readably, so a store refuses it rather than keeping something it
cannot read."
  (and value
       (with-standard-io-syntax
         ;; *READ-EVAL* NIL as well: with it true, SBCL writes a hash table or a structure
         ;; "readably" as a #. form, which READ-DATA refuses to evaluate.
         (let ((*package* (find-package :keyword))
               (*print-readably* t)
               (*read-eval* nil))
           (prin1-to-string value)))))

(defun read-data (text)
  "The value TEXT was written from by WRITE-DATA; NIL for NIL. Never evaluates anything."
  (and text
       (with-standard-io-syntax
         ;; *PRINT-READABLY* NIL: WITH-STANDARD-IO-SYNTAX makes it true, and a handler that prints
         ;; a reader error signalled here (a test framework's, or a logger's) would otherwise get
         ;; PRINT-NOT-READABLE instead of the error.
         (let ((*package* (find-package :keyword))
               (*read-eval* nil)
               (*print-readably* nil))
           (values (read-from-string text))))))

;;; --- the in-memory store ---------------------------------------------------------------

(defclass memory-job-store (job-store)
  ((jobs :initform (make-hash-table :test #'equal) :reader %jobs)
   (runs :initform (make-hash-table :test #'equal) :reader %runs)
   (lock :initform (sb-thread:make-mutex :name "aion/schedule memory store") :reader %lock))
  (:documentation "A job store in this process's memory, for tests and single-process apps. Its
contents end with the process, so it does not keep schedules across a redeploy."))

(defun make-memory-job-store () (make-instance 'memory-job-store))

(defmacro %with-store-lock ((store) &body body)
  `(sb-thread:with-recursive-lock ((%lock ,store)) ,@body))

(defmethod store-jobs ((store memory-job-store))
  (%with-store-lock (store)
    (loop for job being the hash-values of (%jobs store) collect (copy-stored-job job))))

(defmethod store-job ((store memory-job-store) key)
  (%with-store-lock (store)
    (let ((job (gethash key (%jobs store)))) (and job (copy-stored-job job)))))

(defmethod store-put-job ((store memory-job-store) job &key replace)
  (%with-store-lock (store)
    (let ((old (gethash (stored-job-key job) (%jobs store))))
      (cond ((null old)
             (setf (gethash (stored-job-key job) (%jobs store))
                   (let ((new (copy-stored-job job)))
                     (setf (stored-job-lease-holder new) nil (stored-job-lease-until new) nil
                           (stored-job-current-run new) nil)
                     new))
             t)
            (replace
             ;; UNREADABLE too: a database store's replacement rewrites the columns it could not
             ;; read, so the job is readable again, and this store behaves the same way.
             (setf (stored-job-function-name old) (stored-job-function-name job)
                   (stored-job-schedule old) (stored-job-schedule job)
                   (stored-job-args old) (stored-job-args job)
                   (stored-job-next-due old) (stored-job-next-due job)
                   (stored-job-updated-at old) (stored-job-updated-at job)
                   (stored-job-unreadable old) (stored-job-unreadable job))
             t)
            (t nil)))))

(defmethod store-remove-job ((store memory-job-store) key)
  (%with-store-lock (store) (remhash key (%jobs store))))

(defun %lease-free-p (job now)
  (or (null (stored-job-lease-holder job))
      (null (stored-job-lease-until job))
      (< (stored-job-lease-until job) now)))

(defmethod store-acquire ((store memory-job-store) key holder
                          &key now until expected-due (expected-run :any) next-due run-id trigger
                            scheduled-for args)
  (%with-store-lock (store)
    (let ((job (gethash key (%jobs store))))
      (when (and job
                 (%lease-free-p job now)
                 (or (eq expected-due :any) (eql expected-due (stored-job-next-due job)))
                 (or (eq expected-run :any) (equal expected-run (stored-job-current-run job))))
        (let ((old-run (and (stored-job-current-run job)
                            (gethash (stored-job-current-run job) (%runs store)))))
          (when (and old-run (eq :running (job-run-outcome old-run)))
            (setf (job-run-outcome old-run) :abandoned (job-run-finished-at old-run) now)))
        (setf (stored-job-lease-holder job) holder
              (stored-job-lease-until job) until
              (stored-job-current-run job) run-id
              (stored-job-updated-at job) now)
        (unless (eq next-due :keep) (setf (stored-job-next-due job) next-due))
        (let ((run (make-job-run :id run-id :job-key key :holder holder :trigger trigger
                                 :scheduled-for scheduled-for :started-at now
                                 :outcome :running :args args)))
          (setf (gethash run-id (%runs store)) run)
          (copy-job-run run))))))

(defmethod store-abandon ((store memory-job-store) key &key now expected-run)
  (%with-store-lock (store)
    (let ((job (gethash key (%jobs store))))
      (when (and job expected-run
                 (%lease-free-p job now)
                 (equal expected-run (stored-job-current-run job)))
        (let ((run (gethash expected-run (%runs store))))
          (when (and run (eq :running (job-run-outcome run)))
            (setf (job-run-outcome run) :abandoned (job-run-finished-at run) now)))
        (setf (stored-job-lease-holder job) nil (stored-job-lease-until job) nil
              (stored-job-current-run job) nil (stored-job-updated-at job) now)
        t))))

(defmethod store-advance ((store memory-job-store) key &key expected-due next-due)
  (%with-store-lock (store)
    (let ((job (gethash key (%jobs store))))
      (when (and job (eql expected-due (stored-job-next-due job)))
        (setf (stored-job-next-due job) next-due)
        t))))

(defmethod store-renew ((store memory-job-store) key holder run-id until)
  (%with-store-lock (store)
    (let ((job (gethash key (%jobs store))))
      (when (and job (equal holder (stored-job-lease-holder job))
                 (equal run-id (stored-job-current-run job)))
        (setf (stored-job-lease-until job) until)
        t))))

(defun %same-definition-p (a b)
  (and (equal (stored-job-function-name a) (stored-job-function-name b))
       (equal (stored-job-schedule a) (stored-job-schedule b))
       (equal (stored-job-args a) (stored-job-args b))))

(defmethod store-finish ((store memory-job-store) key holder run-id
                         &key now outcome counts error remove-job)
  (%with-store-lock (store)
    (let ((run (gethash run-id (%runs store)))
          (job (gethash key (%jobs store))))
      (when run
        (setf (job-run-outcome run) outcome (job-run-finished-at run) now
              (job-run-counts run) counts (job-run-error run) error))
      (when (and job (equal holder (stored-job-lease-holder job))
                 (equal run-id (stored-job-current-run job)))
        (if (and remove-job (%same-definition-p remove-job job))
            (remhash key (%jobs store))
            (setf (stored-job-lease-holder job) nil (stored-job-lease-until job) nil
                  (stored-job-current-run job) nil (stored-job-updated-at job) now))
        t))))

(defmethod store-record-run ((store memory-job-store) run)
  (%with-store-lock (store)
    (setf (gethash (job-run-id run) (%runs store)) (copy-job-run run))
    run))

(defun %newest-first (runs)
  ;; Ids are v6 UUIDs, ordered by the time they were minted, which breaks a tie between two
  ;; runs started in the same second.
  (sort runs (lambda (a b)
               (let ((sa (job-run-started-at a)) (sb (job-run-started-at b)))
                 (or (> sa sb) (and (= sa sb) (string> (job-run-id a) (job-run-id b))))))))

(defmethod store-runs ((store memory-job-store) key &key limit)
  (%with-store-lock (store)
    (let ((runs (%newest-first
                 (loop for run being the hash-values of (%runs store)
                       when (equal key (job-run-job-key run)) collect (copy-job-run run)))))
      (if limit (subseq runs 0 (min limit (length runs))) runs))))

(defmethod store-run ((store memory-job-store) run-id)
  (%with-store-lock (store)
    (let ((run (gethash run-id (%runs store)))) (and run (copy-job-run run)))))

(defmethod store-prune-runs ((store memory-job-store) &key key before keep)
  (%with-store-lock (store)
    (let ((by-job (make-hash-table :test #'equal))
          (doomed '()))
      (loop for run being the hash-values of (%runs store)
            when (or (null key) (equal key (job-run-job-key run)))
              do (push run (gethash (job-run-job-key run) by-job)))
      (loop for runs being the hash-values of by-job
            do (loop for run in (%newest-first runs)
                     for i from 0
                     unless (eq :running (job-run-outcome run))
                       when (or (and before (< (job-run-started-at run) before))
                                (and keep (>= i keep)))
                         do (push (job-run-id run) doomed)))
      (dolist (id doomed) (remhash id (%runs store)))
      (length doomed))))
