;;;; jobs.lisp --- mnemosyne/jobs: aion/schedule's job store in a database (#689).
;;;;
;;;; The same protocol as aion/schedule's in-memory store, so an app's schedules, leases and run
;;;; log survive a redeploy and are shared by every instance that reads the same database. An aux
;;;; system, so mnemosyne's core does not depend on the scheduler. Postgres and SQLite, with plain
;;;; SQL that both run.
;;;;
;;;; THE LEASE IS A CONDITIONAL UPDATE. STORE-ACQUIRE updates the job row only where the lease is
;;;; free or expired and the next due time and current run are the ones it read, and takes the
;;;; affected-row count as the answer, as hyperion/auth-db does for its own conditional writes.
;;;; Two instances that read the same row both send the update; the database applies one, and the
;;;; other's WHERE no longer matches, so it changes nothing and gets 0.
;;;;
;;;; THE TABLES are created by ENSURE-SCHEMA, or by an app's own migrations from JOBS-DDL. Without
;;;; :ENSURE, MAKE-DB-JOB-STORE reads both tables once and signals MISSING-JOB-TABLES when it
;;;; cannot, so a missing migration stops the app at start rather than at the first due job.

(cl:defpackage #:mnemosyne/jobs
  (:use #:cl)
  (:local-nicknames (#:s #:aion/schedule)
                    (#:conn #:mnemosyne/conn)
                    (#:param #:mnemosyne/param))
  (:documentation
   "An AION/SCHEDULE:JOB-STORE in a database through mnemosyne (#689). MAKE-DB-JOB-STORE over a
    connection or a pool; :ENSURE creates the tables, and JOBS-DDL gives the statements for an
    app's own migrations.")
  (:export #:db-job-store #:make-db-job-store #:ensure-schema #:jobs-ddl
           #:missing-job-tables #:missing-job-tables-tables
           #:*jobs-table* #:*runs-table*))

(in-package #:mnemosyne/jobs)

(defvar *jobs-table* "aion_jobs" "Default table name for stored jobs.")
(defvar *runs-table* "aion_job_runs" "Default table name for job runs.")

(define-condition missing-job-tables (error)
  ((tables :initarg :tables :reader missing-job-tables-tables)
   (cause :initarg :cause :reader %missing-job-tables-cause))
  (:report (lambda (c s)
             (format s "mnemosyne/jobs: the job tables ~{~A~^ and ~} cannot be read (~A). Add the statements from MNEMOSYNE/JOBS:JOBS-DDL to the app's migrations, or pass :ENSURE T to MAKE-DB-JOB-STORE."
                     (missing-job-tables-tables c)
                     (type-of (%missing-job-tables-cause c))))))

(defclass db-job-store (s:job-store)
  ((source :initarg :source :reader store-source)
   (jobs :initarg :jobs :reader jobs-table)
   (runs :initarg :runs :reader runs-table)
   (lock :initform (sb-thread:make-mutex :name "mnemosyne/jobs") :reader store-lock))
  (:documentation "Jobs and their runs in two tables, over a mnemosyne connection or pool."))

(defun call-with-connection (store function)
  "Call FUNCTION with a connection for one operation of STORE: the store's connection under its
lock, or one borrowed from its pool."
  (let ((source (store-source store)))
    (if (conn:poolp source)
        (conn:with-connection (c source) (funcall function c))
        (sb-thread:with-recursive-lock ((store-lock store)) (funcall function source)))))

(defmacro with-connection ((var store) &body body)
  `(call-with-connection ,store (lambda (,var) ,@body)))

(defun %check-table-name (table)
  (unless (and (stringp table) (plusp (length table))
               (every (lambda (ch) (or (alphanumericp ch) (char= ch #\_))) table))
    (error "mnemosyne/jobs: a table name is letters, digits and underscores, not ~S" table))
  table)

(defun jobs-ddl (&key (jobs-table *jobs-table*) (runs-table *runs-table*))
  "The statements that create the two tables and the runs index, the same on Postgres and SQLite,
as a list, for an app that folds them into its own migrations instead of calling ENSURE-SCHEMA."
  (let ((jobs (%check-table-name jobs-table))
        (runs (%check-table-name runs-table)))
    (list
     (format nil "CREATE TABLE IF NOT EXISTS ~A (job_key TEXT PRIMARY KEY, function_name TEXT NOT NULL, schedule TEXT NOT NULL, args TEXT, next_due BIGINT, lease_holder TEXT, lease_until BIGINT, current_run TEXT, updated_at BIGINT NOT NULL)" jobs)
     (format nil "CREATE TABLE IF NOT EXISTS ~A (id TEXT PRIMARY KEY, job_key TEXT NOT NULL, holder TEXT, run_trigger TEXT NOT NULL, scheduled_for BIGINT, started_at BIGINT NOT NULL, finished_at BIGINT, outcome TEXT NOT NULL, counts TEXT, error TEXT, args TEXT)" runs)
     (format nil "CREATE INDEX IF NOT EXISTS ~A_by_job ON ~A (job_key, started_at)" runs runs))))

(defun ensure-schema (store)
  "Create STORE's tables and index when they are absent. Returns STORE."
  (with-connection (c store)
    (dolist (statement (jobs-ddl :jobs-table (jobs-table store) :runs-table (runs-table store)))
      (conn:exec c statement)))
  store)

(defun %check-tables (store)
  (handler-case
      (with-connection (c store)
        (conn:query c (format nil "SELECT job_key, function_name, schedule, args, next_due, lease_holder, lease_until, current_run, updated_at FROM ~A WHERE 1 = 0" (jobs-table store)))
        (conn:query c (format nil "SELECT id, job_key, holder, run_trigger, scheduled_for, started_at, finished_at, outcome, counts, error, args FROM ~A WHERE 1 = 0" (runs-table store))))
    (error (e)
      (error 'missing-job-tables :tables (list (jobs-table store) (runs-table store)) :cause e))))

(defun make-db-job-store (source &key (jobs-table *jobs-table*) (runs-table *runs-table*) ensure)
  "A job store in JOBS-TABLE and RUNS-TABLE over SOURCE, a mnemosyne connection or pool. With
ENSURE, creates the tables; without it, signals MISSING-JOB-TABLES when they cannot be read."
  (let ((store (make-instance 'db-job-store :source source
                                            :jobs (%check-table-name jobs-table)
                                            :runs (%check-table-name runs-table))))
    (if ensure (ensure-schema store) (%check-tables store))
    store))

;;; --- rows -------------------------------------------------------------------------------

(defparameter +triggers+ '(:schedule :catch-up :retry :run-now))
(defparameter +outcomes+
  '(:running :completed :completed-with-errors :failed :skipped :abandoned))

(defun %word (keyword) (and keyword (string-downcase (symbol-name keyword))))

(defun %keyword (text known)
  "The keyword in KNOWN that TEXT names. Never interns: a row is data from the database."
  (and text (find text known :test #'string-equal)))

(defun %int (value)
  (etypecase value
    (null nil)
    (integer value)
    (string (parse-integer value))))

(defun %row->job (row)
  (s:make-stored-job :key (param:row-value row :job_key)
                     :function-name (param:row-value row :function_name)
                     :schedule (s:read-data (param:row-value row :schedule))
                     :args (s:read-data (param:row-value row :args))
                     :next-due (%int (param:row-value row :next_due))
                     :lease-holder (param:row-value row :lease_holder)
                     :lease-until (%int (param:row-value row :lease_until))
                     :current-run (param:row-value row :current_run)
                     :updated-at (%int (param:row-value row :updated_at))))

(defun %row->run (row)
  (s:make-job-run :id (param:row-value row :id)
                  :job-key (param:row-value row :job_key)
                  :holder (param:row-value row :holder)
                  :trigger (%keyword (param:row-value row :run_trigger) +triggers+)
                  :scheduled-for (%int (param:row-value row :scheduled_for))
                  :started-at (%int (param:row-value row :started_at))
                  :finished-at (%int (param:row-value row :finished_at))
                  :outcome (%keyword (param:row-value row :outcome) +outcomes+)
                  :counts (s:read-data (param:row-value row :counts))
                  :error (param:row-value row :error)
                  :args (s:read-data (param:row-value row :args))))

(defun %job-columns () "job_key, function_name, schedule, args, next_due, lease_holder, lease_until, current_run, updated_at")
(defun %run-columns () "id, job_key, holder, run_trigger, scheduled_for, started_at, finished_at, outcome, counts, error, args")

(defun %equals (column value)
  "A WHERE term matching COLUMN to VALUE, and the parameters it binds. `= NULL' is never true in
SQL, so a NIL value is matched with IS NULL and binds nothing."
  (if (null value)
      (values (format nil "~A IS NULL" column) '())
      (values (format nil "~A = ?" column) (list value))))

;;; --- the protocol -----------------------------------------------------------------------

(defmethod s:store-jobs ((store db-job-store))
  (mapcar #'%row->job
          (with-connection (c store)
            (conn:query c (format nil "SELECT ~A FROM ~A ORDER BY job_key" (%job-columns)
                                  (jobs-table store))))))

(defmethod s:store-job ((store db-job-store) key)
  (let ((row (first (with-connection (c store)
                      (conn:query c (format nil "SELECT ~A FROM ~A WHERE job_key = ?"
                                            (%job-columns) (jobs-table store))
                                  key)))))
    (and row (%row->job row))))

(defun %insert-job (c store job)
  "Insert JOB unless its key exists. Returns true when it inserted."
  (plusp (conn:exec c (format nil "INSERT INTO ~A (job_key, function_name, schedule, args, next_due, updated_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (job_key) DO NOTHING"
                              (jobs-table store))
                    (s:stored-job-key job) (s:stored-job-function-name job)
                    (s:write-data (s:stored-job-schedule job)) (s:write-data (s:stored-job-args job))
                    (s:stored-job-next-due job) (s:stored-job-updated-at job))))

(defmethod s:store-put-job ((store db-job-store) job &key replace)
  (with-connection (c store)
    (or (and replace
             (plusp (conn:exec c (format nil "UPDATE ~A SET function_name = ?, schedule = ?, args = ?, next_due = ?, updated_at = ? WHERE job_key = ?"
                                         (jobs-table store))
                               (s:stored-job-function-name job)
                               (s:write-data (s:stored-job-schedule job))
                               (s:write-data (s:stored-job-args job))
                               (s:stored-job-next-due job) (s:stored-job-updated-at job)
                               (s:stored-job-key job))))
        (%insert-job c store job))))

(defmethod s:store-remove-job ((store db-job-store) key)
  (with-connection (c store)
    (plusp (conn:exec c (format nil "DELETE FROM ~A WHERE job_key = ?" (jobs-table store)) key))))

(defmethod s:store-acquire ((store db-job-store) key holder
                            &key now until expected-due (expected-run :any) next-due run-id
                              trigger scheduled-for args)
  (with-connection (c store)
    (conn:with-transaction (c)
      (let ((row (first (conn:query c (format nil "SELECT next_due, current_run FROM ~A WHERE job_key = ?"
                                              (jobs-table store))
                                    key))))
        (when (and row
                   (or (eq expected-run :any)
                       (equal expected-run (param:row-value row :current_run))))
          ;; The UPDATE below matches the current run read here, so a run that changed since the
          ;; read (another instance took over, or the run finished) makes it change nothing.
          (let ((old-run (param:row-value row :current_run)))
            (multiple-value-bind (run-term run-params) (%equals "current_run" old-run)
              (multiple-value-bind (due-term due-params)
                  (if (eq expected-due :any)
                      (values "1 = 1" '())
                      (%equals "next_due" expected-due))
                (let* ((keep (eq next-due :keep))
                       (sql (format nil "UPDATE ~A SET lease_holder = ?, lease_until = ?, current_run = ?, updated_at = ?~:[, next_due = ?~;~] WHERE job_key = ? AND (lease_holder IS NULL OR lease_until IS NULL OR lease_until < ?) AND ~A AND ~A"
                                    (jobs-table store) keep due-term run-term))
                       (params (append (list holder until run-id now)
                                       (unless keep (list next-due))
                                       (list key now)
                                       due-params run-params)))
                  (when (plusp (apply #'conn:exec c sql params))
                    (when old-run
                      (conn:exec c (format nil "UPDATE ~A SET outcome = 'abandoned', finished_at = ? WHERE id = ? AND outcome = 'running'"
                                           (runs-table store))
                                 now old-run))
                    (let ((run (s:make-job-run :id run-id :job-key key :holder holder
                                               :trigger trigger :scheduled-for scheduled-for
                                               :started-at now :outcome :running
                                               :args args)))
                      (%insert-run c store run)
                      run)))))))))))

(defmethod s:store-advance ((store db-job-store) key &key expected-due next-due)
  (multiple-value-bind (term params) (%equals "next_due" expected-due)
    (with-connection (c store)
      (plusp (apply #'conn:exec c (format nil "UPDATE ~A SET next_due = ? WHERE job_key = ? AND ~A"
                                          (jobs-table store) term)
                    next-due key params)))))

(defmethod s:store-renew ((store db-job-store) key holder run-id until)
  (with-connection (c store)
    (plusp (conn:exec c (format nil "UPDATE ~A SET lease_until = ? WHERE job_key = ? AND lease_holder = ? AND current_run = ?"
                                (jobs-table store))
                      until key holder run-id))))

(defmethod s:store-finish ((store db-job-store) key holder run-id
                           &key now outcome counts error remove-job)
  (with-connection (c store)
    (conn:with-transaction (c)
      ;; The job row first, then the run row: the order STORE-ACQUIRE takes them in, so a
      ;; takeover and a late finish on Postgres wait for each other instead of deadlocking.
      (let ((owned (plusp (if remove-job
                              (conn:exec c (format nil "DELETE FROM ~A WHERE job_key = ? AND lease_holder = ? AND current_run = ?"
                                                   (jobs-table store))
                                         key holder run-id)
                              (conn:exec c (format nil "UPDATE ~A SET lease_holder = NULL, lease_until = NULL, current_run = NULL, updated_at = ? WHERE job_key = ? AND lease_holder = ? AND current_run = ?"
                                                   (jobs-table store))
                                         now key holder run-id)))))
        (conn:exec c (format nil "UPDATE ~A SET outcome = ?, finished_at = ?, counts = ?, error = ? WHERE id = ?"
                             (runs-table store))
                   (%word outcome) now (s:write-data counts) error run-id)
        owned))))

(defun %insert-run (c store run)
  (conn:exec c (format nil "INSERT INTO ~A (~A) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                       (runs-table store) (%run-columns))
             (s:job-run-id run) (s:job-run-job-key run) (s:job-run-holder run)
             (%word (s:job-run-trigger run)) (s:job-run-scheduled-for run)
             (s:job-run-started-at run) (s:job-run-finished-at run)
             (%word (s:job-run-outcome run)) (s:write-data (s:job-run-counts run))
             (s:job-run-error run) (s:write-data (s:job-run-args run))))

(defmethod s:store-record-run ((store db-job-store) run)
  (with-connection (c store) (%insert-run c store run))
  run)

(defmethod s:store-runs ((store db-job-store) key &key limit)
  (check-type limit (or null (integer 0)))
  (mapcar #'%row->run
          (with-connection (c store)
            (conn:query c (format nil "SELECT ~A FROM ~A WHERE job_key = ? ORDER BY started_at DESC, id DESC~@[ LIMIT ~D~]"
                                  (%run-columns) (runs-table store) limit)
                        key))))

(defmethod s:store-run ((store db-job-store) run-id)
  (let ((row (first (with-connection (c store)
                      (conn:query c (format nil "SELECT ~A FROM ~A WHERE id = ?"
                                            (%run-columns) (runs-table store))
                                  run-id)))))
    (and row (%row->run row))))

(defmethod s:store-prune-runs ((store db-job-store) &key key before keep)
  (check-type keep (or null (integer 0)))
  (with-connection (c store)
    (conn:with-transaction (c)
      (let ((deleted 0))
        (when before
          (multiple-value-bind (term params) (if key (%equals "job_key" key) (values "1 = 1" '()))
            (incf deleted (apply #'conn:exec c
                                 (format nil "DELETE FROM ~A WHERE started_at < ? AND outcome <> 'running' AND ~A"
                                         (runs-table store) term)
                                 before params))))
        (when keep
          ;; Ranking a job's runs is portable SQL only through a window function, which older
          ;; SQLite builds lack, so the newest KEEP of each job are chosen here.
          (let ((rows (if key
                          (conn:query c (format nil "SELECT id, job_key, outcome FROM ~A WHERE job_key = ? ORDER BY job_key, started_at DESC, id DESC"
                                                (runs-table store))
                                      key)
                          (conn:query c (format nil "SELECT id, job_key, outcome FROM ~A ORDER BY job_key, started_at DESC, id DESC"
                                                (runs-table store)))))
                (seen (make-hash-table :test #'equal)))
            (dolist (row rows)
              (let ((i (incf (gethash (param:row-value row :job_key) seen -1))))
                (when (and (>= i keep) (not (equal "running" (param:row-value row :outcome))))
                  (incf deleted (conn:exec c (format nil "DELETE FROM ~A WHERE id = ?"
                                                     (runs-table store))
                                           (param:row-value row :id))))))))
        deleted))))
