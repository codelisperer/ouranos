;;;; migrate.lisp --- what MIGRATE logs, and at which level (#1046).
;;;;
;;;; A test suite that migrates a fresh database for every test calls MIGRATE thousands of
;;;; times, so each applied migration is a DEBUG line and each call ends with one INFO line.
;;;; These tests capture the log at :INFO and at :DEBUG on an in-memory SQLite database.

(in-package #:mnemosyne/tests)

(def-suite migrate-logging :description "What MIGRATE logs (#1046)." :in mnemosyne)
(in-suite migrate-logging)

(defmacro %with-migrate-log ((stream level) &body body)
  "Run BODY with the log at LEVEL going to STREAM, then put back the appenders, level and layout
that were there before."
  (let ((appenders (gensym "APPENDERS")) (old-level (gensym "LEVEL")) (layout (gensym "LAYOUT")))
    `(let ((,appenders (copy-list (log4cl:logger-appenders log4cl:*root-logger*)))
           (,old-level (log4cl:logger-log-level log4cl:*root-logger*))
           (,layout aion/log:*layout*))
       (unwind-protect
            (progn (aion/log:setup :env :dev :level ,level :stream ,stream)
                   ,@body)
         (log4cl:remove-all-appenders log4cl:*root-logger*)
         (dolist (appender ,appenders)
           (log4cl:add-appender log4cl:*root-logger* appender))
         (log4cl:set-log-level log4cl:*root-logger* ,old-level)
         (setf aion/log:*layout* ,layout)))))

(defun %three-migrations ()
  (list (be:make-migration "20261028_001_a" "table a" "CREATE TABLE mig_a (x integer)"
                           "DROP TABLE mig_a")
        (be:make-migration "20261028_002_b" "table b" "CREATE TABLE mig_b (x integer)"
                           "DROP TABLE mig_b")
        (be:make-migration "20261028_003_c" "table c" "CREATE TABLE mig_c (x integer)"
                           "DROP TABLE mig_c")))

(defun %migrate-lines (text)
  "The lines of TEXT that MIGRATE wrote."
  (remove-if-not (lambda (line) (search "migrate: " line))
                 (uiop:split-string text :separator '(#\Newline))))

(defun %call-migrating (level migrations &key (times 1))
  "Migrate a fresh in-memory SQLite database TIMES times with the log at LEVEL. Returns MIGRATE's
result from the last call, and the lines MIGRATE logged in all of them."
  (let ((log (make-string-output-stream))
        (c (conn:connect (be:make-sqlite ":memory:")))
        (result nil))
    (unwind-protect
         (%with-migrate-log (log level)
           (dotimes (i times)
             (setf result (mig:migrate (be:make-sqlite ":memory:") c migrations))))
      (conn:disconnect c))
    (values result (%migrate-lines (get-output-stream-string log)))))

(test migrate-logs-one-info-line-per-call-with-the-count-and-the-duration
  (multiple-value-bind (applied lines) (%call-migrating :info (%three-migrations))
    (is (= 3 (length applied)))
    (is (= 1 (length lines)) "one line at INFO: ~S" lines)
    (let ((line (first lines)))
      (is (search "migrate: finished" line) "~A" line)
      (is (search "pending=3" line) "~A" line)
      (is (search "applied=3" line) "~A" line)
      (is (search " ms=" line) "~A" line)
      (is (null (search "failed=" line)) "~A" line))))

(test migrate-logs-each-applied-migration-at-debug
  (multiple-value-bind (applied lines) (%call-migrating :debug (%three-migrations))
    (declare (ignore applied))
    (let ((each (remove-if-not (lambda (line) (search "migrate: applied" line)) lines)))
      (is (= 3 (length each)) "one DEBUG line per migration: ~S" lines)
      (is (search "20261028_002_b" (second each)) "~S" each))
    (is (= 1 (count-if (lambda (line) (search "migrate: finished" line)) lines)) "~S" lines)))

(test migrate-with-nothing-to-apply-logs-nothing-at-info
  (multiple-value-bind (applied lines) (%call-migrating :info (%three-migrations) :times 2)
    (is (null applied) "the second call applies nothing")
    (is (= 1 (length lines)) "only the first call's line: ~S" lines)))

(test migrate-that-stops-on-a-failing-migration-names-it-at-info
  (let ((log (make-string-output-stream))
        (c (conn:connect (be:make-sqlite ":memory:")))
        (migrations (list (first (%three-migrations))
                          (be:make-migration "20261028_002_bad" "not SQL" "NOT SQL AT ALL" "")
                          (third (%three-migrations)))))
    (unwind-protect
         (%with-migrate-log (log :info)
           (signals conn:db-error (mig:migrate (be:make-sqlite ":memory:") c migrations)))
      (conn:disconnect c))
    (let ((lines (%migrate-lines (get-output-stream-string log))))
      (is (= 1 (length lines)) "~S" lines)
      (is (search "pending=3" (first lines)) "~S" lines)
      (is (search "applied=1" (first lines)) "~S" lines)
      (is (search "failed=20261028_002_bad" (first lines)) "~S" lines))))
