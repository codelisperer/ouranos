;;;; db-tests.lisp --- cons/db: URL resolution, parsing, and credential handling.
;;;;
;;;; The security-relevant assertions are the point: a password must never reach the child's
;;;; argv (argv is world-readable via ps) and must never be printed. Those are tested
;;;; directly rather than left to review.

(in-package #:cons/tests)
(in-suite all)

(defmacro with-clean-db-env (&body body)
  "Run BODY with the DATABASE_URL* variables cleared, restoring them afterwards.
Skips when the build cannot write the environment — see ENV-WRITABLE-P in packages.lisp."
  `(if (not (env-writable-p))
       (skip "no sb-posix:setenv in this build — env resolution is unexercised here")
       (let ((saved (mapcar (lambda (n) (cons n (uiop:getenv n)))
                            '("DATABASE_URL" "DATABASE_URL_DEV" "DATABASE_URL_STAGING"
                              "DATABASE_URL_PROD"))))
         (unwind-protect
              (progn (dolist (p saved) (unset-env (car p))) ,@body)
           (dolist (p saved) (when (cdr p) (set-env (car p) (cdr p))))))))

;;; --- resolution ------------------------------------------------------------

(test db-url-resolution-per-environment
  (with-clean-db-env
    (set-env "DATABASE_URL" "postgres://u:p@localhost/dev")
    (is (string= "postgres://u:p@localhost/dev"
                 (cons/db:resolve-url :env "dev" :dotenv nil)))
    ;; A suffixed variable is the ONLY thing that answers for a named environment: a
    ;; developer's plain DATABASE_URL must never be mistaken for production.
    (signals cons/db:db-repl-error (cons/db:resolve-url :env "prod" :dotenv nil))
    (set-env "DATABASE_URL_PROD" "postgres://u:p@prod-host/appdb")
    (is (string= "postgres://u:p@prod-host/appdb"
                 (cons/db:resolve-url :env "prod" :dotenv nil)))))

(test db-url-missing-names-the-variables-it-wanted
  (with-clean-db-env
    (handler-case (cons/db:resolve-url :env "staging" :dotenv nil)
      (cons/db:db-repl-error (e)
        (let ((msg (cons/db:db-repl-error-message e)))
          (is (search "staging" msg))
          (is (search "DATABASE_URL_STAGING" msg)))))))

;;; --- parsing ---------------------------------------------------------------

(test db-target-kind-by-scheme
  (is (eq :postgres (cons/db:db-target-kind
                     (cons/db:parse-target "postgres://u@h/db"))))
  (is (eq :postgres (cons/db:db-target-kind
                     (cons/db:parse-target "postgresql://u@h/db"))))
  (is (eq :sqlite (cons/db:db-target-kind (cons/db:parse-target "sqlite:///tmp/x.db"))))
  ;; a local dev database is usually just a path, not a URL
  (is (eq :sqlite (cons/db:db-target-kind (cons/db:parse-target "./data/app.db"))))
  (signals cons/db:db-repl-error (cons/db:parse-target "mysql://u@h/db")))

;;; --- credentials: the part that matters ------------------------------------

(test the-password-never-reaches-the-child-argv
  ;; psql "postgres://u:pw@h/db" would put the credential in the process table, readable by
  ;; any user on the machine via ps. The URL handed to the client carries no password.
  (let ((tgt (cons/db:parse-target "postgres://app:s3cret@db.example.com:5432/appdb?sslmode=require")))
    (is (null (search "s3cret" (cons/db:db-target-url tgt))))
    (is (search "app@db.example.com" (cons/db:db-target-url tgt)))
    (is (search "sslmode=require" (cons/db:db-target-url tgt)))   ; the rest survives
    (is (string= "s3cret"                                        ; captured for the env
                 (aion/secret:reveal (cons/db::db-target-password tgt))))))

(test the-displayed-url-is-redacted
  (let ((tgt (cons/db:parse-target "postgres://app:s3cret@db.example.com/appdb")))
    (is (null (search "s3cret" (cons/db:db-target-display tgt))))
    (is (search "****" (cons/db:db-target-display tgt)))
    ;; still identifies WHICH database, which is the point of showing it at all
    (is (search "db.example.com" (cons/db:db-target-display tgt)))
    (is (search "app" (cons/db:db-target-display tgt)))))

(test a-url-without-a-password-is-unchanged
  (let ((tgt (cons/db:parse-target "postgres://app@localhost/dev")))
    (is (null (cons/db::db-target-password tgt)))
    (is (string= "postgres://app@localhost/dev" (cons/db:db-target-url tgt)))))

(test db-url-prints-redacted-by-default
  ;; The obvious use is pasting the output somewhere -- a ticket, a chat window.
  (with-clean-db-env
    (set-env "DATABASE_URL" "postgres://u:hunter2@h/db")
    (let ((shown (with-output-to-string (*standard-output*)
                   (cons/db:db-url :env "dev"))))
      (is (null (search "hunter2" shown)))
      (is (search "****" shown)))
    (let ((shown (with-output-to-string (*standard-output*)
                   (cons/db:db-url :env "dev" :reveal t))))
      (is (search "hunter2" shown)))))

;;; --- #209: a resolved target must not print its password --------------------

(test db-target-printing-does-not-disclose-the-password
  ;; This struct was already careful twice over -- the URL it carries has the password
  ;; stripped, and DISPLAY is a redacted form built for exactly this purpose -- and still
  ;; leaked, because the default structure printer renders every slot and a backtrace
  ;; prints the frame's arguments. Being careful on the paths you think of is not
  ;; coverage of the path you do not.
  (let* ((pw "s3cret-do-not-log-me")
         (tgt (cons/db::parse-target
               (format nil "postgres://u:~A@h.example.com:5432/appdb" pw)))
         (printed (format nil "~S" tgt)))
    (is (null (search pw printed))
        "a printed DB-TARGET disclosed its password: ~S" printed)
    ;; The redacted display and the stripped URL must still be readable -- they are the
    ;; whole reason this struct is worth printing.
    (is (search "h.example.com" printed))))

(test db-target-password-is-still-there-to-have-been-leaked
  ;; The control: without it the test above passes against a parser that silently dropped
  ;; the password, which would break `cons db-repl` against every password-protected
  ;; database while the suite stayed green.
  (let ((tgt (cons/db::parse-target "postgres://u:s3cret-do-not-log-me@h/appdb")))
    (is (string= "s3cret-do-not-log-me"
                 (aion/secret:reveal (cons/db::db-target-password tgt))))))

;;; --- cons stays Coalton-free (#209) -----------------------------------------

(defun %transitive-deps (system &optional (seen (make-hash-table :test #'equal)))
  "Every system SYSTEM depends on, transitively, as lowercased names."
  (let ((name (string-downcase (asdf:component-name (asdf:find-system system)))))
    (unless (gethash name seen)
      (setf (gethash name seen) t)
      (dolist (d (asdf:system-depends-on (asdf:find-system system)))
        ;; A dep may be a (:feature …) or (:require …) form rather than a name.
        (let ((n (cond ((stringp d) d) ((symbolp d) (string-downcase (symbol-name d))))))
          (when (and n (asdf:find-system n nil))
            (%transitive-deps n seen))))))
  seen)

(test cons-does-not-depend-on-coalton
  ;; #209 added aion/secret to cons so a DB password could be held opaquely. That was only
  ;; admissible because aion/secret is `:depends-on ()' and Coalton-free -- cons's core is
  ;; meant to stay trivial to install, and aion/log is the standing example of an
  ;; intra-tree dep quietly making a framework pull Coalton (see docs/dependencies.md).
  ;;
  ;; Asserted over ASDF's dependency GRAPH rather than over (find-package '#:coalton),
  ;; deliberately: the image question gives a false failure in any warm image that loaded
  ;; Coalton for something else, and the declaration is the thing actually being defended.
  (let ((deps (%transitive-deps "cons")))
    (is-false (gethash "coalton" deps)
              "cons now depends on coalton, transitively -- see docs/dependencies.md")
    ;; Assert the check is still ASKING something: if the walk silently returned an empty
    ;; table, the assertion above would pass forever while testing nothing.
    (is-true (gethash "aion/secret" deps)
             "the dependency walk found nothing -- this test has stopped testing anything")))
