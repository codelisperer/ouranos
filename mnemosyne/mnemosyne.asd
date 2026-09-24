;;;; mnemosyne.asd --- system definition for Mnemosyne
;;;;
;;;; Mnemosyne: the bitemporal data layer for the codelisperer ecosystem -- an
;;;; Ecto-like schema/query DSL + migrations + connection, backend-neutral behind a
;;;; neutral protocol (the PostgreSQL wire protocol; XTDB 2, which speaks PG wire).
;;;; Named for the Titaness of memory (mother of the Muses): it remembers all of
;;;; history -- valid-time (when a fact was true) AND transaction-time (when the
;;;; system learned it). Typed core in Coalton (schema/query types); effectful
;;;; shell in CL (IO). Praxeon's *Kairos* (budgeted, bitemporal agent memory)
;;;; leverages and extends it.

(defsystem "mnemosyne"
  :description "The bitemporal data layer (Ecto-like) for Common Lisp / Coalton."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ("coalton"
               "aion/secret"      ; conn.lisp calls sec:reveal on the backend password
               "aion/log"       ; neutral logging facade (leftward dep: aion is left of mnemosyne)
               "aion/clock"     ; the monotonic clock + v6 ids behind mnemosyne/id (pre-publication issue 96)
               "aion/secret/types" ; the DB password as an opaque field, not a printable String (pre-publication issue 209)
               "alexandria"
               "dbi"            ; CL-DBI: the DB-independent API (the neutral substrate)
               "dbd-postgres"   ; PostgreSQL over the WIRE (cl-postgres, no libpq); XTDB 2 rides it
               "dbd-sqlite3"    ; SQLite for zero-ops local dev
               "cffi"           ; sqlite-library.lisp asks which file holds sqlite3_open (#129); already here via cl-sqlite
               "quri")          ; percent-decoding for DATABASE_URL (already in the tree, via hyperion)
  ;; NOT cl+ssl, deliberately. cl-postgres resolves it at connect time rather than at
  ;; load time, so TLS is available to any image whose APPLICATION depends on it, and
  ;; mnemosyne does not put OpenSSL -- a native library -- on the load path of every
  ;; image that touches a database. Same doctrine as pre-publication issue 139 for the HTTP server; the
  ;; failure it avoids is ADR-0011's (a bundle that dies on a missing .so).
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "backend")   ; typed neutral store protocol (Coalton)
                             (:file "field")     ; typed field-type vocabulary (Coalton)
                             (:file "field-shell") ; its refusals, as conditions (CL) -- pre-publication issue 334
                             (:file "entity")    ; typed entity metadata: DTO trait + touch (Coalton)
                             (:file "id")        ; time-ordered UUID/vid + touch! (CL)
                             (:file "url")       ; DATABASE_URL -> a typed Backend (CL)
                             (:file "param")     ; what a bound value MEANS, per backend
                             (:file "sqlite-library") ; which SQLite file is loaded, and its version (CL) -- #129
                             (:file "conn")      ; connect/exec/query/txn over CL-DBI (CL)
                             (:file "migrate")   ; the migration runner (CL)
                             (:file "query")     ; HoneySQL-style data->SQL builder (CL)
                             (:file "parse")     ; SQL string -> query data (inverse of sql)
                             (:file "derived")   ; staleness of a derived value (CL) -- ADR-0002
                             (:file "schema")    ; Ecto-style schema defs + DDL gen (CL)
                             (:file "ddl")       ; DDL as data: index/drop/alter per dialect (CL)
                             (:file "introspect") ; live table vs defschema: drift as data (CL)
                             (:file "changeset") ; cast + validate + bridge to queries (CL)
                             (:file "mnemosyne"))))
  :in-order-to ((test-op (test-op "mnemosyne/tests"))))


(defsystem "mnemosyne/examples/contacts/tests"
  :description "The contacts example's cast -> validate path (#94)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  ;; DEFINED HERE, WHILE THE APP IT TESTS IS NOT (pre-publication issue 357). `contacts' keeps its own
  ;; contacts.asd and its own cons.lisp deliberately: it is the `cons init contacts
  ;; --template cli' demo, and being a standalone project with its own .asd is the property
  ;; the example exists to demonstrate. So the app system is named for WHAT IT IS and stays
  ;; where it is; only this suite is named for WHERE IT LIVES.
  ;;
  ;; The asymmetry with `hyperion/examples/active-search' is therefore not an inconsistency
  ;; to tidy away: those examples are in-tree and not standalone, so they are named for
  ;; where they live. This one is not. Anyone "fixing" the difference would delete the
  ;; point of the example to make two names match.
  ;;
  ;; WHY THE NAME MATTERS AT ALL: `scripts/check-readme-counts.lisp' attributes a suite to a
  ;; framework by the segment before the first slash. As `contacts/tests' it answered
  ;; `contacts', which has no row in the README Status table, so its checks reached the
  ;; headline total without reaching any row and the table stopped summing to itself -- the
  ;; same signature klio produced. As `mnemosyne/examples/contacts/tests' it answers
  ;; `mnemosyne' and lands in that row, with no change to the checker.
  :depends-on ("contacts" "mnemosyne" "fiveam")  ; changeset-tests.lisp calls mnemosyne/changeset:
  :serial t
  :components ((:module "examples/contacts/tests"
                :serial t
                :components ((:file "changeset-tests"))))
  :perform (test-op (o c) (uiop:symbol-call :mnemosyne/examples/contacts/tests :run-tests)))

(defsystem "mnemosyne/tests"
  :description "Test suite for Mnemosyne."
  :depends-on ("mnemosyne" "aion/secret" "aion/clock" "aion/log" "fiveam")  ; entity.lisp and backends.lisp
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "query")
                             ;; backends FIRST after query (which defines the package):
                             ;; every suite below may be backend-parameterised, and the
                             ;; runner + coverage banner live here (pre-publication issue 176).
                             (:file "backends")
                             (:file "field-type")
                             (:file "schema")
                             (:file "ddl")
                             (:file "introspect")
                             (:file "entity")
                             (:file "url")
                             (:file "param")
                             (:file "sqlite-busy")
                             (:file "sqlite-library")
                             (:file "smoke"))))
  :perform (test-op (o c) (uiop:symbol-call :mnemosyne/tests :run-tests)))
