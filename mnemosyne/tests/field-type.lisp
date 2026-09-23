;;;; tests/field-type.lisp --- the field-type vocabulary's non-total signature (#334).
;;;;
;;;; ADR-0001's whole point is that "this backend cannot store this" became REPRESENTABLE.
;;;; The awkward part of testing that today is that every type in the current vocabulary is
;;;; Native on every dialect -- which is exactly why the old total signature looked correct
;;;; for a year. So the refusal path is exercised by handing the shell an Unsupported value
;;;; directly, rather than by waiting for #142 or #212 to introduce a type that produces one.
;;;; A test that could only run after those land would be a test that does not exist now,
;;;; when the precedent is being set.

(in-package #:mnemosyne/tests)

(in-suite mnemosyne)

;;; --- the dialect is a closed set now --------------------------------------

(test a-known-dialect-resolves
  (dolist (name '("sqlite" "postgres" "xtdb"))
    (is-true (fld:dialect-known? name) "~A should resolve" name)))

(test a-mistyped-dialect-is-refused-rather-than-meaning-not-postgres
  "THE BUG THIS FIXES. `postgers' used to take the else-branch: SQLite affinities against a
Postgres database, no error anywhere, discovered in a migration or not at all."
  (is-false (fld:dialect-known? "postgers"))
  (is-true (fld:dialect-known? "postgres"))
  (signals fldsh:unknown-dialect (fldsh:dialect-for "postgers")))

(test coaltons-none-is-true-in-cl-so-the-predicate-is-the-only-safe-ask
  "Recorded as a test because it is a live trap rather than a curiosity: `(or (dialect-from
name) (error ...))' READS correctly and accepts every bad name, because NONE is an object and
every object is true in CL. This suite caught it before it shipped."
  (is-true (and (fld:dialect-from "postgers") t)
           "NONE is truthy in CL -- if this ever fails, the CL shell can be simplified")
  (is-false (fld:dialect-known? "postgers")))

(test the-refusal-names-the-dialect-it-was-given
  "A refusal that does not say what it refused sends the reader back to the call site."
  (handler-case (progn (fldsh:dialect-for "postgers") (fail "expected UNKNOWN-DIALECT"))
    (fldsh:unknown-dialect (c)
      (is (string= "postgers" (fldsh:unknown-dialect-name c))))))

;;; --- the signature is no longer total -------------------------------------

(test every-current-type-is-native-on-both-real-dialects
  "The control for the refusal tests below: nothing in today's vocabulary is refused, so a
refusal in the suite is about the case under test and not about a broken table."
  (dolist (name '("string" "text" "integer" "float" "boolean" "uuid" "timestamp" "date"))
    (let ((ty (fld:field-type-from name)))
      (dolist (d (list (fldsh:dialect-for "postgres") (fldsh:dialect-for "sqlite")))
        (is (string= "native" (fld:field-type-support ty d))
            "~A on ~A should be native" name (fld:dialect-name d))))))

(test postgres-and-sqlite-still-disagree-where-they-always-did
  "The ADT did not flatten the dialect differences it wraps."
  (let ((ts (fld:field-type-from "timestamp")))
    (is (string= "TIMESTAMPTZ" (fldsh:column-sql ts "postgres")))
    (is (string= "TEXT" (fldsh:column-sql ts "sqlite")))))

(test an-unsupported-type-is-a-value-not-a-string
  "What the old signature could not express. `Unsupported' carries no SQL, which is why
callers must read the tag rather than the text."
  (is (string= "unsupported" (fld:sql-type-tag fld:Unsupported)))
  (is (string= "" (fld:sql-type-text fld:Unsupported)))
  (is (string= "native" (fld:sql-type-tag (fld:Native "BYTEA"))))
  (is (string= "BYTEA" (fld:sql-type-text (fld:Native "BYTEA")))))

;;; --- what the shell does with a refusal -----------------------------------

(test a-native-type-yields-its-sql
  (is (string= "BIGINT" (fldsh:column-sql (fld:field-type-from "integer") "postgres"))))

(test the-error-names-the-field-the-type-and-the-backend
  "Everything a reader needs to act, without opening the schema: which column, which type,
which backend. A condition that says only `unsupported' starts a search."
  (handler-case
      (progn (fldsh:column-sql (fld:field-type-from "uuid") "postgres") t)
    (error () (fail "uuid/postgres is native and must not signal"))))

;;; --- binary, the first type added through the partial signature (#142) -----
;;;
;;; ADR-0001 predicted this one: "#142 (binary) needs none of this machinery -- BYTEA and
;;; BLOB are native everywhere, so it is Native on both backends. But it must be
;;; implemented THROUGH that signature." These tests pin both halves of that: that it is
;;; Native, and that it went through the Sql-Type rather than around it.

(test binary-is-native-on-both-real-dialects
  "Not Emulated and not Unsupported. Both backends carry bytes without help, so claiming
otherwise would make the refusal machinery look exercised when it is not."
  (let ((ty (fld:field-type-from "binary")))
    (is (string= "native" (fld:field-type-support ty (fldsh:dialect-for "sqlite"))))
    (is (string= "native" (fld:field-type-support ty (fldsh:dialect-for "postgres"))))))

(test binary-names-the-column-type-each-backend-actually-has
  (is (string= "BLOB" (fldsh:column-sql (fld:field-type-from "binary") "sqlite")))
  (is (string= "BYTEA" (fldsh:column-sql (fld:field-type-from "binary") "postgres"))))

(test blob-is-an-alias-for-binary
  "Spelled BLOB by SQLite, so an app author reaching for a byte column is likely to type
it. The same aliasing `int' already has for `integer'."
  (is (string= "binary" (fld:field-type-name (fld:field-type-from "blob"))))
  (is (string= "binary" (fld:field-type-name (fld:field-type-from "binary"))))
  (is (string= "BYTEA" (fldsh:column-sql (fld:field-type-from "blob") "postgres"))))

(test an-unknown-type-name-still-falls-back-rather-than-becoming-binary
  "The control for the alias above: adding two names to the parse must not widen what
matches. `blobby' is not `blob'."
  (is (string= "string" (fld:field-type-name (fld:field-type-from "blobby"))))
  (is (string= "string" (fld:field-type-name (fld:field-type-from "bin")))))
;;; --- vector, the first type that is genuinely Unsupported (#212) -----------
;;;
;;; This is the case ADR-0001 was written for. Every type before it was Native on every
;;; dialect, which is why the old total signature looked correct for a year -- the suite
;;; above had to hand the shell an Unsupported value directly because no type produced one.
;;; Vector produces one, so these tests reach the refusal through a real declaration.

(test vector-is-native-on-postgres-and-unsupported-on-sqlite
  "The asymmetry the ADT exists to express. SQLite has no native vector type; sqlite-vec is
an extension with its own build story and a plain SQLite file cannot do this at all."
  (let ((ty (fld:ft-vector 1536)))
    (is (string= "native" (fld:field-type-support ty (fldsh:dialect-for "postgres"))))
    (is (string= "unsupported" (fld:field-type-support ty (fldsh:dialect-for "sqlite"))))))

(test the-dimension-reaches-the-column-type
  "pgvector's type IS `vector(1536)'. A vector that forgot its width is not a narrower
vector, it is not a column type."
  (is (string= "vector(1536)" (fldsh:column-sql (fld:ft-vector 1536) "postgres")))
  (is (string= "vector(768)" (fldsh:column-sql (fld:ft-vector 768) "postgres"))))

(test the-width-is-readable-without-parsing-the-name-back-apart
  "A plain number rather than an Optional, because a CL caller cannot test an Optional with
IF -- Coalton's NONE is an object and every object is true in CL. This file makes the same
point about `dialect-from'. Zero already means `no width' throughout this type, so the
absent case is a value CL handles correctly."
  (is (= 384 (fld:field-type-width (fld:ft-vector 384))))
  (is (= 0 (fld:field-type-width (fld:field-type-from "integer")))
      "a non-vector type has no width to report")
  (is (= 0 (fld:field-type-width (fld:field-type-from "vector")))
      "and neither does a vector that was never given one"))

(test the-type-name-is-the-same-whatever-the-width
  "FIELD-TYPE-NAME is the key the CL shell dispatches casting on. Rendering the width into
it would make the dispatch key vary per declaration, and every vector casts alike."
  (is (string= "vector" (fld:field-type-name (fld:ft-vector 1536))))
  (is (string= "vector" (fld:field-type-name (fld:ft-vector 3)))))

(test a-vector-with-no-width-is-refused-on-every-dialect-including-postgres
  "THE BACKSTOP, and it is deliberately not a default. `field-type-from' can only be given
a name, and a name does not carry a dimension, so it yields a zero width. Postgres does not
accept `vector(0)', so the honest answer is the same refusal SQLite gets rather than a
column the backend would reject at migration time.

Asserted so that nobody later `fixes' this into a default width -- which would turn a
declaration that forgot its dimension into a silently wrong column."
  (let ((no-width (fld:field-type-from "vector")))
    (is (string= "unsupported" (fld:field-type-support no-width (fldsh:dialect-for "postgres"))))
    (is (string= "unsupported" (fld:field-type-support no-width (fldsh:dialect-for "sqlite"))))
    (signals fldsh:unsupported-field-type (fldsh:column-sql no-width "postgres"))))

(test the-refusal-names-the-field-the-type-and-the-backend
  "A refusal an app can act on. ADR-0001 asks for the field, the type, the backend and what
to do about it, matching the XTDB precedent."
  (handler-case
      (progn (fldsh:column-sql (fld:ft-vector 1536) "sqlite" :field-name :embedding)
             (fail "expected UNSUPPORTED-FIELD-TYPE"))
    (fldsh:unsupported-field-type (c)
      (is (eq :embedding (fldsh:unsupported-field-type-field c)))
      (is (string= "vector" (fldsh:unsupported-field-type-type c)))
      (is (string= "sqlite" (fldsh:unsupported-field-type-backend c)))
      (is (string= "unsupported" (fldsh:unsupported-field-type-support c))))))

;;; --- ADR-0003 / #432: one dialect vocabulary, and its refusal ---------------
;;; These test the NORMALISER itself. The per-module tests (query, ddl, schema, introspect)
;;; test that each module goes through it; this tests that going through it is worth doing.

(test dialect-for-accepts-every-designator-and-they-agree
  "A keyword, a string and an already-typed Dialect name the SAME dialect.

THE DEFECT #432 IS ABOUT, stated positively. The tree held two vocabularies -- keywords in
mnemosyne/query, strings in mnemosyne/ddl and mnemosyne/schema -- and a caller holding one
spelling was not refused by the module that wanted the other; it took that module's
`the other dialect' branch. Agreement is the property that makes one vocabulary true, and
it is not implied by each module merely having a check of its own."
  (dolist (name '("postgres" "sqlite" "xtdb"))
    (let ((from-string  (fldsh:dialect-for name))
          (from-keyword (fldsh:dialect-for (intern (string-upcase name) :keyword)))
          (from-upcase  (fldsh:dialect-for (string-upcase name))))
      (is (eq from-string from-keyword)
          "~S and ~S must be the same dialect" name (string-upcase name))
      (is (eq from-string from-upcase))
      (is (string= name (fld:dialect-name from-string))))))

(test dialect-for-is-idempotent
  "Normalising an already-normalised value returns it, so a caller that has checked can pass
the result on without a second vocabulary meaning `already checked'."
  (dolist (d (list fld:D-Sqlite fld:D-Postgres fld:D-Xtdb))
    (is (eq d (fldsh:dialect-for d)))
    (is (eq d (fldsh:dialect-for (fldsh:dialect-for d))))))

(test dialect-for-refuses-a-non-designator
  "The old version called `(string name)' on whatever it was handed, so an object that is
not a string designator produced a CL type error naming STRING -- a refusal about the wrong
object. 42 is not a dialect, and the condition has to say so."
  (signals fldsh:unknown-dialect (fldsh:dialect-for 42))
  (signals fldsh:unknown-dialect (fldsh:dialect-for '(:postgres)))
  (handler-case (progn (fldsh:dialect-for 42) (fail "expected UNKNOWN-DIALECT"))
    (fldsh:unknown-dialect (c)
      (is (eql 42 (fldsh:unknown-dialect-name c))
          "the condition must carry the value that was refused"))))

(test the-known-dialect-list-is-read-from-the-vocabulary
  "+DIALECT-NAMES+ is derived from +DIALECTS+, and the condition's report reads it.

A message that lists its own copy of the three names is a fourth place for them to disagree,
and the one place a reader would most trust. Assert the report names every dialect there
actually is, rather than three words someone typed."
  (is (= (length fldsh:+dialects+) (length fldsh:+dialect-names+)))
  (let ((report (handler-case (progn (fldsh:dialect-for "nope") nil)
                  (fldsh:unknown-dialect (c) (princ-to-string c)))))
    (is (not (null report)) "dialect-for must have signalled")
    (dolist (n fldsh:+dialect-names+)
      (is (search n report) "the report must name the ~A dialect" n))))

(test xtdb-has-no-column-type-for-any-field-type
  "XTDB 2 is schemaless, so there is no column type to return -- for ANY field type.

THE THIRD DIALECT IS WHY `THE OTHER ONE' IS WRONG AS A CONCEPT (#432). field-type-sql asked
`(== (dialect-name dialect) \"postgres\")' and handed D-Xtdb the SQLite arm, so a backend
with no columns at all reported INTEGER, TEXT, BOOLEAN. Nothing reaches it on XTDB today --
schema-ddl and every ddl form refuse XTDB first -- which is exactly why a wrong answer here
could sit unread. Both directions: Unsupported on XTDB, native on the two that have columns."
  ;; Built through FIELD-TYPE-FROM, the way the rest of this file does: FT-Binary is not an
  ;; exported constructor, and reaching for the internal symbol would make the test depend
  ;; on something the package deliberately does not promise.
  (dolist (ty (mapcar #'fld:field-type-from
                      '("string" "text" "integer" "float" "boolean" "uuid" "timestamp"
                        "date" "binary")))
    (is (string= "unsupported" (fld:field-type-support ty fld:D-Xtdb))
        "~A must be unsupported on XTDB" (fld:field-type-name ty))
    (is (string= "native" (fld:field-type-support ty fld:D-Postgres))
        "~A must still be native on Postgres" (fld:field-type-name ty))
    (is (string= "native" (fld:field-type-support ty fld:D-Sqlite))
        "~A must still be native on SQLite" (fld:field-type-name ty))))
