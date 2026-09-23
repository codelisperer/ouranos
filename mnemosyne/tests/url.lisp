;;;; tests/url.lisp --- fiveam suite for mnemosyne/url + the Ssl-Mode core.
;;;;
;;;; The cases here are not hypothetical: each one is a URL a managed provider actually
;;;; emits, or a mistake that would otherwise be found on a deploy, out of hours, against
;;;; a real database. The rejection tests matter at least as much as the acceptance ones
;;;; -- a parser suite that only feeds it well-formed input is testing the wrong half.

(cl:in-package #:mnemosyne/tests)

(in-suite mnemosyne)

(defmacro %rejects (url &optional (what ""))
  "URL must signal INVALID-DATABASE-URL -- not return a Backend, and not signal something
else."
  `(is (handler-case (progn (mnemosyne/url:backend-from-url ,url) nil)
         (mnemosyne/url:invalid-database-url () t)
         (error (e) (declare (ignore e)) nil))
       "~S should be rejected as a bad URL~@[ (~A)~]" ,url ,what))

;;; --- the SSL vocabulary (Coalton core) -------------------------------------

(test ssl-mode-maps-libpq-to-the-driver
  ;; The mapping the whole feature turns on, and the one nobody should have to remember:
  ;; libpq's `require' does NOT verify, and cl-postgres spells the verifying modes
  ;; `:yes' and `:full'. Getting this backwards yields a connection that is encrypted but
  ;; unauthenticated while reporting that it is verified.
  (is (string= "no"      (mnemosyne/backend:ssl-mode-driver-name
                          (mnemosyne/backend:parse-ssl-mode-or-full "disable"))))
  (is (string= "try"     (mnemosyne/backend:ssl-mode-driver-name
                          (mnemosyne/backend:parse-ssl-mode-or-full "prefer"))))
  (is (string= "try"     (mnemosyne/backend:ssl-mode-driver-name
                          (mnemosyne/backend:parse-ssl-mode-or-full "allow"))))
  (is (string= "require" (mnemosyne/backend:ssl-mode-driver-name
                          (mnemosyne/backend:parse-ssl-mode-or-full "require"))))
  (is (string= "yes"     (mnemosyne/backend:ssl-mode-driver-name
                          (mnemosyne/backend:parse-ssl-mode-or-full "verify-ca"))))
  (is (string= "full"    (mnemosyne/backend:ssl-mode-driver-name
                          (mnemosyne/backend:parse-ssl-mode-or-full "verify-full")))))

(test ssl-mode-guarantee-is-only-for-modes-that-promise
  ;; This predicate decides whether a missing TLS library degrades or fails, so it is
  ;; load-bearing security logic rather than a convenience.
  (is (not (mnemosyne/backend:ssl-mode-guaranteed?
            (mnemosyne/backend:parse-ssl-mode-or-full "disable"))))
  (is (not (mnemosyne/backend:ssl-mode-guaranteed?
            (mnemosyne/backend:parse-ssl-mode-or-full "prefer"))))
  (is (mnemosyne/backend:ssl-mode-guaranteed?
       (mnemosyne/backend:parse-ssl-mode-or-full "require")))
  (is (mnemosyne/backend:ssl-mode-guaranteed?
       (mnemosyne/backend:parse-ssl-mode-or-full "verify-ca")))
  (is (mnemosyne/backend:ssl-mode-guaranteed?
       (mnemosyne/backend:parse-ssl-mode-or-full "verify-full"))))

(test ssl-mode-known-is-a-closed-vocabulary
  (is (mnemosyne/backend:ssl-mode-known? "require"))
  (is (not (mnemosyne/backend:ssl-mode-known? "REQUIRE"))     "case folding is the shell's job")
  (is (not (mnemosyne/backend:ssl-mode-known? "required")))
  (is (not (mnemosyne/backend:ssl-mode-known? "true")))
  (is (not (mnemosyne/backend:ssl-mode-known? ""))))

;;; --- a provider's URL ------------------------------------------------------

(test url-parses-a-managed-provider-url
  ;; Shaped exactly like DigitalOcean's, including the percent-encoded password.
  (let ((b (mnemosyne/url:backend-from-url
            "postgres://doadmin:pa%24%24w0rd@db-x.b.db.ondigitalocean.com:25060/defaultdb?sslmode=require")))
    (is (string= "postgres" (mnemosyne/backend:backend-name b)))
    (is (string= "db-x.b.db.ondigitalocean.com" (mnemosyne/backend:backend-pg-host b)))
    (is (= 25060 (mnemosyne/backend:backend-pg-port b)))
    (is (string= "defaultdb" (mnemosyne/backend:backend-pg-database b)))
    (is (string= "doadmin" (mnemosyne/backend:backend-pg-user b)))
    ;; The decode is the point: split or decode this wrong and you get an auth failure
    ;; with no hint as to why, intermittently, depending on what the generator picked.
    (is (string= "pa$$w0rd" (aion/secret:reveal (mnemosyne/backend:backend-pg-password b))))
    (is (string= "require" (mnemosyne/backend:backend-pg-ssl-mode b)))))

(test url-accepts-both-scheme-spellings
  (dolist (scheme '("postgres" "postgresql"))
    (let ((b (mnemosyne/url:backend-from-url (format nil "~A://u:p@h/d" scheme))))
      (is (string= "postgres" (mnemosyne/backend:backend-name b))
          "~A:// should yield a postgres backend" scheme))))

(test url-defaults-port-and-sslmode
  ;; Absent port is 5432 and absent sslmode is `prefer' -- libpq's own defaults, so an
  ;; operator gets what psql would give them rather than a policy we invented.
  (let ((b (mnemosyne/url:backend-from-url "postgres://u:p@h/d")))
    (is (= 5432 (mnemosyne/backend:backend-pg-port b)))
    (is (string= "prefer" (mnemosyne/backend:backend-pg-ssl-mode b)))))

(test url-database-name-may-be-absent
  (dolist (u '("postgres://u:p@h" "postgres://u:p@h/" "postgres://u:p@h:5432/"))
    (let ((b (mnemosyne/url:backend-from-url u)))
      (is (string= "" (mnemosyne/backend:backend-pg-database b)) "~S" u)
      (is (string= "h" (mnemosyne/backend:backend-pg-host b)) "~S" u))))

(test url-handles-a-bracketed-ipv6-host
  ;; quri rejects this shape outright when userinfo is present, which is why the
  ;; authority is split here rather than delegated. The brackets are framing, not part
  ;; of the address, so the driver must be handed the bare literal.
  (let ((b (mnemosyne/url:backend-from-url "postgres://u:p@[2001:db8::1]:5433/d")))
    (is (string= "2001:db8::1" (mnemosyne/backend:backend-pg-host b)))
    (is (= 5433 (mnemosyne/backend:backend-pg-port b))))
  (let ((b (mnemosyne/url:backend-from-url "postgres://u:p@[::1]/d")))
    (is (string= "::1" (mnemosyne/backend:backend-pg-host b)))
    (is (= 5432 (mnemosyne/backend:backend-pg-port b)))))

(test url-splits-userinfo-at-the-last-at-sign
  ;; An unencoded `@' in a generated password is common and libpq splits on the last one.
  ;; Splitting on the first turns a working URL into an invisible auth failure.
  (let ((b (mnemosyne/url:backend-from-url "postgres://user:p@ss@host/d")))
    (is (string= "user" (mnemosyne/backend:backend-pg-user b)))
    (is (string= "p@ss" (aion/secret:reveal (mnemosyne/backend:backend-pg-password b))))
    (is (string= "host" (mnemosyne/backend:backend-pg-host b)))))

(test url-decodes-reserved-characters-in-the-password
  (let ((b (mnemosyne/url:backend-from-url "postgres://u:p%40ss%2Fword%3A1%3Fx@h/d")))
    (is (string= "p@ss/word:1?x" (aion/secret:reveal (mnemosyne/backend:backend-pg-password b))))))

(test url-takes-the-last-sslmode-when-repeated
  ;; libpq's behaviour, and the safe one: a repeated key must not resolve to the weaker
  ;; value by accident of ordering.
  (let ((b (mnemosyne/url:backend-from-url "postgres://u:p@h/d?sslmode=disable&sslmode=require")))
    (is (string= "require" (mnemosyne/backend:backend-pg-ssl-mode b)))))

(test url-ignores-other-query-parameters
  (let ((b (mnemosyne/url:backend-from-url
            "postgres://u:p@h/d?application_name=app&sslmode=verify-full&connect_timeout=10")))
    (is (string= "verify-full" (mnemosyne/backend:backend-pg-ssl-mode b)))))

;;; --- sqlite, so ONE variable configures every environment ------------------

(test url-parses-sqlite
  (is (string= "/data/app.db"
               (mnemosyne/backend:sqlite-path
                (mnemosyne/url:backend-from-url "sqlite:///data/app.db"))))
  (is (string= "data/app.db"
               (mnemosyne/backend:sqlite-path
                (mnemosyne/url:backend-from-url "sqlite://data/app.db"))))
  (is (string= ":memory:"
               (mnemosyne/backend:sqlite-path
                (mnemosyne/url:backend-from-url "sqlite://:memory:"))))
  (is (string= ":memory:"
               (mnemosyne/backend:sqlite-path
                (mnemosyne/url:backend-from-url "sqlite3://")))))

;;; --- what must be REFUSED --------------------------------------------------

(test url-rejects-malformed-input
  (%rejects "" "empty")
  (%rejects "   " "blank")
  (%rejects "not a url" "no scheme -- quri would accept this as a relative path")
  (%rejects "postgres:/h/d" "only one slash")
  (%rejects "postgres://" "no host")
  (%rejects "postgres:///d" "empty host")
  (%rejects "mysql://u:p@h/d" "unsupported scheme")
  (%rejects "http://u:p@h/d" "unsupported scheme"))

(test url-rejects-a-bad-port
  (%rejects "postgres://u:p@h:notaport/d" "non-numeric port")
  (%rejects "postgres://u:p@h:0/d" "port 0")
  (%rejects "postgres://u:p@h:70000/d" "port above 65535"))

(test url-rejects-an-unclosed-ipv6-bracket
  (%rejects "postgres://u:p@[::1/d" "no closing bracket"))

(test url-rejects-an-unknown-sslmode
  ;; The important one. A typo must not silently become `prefer' and connect in the
  ;; clear -- an operator who wrote sslmode=requre meant to require TLS.
  (%rejects "postgres://u:p@h/d?sslmode=requre" "typo")
  (%rejects "postgres://u:p@h/d?sslmode=true" "not libpq's vocabulary")
  (%rejects "postgres://u:p@h/d?sslmode=" "empty"))

(defmacro %rejects-because (url substring &optional (what ""))
  "URL must signal INVALID-DATABASE-URL whose REASON contains SUBSTRING.

Asserting the REASON and not merely the signal is the whole point here. A malformed
`sslmode' escape already signalled before this was fixed -- as an UNKNOWN-SSLMODE error,
because the lenient decode handed the known-mode check the literal string `req%ZZuire'.
%REJECTS cannot tell those two apart, so it would have passed against the bug and proved
nothing."
  `(is (handler-case (progn (mnemosyne/url:backend-from-url ,url) nil)
         (mnemosyne/url:invalid-database-url (e)
           (and (search ,substring (mnemosyne/url:invalid-database-url-reason e)) t))
         (error () nil))
       "~S should be rejected with a reason naming ~S~@[ (~A)~]" ,url ,substring ,what))

(test url-rejects-a-malformed-percent-escape
  "Every component decodes through the same strict path, so every component fails the
same way. The two that did not were the query value and the sqlite path."
  (%rejects-because "postgres://u:p@h/d?sslmode=req%ZZuire" "percent-escape"
                    "the sslmode query value")
  (%rejects-because "postgres://u:p@h/d?sslmode=req%ZZuire" "sslmode"
                    "and it names WHICH component")
  ;; The sqlite path is the dangerous one. Nothing downstream validates a filesystem
  ;; path, so a mangled escape produced no error at all -- SQLite would open, and being
  ;; SQLite CREATE, a different database file than the operator configured.
  (%rejects-because "sqlite:///data%ZZ/app.db" "percent-escape" "the sqlite path")
  (%rejects-because "sqlite:///data%ZZ/app.db" "database path" "and names it"))

(test url-still-decodes-well-formed-escapes
  "The other direction of the same fix: strictness must not have turned decoding off.
A path or an sslmode that is correctly encoded still arrives decoded."
  (is (string= "require"
               (mnemosyne/backend:backend-pg-ssl-mode
                (mnemosyne/url:backend-from-url "postgres://u:p@h/d?sslmode=requi%72e"))))
  (is (string= "/data/app.db"
               (mnemosyne/backend:sqlite-path
                (mnemosyne/url:backend-from-url "sqlite:///data%2Fapp.db"))))
  ;; A space in a path is the everyday case, and the one a lenient decode would leave
  ;; as the literal characters `%20'.
  (is (string= "/my db.sqlite"
               (mnemosyne/backend:sqlite-path
                (mnemosyne/url:backend-from-url "sqlite:///my%20db.sqlite")))))

(test url-error-never-contains-the-password
  ;; This condition is reported into logs and crash dumps. Leaking the credential while
  ;; explaining that the URL was malformed would be a poor trade.
  (handler-case (mnemosyne/url:backend-from-url "postgres://u:hunter2@h:bad/d")
    (mnemosyne/url:invalid-database-url (e)
      (let ((printed (princ-to-string e)))
        (is (null (search "hunter2" printed))
            "the printed condition leaked the password: ~A" printed)))
    (:no-error (b) (declare (ignore b)) (is nil "should have signalled"))))

;;; --- the degrade-vs-fail rule (the security-critical half of the shell) ----

(defun %resolve (url tls-available)
  (mnemosyne/conn::%resolve-ssl (mnemosyne/url:backend-from-url url) tls-available))

(test tls-present-passes-the-mode-straight-through
  (is (eq :no      (%resolve "postgres://u:p@h/d?sslmode=disable" t)))
  (is (eq :try     (%resolve "postgres://u:p@h/d?sslmode=prefer" t)))
  (is (eq :require (%resolve "postgres://u:p@h/d?sslmode=require" t)))
  (is (eq :yes     (%resolve "postgres://u:p@h/d?sslmode=verify-ca" t)))
  (is (eq :full    (%resolve "postgres://u:p@h/d?sslmode=verify-full" t))))

(test tls-absent-degrades-only-what-promised-nothing
  ;; `disable' and `prefer' carry no guarantee, so they connect.
  (is (eq :no (%resolve "postgres://u:p@h/d?sslmode=disable" nil)))
  (is (eq :no (%resolve "postgres://u:p@h/d?sslmode=prefer" nil)))
  (is (eq :no (%resolve "postgres://u:p@h/d" nil)) "the default is prefer, so it degrades"))

(test tls-absent-refuses-a-mode-that-promised-encryption
  ;; THE test in this change. Silently connecting in plaintext here would hand a
  ;; deployment exactly the failure it wrote sslmode=require to prevent -- and would do
  ;; it invisibly, which is worse than not starting.
  (dolist (mode '("require" "verify-ca" "verify-full"))
    (let ((url (format nil "postgres://u:p@h/d?sslmode=~A" mode)))
      (is (handler-case (progn (%resolve url nil) nil)
            (mnemosyne/conn:db-error () t)
            (error () nil))
          "sslmode=~A must refuse to connect without TLS, not downgrade" mode))))

(test tls-refusal-names-the-fix-and-not-the-password
  (handler-case (%resolve "postgres://u:hunter2@h/d?sslmode=require" nil)
    (mnemosyne/conn:db-error (e)
      (let ((printed (princ-to-string e)))
        (is (search "cl+ssl" printed) "the error must name what to add: ~A" printed)
        (is (null (search "hunter2" printed)) "leaked the password: ~A" printed)))
    (:no-error (r) (declare (ignore r)) (is nil "should have signalled"))))

(test sqlite-never-asks-the-driver-for-tls
  (is (eq :no (mnemosyne/conn::%resolve-ssl (mnemosyne/backend:make-sqlite ":memory:") nil)))
  (is (eq :no (mnemosyne/conn::%resolve-ssl (mnemosyne/backend:make-sqlite ":memory:") t))))

;;; --- the constructors ------------------------------------------------------

(test make-postgres-keeps-its-arity-and-its-plaintext-default
  ;; Public API reached by hyperion/session-db and hyperion/auth-db: adding a required
  ;; argument here would break every caller to change a default they never stated.
  (let ((b (mnemosyne/backend:make-postgres "h" 5432 "d" "u" "p")))
    (is (string= "disable" (mnemosyne/backend:backend-pg-ssl-mode b)))
    (is (string= "no" (mnemosyne/backend:backend-pg-ssl-driver b)))
    (is (not (mnemosyne/backend:backend-pg-ssl-guaranteed? b)))))

(test make-postgres-with-ssl-fails-closed-on-an-unknown-mode
  ;; Unreachable through BACKEND-FROM-URL, which validates first -- but the branch has to
  ;; exist, and an unreadable security token must fail closed rather than open.
  (let ((b (mnemosyne/backend:make-postgres-with-ssl "h" 5432 "d" "u" "p" "nonsense")))
    (is (string= "verify-full" (mnemosyne/backend:backend-pg-ssl-mode b)))
    (is (mnemosyne/backend:backend-pg-ssl-guaranteed? b))))

(test sqlite-backend-reports-no-tls
  ;; The accessors are total over Backend, so they must answer sensibly for SQLite rather
  ;; than returning something the CL shell would misread.
  (let ((b (mnemosyne/backend:make-sqlite ":memory:")))
    (is (string= "disable" (mnemosyne/backend:backend-pg-ssl-mode b)))
    (is (string= "no" (mnemosyne/backend:backend-pg-ssl-driver b)))
    (is (not (mnemosyne/backend:backend-pg-ssl-guaranteed? b)))))

;;; --- pre-publication issue 209: the password must not be printable ------------------------------
;;;
;;; The reported defect: PG-CONFIG is a Coalton DEFINE-TYPE, whose generated printer
;;; renders every field, so a String password was written out in full by anything that
;;; printed the config. In the report that was an unhandled condition's backtrace during a
;;; migration -- so a production database password reached a deploy log, with nothing
;;; whatever wrong with the code that put it there.

(defparameter +leak-probe+ "pa$$w0rd-do-not-log-me"
  "Distinctive on purpose: these tests are substring searches over printed output.")

(test backend-printing-does-not-disclose-the-password
  (let ((printed (format nil "~S" (mnemosyne/backend:make-postgres
                                   "db.example.com" 25060 "app" "app_user" +leak-probe+))))
    (is (null (search +leak-probe+ printed))
        "a printed Backend disclosed its password: ~S" printed)
    ;; ...while everything an operator actually needs from that backtrace still prints.
    ;; Redacting the whole config would satisfy the assertion above and be useless.
    (is (search "db.example.com" printed))
    (is (search "app_user" printed))))

(test backend-printing-does-not-disclose-the-password-under-princ
  ;; ~A as well as ~S: PRINC binds *PRINT-ESCAPE* to NIL, and a log line built with
  ;; FORMAT ~A is at least as likely a disclosure path as a backtrace.
  (let ((printed (format nil "~A" (mnemosyne/backend:make-postgres-with-ssl
                                   "db.example.com" 25060 "app" "app_user"
                                   +leak-probe+ "require"))))
    (is (null (search +leak-probe+ printed)))))

(test the-password-is-still-there-to-have-been-leaked
  ;; The control for both tests above. Without it they would pass just as happily against
  ;; a constructor that dropped the password on the floor -- and CONNECT would then fail
  ;; authentication in a way no test here would explain.
  (let ((b (mnemosyne/backend:make-postgres "h" 5432 "d" "u" +leak-probe+)))
    (is (string= +leak-probe+
                 (aion/secret:reveal (mnemosyne/backend:backend-pg-password b))))))

(test a-sqlite-backend-answers-with-an-empty-secret
  ;; Total accessors: SQLite has no password, and the answer must still be a SECRET so
  ;; callers cannot accidentally get a bare String on one branch and not the other.
  (let ((b (mnemosyne/backend:make-sqlite ":memory:")))
    (is (aion/secret:secretp (mnemosyne/backend:backend-pg-password b)))
    (is (string= "" (aion/secret:reveal (mnemosyne/backend:backend-pg-password b))))))
