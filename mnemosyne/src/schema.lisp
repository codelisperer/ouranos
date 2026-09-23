;;;; schema.lisp --- Ecto-style schema definitions (effectful CL shell).
;;;;
;;;; A SCHEMA names a table and its FIELDs (each a typed column with options). It is the
;;;; single source of truth two things read: DDL generation (SCHEMA-DDL -> a migration's
;;;; up-SQL) and changeset casting/validation (mnemosyne/changeset). The field *types* are
;;;; the typed Coalton core (mnemosyne/field); the definition, registry, and DDL rendering
;;;; are dynamic CL. No macro magic beyond DEFSCHEMA, which is sugar over MAKE-SCHEMA data.

(in-package #:mnemosyne/schema)

(defparameter +field-type-names+
  '("string" "text" "integer" "int" "float" "boolean" "bool" "uuid" "timestamp" "date"
    "binary" "blob" "vector")
  "The type names DEFSCHEMA accepts (mirror of mnemosyne/field:Field-Type).")

(defstruct (field (:constructor %make-field) (:copier nil))
  "One column of a schema: NAME (keyword), TYPE (a mnemosyne/field:Field-Type), a keyword
TYPE-NAME mirror the changeset dispatches casting on, and the usual options."
  (name (error "field name required") :type keyword)
  type
  (type-name (error "type-name required") :type keyword)
  (required nil)
  (primary nil)
  (default nil)
  ;; The field names this column's value is DERIVED FROM, in declaration order (ADR-0002).
  ;; NIL for an ordinary column, which is every column that existed before the convention.
  (derived-from nil :type list))

(defstruct (schema (:constructor %make-schema) (:copier nil))
  "A named entity over a TABLE with a list of FIELDs."
  (name (error "schema name required") :type symbol)
  (table (error "table required") :type string)
  (fields nil :type list))

(defvar *schemas* (make-hash-table :test 'eq)
  "Registry: schema name (symbol) -> SCHEMA. DEFSCHEMA registers here.")

(defun make-schema (name table fields)
  "A SCHEMA built at RUNTIME: NAME a symbol, TABLE a string, FIELDS a list of specs.

WHY THIS IS PUBLIC AND DEFSCHEMA IS NOT ENOUGH (#138). A parameterised column carries its
parameter in its type, and for a vector that parameter is a DEPLOYMENT fact rather than a
source-code one: the width follows from which embedding model an operator configured, so a
literal `(:embedding :vector :dimensions 1536)' in a DEFSCHEMA has hard-coded one vendor's
model into the schema. A caller that learns the width at startup needs to build the schema
then, and until now the only constructor was internal.

FIELDS are specs, not FIELD objects, so this validates the same way DEFSCHEMA does rather
than accepting whatever a caller assembled -- one parser, not two."
  (check-type name symbol)
  (check-type table string)
  (%make-schema :name name :table table :fields (mapcar #'make-field fields)))

(defun register-schema (schema)
  "Register SCHEMA under its name; return it."
  (setf (gethash (schema-name schema) *schemas*) schema))

(defun find-schema (name)
  "The registered SCHEMA named NAME (a symbol), or signal."
  (or (gethash name *schemas*)
      (error "mnemosyne/schema: no schema named ~S" name)))

(defun schema-field (schema name)
  "The FIELD named NAME (keyword) in SCHEMA, or signal."
  (or (find name (schema-fields schema) :key #'field-name)
      (error "mnemosyne/schema: schema ~S has no field ~S" (schema-name schema) name)))

(defun primary-key (schema)
  "The NAME of SCHEMA's primary-key field, or NIL if none is marked."
  (let ((f (find t (schema-fields schema) :key #'field-primary)))
    (and f (field-name f))))

(defun field-type-for (type-name opts &key field-name (context "mnemosyne/schema"))
  "The Field-Type a declaration means, including any parameter it carries.

ONE PLACE THAT KNOWS A VECTOR NEEDS A DIMENSION (pre-publication issue 212). Two callers build a Field-Type from
a declared spec -- MAKE-FIELD here and MNEMOSYNE/DDL's column builder -- and a parameterised
type is the first thing they cannot both get right by calling FIELD-TYPE-FROM with a name.
Two copies of this rule is how the two would disagree about a declaration somebody writes
later, which is the reason the dialect mapping was centralised for the same reason.

TYPE-NAME is the already-validated lowercase name. OPTS is the declaration's plist."
  (if (string= type-name "vector")
      (let ((dims (getf opts :dimensions)))
        (unless (and (integerp dims) (plusp dims))
          ;; REFUSED AT DECLARATION TIME, which is the earliest moment this is knowable and
          ;; long before a migration would meet it. pgvector's type is `vector(N)': without
          ;; N there is no column type to emit, so there is nothing sensible to default to.
          (error "~A: ~@[field ~S: ~]a :vector needs a positive :dimensions, got ~S.~%Declare it as part of the type, e.g. (:embedding :vector :dimensions 1536)."
                 context field-name dims))
        (mnemosyne/field:ft-vector dims))
      (mnemosyne/field:field-type-from type-name)))

(defun make-field (spec)
  "Build a FIELD from a spec (:name :type &key required primary default dimensions)."
  (destructuring-bind (name type &rest opts) spec
    (let ((tn (string-downcase (symbol-name type))))
      (unless (member tn +field-type-names+ :test #'string=)
        (error "mnemosyne/schema: unknown field type ~S (one of ~{~A~^, ~})" type +field-type-names+))
      ;; ADR-0001 NAMES THIS SYNTAX, SO IT MUST NOT BE IGNORED. The ADR makes emulation
      ;; opt-in at the declaration site -- `(:embedding :vector :dimensions 1536
      ;; :on-unsupported :emulate)' -- and an app following it would write exactly that.
      ;; No emulation exists for any type yet, and the ADR says so in the same breath:
      ;; "Emulated obliges someone to write a real emulation. Until one exists, :emulate on
      ;; a vector column is itself unsupported -- which is honest, and loud."
      ;;
      ;; Accepting the option and doing nothing would be the quietest possible version of
      ;; that: the app believes it opted in, the column is refused anyway, and the reason
      ;; names the backend rather than the missing emulation. Refusing here says which.
      (when (getf opts :on-unsupported)
        (error "mnemosyne/schema: field ~S declares :on-unsupported ~S, and no emulation exists for type ~S.~%ADR-0001 makes emulation opt-in, and the opt-in is not implemented: the option is refused rather than accepted and ignored.~%Remove it, or use a backend where the type is native."
               name (getf opts :on-unsupported) type))
      (let ((derived-from (let ((d (getf opts :derived-from)))
                            ;; A KEYWORD OR A LIST, and the reason is the evaluated option
                            ;; values above: `:derived-from :body' needs no quote because a
                            ;; keyword self-evaluates, while two inputs are
                            ;; `:derived-from (quote (:title :body))'. Accepting the single
                            ;; keyword is what keeps the common case free of a quote that
                            ;; readers forget -- and forgetting it is not silent: `(:title
                            ;; :body)' evaluates as a call to :TITLE and fails at definition.
                            (cond ((null d) nil)
                                  ((keywordp d) (list d))
                                  ((listp d) d)
                                  (t (error "mnemosyne/schema: field ~S declares :derived-from ~S, which must be a field name or a quoted list of them -- the inputs to this value, in the order they are fingerprinted (ADR-0002)."
                                            name d))))))
        (%make-field :name name
                     :type (field-type-for tn opts :field-name name)
                     :type-name (intern (string-upcase tn) :keyword)
                     :required (getf opts :required)
                     :primary (getf opts :primary)
                     :default (getf opts :default)
                     :derived-from derived-from)))))

;;; --- a derived value's staleness columns (ADR-0002) -------------------------

(defun expand-derived (fields)
  "FIELDS with the companion columns a `:derived-from' declaration implies.

Each derived column gains two: `<name>_fingerprint', the fingerprint of its inputs when the
value was computed, and `<name>_deriver', what computed it (a model id, a version). They are
REAL FIELDS rather than columns conjured at DDL time, so `schema-ddl', drift detection and
casting need no special case -- and a table that has them while its schema does not is exactly
the drift MNEMOSYNE/INTROSPECT exists to report.

Every name in `:derived-from' must be a declared field of the same schema. A typo would
otherwise fingerprint the empty string forever: the value would look permanently up to date,
which is the failure mode this convention exists to prevent, arriving through its own front
door."
  (let ((names (mapcar #'field-name fields)))
    (dolist (f fields)
      (dolist (input (field-derived-from f))
        (unless (member input names)
          (error "mnemosyne/schema: field ~S is declared :derived-from ~S, and ~S is not a field of this schema (it has ~{~S~^, ~}).~%A fingerprint over a field that does not exist never changes, so the value would look permanently fresh."
                 (field-name f) (field-derived-from f) input names))))
    (append fields
            (loop for f in fields
                  when (field-derived-from f)
                    append (list (make-field (list (mnemosyne/derived:fingerprint-column
                                                    (field-name f))
                                                   :string))
                                 (make-field (list (mnemosyne/derived:deriver-column
                                                    (field-name f))
                                                   :string)))))))

(defun derived-fields (schema)
  "SCHEMA's fields that declare what they are derived from."
  (remove-if-not #'field-derived-from (schema-fields schema)))

(defun derived-inputs (schema field-name)
  "The field names FIELD-NAME's value is derived from, in declaration order.

THE ORDER IS THE SCHEMA'S and callers must keep it: `content-fingerprint' frames its inputs
positionally, so two consumers that read this and one that guesses compute different
fingerprints for identical content."
  (field-derived-from (schema-field schema field-name)))

(defmacro defschema (name (&key table) &body field-specs)
  "Define and register schema NAME. TABLE defaults to the lowercased NAME. Each FIELD-SPEC
is (:field :type &key required primary default dimensions).

A FIELD SPEC'S OPTION VALUES ARE EVALUATED, and that CHANGED in pre-publication issue 258: they used to be quoted
whole, so every value was a literal. `:dimensions +embedding-width+' and
`:dimensions (embedding-width)' now resolve a width from configuration at definition time,
which is what the change bought.

IF YOU ARE UPGRADING AND YOUR DECLARATION PASSED A NON-SELF-EVALUATING VALUE -- a bare symbol
you meant as a symbol, or a list you meant as data -- QUOTE IT: `:default (quote (:a :b))'.
Values that are self-evaluating are unaffected, which is every option in every declaration in
this tree (keywords, strings, numbers, T) and almost certainly in yours; a bare symbol that
used to arrive as itself now evaluates, so an unbound variable is the failure you would see.
Said here rather than only in a commit message because this macro ships beyond this tree --
`cons conform' puts it in generated projects -- and an inspection of THIS tree is not a
promise about code we cannot see.

A migration's SQL must still be pinned rather than re-derived per deploy; see the commentary
below and docs/migrations.md §8. E.g.

  (defschema user (:table \"users\")
    (:id         :uuid      :primary t)
    (:email      :string    :required t)
    (:name       :string)
    (:age        :integer)
    (:active     :boolean   :default t))"
  `(register-schema
    (%make-schema :name ',name
                  :table ,(or table (string-downcase (symbol-name name)))
                  ;; THE OPTION VALUES ARE ORDINARY LISP EXPRESSIONS, and that is the whole
                  ;; of what pre-publication issue 258 needed from this macro. The specs used to be quoted whole,
                  ;; so every value had to be a literal -- which is fine for `:primary t' and
                  ;; fatal for `:dimensions', the one option whose value is a DEPLOYMENT fact
                  ;; rather than a schema one. A consuming app cannot commit to an embedding
                  ;; width before measuring recall on its own corpus, and could not measure
                  ;; before the column existed; `:dimensions +embedding-width+' now works.
                  ;;
                  ;; Every existing declaration in this tree passes only self-evaluating
                  ;; values -- keywords, strings, numbers, T -- so this is backward compatible
                  ;; by inspection rather than by promise (hyperion/session-db, auth-db, the
                  ;; active-search example, and every doc example were checked).
                  ;;
                  ;; WHAT THIS MAKES POSSIBLE AND THE RULE THAT GOES WITH IT: a schema whose
                  ;; width comes from configuration renders DIFFERENT DDL in two deployments.
                  ;; That is a real hazard and it already has a detector -- MNEMOSYNE/INTROSPECT's
                  ;; VERIFY-SCHEMA reports a changed vector dimension as drift, by design
                  ;; (pre-publication issue 212) -- so the rule is: a migration's up-SQL is PINNED, generated once
                  ;; and committed as text, never regenerated from a config-resolved schema at
                  ;; each deploy. Verify at boot; do not re-derive at deploy.
                  :fields (expand-derived
                           (list ,@(mapcar (lambda (spec) `(make-field (list ,@spec)))
                                           field-specs))))))

;;; --- DDL generation (feeds a migration's up-SQL) --------------------------
(defun %default-sql (v)
  "Render a column DEFAULT literal, or NIL to omit. NIL means \"no default\"; use a keyword
(e.g. :current_timestamp, :false) for SQL constants/functions."
  (cond ((null v) nil)
        ((eq v t) "TRUE")
        ((numberp v) (princ-to-string v))
        ((stringp v) (format nil "'~A'" v))
        ((keywordp v) (string-downcase (symbol-name v)))
        (t (princ-to-string v))))

(defun %column-ddl (field dialect)
  (let ((default (%default-sql (field-default field))))
    (format nil "~A ~A~:[~; PRIMARY KEY~]~:[~; NOT NULL~]~@[ DEFAULT ~A~]"
            (string-downcase (symbol-name (field-name field)))
            (mnemosyne/field-shell:column-sql (field-type field) dialect
                                             :field-name (field-name field))
            (field-primary field)
            (and (field-required field) (not (field-primary field)))
            default)))

(defun schema-ddl (schema &key (dialect "postgres") (if-not-exists t))
  "CREATE TABLE DDL for SCHEMA under DIALECT (a backend designator). Intended as a migration's
up-SQL: DDL stays raw SQL in migrations, but the shape is derived from the schema, not
hand-written twice. XTDB 2 is schemaless -- it has no DDL, so this does not apply there."
  ;; NORMALISED BEFORE THE GUARD (pre-publication issue 432, ADR-0003). This was `(string= dialect "xtdb")', and
  ;; STRING= on a symbol designator compares its SYMBOL-NAME -- so the KEYWORD :xtdb, which
  ;; is the spelling MNEMOSYNE/QUERY takes, compared "XTDB" against "xtdb" and missed. The
  ;; guard that exists to say "XTDB is schemaless" was skipped by one of the two spellings
  ;; of XTDB in this tree, and the caller got a Coalton "Pattern match not exhaustive"
  ;; from further in, naming neither the dialect nor the reason.
  (let ((dialect (fldsh:dialect-for dialect)))
    (when (eq dialect fld:D-Xtdb)
      (error "mnemosyne/schema: XTDB 2 is schemaless -- no CREATE TABLE. See docs/xtdb-notes.md."))
    (format nil "CREATE TABLE ~:[~;IF NOT EXISTS ~]~A (~%~{  ~A~^,~%~}~%)"
            if-not-exists (schema-table schema)
            (mapcar (lambda (f) (%column-ddl f dialect)) (schema-fields schema)))))
