;;;; ddl.lisp --- DDL as data: CREATE INDEX / DROP / ALTER TABLE, rendered per dialect.
;;;;
;;;; The query DSL is DML-only, so migrations had to hand-write every CREATE INDEX, DROP
;;;; TABLE and ALTER TABLE as a raw SQL string -- the concrete reason a migration list
;;;; could not be fully generated from CL. This module closes that gap the same way the
;;;; DML side works: a statement is DATA (a plist whose first key names the operation),
;;;; rendered to SQL for a dialect. SCHEMA-DDL's CREATE TABLE becomes one case among many.
;;;;
;;;; Generation is OPTIONAL and additive. MAKE-MIGRATION still takes raw up/down SQL
;;;; strings, and always will: raw SQL is the escape hatch for vendor-specific DDL and for
;;;; anything the generator does not cover. A migration may mix generated forms and
;;;; hand-written strings freely.
;;;;
;;;; Dialects differ in ways that matter, and this is where the work actually is: SQLite's
;;;; ALTER TABLE understands only ADD/DROP/RENAME COLUMN and RENAME TO -- no DROP
;;;; CONSTRAINT, no ALTER COLUMN (both need the table-rebuild dance) -- and it has no
;;;; CASCADE. Rather than emit SQL the backend will reject at runtime, an unsupported
;;;; combination signals UNSUPPORTED-DDL at render time, naming the dialect and the
;;;; operation. XTDB 2 is schemaless and has no DDL at all -- the same seam SCHEMA-DDL
;;;; already draws.
;;;;
;;;; No IO here: these are pure string builders. Running them is CONN:EXEC's job.

(in-package #:mnemosyne/ddl)

(define-condition unsupported-ddl (error)
  ((dialect   :initarg :dialect   :reader unsupported-ddl-dialect)
   (operation :initarg :operation :reader unsupported-ddl-operation)
   (detail    :initarg :detail    :initform nil :reader unsupported-ddl-detail))
  (:report (lambda (c s)
             (format s "mnemosyne/ddl: ~A does not support ~A~@[ -- ~A~]"
                     (unsupported-ddl-dialect c)
                     (unsupported-ddl-operation c)
                     (unsupported-ddl-detail c))))
  (:documentation
   "Signalled when a DDL form cannot be expressed in the target dialect -- caught at render
time, with a restart-able condition, rather than as a driver error at migration time."))

(defun %ident (x)
  "Render X (keyword/symbol/string) as a SQL identifier -- the same convention as the query
DSL: a keyword or symbol is an identifier, a string passes through."
  (typecase x
    (string x)
    (symbol (string-downcase (symbol-name x)))
    (t (princ-to-string x))))

;;; --- the dialect ------------------------------------------------------------
;;; ONE VOCABULARY (pre-publication issue 432, ADR-0003). This module used to normalise with its own
;;; `%dialect-name': downcase a string, a symbol-name or a PRINC of anything else, then
;;; compare the result with STRING=. Two things followed, and both were defects rather than
;;; looseness:
;;;
;;;   * `%sqlite-p' was a TWO-WAY test whose else-arm meant Postgres, so an unrecognised
;;;     spelling was not refused -- it was rendered. `(ddl '(:drop-table :name :users
;;;     :cascade t) :dialect "sqlrite")' returned "DROP TABLE IF EXISTS users CASCADE",
;;;     which is valid Postgres and a syntax error on the SQLite the caller meant.
;;;   * `%check-not-xtdb' was the same shape, so a typo also skipped the XTDB guard.
;;;
;;; The typo case had no upper bound on how wrong it could be, because PRINC-TO-STRING gave
;;; every object a dialect name. Now the entry points normalise once through the tree-wide
;;; normaliser and everything below branches on a checked, typed value.

(defun %check-not-xtdb (dialect operation)
  "DIALECT is a typed MNEMOSYNE/FIELD:DIALECT -- normalised by DDL / DDL-STATEMENTS."
  (when (eq dialect fld:D-Xtdb)
    (error 'unsupported-ddl :dialect "xtdb" :operation operation
                            :detail "XTDB 2 is schemaless -- it has no DDL. See docs/xtdb-notes.md")))

(defun %sqlite-p (dialect) (eq dialect fld:D-Sqlite))

;;; --- indexes ---------------------------------------------------------------

(defparameter +index-methods+ '(:btree :hash :gin :gist :brin :spgist :hnsw :ivfflat)
  "Index methods :USING accepts. HNSW and IVFFLAT come from pgvector (pre-publication issue 258).

A CLOSED LIST rather than a passthrough, for the reason the dialect became one (ADR-0001):
a string whose only legal values are a known set is a closed type wearing an open one, and
a typo would otherwise reach Postgres as a syntax error naming a line rather than a method.")

(defparameter +vector-opclasses+ '(:vector_l2_ops :vector_cosine_ops :vector_ip_ops)
  "pgvector's operator classes, one per distance operator.

WHICH ONE YOU CHOOSE DECIDES WHICH QUERIES THE INDEX SERVES. An index built with
vector_l2_ops does not serve a `<=>' query -- Postgres does not error, it sequentially
scans. See MNEMOSYNE/QUERY:+VECTOR-DISTANCE-OPS+ for the pairing.")

(defun %create-index (form dialect)
  (destructuring-bind (&key name on columns unique (if-not-exists t) where using opclass
                            with)
      form
    (%check-not-xtdb dialect "CREATE INDEX")
    (unless (and name on columns)
      (error "mnemosyne/ddl: :create-index needs :name, :on and :columns -- got ~S" form))
    (when (and using (not (member using +index-methods+)))
      (error "mnemosyne/ddl: unknown index method ~S (one of ~{:~(~A~)~^, ~})"
             using +index-methods+))
    (when (and opclass (not using))
      ;; An operator class without a method is almost always a vector index missing its
      ;; :USING, and the resulting SQL would be a btree over a vector -- accepted by
      ;; Postgres and useless for distance.
      (error "mnemosyne/ddl: :opclass ~S needs a :using -- an operator class belongs to an index method." opclass))
    (when (and (member using '(:hnsw :ivfflat)) (null opclass))
      ;; REFUSED RATHER THAN DEFAULTED. pgvector will happily build an index with its own
      ;; default operator class, and a reader of the DDL then cannot tell which distance
      ;; operator it serves -- which is the one thing about a vector index worth knowing.
      (error "mnemosyne/ddl: a ~(~A~) index needs an explicit :opclass (one of ~{:~(~A~)~^, ~}).~%It decides which distance operator the index serves, and defaulting it hides that."
             using +vector-opclasses+))
    (when (and opclass (member using '(:hnsw :ivfflat))
               (not (member opclass +vector-opclasses+)))
      (error "mnemosyne/ddl: unknown vector operator class ~S (one of ~{:~(~A~)~^, ~})"
             opclass +vector-opclasses+))
    (format nil "CREATE ~:[~;UNIQUE ~]INDEX ~:[~;IF NOT EXISTS ~]~A ON ~A~@[ USING ~A~] (~{~A~^, ~})~@[ WITH (~A)~]~@[ WHERE ~A~]"
            unique if-not-exists (%ident name) (%ident on)
            (and using (string-downcase (symbol-name using)))
            (let ((cols (mapcar #'%ident (if (listp columns) columns (list columns)))))
              (if opclass
                  (cons (format nil "~A ~(~A~)" (first cols) opclass) (rest cols))
                  cols))
            (and with (%index-with with))
            where)))

(defun %index-with (with)
  "Render an index's WITH options: a plist, rendered as `key = value'.

IVFFlat needs `lists', HNSW takes `m' and `ef_construction', and the right values depend on
the corpus rather than on us -- so this renders what the caller asked for rather than
choosing. IVFFlat also has an ORDERING CONSTRAINT this cannot enforce: it must be built
AFTER the table holds representative data, because it clusters what is there. Building it
on an empty table produces an index that works and retrieves badly, which is a migration
fact rather than a schema one (pre-publication issue 258)."
  (format nil "~{~A~^, ~}"
          (loop for (k v) on with by #'cddr
                collect (format nil "~(~A~) = ~A" k v))))

(defun %drop-index (form dialect)
  (destructuring-bind (&key name on (if-exists t)) form
    ;; Postgres and SQLite both drop an index by its own name; :on is accepted and ignored
    ;; so a caller can keep the pair together for readability next to :create-index.
    (declare (ignorable on))
    (%check-not-xtdb dialect "DROP INDEX")
    (unless name (error "mnemosyne/ddl: :drop-index needs :name -- got ~S" form))
    (format nil "DROP INDEX ~:[~;IF EXISTS ~]~A" if-exists (%ident name))))

;;; --- tables ----------------------------------------------------------------

(defun %drop-table (form dialect)
  (destructuring-bind (&key name (if-exists t) cascade) form
    (%check-not-xtdb dialect "DROP TABLE")
    (unless name (error "mnemosyne/ddl: :drop-table needs :name -- got ~S" form))
    (when (and cascade (%sqlite-p dialect))
      (error 'unsupported-ddl :dialect "sqlite" :operation "DROP TABLE ... CASCADE"
                              :detail "SQLite has no CASCADE; drop dependents explicitly"))
    (format nil "DROP TABLE ~:[~;IF EXISTS ~]~A~:[~; CASCADE~]"
            if-exists (%ident name) cascade)))

;;; --- alter table -----------------------------------------------------------
;;; Each action is its own little form so a caller can express several in one migration
;;; step; SQL requires them as separate statements on SQLite anyway, so ALTER-TABLE returns
;;; a LIST of statements and DDL joins them.

(defun %column-spec (spec dialect)
  "A column definition inside ADD COLUMN: (name type &key required default primary).

TYPE is a schema field-type keyword (:string, :uuid, ...), converted here to the typed
Coalton vocabulary the same way DEFSCHEMA does -- FIELD-TYPE-SQL takes the Coalton value,
not the keyword, and handing it a raw keyword fails as a non-exhaustive pattern match
rather than a readable error."
  (destructuring-bind (name type &key required default primary dimensions) spec
    (let ((tn (string-downcase (symbol-name type))))
      (unless (member tn mnemosyne/schema::+field-type-names+ :test #'string=)
        (error "mnemosyne/ddl: unknown field type ~S (one of ~{~A~^, ~})"
               type mnemosyne/schema::+field-type-names+))
      (format nil "~A ~A~:[~; PRIMARY KEY~]~:[~; NOT NULL~]~@[ DEFAULT ~A~]"
              (%ident name)
              ;; Through the same builder MAKE-FIELD uses, so an :add-column naming a
              ;; parameterised type gets the parameter (pre-publication issue 212). Calling FIELD-TYPE-FROM with
              ;; the bare name here would have produced a dimension-less vector and, before
              ;; that type existed, would silently have produced a TEXT column.
              (mnemosyne/field-shell:column-sql
               (mnemosyne/schema:field-type-for tn (list :dimensions dimensions)
                                                :field-name name
                                                :context "mnemosyne/ddl")
               dialect
               :field-name name)
              primary
              (and required (not primary))
              (mnemosyne/schema::%default-sql default)))))

(defun %alter-action (table action dialect)
  (let ((op (first action)))
    (ecase op
      (:add-column
       (format nil "ALTER TABLE ~A ADD COLUMN ~A"
               (%ident table) (%column-spec (rest action) dialect)))
      (:drop-column
       (format nil "ALTER TABLE ~A DROP COLUMN ~A"
               (%ident table) (%ident (second action))))
      (:rename-column
       (format nil "ALTER TABLE ~A RENAME COLUMN ~A TO ~A"
               (%ident table) (%ident (second action)) (%ident (third action))))
      (:rename-to
       (format nil "ALTER TABLE ~A RENAME TO ~A"
               (%ident table) (%ident (second action))))
      (:add-constraint
       ;; (:add-constraint name "CHECK (...)" ) -- the body stays raw SQL on purpose:
       ;; constraint expressions are the long tail, and inventing a DSL for them here
       ;; would cover less than the escape hatch already does.
       (format nil "ALTER TABLE ~A ADD CONSTRAINT ~A ~A"
               (%ident table) (%ident (second action)) (third action)))
      (:drop-constraint
       (when (%sqlite-p dialect)
         (error 'unsupported-ddl :dialect "sqlite" :operation "ALTER TABLE ... DROP CONSTRAINT"
                                 :detail "SQLite needs a table rebuild (create new, copy, drop, rename)"))
       (format nil "ALTER TABLE ~A DROP CONSTRAINT ~A"
               (%ident table) (%ident (second action)))))))

(defun %alter-table (form dialect)
  "FORM is (:alter-table TABLE action...); returns a list of statements."
  (%check-not-xtdb dialect "ALTER TABLE")
  (let ((table (second form))
        (actions (cddr form)))
    (unless (and table actions)
      (error "mnemosyne/ddl: :alter-table needs a table and at least one action -- got ~S" form))
    (mapcar (lambda (a) (%alter-action table a dialect)) actions)))

;;; --- the entry point -------------------------------------------------------

(defun ddl (form &key (dialect "postgres"))
  "Render a DDL FORM (data) to a SQL string for DIALECT.

    (ddl '(:create-index :name :idx_users_email :on :users :columns (:email) :unique t))
    ;; => \"CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email ON users (email)\"

    (ddl '(:alter-table :users (:add-column :nickname :text)
                               (:rename-column :bio :about)))
    ;; => two statements, separated by \";\\n\"

    (ddl '(:drop-table :name :widgets))

Forms: :create-index (:name :on :columns :unique :if-not-exists :where), :drop-index
\(:name :if-exists), :drop-table (:name :if-exists :cascade), :create-extension (:name
:if-not-exists), :alter-table (table + actions :add-column / :drop-column / :rename-column /
:rename-to / :add-constraint / :drop-constraint).

DIALECT is a designator -- \"postgres\", :postgres or a typed MNEMOSYNE/FIELD:DIALECT -- and
is normalised here; an unrecognised spelling signals MNEMOSYNE/FIELD-SHELL:UNKNOWN-DIALECT
rather than rendering the Postgres form of the statement (pre-publication issue 432, ADR-0003).

Signals UNSUPPORTED-DDL when the dialect cannot express the form (SQLite CASCADE or DROP
CONSTRAINT; anything at all on XTDB 2) -- at render time, where a migration author can see
it, rather than as a driver error mid-migration."
  (unless (consp form)
    (error "mnemosyne/ddl: a DDL form is a list -- got ~S" form))
  ;; NORMALISED ONCE, HERE (pre-publication issue 432). Every branch below compares a typed value, so there is no
  ;; arm that an unrecognised spelling can reach by not matching the other one.
  (setf dialect (fldsh:dialect-for dialect))
  (let ((op (first form)))
    (case op
      (:create-index (%create-index (rest form) dialect))
      (:create-extension (%create-extension (rest form) dialect))
      (:drop-index   (%drop-index (rest form) dialect))
      (:drop-table   (%drop-table (rest form) dialect))
      (:alter-table  (format nil "~{~A~^;~%~}" (%alter-table form dialect)))
      (t (error "mnemosyne/ddl: unknown DDL operation ~S in ~S" op form)))))

(defun %create-extension (args dialect)
  "(:create-extension :name :vector [:if-not-exists nil]) for DIALECT.

AN EXTENSION IS A DEPLOYMENT FACT AND A MIGRATION HAS TO STATE IT (pre-publication issue 258). `CREATE EXTENSION'
is privileged and is not available on every managed Postgres -- it is on RDS, Cloud SQL and
DigitalOcean's managed databases, and on a bare install the extension package has to be on
the host. A migration that assumes it fails as whatever Postgres says about an unknown TYPE,
which names neither the extension nor the privilege; declaring it names both, and
MNEMOSYNE/MIGRATE:REQUIRE-EXTENSION checks it before a migration runs.

REFUSED RATHER THAN IGNORED on a dialect with no such concept. SQLite has loadable
extensions but no CREATE EXTENSION, and emitting nothing would be the silent degradation
mnemosyne/docs/adr/0001 rejected: a vector column on SQLite is accepted as TEXT and searches
nothing, so the extension statement quietly succeeding is the same defect one statement
earlier."
  (destructuring-bind (&key name (if-not-exists t)) args
    (unless name
      (error "mnemosyne/ddl: :create-extension needs a :name"))
    (%check-not-xtdb dialect "CREATE EXTENSION")
    (when (%sqlite-p dialect)
      (error 'unsupported-ddl
             :dialect "sqlite" :operation "CREATE EXTENSION"
             :detail (format nil "SQLite has no extension registry; `~A' is a Postgres extension and this schema needs a Postgres backend"
                             (%ident name))))
    (format nil "CREATE EXTENSION ~:[~;IF NOT EXISTS ~]~A" if-not-exists (%ident name))))

(defun ddl-statements (form &key (dialect "postgres"))
  "Like DDL but always returns a LIST of statements -- what you want when feeding CONN:EXEC,
which takes one statement at a time. An :alter-table with three actions yields three."
  (if (eq (first form) :alter-table)
      ;; %ALTER-TABLE is below the entry point, so it is reached here without passing
      ;; through DDL -- normalise on this path too, or the one form that bypasses DDL is
      ;; the one form with no check (pre-publication issue 432).
      (%alter-table form (fldsh:dialect-for dialect))
      (list (ddl form :dialect dialect))))
