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

DELIBERATELY POSITIONAL, AND NOT TO BE CONVERTED TO MNEMOSYNE/PARAM:ROW-VALUE (#489). It
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
Returns the list of ids applied this run (NIL when already up to date)."
  (conn:exec connection (be:schema-migrations-ddl backend))
  (let ((applied '())
        (todo (pending connection migrations)))
    ;; :info, not :debug -- a schema change is the one DB event an operator wants in the
    ;; record at default level, and it happens once per deploy, not per request.
    (if todo
        (log:info "migrate: applying" :count (length todo)
                                      :ids (format nil "~{~A~^,~}" (mapcar #'be:migration-id todo)))
        (log:debug "migrate: up to date"))
    (dolist (m todo (nreverse applied))
      (let ((start (get-internal-real-time)))
        (conn:with-transaction (connection)
          (conn:exec connection (be:migration-up m))
          (conn:exec connection "INSERT INTO schema_migrations (id) VALUES (?)"
                     (be:migration-id m)))
        (log:info "migrate: applied" :id (be:migration-id m)
                                     :description (be:migration-description m)
                                     :ms (round (* 1000 (- (get-internal-real-time) start))
                                                internal-time-units-per-second)))
      (push (be:migration-id m) applied))))

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

;;; --- extensions, which are a deployment fact (#258) -------------------------
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
