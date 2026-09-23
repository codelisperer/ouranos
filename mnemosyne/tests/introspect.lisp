;;;; tests/introspect.lisp --- the live table vs the defschema (#144).
;;;;
;;;; Two halves, and the second is the one that matters.
;;;;
;;;; The PURE half diffs a schema against a hand-built column list: it can reach the
;;;; branches (a type that differs, a nullability that differs, a table that is not there)
;;;; without contriving DDL for each one, and it needs no database.
;;;;
;;;; The LIVE half runs on every active backend and closes the actual loop the ticket is
;;;; about: CREATE the table from SCHEMA-DDL, read it back out of the catalog, and require
;;;; the diff to be CLEAN. That is a round trip through two independent translations -- the
;;;; generator's idea of what `:uuid` is, and the catalog's report of what it got -- and it
;;;; is per-dialect, which is where this class of bug lives. `:uuid` is UUID on Postgres and
;;;; TEXT on SQLite; `:boolean` is BOOLEAN and INTEGER; `:integer` is BIGINT and INTEGER.
;;;; Diffing SQLite against Postgres expectations would report drift in every single row.
;;;;
;;;; Then the ticket's own scenario, executed rather than described: a defschema that has
;;;; grown a column the table does not have, reconciled by DDL DERIVED FROM THE DIFF and
;;;; applied, after which the diff is clean -- and the reverse reading, where the table is
;;;; ahead of the definition, which is the shape #144's workaround actually leaves behind.

(in-package #:mnemosyne/tests)

(in-suite mnemosyne)

;;; Two versions of one table: v1 is what was migrated, v2 is the defschema after someone
;;; added a column. The whole ticket is the gap between them.
(sch:defschema drift-v1 (:table "drift_t")
  (:id     :uuid    :primary t)
  (:email  :string  :required t)
  (:age    :integer)
  (:active :boolean))

(sch:defschema drift-v2 (:table "drift_t")
  (:id       :uuid    :primary t)
  (:email    :string  :required t)
  (:age      :integer)
  (:active   :boolean)
  (:nickname :string))

;;; --- pure: the diff, with no database -------------------------------------

(defun %dcol (name type &key required primary)
  "A COLUMN built by hand. Named %DCOL, not %COL: tests/param.lisp already owns %COL and
loads after this file, so the shorter name would be silently redefined out from under
these tests -- which is how they first failed."
  (intro::%make-column :name name :sql-type type :required required :primary primary))

(defun %v1-columns (&key (dialect "postgres"))
  "The columns a correct drift_t would have under DIALECT, built by hand."
  (if (string= dialect "postgres")
      (list (%dcol :id "uuid" :primary t :required t)
            (%dcol :email "text" :required t)
            (%dcol :age "bigint")
            (%dcol :active "boolean"))
      (list (%dcol :id "TEXT" :primary t)
            (%dcol :email "TEXT" :required t)
            (%dcol :age "INTEGER")
            (%dcol :active "INTEGER"))))

(test diff-clean-when-the-table-matches
  (dolist (d '("postgres" "sqlite"))
    (let ((drift (intro:schema-diff (sch:find-schema 'drift-v1) (%v1-columns :dialect d)
                                    :dialect d)))
      (is (intro:drift-clean-p drift) "drift_t must match drift-v1 under ~A" d)
      (is (null (intro:drift-missing drift)))
      (is (null (intro:drift-extra drift)))
      (is (null (intro:drift-mismatched drift))))))

(test diff-reports-a-column-the-table-lacks
  ;; The defschema grew a column and nobody wrote the migration -- silent divergence,
  ;; normally discovered at runtime on whichever database is behind.
  (let ((drift (intro:schema-diff (sch:find-schema 'drift-v2) (%v1-columns))))
    (is (not (intro:drift-clean-p drift)))
    (is (equal '(:nickname) (mapcar #'sch:field-name (intro:drift-missing drift))))
    (is (null (intro:drift-extra drift)))))

(test diff-reports-a-column-the-schema-lacks
  ;; The inverse, and the one #144's survivable workaround produces: an ALTER migration ran
  ;; and the defschema was deliberately left alone. Correct data, lying definition.
  (let ((drift (intro:schema-diff (sch:find-schema 'drift-v1)
                                  (append (%v1-columns) (list (%dcol :nickname "text"))))))
    (is (not (intro:drift-clean-p drift)))
    (is (equal '(:nickname) (mapcar #'intro:column-name (intro:drift-extra drift))))
    (is (null (intro:drift-missing drift)))))

(test diff-reports-a-type-that-differs
  (let* ((cols (substitute (%dcol :age "integer") :age (%v1-columns)
                           :key #'intro:column-name :count 1))
         (drift (intro:schema-diff (sch:find-schema 'drift-v1) cols)))
    (is (not (intro:drift-clean-p drift))
        "int4 where the schema asks for int8 is real drift, not a spelling difference")
    (is (equal '(:age) (mapcar (lambda (p) (sch:field-name (car p)))
                               (intro:drift-mismatched drift))))))

(test diff-reports-a-nullability-that-differs
  (let* ((cols (substitute (%dcol :email "text") :email (%v1-columns)
                           :key #'intro:column-name :count 1))
         (drift (intro:schema-diff (sch:find-schema 'drift-v1) cols)))
    (is (equal '(:email) (mapcar (lambda (p) (sch:field-name (car p)))
                                 (intro:drift-mismatched drift))))))

(test diff-tolerates-a-primary-key-sqlite-does-not-mark-not-null
  ;; SQLite allows NULL in a TEXT PRIMARY KEY column, so pragma_table_info reports
  ;; notnull=0 for exactly the column SCHEMA-DDL wrote as `id TEXT PRIMARY KEY`. Comparing
  ;; the NOT NULL flag alone would report permanent, unfixable drift on every such table.
  (let ((drift (intro:schema-diff (sch:find-schema 'drift-v1)
                                  (list (%dcol :id "TEXT" :primary t)   ; required NIL
                                        (%dcol :email "TEXT" :required t)
                                        (%dcol :age "INTEGER")
                                        (%dcol :active "INTEGER"))
                                  :dialect "sqlite")))
    (is (intro:drift-clean-p drift))))

(test diff-reports-a-missing-table-as-its-own-state
  (let ((drift (intro:schema-diff (sch:find-schema 'drift-v1) '())))
    (is (not (intro:drift-table-present drift))
        "no columns at all means no table -- a different problem from an out-of-date one")
    (is (not (intro:drift-clean-p drift)))))

(test canonical-type-folds-spellings-but-not-widths
  (flet ((c (s) (intro::%canonical-type s)))
    (is (string= "VARCHAR" (c "character varying(255)")) "precision is not drift")
    (is (string= "TIMESTAMPTZ" (c "timestamp with time zone")))
    (is (string= "TIMESTAMP" (c "timestamp without time zone")))
    (is (string= "BOOLEAN" (c "bool")))
    (is (string= "INTEGER" (c "int4")))
    (is (string= "BIGINT" (c "int8")))
    (is (string= "DOUBLE PRECISION" (c "  double   precision ")))
    (is (not (string= (c "integer") (c "bigint"))) "a width difference must survive")))

;;; --- pure: turning the difference back into DDL ---------------------------

(test drift-ddl-derives-the-alter-that-reconciles
  (let* ((drift (intro:schema-diff (sch:find-schema 'drift-v2) (%v1-columns)))
         (forms (intro:drift-ddl drift)))
    (is (= 1 (length forms)))
    (is (eq :alter-table (first (first forms))))
    (is (equal '(:add-column :nickname :string) (third (first forms))))
    ;; and it must actually render -- the point is that nobody hand-writes this
    (let ((sql (first (ddl:ddl-statements (first forms) :dialect "postgres"))))
      (is (search "ALTER TABLE drift_t ADD COLUMN nickname TEXT" sql)))))

(test drift-ddl-does-not-drop-by-default
  ;; An extra column is usually the #144 workaround -- correct data the defschema does not
  ;; mention. Defaulting to DROP COLUMN would turn a documentation problem into a
  ;; destructive one.
  (let ((drift (intro:schema-diff (sch:find-schema 'drift-v1)
                                  (append (%v1-columns) (list (%dcol :nickname "text"))))))
    (is (null (intro:drift-ddl drift)))
    (is (equal '(:drop-column :nickname)
               (third (first (intro:drift-ddl drift :include-drops t)))))))

(test drift-ddl-refuses-to-guess-at-a-type-change
  (let* ((cols (substitute (%dcol :age "integer") :age (%v1-columns)
                           :key #'intro:column-name :count 1))
         (drift (intro:schema-diff (sch:find-schema 'drift-v1) cols)))
    (is (intro:drift-mismatched drift))
    (is (null (intro:drift-ddl drift))
        "changing a column type is a table rebuild on SQLite and a data decision on Postgres")))

;;; --- live: the round trip, on every active backend ------------------------

(defun %signals-drift-p (thunk)
  "Did calling THUNK signal SCHEMA-DRIFT?

A function rather than a HANDLER-CASE written inline in IS*: fiveam's IS destructures a
form as (predicate . args) and evaluates each argument to report it, so the handler CLAUSE
of an inline HANDLER-CASE gets compiled as an argument expression -- `(schema-drift nil t)`,
an undefined function call. The test still passed for the wrong reason."
  (handler-case (progn (funcall thunk) nil)
    (intro:schema-drift () t)))

(defun %backend ()
  "The BACKEND matching the connection WITH-EACH-BACKEND is currently bound to.

Recovered from the name rather than exposed by the macro so that the shared harness stays
as it is; ACTIVE-BACKENDS is memoised, so this costs a lookup and not a probe."
  (cdr (assoc *current-backend* (active-backends) :test #'equal)))

(defun %create-drift-t (conn schema)
  "DROP then CREATE drift_t from SCHEMA's generated DDL, in the current dialect.

DROP first for %FRESH-TABLE's reason: `:memory:` is empty at every connect and a real
Postgres is not."
  (conn:exec conn "DROP TABLE IF EXISTS drift_t")
  (conn:exec conn (sch:schema-ddl (sch:find-schema schema)
                                  :dialect (be:backend-name (%backend)))))

(test generated-ddl-round-trips-through-the-catalog
  ;; The load-bearing test. SCHEMA-DDL's idea of what a field is, and the catalog's report
  ;; of what the database made, are two independent translations; this requires them to
  ;; agree, per dialect, or the drift checker is useless on that backend.
  (with-each-backend (c)
    (%create-drift-t c 'drift-v1)
    (let ((drift (intro:diff-table (%backend) c (sch:find-schema 'drift-v1))))
      (unless (intro:drift-clean-p drift)
        (intro:report-drift drift *error-output*))
      (is* (intro:drift-clean-p drift)
           "a table CREATEd from schema-ddl must read back as matching its own schema")
      (is* (intro:drift-table-present drift))
      (is* (= 4 (length (intro:table-columns (%backend) c "drift_t")))))))

(test a-defschema-ahead-of-the-table-is-found-and-reconciled
  ;; #144, executed: the defschema grew a column, the table did not. The gap is detected,
  ;; the ALTER is DERIVED from the gap rather than hand-written, applying it closes the
  ;; gap -- and the already-applied CREATE was never touched.
  (with-each-backend (c)
    (%create-drift-t c 'drift-v1)                       ; history, replayed
    (let* ((b (%backend))
           (schema (sch:find-schema 'drift-v2))         ; the present
           (drift (intro:diff-table b c schema)))
      (is* (equal '(:nickname) (mapcar #'sch:field-name (intro:drift-missing drift)))
           "the column in the defschema and not in the table must be named")
      (is* (not (intro:drift-clean-p drift)))
      ;; verify-schema is the assertion an app puts after MIGRATE
      (is* (%signals-drift-p (lambda () (intro:verify-schema b c schema)))
           "verify-schema must signal on a missing column")
      ;; the loop: diff -> ddl -> exec -> clean
      (dolist (form (intro:drift-ddl drift))
        (dolist (stmt (ddl:ddl-statements form :dialect (be:backend-name b)))
          (conn:exec c stmt)))
      (let ((after (intro:diff-table b c schema)))
        (unless (intro:drift-clean-p after)
          (intro:report-drift after *error-output*))
        (is* (intro:drift-clean-p after)
             "applying the derived ALTER must leave the table matching the defschema")))))

(test a-table-ahead-of-the-defschema-is-the-workaround-and-is-sayable
  ;; The other direction, which is the state #144 says apps are actually left in: the ALTER
  ;; ran and the defschema was deliberately not touched. VERIFY-SCHEMA must be able to call
  ;; that out AND to be told it is intended, because a check with only an off switch gets
  ;; switched off.
  (with-each-backend (c)
    (%create-drift-t c 'drift-v2)                       ; the table has nickname
    (let* ((b (%backend))
           (behind (sch:find-schema 'drift-v1))         ; the defschema does not
           (drift (intro:diff-table b c behind)))
      (is* (equal '(:nickname) (mapcar #'intro:column-name (intro:drift-extra drift))))
      (is* (%signals-drift-p (lambda () (intro:verify-schema b c behind)))
           "an undeclared column must signal by default")
      (is* (not (%signals-drift-p
                 (lambda () (intro:verify-schema b c behind :allow-extra t))))
           ":allow-extra is how an app says the divergence is deliberate"))))

(test an-absent-table-is-reported-as-absent-not-as-empty
  (with-each-backend (c)
    (conn:exec c "DROP TABLE IF EXISTS drift_t")
    (let ((b (%backend)))
      (is* (null (intro:table-columns b c "drift_t")))
      (is* (not (intro:table-exists-p b c "drift_t")))
      (is* (not (intro:drift-table-present (intro:diff-table b c (sch:find-schema 'drift-v1))))))))

(test a-changed-vector-dimension-is-drift-but-a-changed-varchar-precision-is-not
  "The parenthesised number means different things in different types (#212).

VARCHAR(255) and VARCHAR(80) hold the same kind of value and one can become the other, so
the existing rule drops the precision and is right to. VECTOR(1536) and VECTOR(768) cannot:
pgvector refuses a value of the wrong width, and a schema that says one against a database
that says the other fails every write. Reporting that as clean would hide the one thing
about a vector column most worth seeing."
  (flet ((c (s) (intro::%canonical-type s)))
    (is (string= (c "character varying(255)") (c "character varying(80)"))
        "a varchar precision difference is still not drift")
    (is (not (string= (c "vector(1536)") (c "vector(768)")))
        "a vector dimension difference must be drift")
    (is (string= "VECTOR(1536)" (c "vector(1536)")))
    (is (string= "VECTOR(1536)" (c "  VECTOR (1536) "))
        "spacing a catalog happens to use must not read as a different type")
    (is (string= "VECTOR" (c "vector"))
        "a bare vector still canonicalises to itself")))
;;; --- the guard that makes a config-resolved width safe (#258) ---------------
;;;
;;; #258 let `:dimensions' be an ordinary Lisp expression, so a width can come from
;;; configuration. That buys a real thing -- an app can measure recall at 1024 and at 3072
;;; without editing schema source -- and it creates one hazard: two deployments of the same
;;; code render DIFFERENT DDL, so a database migrated at one width meets a schema declaring
;;; another. This is the detector for exactly that, and it already existed: a changed vector
;;; dimension is drift by design (#212). What is new is the assertion that it covers the case
;;; the new capability introduces, on every host, with no database.

(sch:defschema width-1024 (:table "width_t")
  (:id        :uuid   :primary t)
  (:embedding :vector :dimensions 1024))

(test a-width-the-database-does-not-share-is-drift-and-names-the-column
  (let ((drift (intro:schema-diff (sch:find-schema 'width-1024)
                                  (list (%dcol :id "uuid" :primary t)
                                        (%dcol :embedding "vector(768)")))))
    (is (not (intro:drift-clean-p drift))
        "a schema resolved to 1024 against a column of 768 must not read as clean")
    (is (null (intro:drift-missing drift)) "the column is there")
    (is (= 1 (length (intro:drift-mismatched drift)))
        "it is a MISMATCH -- the one drift class an app can neither ignore nor migrate away
by adding something")
    (let ((report (with-output-to-string (s) (intro:report-drift drift s))))
      ;; The report is better than "names the column", so this asserts what it actually
      ;; gives: BOTH widths, which is what tells a reader whether the fix is a migration or
      ;; a configuration change. (Case-insensitively -- it prints the schema's column names
      ;; upcased, and a test that pinned the case would be asserting the printer's taste.)
      (is (search "embedding" report :test #'char-equal) "the column is named")
      (is (search "1024" report) "the width the schema resolved to")
      (is (search "768" report)
          "and the width the database has -- the pair is the diagnosis; either alone leaves
the reader to guess which side moved"))))

(test the-same-width-on-both-sides-is-clean
  "The control. Without it the assertion above could be satisfied by a diff that called
every vector column drift, which would make the detector useless in the opposite direction."
  (let ((drift (intro:schema-diff (sch:find-schema 'width-1024)
                                  (list (%dcol :id "uuid" :primary t)
                                        (%dcol :embedding "vector(1024)")))))
    (is (intro:drift-clean-p drift))))

;;; --- ADR-0003 / #432: introspect speaks the tree's dialect vocabulary -------

(test schema-diff-refuses-an-unrecognised-dialect
  "DRIFT-DIALECT is printed in a report an operator is meant to act on, so an unchecked
designator reaching it is a backend name nobody verified. Refuse at the entry instead."
  (dolist (bad '("postgers" :postgers 42))
    (signals fldsh:unknown-dialect
      (intro:schema-diff (sch:find-schema 'drift-v1) (%v1-columns) :dialect bad))))

(test schema-diff-agrees-across-spellings-and-canonicalises-the-name
  "The same dialect under either spelling gives the same verdict, and the DRIFT carries the
canonical name rather than whatever the caller happened to type. A diff that reported
drift in every row because the caller used the other module's spelling is the same defect
#432 is about, one module over."
  (dolist (pair '(("postgres" . :postgres) ("sqlite" . :sqlite)))
    (let* ((cols (%v1-columns :dialect (car pair)))
           (by-string  (intro:schema-diff (sch:find-schema 'drift-v1) cols :dialect (car pair)))
           (by-keyword (intro:schema-diff (sch:find-schema 'drift-v1) cols :dialect (cdr pair))))
      (is (eq (intro:drift-clean-p by-string) (intro:drift-clean-p by-keyword))
          "~S and ~S must reach the same verdict" (car pair) (cdr pair))
      (is (intro:drift-clean-p by-keyword)
          "drift_t must be clean under ~S -- if the keyword spelling took the other
dialect's expectations, every row would mismatch" (cdr pair))
      (is (string= (car pair) (intro:drift-dialect by-keyword))
          "the drift must carry the canonical name, not the caller's spelling"))))
