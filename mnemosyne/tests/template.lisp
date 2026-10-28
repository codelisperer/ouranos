;;;; template.lisp --- tests for mnemosyne/test-template (#1047).
;;;;
;;;; A copy must hold what the migrations made, and must be its own database: a test that
;;;; writes to its copy must not change what the next test's copy holds.

(in-package #:mnemosyne/tests)

(def-suite template
  :description "mnemosyne/test-template: one migrated SQLite template, a copy per test (#1047)."
  :in mnemosyne)
(in-suite template)

(defun %template-migrations ()
  (list (be:make-migration "20261028_101_notes" "notes"
                           "CREATE TABLE notes (id integer PRIMARY KEY, body text NOT NULL)"
                           "DROP TABLE notes")
        (be:make-migration "20261028_102_seed" "one seeded note"
                           "INSERT INTO notes (id, body) VALUES (1, 'seeded')"
                           "DELETE FROM notes WHERE id = 1")))

(defun %count (c sql)
  (second (first (conn:query c sql))))

(defmacro %with-template ((var migrations) &body body)
  `(let ((,var (tmpl:make-sqlite-template ,migrations)))
     (unwind-protect (progn ,@body)
       (tmpl:close-sqlite-template ,var))))

(test a-copy-holds-the-migrated-tables-rows-and-migration-records
  (%with-template (tm (%template-migrations))
    (is (equal '("20261028_101_notes" "20261028_102_seed") (tmpl:sqlite-template-applied tm)))
    (tmpl:with-sqlite-template-copy (c tm)
      (is (= 1 (%count c "SELECT count(*) FROM notes")))
      (is (= 2 (%count c "SELECT count(*) FROM schema_migrations")))
      (is (null (mig:pending c (%template-migrations)))
          "migrate has nothing left to apply to a copy"))))

(test a-write-to-one-copy-is-not-seen-by-the-template-or-the-next-copy
  "Each test gets its own database. Control: two connections to one database would see the row."
  (%with-template (tm (%template-migrations))
    (tmpl:with-sqlite-template-copy (first tm)
      (conn:exec first "INSERT INTO notes (id, body) VALUES (2, 'written by the first test')")
      (conn:exec first "DELETE FROM notes WHERE id = 1")
      (is (= 1 (%count first "SELECT count(*) FROM notes WHERE id = 2")))
      (is (= 0 (%count first "SELECT count(*) FROM notes WHERE id = 1"))))
    (tmpl:with-sqlite-template-copy (next tm)
      (is (= 0 (%count next "SELECT count(*) FROM notes WHERE id = 2"))
          "the next copy does not see the first test's insert")
      (is (= 1 (%count next "SELECT count(*) FROM notes WHERE id = 1"))
          "nor its delete"))
    (is (= 1 (%count (tmpl::sqlite-template-connection tm) "SELECT count(*) FROM notes"))
        "the template is unchanged")))

(test two-copies-open-at-once-are-separate
  (%with-template (tm (%template-migrations))
    (tmpl:with-sqlite-template-copy (a tm)
      (tmpl:with-sqlite-template-copy (b tm)
        (conn:exec a "INSERT INTO notes (id, body) VALUES (3, 'a')")
        (is (= 2 (%count a "SELECT count(*) FROM notes")))
        (is (= 1 (%count b "SELECT count(*) FROM notes")))))))

(test a-copy-outlives-its-template
  (let* ((tm (tmpl:make-sqlite-template (%template-migrations)))
         (c (tmpl:copy-sqlite-template tm)))
    (tmpl:close-sqlite-template tm)
    (unwind-protect (is (= 1 (%count c "SELECT count(*) FROM notes")))
      (conn:disconnect c))))

(test a-template-whose-migration-fails-signals
  (signals conn:db-error
    (tmpl:make-sqlite-template
     (list (be:make-migration "20261028_103_bad" "not SQL" "NOT SQL AT ALL" "")))))
