;;;; migrate.lisp --- the migration runner (CL shell over backend + conn).
;;;;
;;;; Apply an ordered set of Lisp-defined, typed MIGRATIONs (mnemosyne/backend:Migration
;;;; -- id/description/up/down) to a connection: ensure the `schema_migrations` tracking
;;;; table, run each *pending* up-SQL in id order (each in its own transaction, then
;;;; record the id), and stop. Idempotent -- already-applied migrations are skipped, so
;;;; re-running is a no-op. ROLLBACK runs down-SQL newest-first. Small on purpose: no
;;;; framework, no globals. The typed spec for "which are pending" is
;;;; mnemosyne/backend:pending; PENDING here is its operational CL mirror over the DB.

(in-package #:mnemosyne/migrate)

(defun %col1 (row)
  "The value of the single selected column in a CL-DBI result ROW (a plist).

DELIBERATELY POSITIONAL, AND NOT TO BE CONVERTED TO MNEMOSYNE/PARAM:ROW-VALUE (pre-publication issue 489). It
avoids the driver's column-name casing by never naming a column -- and here there is no name
worth relying on: every caller selects an unaliased `count(*)', whose result column is named
`count' by Postgres and `count(*)' by SQLite. Reading it by key would put a backend-specific
spelling into code whose whole job is not to have one. Not naming a column is stronger than
naming it carefully."
  (second row))

(defun applied-ids (connection)
  "The migration ids already recorded in `schema_migrations`, oldest first (ids are
sortable, e.g. \"20260722_001_...\")."
  (mapcar #'%col1
          (conn:query connection "SELECT id FROM schema_migrations ORDER BY id")))

(defun pending (connection migrations)
  "The MIGRATIONS (mnemosyne/backend:Migration values) not yet in `schema_migrations`,
order preserved. Operational mirror of the typed mnemosyne/backend:pending."
  (let ((done (applied-ids connection)))
    (remove-if (lambda (m) (member (be:migration-id m) done :test #'string=)) migrations)))

(defun migrate (backend connection migrations)
  "Ensure `schema_migrations` exists (DDL from BACKEND), then apply every PENDING
migration's up-SQL in order -- each in its own transaction, recording its id. Idempotent.
Returns the list of ids applied this run (NIL when already up to date).

Logging (#1046): each applied migration is one DEBUG line, \"migrate: applied\", with its id,
description and milliseconds. A call that had migrations to apply ends with one INFO line,
\"migrate: finished\", giving how many were pending, how many were applied and the
milliseconds for the whole call; when a migration signalled, the line also names it in :FAILED.
A call with nothing to apply logs \"migrate: up to date\" at DEBUG."
  (conn:exec connection (be:schema-migrations-ddl backend))
  (let ((applied '())
        (todo (pending connection migrations))
        (started (get-internal-real-time))
        (current nil))
    (flet ((ms-since (start)
             (round (* 1000 (- (get-internal-real-time) start)) internal-time-units-per-second)))
      (unless todo
        (log:debug "migrate: up to date")
        (return-from migrate nil))
      (log:debug "migrate: applying" :count (length todo)
                                     :ids (format nil "~{~A~^,~}" (mapcar #'be:migration-id todo)))
      ;; One INFO line per call, not per migration: a test suite that migrates a fresh database
      ;; for every test would otherwise write one line per migration per test. A schema change is
      ;; still in the record at the default level, as this line, including when it stopped.
      (unwind-protect
           (dolist (m todo)
             (setf current (be:migration-id m))
             (let ((start (get-internal-real-time)))
               (conn:with-transaction (connection)
                 (conn:exec connection (be:migration-up m))
                 (conn:exec connection "INSERT INTO schema_migrations (id) VALUES (?)"
                            (be:migration-id m)))
               (log:debug "migrate: applied" :id (be:migration-id m)
                                             :description (be:migration-description m)
                                             :ms (ms-since start)))
             (push (be:migration-id m) applied)
             (setf current nil))
        (if current
            (log:info "migrate: finished" :pending (length todo) :applied (length applied)
                                          :ms (ms-since started) :failed current)
            (log:info "migrate: finished" :pending (length todo) :applied (length applied)
                                          :ms (ms-since started))))
      (reverse applied))))

(defun rollback (backend connection migrations &key (steps 1))
  "Roll back the last STEPS applied migrations: run each one's down-SQL (newest first)
and delete its `schema_migrations` row, each in a transaction. MIGRATIONS is the known set
(used to look up the down-SQL by id). Returns the ids rolled back."
  (conn:exec connection (be:schema-migrations-ddl backend))
  (let* ((newest-first (reverse (applied-ids connection)))
         (targets (subseq newest-first 0 (min steps (length newest-first))))
         (rolled '()))
    (dolist (id targets (nreverse rolled))
      (let ((m (find id migrations :key #'be:migration-id :test #'string=)))
        (if m
            (progn
              (conn:with-transaction (connection)
                (conn:exec connection (be:migration-down m))
                (conn:exec connection "DELETE FROM schema_migrations WHERE id = ?" id))
              (log:info "migrate: rolled back" :id id)
              (push id rolled))
            ;; applied in the DB but absent from the known set -- silently skipped before,
            ;; which is exactly the kind of thing you want to see in a log.
            (log:warn "migrate: cannot roll back, migration not in the known set" :id id))))))

;;; --- extensions, which are a deployment fact (pre-publication issue 258) -------------------------
;;;
;;; `CREATE EXTENSION' is privileged and the package has to be on the host. It is available
;;; on RDS, Cloud SQL and DigitalOcean's managed databases and not on every managed Postgres;
;;; on a bare install someone has to have installed the package. So a schema that needs
;;; pgvector has a PRECONDITION, and the failure without one is a Postgres error about an
;;; unknown TYPE -- which names neither the extension nor the privilege, and sends the reader
;;; to the column definition instead of to the deployment.
;;;
;;; THE TWO FAILURES ARE DIFFERENT AND THE FIX IS DIFFERENT, which is the whole reason this
;;; distinguishes them: a server without the package needs an install (or a different
;;; server), while a server that has it and refuses needs a privilege. Reporting both as "no
;;; pgvector" sends half the readers to the wrong place.

(define-condition extension-unavailable (error)
  ((name :initarg :name :reader extension-unavailable-name)
   (reason :initarg :reason :initform :absent :reader extension-unavailable-reason)
   (detail :initarg :detail :initform nil :reader extension-unavailable-detail))
  (:report
   (lambda (c s)
     (format s "mnemosyne/migrate: the `~A' extension is not usable on this server -- ~A.~@[~%  ~A~]"
             (extension-unavailable-name c)
             (ecase (extension-unavailable-reason c)
               (:absent "the server does not offer it (the extension package is not installed on the host, or this managed Postgres does not carry it)")
               (:unprivileged "it is available but CREATE EXTENSION was refused, which needs a privileged role (superuser, or rds_superuser and equivalents)"))
             (extension-unavailable-detail c))))
  (:documentation
   "Signalled when an extension a schema requires cannot be used. REASON is :ABSENT (the
server does not offer it) or :UNPRIVILEGED (it does, and creating it was refused) -- two
different problems with two different fixes, which is why one condition carries which."))

(defun extension-available-p (connection name)
  "Does this SERVER offer the NAME extension?

Asked of `pg_available_extensions', not `pg_extension': the question is whether the server
HAS it, not whether this database happens to have run CREATE EXTENSION already. Asking the
second and reporting the first is how a fresh database looks like an unsupported server."
  (let ((rows (conn:query connection
                          "SELECT count(*) FROM pg_available_extensions WHERE name = ?"
                          (string-downcase (string name)))))
    (plusp (or (%col1 (first rows)) 0))))

(defun extension-present-p (connection name)
  "Has NAME already been created IN THIS DATABASE? The other half of the question above."
  (let ((rows (conn:query connection
                          "SELECT count(*) FROM pg_extension WHERE extname = ?"
                          (string-downcase (string name)))))
    (plusp (or (%col1 (first rows)) 0))))

(defun require-extension (connection name)
  "Ensure NAME exists in this database, creating it if the server offers it. Returns NAME.

CALL THIS BEFORE A MIGRATION THAT NEEDS THE EXTENSION, so the failure names the extension and
the privilege rather than arriving later as an error about an unknown type. Signals
EXTENSION-UNAVAILABLE with :ABSENT when the server does not offer it and :UNPRIVILEGED when it
does and the CREATE was refused -- two problems with two fixes.

Idempotent: an extension already present is left alone and not re-created, so this is safe to
call from every migration that depends on it rather than from one that has to run first."
  (let ((ext (string-downcase (string name))))
    (cond
      ((extension-present-p connection ext) name)
      ((not (extension-available-p connection ext))
       (error 'extension-unavailable :name ext :reason :absent))
      (t
       (handler-case
           (progn (conn:exec connection (format nil "CREATE EXTENSION IF NOT EXISTS ~A" ext))
                  name)
         (error (e)
           ;; The server offers it and refused to create it. The commonest cause by far is
           ;; the privilege, and the driver's message is kept as DETAIL rather than replaced,
           ;; because a wrong guess about the cause is worse than a right guess plus the
           ;; original text.
           (error 'extension-unavailable :name ext :reason :unprivileged
                                        :detail (princ-to-string e))))))))

;;; --- rewriting a SQLite column's text values in place (#425) ---------------------

(defun rewrite-sqlite-text-values (connection table key column function &key (batch-size 500))
  "On a SQLite CONNECTION, set COLUMN of every row of TABLE whose COLUMN holds a TEXT value to
(FUNCTION text). A row for which FUNCTION returns NIL is left as it was. KEY is a column that
orders the rows uniquely, usually the primary key. Returns two values: the number of rows
rewritten and the number left.

FOR A STORE THAT CHANGES HOW IT ENCODES A COLUMN, in a store whose readers accept both encodings.
It is written to be run on every open:
- A CHEAP CHECK FIRST. One SELECT ... LIMIT 1, outside any transaction, asks whether any TEXT value
  is left; when none is, this returns 0 and 0 without taking SQLite's write lock.
- ONE TRANSACTION PER BATCH of BATCH-SIZE rows, each begun IMMEDIATE, so the write lock is held for
  one batch at a time and another process's writes, or its own open, wait at most that long. A
  single transaction over a large table held the lock for longer than mnemosyne's busy timeout
  (*SQLITE-BUSY-TIMEOUT-MS*), and the other process's statement failed (#425's review).
- RESUMABLE. An error in a batch rolls that batch back; the batches before it stay rewritten. The
  table is then partly in each encoding, which its readers accept, and the next run carries on
  from what is still TEXT.
- A value in SQLite is typed by the value and not by the column's declared type, so FUNCTION may
  return a BLOB for a column declared TEXT; that is what it is for.

TABLE, KEY and COLUMN are interpolated into the SQL, so they must be identifiers the caller
controls, never input."
  (let ((rewritten 0) (left 0) (after nil))
    (unless (conn:query connection
                        (format nil "SELECT 1 AS one FROM ~A WHERE typeof(~A) = 'text' LIMIT 1" table column))
      (return-from rewrite-sqlite-text-values (values 0 0)))
    (loop
      (let ((rows nil))
        (conn:with-transaction (connection :immediate t)
          (setf rows (if after
                         (conn:query connection
                                     (format nil "SELECT ~A AS k, ~A AS v FROM ~A WHERE typeof(~A) = 'text' AND ~A > ? ORDER BY ~A LIMIT ~D"
                                             key column table column key key batch-size)
                                     after)
                         (conn:query connection
                                     (format nil "SELECT ~A AS k, ~A AS v FROM ~A WHERE typeof(~A) = 'text' ORDER BY ~A LIMIT ~D"
                                             key column table column key batch-size))))
          (dolist (row rows)
            (let ((value (funcall function (getf row :|v|))))
              (if value
                  (progn
                    (conn:exec connection (format nil "UPDATE ~A SET ~A = ? WHERE ~A = ?" table column key)
                               value (getf row :|k|))
                    (incf rewritten))
                  (incf left)))))
        (when (null rows) (return))
        (setf after (getf (car (last rows)) :|k|))))
    (values rewritten left)))
