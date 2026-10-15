;;;; auth-email-tests.lisp --- email confirmation, change of address and password reset (#690).
;;;;
;;;; Same package and suite as auth-db-tests.lisp, which is loaded first and defines the
;;;; migration helpers used here. In-memory SQLite with an injected clock; the Postgres run is
;;;; at the end and skips without MNEMOSYNE_TEST_PG_URL.

(in-package #:hyperion/auth-db/tests)
(in-suite auth-db)

(defvar *now* 3900000000
  "The clock the email stores in these tests read. A test that moves time binds it.")

(defun %clock () *now*)

(defmacro with-email-auth ((var &rest keys) &body body)
  "Bind VAR to a store over a fresh in-memory SQLite, tables ensured, reading *NOW*."
  (let ((c (gensym)))
    `(let ((,c (conn:connect (be:make-sqlite ":memory:"))))
       (unwind-protect
            (let ((,var (auth:make-db-auth ,c :dialect :sqlite :ensure t :clock #'%clock ,@keys)))
              ,@body)
         (conn:disconnect ,c)))))

(defun %token-reason (thunk)
  "The INVALID-TOKEN reason THUNK signals, :OK when it returns, or the other condition."
  (handler-case (progn (funcall thunk) :ok)
    (auth:invalid-token (e) (auth:invalid-token-reason e))
    (error (e) e)))

(defun %new-user (store email &key (password "old-pw"))
  (auth:user-id (auth:create-user store :email email :password password)))

;;; --- confirmation at signup --------------------------------------------------------------

(test a-confirmation-token-confirms-the-address-once
  (with-email-auth (a)
    (let ((id (%new-user a "sign@x.com")))
      (is (not (auth:email-confirmed-p (auth:find-user-by-id a id))) "a new account is unconfirmed")
      (multiple-value-bind (token email expires) (auth:issue-confirmation a id)
        (is (stringp token))
        (is (= 64 (length token)) "256 bits as hex")
        (is (string= "sign@x.com" email))
        (is (= (+ *now* 86400) expires) "24 hours by default")
        (let ((u (auth:confirm-email a token)))
          (is (auth:email-confirmed-p u))
          (is (= *now* (auth:user-email-confirmed-at u))))
        (is (eq :used (%token-reason (lambda () (auth:confirm-email a token)))))
        (is (equal '(("confirmed" "sign@x.com" "sign@x.com"))
                   (mapcar (lambda (e) (list (getf e :action) (getf e :old-email) (getf e :new-email)))
                           (auth:email-history a id))))
        (is (null (auth:issue-confirmation a id)) "nothing to issue once confirmed")))))

(test the-table-keeps-the-token-s-hash-and-not-the-token
  (with-email-auth (a)
    (let* ((id (%new-user a "hash@x.com"))
           (token (auth:issue-confirmation a id))
           (rows (conn:query (slot-value a 'auth::source)
                             "SELECT * FROM hyperion_email_tokens")))
      (is (= 1 (length rows)))
      (is (notany (lambda (v) (equal v token)) (first rows))
          "no column holds the token itself: ~S" (first rows))
      (is (string= (auth::%token-hash token) (auth::%rget (first rows) :token_hash))))))

(test an-expired-or-unknown-token-is-refused
  (with-email-auth (a)
    (let* ((id (%new-user a "late@x.com"))
           (token (auth:issue-confirmation a id)))
      (is (eq :unknown (%token-reason (lambda () (auth:confirm-email a "not-a-token")))))
      (is (eq :unknown (%token-reason (lambda () (auth:confirm-email a nil)))))
      (let ((*now* (+ *now* 86400)))
        (is (eq :ok (%token-reason (lambda () (auth:issue-confirmation a id))))
            "premise: still issuable"))
      (let ((*now* (+ *now* 86401)))
        (is (eq :expired (%token-reason (lambda () (auth:confirm-email a token)))))))))

(test a-token-for-one-purpose-is-unknown-to-another
  (with-email-auth (a)
    (let* ((id (%new-user a "purpose@x.com"))
           (confirm (auth:issue-confirmation a id))
           (reset (auth:issue-password-reset a "purpose@x.com")))
      (is (eq :unknown (%token-reason (lambda () (auth:reset-password a confirm "new-pw")))))
      (is (eq :unknown (%token-reason (lambda () (auth:confirm-email a reset)))))
      (is (eq :unknown (%token-reason (lambda () (auth:confirm-email-change a confirm)))))
      (is (eq :unknown (%token-reason (lambda () (auth:revert-email-change a reset :none))))))))

(test a-user-is-sent-at-most-five-tokens-of-one-purpose-an-hour
  (with-email-auth (a)
    (let ((id (%new-user a "resend@x.com")))
      (dotimes (i 5)
        (let ((*now* (+ *now* (* i 60))))
          (is (stringp (auth:issue-confirmation a id)))))
      (let* ((*now* (+ *now* 600))
             (err (handler-case (progn (auth:issue-confirmation a id) nil)
                    (auth:too-many-tokens (e) e))))
        (is (typep err 'auth:too-many-tokens) "the sixth within the hour is refused")
        (when err
          (is (eq :confirm (auth:too-many-tokens-purpose err)))
          (is (= 3000 (auth:too-many-tokens-retry-after err))
              "the first was sent 600 seconds ago, so 3000 seconds remain: ~D"
              (auth:too-many-tokens-retry-after err))))
      (is (stringp (auth:issue-password-reset a "resend@x.com"))
          "the limit is per purpose")
      (let ((*now* (+ *now* 3601)))
        (is (stringp (auth:issue-confirmation a id)) "the window moves on")))))

(test the-token-limit-and-lifetimes-are-settings-of-the-store
  (with-email-auth (a :token-limit 2 :token-window 100 :confirm-token-seconds 50)
    (let ((id (%new-user a "settings@x.com")))
      (multiple-value-bind (token email expires) (auth:issue-confirmation a id)
        (declare (ignore token email))
        (is (= (+ *now* 50) expires)))
      (auth:issue-confirmation a id)
      (signals auth:too-many-tokens (auth:issue-confirmation a id)))))

;;; --- change of address --------------------------------------------------------------------

(test a-change-of-address-needs-the-password-and-holds-until-the-new-address-confirms
  (with-email-auth (a)
    (let ((id (%new-user a "old@x.com")))
      (signals auth:wrong-password (auth:request-email-change a id "new@x.com"))
      (signals auth:wrong-password (auth:request-email-change a id "new@x.com" :password "nope"))
      (multiple-value-bind (token new old expires)
          (auth:request-email-change a id "New@X.com" :password "old-pw")
        (is (string= "new@x.com" new))
        (is (string= "old@x.com" old))
        (is (= (+ *now* 86400) expires))
        (is (string= "old@x.com" (auth:user-email (auth:find-user-by-id a id)))
            "nothing changes until the new address confirms")
        (let ((*now* (+ *now* 10)))
          (multiple-value-bind (user old2 revert) (auth:confirm-email-change a token)
            (is (string= "new@x.com" (auth:user-email user)))
            (is (auth:email-confirmed-p user))
            (is (string= "old@x.com" old2))
            (is (stringp revert))))
        (is (auth:authenticate a "new@x.com" "old-pw"))
        (is (null (auth:authenticate a "old@x.com" "old-pw")))
        (is (equal '(("changed" "old@x.com" "new@x.com" ""))
                   (mapcar (lambda (e) (list (getf e :action) (getf e :old-email) (getf e :new-email)
                                             (if (equal (getf e :actor) id) "" (getf e :actor))))
                           (auth:email-history a id)))
            "one event, with the user as actor")))))

(test password-skip-is-for-an-account-without-one
  (with-email-auth (a)
    (let ((id (auth:user-id (auth:create-user a :email "nopw@x.com"))))
      (signals auth:wrong-password (auth:request-email-change a id "nopw2@x.com"))
      (is (stringp (auth:request-email-change a id "nopw2@x.com" :password :skip))))))

(test a-change-to-the-same-or-a-taken-address-is-refused
  (with-email-auth (a)
    (let ((id (%new-user a "mine@x.com")))
      (%new-user a "theirs@x.com")
      (signals auth:same-email (auth:request-email-change a id "Mine@x.com" :password "old-pw"))
      (signals auth:duplicate-email (auth:request-email-change a id "theirs@x.com" :password "old-pw"))
      (is (null (auth:request-email-change a "no-such-id" "a@x.com" :password :skip))))))

(test an-address-taken-after-the-request-is-refused-at-confirmation-and-the-token-kept
  (with-email-auth (a)
    (let* ((id (%new-user a "slow@x.com"))
           (token (auth:request-email-change a id "race@x.com" :password "old-pw")))
      (auth:create-user a :email "race@x.com")
      (signals auth:duplicate-email (auth:confirm-email-change a token))
      (is (string= "slow@x.com" (auth:user-email (auth:find-user-by-id a id))))
      (is (typep (handler-case (auth:confirm-email-change a token) (error (e) e))
                 'auth:duplicate-email)
          "the failed confirmation rolled back, so the token is still unused"))))

(test a-change-cancels-tokens-mailed-to-the-old-address
  (with-email-auth (a)
    (let* ((id (%new-user a "before@x.com"))
           (confirm (auth:issue-confirmation a id))
           (reset (auth:issue-password-reset a "before@x.com"))
           (change (auth:request-email-change a id "after@x.com" :password "old-pw"))
           (other-change (auth:request-email-change a id "other@x.com" :password "old-pw")))
      (auth:confirm-email-change a change)
      (is (eq :used (%token-reason (lambda () (auth:confirm-email a confirm)))))
      (is (eq :used (%token-reason (lambda () (auth:reset-password a reset "hijack")))))
      (is (eq :used (%token-reason (lambda () (auth:confirm-email-change a other-change))))
          "a second pending change does not survive the first")
      (is (auth:authenticate a "after@x.com" "old-pw") "the password is unchanged"))))

;;; --- revert --------------------------------------------------------------------------------

(defun %signed-in (sessions user-id)
  "A session in SESSIONS holding USER-ID under :USER-ID, as SIGN-IN! leaves one."
  (let ((s (session:ensure-session (list :headers (make-hash-table :test 'equal)) sessions)))
    (session:session-set s :user-id user-id)
    s))

(test a-revert-restores-the-old-address-and-ends-every-session-of-the-user
  (with-email-auth (a)
    (let* ((sessions (session:make-memory-store))
           (id (%new-user a "owner@x.com"))
           (other (%new-user a "bystander@x.com"))
           (change (auth:request-email-change a id "hijacker@x.com" :password "old-pw")))
      (%signed-in sessions id) (%signed-in sessions id) (%signed-in sessions other)
      (multiple-value-bind (user old revert) (auth:confirm-email-change a change)
        (declare (ignore user old))
        (multiple-value-bind (restored ended) (auth:revert-email-change a revert sessions)
          (is (string= "owner@x.com" (auth:user-email restored)))
          (is (auth:email-confirmed-p restored))
          (is (= 2 ended) "the user's two sessions")
          (is (= 1 (session:store-count sessions)) "and not the other user's"))
        (is (eq :used (%token-reason (lambda () (auth:revert-email-change a revert sessions))))))
      (is (equal '("changed" "reverted") (mapcar (lambda (e) (getf e :action)) (auth:email-history a id)))))))

(test a-second-change-does-not-cancel-the-revert-link-the-owner-was-sent
  "Whoever moved the account to their own address must not be able to cancel the owner's revert
link by changing it again. The revert puts back the address the link was sent to."
  (with-email-auth (a)
    (let* ((id (%new-user a "owner2@x.com"))
           (revert (nth-value 2 (auth:confirm-email-change
                                 a (auth:request-email-change a id "hijack1@x.com" :password "old-pw"))))
           (hijacker-revert (nth-value 2 (auth:confirm-email-change
                                          a (auth:request-email-change a id "hijack2@x.com"
                                                                       :password "old-pw")))))
      (is (string= "owner2@x.com" (auth:user-email (auth:revert-email-change a revert :none))))
      (is (eq :used (%token-reason (lambda () (auth:revert-email-change a hijacker-revert :none))))
          "the revert cancels every token, the hijacker's revert link included"))))

(test a-revert-is-refused-without-a-session-store
  (with-email-auth (a)
    (let* ((id (%new-user a "nostore@x.com"))
           (revert (nth-value 2 (auth:confirm-email-change
                                 a (auth:request-email-change a id "ns2@x.com" :password "old-pw")))))
      (signals error (auth:revert-email-change a revert nil))
      (is (string= "nostore@x.com" (auth:user-email (auth:revert-email-change a revert :none)))
          "the refusal used no token"))))

(test a-revert-link-lasts-seven-days
  (with-email-auth (a)
    (let* ((id (%new-user a "week@x.com"))
           (revert-expires (nth-value 3 (auth:confirm-email-change
                                         a (auth:request-email-change a id "w2@x.com"
                                                                      :password "old-pw")))))
      (is (= (+ *now* 604800) revert-expires)))))

;;; --- the operator path ---------------------------------------------------------------------

(test an-operator-change-applies-at-once-and-leaves-the-address-unconfirmed
  (with-email-auth (a)
    (let* ((id (%new-user a "support@x.com"))
           (reset (auth:issue-password-reset a "support@x.com")))
      (auth:confirm-email a (auth:issue-confirmation a id))
      (signals auth:missing-actor (auth:set-email a id "fixed@x.com"))
      (let ((u (auth:set-email a id "Fixed@x.com" :actor "op-1")))
        (is (string= "fixed@x.com" (auth:user-email u)))
        (is (not (auth:email-confirmed-p u)) "the new address has not proved itself"))
      (is (eq :used (%token-reason (lambda () (auth:reset-password a reset "x")))))
      (let ((u (auth:set-email a id "verified@x.com" :actor "op-2" :confirmed t)))
        (is (auth:email-confirmed-p u)))
      (is (equal '(("confirmed" nil) ("operator-changed" "op-1") ("operator-changed-confirmed" "op-2"))
                 (mapcar (lambda (e) (list (getf e :action)
                                           (and (not (equal (getf e :actor) id)) (getf e :actor))))
                         (auth:email-history a id))))
      (is (null (auth:set-email a "no-such-id" "z@x.com" :actor "op"))))))

;;; --- password reset ------------------------------------------------------------------------

(test a-reset-token-sets-the-password-once-and-cancels-the-others
  (with-email-auth (a)
    (let* ((id (auth:user-id (auth:create-user a :email "forgot@x.com" :password "old-pw"
                                                 :temp-password-p t)))
           (first-token (auth:issue-password-reset a "forgot@x.com")))
      (multiple-value-bind (token user expires) (auth:issue-password-reset a "Forgot@X.com")
        (is (string= id (auth:user-id user)))
        (is (= (+ *now* 3600) expires) "one hour")
        (let ((u (auth:reset-password a token "new-pw")))
          (is (not (auth:user-temp-password-p u)) "the temp-password flag is cleared"))
        (is (auth:authenticate a "forgot@x.com" "new-pw"))
        (is (null (auth:authenticate a "forgot@x.com" "old-pw")))
        (is (eq :used (%token-reason (lambda () (auth:reset-password a token "again")))))
        (is (eq :used (%token-reason (lambda () (auth:reset-password a first-token "again"))))
            "the earlier reset token is cancelled too")))))

(test a-reset-for-an-unknown-address-returns-nil
  (with-email-auth (a)
    (is (null (auth:issue-password-reset a "nobody@x.com")))))

(test a-reset-token-expires-after-an-hour
  (with-email-auth (a)
    (%new-user a "hour@x.com")
    (let ((token (auth:issue-password-reset a "hour@x.com")))
      (let ((*now* (+ *now* 3601)))
        (is (eq :expired (%token-reason (lambda () (auth:reset-password a token "new-pw")))))))))

;;; --- pruning -------------------------------------------------------------------------------

(test prune-deletes-expired-tokens-and-keeps-live-used-ones
  (with-email-auth (a)
    (let* ((id (%new-user a "prune@x.com"))
           (used (auth:issue-confirmation a id)))
      (auth:issue-password-reset a "prune@x.com")
      (auth:confirm-email a used)
      (is (= 0 (auth:prune-email-tokens a)) "nothing has expired")
      (is (eq :used (%token-reason (lambda () (auth:confirm-email a used)))))
      (let ((*now* (+ *now* 3601)))
        (is (= 1 (auth:prune-email-tokens a)) "the reset, after its hour"))
      (let ((*now* (+ *now* 86401)))
        (is (= 1 (auth:prune-email-tokens a)) "the used confirmation, after its day")))))

;;; --- the construction check (E5) -----------------------------------------------------------

(test a-timeline-without-the-email-tables-is-refused-at-construction
  (%with-migrated (c (append (list (%users-migration) (%email-index-migration)) (%role-log-migrations)))
    (let ((err (handler-case (progn (auth:make-db-auth c :dialect :sqlite) nil)
                 (auth:missing-email-tables (e) e))))
      (is (typep err 'auth:missing-email-tables) "expected MISSING-EMAIL-TABLES, got ~S" err)
      (when err
        (is (auth:missing-email-tables-cause err) "the database's own error is kept")
        (let ((report (princ-to-string err)))
          (dolist (name '("users-email-confirmed-ddl" "email-tokens-ddl" "email-tokens-hash-index-ddl"
                          "email-tokens-user-index-ddl" "email-events-ddl" "email-events-index-ddl"
                          "SET email_confirmed_at = created_at"))
            (is (search name report :test #'char-equal) "the report names ~A" name)))))
    (is (typep (auth:make-db-auth c :dialect :sqlite :require-email-tables nil) 'auth:db-auth)
        ":require-email-tables nil is the opt-out")))

(test a-timeline-missing-only-the-token-table-is-refused
  (%with-migrated (c (append (list (%users-migration) (%email-index-migration)) (%role-log-migrations)
                             ;; the token table and its two indexes
                             (remove-if (lambda (m) (search "email_tokens" (be:migration-id m)))
                                        (%email-migrations))))
    (signals auth:missing-email-tables (auth:make-db-auth c :dialect :sqlite))))

(test an-existing-database-gets-the-column-and-its-accounts-start-unconfirmed
  "docs/migrations.md §8: the users table exists with accounts in it, then the email steps run.
The accounts are unconfirmed until the documented UPDATE marks them."
  (let ((c (conn:connect (be:make-sqlite ":memory:"))))
    (unwind-protect
         (let ((base (append (list (%users-migration) (%email-index-migration)) (%role-log-migrations))))
           (mnemosyne/migrate:migrate (be:make-sqlite ":memory:") c base)
           (let ((id (auth:user-id (auth:create-user
                                    (auth:make-db-auth c :dialect :sqlite :require-email-tables nil)
                                    :email "veteran@x.com"))))
             (mnemosyne/migrate:migrate (be:make-sqlite ":memory:") c (append base (%email-migrations)))
             (let ((a (auth:make-db-auth c :dialect :sqlite)))
               (is (not (auth:email-confirmed-p (auth:find-user-by-id a id))))
               (conn:exec c "UPDATE hyperion_users SET email_confirmed_at = created_at WHERE email_confirmed_at IS NULL")
               (is (auth:email-confirmed-p (auth:find-user-by-id a id))))))
      (conn:disconnect c))))

(test ensure-schema-runs-twice-without-adding-the-column-twice
  (let ((c (conn:connect (be:make-sqlite ":memory:"))))
    (unwind-protect
         (let ((a (auth:make-db-auth c :dialect :sqlite :ensure t)))
           (is (eq a (auth:ensure-schema a))))
      (conn:disconnect c))))

(test the-email-ddl-helpers-take-a-table-name
  (is (search "ALTER TABLE members ADD COLUMN email_confirmed_at INTEGER"
              (auth:users-email-confirmed-ddl :table "members")))
  (is (search "BIGINT" (auth:users-email-confirmed-ddl :dialect :postgres)))
  (is (search "CREATE TABLE IF NOT EXISTS member_tokens ("
              (auth:email-tokens-ddl :table "member_tokens")))
  (is (search "ON member_tokens (token_hash)" (auth:email-tokens-hash-index-ddl :table "member_tokens")))
  (signals error (auth:email-tokens-ddl :table "t; DROP TABLE x"))
  (signals error (auth:email-events-index-ddl :table "")))

;;; --- Postgres ------------------------------------------------------------------------------

(test the-email-flows-run-on-postgres
  (if (not (%pg-url))
      (skip "MNEMOSYNE_TEST_PG_URL is not set -- this says nothing about Postgres")
      (multiple-value-bind (users events tokens email-events) (%pg-names)
        (let ((c (conn:connect (mnemosyne/url:backend-from-url (%pg-url)))))
          (unwind-protect
               (let* ((a (auth:make-db-auth c :dialect :postgres :table users :events-table events
                                              :tokens-table tokens :email-events-table email-events
                                              :ensure t :clock #'%clock))
                      (id (%new-user a "pg@x.com")))
                 (is (auth:email-confirmed-p (auth:confirm-email a (auth:issue-confirmation a id))))
                 (is (eq :used (%token-reason
                                (lambda () (auth:confirm-email a (auth:issue-confirmation a id))))))
                 (let ((other (%new-user a "pg-taken@x.com")))
                   (declare (ignore other))
                   (signals auth:duplicate-email
                     (auth:request-email-change a id "pg-taken@x.com" :password "old-pw")))
                 (multiple-value-bind (user old revert)
                     (auth:confirm-email-change
                      a (auth:request-email-change a id "pg-new@x.com" :password "old-pw"))
                   (is (string= "pg-new@x.com" (auth:user-email user)))
                   (is (string= "pg@x.com" old))
                   (is (string= "pg@x.com" (auth:user-email (auth:revert-email-change a revert :none)))))
                 (let ((u (auth:reset-password a (auth:issue-password-reset a "pg@x.com") "pg-new-pw")))
                   (is (auth:authenticate a "pg@x.com" "pg-new-pw"))
                   (is (string= id (auth:user-id u))))
                 (is (equal '("confirmed" "changed" "reverted")
                            (mapcar (lambda (e) (getf e :action)) (auth:email-history a id))))
                 (is (eql 0 (auth:prune-email-tokens a))))
            (%drop-tables c users events tokens email-events)
            (conn:disconnect c))))))
