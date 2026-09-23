;;;; field.lisp --- the typed field-type vocabulary (Coalton core).
;;;;
;;;; What TYPE a schema field declares -- typed and IO-free. A Field-Type maps two ways:
;;;; to a SQL column type per dialect (feeds DDL / migrations) and to a name the CL shell
;;;; dispatches its cast on (mnemosyne/changeset). The schema definition, casting of raw
;;;; params, and validation are the effectful CL shell; the type vocabulary is here.

(cl:in-package #:mnemosyne/field)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  (define-type Field-Type
    "The column-type vocabulary a schema field can declare. SQLite is dynamically typed
(affinities); Postgres gets precise types; XTDB 2 is schemaless (types advisory)."
    FT-String FT-Text FT-Integer FT-Float FT-Boolean FT-Uuid FT-Timestamp FT-Date
    ;; Raw bytes (pre-publication issue 142). BLOB on SQLite, BYTEA on Postgres -- native on both, which is
    ;; what ADR-0001 predicted when it said binary "needs none of this machinery" and
    ;; would be Native on both backends. It is added THROUGH the partial signature the
    ;; ADR requires rather than before it, so the easy case did not set the precedent.
    FT-Binary
    ;; THE FIRST PARAMETERISED CONSTRUCTOR IN THIS VOCABULARY (pre-publication issue 212), and the parameter is
    ;; not decoration: pgvector's type IS `vector(1536)', so a dimension-less vector is not
    ;; a narrower vector, it is not a column type at all. That makes the dimension part of
    ;; the type rather than an option beside it.
    ;;
    ;; It is also the first type that is genuinely Unsupported somewhere, which is what
    ;; ADR-0001 built the Sql-Type ADT for. SQLite has no native vector; sqlite-vec is an
    ;; extension with its own build story and a plain SQLite file cannot do this at all.
    (FT-Vector UFix))

  (declare field-type-name (Field-Type -> String))
  (define (field-type-name ty)
    "A stable short name the CL shell dispatches casting on."
    (match ty
      ((FT-String) "string") ((FT-Text) "text") ((FT-Integer) "integer")
      ((FT-Float) "float") ((FT-Boolean) "boolean") ((FT-Uuid) "uuid")
      ((FT-Timestamp) "timestamp") ((FT-Date) "date") ((FT-Binary) "binary")
      ;; The DIMENSION IS DELIBERATELY NOT HERE. This name is what the CL shell dispatches
      ;; casting on, and every vector casts the same way whatever its width. Rendering
      ;; "vector(1536)" here would make the dispatch key vary per declaration.
      ;; FIELD-TYPE-DIMENSION is how a caller that wants the width asks for it.
      ((FT-Vector _) "vector")))

  ;; A UFIX RATHER THAN AN OPTIONAL, AND THAT IS THE CL BOUNDARY TALKING. This file already
  ;; carries the lesson twenty lines up: Coalton's NONE is an OBJECT, and every object is
  ;; true in CL, so a CL caller writing `(if (field-type-dimension ty) ...)' against an
  ;; Optional takes the true branch for every type in the vocabulary. `dialect-from' solved
  ;; that by adding a Boolean-returning partner for CL to ask instead.
  ;;
  ;; Here there is a better answer than a partner function, because ZERO ALREADY MEANS
  ;; "no width" everywhere else in this type: `field-type-from "vector"' yields it, and
  ;; `field-type-sql' refuses it on every dialect. So the width can be a plain number whose
  ;; absent case is a value CL handles correctly, and the trap does not exist to document.
  ;;
  ;; Written as an Optional first, and the suite caught it immediately -- the assertion that
  ;; a non-vector type has no width failed, because NONE is truthy.
  (declare field-type-width (Field-Type -> UFix))
  (define (field-type-width ty)
    "The declared width of a vector type, or 0 for every type that has none.

Separate from FIELD-TYPE-NAME so the name stays a dispatch key and the width stays a
number, rather than one string a caller has to take apart again."
    (match ty
      ((FT-Vector n) n)
      (_ 0)))
  ;; THE DIALECT IS A CLOSED SET (ADR-0001 Consequences, pre-publication issue 334). It was a String, and a typo
  ;; -- "postgers" -- silently took the non-Postgres branch: no error anywhere, and a
  ;; migration with SQLite affinities against a Postgres database. A String argument whose
  ;; only legal values are three known words is a closed type wearing an open one.
  (define-type Dialect
    D-Sqlite D-Postgres D-Xtdb)

  (declare dialect-name (Dialect -> String))
  (define (dialect-name d)
    (match d
      ((D-Sqlite) "sqlite")
      ((D-Postgres) "postgres")
      ((D-Xtdb) "xtdb")))

  ;; PARTIAL ON PURPOSE. The old code took any string and quietly meant "not postgres"; this
  ;; returns None so the caller has to decide what an unknown backend means. That is the
  ;; whole value of the change -- the typo becomes a thing somebody must handle.
  (declare dialect-from (String -> (Optional Dialect)))
  (define (dialect-from name)
    (cond
      ((== name "sqlite") (Some D-Sqlite))
      ((== name "postgres") (Some D-Postgres))
      ((== name "xtdb") (Some D-Xtdb))
      (True None)))

  ;; THE CL-FACING PAIR. `dialect-from' returns an Optional, which is right for a Coalton
  ;; caller and a trap for a CL one: Coalton's NONE is an OBJECT, and every object is true in
  ;; CL, so `(or (dialect-from name) (error ...))' accepts the failure case silently. Found by
  ;; a test asserting the refusal, which is the only reason it was not shipped (pre-publication issue 334).
  (declare dialect-known? (String -> Boolean))
  (define (dialect-known? name)
    (match (dialect-from name)
      ((Some _) True)
      ((None) False)))

  ;; Guarded by DIALECT-KNOWN?, which the CL shell calls first. The fallback branch is
  ;; unreachable from it and exists only because Coalton cannot signal -- keeping the
  ;; name-to-constructor mapping in ONE place is worth more than avoiding an unreachable
  ;; branch, because the alternative is the same mapping written again in CL, and two copies
  ;; of a mapping is how the two disagree about a name somebody adds later.
  (declare dialect-required (String -> Dialect))
  (define (dialect-required name)
    (match (dialect-from name)
      ((Some d) d)
      ((None) D-Sqlite)))

  ;; WHAT A BACKEND CAN DO WITH A TYPE, as a value rather than a string that always exists.
  ;; ADR-0001: the old signature was total, so "this backend cannot do this" was not
  ;; something the protocol declined to express -- it was something it COULD not express,
  ;; and an implementer adding a vector type could only write a string. Whatever they wrote
  ;; for the non-Postgres branch would have become the precedent, structurally rather than
  ;; through anyone's carelessness.
  (define-type Sql-Type
    (Native String)
    (Emulated String)
    Unsupported)

  (declare sql-type-tag (Sql-Type -> String))
  (define (sql-type-tag s)
    (match s
      ((Native _) "native")
      ((Emulated _) "emulated")
      ((Unsupported) "unsupported")))

  ;; The SQL, for the two cases that have any. Unsupported has none, which is why callers
  ;; must read the tag first -- and why this returns the empty string rather than inventing
  ;; a column type for a backend that cannot store the value.
  (declare sql-type-text (Sql-Type -> String))
  (define (sql-type-text s)
    (match s
      ((Native sql) sql)
      ((Emulated sql) sql)
      ((Unsupported) "")))

  ;; THE DIALECT IS MATCHED, NOT NAME-COMPARED (pre-publication issue 432, ADR-0003). This used to ask
  ;; `(== (dialect-name dialect) "postgres")': a two-way test on a three-constructor type,
  ;; put by rendering the closed type back into the open string it exists to replace. Both
  ;; consequences of that shape were real -- D-Xtdb took the SQLite arm and got INTEGER/TEXT
  ;; affinities for a backend that has no columns at all, and a fourth dialect would have
  ;; compiled silently into "not postgres". A `match' makes the compiler ask instead.
  (declare field-type-sql (Field-Type * Dialect -> Sql-Type))
  (define (field-type-sql ty dialect)
    "The SQL column type for TY under DIALECT, or the fact that there is none.

Every type in the current vocabulary is NATIVE on both RELATIONAL dialects -- which is
exactly why the old total signature looked correct for a year. The ADT is here for the types
that do not fit (pre-publication issue 142 binary, pre-publication issue 212 vector), so the first one to arrive cannot set the
precedent by accident."
    (match dialect
      ;; XTDB 2 IS SCHEMALESS: there is no column type to return and there never was one.
      ;; The name comparison made this arm "not postgres" and handed back SQLite's
      ;; affinities. Nothing reaches here on XTDB today -- schema-ddl and every ddl form
      ;; refuse it first -- which is exactly why a wrong answer here could sit unread for a
      ;; year. Unsupported is what ADR-0001 says to return when a backend cannot carry a
      ;; type, and XTDB cannot carry any of them AS A COLUMN.
      ((D-Xtdb) Unsupported)
      ((D-Postgres) (relational-column ty True))
      ((D-Sqlite) (relational-column ty False))))

  ;; Reached only for the two dialects that HAVE columns, which is what makes a Boolean an
  ;; honest question here rather than the collapsed one it replaced.
  (declare relational-column (Field-Type * Boolean -> Sql-Type))
  (define (relational-column ty pg)
    "The column type for TY on a relational dialect; PG selects Postgres over SQLite."
    (match ty
      ((FT-String) (Native "TEXT"))
      ((FT-Text) (Native "TEXT"))
      ((FT-Integer) (Native (if pg "BIGINT" "INTEGER")))
      ((FT-Float) (Native (if pg "DOUBLE PRECISION" "REAL")))
      ((FT-Boolean) (Native (if pg "BOOLEAN" "INTEGER")))
      ((FT-Uuid) (Native (if pg "UUID" "TEXT")))
      ((FT-Timestamp) (Native (if pg "TIMESTAMPTZ" "TEXT")))
      ((FT-Date) (Native (if pg "DATE" "TEXT")))
      ;; Both backends carry bytes natively, so neither needs Emulated and neither is
      ;; Unsupported. SQLite BLOB has no declared length; Postgres BYTEA is capped at
      ;; 1 GB, which is a ceiling the driver reports rather than something this expresses.
      ((FT-Binary) (Native (if pg "BYTEA" "BLOB")))
      ;; THE FIRST UNSUPPORTED IN THE VOCABULARY, and what ADR-0001 exists for. Postgres
      ;; carries it through pgvector; SQLite has no native vector and XTDB is schemaless.
      ;; Returning Unsupported rather than a TEXT column is the whole decision: a vector
      ;; stored as text is not a narrower vector, it is a column that silently cannot be
      ;; searched, which is the quiet degradation the ADR rejected.
      ;;
      ;; A ZERO WIDTH IS UNSUPPORTED EVERYWHERE, including Postgres. It means no
      ;; dimension was supplied, `vector(0)' is not a type pgvector accepts, and the
      ;; alternative is emitting SQL the backend rejects at migration time. The CL shell
      ;; refuses a dimension-less declaration with a better message than this; this is the
      ;; backstop for any path that reaches the type without going through it.
      ((FT-Vector n)
       (if (and pg (> n 0))
           (Native (<> "vector(" (<> (the String (into n)) ")")))
           Unsupported))))

  ;; The predicate ADR-0001 asks for, so production can assert what dev merely tolerated.
  (declare field-type-support (Field-Type * Dialect -> String))
  (define (field-type-support ty dialect)
    (sql-type-tag (field-type-sql ty dialect)))

  (declare field-type-from (String -> Field-Type))
  (define (field-type-from name)
    "Parse a type NAME to a Field-Type. Unknown names fall back to FT-String; the CL shell
validates the spelling up front (defschema), so the fallback is not reached in practice."
    (cond
      ((== name "string") FT-String)
      ((== name "text") FT-Text)
      ((or (== name "integer") (== name "int")) FT-Integer)
      ((== name "float") FT-Float)
      ((or (== name "boolean") (== name "bool")) FT-Boolean)
      ((== name "uuid") FT-Uuid)
      ((== name "timestamp") FT-Timestamp)
      ((== name "date") FT-Date)
      ;; "blob" is an alias for "binary" the way "int" is for "integer": SQLite spells it
      ;; BLOB and an app author reaching for a byte column is likely to type that.
      ((or (== name "binary") (== name "blob")) FT-Binary)
      ;; "vector" RESOLVES TO A ZERO WIDTH, which every dialect refuses. A name is not
      ;; enough to build this type -- the dimension lives in the declaration's options --
      ;; so any caller that reaches here with "vector" has skipped the shell that reads
      ;; them. Falling back to FT-String the way an unknown name does would emit a TEXT
      ;; column and lose the failure; this way the refusal arrives at migration time,
      ;; named. Asserted in the suite so nobody later "fixes" it into a default width.
      ((== name "vector") (FT-Vector 0))
      (True FT-String))))
