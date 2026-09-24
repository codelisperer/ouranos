;;;; auth-db-tests.lisp --- integration tests for the mnemosyne-backed identity store.
;;;;
;;;; Own package + system so core Hyperion keeps no DB dependency. In-memory SQLite, one
;;;; connection per test.

(cl:defpackage #:hyperion/auth-db/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:auth #:hyperion/auth-db)
                    (#:conn #:mnemosyne/conn)
                    (#:q    #:mnemosyne/query)
                    (#:bt   #:bordeaux-threads)
                    (#:be   #:mnemosyne/backend))
  (:export #:run-tests))
(in-package #:hyperion/auth-db/tests)

(def-suite auth-db :description "mnemosyne-backed identity store: users + password auth.")
(defun run-tests () (run! 'auth-db))
(in-suite auth-db)

(defmacro with-auth ((var) &body body)
  (let ((c (gensym)))
    `(let ((,c (conn:connect (be:make-sqlite ":memory:"))))
       (unwind-protect
            (let ((,var (auth:make-db-auth ,c :dialect :sqlite :ensure t)))
              ,@body)
         (conn:disconnect ,c)))))

(test password-hash-round-trips
  (let ((h (auth:hash-password "s3cret-pass")))
    (is (stringp h))
    (is (auth:verify-password "s3cret-pass" h))
    (is (not (auth:verify-password "wrong" h)))
    (is (not (auth:verify-password "s3cret-pass" nil)))))

(test create-and-find-by-email-normalizes-and-round-trips
  (with-auth (a)
    (let ((u (auth:create-user a :email "Bob@example.COM" :phone "+18135233751"
                                 :password "pw" :roles '(:super-admin))))
      (is (auth:user-p u))
      (is (string= "bob@example.com" (auth:user-email u)))   ; normalized
      (is (string= "+18135233751" (auth:user-phone u)))
      (is (equal '(:super-admin) (auth:user-roles u))))
    (let ((got (auth:find-user-by-email a "BOB@example.com")))   ; case-insensitive lookup
      (is (auth:user-p got))
      (is (equal '(:super-admin) (auth:user-roles got))))
    (is (null (auth:find-user-by-email a "nobody@x.com")))))

(test phone-is-optional
  (with-auth (a)
    (let ((u (auth:create-user a :email "np@x.com" :password "pw")))
      (is (null (auth:user-phone u))))))

(test authenticate-checks-password
  (with-auth (a)
    (auth:create-user a :email "u@x.com" :password "right")
    (is (auth:user-p (auth:authenticate a "u@x.com" "right")))
    (is (auth:user-p (auth:authenticate a "U@X.com" "right")))   ; email case-insensitive
    (is (null (auth:authenticate a "u@x.com" "wrong")))
    (is (null (auth:authenticate a "missing@x.com" "right")))))

(test temp-password-flag-and-forced-change
  (with-auth (a)
    (let ((u (auth:create-user a :email "t@x.com" :password "temp123" :temp-password-p t)))
      (is (auth:user-temp-password-p u))
      ;; complete the forced change: set a new password, clearing the temp flag
      (auth:set-password a (auth:user-id u) "chosen-pw")
      (let ((got (auth:find-user-by-email a "t@x.com")))
        (is (not (auth:user-temp-password-p got)))
        (is (auth:user-p (auth:authenticate a "t@x.com" "chosen-pw")))
        (is (null (auth:authenticate a "t@x.com" "temp123")))))))   ; old temp no longer valid

(test duplicate-email-signals
  (with-auth (a)
    (auth:create-user a :email "dup@x.com" :password "pw")
    (signals auth:duplicate-email (auth:create-user a :email "DUP@x.com" :password "pw2"))))

(test find-by-id
  (with-auth (a)
    (let ((u (auth:create-user a :email "id@x.com" :password "pw")))
      (is (string= "id@x.com" (auth:user-email (auth:find-user-by-id a (auth:user-id u)))))
      (is (null (auth:find-user-by-id a "no-such-id"))))))

;;; --- roles: grant / revoke ------------------------------------------------
;;;
;;; The gap these close: roles could be decided once, at creation, and never again -- so an
;;; app could not promote a moderator, appoint a second administrator, or (the direction you
;;; least want to be slow at) revoke either. The app that reported it had reached around the
;;; API and written the framework's own table, duplicating the serialisation format by hand.

(defvar *store-connection* nil
  "The raw connection behind the store under test -- so a test can look at columns the
public surface does not expose (`vid`, which is what the compare-and-swap guards on).")

(defmacro with-auth-roles ((var &rest make-args) &body body)
  "WITH-AUTH, but passing extra arguments through to MAKE-DB-AUTH and keeping the raw
connection reachable as *STORE-CONNECTION*."
  `(let ((*store-connection* (conn:connect (be:make-sqlite ":memory:"))))
     (unwind-protect
          (let ((,var (auth:make-db-auth *store-connection*
                                         :dialect :sqlite :ensure t ,@make-args)))
            ,@body)
       (conn:disconnect *store-connection*))))

(defun %roles-of (store id)
  (auth:user-roles (auth:find-user-by-id store id)))

(defun %vid-of (id)
  "Read the row version directly -- the value the compare-and-swap is guarding on. Drivers
disagree on result-key case, so match the column name case-insensitively."
  (let* ((rows (q:fetch *store-connection*
                        (list :select '(:vid) :from (list auth:*table*)
                              :where (list := :_id id))
                        :dialect :sqlite))
         (row (first rows)))
    (loop for (k v) on row by #'cddr
          when (and (symbolp k) (string-equal (symbol-name k) "VID")) do (return v))))

(test grant-role-adds-without-disturbing-the-others
  (with-auth (a)
    (let ((id (auth:user-id (auth:create-user a :email "g@x.com" :roles '(:member)))))
      (is (eq t (auth:grant-role a id :moderator :actor "test")))
      (is (equal '(:member :moderator) (%roles-of a id)))
      (auth:grant-role a id :editor :actor "test")
      (is (equal '(:member :moderator :editor) (%roles-of a id)))
      ;; the whole point: the pre-existing role is still there
      (is (member :member (%roles-of a id))))))

(test revoke-role-removes-only-the-named-one
  (with-auth (a)
    (let ((id (auth:user-id (auth:create-user a :email "r@x.com"
                                                :roles '(:member :moderator :editor)))))
      (is (eq t (auth:revoke-role a id :moderator :actor "test")))
      (is (equal '(:member :editor) (%roles-of a id))))))

(test grant-and-revoke-are-idempotent
  ;; An admin console clicking "grant" twice, or two admins revoking the same role, must not
  ;; be an error -- the end state is what was asked for either way.
  (with-auth (a)
    (let ((id (auth:user-id (auth:create-user a :email "i@x.com" :roles '(:member)))))
      (is (eq t (auth:grant-role a id :member :actor "test")))          ; already held
      (is (equal '(:member) (%roles-of a id)))
      (is (eq t (auth:revoke-role a id :ghost :actor "test")))          ; never held
      (is (equal '(:member) (%roles-of a id)))
      (auth:revoke-role a id :member :actor "test")
      (is (null (%roles-of a id)))
      (is (eq t (auth:revoke-role a id :member :actor "test"))))))      ; and again, on an empty list

(test a-no-op-grant-does-not-bump-the-version
  ;; If an idempotent grant bumped `vid` it would invalidate some other writer's in-flight
  ;; compare-and-swap for no reason at all.
  (with-auth-roles (a)
    (let* ((id (auth:user-id (auth:create-user a :email "v@x.com" :roles '(:member))))
           (before (%vid-of id)))
      (is (integerp before))
      (auth:grant-role a id :member :actor "test")
      (is (eql before (%vid-of id)) "no-op grant must not write")
      (auth:grant-role a id :moderator :actor "test")
      (is (= (1+ before) (%vid-of id)) "a real change bumps the version"))))

(test roles-round-trip-through-the-frameworks-own-serialisation
  ;; The format the reporting app was duplicating by hand with ~S. If it ever changes, this
  ;; is what says so -- rather than a user silently losing their roles at next login.
  (with-auth (a)
    (let ((id (auth:user-id (auth:create-user a :email "s@x.com"))))
      (auth:grant-role a id :super-admin :actor "test")
      (auth:grant-role a id :billing-manager :actor "test")
      ;; survives a re-read from the database, keywords intact
      (let ((roles (%roles-of a id)))
        (is (equal '(:super-admin :billing-manager) roles))
        (is (every #'keywordp roles))))))

(test mutating-roles-on-a-missing-user-reports-rather-than-inventing-one
  (with-auth (a)
    (is (null (auth:grant-role a "no-such-id" :admin :actor "test")))
    (is (null (auth:revoke-role a "no-such-id" :admin :actor "test")))))

(test concurrent-grants-of-different-roles-all-survive
  ;; This is the bug a wholesale SET-ROLES would have had: each thread reads the list, adds
  ;; its own role, writes the whole thing back, and the losers vanish silently. Here the
  ;; read-modify-write is inside the store, so every grant must be present at the end.
  (with-auth (a)
    (let* ((id (auth:user-id (auth:create-user a :email "c@x.com")))
           (roles '(:alpha :bravo :charlie :delta :echo :foxtrot :golf :hotel))
           (threads (mapcar (lambda (r)
                              (bt:make-thread (lambda () (auth:grant-role a id r :actor "test"))
                                              :name (format nil "grant-~A" r)))
                            roles)))
      (aion/test-threads:join-all threads)
      (let ((final (%roles-of a id)))
        (is (= (length roles) (length final)) "every grant must survive: got ~S" final)
        (dolist (r roles)
          (is (member r final) "~S was lost" r))))))

(test the-compare-and-swap-gives-up-rather-than-spinning-forever
  ;; Driving the retry budget to zero exercises the give-up path deterministically, without
  ;; needing to win a race against a real second writer.
  (with-auth (a)
    (let ((id (auth:user-id (auth:create-user a :email "x@x.com"))))
      (let ((auth:*role-update-attempts* 0))
        (signals auth:role-update-conflict (auth:grant-role a id :admin :actor "test")))
      ;; and the failure wrote nothing
      (is (null (%roles-of a id))))))

;;; --- the last-administrator question --------------------------------------
;;;
;;; Deliberately NOT the store's decision: roles are arbitrary keywords, so it cannot know
;;; :SUPER-ADMIN outranks :MODERATOR, and teaching it would mean the framework inventing
;;; application vocabulary. USERS-WITH-ROLE makes the app's own guard a one-liner.

(test users-with-role-finds-every-holder
  (with-auth (a)
    (auth:create-user a :email "a1@x.com" :roles '(:super-admin))
    (auth:create-user a :email "a2@x.com" :roles '(:member))
    (let ((id3 (auth:user-id (auth:create-user a :email "a3@x.com" :roles '(:member)))))
      (is (= 1 (length (auth:users-with-role a :super-admin))))
      (auth:grant-role a id3 :super-admin :actor "test")
      (is (= 2 (length (auth:users-with-role a :super-admin))))
      (is (member id3 (auth:users-with-role a :super-admin) :test #'string=))
      (is (null (auth:users-with-role a :nobody-has-this))))))

(test the-store-will-revoke-the-last-admin-and-the-app-is-what-stops-it
  ;; Both halves matter. The store must not refuse (it cannot know), and the guard the app
  ;; writes on top of USERS-WITH-ROLE must actually catch it.
  (with-auth (a)
    (let ((id (auth:user-id (auth:create-user a :email "solo@x.com" :roles '(:super-admin)))))
      ;; the app's one-line guard sees it coming
      (is (= 1 (length (auth:users-with-role a :super-admin))))
      ;; and the store, asked directly, does it anyway
      (auth:revoke-role a id :super-admin :actor "test")
      (is (null (auth:users-with-role a :super-admin))))))

;;; --- the optional role vocabulary -----------------------------------------

(test without-a-vocabulary-any-keyword-is-accepted
  ;; The historical behaviour, and the default: :MODERATER is stored happily and grants
  ;; nothing. Kept so existing callers are unaffected.
  (with-auth (a)
    (let ((id (auth:user-id (auth:create-user a :email "free@x.com"))))
      (auth:grant-role a id :moderater :actor "test")
      (is (equal '(:moderater) (%roles-of a id))))))

(test with-a-vocabulary-a-typo-is-an-error-at-the-point-of-the-mistake
  (with-auth-roles (a :known-roles '(:member :moderator :super-admin))
    (let ((id (auth:user-id (auth:create-user a :email "voc@x.com" :roles '(:member)))))
      (signals auth:unknown-role (auth:grant-role a id :moderater :actor "test"))
      (is (equal '(:member) (%roles-of a id)) "the bad grant wrote nothing")
      (is (eq t (auth:grant-role a id :moderator :actor "test")))
      ;; revoke checks too -- a typo on the way out silently no-ops otherwise, which is the
      ;; worse direction: you believe you removed a role and you did not
      (signals auth:unknown-role (auth:revoke-role a id :moderater :actor "test"))
      (is (member :moderator (%roles-of a id))))))

(test a-vocabulary-is-enforced-at-creation-too
  (with-auth-roles (a :known-roles '(:member))
    (signals auth:unknown-role
      (auth:create-user a :email "bad@x.com" :roles '(:member :nonsense)))))

(test a-role-must-be-a-keyword
  (with-auth (a)
    (let ((id (auth:user-id (auth:create-user a :email "kw@x.com"))))
      (signals type-error (auth:grant-role a id "admin" :actor "test")))))

;;; --- the compare-and-swap actually retrying -------------------------------
;;;
;;; Everything above runs in one image, where the store's lock serialises writers and the
;;; swap therefore never loses. That makes the in-image tests silent about the case the swap
;;; exists FOR: a second process -- another app instance, another box behind a load balancer
;;; -- committing between our read and our write, where no lock in this image applies.
;;;
;;; So this drives that case deterministically instead of racing for it: a file-backed
;;; database with TWO connections (which is what two processes look like from SQLite's side),
;;; and a competing commit interposed exactly between the read and the write. It reaches for
;;; the internal %UPDATE-ROLES because that is the only way to place the interloper at the
;;; one instant that matters rather than hoping a thread lands there.

(defun %temp-db-path (tag)
  (merge-pathnames (format nil "hyperion-auth-cas-~A-~D.sqlite" tag (get-universal-time))
                   (uiop:temporary-directory)))

(test a-lost-compare-and-swap-retries-and-keeps-the-other-writers-change
  (let ((path (%temp-db-path "retry")))
    (unwind-protect
         (let* ((ca (conn:connect (be:make-sqlite (namestring path))))
                (cb (conn:connect (be:make-sqlite (namestring path)))))
           (unwind-protect
                (let* ((a (auth:make-db-auth ca :dialect :sqlite :ensure t))
                       (b (auth:make-db-auth cb :dialect :sqlite))   ; same rows, other "process"
                       (id (auth:user-id (auth:create-user a :email "cas@x.com"
                                                             :roles '(:member))))
                       (interposed 0))
                  ;; On the FIRST pass only, the other connection commits first. A's write is
                  ;; then guarding on a `vid` that no longer exists, must affect zero rows,
                  ;; and must re-read rather than clobber.
                  (let ((result
                          (hyperion/auth-db::%update-roles
                           a id
                           (lambda (roles)
                             (when (zerop interposed)
                               (incf interposed)
                               (auth:grant-role b id :interloper :actor "test"))
                             (append roles (list :mine))))))
                    (is (eq t result))
                    (is (= 1 interposed) "the competing write must have happened once")
                    (let ((final (auth:user-roles (auth:find-user-by-id a id))))
                      ;; Both survive. Without the retry, :INTERLOPER would have been
                      ;; overwritten and lost -- silently, which is the whole problem.
                      (is (member :interloper final) "the other writer's change was clobbered")
                      (is (member :mine final) "our own change did not land")
                      (is (member :member final) "the pre-existing role was lost"))))
             (conn:disconnect ca)
             (conn:disconnect cb)))
      (ignore-errors (delete-file path)))))

;;; --- pre-publication issue 166: role changes must be auditable ------------------------------------
;;;
;;; `roles' holds only CURRENT STATE, so the questions actually asked after an incident --
;;; who granted :super-admin and when, who removed the moderator, was the account escalated
;;; before or after -- were unanswerable. `updated_at' does not narrow the window either:
;;; it moves on any user write, a password change included.

(test a-grant-is-recorded-with-who-and-when
  (with-auth (a)
    (let ((id (auth:user-id (auth:create-user a :email "audit@example.com" :password "pw")))
          (before (get-universal-time)))
      (auth:grant-role a id :moderator :actor "admin-7")
      (let ((history (auth:role-history a id)))
        (is (= 1 (length history)) "expected one event, got ~S" history)
        (let ((e (first history)))
          (is (eq :moderator (getf e :role)))
          (is (string= "grant" (getf e :action)))
          (is (string= "admin-7" (getf e :actor)))
          (is (<= before (getf e :at)) "the timestamp must be the moment of the change"))))))

(test the-history-reconstructs-the-order-of-events
  ;; The question is "was this account escalated before or after the incident", so ordering
  ;; is the property, not merely presence.
  (with-auth (a)
    (let ((id (auth:user-id (auth:create-user a :email "order@example.com" :password "pw"))))
      (auth:grant-role a id :moderator :actor "alice")
      (auth:grant-role a id :editor :actor "bob")
      (auth:revoke-role a id :moderator :actor "carol")
      (let ((history (auth:role-history a id)))
        (is (equal '("grant" "grant" "revoke") (mapcar (lambda (e) (getf e :action)) history)))
        (is (equal '(:moderator :editor :moderator) (mapcar (lambda (e) (getf e :role)) history)))
        (is (equal '("alice" "bob" "carol") (mapcar (lambda (e) (getf e :actor)) history)))))))

(test a-no-op-grant-records-nothing
  ;; An idempotent grant that changed nothing is not a role change, and a log full of them
  ;; is a log nobody reads -- which would defeat the whole point.
  (with-auth (a)
    (let ((id (auth:user-id (auth:create-user a :email "noop@example.com" :password "pw"))))
      (auth:grant-role a id :member :actor "alice")
      (auth:grant-role a id :member :actor "bob")      ; already held
      (auth:revoke-role a id :ghost :actor "carol")    ; never held
      (is (= 1 (length (auth:role-history a id)))
          "only the change that actually happened should be recorded"))))

(test the-history-is-per-user
  (with-auth (a)
    (let ((one (auth:user-id (auth:create-user a :email "one@example.com" :password "pw")))
          (two (auth:user-id (auth:create-user a :email "two@example.com" :password "pw"))))
      (auth:grant-role a one :moderator :actor "alice")
      (auth:grant-role a two :editor :actor "bob")
      (is (= 1 (length (auth:role-history a one))))
      (is (eq :moderator (getf (first (auth:role-history a one)) :role)))
      (is (eq :editor (getf (first (auth:role-history a two)) :role))))))

(test an-actorless-change-is-refused-rather-than-recorded-as-unknown
  ;; The one deliberate break in pre-publication issue 166. An optional audit field is an omitted audit field:
  ;; the caller who most needs the record is the one who has not thought about it.
  (with-auth (a)
    (let ((id (auth:user-id (auth:create-user a :email "noactor@example.com" :password "pw"))))
      (signals auth:missing-actor (auth:grant-role a id :moderator))
      (signals auth:missing-actor (auth:revoke-role a id :moderator))
      (signals auth:missing-actor (auth:grant-role a id :moderator :actor ""))
      ;; ...and the refusal must leave the roles alone. A half-applied change with no
      ;; record is precisely the state this issue exists to prevent.
      (is (null (%roles-of a id)))
      (is (null (auth:role-history a id))))))

(test the-refusal-says-what-to-pass
  (let ((text (princ-to-string (make-condition 'auth:missing-actor :operation "GRANT-ROLE"))))
    (is (search "GRANT-ROLE" text))
    (is (search ":ACTOR" text))
    (is (search "current-user-id" text) "it must show the shape of the fix: ~S" text)))

(test the-event-and-the-change-commit-together
  ;; An audit row that can survive a failed update -- or an update that survives a failed
  ;; audit -- is worse than no audit: a record that is wrong rather than missing, with
  ;; nothing downstream able to tell which. Asserted by their agreeing after a real change.
  (with-auth (a)
    (let ((id (auth:user-id (auth:create-user a :email "atomic@example.com" :password "pw"))))
      (auth:grant-role a id :moderator :actor "alice")
      (is (member :moderator (%roles-of a id)))
      (is (= 1 (length (auth:role-history a id))))
      (auth:revoke-role a id :moderator :actor "alice")
      (is (null (%roles-of a id)))
      (is (= 2 (length (auth:role-history a id))))
      (is (string= "revoke" (getf (second (auth:role-history a id)) :action))))))

(test two-changes-in-the-same-second-still-come-back-in-order
  ;; `at' is whole seconds and these will share one. Ordering is THE property the log
  ;; exists for -- before or after the incident -- so a tie that resolves arbitrarily is a
  ;; wrong answer, not a cosmetic one. The tiebreaker is _id, a time-ordered UUID v6.
  (with-auth (a)
    (let ((id (auth:user-id (auth:create-user a :email "sameseC@x.com" :password "pw"))))
      (auth:grant-role a id :moderator :actor "alice")
      (auth:revoke-role a id :moderator :actor "bob")
      (auth:grant-role a id :moderator :actor "carol")
      (let ((history (auth:role-history a id)))
        (is (equal '("grant" "revoke" "grant")
                   (mapcar (lambda (e) (getf e :action)) history))
            "order was ~S" (mapcar (lambda (e) (getf e :actor)) history))
        (is (equal '("alice" "bob" "carol") (mapcar (lambda (e) (getf e :actor)) history)))
        ;; ...and assert the premise: they really did land in the same second, so this test
        ;; is exercising the tiebreaker rather than passing on distinct timestamps.
        (is (= 1 (length (remove-duplicates (mapcar (lambda (e) (getf e :at)) history))))
            "the events had distinct timestamps, so the tie was never tested")))))

;;; --- the role-event log is checked at construction (#139) ------------------------------
;;;
;;; An app that follows docs/migrations.md owns its timeline and does not pass :ENSURE. Until
;;; #139 the documented set created only hyperion_users, and the missing role log surfaced as
;;; "no such table" the first time an operator changed a role. These run the timeline through
;;; mnemosyne's own MIGRATE, as an app does, rather than calling the DDL directly.

(defun %users-migration ()
  (be:make-migration "20260729_003_hyperion_users" "identity store"
                     (auth:users-ddl :dialect :sqlite)
                     "DROP TABLE hyperion_users"))

(defun %email-index-migration ()
  (be:make-migration "20260729_003a_hyperion_users_email" "one account per email"
                     (auth:users-email-index-ddl)
                     "DROP INDEX idx_hyperion_users_email"))

(defun %role-log-migrations ()
  (list (be:make-migration "20260729_004_hyperion_role_events" "role-change log"
                           (auth:role-events-ddl :dialect :sqlite)
                           "DROP TABLE hyperion_role_events")
        (be:make-migration "20260729_005_hyperion_role_events_index" "role-change log index"
                           (auth:role-events-index-ddl)
                           "DROP INDEX idx_hyperion_role_events_user_at")))

(defun %with-file-migrated (path-and-migrations)
  "Apply MIGRATIONS to the SQLite file PATH through MIGRATE, then close the connection."
  (destructuring-bind (path migrations) path-and-migrations
    (let ((c (conn:connect (be:make-sqlite (namestring path)))))
      (unwind-protect (mnemosyne/migrate:migrate (be:make-sqlite (namestring path)) c migrations)
        (conn:disconnect c)))))

(defmacro %with-migrated ((conn migrations) &body body)
  `(let ((,conn (conn:connect (be:make-sqlite ":memory:"))))
     (unwind-protect
          (progn (mnemosyne/migrate:migrate (be:make-sqlite ":memory:") ,conn ,migrations)
                 ,@body)
       (conn:disconnect ,conn))))

(test the-documented-migration-set-gives-a-store-whose-role-changes-work
  (%with-migrated (c (list* (%users-migration) (%email-index-migration) (%role-log-migrations)))
    (let* ((store (auth:make-db-auth c :dialect :sqlite))
           (id (auth:user-id (auth:create-user store :email "doc@x.com" :roles '(:member)))))
      (auth:grant-role store id :moderator :actor "test")
      (is (= 1 (length (auth:role-history store id)))
          "the grant must be recorded in the role log the migrations created"))))

(test a-timeline-without-the-role-log-is-refused-at-construction
  ;; The pre-#139 documented set: users only.
  (%with-migrated (c (list (%users-migration)))
    (let ((err (handler-case (progn (auth:make-db-auth c :dialect :sqlite) nil)
                 (auth:missing-role-log (e) e))))
      (is (typep err 'auth:missing-role-log) "expected MISSING-ROLE-LOG, got ~S" err)
      (when err
        (is (string= "hyperion_role_events" (auth:missing-role-log-table err)))
        (is (auth:missing-role-log-cause err) "the database's own error is kept")
        (let ((report (princ-to-string err)))
          (is (search "role-events-ddl" report) "the report names the migration's DDL")
          (is (search "role-events-index-ddl" report) "and the index's"))))))

(test require-role-log-nil-constructs-without-the-table
  (%with-migrated (c (list (%users-migration)))
    (is (typep (auth:make-db-auth c :dialect :sqlite :require-role-log nil) 'auth:db-auth))))

(test ensure-still-creates-the-role-log
  (let ((c (conn:connect (be:make-sqlite ":memory:"))))
    (unwind-protect
         (is (typep (auth:make-db-auth c :dialect :sqlite :ensure t) 'auth:db-auth))
      (conn:disconnect c))))

;;; --- one account per email (#221) ----------------------------------------------------
;;;
;;; USERS-DDL declares no UNIQUE constraint. Until #221 CREATE-USER relied only on the unique
;;; index's error, and the documented migration set did not create the index, so a second
;;; sign-up with the same address created a second account (measured on main: 2 rows).

(defun %email-rows (c email)
  (length (conn:query c "SELECT _id FROM hyperion_users WHERE email = ?" email)))

(test a-duplicate-email-is-refused-even-without-the-index
  ;; The users table only, as docs/migrations.md used to show, plus the role log so the
  ;; store constructs. The refusal comes from CREATE-USER's own check.
  (%with-migrated (c (cons (%users-migration) (%role-log-migrations)))
    (let ((store (auth:make-db-auth c :dialect :sqlite)))
      (auth:create-user store :email "same@x.com")
      (signals auth:duplicate-email (auth:create-user store :email "Same@X.com"))
      (is (= 1 (%email-rows c "same@x.com")) "one account for the address"))))

(defun %concurrent-duplicate-signups (path pairs)
  "Two stores on two connections to the SQLite file PATH. For each of PAIRS emails, both sign
up at once. Returns (values pairs-with-exactly-one-row created refused other-errors)."
  (let* ((ca (conn:connect (be:make-sqlite (namestring path))))
         (cb (conn:connect (be:make-sqlite (namestring path))))
         ;; Without a busy timeout, SQLite refuses a second writer at once with BUSY instead
         ;; of waiting, and mnemosyne sets none, so here some sign-ups failed with "database is
         ;; locked" before ever reaching the index (#223). Set here so
         ;; this test measures the index, not the lock.
         (_ (dolist (c (list ca cb)) (conn:exec c "PRAGMA busy_timeout = 5000")))
         (a (auth:make-db-auth ca :dialect :sqlite))
         (b (auth:make-db-auth cb :dialect :sqlite))
         (one-row 0) (created 0) (refused 0) (other '()))
    (declare (ignore _))
    (unwind-protect
         (dotimes (i pairs)
           (let* ((email (format nil "race-~D@x.com" i))
                  (go (sb-thread:make-semaphore))
                  (outcomes (make-array 2 :initial-element nil))
                  (threads
                    (loop for store in (list a b) for k from 0
                          collect (let ((store store) (k k))
                                    ;; THREAD-LIFETIME: scoped -- joined below, before the next pair.
                                    (sb-thread:make-thread
                                     (lambda ()
                                       (sb-thread:wait-on-semaphore go)
                                       (setf (aref outcomes k)
                                             (handler-case (progn (auth:create-user store :email email)
                                                                  :created)
                                               (auth:duplicate-email () :refused)
                                               (error (e) (princ-to-string e)))))
                                     :name "signup")))))
             (sb-thread:signal-semaphore go 2)
             (dolist (th threads) (aion/test-threads:join th))
             (when (= 1 (%email-rows ca email)) (incf one-row))
             (loop for o across outcomes
                   do (case o (:created (incf created)) (:refused (incf refused))
                        (t (push o other))))))
      (conn:disconnect ca) (conn:disconnect cb))
    (values one-row created refused other)))

(test concurrent-duplicate-signups-leave-one-account-with-the-index
  ;; Two stores do not share a lock, so both can pass CREATE-USER's check at once. The index
  ;; is what refuses the second insert, and its error must still arrive as DUPLICATE-EMAIL.
  (let ((path (%temp-db-path "email-race")))
    (unwind-protect
         (progn
           (%with-file-migrated (list path (list* (%users-migration) (%email-index-migration)
                                                   (%role-log-migrations))))
           (multiple-value-bind (one-row created refused other)
               (%concurrent-duplicate-signups path 50)
             (is (= 50 one-row) "every contested address holds exactly one account")
             (is (= 50 created) "one sign-up per address succeeds")
             (is (= 50 refused) "and the other is refused as DUPLICATE-EMAIL")
             (is (null other) "no other error: ~S" (remove-duplicates other :test #'string=))))
      (ignore-errors (delete-file path)))))
