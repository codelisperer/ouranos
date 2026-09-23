;;;; tests/schema.lisp --- fiveam suite for mnemosyne/schema + mnemosyne/changeset.
;;;;
;;;; Covers DDL generation (per dialect, and the XTDB no-DDL guard) and the changeset
;;;; funnel: casting by type, safe mass-assignment, the validators, and the bridge into
;;;; a mnemosyne/query INSERT/UPDATE. Adds to the shared MNEMOSYNE suite.

(in-package #:mnemosyne/tests)

(in-suite mnemosyne)

;; A schema to exercise (registered once at load).
(sch:defschema test-user (:table "users")
  (:id     :uuid    :primary t)
  (:email  :string  :required t)
  (:name   :string)
  (:age    :integer)
  (:active :boolean :default t))

;;; --- DDL generation -------------------------------------------------------
(test schema-ddl-postgres
  (let ((ddl (sch:schema-ddl (sch:find-schema 'test-user) :dialect "postgres")))
    (is (search "CREATE TABLE IF NOT EXISTS users (" ddl))
    (is (search "id UUID PRIMARY KEY" ddl))
    (is (search "email TEXT NOT NULL" ddl))
    (is (search "age BIGINT" ddl))
    (is (search "active BOOLEAN DEFAULT TRUE" ddl))))

(test schema-ddl-sqlite
  (let ((ddl (sch:schema-ddl (sch:find-schema 'test-user) :dialect "sqlite")))
    (is (search "id TEXT PRIMARY KEY" ddl))       ; UUID -> TEXT under sqlite
    (is (search "age INTEGER" ddl))))             ; BIGINT -> INTEGER under sqlite

(test schema-ddl-xtdb-signals            ; XTDB 2 is schemaless -- no DDL
  (signals error (sch:schema-ddl (sch:find-schema 'test-user) :dialect "xtdb")))

(test primary-key
  (is (eq :id (sch:primary-key (sch:find-schema 'test-user)))))

;;; --- changeset: cast + validate -------------------------------------------
(test cast-casts-by-type
  (let ((c (cs:cast 'test-user '(:email "a@x" :age "42" :active "yes") '(:email :age :active))))
    (is (cs:changeset-valid-p c))
    (is (equal '(:email "a@x" :age 42 :active 1) (cs:changeset-changes c)))))  ; str->int, bool->1

(test cast-safe-mass-assignment          ; a field not in ALLOWED never moves
  (let ((c (cs:cast 'test-user '(:email "a@x" :age "9") '(:email))))   ; :age omitted from allowed
    (is (null (nth-value 1 (cs:get-change c :age))))
    (is (equal '(:email "a@x") (cs:changeset-changes c)))))

(test cast-rejects-bad-integer
  (let ((c (cs:cast 'test-user '(:age "not-a-number") '(:age))))
    (is (not (cs:changeset-valid-p c)))
    (is (assoc :age (cs:changeset-errors c)))))

(test boolean-cast-variants
  (flet ((b (raw) (getf (cs:changeset-changes (cs:cast 'test-user (list :active raw) '(:active))) :active)))
    (is (eql 1 (b "yes"))) (is (eql 1 (b "1"))) (is (eql 1 (b "true")))
    (is (eql 0 (b "no")))  (is (eql 0 (b "0"))) (is (eql 0 (b "false")))))

(test validate-required-blank
  (let ((c (cs:validate-required
            (cs:cast 'test-user '(:email "   ") '(:email)) '(:email))))  ; whitespace = blank
    (is (not (cs:changeset-valid-p c)))
    (is (equal "can't be blank" (cdr (assoc :email (cs:changeset-errors c)))))))

(test validate-number-range
  (let ((ok  (cs:validate-number (cs:cast 'test-user '(:age "30") '(:age)) :age :gte 18 :lte 120))
        (bad (cs:validate-number (cs:cast 'test-user '(:age "5")  '(:age)) :age :gte 18 :lte 120)))
    (is (cs:changeset-valid-p ok))
    (is (not (cs:changeset-valid-p bad)))))

(test validate-format-predicate
  (let* ((email? (lambda (s) (and (find #\@ s) (find #\. s))))
         (ok  (cs:validate-format (cs:cast 'test-user '(:email "a@x.io") '(:email)) :email email?))
         (bad (cs:validate-format (cs:cast 'test-user '(:email "nope")   '(:email)) :email email?)))
    (is (cs:changeset-valid-p ok))
    (is (not (cs:changeset-valid-p bad)))))

;;; --- bridge to queries ----------------------------------------------------
(test changeset-to-insert
  (let ((c (cs:cast 'test-user '(:email "a@x" :name "Ann") '(:email :name))))
    (is (equal '(:insert-into "users" :values ((:email "a@x" :name "Ann"))) (cs:to-insert c)))
    ;; and it compiles to real parameterized SQL
    (multiple-value-bind (sql params) (q:sql (cs:to-insert c) :dialect :postgres)
      (is (equal "INSERT INTO users (email, name) VALUES (?, ?)" sql))
      (is (equal '("a@x" "Ann") params)))))

(test changeset-to-update
  (let ((c (cs:cast 'test-user '(:name "Bob") '(:name))))
    (is (equal '(:update "users" :set (:name "Bob") :where (:= :id 5))
               (cs:to-update c '(:= :id 5))))))

(test changeset-invalid-signals-at-edge
  (let ((c (cs:validate-required (cs:cast 'test-user '() '(:email)) '(:email))))
    (signals cs:changeset-invalid (cs:to-insert c))))

;;; --- binary columns (#142) -------------------------------------------------

(test defschema-accepts-binary-and-blob
  "Before #142 `make-field' rejected both, so a schema could not name a byte column at all
and an app had no way to register one itself."
  (finishes (sch:make-field '(:avatar :binary)))
  (finishes (sch:make-field '(:avatar :blob)))
  (signals error (sch:make-field '(:avatar :blobby))))

(test schema-ddl-emits-the-byte-column-per-dialect
  (sch:defschema binary-demo (:table "binary_demo")
    (:id :string :primary t)
    (:payload :binary))
  (let ((pg (sch:schema-ddl (sch:find-schema 'binary-demo) :dialect "postgres"))
        (lite (sch:schema-ddl (sch:find-schema 'binary-demo) :dialect "sqlite")))
    (is (search "BYTEA" pg) "postgres DDL should carry BYTEA, got: ~A" pg)
    (is (search "BLOB" lite) "sqlite DDL should carry BLOB, got: ~A" lite)))

(test cast-takes-octets-and-refuses-everything-else
  "BYTES IN, BYTES OUT. A string is refused rather than encoded: picking an encoding here
would be the framework guessing what the caller meant, and the guess is unreadable once the
row is written."
  (let* ((bytes (make-array 3 :element-type '(unsigned-byte 8)
                              :initial-contents '(0 255 65)))
         (ok (cs:cast 'binary-demo (list :payload bytes) '(:payload)))
         (from-string (cs:cast 'binary-demo (list :payload "hello") '(:payload)))
         (from-vector (cs:cast 'binary-demo (list :payload #(1 2 3)) '(:payload))))
    (is (cs:changeset-valid-p ok))
    (is (equalp bytes (cs:get-change ok :payload)))
    (is (not (cs:changeset-valid-p from-string)) "a string must not become bytes silently")
    (is (not (cs:changeset-valid-p from-vector))
        "a general vector of small integers is not an octet vector")))

(test an-empty-octet-vector-is-a-value-not-an-absence
  "Zero bytes is a legitimate payload. It must cast, and it must not read as missing --
`validate-required' asks a different question and gets to answer it."
  (let* ((empty (make-array 0 :element-type '(unsigned-byte 8)))
         (c (cs:cast 'binary-demo (list :payload empty) '(:payload))))
    (is (cs:changeset-valid-p c))
    ;; MULTIPLE-VALUE-BIND rather than (is (nth-value 1 ...)): fiveam's IS analyses the
    ;; form it is given to build its report, and NTH-VALUE is a macro rather than a
    ;; function, so it does not survive that analysis. It reported this as a failure while
    ;; the value under test was T -- checked directly outside the suite before changing
    ;; any of the code it appeared to be about.
    (multiple-value-bind (value present) (cs:get-change c :payload)
      (is-true present "zero bytes is a value, so the field must be present")
      (is (equalp empty value)))))
;;; --- vector columns (#212) -------------------------------------------------

(test defschema-carries-the-dimension-into-the-postgres-ddl
  (sch:defschema vector-demo (:table "vector_demo")
    (:id :string :primary t)
    (:embedding :vector :dimensions 1536))
  (let ((pg (sch:schema-ddl (sch:find-schema 'vector-demo) :dialect "postgres")))
    (is (search "vector(1536)" pg) "postgres DDL should carry vector(1536), got: ~A" pg)))

(test migrating-a-vector-schema-against-sqlite-is-refused-not-degraded
  "ADR-0001's default: refuse at migration time with a named reason, rather than emit a
column that would silently accept the values and never be searchable."
  (signals fldsh:unsupported-field-type
    (sch:schema-ddl (sch:find-schema 'vector-demo) :dialect "sqlite")))

(test a-vector-without-dimensions-is-refused-at-declaration-time
  "The earliest moment this is knowable, and long before a migration would meet it. There
is nothing sensible to default to: without N there is no pgvector type to emit."
  (signals error (sch:make-field '(:embedding :vector)))
  (signals error (sch:make-field '(:embedding :vector :dimensions 0)))
  (signals error (sch:make-field '(:embedding :vector :dimensions "1536")))
  (finishes (sch:make-field '(:embedding :vector :dimensions 1536))))

(test the-emulation-opt-in-is-refused-rather-than-accepted-and-ignored
  "ADR-0001 names `:on-unsupported :emulate' as the opt-in and says in the same breath that
until an emulation exists, :emulate is itself unsupported. Accepting the option and doing
nothing would let an app believe it had opted in while the column is refused anyway."
  (signals error (sch:make-field '(:embedding :vector :dimensions 1536
                                   :on-unsupported :emulate))))

(test the-ddl-add-column-path-carries-the-dimension-too
  "Two callers build a Field-Type from a declaration, and a parameterised type is the first
thing they cannot both get right from a name alone. Before this they were different
functions; a vector added by ALTER TABLE would have lost its width."
  (let ((sql (ddl:ddl '(:alter-table :docs (:add-column :embedding :vector :dimensions 768))
                      :dialect "postgres")))
    (is (search "vector(768)" (princ-to-string sql))
        "add-column should carry the dimension, got: ~A" sql)))

;;; --- an embedding width resolved from configuration (#258) ------------------
;;;
;;; The dimension of a vector column is a DEPLOYMENT fact, not a schema one. A consuming app
;;; could not commit to a width before measuring recall on its own corpus -- Russian-first
;;; across sixteen locales, so the plan of record of 1536 may have to become 1024 or 3072 --
;;; and could not measure before the column existed. `defschema' quoted its specs whole, so
;;; every option value had to be a literal and that measurement was unreachable.

(defparameter +configured-width+ 1024
  "Stands in for a width an app reads from its own configuration.")

(defun %width-from-config () 3072)

(sch:defschema cfg-embedding (:table "cfg_embeddings")
  (:id        :uuid   :primary t)
  (:embedding :vector :dimensions +configured-width+))

(sch:defschema fn-embedding (:table "fn_embeddings")
  (:id        :uuid   :primary t)
  (:embedding :vector :dimensions (%width-from-config)))

(test a-width-may-come-from-a-constant
  (let ((field (sch:schema-field (sch:find-schema 'cfg-embedding) :embedding)))
    (is (= 1024 (fld:field-type-width (sch:field-type field)))
        "the constant's VALUE reaches the type, not its name")
    (is (search "vector(1024)" (sch:schema-ddl (sch:find-schema 'cfg-embedding)))
        "and the DDL says so")))

(test a-width-may-come-from-a-function-call
  "Which is what reading it from configuration looks like."
  (let ((field (sch:schema-field (sch:find-schema 'fn-embedding) :embedding)))
    (is (= 3072 (fld:field-type-width (sch:field-type field))))
    (is (search "vector(3072)" (sch:schema-ddl (sch:find-schema 'fn-embedding))))))

(test a-width-that-resolves-to-nothing-is-still-refused
  "The control for the two above: evaluating the option did not weaken the check. A config
key that is absent resolves to NIL, which is exactly when an app most needs the refusal --
the alternative is a `vector(NIL)' or a silent default nobody chose."
  (signals error (sch:make-field (list :embedding :vector :dimensions nil)))
  (signals error (sch:make-field (list :embedding :vector :dimensions 0)))
  (signals error (sch:make-field (list :embedding :vector :dimensions "1536"))
    "a string from an environment variable is not a width either -- reading config is the
app's job, and parsing it is part of reading it"))

(test the-other-options-still-mean-what-they-meant
  "Every declaration in the tree passes self-evaluating values, so evaluating them changes
nothing -- asserted rather than promised."
  (let ((field (sch:make-field (list :email :string :required t :default "none"))))
    (is (eq t (sch:field-required field)))
    (is (string= "none" (sch:field-default field))))
  (let ((field (sch:make-field (list :created :integer :default :current_timestamp))))
    (is (eq :current_timestamp (sch:field-default field))
        "a keyword default is still the keyword and not its value")))

;;; --- casting a vector, at cast time (#258) ----------------------------------
;;;
;;; AGENTS.md makes `cast -> validate -> insert!' the path external input takes, and before
;;; this a vector could not travel it at all: `%cast-value' had no :vector clause, so ecase
;;; signalled, the handler turned it into a failed cast, and a CORRECT 1536-float embedding
;;; came back "is invalid (expected vector)". A wrong-length one got the same sentence, so an
;;; app could not tell "I sent 768 values into a 1536 column" from "this is not supported".
;;;
;;; Measured against the real backend before designing this: a Lisp list bound as a parameter
;;; reaches Postgres as `{1.0,0.0,0.0}' (array syntax) and is refused; `[1,0,0]' binds fine;
;;; and a SELECT returns `"[1,0.5,0]"'. Those three facts decide the whole shape.

(sch:defschema vec3 (:table "vec3_t")
  (:id        :integer :primary t)
  (:embedding :vector  :dimensions 3))

(test a-sequence-of-reals-casts-to-a-vector-literal
  (let ((c (cs:cast 'vec3 (list :id 1 :embedding (list 1.0 0.0 0.0)) '(:id :embedding))))
    (is-true (cs:changeset-valid-p c) "errors: ~S" (cs:changeset-errors c))
    (is (string= "[1.0,0.0,0.0]" (getf (cs:changeset-changes c) :embedding))
        "pgvector's text form, because a bound Lisp list is refused by Postgres"))
  (let ((c (cs:cast 'vec3 (list :id 1 :embedding (vector 1 2 3)) '(:id :embedding))))
    (is-true (cs:changeset-valid-p c) "a Lisp vector is a sequence of reals too")
    (is (string= "[1.0,2.0,3.0]" (getf (cs:changeset-changes c) :embedding)))))

(test a-double-float-renders-without-its-exponent-marker
  "The case a unit test written with single-float literals would have missed: ~A prints a
double as `1.0d0' and Postgres answers `invalid input syntax for type vector'. Embeddings
arrive as doubles from any JSON reader."
  (let ((c (cs:cast 'vec3 (list :embedding (list 0.1d0 -0.25d0 1d0)) '(:embedding))))
    (is-true (cs:changeset-valid-p c))
    (let ((text (getf (cs:changeset-changes c) :embedding)))
      (is-false (search "d" text) "no exponent marker anywhere in ~S" text)
      (is (string= "[0.1,-0.25,1.0]" text)))))

(test a-wrong-length-vector-is-refused-with-both-numbers
  "At cast time, where the error can name the schema's width -- not at insert time, where it
is a Postgres error about a column."
  (let ((c (cs:cast 'vec3 (list :id 1 :embedding (list 1.0 0.0)) '(:id :embedding))))
    (is-false (cs:changeset-valid-p c))
    (let ((reason (cdr (assoc :embedding (cs:changeset-errors c)))))
      (is (search "2" reason) "what arrived")
      (is (search "3" reason) "and what the column declares -- either alone leaves the
reader to guess which side is wrong")
      (is-false (search "is invalid" reason)
                "and it is not the generic sentence, which is what a correct-but-wrong-width
embedding used to get: ~S" reason))))

(test a-literal-postgres-returned-casts-back-unchanged
  "Read-modify-write has to work: `[1,0.5,0]' is exactly what a SELECT returns for a vector
column, so refusing it would mean every app parsing the string itself."
  (let ((c (cs:cast 'vec3 (list :embedding "[1,0.5,0]") '(:embedding))))
    (is-true (cs:changeset-valid-p c) "errors: ~S" (cs:changeset-errors c))
    (is (string= "[1,0.5,0]" (getf (cs:changeset-changes c) :embedding))
        "and it is not re-rendered, so a round trip does not drift"))
  (let ((c (cs:cast 'vec3 (list :embedding "[1,0.5]") '(:embedding))))
    (is-false (cs:changeset-valid-p c) "a literal of the wrong width is still refused")))

(test what-is-not-a-vector-is-refused-rather-than-coerced
  "The same call this file already makes for binary: choosing a representation for the caller
is a guess that becomes invisible once the row is written."
  (dolist (raw (list 42 "not a vector" "[a,b,c]" (list 1.0 "x" 3.0)))
    (let ((c (cs:cast 'vec3 (list :embedding raw) '(:embedding))))
      (is-false (cs:changeset-valid-p c) "~S must not cast to a vector" raw))))

;;; --- staleness of a derived value (ADR-0002, #258) --------------------------
;;;
;;; The convention is one sentence: THE FINGERPRINT COVERS EXACTLY THE INPUTS TO THE DERIVED
;;; VALUE. The test that matters is the one asserting the version stamp's defect is ABSENT --
;;; a write to a column the value does not depend on must not report staleness, because the
;;; cost of a false positive here is a model call per row.

(defun %hash (text)
  "A stand-in for the caller's digest. Not a cryptographic hash and not mnemosyne's business:
what is asserted below is the framing and the comparison, both of which are indifferent to
which digest a consumer brings (ADR-0002)."
  (format nil "h~D:~D" (length text) (sxhash text)))

(sch:defschema block-row (:table "block_rows")
  (:id        :uuid   :primary t)
  (:title     :string)
  (:body      :text)
  (:structure :text)                       ; layout and ordering -- everything that is not words
  (:embedding :vector :dimensions 3 :derived-from '(:title :body)))

(test a-derived-column-brings-its-two-companion-columns
  (let ((schema (sch:find-schema 'block-row)))
    (is-true (sch:schema-field schema :embedding_fingerprint)
             "the fingerprint of the inputs, as of when the value was computed")
    (is-true (sch:schema-field schema :embedding_deriver)
             "and what computed it, which is what makes a bulk re-derive one predicate")
    (let ((ddl (sch:schema-ddl schema :dialect "postgres")))
      (is-true (search "embedding_fingerprint" ddl)
               "real fields, so DDL needs no special case: ~S" ddl)
      (is-true (search "embedding_deriver" ddl)))
    (is (equal '(:title :body) (sch:derived-inputs schema :embedding))
        "the inputs in DECLARATION order, which two consumers must share or they compute
different fingerprints for identical content")))

(test an-input-that-is-not-a-field-is-refused
  "A typo would fingerprint the empty string forever, so the value would look permanently
fresh -- this convention's own failure mode, arriving through its front door."
  (signals error
    (sch:expand-derived (list (sch:make-field (list :body :text))
                              (sch:make-field (list :embedding :vector :dimensions 3
                                                    :derived-from '(:bdoy))))))
  (is-true (sch:expand-derived (list (sch:make-field (list :body :text))
                                     (sch:make-field (list :embedding :vector :dimensions 3
                                                           :derived-from :body))))
           "the control: the same declaration spelled correctly expands"))

(test a-fingerprint-needs-a-hash-the-caller-chose
  "No default, because a default fingerprint function is a compatibility promise nobody made:
two consumers that disagree about the digest disagree about staleness, silently."
  (signals der:no-fingerprint-hash (der:content-fingerprint (list "a" "b")))
  (is-true (der:content-fingerprint (list "a" "b") :hash #'%hash)))

(test the-framing-cannot-confuse-two-different-contents
  "`(\"ab\" \"c\")' and `(\"a\" \"bc\")' are different content. Any separator -- a newline, a
NUL, a private sentinel -- can occur in prose, so the framing is length-prefixed instead."
  (is (not (string= (der:frame-inputs (list "ab" "c"))
                    (der:frame-inputs (list "a" "bc")))))
  (is (not (string= (der:content-fingerprint (list "ab" "c") :hash #'%hash)
                    (der:content-fingerprint (list "a" "bc") :hash #'%hash))))
  (is (string= (der:frame-inputs (list nil "x"))
               (der:frame-inputs (list "" "x")))
      "a NULL column and an empty one fingerprint alike, which is correct: both contribute no
text to the derived value, so NULL -> \"\" is not staleness")
  (is (not (string= (der:frame-inputs (list nil "x"))
                    (der:frame-inputs (list "NIL" "x"))))
      "but a column holding the letters N-I-L is content, and must not look like an absent one")
  (is (string= (der:frame-inputs (list "x")) (der:frame-inputs (list "x")))
      "and the framing is stable for the same inputs"))

(test a-write-to-a-column-the-value-does-not-depend-on-is-not-staleness
  "THE WHOLE CONVENTION. A version stamp says the ROW changed; this says the CONTENT changed.
Reorder blocks and every row below bumps its version with no text touched -- a stamp re-derives
all of them, at a model call each."
  (let* ((title "A block")
         (body "Some words.")
         (before (der:content-fingerprint (list title body) :hash #'%hash))
         ;; the `structure' column changes -- ordering, styling, not words
         (after-restructure (der:content-fingerprint (list title body) :hash #'%hash))
         (after-edit (der:content-fingerprint (list title "Some other words.") :hash #'%hash)))
    (is-false (der:derived-stale-p before after-restructure)
              "a write that touched no input is not staleness")
    (is-true (der:derived-stale-p before after-edit)
             "and the control: an edit to an input IS -- otherwise the assertion above would
be satisfied by a fingerprint that never changes at all")))

(test a-row-with-no-fingerprint-yet-is-stale
  "The case that matters on the day the convention arrives: every existing row has no
fingerprint, and reading `never recorded one' as `up to date' would leave exactly those rows
un-re-derived forever."
  (is-true (der:derived-stale-p nil "h1:2"))
  (is-false (der:derived-stale-p "h1:2" "h1:2")))

(test the-deriver-column-drives-a-bulk-re-derive
  "A model or dimension change is not content changing, so the fingerprint cannot find those
rows. One predicate against a bind parameter can."
  (multiple-value-bind (sql params)
      (q:sql '(:select (:id) :from ("block_rows")
               :where (:<> :embedding_deriver "text-embedding-3-small"))
             :dialect :postgres)
    (is-true (search "embedding_deriver" sql))
    (is (equal '("text-embedding-3-small") params)
        "a bind parameter, which is what makes this work on every backend")))

(test staleness-is-the-disjunction-of-the-two-columns
  "Two columns invite checking one. Each disagreement alone is staleness: a caller comparing
only the fingerprint misses every row needing re-derivation after a model change -- the bulk
case the deriver column exists for -- and one comparing only the deriver misses every edit."
  (let ((fp-a (der:content-fingerprint (list "text") :hash #'%hash))
        (fp-b (der:content-fingerprint (list "other") :hash #'%hash)))
    (is-false (der:derived-stale-p fp-a fp-a :stored-deriver "m1" :current-deriver "m1")
              "both match: not stale, which is the control for the three below")
    (is-true (der:derived-stale-p fp-a fp-b :stored-deriver "m1" :current-deriver "m1")
             "the text was edited")
    (is-true (der:derived-stale-p fp-a fp-a :stored-deriver "m1" :current-deriver "m2")
             "the model changed, and the fingerprint cannot see it")
    (is-true (der:derived-stale-p fp-a fp-b :stored-deriver "m1" :current-deriver "m2")
             "both happened")
    (is-false (der:derived-stale-p fp-a fp-a)
              "a consumer that records no deriver is asking the fingerprint question alone and
gets that answer, rather than every row reading as stale forever")))

;;; --- ADR-0003 / #432: schema speaks the tree's dialect vocabulary -----------

(test the-schema-xtdb-guard-fires-under-either-spelling
  "The keyword :xtdb used to WALK PAST this guard.

`(string= dialect \"xtdb\")' compares a symbol designator by its SYMBOL-NAME, so :xtdb
compared \"XTDB\" against \"xtdb\" and missed -- and :xtdb is exactly the spelling
mnemosyne/query takes. The caller then got a Coalton \"Pattern match not exhaustive\" from
further in, naming neither the dialect nor the reason. The guard that exists to say
\"XTDB is schemaless\" was reachable by only one of XTDB's two spellings in this tree."
  (dolist (d '("xtdb" :xtdb "XTDB"))
    (signals error (sch:schema-ddl (sch:find-schema 'test-user) :dialect d))))

(test schema-ddl-refuses-an-unrecognised-spelling
  "A typo is not `the other dialect'. Both directions: refused, and the dialect it was a
typo of still generates."
  (dolist (bad '("postgers" :postgers "" 42))
    (signals fldsh:unknown-dialect (sch:schema-ddl (sch:find-schema 'test-user) :dialect bad)))
  (is (search "CREATE TABLE" (sch:schema-ddl (sch:find-schema 'test-user) :dialect "postgres"))))

(test schema-ddl-agrees-across-spellings
  "Identical DDL for the same dialect however it is named -- the property that makes one
vocabulary true, which a per-module refusal on its own does not give."
  (dolist (pair '(("postgres" . :postgres) ("sqlite" . :sqlite)))
    (is (string= (sch:schema-ddl (sch:find-schema 'test-user) :dialect (car pair))
                 (sch:schema-ddl (sch:find-schema 'test-user) :dialect (cdr pair)))
        "test-user DDL must be identical for ~S and ~S" (car pair) (cdr pair))))
