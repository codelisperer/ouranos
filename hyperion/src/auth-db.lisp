;;;; auth-db.lisp --- a mnemosyne-backed identity store (Hyperion aux system).
;;;;
;;;; Users + password authentication for the web layer: create/find users, verify passwords
;;;; (PBKDF2 via ironclad), a temp-password flag driving forced-change-at-first-login, and a
;;;; serialized roles field. Lives in its own ASDF system (hyperion/auth-db) so hyperion core
;;;; keeps no database dependency -- this aux system depends on mnemosyne (a leftward dep) and
;;;; ironclad, exactly like hyperion/session-db. It dogfoods the mnemosyne query builder
;;;; (insert / select / update) and the entity id (mnemosyne/id:new-id).
;;;;
;;;; Scope: identity + authentication. Community-scoped capability GRANTS (authorization) are
;;;; a separate concern -- a later hyperion authz increment + a grants table; `roles` here is a
;;;; simple serialized keyword list to bootstrap super-admins.
;;;;
;;;; NOTHING HERE AUTHORISES THE CALLER. Every mutation -- SET-PASSWORD, GRANT-ROLE,
;;;; REVOKE-ROLE -- does what it is told to the user id it is given, and none of them has any
;;;; opinion about who is asking. A function named GRANT-ROLE invites the assumption that it
;;;; does; it does not. Deciding whether the *current* user may act on another is the
;;;; application's job, and there is nothing in this file that will stop a handler that forgot.

(cl:defpackage #:hyperion/auth-db
  (:use #:cl)
  (:local-nicknames (#:q      #:mnemosyne/query)
                    (#:conn   #:mnemosyne/conn)
                    (#:schema #:mnemosyne/schema)
                    (#:id     #:mnemosyne/id)
                    (#:bt     #:bordeaux-threads))
  (:documentation
   "A mnemosyne-backed identity store: users (email + optional phone), PBKDF2 password
    hashing, a temp-password flag (forced change at first login), and a serialized roles
    field. MAKE-DB-AUTH over an open mnemosyne connection; :ensure t creates the table.")
  (:export #:db-auth #:make-db-auth #:ensure-schema #:db-auth-ddl #:users-ddl #:*table*
           #:hash-password #:verify-password
           #:create-user #:find-user-by-email #:find-user-by-id #:authenticate #:set-password
           #:grant-role #:revoke-role #:users-with-role #:known-roles
           #:*role-update-attempts*
           #:user #:user-p #:user-id #:user-email #:user-phone #:user-roles
           #:user-temp-password-p #:user-status #:user-created-at #:user-updated-at
           #:duplicate-email #:unknown-role #:unknown-role-role #:unknown-role-known
           #:role-update-conflict #:role-update-conflict-id
           #:role-update-conflict-attempts
           ;; pre-publication issue 166: the append-only role-change log.
           #:role-history #:role-events-ddl #:role-events-index-ddl #:events-table #:*events-table*
           #:users-email-index-ddl
           #:missing-role-log #:missing-role-log-table #:missing-role-log-cause
           #:missing-actor #:missing-actor-operation))
(in-package #:hyperion/auth-db)

(defvar *table* "hyperion_users" "Default table name for the identity store.")

(defvar *events-table* "hyperion_role_events"
  "Default table name for the append-only role-change log (pre-publication issue 166).")

(defparameter *pbkdf2-iterations* 100000
  "PBKDF2 iteration count for password hashing (raise over time as hardware allows).")

;;; --- schema (single source of truth for the DDL) --------------------------
(schema:defschema hyperion-user (:table "hyperion_users")
  (:_id           :string  :primary t)
  (:vid           :integer)
  (:email         :string  :required t)   ; unique -- enforced by USERS-EMAIL-INDEX-DDL (#221)
  (:phone         :string)                ; optional (E.164); NIL -> no SMS
  (:pw_hash       :text)
  (:temp_password :integer)               ; 0/1 (sqlite has no boolean)
  (:roles         :text)                  ; serialized keyword list, e.g. "(:SUPER-ADMIN)"
  (:status        :string)
  (:created_at    :integer)
  (:updated_at    :integer))

;;; pre-publication issue 166. An APPEND-ONLY log of role changes, and the reason it is a second table rather
;;; than more columns is that `roles' holds only CURRENT STATE -- so the questions actually
;;; asked after an incident ("who gave this account :super-admin, and when?", "was it
;;; escalated before or after?") are unanswerable from it. `updated_at' does not even
;;; narrow the window: it moves on any user write, a password change included.
;;;
;;; WHY THIS DOES NOT WAIT FOR THE GRANTS TABLE. The issue's own hesitation was that an
;;; audit log would be bolted onto a representation already scheduled to be replaced. But
;;; an event log is NOT COUPLED TO THE REPRESENTATION IT OBSERVES: it records what
;;; HAPPENED -- user, role, granted or revoked, by whom, when -- while a grants table would
;;; record what IS. The vocabulary is shared, so a later grants table takes over current
;;; state and this keeps the history it would otherwise have to invent. The representation
;;; is the part that changes; the events are the part that survives.
;;;
;;; And the alternative the issue floated is not available: mnemosyne has NO SQL:2011
;;; temporal implementation today -- the bitemporal thesis is in the vision docs and the
;;; package headers, and there is not a period column or a `system versioning' clause in
;;; the tree. "Dogfood the temporal model" would mean building the temporal model first.
(schema:defschema hyperion-role-event (:table "hyperion_role_events")
  (:_id      :string  :primary t)
  (:user_id  :string  :required t)
  (:role     :string  :required t)   ; the keyword's name, e.g. "SUPER-ADMIN"
  (:action   :string  :required t)   ; "grant" | "revoke"
  (:actor    :string  :required t)   ; who did it -- see GRANT-ROLE on why this is required
  (:at       :integer :required t))  ; universal time

;;; --- the store ------------------------------------------------------------
(defclass db-auth ()
  ((connection :initarg :connection :reader conn)
   (dialect    :initarg :dialect    :reader dialect :initform :sqlite)
   (table      :initarg :table      :reader table   :initform *table*)
   (events-table :initarg :events-table :reader events-table :initform *events-table*)
   (known-roles :initarg :known-roles :reader known-roles :initform nil)
   (lock :initform (bt:make-lock "hyperion-auth-db") :reader lock))
  (:documentation "An identity store over a mnemosyne connection (one connection, locked)."))

(defun make-db-auth (connection &key (dialect :sqlite) (table *table*)
                                     (events-table *events-table*) ensure known-roles
                                     (require-role-log t))
  "An identity store over an open mnemosyne CONNECTION. DIALECT is :sqlite or :postgres.
With :ENSURE, create the users table, its unique email index, and the role-event log.

THE ROLE-EVENT LOG IS CHECKED HERE, at construction (#139). GRANT-ROLE and REVOKE-ROLE write
to it on every call, so a store without it fails the first time an operator changes a role,
in an admin screen, long after boot. An app that owns its migration timeline creates it with
ROLE-EVENTS-DDL and ROLE-EVENTS-INDEX-DDL (docs/migrations.md, section 5); if it has not,
this signals MISSING-ROLE-LOG naming that migration. Pass :REQUIRE-ROLE-LOG NIL only for an
app that never grants or revokes a role, and so deliberately runs without the table.

KNOWN-ROLES is an optional vocabulary: when NIL (the default) any keyword is accepted, which
is the historical behaviour and means a typo like :MODERATER is stored happily and silently
grants nothing. Supply a list and CREATE-USER, GRANT-ROLE and REVOKE-ROLE signal UNKNOWN-ROLE
instead, turning that typo into an error at the point of the mistake. Opt-in, because the
framework does not know an application's vocabulary and existing callers must keep working."
  (let ((store (make-instance 'db-auth :connection connection :dialect dialect :table table
                                       :events-table events-table
                                       :known-roles known-roles)))
    (when ensure (ensure-schema store))
    (when require-role-log (%check-role-log store))
    store))

(define-condition missing-role-log (error)
  ((table :initarg :table :reader missing-role-log-table)
   (dialect :initarg :dialect :reader missing-role-log-dialect)
   (cause :initarg :cause :initform nil :reader missing-role-log-cause))
  (:report
   (lambda (c s)
     (format s "hyperion/auth-db: the role-event log table ~A could not be read (~A).~%"
             (missing-role-log-table c) (missing-role-log-cause c))
     (format s "~%GRANT-ROLE and REVOKE-ROLE write to it on every call, so without it the first role change~%")
     (format s "fails at run time. Add a migration to your timeline that creates it:~%~%")
     (format s "  (be:make-migration \"<your-id>_hyperion_role_events\" \"role-change log\"~%")
     (format s "                     (auth:role-events-ddl :dialect ~S)~%" (missing-role-log-dialect c))
     (format s "                     \"DROP TABLE ~A\")~%" (missing-role-log-table c))
     (format s "  (be:make-migration \"<your-id>_hyperion_role_events_index\" \"role-change log index\"~%")
     (format s "                     (auth:role-events-index-ddl)~%")
     (format s "                     \"DROP INDEX idx_~A_user_at\")~%" (missing-role-log-table c))
     (format s "~%See docs/migrations.md, section 5. An app that never changes roles can pass~%")
     (format s ":REQUIRE-ROLE-LOG NIL to MAKE-DB-AUTH instead.~%")))
  (:documentation
   "Signalled by MAKE-DB-AUTH when the role-event log table cannot be read (#139). CAUSE is the
database's own error. The report names the migration that creates the table."))

(defun %check-role-log (store)
  "Signal MISSING-ROLE-LOG unless STORE's role-event table can be read. A query that returns no
rows, so it costs one round trip and reads nothing."
  (handler-case
      (conn:query (conn store) (format nil "SELECT 1 FROM ~A WHERE 1 = 0" (events-table store)))
    (error (e)
      (error 'missing-role-log :table (events-table store) :dialect (dialect store) :cause e))))

(defun users-ddl (&key (dialect :sqlite))
  "The CREATE TABLE SQL for the users table under DIALECT, **store-less** -- so a consuming
app can fold the identity schema into its OWN migration timeline (mnemosyne make-migration)
rather than call ENSURE-SCHEMA. The unique email index is a separate statement,
USERS-EMAIL-INDEX-DDL, which an app owning its migrations adds as its own step (#221)."
  ;; The designator goes straight through (pre-publication issue 432, ADR-0003). This used to be
  ;; `(string-downcase (symbol-name dialect))' -- a fourth hand-rolled conversion, written
  ;; here because hyperion holds the dialect as a KEYWORD and schema-ddl used to take only a
  ;; STRING. It also made this helper keyword-only: a caller with the string spelling hit a
  ;; type error from SYMBOL-NAME. mnemosyne now normalises designators itself.
  (schema:schema-ddl (schema:find-schema 'hyperion-user) :dialect dialect))

(defun users-email-index-ddl (&key (table *table*))
  "CREATE UNIQUE INDEX DDL for the users table's email column, store-less like USERS-DDL, so an
app that owns its migrations adds it as its own step (docs/migrations.md, section 5).

THIS INDEX IS WHAT MAKES AN EMAIL UNIQUE (#221). USERS-DDL declares no UNIQUE constraint, and a
database without this index accepts two rows for one address. CREATE-USER also refuses a known
duplicate before inserting, but only the index holds when two processes insert at once."
  (format nil "CREATE UNIQUE INDEX IF NOT EXISTS idx_~A_email ON ~A (email)" table table))

(defun db-auth-ddl (store)
  (users-ddl :dialect (dialect store)))

(defun role-events-ddl (&key (dialect :sqlite))
  "CREATE TABLE DDL for the append-only role-change log (pre-publication issue 166)."
  (schema:schema-ddl (schema:find-schema 'hyperion-role-event) :dialect dialect))

(defun role-events-index-ddl (&key (table *events-table*))
  "CREATE INDEX DDL for the role-event log, store-less like ROLE-EVENTS-DDL, so an app that owns
its migrations can add it as its own step. Indexed by (user_id, at) because the question is
always \"this account's history\", ordered."
  (format nil "CREATE INDEX IF NOT EXISTS idx_~A_user_at ON ~A (user_id, at)" table table))

(defun ensure-schema (store)
  "Create the users table, its unique email index, and the role-event log if absent.
Returns STORE."
  (conn:exec (conn store) (db-auth-ddl store))
  (conn:exec (conn store) (users-email-index-ddl :table (table store)))
  (conn:exec (conn store) (role-events-ddl :dialect (dialect store)))
  ;; Never an index on `at' alone: the question is never "every role event ever".
  (conn:exec (conn store) (role-events-index-ddl :table (events-table store)))
  store)

;;; --- passwords (pure; PBKDF2 self-describing combined string) --------------
(defun %octets (s)
  #+sbcl (sb-ext:string-to-octets s :external-format :utf-8)
  #-sbcl (ironclad:ascii-string-to-byte-array s))

(defun hash-password (plaintext)
  "A self-describing PBKDF2 hash string (salt + iterations + digest embedded)."
  (ironclad:pbkdf2-hash-password-to-combined-string
   (%octets plaintext) :iterations *pbkdf2-iterations*))

(defun verify-password (plaintext hash)
  "True iff PLAINTEXT matches the stored combined HASH string."
  (and (stringp hash) (plusp (length hash))
       (ignore-errors (ironclad:pbkdf2-check-password (%octets plaintext) hash))))

;;; --- user records ---------------------------------------------------------
(defstruct (user (:constructor %make-user) (:predicate user-p))
  id email phone hash temp-password-p roles status created-at updated-at)

(define-condition duplicate-email (error)
  ((email :initarg :email :reader duplicate-email-email))
  (:report (lambda (c s) (format s "a user with email ~S already exists"
                                 (duplicate-email-email c)))))

(define-condition unknown-role (error)
  ((role  :initarg :role  :reader unknown-role-role)
   (known :initarg :known :reader unknown-role-known))
  (:report (lambda (c s)
             (format s "~S is not a known role; this store accepts ~{~S~^, ~}"
                     (unknown-role-role c) (unknown-role-known c)))))

(define-condition role-update-conflict (error)
  ((id       :initarg :id       :reader role-update-conflict-id)
   (attempts :initarg :attempts :reader role-update-conflict-attempts))
  (:report (lambda (c s)
             (format s "roles for user ~S were changed concurrently ~D times running; gave up"
                     (role-update-conflict-id c) (role-update-conflict-attempts c)))))

(defun %rget (row key)
  "Value of column KEY (keyword) from a fetched ROW plist, case-insensitively (drivers
disagree on key case)."
  (let ((name (symbol-name key)))
    (loop for (k v) on row by #'cddr
          when (and (symbolp k) (string-equal (symbol-name k) name)) do (return v))))

(defun %to-int (v)
  (cond ((integerp v) v)
        ((stringp v) (or (ignore-errors (parse-integer v :junk-allowed t)) 0))
        (t 0)))

(defun %read-roles (s)
  (when (and (stringp s) (plusp (length s)))
    (let ((*read-eval* nil))
      (handler-case (let ((r (read-from-string s))) (and (listp r) r)) (error () nil)))))

(defun %write-roles (roles)
  (with-standard-io-syntax
    (let ((*package* (find-package '#:keyword))) (prin1-to-string roles))))

(defun %row->user (row)
  (%make-user :id (%rget row :_id) :email (%rget row :email) :phone (%rget row :phone)
              :hash (%rget row :pw_hash)
              :temp-password-p (not (zerop (%to-int (%rget row :temp_password))))
              :roles (%read-roles (%rget row :roles))
              :status (%rget row :status)
              :created-at (%to-int (%rget row :created_at))
              :updated-at (%to-int (%rget row :updated_at))))

;;; --- CRUD -----------------------------------------------------------------
(defun %norm-email (email) (string-downcase (string-trim " " email)))

(defun create-user (store &key email phone password (roles '()) temp-password-p status)
  "Create + persist a user. EMAIL is required (lower-cased, unique); PHONE optional.
PASSWORD is hashed if given. TEMP-PASSWORD-P marks it as a temp password (forces change at
first login). ROLES is a keyword list. Signals DUPLICATE-EMAIL on a unique-email clash, and
UNKNOWN-ROLE if the store was given a role vocabulary and ROLES strays outside it.
Returns the USER.

Roles given here can be changed afterwards with GRANT-ROLE / REVOKE-ROLE; this is not the
only chance to decide them."
  (mapc (lambda (r) (%check-role store r)) roles)
  (let* ((now (get-universal-time))
         (em  (%norm-email email))
         (row (list :_id (id:new-id) :vid 1 :email em :phone phone
                    :pw_hash (and password (hash-password password))
                    :temp_password (if temp-password-p 1 0)
                    :roles (%write-roles roles)
                    :status (or status "active")
                    :created_at now :updated_at now)))
    (bt:with-lock-held ((lock store))
      ;; A KNOWN duplicate is refused here, before the insert (#221). Until #221 this relied
      ;; only on the unique index's error, and a database built from USERS-DDL alone, which is
      ;; what docs/migrations.md used to show, has no index: a second sign-up with the same
      ;; address then created a second account, silently. The check covers any caller of THIS
      ;; store, which serialises on the lock. Two processes, or two stores on one database,
      ;; can still both pass it at the same moment; only USERS-EMAIL-INDEX-DDL's index refuses
      ;; that, and the handler below turns its error into DUPLICATE-EMAIL.
      (when (find-user-by-email store em)
        (error 'duplicate-email :email em))
      (handler-case
          (q:run (conn store) (list :insert-into (table store) :values (list row))
                 :dialect (dialect store))
        (conn:db-error (e)
          (if (search "UNIQUE" (or (conn:db-error-message e) "") :test #'char-equal)
              (error 'duplicate-email :email em)
              (error e)))))
    (%row->user row)))

(defun find-user-by-email (store email)
  "The USER with EMAIL (case-insensitive), or NIL."
  (let ((rows (q:fetch (conn store)
                       (list :select '(:*) :from (list (table store))
                             :where (list := :email (%norm-email email)))
                       :dialect (dialect store))))
    (when rows (%row->user (first rows)))))

(defun find-user-by-id (store id)
  "The USER with primary key ID, or NIL."
  (let ((rows (q:fetch (conn store)
                       (list :select '(:*) :from (list (table store))
                             :where (list := :_id id))
                       :dialect (dialect store))))
    (when rows (%row->user (first rows)))))

(defun authenticate (store email plaintext)
  "The USER if EMAIL exists and PLAINTEXT matches its password; else NIL."
  (let ((u (find-user-by-email store email)))
    (when (and u (verify-password plaintext (user-hash u))) u)))

;;; --- roles ----------------------------------------------------------------
;;;
;;; Roles can be GRANTED and REVOKED, not set wholesale, and the difference matters. A
;;; `set-roles` forces the read-modify-write into the application -- read USER-ROLES, cons or
;;; remove, write the whole list back -- so two administrators editing the same account in
;;; that window silently lose one edit, with no error anywhere. GRANT-ROLE and REVOKE-ROLE
;;; move that window inside the store, where it can be closed, and are idempotent: granting a
;;; role already held, or revoking one not held, succeeds and changes nothing.
;;;
;;; The window is closed TWICE, because one mechanism is not enough:
;;;
;;;   The store's lock serialises threads sharing this image -- and is mandatory anyway,
;;;   since a DB-AUTH holds ONE connection and concurrent statements on it are not safe.
;;;
;;;   That lock does nothing across processes: two app instances, or two boxes behind a
;;;   load balancer, hold different locks over the same row. So the write is also a
;;;   compare-and-swap on `vid`, the version the row was read at --
;;;   `UPDATE ... WHERE _id = ? AND vid = ?` -- which affects zero rows if anyone else got
;;;   there first, and is retried against the new state. That is the only part that is
;;;   actually correct in a deployment with more than one process.

(defparameter *role-update-attempts* 8
  "How many times a role change re-reads and retries after losing a compare-and-swap before
signalling ROLE-UPDATE-CONFLICT. Each loss means another writer committed first, so a run of
eight is contention no retry count will fix -- better to report it than to spin.")

(defun %check-role (store role)
  "Signal unless ROLE is acceptable to STORE: a keyword, and in KNOWN-ROLES when one is set."
  (unless (keywordp role)
    (error 'type-error :datum role :expected-type 'keyword))
  (let ((known (known-roles store)))
    (when (and known (not (member role known)))
      (error 'unknown-role :role role :known known))))

(defun %roles-row (store id)
  "(values vid roles) for user ID, or NIL if there is no such user."
  (let ((rows (q:fetch (conn store)
                       (list :select '(:vid :roles) :from (list (table store))
                             :where (list := :_id id))
                       :dialect (dialect store))))
    (when rows
      (values (%to-int (%rget (first rows) :vid))
              (%read-roles (%rget (first rows) :roles))))))

(defun %record-role-event (store user-id role action actor)
  "Append one row to the role-change log. Called INSIDE the transaction that makes the
change, never beside it -- see %UPDATE-ROLES."
  (q:run (conn store)
         (list :insert-into (events-table store)
               :values (list (list :_id (id:new-id)
                                   :user_id user-id
                                   :role (symbol-name role)
                                   :action action
                                   :actor actor
                                   :at (get-universal-time))))
         :dialect (dialect store)))

(defun %update-roles (store id transform &key action role actor)
  "Apply TRANSFORM to user ID's role list and persist it, retrying on a lost compare-and-swap.

Returns T on success (including the no-op case where TRANSFORM changed nothing), NIL if there
is no such user. Signals ROLE-UPDATE-CONFLICT if it keeps losing the swap."
  (bt:with-lock-held ((lock store))
    (loop repeat *role-update-attempts*
          do (multiple-value-bind (vid roles) (%roles-row store id)
               (when (null vid) (return nil))
               (let ((next (funcall transform roles)))
                 ;; Nothing to do is a success, not a write: an idempotent grant must not
                 ;; bump `vid` and make some other writer's swap fail for no reason. It
                 ;; must not write an AUDIT EVENT either -- a grant that changed nothing is
                 ;; not a role change, and a log full of them is a log nobody reads.
                 (when (equal next roles) (return t))
                 ;; The event and the change commit TOGETHER or not at all (pre-publication issue 166). An audit
                 ;; row that can survive a failed update -- or an update that can survive a
                 ;; failed audit -- is worse than no audit: it is a record that is wrong
                 ;; rather than missing, and nothing downstream can tell which.
                 (let ((committed nil))
                   (conn:with-transaction ((conn store))
                     (let ((affected (q:run (conn store)
                                            (list :update (table store)
                                                  :set (list :roles (%write-roles next)
                                                             :vid (1+ vid)
                                                             :updated_at (get-universal-time))
                                                  :where (list :and
                                                               (list := :_id id)
                                                               (list := :vid vid)))
                                            :dialect (dialect store))))
                       ;; Zero rows affected == somebody else committed between our read and
                       ;; our write. Their change stands; re-read and reapply on top of it.
                       (when (plusp (%to-int affected))
                         (when action (%record-role-event store id role action actor))
                         (setf committed t))))
                   (when committed (return t)))))
          finally (error 'role-update-conflict :id id :attempts *role-update-attempts*))))

(define-condition missing-actor (error)
  ((operation :initarg :operation :reader missing-actor-operation))
  (:report
   (lambda (c s)
     (format s "hyperion/auth-db: ~A needs :ACTOR -- who is making this change.~%"
             (missing-actor-operation c))
     (format s "~%A role change is recorded in an append-only log (pre-publication issue 166), and a record that~%")
     (format s "cannot name who acted answers none of the questions the log exists for:~%")
     (format s "who granted :super-admin and when; who removed the moderator; whether the~%")
     (format s "account was escalated before or after the incident.~%")
     (format s "~%Pass whatever identifies the actor in your application -- the acting user's~%")
     (format s "id, or a name like \"system\" / \"cli\" for changes no person made:~%")
     (format s "~%  (grant-role store id :moderator :actor (current-user-id))~%")))
  (:documentation
   "Signalled when GRANT-ROLE / REVOKE-ROLE is called without :ACTOR (pre-publication issue 166).

REQUIRED rather than defaulted, deliberately, and it is the one deliberate break in pre-publication issue 166.
An optional audit field is an omitted audit field: the caller who most needs the record is
the one who has not thought about it. This module already refuses to guess a caller's
identity -- it does not authorise anyone and has no notion of a current user -- so the
actor is exactly the thing it cannot supply and must be told."))

(defun %require-actor (actor operation)
  (unless (and actor (stringp actor) (plusp (length actor)))
    (error 'missing-actor :operation operation))
  actor)

(defun role-history (store id)
  "Every recorded role change for user ID, oldest first, as plists:
(:ROLE :ACTION :ACTOR :AT). The answer to the questions pre-publication issue 166 was filed about.

Oldest-first because the reconstruction is chronological -- what happened to this account,
in order -- and a reader scanning for \"when did this start\" reads forwards."
  (let ((rows (q:fetch (conn store)
                       (list :select '(:role :action :actor :at)
                             :from (list (events-table store))
                             :where (list := :user_id id)
                             ;; _id BREAKS THE TIE, and it has to. `at' is whole seconds, so
                             ;; two changes in the same second order arbitrarily under `at'
                             ;; alone -- and "was this account escalated before or after the
                             ;; incident" is exactly an ordering question, so an ambiguous
                             ;; order is a wrong answer to the thing the log is for. Found
                             ;; by a Postgres run where a grant and a revoke came back
                             ;; sharing one timestamp.
                             ;;
                             ;; _id is a UUID v6, which is time-ordered and sorts
                             ;; lexicographically in generation order (verified over 200
                             ;; ids) -- so it is a sub-second tiebreaker already present in
                             ;; the row, not a column added to paper over the resolution.
                             :order-by '((:at :asc) (:_id :asc)))
                       :dialect (dialect store))))
    (mapcar (lambda (row)
              (list :role (let ((r (%rget row :role)))
                            (and r (intern (string-upcase r) :keyword)))
                    :action (%rget row :action)
                    :actor (%rget row :actor)
                    :at (%to-int (%rget row :at))))
            rows)))

(defun grant-role (store id role &key actor)
  "Give user ID the ROLE, recording who did it. Returns T, or NIL if there is no such user.

ACTOR is REQUIRED (pre-publication issue 166) -- see MISSING-ACTOR for why an optional one would be no audit at
all. It is an opaque application string: a user id, or a name like \"system\" for changes
no person made.

**This does not authorise the caller.** It grants ROLE to user ID; deciding whether the
*current* user may do that is the application's job, and there is nothing here that will stop
a handler that forgot to ask. (SET-PASSWORD makes no such check either.)

Idempotent -- granting a role already held succeeds and writes nothing -- and it leaves the
user's other roles alone. Signals UNKNOWN-ROLE if the store was given a role vocabulary and
ROLE is not in it, and ROLE-UPDATE-CONFLICT under sustained concurrent writes."
  (%require-actor actor "GRANT-ROLE")
  (%check-role store role)
  (%update-roles store id (lambda (roles)
                            (if (member role roles) roles (append roles (list role))))
                 :action "grant" :role role :actor actor))

(defun revoke-role (store id role &key actor)
  "Take ROLE away from user ID, recording who did it. Returns T, or NIL if no such user.

ACTOR is REQUIRED (pre-publication issue 166), as for GRANT-ROLE.

**This does not authorise the caller** -- see GRANT-ROLE. In particular nothing here knows
that revoking the last administrator locks everybody out of the application: roles are
arbitrary keywords, so the store cannot tell that :SUPER-ADMIN outranks :MODERATOR, and
teaching it would mean the framework inventing application vocabulary. USERS-WITH-ROLE exists
so the app can make that check where the knowledge lives:

  (when (and (eq role :super-admin)
             (= 1 (length (users-with-role store :super-admin))))
    (error 'last-administrator))

Idempotent -- revoking a role not held succeeds and writes nothing."
  (%require-actor actor "REVOKE-ROLE")
  (%check-role store role)
  (%update-roles store id (lambda (roles) (remove role roles))
                 :action "revoke" :role role :actor actor))

(defun users-with-role (store role)
  "The ids of every user holding ROLE.

Chiefly for the guard REVOKE-ROLE deliberately does not make: counting the administrators
before removing one. Roles are a serialized keyword list in a text column, so there is no
portable SQL predicate for this and it scans the table -- fine for an admin-console guard,
and the signal to move to a real grants table (see the header) if it ever is not."
  (let ((rows (q:fetch (conn store)
                       (list :select '(:_id :roles) :from (list (table store)))
                       :dialect (dialect store))))
    (loop for row in rows
          when (member role (%read-roles (%rget row :roles)))
            collect (%rget row :_id))))

(defun set-password (store id new-plaintext &key (clear-temp t))
  "Set user ID's password to NEW-PLAINTEXT (hashed); by default clears the temp-password
flag (the forced-change-at-first-login completion). Bumps updated_at. Returns T."
  (let ((now (get-universal-time)))
    (bt:with-lock-held ((lock store))
      (q:run (conn store)
             (list :update (table store)
                   :set (list :pw_hash (hash-password new-plaintext)
                              :temp_password (if clear-temp 0 1)
                              :updated_at now)
                   :where (list := :_id id))
             :dialect (dialect store))))
  t)
