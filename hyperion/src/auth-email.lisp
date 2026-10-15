;;;; auth-email.lisp --- email confirmation, change of address and password reset (#690).
;;;;
;;;; Part of hyperion/auth-db. The design and the maintainer's rulings are on issue #690.
;;;;
;;;; WHAT THE FRAMEWORK DOES AND WHAT THE APP DOES. These functions own the tokens, the checks
;;;; and the writes. They send no mail: hyperion cannot depend on hermes, which is a satellite,
;;;; so every function that creates a token returns it, with the address it is for, and the app
;;;; mails it. The app also renders every page.
;;;;
;;;; THE TOKENS. A token is 256 bits from the OS (aion/random), returned once as hex. The table
;;;; keeps only its SHA-256, so a copy of the table does not hold a usable token. Each token has
;;;; a purpose, and is good only for that purpose, for the address it was sent to, and once:
;;;;
;;;;   confirm  -- proves the account's current address receives mail (signup, or a resend)
;;;;   change   -- sent to a NEW address; using it moves the account to that address
;;;;   revert   -- sent to the OLD address when a change completes; using it moves the account
;;;;               back, and ends every session of the account
;;;;   reset    -- a password reset, sent to the current address
;;;;
;;;; WHICH TOKENS A CHANGE CANCELS. A change of address, by the user or by an operator, cancels
;;;; the user's outstanding confirm, change and reset tokens: a token mailed to an address the
;;;; account no longer has must not keep working. It does NOT cancel revert tokens. A hijacker
;;;; who moved the account to an address they hold could otherwise make a second change and so
;;;; cancel the revert link the owner was sent. A revert cancels every token, revert tokens
;;;; included, because the hijacker may hold a revert token for their own address.
;;;;
;;;; THE EMAIL_CONFIRMED_AT COLUMN IS NOT IN USERS-DDL, deliberately. docs/migrations.md §8: a
;;;; migration that calls USERS-DDL runs it when the migrations run, so adding the column there
;;;; would make every fresh database replaying an old timeline create it, and the ALTER that an
;;;; existing database needs would then fail on it. So every timeline, new or old, adds it with
;;;; its own USERS-EMAIL-CONFIRMED-DDL step.

(in-package #:hyperion/auth-db)

;;; --- conditions -----------------------------------------------------------------------------

(define-condition missing-email-tables (error)
  ((store :initarg :store :reader %missing-email-tables-store)
   (cause :initarg :cause :initform nil :reader missing-email-tables-cause))
  (:report
   (lambda (c s)
     (let* ((store (%missing-email-tables-store c))
            (d (dialect store)))
       (format s "hyperion/auth-db: the email confirmation tables could not be read (~A).~%"
               (missing-email-tables-cause c))
       (format s "~%They are the column email_confirmed_at in ~A, and the tables ~A and ~A (#690).~%"
               (table store) (tokens-table store) (email-events-table store))
       (format s "Add these steps to your migrations, each with its own id:~%~%")
       (format s "  (auth:users-email-confirmed-ddl :dialect ~S)~%" d)
       (format s "  (auth:email-tokens-ddl :dialect ~S)~%" d)
       (format s "  (auth:email-tokens-hash-index-ddl)~%")
       (format s "  (auth:email-tokens-user-index-ddl)~%")
       (format s "  (auth:email-events-ddl :dialect ~S)~%" d)
       (format s "  (auth:email-events-index-ddl)~%")
       (format s "~%Existing accounts start unconfirmed. To mark them confirmed instead, add:~%~%")
       (format s "  UPDATE ~A SET email_confirmed_at = created_at WHERE email_confirmed_at IS NULL~%"
               (table store))
       (format s "~%See docs/migrations.md, section 5. An app that uses none of the confirmation,~%")
       (format s "change-of-address or password-reset functions can pass :REQUIRE-EMAIL-TABLES NIL~%")
       (format s "to MAKE-DB-AUTH instead.~%"))))
  (:documentation "Signalled by MAKE-DB-AUTH when the email confirmation column or tables cannot
be read (#690). CAUSE is the database's own error. The report names the migrations."))

(define-condition invalid-token (error)
  ((reason :initarg :reason :reader invalid-token-reason))
  (:report (lambda (c s)
             (format s "hyperion/auth-db: the token cannot be used (~(~A~))."
                     (invalid-token-reason c))))
  (:documentation "A token that cannot be used. REASON is :UNKNOWN (no such token, or one for
another purpose), :USED, :EXPIRED, or :SUPERSEDED (the account no longer has the address the
token was sent to, or the user it was for is gone). Show the visitor the same page for all four;
the reason is for the log."))

(define-condition too-many-tokens (error)
  ((purpose :initarg :purpose :reader too-many-tokens-purpose)
   (retry-after :initarg :retry-after :reader too-many-tokens-retry-after))
  (:report (lambda (c s)
             (format s "hyperion/auth-db: too many ~(~A~) tokens for this user; try again in ~D seconds."
                     (too-many-tokens-purpose c) (too-many-tokens-retry-after c))))
  (:documentation "The user has been sent the store's TOKEN-LIMIT tokens of this purpose within
its TOKEN-WINDOW. RETRY-AFTER is the seconds until another may be sent."))

(define-condition wrong-password (error) ()
  (:report "hyperion/auth-db: the current password is required and was not given correctly.")
  (:documentation "REQUEST-EMAIL-CHANGE was given a :PASSWORD that does not match, or none."))

(define-condition same-email (error)
  ((email :initarg :email :reader same-email-email))
  (:report (lambda (c s)
             (format s "hyperion/auth-db: the account already has the address ~S." (same-email-email c)))))

;;; --- DDL ----------------------------------------------------------------------------------

(schema:defschema hyperion-email-token (:table "hyperion_email_tokens")
  (:_id        :string  :primary t)
  (:user_id    :string  :required t)
  (:purpose    :string  :required t)   ; confirm | change | revert | reset
  (:email      :string  :required t)   ; the address the token was sent to
  (:token_hash :string  :required t)   ; SHA-256 of the token, hex; the token itself is not kept
  (:created_at :integer :required t)
  (:expires_at :integer :required t)
  (:used_at    :integer))              ; NIL until used or cancelled

(schema:defschema hyperion-email-event (:table "hyperion_email_events")
  (:_id       :string  :primary t)
  (:user_id   :string  :required t)
  (:action    :string  :required t)    ; confirmed | changed | reverted | operator-changed |
                                       ; operator-changed-confirmed
  (:old_email :string)
  (:new_email :string)
  (:actor     :string  :required t)
  (:at        :integer :required t))

(defun users-email-confirmed-ddl (&key (dialect :sqlite) (table *table*))
  "The ALTER TABLE that adds email_confirmed_at to the users table named TABLE (#690). Every
timeline adds it as its own step, new or old; see the header of this file for why USERS-DDL does
not include it."
  (format nil "ALTER TABLE ~A ADD COLUMN email_confirmed_at ~A" (%check-table table)
          (if (member dialect '(:postgres "postgres" "postgresql") :test #'equalp) "BIGINT" "INTEGER")))

(defun email-tokens-ddl (&key (dialect :sqlite) (table *tokens-table*))
  "CREATE TABLE DDL for the token table, named TABLE (#690)."
  (%schema-ddl 'hyperion-email-token table dialect))

(defun email-tokens-hash-index-ddl (&key (table *tokens-table*))
  "The unique index on the token table's token_hash: how a token is looked up."
  (format nil "CREATE UNIQUE INDEX IF NOT EXISTS idx_~A_hash ON ~A (token_hash)"
          (%check-table table) table))

(defun email-tokens-user-index-ddl (&key (table *tokens-table*))
  "The index on the token table's (user_id, purpose, created_at): how the tokens a user was sent
are counted and cancelled."
  (format nil "CREATE INDEX IF NOT EXISTS idx_~A_user ON ~A (user_id, purpose, created_at)"
          (%check-table table) table))

(defun email-events-ddl (&key (dialect :sqlite) (table *email-events-table*))
  "CREATE TABLE DDL for the append-only log of address confirmations and changes (#690)."
  (%schema-ddl 'hyperion-email-event table dialect))

(defun email-events-index-ddl (&key (table *email-events-table*))
  "The index on the email-event log's (user_id, at)."
  (format nil "CREATE INDEX IF NOT EXISTS idx_~A_user_at ON ~A (user_id, at)"
          (%check-table table) table))

(defun %probe (store sql)
  (conn:query (conn store) sql))

(defun %email-column-present-p (store)
  (handler-case (progn (%probe store (format nil "SELECT email_confirmed_at FROM ~A WHERE 1 = 0"
                                             (table store)))
                       t)
    (error () nil)))

(defun %ensure-email-schema (store)
  "Create the email column, tables and indexes when absent. Called by ENSURE-SCHEMA, inside its
connection."
  (unless (%email-column-present-p store)
    (conn:exec (conn store) (users-email-confirmed-ddl :dialect (dialect store) :table (table store))))
  (conn:exec (conn store) (email-tokens-ddl :dialect (dialect store) :table (tokens-table store)))
  (conn:exec (conn store) (email-tokens-hash-index-ddl :table (tokens-table store)))
  (conn:exec (conn store) (email-tokens-user-index-ddl :table (tokens-table store)))
  (conn:exec (conn store) (email-events-ddl :dialect (dialect store) :table (email-events-table store)))
  (conn:exec (conn store) (email-events-index-ddl :table (email-events-table store))))

(defun %check-email-tables (store)
  "Signal MISSING-EMAIL-TABLES unless the column and both tables can be read. Queries that return
no rows."
  (handler-case
      (with-store-connection (store)
        (%probe store (format nil "SELECT email_confirmed_at FROM ~A WHERE 1 = 0" (table store)))
        (%probe store (format nil "SELECT _id, user_id, purpose, email, token_hash, created_at, expires_at, used_at FROM ~A WHERE 1 = 0"
                              (tokens-table store)))
        (%probe store (format nil "SELECT _id, user_id, action, old_email, new_email, actor, at FROM ~A WHERE 1 = 0"
                              (email-events-table store))))
    (error (e)
      (error 'missing-email-tables :store store :cause e))))

;;; --- tokens -------------------------------------------------------------------------------

(defun %now (store) (funcall (store-clock store)))

(defun %token-hash (token)
  (ironclad:byte-array-to-hex-string (ironclad:digest-sequence :sha256 (%octets token))))

(defun %purpose-word (purpose) (string-downcase (symbol-name purpose)))

(defun %issue-token (store user-id purpose email now &key (limit t))
  "Insert a token of PURPOSE for USER-ID, sent to EMAIL. Returns (values token expires-at).
Signals TOO-MANY-TOKENS when LIMIT is true and the user has had the store's limit of this purpose
within its window. Runs inside an exclusive store connection."
  (when limit
    (let* ((since (- now (token-window store)))
           (rows (conn:query (conn store)
                             (format nil "SELECT created_at FROM ~A WHERE user_id = ? AND purpose = ? AND created_at > ? ORDER BY created_at"
                                     (tokens-table store))
                             user-id (%purpose-word purpose) since)))
      (when (>= (length rows) (token-limit store))
        (error 'too-many-tokens
               :purpose purpose
               :retry-after (max 1 (- (+ (%to-int (%rget (first rows) :created_at))
                                         (token-window store))
                                      now))))))
  (let ((token (rnd:random-hex 256))
        (expires (+ now (getf (token-seconds store) purpose))))
    (conn:exec (conn store)
               (format nil "INSERT INTO ~A (_id, user_id, purpose, email, token_hash, created_at, expires_at, used_at) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)"
                       (tokens-table store))
               (id:new-id) user-id (%purpose-word purpose) email (%token-hash token) now expires)
    (values token expires)))

(defun %take-token (store token purpose now)
  "Mark TOKEN used and return its row, or signal INVALID-TOKEN. Runs inside a transaction on an
exclusive store connection, so a failure later in the caller's transaction leaves it unused."
  (let ((row (and (stringp token)
                  (first (conn:query (conn store)
                                     (format nil "SELECT _id, user_id, purpose, email, expires_at, used_at FROM ~A WHERE token_hash = ?"
                                             (tokens-table store))
                                     (%token-hash token))))))
    (cond ((or (null row) (not (equal (%rget row :purpose) (%purpose-word purpose))))
           (error 'invalid-token :reason :unknown))
          ((%rget row :used_at) (error 'invalid-token :reason :used))
          ((< (%to-int (%rget row :expires_at)) now) (error 'invalid-token :reason :expired)))
    ;; Conditional, so two requests with one token cannot both use it.
    (unless (plusp (%to-int (conn:exec (conn store)
                                       (format nil "UPDATE ~A SET used_at = ? WHERE _id = ? AND used_at IS NULL"
                                               (tokens-table store))
                                       now (%rget row :_id))))
      (error 'invalid-token :reason :used))
    row))

(defun %cancel-tokens (store user-id now &key (include-revert nil))
  "Mark the user's unused tokens used: all of them with INCLUDE-REVERT, else all but revert
tokens. See the header for why a change keeps revert tokens."
  (conn:exec (conn store)
             (format nil "UPDATE ~A SET used_at = ? WHERE user_id = ? AND used_at IS NULL~:[ AND purpose <> 'revert'~;~]"
                     (tokens-table store) include-revert)
             now user-id))

(defun %record-email-event (store user-id action old new actor now)
  (conn:exec (conn store)
             (format nil "INSERT INTO ~A (_id, user_id, action, old_email, new_email, actor, at) VALUES (?, ?, ?, ?, ?, ?, ?)"
                     (email-events-table store))
             (id:new-id) user-id action old new actor now))

(defun %user-row (store user-id)
  (first (conn:query (conn store) (format nil "SELECT * FROM ~A WHERE _id = ?" (table store))
                     user-id)))

(defun %email-taken-p (store email user-id)
  "True when an account other than USER-ID has EMAIL."
  (conn:query (conn store) (format nil "SELECT _id FROM ~A WHERE email = ? AND _id <> ?" (table store))
              email user-id))

(defun %write-email (store user-id old new confirmed-at now)
  "Move USER-ID from OLD to NEW. Returns true when it wrote: the account still had OLD. Signals
DUPLICATE-EMAIL when the unique index refuses NEW, as CREATE-USER does."
  (handler-case
      (plusp (%to-int (conn:exec (conn store)
                                 (format nil "UPDATE ~A SET email = ?, email_confirmed_at = ?, updated_at = ?, vid = vid + 1 WHERE _id = ? AND email = ?"
                                         (table store))
                                 new confirmed-at now user-id old)))
    (conn:db-error (e)
      (if (search "UNIQUE" (or (conn:db-error-message e) "") :test #'char-equal)
          (error 'duplicate-email :email new)
          (error e)))))

;;; --- confirmation at signup ---------------------------------------------------------------

(defun issue-confirmation (store user-id)
  "A token that confirms USER-ID's current address, for signup or a resend. Returns
(values token email expires-at): mail a link carrying TOKEN to EMAIL. Returns NIL when there is
no such user or the address is already confirmed. Signals TOO-MANY-TOKENS past the store's limit."
  (with-store-connection (store :exclusive t)
    (let ((row (%user-row store user-id))
          (now (%now store)))
      (when (and row (null (%rget row :email_confirmed_at)))
        (multiple-value-bind (token expires) (%issue-token store user-id :confirm (%rget row :email) now)
          (values token (%rget row :email) expires))))))

(defun confirm-email (store token)
  "Confirm the address a confirmation TOKEN was sent to. Returns the USER. Signals INVALID-TOKEN
when the token is unknown, used or expired, or the account no longer has that address
(:SUPERSEDED)."
  (let ((user-id
          (with-store-connection (store :exclusive t)
            (let ((now (%now store)))
              (conn:with-transaction ((conn store))
                (let* ((tok (%take-token store token :confirm now))
                       (user-id (%rget tok :user_id))
                       (email (%rget tok :email)))
                  (unless (plusp (%to-int
                                  (conn:exec (conn store)
                                             (format nil "UPDATE ~A SET email_confirmed_at = ?, updated_at = ? WHERE _id = ? AND email = ?"
                                                     (table store))
                                             now now user-id email)))
                    (error 'invalid-token :reason :superseded))
                  (%record-email-event store user-id "confirmed" email email user-id now)
                  user-id))))))
    (find-user-by-id store user-id)))

;;; --- change of address --------------------------------------------------------------------

(defun request-email-change (store user-id new-email &key password)
  "Start moving USER-ID to NEW-EMAIL. Nothing changes until the new address confirms it with
CONFIRM-EMAIL-CHANGE. Returns (values token new-email old-email expires-at): mail a link carrying
TOKEN to NEW-EMAIL, and a notice to OLD-EMAIL that a change was asked for.

PASSWORD is the account's current password, so a session someone else has taken over cannot
start a change; it signals WRONG-PASSWORD when it does not match, including when it is not
given. Pass :PASSWORD :SKIP for an account that signs in without one.

Signals DUPLICATE-EMAIL when another account has NEW-EMAIL, SAME-EMAIL when this one does, and
TOO-MANY-TOKENS past the store's limit. Returns NIL when there is no such user."
  (let ((user (find-user-by-id store user-id))
        (new (%norm-email new-email)))
    (when user
      ;; Verified before the store's lock is taken: PBKDF2 is deliberately slow.
      (unless (or (eq password :skip)
                  (and (stringp password) (verify-password password (user-hash user))))
        (error 'wrong-password))
      (with-store-connection (store :exclusive t)
        (let* ((now (%now store))
               (row (%user-row store user-id))
               (old (and row (%rget row :email))))
          (when row
            (when (equal new old) (error 'same-email :email new))
            (when (%email-taken-p store new user-id) (error 'duplicate-email :email new))
            (multiple-value-bind (token expires) (%issue-token store user-id :change new now)
              (values token new old expires))))))))

(defun confirm-email-change (store token &key actor)
  "Complete a change of address with the TOKEN mailed to the new address. From any browser: the
token is the proof. In one transaction it moves the account to the new address, marks it
confirmed, cancels the user's outstanding confirm, change and reset tokens, records the change,
and creates a revert token for the old address.

Returns (values user old-email revert-token revert-expires-at): mail a link carrying
REVERT-TOKEN to OLD-EMAIL, saying the address was changed and how to undo it. Then end the
user's other sessions (HYPERION/SESSION:END-SESSIONS) and rotate the current one.

ACTOR is recorded with the change, and defaults to the user's id. Signals INVALID-TOKEN, and
DUPLICATE-EMAIL when another account took the address after the request; the token is then left
unused."
  (let (user-id old revert revert-expires)
    (with-store-connection (store :exclusive t)
      (let ((now (%now store)))
        (conn:with-transaction ((conn store))
          (let* ((tok (%take-token store token :change now))
                 (new (%rget tok :email))
                 (row (%user-row store (%rget tok :user_id))))
            (unless row (error 'invalid-token :reason :superseded))
            (setf user-id (%rget row :_id)
                  old (%rget row :email))
            (when (%email-taken-p store new user-id) (error 'duplicate-email :email new))
            (unless (%write-email store user-id old new now now)
              (error 'invalid-token :reason :superseded))
            (%cancel-tokens store user-id now)
            (%record-email-event store user-id "changed" old new (or actor user-id) now)
            (multiple-value-setq (revert revert-expires)
              (%issue-token store user-id :revert old now :limit nil))))))
    (values (find-user-by-id store user-id) old revert revert-expires)))

(defun revert-email-change (store token session-store &key (session-key :user-id) actor)
  "Undo a change of address with the TOKEN mailed to the old address: move the account back to
that address, mark it confirmed, cancel every outstanding token of the user (revert tokens
included), record it, and end every session of the user in SESSION-STORE.

SESSION-STORE is required, because a revert means someone else may hold a session: a
HYPERION/SESSION store, whose sessions hold the user's id under SESSION-KEY (:USER-ID, as
SIGN-IN! is usually called). Pass :NONE for an app that keeps no server-side sessions.

Returns (values user sessions-ended). Consider also sending ISSUE-PASSWORD-RESET's token to the
restored address, since whoever made the change may have changed the password. ACTOR defaults to
the user's id. Signals INVALID-TOKEN, and DUPLICATE-EMAIL when another account now has the old
address."
  (unless (or (eq session-store :none) session-store)
    (error "hyperion/auth-db: REVERT-EMAIL-CHANGE needs the session store, or :NONE"))
  (let (user-id)
    (with-store-connection (store :exclusive t)
      (let ((now (%now store)))
        (conn:with-transaction ((conn store))
          (let* ((tok (%take-token store token :revert now))
                 (restore (%rget tok :email))
                 (row (%user-row store (%rget tok :user_id))))
            (unless row (error 'invalid-token :reason :superseded))
            (setf user-id (%rget row :_id))
            (let ((current (%rget row :email)))
              (when (%email-taken-p store restore user-id) (error 'duplicate-email :email restore))
              (unless (%write-email store user-id current restore now now)
                (error 'invalid-token :reason :superseded))
              (%cancel-tokens store user-id now :include-revert t)
              (%record-email-event store user-id "reverted" current restore (or actor user-id) now))))))
    (let ((ended (if (eq session-store :none)
                     0
                     (session:end-sessions session-store session-key user-id))))
      (values (find-user-by-id store user-id) ended))))

(defun set-email (store user-id new-email &key actor confirmed)
  "The operator path: move USER-ID to NEW-EMAIL at once, recording ACTOR (required, as for
GRANT-ROLE). The address is unconfirmed afterwards unless CONFIRMED is true, for an operator who
has verified it another way; the event records which. Cancels the user's outstanding confirm,
change and reset tokens. Returns the USER, or NIL when there is no such user. Signals
DUPLICATE-EMAIL, SAME-EMAIL and MISSING-ACTOR.

To have the new address prove itself, call ISSUE-CONFIRMATION afterwards.

**This does not authorise the caller**, like everything in this module."
  (%require-actor actor "SET-EMAIL")
  (let ((new (%norm-email new-email))
        (found nil))
    (with-store-connection (store :exclusive t)
      (let ((now (%now store)))
        (conn:with-transaction ((conn store))
          (let ((row (%user-row store user-id)))
            (when row
              (let ((old (%rget row :email)))
                (when (equal new old) (error 'same-email :email new))
                (when (%email-taken-p store new user-id) (error 'duplicate-email :email new))
                (%write-email store user-id old new (and confirmed now) now)
                (%cancel-tokens store user-id now)
                (%record-email-event store user-id
                                     (if confirmed "operator-changed-confirmed" "operator-changed")
                                     old new actor now)
                (setf found t)))))))
    (and found (find-user-by-id store user-id))))

;;; --- password reset -----------------------------------------------------------------------

(defun issue-password-reset (store email)
  "A password-reset token for the account with EMAIL. Returns (values token user expires-at):
mail a link carrying TOKEN to the account's address. Returns NIL when no account has EMAIL; the
app must then show the same page as when one does, or the form tells anyone which addresses
have accounts. Signals TOO-MANY-TOKENS past the store's limit."
  (with-store-connection (store :exclusive t)
    (let ((user (find-user-by-email store email)))
      (when user
        (multiple-value-bind (token expires)
            (%issue-token store (user-id user) :reset (user-email user) (%now store))
          (values token user expires))))))

(defun reset-password (store token new-plaintext)
  "Set a new password with a reset TOKEN, and clear the temp-password flag. Cancels the user's
other reset tokens. Returns the USER. Signals INVALID-TOKEN, including :SUPERSEDED when the
account's address has changed since the token was sent. Consider ending the user's other
sessions afterwards (HYPERION/SESSION:END-SESSIONS)."
  (let ((hash (hash-password new-plaintext))
        user-id)
    (with-store-connection (store :exclusive t)
      (let ((now (%now store)))
        (conn:with-transaction ((conn store))
          (let* ((tok (%take-token store token :reset now)))
            (setf user-id (%rget tok :user_id))
            (unless (plusp (%to-int
                            (conn:exec (conn store)
                                       (format nil "UPDATE ~A SET pw_hash = ?, temp_password = 0, updated_at = ? WHERE _id = ? AND email = ?"
                                               (table store))
                                       hash now user-id (%rget tok :email))))
              (error 'invalid-token :reason :superseded))
            (conn:exec (conn store)
                       (format nil "UPDATE ~A SET used_at = ? WHERE user_id = ? AND purpose = 'reset' AND used_at IS NULL"
                               (tokens-table store))
                       now user-id)))))
    (find-user-by-id store user-id)))

;;; --- history and pruning ------------------------------------------------------------------

(defun email-history (store user-id)
  "Every recorded confirmation and change of USER-ID's address, oldest first, as plists
(:ACTION :OLD-EMAIL :NEW-EMAIL :ACTOR :AT)."
  (mapcar (lambda (row)
            (list :action (%rget row :action) :old-email (%rget row :old_email)
                  :new-email (%rget row :new_email) :actor (%rget row :actor)
                  :at (%to-int (%rget row :at))))
          (with-store-connection (store)
            (conn:query (conn store)
                        (format nil "SELECT action, old_email, new_email, actor, at FROM ~A WHERE user_id = ? ORDER BY at, _id"
                                (email-events-table store))
                        user-id))))

(defun prune-email-tokens (store &key (before (%now store)))
  "Delete tokens that expired before BEFORE (by default now), used or not. A used token that has
not yet expired is kept, so a second use of it still reports :USED rather than :UNKNOWN. Returns
how many were deleted."
  (with-store-connection (store :exclusive t)
    (%to-int (conn:exec (conn store)
                        (format nil "DELETE FROM ~A WHERE expires_at < ?" (tokens-table store))
                        before))))
