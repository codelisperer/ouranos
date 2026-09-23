;;;; introspect.lisp --- what the TABLE actually is, and where it disagrees with the
;;;; DEFSCHEMA (#144).
;;;;
;;;; SCHEMA-DDL reads a MUTABLE definition to produce SQL for an IMMUTABLE, already-applied
;;;; migration. That wiring is the bind #144 reports: a migration that says
;;;; `(schema-ddl (find-schema 'profile))` is evaluated when migrations RUN, not when the
;;;; migration was WRITTEN, so editing the defschema silently rewrites history for anyone
;;;; who has not run it yet. Adding one column leaves three moves and all three are wrong:
;;;;
;;;;   edit the defschema + write an ALTER  -> a FRESH database creates the column in the
;;;;                                           original migration, then dies on the ALTER.
;;;;   edit the defschema only              -> fresh databases get it, existing ones never
;;;;                                           do. Silent divergence, found at runtime.
;;;;   ALTER only, defschema untouched      -> both paths correct, and the defschema now
;;;;                                           describes something other than the table.
;;;;
;;;; The third is the survivable one, and it is what apps do. What it lacks is a MECHANISM:
;;;; nothing tells you the definition has stopped describing reality, and the one failure
;;;; mode that IS loud -- the duplicate-column ALTER -- fires only on a fresh database,
;;;; which is exactly the database whoever made the change does not have.
;;;;
;;;; So state the model and then MEASURE it:
;;;;
;;;;   The DEFSCHEMA is the PRESENT. The migration list is HISTORY. A fresh database
;;;;   replays history and must ARRIVE at the present.
;;;;
;;;; This module is the "must arrive" half. TABLE-COLUMNS asks the live database what it
;;;; actually has; SCHEMA-DIFF compares that to the defschema and returns the difference as
;;;; DATA; VERIFY-SCHEMA signals on it, so an app can assert the invariant at boot or in a
;;;; test rather than discover it in production. DRIFT-DDL turns the difference back into
;;;; mnemosyne/ddl forms, which closes the loop #144 asks about: you edit the defschema,
;;;; ask what it would take to get there, and paste THAT into a NEW migration. Migration
;;;; 0007 is never touched, and the ALTER was still derived rather than hand-written.
;;;;
;;;; Effectful CL, deliberately: reading a catalog is IO. SCHEMA-DIFF and DRIFT-DDL are
;;;; pure and take the columns as an argument, so the whole comparison is testable without
;;;; a database.
;;;;
;;;; WHAT IS COMPARED, and what is not. Names, SQL types, NOT NULL and PRIMARY KEY are
;;;; compared. DEFAULTS ARE READ AND REPORTED BUT NEVER DIFFED -- Postgres rewrites a
;;;; default into its own normal form (`true`, `'x'::text`, `nextval(...)`), so comparing
;;;; the text would report drift on tables that are perfectly correct. A checker that cries
;;;; wolf gets ignored, and an ignored checker is worse than none.

(in-package #:mnemosyne/introspect)

;;; --- what the database says ------------------------------------------------

(defstruct (column (:constructor %make-column) (:copier nil))
  "One column as the DATABASE describes it -- not as a defschema wishes it were.

SQL-TYPE is the type the catalog reports, verbatim; comparison canonicalises it (see
%CANONICAL-TYPE) rather than storing a lossy translation, because the raw spelling is what
an operator needs to see in a drift report. DEFAULT is likewise raw, and is not diffed."
  (name (error "column name required") :type keyword)
  (sql-type "" :type string)
  (required nil)
  (primary nil)
  (default nil))

(defun %row-values (row)
  "The values of a result ROW (a plist) in SELECT order.

DELIBERATELY POSITIONAL, AND NOT TO BE CONVERTED TO MNEMOSYNE/PARAM:ROW-VALUE (#489).
Positional avoids the drivers' disagreement about column-name case by never naming a column,
and a catalog query is where that would bite -- but the stronger reason is the one visible in
the two callers below: they destructure `information_schema' rows as (name data-type
is-nullable default) and `pragma_table_info' rows as (name type notnull default pk). TWO
CATALOGS WITH DIFFERENT COLUMN NAMES, read into one shape. Keying this would mean writing
both vendors' spellings into the backend-neutral half of this file."
  (loop for tail on row by #'cddr collect (second tail)))

(defun %truthy (v)
  "Is V the driver's way of saying yes? Covers `1`/`t` (mnemosyne/param's boolean
vocabulary, #165), SQLite's integer flags, and Postgres' 'YES' text in information_schema."
  (typecase v
    (null nil)
    (integer (plusp v))
    (string (member v '("YES" "yes" "t" "true" "TRUE" "1") :test #'string=))
    (t t)))

(defun %kw (name)
  "A column name from the catalog as a keyword, lowercased -- the spelling DEFSCHEMA uses."
  (intern (string-upcase (string-trim " " (princ-to-string name))) :keyword))

(defun %pg-columns (connection table)
  (let ((pks (mapcar (lambda (row) (%kw (first (%row-values row))))
                     (conn:query connection
                                 "SELECT kcu.column_name FROM information_schema.table_constraints tc JOIN information_schema.key_column_usage kcu ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema WHERE tc.table_schema = current_schema() AND tc.table_name = ? AND tc.constraint_type = 'PRIMARY KEY'"
                                 table))))
    (mapcar (lambda (row)
              (destructuring-bind (name data-type is-nullable default) (%row-values row)
                (let ((kw (%kw name)))
                  (%make-column :name kw
                                :sql-type (princ-to-string data-type)
                                ;; information_schema says NULLABLE; we want its inverse.
                                :required (not (%truthy is-nullable))
                                :primary (and (member kw pks) t)
                                :default (and default (princ-to-string default))))))
            (conn:query connection
                        "SELECT column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = ? ORDER BY ordinal_position"
                        table))))

(defun %sqlite-columns (connection table)
  ;; pragma_table_info as a table-valued function, so the table name is a BOUND PARAM.
  ;; `PRAGMA table_info(x)` cannot take one, and interpolating an identifier into DDL-ish
  ;; SQL is the habit worth not having even when the name came from a defschema.
  (mapcar (lambda (row)
            (destructuring-bind (name type notnull default pk) (%row-values row)
              (%make-column :name (%kw name)
                            :sql-type (princ-to-string (or type ""))
                            :required (%truthy notnull)
                            ;; pk is 0, or the column's 1-based position in the key.
                            :primary (%truthy pk)
                            :default (and default (princ-to-string default)))))
          (conn:query connection
                      "SELECT name, type, \"notnull\", dflt_value, pk FROM pragma_table_info(?)"
                      table)))

(defun table-columns (backend connection table)
  "The COLUMNs of TABLE (a string) as CONNECTION's database actually has them, in
declaration order. An empty list means the table does not exist -- neither backend can
hold a table with no columns, so the two cases do not need telling apart.

BACKEND selects the catalog to ask, the same way MIGRATE takes one: `information_schema`
on Postgres, `pragma_table_info` on SQLite. XTDB 2 is schemaless and has no catalog to
read, which is the same seam SCHEMA-DDL already draws."
  (let ((name (be:backend-name backend)))
    (cond ((string= name "postgres") (%pg-columns connection table))
          ((string= name "sqlite") (%sqlite-columns connection table))
          (t (error "mnemosyne/introspect: no catalog reader for backend ~S" name)))))

(defun table-exists-p (backend connection table)
  "Does TABLE exist in CONNECTION's database?"
  (and (table-columns backend connection table) t))

;;; --- comparing a type across dialects --------------------------------------

(defparameter +sql-type-synonyms+
  '(("CHARACTER VARYING" . "VARCHAR")
    ("VARYING CHARACTER" . "VARCHAR")
    ("INT" . "INTEGER")
    ("INT4" . "INTEGER")
    ("INT8" . "BIGINT")
    ("FLOAT8" . "DOUBLE PRECISION")
    ("FLOAT4" . "REAL")
    ("TIMESTAMP WITH TIME ZONE" . "TIMESTAMPTZ")
    ("TIMESTAMP WITHOUT TIME ZONE" . "TIMESTAMP")
    ("BOOL" . "BOOLEAN"))
  "Spellings that name the SAME column type, mapped to one canonical token.

Only SPELLINGS. `INTEGER` and `BIGINT` stay distinct because they are distinct -- a table
whose id is int4 where the defschema asks for int8 has really drifted, and folding that
away to keep a report quiet would defeat the point of the report.")

(defun %collapse-spaces (s)
  (string-trim " "
               (with-output-to-string (out)
                 (let ((prev-space t))
                   (loop for ch across s
                         do (if (member ch '(#\Space #\Tab #\Newline))
                                (unless prev-space
                                  (write-char #\Space out)
                                  (setf prev-space t))
                                (progn (write-char ch out)
                                       (setf prev-space nil))))))))

(defparameter +parameterised-sql-types+ '("VECTOR")
  "SQL types whose parenthesised parameter is part of the type rather than a precision.

A VARCHAR(255) and a VARCHAR(80) hold the same kind of value and one can become the other.
A VECTOR(1536) and a VECTOR(768) cannot: pgvector refuses a value of the wrong width. So
the first is drift nobody should be told about and the second is drift somebody must be.")

(defun %canonical-type (s)
  "S (a SQL type as some catalog spells it) reduced to a comparable token: upcased,
whitespace collapsed, any `(n)` precision dropped, synonyms folded.

Precision is dropped because no dialect's catalog reports it the way the DDL wrote it, and
a `VARCHAR(255)` that reads back as `character varying` would otherwise be permanent,
unfixable drift.

EXCEPT WHERE THE PARENTHESES ARE THE TYPE (#212). `VECTOR(1536)` and `VECTOR(768)` are not
one type at two precisions: they are different columns, pgvector rejects an insert of the
wrong width, and no amount of ALTER will make one hold the other's data. Dropping the
number there would make a changed embedding dimension invisible to drift detection, which
is the one place it most needs to be visible -- a schema says 1536, the database says 768,
and every write fails for a reason the drift report did not mention.

So the rule is per type rather than global. A type in +PARAMETERISED-SQL-TYPES+ keeps its
parameter; everything else behaves exactly as before. The list is short on purpose: adding
to it is a claim that the number changes what the column can hold, not merely how much."
  (let* ((up (%collapse-spaces (string-upcase (or s ""))))
         (paren (position #\( up))
         (base (%collapse-spaces (if paren (subseq up 0 paren) up)))
         (folded (or (cdr (assoc base +sql-type-synonyms+ :test #'string=)) base)))
    (if (and paren (member folded +parameterised-sql-types+ :test #'string=))
        ;; Keep the parameter, with the whitespace normalised the same way the base is.
        (%collapse-spaces (remove #\Space (concatenate 'string folded (subseq up paren))))
        folded)))

(defun %expected-sql-type (field dialect)
  (mnemosyne/field-shell:column-sql (schema:field-type field) dialect
                                   :field-name (schema:field-name field)))

(defun %expected-required (field)
  "Is FIELD NOT NULL as SCHEMA-DDL would write it? A primary key is, implicitly, which is
why SCHEMA's %COLUMN-DDL omits the redundant NOT NULL and why comparing the flag alone
would report drift on every table with a text primary key on SQLite."
  (and (or (schema:field-required field) (schema:field-primary field)) t))

(defun %column-required (column)
  (and (or (column-required column) (column-primary column)) t))

;;; --- the difference, as data -----------------------------------------------

(defstruct (drift (:constructor %make-drift) (:copier nil) (:predicate nil))
  "How a live table differs from its DEFSCHEMA. Data, not a message: an app may report it,
assert on it, or hand it to DRIFT-DDL.

  TABLE-PRESENT  NIL when the table does not exist at all -- a different problem from a
                 table that is merely out of date, and the one case where every field
                 shows up as missing for an uninteresting reason.
  MISSING        schema FIELDs with no column in the table. The common case: a column was
                 added to the defschema and no migration was written.
  EXTRA          COLUMNs in the table with no field in the schema. Also common, and often
                 CORRECT -- an ALTER migration whose defschema was deliberately left
                 alone is exactly this shape, which is the state #144 describes.
  MISMATCHED     a list of (FIELD . COLUMN) that share a name and disagree about type,
                 NOT NULL, or PRIMARY KEY.

The predicate is suppressed: `drift-p` would read as \"has this table drifted?\" and mean
\"is this object a drift?\". DRIFT-CLEAN-P is the question worth asking."
  (table "" :type string)
  (schema-name nil)
  (dialect "" :type string)
  (table-present t)
  (missing nil :type list)
  (extra nil :type list)
  (mismatched nil :type list))

(defun drift-clean-p (drift)
  "Does the table match its schema? True only when the table exists and nothing is missing,
extra, or mismatched."
  (and (drift-table-present drift)
       (null (drift-missing drift))
       (null (drift-extra drift))
       (null (drift-mismatched drift))))

(defun %mismatch-reasons (field column dialect)
  "The ways FIELD and COLUMN disagree, as a list of human-readable strings. Empty when they
agree. Defaults are deliberately not among them -- see the file header."
  (let ((reasons '())
        (want (%canonical-type (%expected-sql-type field dialect)))
        (got (%canonical-type (column-sql-type column))))
    (unless (string= want got)
      (push (format nil "type: schema says ~A, table has ~A" want (column-sql-type column))
            reasons))
    (unless (eq (%expected-required field) (%column-required column))
      (push (format nil "nullability: schema says ~:[NULL~;NOT NULL~], table is ~:[NULL~;NOT NULL~]"
                    (%expected-required field) (%column-required column))
            reasons))
    (unless (eq (and (schema:field-primary field) t) (and (column-primary column) t))
      (push (format nil "primary key: schema says ~:[no~;yes~], table says ~:[no~;yes~]"
                    (schema:field-primary field) (column-primary column))
            reasons))
    (nreverse reasons)))

(defun schema-diff (schema columns &key (dialect "postgres"))
  "Compare SCHEMA (a mnemosyne/schema SCHEMA) against COLUMNS (what TABLE-COLUMNS returned)
and return a DRIFT. Pure -- no database, so the whole comparison is testable offline.

DIALECT is a backend designator, and it matters: the SQL type a field expects is
dialect-dependent (`:uuid` is UUID on Postgres and TEXT on SQLite), so diffing a SQLite
table against Postgres expectations would report drift in every row. An unrecognised one
signals MNEMOSYNE/FIELD-SHELL:UNKNOWN-DIALECT here rather than being carried into the report
as a backend name nobody checked (#432, ADR-0003)."
  ;; NORMALISED ONCE, and rendered back to its canonical spelling for the DRIFT slot, which
  ;; is declared `:type string' and is read by the reporting functions (#432, ADR-0003).
  ;; A designator that reaches DRIFT unchecked is a dialect name nobody verified, printed in
  ;; a report an operator is meant to act on.
  (let ((dialect (fldsh:dialect-name-of dialect))
        (missing '()) (extra '()) (mismatched '()))
    (dolist (f (schema:schema-fields schema))
      (let ((c (find (schema:field-name f) columns :key #'column-name)))
        (cond ((null c) (push f missing))
              ((%mismatch-reasons f c dialect) (push (cons f c) mismatched)))))
    (dolist (c columns)
      (unless (find (column-name c) (schema:schema-fields schema) :key #'schema:field-name)
        (push c extra)))
    (%make-drift :table (schema:schema-table schema)
                 :schema-name (schema:schema-name schema)
                 :dialect dialect
                 :table-present (and columns t)
                 :missing (nreverse missing)
                 :extra (nreverse extra)
                 :mismatched (nreverse mismatched))))

(defun diff-table (backend connection schema)
  "TABLE-COLUMNS then SCHEMA-DIFF: how SCHEMA's table in CONNECTION's database differs from
the definition. The dialect is taken from BACKEND, so it cannot be got wrong."
  (let ((dialect (be:backend-name backend)))
    (schema-diff schema
                 (table-columns backend connection (schema:schema-table schema))
                 :dialect dialect)))

;;; --- reporting -------------------------------------------------------------

(defun report-drift (drift &optional (stream *standard-output*))
  "Print DRIFT in a form an operator can act on. Returns DRIFT."
  (cond
    ((not (drift-table-present drift))
     (format stream "~&schema ~A: table ~A DOES NOT EXIST -- migrations have not been run, or they create a different table.~%"
             (drift-schema-name drift) (drift-table drift)))
    ((drift-clean-p drift)
     (format stream "~&schema ~A: table ~A matches (~A).~%"
             (drift-schema-name drift) (drift-table drift) (drift-dialect drift)))
    (t
     (format stream "~&schema ~A vs table ~A (~A):~%"
             (drift-schema-name drift) (drift-table drift) (drift-dialect drift))
     (dolist (f (drift-missing drift))
       (format stream "  MISSING in the table: ~A ~A -- in the defschema, never migrated.~%"
               (schema:field-name f)
               (%expected-sql-type f (drift-dialect drift))))
     (dolist (c (drift-extra drift))
       (format stream "  EXTRA in the table:   ~A ~A -- migrated, but not in the defschema.~%"
               (column-name c) (column-sql-type c)))
     (dolist (pair (drift-mismatched drift))
       (format stream "  DIFFERS: ~A~%" (schema:field-name (car pair)))
       (dolist (r (%mismatch-reasons (car pair) (cdr pair) (drift-dialect drift)))
         (format stream "    - ~A~%" r)))))
  (finish-output stream)
  drift)

(define-condition schema-drift (error)
  ((drift :initarg :drift :reader schema-drift-drift))
  (:report (lambda (c s)
             (format s "mnemosyne/introspect: table ~A no longer matches schema ~A.~%~A"
                     (drift-table (schema-drift-drift c))
                     (drift-schema-name (schema-drift-drift c))
                     (with-output-to-string (out)
                       (report-drift (schema-drift-drift c) out)))))
  (:documentation
   "Signalled by VERIFY-SCHEMA when the live table has stopped matching its DEFSCHEMA.

An error rather than a warning, and with a CONTINUE restart rather than without one: the
divergence is usually a missing migration, which is worth stopping a boot for, but an app
that has deliberately let the two differ -- the survivable option in #144 -- needs a way
to say so that is a decision in the code and not a muffled warning nobody reads."))

(defun verify-schema (backend connection schema &key (allow-extra nil))
  "Assert that SCHEMA's table in CONNECTION's database matches the definition. Returns the
DRIFT when it does; signals SCHEMA-DRIFT (with a CONTINUE restart) when it does not.

Call it after MIGRATE, from an app's bring-up or from its test suite: replaying history
must arrive at the present, and this is the assertion that says so.

ALLOW-EXTRA tolerates columns the table has and the defschema does not. That is the exact
shape of the #144 workaround -- an ALTER migration whose defschema was deliberately left
alone -- and an app that has chosen it should be able to keep the rest of the check rather
than turn the whole thing off. Missing and mismatched columns still signal."
  (let* ((drift (diff-table backend connection schema))
         (ok (if allow-extra
                 (and (drift-table-present drift)
                      (null (drift-missing drift))
                      (null (drift-mismatched drift)))
                 (drift-clean-p drift))))
    (if ok
        drift
        (restart-case (error 'schema-drift :drift drift)
          (continue ()
            :report "Proceed despite the drift."
            drift)))))

;;; --- from a difference back to DDL -----------------------------------------

(defun drift-ddl (drift &key (include-drops nil))
  "The mnemosyne/ddl forms that would reconcile the table with the schema, as DATA -- feed
them to DDL:DDL-STATEMENTS for SQL. Returns NIL when there is nothing to do.

This is the half that makes the model work. You edit the defschema (the present), ask what
it would take to get there, and paste the result into a NEW migration under a NEW id. The
already-applied migration is never touched, so history keeps meaning what it meant, and the
ALTER was still derived from the schema rather than written twice.

Three deliberate refusals:

- MISMATCHED columns generate NOTHING. Changing a column's type is a table rebuild on
  SQLite and a data-losing decision on Postgres; emitting a plausible ALTER for it would
  be guessing on the author's behalf about their data. They are in the drift; write it.
- EXTRA columns generate a DROP only under INCLUDE-DROPS. The default is off because the
  overwhelmingly common cause of an extra column is #144's own workaround -- correct data
  that the defschema does not mention -- and defaulting to `DROP COLUMN` would turn a
  documentation problem into a destructive one.
- A missing table generates nothing: that is SCHEMA:SCHEMA-DDL's job, not an ALTER.

One hazard the generated SQL cannot fix for you: `ADD COLUMN ... NOT NULL` with no DEFAULT
fails on a table that already has rows. If the field is required, add it nullable, backfill,
then set NOT NULL -- three statements, and only you know what to backfill with."
  (let ((actions '()))
    (when (drift-table-present drift)
      (dolist (f (drift-missing drift))
        (push (append (list :add-column
                            (schema:field-name f)
                            (schema:field-type-name f))
                      (when (schema:field-required f) (list :required t))
                      ;; Carried through even though ADD COLUMN ... PRIMARY KEY fails on a
                      ;; table that already has one. Dropping it silently would emit a
                      ;; column that LOOKS like the schema and is not the key -- a wrong
                      ;; answer beats a loud one only if you never read the loud one.
                      (when (schema:field-primary f) (list :primary t))
                      (when (schema:field-default f)
                        (list :default (schema:field-default f))))
              actions))
      (when include-drops
        (dolist (c (drift-extra drift))
          (push (list :drop-column (column-name c)) actions))))
    (when actions
      ;; The table name goes through as a STRING: DDL's %IDENT passes strings verbatim
      ;; and downcases symbols, so a mixed-case table would not survive as a keyword.
      (list (list* :alter-table (drift-table drift) (nreverse actions))))))
