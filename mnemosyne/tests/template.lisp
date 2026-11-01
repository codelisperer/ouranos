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

(defmacro %with-template ((var migrations &rest options) &body body)
  `(let ((,var (tmpl:make-sqlite-template ,migrations ,@options)))
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
  "Each test gets its own database."
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

(test a-copy-that-cannot-be-made-signals-and-closes-its-connection
  "sqlite3_backup_init refuses a destination that has a transaction open. The connection
COPY-SQLITE-TEMPLATE opens is made to start a read transaction, so the copy fails inside
%BACKUP; that connection is then disconnected, and the template is not."
  (%with-template (tm (%template-migrations))
    (let ((closed '()))
      (unwind-protect
           (progn
             (sb-int:encapsulate 'conn:connect '%begin-a-read
                                 (lambda (f backend)
                                   (let ((c (funcall f backend)))
                                     (conn:exec c "BEGIN")
                                     (conn:query c "SELECT count(*) FROM sqlite_master")
                                     c)))
             (sb-int:encapsulate 'conn:disconnect '%record-disconnect
                                 (lambda (f c) (push c closed) (funcall f c)))
             (signals conn:db-error (tmpl:copy-sqlite-template tm)))
        (sb-int:unencapsulate 'conn:connect '%begin-a-read)
        (sb-int:unencapsulate 'conn:disconnect '%record-disconnect))
      (is (= 1 (length closed)) "the copy's connection was disconnected: ~S" closed)
      (is (not (eq (tmpl::sqlite-template-connection tm) (first closed)))
          "and it was not the template's"))))

(test foreign-keys-are-off-on-a-copy-until-the-test-turns-them-on
  "PRAGMA foreign_keys belongs to a connection, so a copy does not inherit it (docs/migrations.md
section 10). A test that relies on foreign keys sets it on its copy, and SQLite then enforces them."
  (%with-template (tm (list (be:make-migration "20261028_104_parent" "parent"
                                               "CREATE TABLE parent (id integer PRIMARY KEY)"
                                               "DROP TABLE parent")
                            (be:make-migration "20261028_105_child" "child"
                                               (concatenate
                                                'string
                                                "CREATE TABLE child (id integer PRIMARY KEY, "
                                                "parent_id integer NOT NULL "
                                                "REFERENCES parent (id))")
                                               "DROP TABLE child")))
    (tmpl:with-sqlite-template-copy (c tm)
      (is (= 0 (%count c "PRAGMA foreign_keys")))
      (conn:exec c "INSERT INTO child (id, parent_id) VALUES (1, 99)")
      (is (= 1 (%count c "SELECT count(*) FROM child")) "without the pragma the orphan is stored"))
    (tmpl:with-sqlite-template-copy (c tm)
      (conn:exec c "PRAGMA foreign_keys = ON")
      (is (= 1 (%count c "PRAGMA foreign_keys")))
      (signals conn:db-error (conn:exec c "INSERT INTO child (id, parent_id) VALUES (1, 99)"))
      (is (= 0 (%count c "SELECT count(*) FROM child"))))))

(test a-closed-template-refuses-a-copy
  (let ((tm (tmpl:make-sqlite-template (%template-migrations))))
    (tmpl:close-sqlite-template tm)
    (signals conn:db-error (tmpl:copy-sqlite-template tm))
    (finishes (tmpl:close-sqlite-template tm))))

(test setup-runs-on-the-template-connection-before-the-migrations
  "With foreign keys on while migrating, a migration's delete cascades in the template, and so
in every copy. Without SETUP the child row stays behind."
  (let ((migrations
          (list (be:make-migration "20261028_106_parent" "parent"
                                   "CREATE TABLE parent (id integer PRIMARY KEY)"
                                   "DROP TABLE parent")
                (be:make-migration "20261028_107_child" "child"
                                   (concatenate
                                    'string
                                    "CREATE TABLE child (id integer PRIMARY KEY, parent_id integer "
                                    "REFERENCES parent (id) ON DELETE CASCADE)")
                                   "DROP TABLE child")
                (be:make-migration "20261028_108_rows" "rows"
                                   "INSERT INTO parent (id) VALUES (1)" "")
                (be:make-migration "20261028_109_child_row" "a child row"
                                   "INSERT INTO child (id, parent_id) VALUES (1, 1)" "")
                (be:make-migration "20261028_110_delete" "delete the parent"
                                   "DELETE FROM parent WHERE id = 1" ""))))
    (%with-template (tm migrations
                        :setup (lambda (c) (conn:exec c "PRAGMA foreign_keys = ON")))
      (tmpl:with-sqlite-template-copy (c tm)
        (is (= 0 (%count c "SELECT count(*) FROM child")) "the delete cascaded")))
    (%with-template (tm migrations)
      (tmpl:with-sqlite-template-copy (c tm)
        (is (= 1 (%count c "SELECT count(*) FROM child")) "control: without SETUP it did not")))))
