;;;; tests/ddl.lisp --- DDL as data: rendering, and the dialect differences.
;;;;
;;;; The rendering is the easy half. The half worth testing is where dialects disagree --
;;;; SQLite's missing CASCADE and DROP CONSTRAINT, XTDB's absence of DDL entirely -- because
;;;; the whole point of signalling at render time is that a migration author sees the
;;;; problem before it reaches a driver mid-migration.

(in-package #:mnemosyne/tests)

(in-suite mnemosyne)

;;; --- indexes ---------------------------------------------------------------

(test ddl-create-index
  (is (string= "CREATE INDEX IF NOT EXISTS idx_users_email ON users (email)"
               (ddl:ddl '(:create-index :name :idx_users_email :on :users :columns (:email)))))
  (is (string= "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email ON users (email)"
               (ddl:ddl '(:create-index :name :idx_users_email :on :users
                          :columns (:email) :unique t))))
  ;; multi-column, and IF NOT EXISTS opt-out
  (is (string= "CREATE INDEX idx_a ON t (a, b)"
               (ddl:ddl '(:create-index :name :idx_a :on :t :columns (:a :b)
                          :if-not-exists nil))))
  ;; a single column need not be a list
  (is (search "(email)" (ddl:ddl '(:create-index :name :i :on :users :columns :email))))
  ;; partial index
  (is (search "WHERE deleted_at IS NULL"
              (ddl:ddl '(:create-index :name :i :on :users :columns (:email)
                         :where "deleted_at IS NULL")))))

(test ddl-create-index-requires-its-parts
  (signals error (ddl:ddl '(:create-index :name :i :on :users)))       ; no columns
  (signals error (ddl:ddl '(:create-index :on :users :columns (:a))))) ; no name

(test ddl-drop-index
  (is (string= "DROP INDEX IF EXISTS idx_a" (ddl:ddl '(:drop-index :name :idx_a))))
  (is (string= "DROP INDEX idx_a" (ddl:ddl '(:drop-index :name :idx_a :if-exists nil)))))

;;; --- tables ----------------------------------------------------------------

(test ddl-drop-table
  (is (string= "DROP TABLE IF EXISTS widgets" (ddl:ddl '(:drop-table :name :widgets))))
  (is (string= "DROP TABLE widgets" (ddl:ddl '(:drop-table :name :widgets :if-exists nil))))
  (is (string= "DROP TABLE IF EXISTS widgets CASCADE"
               (ddl:ddl '(:drop-table :name :widgets :cascade t) :dialect "postgres"))))

;;; --- alter table -----------------------------------------------------------

(test ddl-alter-table-actions
  ;; Types render per dialect through the same Coalton vocabulary schema-ddl uses:
  ;; :string -> TEXT, :integer -> BIGINT on postgres (INTEGER on sqlite).
  (is (string= "ALTER TABLE users ADD COLUMN nickname TEXT"
               (ddl:ddl '(:alter-table :users (:add-column :nickname :string)))))
  (is (search "ADD COLUMN age BIGINT NOT NULL DEFAULT 0"
              (ddl:ddl '(:alter-table :users
                         (:add-column :age :integer :required t :default 0)))))
  (is (search "ADD COLUMN age INTEGER"
              (ddl:ddl '(:alter-table :users (:add-column :age :integer))
                       :dialect "sqlite")))
  ;; an unknown field type is caught here, not at the driver
  (signals error (ddl:ddl '(:alter-table :users (:add-column :x :not-a-type))))
  (is (string= "ALTER TABLE users DROP COLUMN bio"
               (ddl:ddl '(:alter-table :users (:drop-column :bio)))))
  (is (string= "ALTER TABLE users RENAME COLUMN bio TO about"
               (ddl:ddl '(:alter-table :users (:rename-column :bio :about)))))
  (is (string= "ALTER TABLE users RENAME TO accounts"
               (ddl:ddl '(:alter-table :users (:rename-to :accounts)))))
  (is (search "ADD CONSTRAINT age_positive CHECK (age >= 0)"
              (ddl:ddl '(:alter-table :users
                         (:add-constraint :age_positive "CHECK (age >= 0)"))))))

(test ddl-alter-table-multiple-actions-are-separate-statements
  ;; SQL requires them separately on SQLite, so the list form is the honest one.
  (let ((stmts (ddl:ddl-statements '(:alter-table :users
                                     (:add-column :nickname :string)
                                     (:rename-column :bio :about)))))
    (is (= 2 (length stmts)))
    (is (search "ADD COLUMN nickname" (first stmts)))
    (is (search "RENAME COLUMN bio" (second stmts))))
  ;; DDL joins them for display/inspection
  (is (search ";" (ddl:ddl '(:alter-table :users (:add-column :a :string)
                                                 (:drop-column :b)))))
  ;; a non-alter form still comes back as a one-element list
  (is (= 1 (length (ddl:ddl-statements '(:drop-table :name :t))))))

;;; --- dialect differences (the part that matters) ---------------------------

(test sqlite-rejects-what-it-cannot-do
  ;; Signalled at RENDER time, so a migration author sees it -- not as a driver error
  ;; halfway through a migration run.
  (signals ddl:unsupported-ddl
    (ddl:ddl '(:drop-table :name :t :cascade t) :dialect "sqlite"))
  (signals ddl:unsupported-ddl
    (ddl:ddl '(:alter-table :users (:drop-constraint :chk)) :dialect "sqlite"))
  ;; ...but what SQLite *can* do still renders
  (is (search "ADD COLUMN" (ddl:ddl '(:alter-table :users (:add-column :a :string))
                                    :dialect "sqlite")))
  (is (search "DROP TABLE" (ddl:ddl '(:drop-table :name :t) :dialect "sqlite"))))

(test xtdb-has-no-ddl-at-all
  ;; Same seam schema-ddl already draws: XTDB 2 is schemaless.
  (dolist (form '((:create-index :name :i :on :t :columns (:a))
                  (:drop-index :name :i)
                  (:drop-table :name :t)
                  (:alter-table :t (:add-column :a :string))))
    (signals ddl:unsupported-ddl (ddl:ddl form :dialect "xtdb"))))

(test unsupported-ddl-says-which-dialect-and-what
  (handler-case (ddl:ddl '(:drop-table :name :t :cascade t) :dialect "sqlite")
    (ddl:unsupported-ddl (c)
      (is (string= "sqlite" (ddl:unsupported-ddl-dialect c)))
      (is (search "CASCADE" (ddl:unsupported-ddl-operation c)))
      (is (stringp (princ-to-string c))))))

(test ddl-rejects-nonsense
  (signals error (ddl:ddl '(:vacuum-the-galaxy)))
  (signals error (ddl:ddl :not-a-form)))

;;; --- generated DDL is usable as a migration's up/down ----------------------

(test generated-ddl-runs-against-sqlite
  ;; The point of the whole module: a migration can be built from forms instead of strings.
  (let ((c (conn:connect (be:make-sqlite ":memory:"))))
    (unwind-protect
         (progn
           (conn:exec c "CREATE TABLE users (id TEXT PRIMARY KEY, email TEXT)")
           (dolist (stmt (ddl:ddl-statements
                          '(:create-index :name :idx_users_email :on :users
                            :columns (:email) :unique t)
                          :dialect "sqlite"))
             (conn:exec c stmt))
           (dolist (stmt (ddl:ddl-statements
                          '(:alter-table :users (:add-column :nickname :string))
                          :dialect "sqlite"))
             (conn:exec c stmt))
           ;; the new column really exists
           (conn:exec c "INSERT INTO users (id, email, nickname) VALUES (?, ?, ?)"
                      "u1" "a@x.io" "ace")
           (is (= 1 (length (conn:query c "SELECT nickname FROM users"))))
           ;; and the unique index really constrains
           (signals conn:db-error
             (conn:exec c "INSERT INTO users (id, email) VALUES (?, ?)" "u2" "a@x.io"))
           ;; down-migration direction works too
           (dolist (stmt (ddl:ddl-statements '(:drop-index :name :idx_users_email)
                                             :dialect "sqlite"))
             (conn:exec c stmt)))
      (conn:disconnect c))))

;;; --- first-run bring-up: the SQLite parent directory -----------------------

(test connect-creates-a-missing-parent-directory
  ;; SQLite creates the file but never the folder, so "./data/app.db" failed a first run
  ;; with a bare "unable to open database file". Reported from a consuming app.
  (let* ((root (merge-pathnames (format nil "mnemo-ddl-test-~D/" (get-universal-time))
                                (uiop:temporary-directory)))
         (db (namestring (merge-pathnames "nested/deeper/app.db" root))))
    (unwind-protect
         (progn
           (is (not (uiop:directory-exists-p (merge-pathnames "nested/deeper/" root))))
           (let ((c (conn:connect (be:make-sqlite db))))
             (unwind-protect
                  (progn
                    (is (uiop:file-exists-p db))
                    (conn:exec c "CREATE TABLE t (a TEXT)")
                    (is (= 0 (length (conn:query c "SELECT * FROM t")))))
               (conn:disconnect c))))
      (ignore-errors (uiop:delete-directory-tree root :validate t)))))

(test in-memory-and-empty-paths-are-left-alone
  ;; ":memory:" and "" are not paths -- creating a directory for them would be nonsense.
  (dolist (path '(":memory:" ""))
    (let ((c (conn:connect (be:make-sqlite path))))
      (unwind-protect (is (not (null c)))
        (conn:disconnect c))))
  (is (not (uiop:directory-exists-p ":memory:"))))

;;; --- vector index kinds (#258) ---------------------------------------------

(test a-vector-index-names-its-method-and-its-operator-class
  (let ((sql (ddl:ddl '(:create-index :name :idx_e :on :docs :columns (:embedding)
                        :using :hnsw :opclass :vector_cosine_ops)
                      :dialect "postgres")))
    (is (search "USING hnsw" sql) "got: ~A" sql)
    (is (search "(embedding vector_cosine_ops)" sql)
        "the operator class belongs to the column, got: ~A" sql)))

(test an-ivfflat-index-carries-its-list-count
  "IVFFlat's `lists' depends on the corpus rather than on us, so it is rendered rather than
chosen. The ordering constraint it carries -- build AFTER the table holds representative
data, because it clusters what is there -- is a migration fact this cannot enforce."
  (let ((sql (ddl:ddl '(:create-index :name :idx_e :on :docs :columns (:embedding)
                        :using :ivfflat :opclass :vector_l2_ops :with (:lists 100))
                      :dialect "postgres")))
    (is (search "USING ivfflat" sql) "got: ~A" sql)
    (is (search "WITH (lists = 100)" sql) "got: ~A" sql)))

(test a-vector-index-without-an-operator-class-is-refused
  "REFUSED RATHER THAN DEFAULTED. pgvector will build one with its own default class, and a
reader of the DDL then cannot tell which distance operator it serves -- the one thing about
a vector index worth knowing."
  (signals error
    (ddl:ddl '(:create-index :name :i :on :d :columns (:e) :using :hnsw) :dialect "postgres"))
  (signals error
    (ddl:ddl '(:create-index :name :i :on :d :columns (:e) :using :ivfflat) :dialect "postgres")))

(test an-operator-class-without-a-method-is-refused
  "Almost always a vector index that lost its :using, and the SQL would be a btree over a
vector -- accepted by Postgres and useless for distance."
  (signals error
    (ddl:ddl '(:create-index :name :i :on :d :columns (:e) :opclass :vector_l2_ops)
             :dialect "postgres")))

(test an-unknown-index-method-or-operator-class-is-refused
  "A closed list rather than a passthrough, for the reason the dialect became one: a typo
would otherwise reach Postgres as a syntax error naming a line rather than a method."
  (signals error
    (ddl:ddl '(:create-index :name :i :on :d :columns (:e) :using :hnws
               :opclass :vector_l2_ops)
             :dialect "postgres"))
  (signals error
    (ddl:ddl '(:create-index :name :i :on :d :columns (:e) :using :hnsw
               :opclass :vector_cosine)
             :dialect "postgres")))

(test an-ordinary-index-is-unchanged
  "The control: adding :using, :opclass and :with must not alter what an index without them
renders to."
  (is (string= (ddl:ddl '(:create-index :name :idx_email :on :users :columns (:email) :unique t)
                        :dialect "postgres")
               "CREATE UNIQUE INDEX IF NOT EXISTS idx_email ON users (email)")))

;;; --- CREATE EXTENSION, which is a deployment fact (#258) --------------------
;;;
;;; A schema that needs pgvector has a PRECONDITION. Without it stated, the failure is a
;;; Postgres error about an unknown TYPE -- which names neither the extension nor the
;;; privilege, and sends the reader to the column definition instead of to the deployment.

(test an-extension-renders-for-postgres
  (is (string= "CREATE EXTENSION IF NOT EXISTS vector"
               (ddl:ddl '(:create-extension :name :vector))))
  (is (string= "CREATE EXTENSION vector"
               (ddl:ddl '(:create-extension :name :vector :if-not-exists nil)))
      "a migration that wants the error when it already exists can ask for it")
  (signals error (ddl:ddl '(:create-extension))
    "a form with no :name is a mistake, not an extension called NIL"))

(test sqlite-refuses-an-extension-and-names-it
  "Emitting nothing would be the silent degradation ADR-0001 rejected, one statement earlier
than the column: a vector column on SQLite is accepted as TEXT and searches nothing, so an
extension statement that quietly succeeded would make the whole schema look portable."
  (handler-case (progn (ddl:ddl '(:create-extension :name :vector) :dialect "sqlite")
                       (fail "SQLite must refuse CREATE EXTENSION"))
    (ddl:unsupported-ddl (c)
      (is (search "vector" (princ-to-string c))
          "the message names the extension, which is what the reader needs to go and look up")
      (is (search "Postgres" (princ-to-string c))
          "and says what kind of backend the schema needs"))))

(test xtdb-refuses-an-extension-like-every-other-ddl
  (signals ddl:unsupported-ddl
    (ddl:ddl '(:create-extension :name :vector) :dialect "xtdb")))

;;; --- ADR-0003 / #432: ddl speaks the tree's dialect vocabulary --------------

(test ddl-refuses-an-unrecognised-spelling-instead-of-rendering-postgres
  "A typo used to be RENDERED, not refused -- and this module's else-arm means Postgres.

`%sqlite-p' was `(string= (%dialect-name dialect) \"sqlite\")' over a normaliser that
PRINC'd anything it did not understand, so `:dialect \"sqlrite\"' returned
\"DROP TABLE IF EXISTS users CASCADE\": valid Postgres, and a syntax error on the SQLite the
caller meant. This is mnemosyne/query's original defect in the opposite direction, and it
was live in this module while the ticket described it as mere permissiveness.

Both directions: the typo is refused, and the dialect it was a typo OF still renders."
  (dolist (form '((:drop-table :name :users :cascade t)
                  (:create-extension :name :vector)
                  (:create-index :name :i :on :t :columns (:a))
                  (:drop-index :name :i)
                  (:alter-table :users (:add-column :nickname :string))))
    (dolist (bad '("sqlrite" "postgers" :postgers 42))
      (signals fldsh:unknown-dialect (ddl:ddl form :dialect bad))
      (signals fldsh:unknown-dialect (ddl:ddl-statements form :dialect bad)))
    ;; The control: a spelling that IS a dialect still works, so the refusal above is about
    ;; the spelling rather than about the form.
    (is (ddl:ddl form :dialect "postgres") "~S must still render on Postgres" form)))

(test the-sqlite-and-xtdb-ddl-guards-fire-under-either-spelling
  "CASCADE, DROP CONSTRAINT and XTDB's absence of DDL are refused whether the dialect is
spelled as a string or as the keyword mnemosyne/query uses. A guard only one spelling can
reach is not a guard -- it is a guard plus a way around it."
  (dolist (pair '(("sqlite" . :sqlite)))
    (dolist (d (list (car pair) (cdr pair)))
      (signals ddl:unsupported-ddl
        (ddl:ddl '(:drop-table :name :users :cascade t) :dialect d))
      (signals ddl:unsupported-ddl
        (ddl:ddl '(:create-extension :name :vector) :dialect d))
      (signals ddl:unsupported-ddl
        (ddl:ddl '(:alter-table :users (:drop-constraint :ck)) :dialect d))))
  (dolist (d '("xtdb" :xtdb))
    (dolist (form '((:create-index :name :i :on :t :columns (:a))
                    (:drop-index :name :i)
                    (:drop-table :name :users)
                    (:create-extension :name :vector)
                    (:alter-table :users (:add-column :n :string))))
      (signals ddl:unsupported-ddl (ddl:ddl form :dialect d))
      (signals ddl:unsupported-ddl (ddl:ddl-statements form :dialect d)))))

(test ddl-renders-the-same-however-the-dialect-is-spelled
  "Agreement, not merely refusal: the same dialect under two spellings must produce
byte-identical SQL, or the vocabularies have not actually been unified."
  (dolist (form '((:create-index :name :i :on :t :columns (:a))
                  (:drop-table :name :users)
                  (:alter-table :users (:add-column :nickname :string))))
    (dolist (pair '(("postgres" . :postgres) ("sqlite" . :sqlite)))
      (is (string= (ddl:ddl form :dialect (car pair))
                   (ddl:ddl form :dialect (cdr pair)))
          "~S must render identically for ~S and ~S" form (car pair) (cdr pair)))))
