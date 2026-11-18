;;;; tests.lisp --- dokimasia/mnemosyne's probes against a SQLite database (#1028). No browser:
;;;; each probe's local form is called directly, and through dokimasia's :EXPECT-STORED step with
;;;; a row bound by hand.

(defpackage #:dokimasia/mnemosyne/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:d #:dokimasia)
                    (#:dm #:dokimasia/mnemosyne)
                    (#:be #:mnemosyne/backend)
                    (#:conn #:mnemosyne/conn))
  (:export #:run-tests))

(in-package #:dokimasia/mnemosyne/tests)

(def-suite dokimasia/mnemosyne :description "dokimasia/mnemosyne: stored-data probes that read a database through mnemosyne.")
(in-suite dokimasia/mnemosyne)

(defun run-tests ()
  (run! 'dokimasia/mnemosyne))

(defun call-with-accounts (function)
  "Call FUNCTION with a SQLite backend whose accounts table has two rows, in a new directory
that is deleted afterwards."
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "dokimasia-mnemosyne-~36R"
                                       (random (expt 36 8) (make-random-state t)))
                               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    (unwind-protect
         (let ((backend (be:make-sqlite (uiop:native-namestring (merge-pathnames "app.db" dir)))))
           (conn:with-connection (c backend)
             (conn:exec c "CREATE TABLE accounts (email TEXT NOT NULL, plan TEXT NOT NULL, seats INTEGER NOT NULL)")
             (conn:exec c "INSERT INTO accounts (email, plan, seats) VALUES (?, ?, ?), (?, ?, ?)"
                        "new@example.com" "free" 1 "team@example.com" "team" 5))
           (funcall function backend))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(defmacro with-accounts ((backend) &body body)
  `(call-with-accounts (lambda (,backend) ,@body)))

(defun local-form (name)
  (dokimasia::probe-local (dokimasia::find-probe name)))

(defun probe (name &rest values)
  "The probe NAME's local form called with VALUES: its result and its reason, as a list."
  (multiple-value-list (apply (local-form name) values)))

(defmacro refused ((fragment) &body body)
  `(let ((c (handler-case (progn ,@body nil) (d:invalid-definition (c) c))))
     (is (typep c 'd:invalid-definition) "~S was accepted" ',body)
     (when c (is (search ,fragment (d:invalid-definition-reason c))
                 "the reason ~S does not mention ~S" (d:invalid-definition-reason c) ,fragment))))

;;; --- define-row-probe --------------------------------------------------------------------

(test a-row-probe-passes-when-a-row-holds-the-values
  (with-accounts (db)
    (dm:define-row-probe :t-account :source db :table :accounts :match '(:email :plan))
    (dm:define-row-probe :t-seats :source db :table :accounts :match '(:email :seats))
    (is (equal '(t) (probe :t-account "new@example.com" "free")))
    (is (equal '(t) (probe :t-seats "team@example.com" "5"))
        "a step's value is a string, and SQLite compares it with an INTEGER column as a number")))

(test a-row-probe-failure-names-the-table-the-values-and-what-is-stored
  (with-accounts (db)
    (dm:define-row-probe :t-account :source db :table :accounts :match '(:email :plan))
    (dm:define-row-probe :t-email :source db :table :accounts :match '(:email))
    (destructuring-bind (ok why) (probe :t-account "new@example.com" "team")
      (is (null ok))
      (is (equal "accounts has no row with email = \"new@example.com\" and plan = \"team\"; the rows with email = \"new@example.com\" have plan = \"free\""
                 why)))
    (destructuring-bind (ok why) (probe :t-account "nobody@example.com" "free")
      (is (null ok))
      (is (equal "accounts has no row with email = \"nobody@example.com\" and plan = \"free\"" why)
          "with no row for the first column either, the reason stops after the values"))
    (is (equal '(nil "accounts has no row with email = \"x@example.com\"")
               (probe :t-email "x@example.com")))))

(test an-absent-row-probe-passes-only-when-no-row-holds-the-values
  (with-accounts (db)
    (dm:define-row-probe :t-no-account :source db :table :accounts :match '(:email) :absent t)
    (is (equal '(t) (probe :t-no-account "weak@example.com")))
    (is (equal '(nil "accounts has a row with email = \"new@example.com\", and the step expected none")
               (probe :t-no-account "new@example.com")))))

(test a-row-probe-given-the-wrong-number-of-values-says-so
  (with-accounts (db)
    (dm:define-row-probe :t-account :source db :table :accounts :match '(:email :plan))
    (is (equal '(nil "it matches 2 columns (email, plan), and the step gave 1 value")
               (probe :t-account "new@example.com")))))

(test the-source-can-be-a-pool-or-a-function-called-when-the-step-runs
  (with-accounts (db)
    (let ((pool (conn:make-pool db :size 1))
          (calls 0))
      (unwind-protect
           (progn
             (dm:define-row-probe :t-pooled :source pool :table :accounts :match '(:email))
             (dm:define-row-probe :t-late :source (lambda () (incf calls) db)
                                          :table :accounts :match '(:email))
             (is (= 0 calls) "defining the probe does not ask for the database")
             (is (equal '(t) (probe :t-pooled "team@example.com")))
             (is (equal '(t) (probe :t-late "team@example.com")))
             (is (= 1 calls)))
        (conn:close-pool pool)))))

(test a-query-the-database-refuses-fails-the-probe-with-the-database-s-reason
  (with-accounts (db)
    (dm:define-row-probe :t-missing :source db :table :no_such_table :match '(:email))
    (destructuring-bind (ok why) (probe :t-missing "new@example.com")
      (is (null ok))
      (is (search "the database refused the probe's query" why))
      (is (search "no_such_table" why) "the reason ~S does not name the table" why))))

(test a-row-probe-that-cannot-work-is-refused-when-it-is-defined
  (let ((db (be:make-sqlite ":memory:")))
    (refused (":SOURCE") (dm:define-row-probe :t-bad :table :accounts :match '(:email)))
    (refused (":TABLE") (dm:define-row-probe :t-bad :source db :table "accounts" :match '(:email)))
    (refused (":MATCH") (dm:define-row-probe :t-bad :source db :table :accounts :match '()))
    (refused (":MATCH") (dm:define-row-probe :t-bad :source db :table :accounts :match '("email")))
    (refused ("not a dialect") (dm:define-row-probe :t-bad :source db :table :accounts
                                                           :match '(:email) :dialect :oracle))
    (refused ("t-bad") (dm:define-row-probe :t-bad :source db :table :|accounts; drop|
                                                   :match '(:email)))
    (is (null (dokimasia::find-probe :t-bad)) "a refused probe is not stored")))

;;; --- define-query-probe ------------------------------------------------------------------

(test a-query-probe-runs-the-query-built-from-the-step-s-values
  (with-accounts (db)
    (dm:define-query-probe :t-seats-at-least :source db
                           :query (lambda (email seats)
                                    `(:select (:email) :from (:accounts)
                                      :where (:and (:= :email ,email) (:>= :seats ,(parse-integer seats))))))
    (dm:define-query-probe :t-no-big-team :source db :absent t
                           :query (lambda (seats)
                                    `(:select (:email) :from (:accounts)
                                      :where (:> :seats ,(parse-integer seats)))))
    (is (equal '(t) (probe :t-seats-at-least "team@example.com" "3")))
    (is (equal '(nil "the query for \"team@example.com\", \"9\" returned no row")
               (probe :t-seats-at-least "team@example.com" "9")))
    (is (equal '(t) (probe :t-no-big-team "10")))
    (is (equal '(nil "the query for \"0\" returned 2 rows, and the step expected none")
               (probe :t-no-big-team "0")))
    (refused (":QUERY") (dm:define-query-probe :t-bad :source db :query '(:select (:email))))))

;;; --- through dokimasia's :expect-stored step ----------------------------------------------

(defun expect-stored (target inputs &rest step-args)
  "Run the :EXPECT-STORED step with STEP-ARGS in a row against TARGET with INPUTS, as the runner
does, without a browser. Returns :PASSED, :NOT-RUN or :FAILED, and the reason."
  (let ((d:*row* (dokimasia::%make-row :target target :inputs inputs)))
    (handler-case (multiple-value-bind (kind why) (dokimasia::%expect-stored step-args)
                    (if (eq kind :not-run) (values :not-run why) (values :passed "")))
      (dokimasia::step-failure (c) (values :failed (dokimasia::step-failure-reason c))))))

(test the-step-runs-the-probe-against-a-process-target-and-not-against-a-url
  (with-accounts (db)
    (dm:define-row-probe :t-account :source db :table :accounts :match '(:email :plan))
    (let ((started (d:process-target :start (lambda () "http://127.0.0.1:1")))
          (deployed (d:url-target "https://staging.example.com"))
          (inputs '(("email" . "new@example.com") ("plan" . "free"))))
      (is (eq :passed (expect-stored started inputs :t-account '(:input :email) '(:input :plan))))
      (multiple-value-bind (kind why)
          (expect-stored started inputs :t-account '(:input :email) "team")
        (is (eq :failed kind))
        (is (search "the probe t-account: accounts has no row with email" why) "~S" why))
      (multiple-value-bind (kind why)
          (expect-stored deployed inputs :t-account '(:input :email) '(:input :plan))
        (is (eq :not-run kind) "a probe with only a local form is not run against a URL")
        (is (search "has no HTTP form" why))))))

(test a-url-target-made-with-local-probes-runs-a-row-probe
  (with-accounts (db)
    (dm:define-row-probe :t-account :source db :table :accounts :match '(:email :plan))
    (let ((reachable (d:url-target "http://127.0.0.1:1" :local-probes t))
          (control (d:url-target "http://127.0.0.1:1"))
          (inputs '(("email" . "new@example.com") ("plan" . "free"))))
      (is (eq :passed (expect-stored reachable inputs :t-account '(:input :email) '(:input :plan))))
      (multiple-value-bind (kind why)
          (expect-stored reachable inputs :t-account '(:input :email) "team")
        (is (eq :failed kind) "the probe ran, so a wrong value fails rather than not running")
        (is (search "accounts has no row with email" why) "~S" why))
      (multiple-value-bind (kind why)
          (expect-stored control inputs :t-account '(:input :email) '(:input :plan))
        (is (eq :not-run kind) "without :LOCAL-PROBES the same step against the same URL is not run")
        (is (search ":LOCAL-PROBES T" why) "the reason ~S does not say how to run it" why)))))
