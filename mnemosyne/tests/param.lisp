;;;; tests/param.lisp --- NULL vs boolean false at the bind boundary (#165).
;;;;
;;;; The bug this pins was reported as failing inserts, but the failing half was the SAFE
;;;; half. On Postgres a NIL bound to a numeric column raised 22P02 and stopped; a NIL bound
;;;; to a TEXT column stored the four characters "false", committed, and broke every later
;;;; `WHERE ... IS NULL` silently. An app could pass its whole suite on SQLite and corrupt
;;;; data on deploy.
;;;;
;;;; READ THIS BEFORE "SIMPLIFYING" THE ASYMMETRY BELOW.
;;;;
;;;; These tests are deliberately lopsided PER BACKEND, and it is not a compromise. SQLITE
;;;; WAS ALREADY CORRECT for NULL -- measured: it stores NIL as SQL NULL and `IS NULL`
;;;; matches. So the NULL half cannot be made to fail on SQLite; there is no red-before to
;;;; produce there, and asserting it on SQLite is a regression guard, not a reproduction.
;;;;
;;;; The BOOLEAN half is the opposite: :TRUE and :FALSE both errored on SQLite before this
;;;; module existed (the driver refuses a non-scalar bind value), so those assertions were
;;;; genuinely red here.
;;;;
;;;; WHAT CHANGED IN #176: the reproduction is no longer out of reach. The round-trip tests
;;;; below run under WITH-EACH-BACKEND, so when MNEMOSYNE_TEST_PG_URL names a reachable
;;;; server they execute on Postgres too -- where the NULL half IS the reproduction and
;;;; goes genuinely red against the pre-#165 mapping. When the variable is unset they run
;;;; on SQLite alone and the run says so loudly, rather than reporting a green that quietly
;;;; covers one engine. See tests/backends.lisp.
;;;;
;;;; Do not delete the NULL assertions for being un-failable on SQLite. They are the guard
;;;; that stops someone "simplifying" mnemosyne/param back into the bug, on the backend
;;;; where it does not bite, for the app that deploys to the one where it does.

(cl:in-package #:mnemosyne/tests)

(in-suite mnemosyne)

;;; --- the mapping, per driver, without needing either database ---------------
;;;
;;; NORMALIZE is a pure function of (value, driver), so the Postgres column of the truth
;;; table is testable on a machine with no Postgres. What it cannot prove is that
;;; cl-postgres then does what its source says with those values -- that is the app's
;;; round trip, and this is not a substitute for it.

(test param-postgres-mapping
  ;; Sourced from cl-postgres/sql-string.lisp: :null -> "NULL", t -> "true", nil -> "false".
  (is (eq :null (mnemosyne/param:to-driver nil :postgres))
      "NIL must become SQL NULL -- rendering it as the literal false IS the bug")
  (is (eq :null (mnemosyne/param:to-driver :null :postgres)))
  (is (eq t (mnemosyne/param:to-driver :true :postgres)))
  (is (eq t (mnemosyne/param:to-driver t :postgres)))
  ;; :FALSE -> NIL is correct, not a relapse: cl-postgres renders NIL as "false", which is
  ;; right when the column IS boolean. The defect was the overloading, not this mapping.
  (is (eq nil (mnemosyne/param:to-driver :false :postgres)))
  ;; ordinary values pass through untouched
  (is (= 42 (mnemosyne/param:to-driver 42 :postgres)))
  (is (string= "x" (mnemosyne/param:to-driver "x" :postgres))))

(test param-sqlite-mapping
  ;; SQLite stores booleans as integers and already treats NIL as NULL.
  (is (eq nil (mnemosyne/param:to-driver nil :sqlite3)))
  (is (eq nil (mnemosyne/param:to-driver :null :sqlite3))
      "the explicit spelling must reach SQLite as its existing NULL, not as a keyword")
  (is (= 1 (mnemosyne/param:to-driver :true :sqlite3)))
  (is (= 0 (mnemosyne/param:to-driver :false :sqlite3)))
  ;; T errored on SQLite before this -- a portable query could not write boolean true at all
  (is (= 1 (mnemosyne/param:to-driver t :sqlite3)))
  (is (= 42 (mnemosyne/param:to-driver 42 :sqlite3))))

(test param-unknown-driver-stays-conservative
  ;; An unrecognised driver must not have a literal invented for it that it will reject.
  (is (eq nil (mnemosyne/param:to-driver nil :some-future-driver)))
  (is (= 1 (mnemosyne/param:to-driver :true :some-future-driver))))

(test param-vocabulary-predicates
  ;; The one thing about this module worth remembering: NIL is NULL, not false.
  (is (mnemosyne/param:null-value-p nil))
  (is (mnemosyne/param:null-value-p :null))
  (is (not (mnemosyne/param:false-value-p nil))
      "NIL must NOT read as boolean false -- that overloading is the bug")
  (is (mnemosyne/param:false-value-p :false))
  (is (mnemosyne/param:true-value-p t))
  (is (mnemosyne/param:true-value-p :true)))

(test param-to-driver-params-is-non-destructive
  (let* ((original (list nil :true "x"))
         (copy (copy-list original))
         (out (mnemosyne/param:to-driver-params original :postgres)))
    (is (equal copy original) "the caller's parameter list must not be mutated")
    (is (equal (list :null t "x") out))))

;;; --- the round trip, on the backend this machine has -----------------------
;;;
;;; The shape triage asked for: insert, read back, assert. On SQLite the NULL half is a
;;; guard (it already passed before the fix) and the boolean half is a genuine repair.

;;; The helpers are backend-NEUTRAL, and that constraint did real work here (#176).
;;;
;;; The previous versions asserted through SQLite's `typeof()`, which Postgres does not
;;; have. Reaching for `pg_typeof` per backend would have preserved the shape and missed
;;; the point: storage type is not what an application depends on. What it depends on is
;;; whether the value MEANS absent when it comes back -- so these assert `IS NULL` in SQL
;;; and NULL-ness in Lisp, which are the same question asked on both sides of the wire and
;;; are sayable on every backend.

(defun %col (conn id column)
  (getf (first (mnemosyne/conn:query
                conn (format nil "SELECT ~A AS v FROM param_t WHERE id = ~D" column id)))
        :|v|))

(defun %sql-null-p (conn id column)
  "Does SQL itself consider (ID, COLUMN) NULL? Asked as a predicate rather than by
inspecting a storage type, because `IS NULL` is the operator applications actually use and
is spelled identically on every backend."
  (plusp (or (getf (first (mnemosyne/conn:query
                           conn (format nil "SELECT (~A IS NULL) AS v FROM param_t WHERE id = ~D"
                                        column id)))
                   :|v|)
             0)))

(defun %fresh-table (conn)
  "A clean param_t on any backend.

DROP first, not `CREATE TABLE IF NOT EXISTS`: SQLite's `:memory:` is empty at every connect
but a real Postgres is not, so a suite that only created would run its second test against
the first test's rows. That is the kind of shared state that makes a suite pass for reasons
nobody chose."
  (mnemosyne/conn:exec conn "DROP TABLE IF EXISTS param_t")
  (mnemosyne/conn:exec conn
    "CREATE TABLE param_t (id integer primary key, note text, num bigint, flag boolean)"))

(test null-round-trips-as-sql-null-not-as-the-string-false
  ;; On SQLite this is a GUARD: SQLite already stored NIL as NULL, so it cannot go red here.
  ;; On Postgres it is the REPRODUCTION -- before #165 the text column held the four
  ;; characters "false", `IS NULL` stopped matching, and the suite could not see it because
  ;; the suite could not reach Postgres. That is this ticket in one test.
  (with-each-backend (c)
    (%fresh-table c)
    (mnemosyne/query:run c (list :insert-into "param_t"
                                 :values (list (list :id 1 :note nil :num nil)))
                         :dialect *current-dialect*)
    (is* (%sql-null-p c 1 "note")
         "a NIL text value must be SQL NULL, not the four characters \"false\"")
    (is* (%sql-null-p c 1 "num"))
    (is* (null (%col c 1 "note"))
         "and it must read back as CL NIL -- (null (getf row :x)) is how apps test absence")
    ;; the predicate the silent corruption actually broke
    (is* (= 1 (length (mnemosyne/conn:query c "SELECT id FROM param_t WHERE note IS NULL")))
         "WHERE ... IS NULL must match the row -- this is what stopped working silently")))

(test explicit-null-is-the-same-as-nil
  (with-each-backend (c)
    (%fresh-table c)
    (mnemosyne/query:run c (list :insert-into "param_t"
                                 :values (list (list :id 1 :note :null)))
                         :dialect *current-dialect*)
    (is* (%sql-null-p c 1 "note"))))

(test booleans-round-trip-and-are-distinguishable-from-null
  ;; The control. False must survive as false, or a "fix" that turned every boolean into
  ;; NULL would look like a pass on the test above.
  (with-each-backend (c)
    (%fresh-table c)
    (mnemosyne/query:run c (list :insert-into "param_t"
                                 :values (list (list :id 1 :flag :true)
                                               (list :id 2 :flag :false)
                                               (list :id 3 :flag nil)))
                         :dialect *current-dialect*)
    (is* (eql 1 (%col c 1 "flag")) "boolean true must store as true")
    (is* (eql 0 (%col c 2 "flag")) "boolean false must store as FALSE, not as NULL")
    (is* (not (%sql-null-p c 2 "flag"))
         "false is a value, so SQL must not consider the column null")
    (is* (%sql-null-p c 3 "flag")
         "and NIL in the same column must still mean NULL -- the split is the point")))

(test cl-t-can-now-write-boolean-true
  ;; A second, unreported bug closed by the same change: T errored on SQLite and worked on
  ;; Postgres, so a portable query could not write boolean true at all.
  (with-each-backend (c)
    (%fresh-table c)
    (mnemosyne/query:run c (list :insert-into "param_t" :values (list (list :id 1 :flag t)))
                         :dialect *current-dialect*)
    (is* (eql 1 (%col c 1 "flag")))))

(test a-nullable-numeric-insert-succeeds
  ;; The LOUD half of the #165 report, and the half only Postgres can show: there this
  ;; raised `invalid input syntax for type bigint: "false"` (22P02) and 6 of 12 operations
  ;; failed outright. On SQLite it always passed.
  (with-each-backend (c)
    (%fresh-table c)
    (finishes (mnemosyne/query:run c (list :insert-into "param_t"
                                           :values (list (list :id 1 :num nil)))
                                   :dialect *current-dialect*))
    (is* (%sql-null-p c 1 "num"))))

(test integers-are-never-reinterpreted-as-booleans
  ;; Deliberate, and a hard limit rather than a preference: this layer cannot see the column
  ;; type, so a bound 0 is indistinguishable from a genuine integer zero. Folding 0/1 into
  ;; the boolean vocabulary would silently rewrite a value the caller did write -- a new
  ;; instance of the bug this module removes. (Postgres coerces 0 in a boolean column to
  ;; false on its own; that is the engine's leniency to grant, not ours to imitate.)
  (dolist (driver '(:postgres :sqlite3))
    (is (eql 0 (mnemosyne/param:to-driver 0 driver)) "0 must stay an integer on ~A" driver)
    (is (eql 1 (mnemosyne/param:to-driver 1 driver))))
  (is (not (mnemosyne/param:false-value-p 0)) "0 is not the boolean-false spelling")
  (is (not (mnemosyne/param:true-value-p 1))  "1 is not the boolean-true spelling")
  ;; and an integer zero survives a round trip into an integer column as a number
  (with-each-backend (c)
    (%fresh-table c)
    (mnemosyne/query:run c (list :insert-into "param_t" :values (list (list :id 1 :num 0)))
                         :dialect *current-dialect*)
    (is* (eql 0 (%col c 1 "num")))
    (is* (not (%sql-null-p c 1 "num"))
         "an integer zero is a value, not an absence -- the collapse this guards against")))

;;; --- the read direction ----------------------------------------------------
;;;
;;; Fixing writes alone left the mirror-image defect, and the more dangerous half. A NULL
;;; read back as :NULL on Postgres and NIL on SQLite, so an app that could finally WRITE a
;;; portable NULL still could not READ one -- and since :NULL is truthy while NIL is not,
;;; every `(when (getf row :field) ...)` inverted. A consuming app hit it as
;;; `(null (getf row :valid-until))` returning false for every current row, which is
;;; `WHERE ... IS NULL` silently ceasing to match, one layer up in Lisp.
;;;
;;; ON THE ASYMMETRY BELOW, AGAIN: the SQLite assertions are pass-through checks, not
;;; reproductions. SQLite already returns NULL as NIL and booleans as 1/0 -- that is exactly
;;; why 1/0 was chosen as the target shape, being the only one reachable on both backends.
;;; The Postgres mapping is the part that repairs anything, and it is a pure function here
;;; precisely so it is testable on a machine with no Postgres.

(test read-postgres-null-becomes-nil
  ;; The whole point: :NULL is cl-postgres' spelling, not mnemosyne's, and it must not reach
  ;; application code -- `(null :NULL)` is false, which is how a predicate silently inverts.
  (is (eq nil (mnemosyne/param:from-driver :null :postgres)))
  (is (null (mnemosyne/param:from-driver :null :postgres))
      "it must satisfy NULL, since (null (getf row :x)) is how apps test for absence"))

(test read-postgres-booleans-become-integers
  ;; 1/0 rather than T/:FALSE because it is the only shape reachable on BOTH backends:
  ;; SQLite has no boolean type and its driver exposes column names only, so a boolean 1
  ;; there cannot be told from an integer 1 and cannot be rewritten without guessing.
  (is (eql 1 (mnemosyne/param:from-driver t :postgres)))
  (is (eql 0 (mnemosyne/param:from-driver nil :postgres))
      "boolean false must NOT collapse into NULL -- cl-postgres distinguishes them and so must we"))

(test read-false-and-null-stay-distinguishable
  ;; The failure this ordering exists to prevent. Map :NULL to NIL without moving boolean
  ;; false off NIL and the two collapse -- re-introducing on the read side the exact
  ;; ambiguity the write side just removed.
  (let ((null-read (mnemosyne/param:from-driver :null :postgres))
        (false-read (mnemosyne/param:from-driver nil :postgres)))
    (is (not (eql null-read false-read))
        "SQL NULL and boolean false must remain different values after normalisation")
    (is (null null-read))
    (is (eql 0 false-read))))

(test read-sqlite-values-pass-through-untouched
  ;; SQLite already produces the target shape, which is why no existing SQLite reader moves.
  (dolist (value (list nil 0 1 42 "x"))
    (is (equal value (mnemosyne/param:from-driver value :sqlite3))
        "~S must be unchanged on SQLite" value)))

(test read-ordinary-values-are-not-touched-on-either-backend
  (dolist (driver '(:postgres :sqlite3))
    (is (= 42 (mnemosyne/param:from-driver 42 driver)))
    (is (string= "false" (mnemosyne/param:from-driver "false" driver))
        "a genuine string \"false\" must survive -- it is data, not a sentinel")))

(test read-row-translates-values-and-leaves-keys-alone
  (let ((row (mnemosyne/param:from-driver-row
              (list :|id| 1 :|note| :null :|flag| t :|other| nil) :postgres)))
    (is (equal (list :|id| 1 :|note| nil :|flag| 1 :|other| 0) row))))

(test read-rows-on-sqlite-returns-the-same-object
  ;; The common path must not allocate a copy of every result set for nothing.
  (let ((rows (list (list :|a| 1) (list :|a| 2))))
    (is (eq rows (mnemosyne/param:from-driver-rows rows :sqlite3)))))

(test the-predicate-that-broke-works-again
  ;; The application-level shape, reduced: a row whose nullable column is NULL must satisfy
  ;; the is-it-set test apps actually write. Reproduced against a Postgres-shaped row rather
  ;; than a live server, since the defect is in the value, not the wire.
  (let ((pg-row (mnemosyne/param:from-driver-row (list :|id| 1 :|valid-until| :null) :postgres)))
    (is (null (getf pg-row :|valid-until|))
        "(null (getf row :valid-until)) must be TRUE for a current row -- this returning
         false for every row is what inserted a duplicate and tripped a unique index")))

(test a-round-trip-through-both-directions-preserves-meaning
  ;; write then read, on the Postgres mapping, for each member of the vocabulary
  (flet ((round-trip (v) (mnemosyne/param:from-driver
                          (mnemosyne/param:to-driver v :postgres) :postgres)))
    (is (null (round-trip nil))   "NULL written is NULL read")
    (is (null (round-trip :null)) "explicit NULL likewise")
    (is (eql 1 (round-trip :true)))
    (is (eql 1 (round-trip t)))
    (is (eql 0 (round-trip :false)) "false survives as false, not as NULL")))

;;; --- binary columns survive the drivers (#142) -----------------------------
;;;
;;; #142 called this half "the real work" and warned that "Postgres BYTEA in particular has
;;; its own escaping". Measured before writing any of it: both drivers already bind and
;;; return (unsigned-byte 8) vectors unchanged, so the column type was the whole change and
;;; this suite is what keeps that true rather than what made it true.
;;;
;;; The bytes are chosen to break the plausible wrong implementations rather than to be
;;; pretty. 0 is the C string terminator; 255 is not valid UTF-8 on its own; 39 and 92 are
;;; an apostrophe and a backslash, which is what a value spliced into SQL rather than bound
;;; would break on; 13 and 10 are CR and LF, which a text-mode round-trip would translate.

(defparameter +probe-bytes+
  (make-array 8 :element-type '(unsigned-byte 8)
                :initial-contents '(0 255 39 92 13 10 128 65))
  "Bytes that a string round-trip, a text-mode translation, or SQL splicing would each
corrupt differently.")

(defun %fresh-blob-table (conn)
  "A clean blob_t on any backend, with the byte column type WRITTEN OUT LITERALLY.

Deliberately not `(column-sql (field-type-from \"binary\") ...)', which is what this first
did. Deriving the fixture's DDL from the function under test makes the test a producer
checking its own output: mapping binary to TEXT by mistake would also create a TEXT column
here, and both drivers round-trip octets through one well enough that the test stayed green.
The control caught it -- six assertions went red under that injection and this was not among
them. The column type each backend really has belongs in the test, spelled out, so this
asserts that bytes survive a byte column rather than that two functions agree."
  (conn:exec conn "DROP TABLE IF EXISTS blob_t")
  (conn:exec conn
             (format nil "CREATE TABLE blob_t (id integer primary key, payload ~A)"
                     (if (eq *current-dialect* :postgres) "BYTEA" "BLOB"))))

(test octets-round-trip-through-a-binary-column-unchanged
  "The whole point of the type. Every byte back, in order, as octets rather than a string."
  (with-each-backend (c)
    (%fresh-blob-table c)
    (q:run c (list :insert-into "blob_t" :values (list (list :id 1 :payload +probe-bytes+)))
           :dialect *current-dialect*)
    (let* ((rows (q:fetch c (list :select '(:payload) :from '("blob_t")
                                  :where (list := :id 1))
                          :dialect *current-dialect*))
           (got (second (first rows))))
      (is* (vectorp got) "expected a vector back, got ~S" (type-of got))
      (is* (and (vectorp got) (subtypep (array-element-type got) '(unsigned-byte 8)))
           "expected octets back, got element type ~S"
           (and (vectorp got) (array-element-type got)))
      (is* (equalp +probe-bytes+ got)
           "bytes changed in the round trip: sent ~S, got ~S" +probe-bytes+ got))))

(test an-empty-blob-is-distinct-from-sql-null
  "Zero bytes and no value are different answers, and a driver that conflated them would
make an absent avatar indistinguishable from a deliberately blank one."
  (with-each-backend (c)
    (%fresh-blob-table c)
    (let ((empty (make-array 0 :element-type '(unsigned-byte 8))))
      (q:run c (list :insert-into "blob_t" :values (list (list :id 1 :payload empty)))
             :dialect *current-dialect*)
      (q:run c (list :insert-into "blob_t" :values (list (list :id 2 :payload nil)))
             :dialect *current-dialect*))
    (is* (not (%sql-null-p* c 1 "payload")) "an empty blob must not be SQL NULL")
    (is* (%sql-null-p* c 2 "payload") "an absent blob must be SQL NULL")))

(defun %sql-null-p* (conn id column)
  "%SQL-NULL-P against blob_t. Same question, different table."
  (plusp (or (getf (first (conn:query
                           conn (format nil "SELECT (~A IS NULL) AS v FROM blob_t WHERE id = ~D"
                                        column id)))
                   :|v|)
             0)))

;;; --- vector search against a real pgvector (#258) --------------------------
;;;
;;; EVERYTHING ABOVE IS RENDERING, and rendering is a producer checking its own output: it
;;; proves we emitted the operator we meant to, not that Postgres accepts it or that a
;;; vector comes back. These run the SQL.
;;;
;;; They need the pgvector extension, which is why docker-compose.test.yml carries
;;; pgvector/pgvector:pg17 rather than postgres:17-alpine. Where the extension is absent
;;; they SKIP WITH A NAMED REASON rather than passing: a skip is coverage this run does not
;;; have, and the summary has to say so. Today that is the macOS and Windows CI legs, which
;;; provision Postgres by Homebrew and by the runner's preinstalled service and never see
;;; that compose file -- #371 covers macOS; Windows is a documented exclusion.

(defun %pgvector-available-p (conn)
  "Is the pgvector extension installable on this server?

Asked of pg_available_extensions rather than pg_extension: the question is whether the
server HAS it, not whether this database happens to have run CREATE EXTENSION already."
  (plusp (or (getf (first (conn:query
                           conn "select count(*) as n from pg_available_extensions where name = 'vector'"))
                   :|n|)
             0)))

(defmacro %with-pgvector ((conn) &body body)
  "Bind CONN to a Postgres connection with the vector extension created, or skip.

The skip reason names the host and the consequence, in the form verify-tree prints, so a
green run on a leg without pgvector says what it did not cover."
  `(let ((url (test-pg-url)))
     (if (null url)
         (skip "no ~A: vector operator and index coverage needs a Postgres (#258)"
               +pg-url-var+)
         (let ((,conn (conn:connect (mnemosyne/url:backend-from-url url))))
           (unwind-protect
                (if (not (%pgvector-available-p ,conn))
                    (skip "no pgvector on this host: the extension is not available, so operator and index coverage is Linux-only (#258, macOS #371)")
                    (progn
                      (conn:exec ,conn "CREATE EXTENSION IF NOT EXISTS vector")
                      ,@body))
             (conn:disconnect ,conn))))))

(defun %fresh-vector-table (conn)
  (conn:exec conn "DROP TABLE IF EXISTS vec_t")
  (conn:exec conn "CREATE TABLE vec_t (id integer primary key, embedding vector(3))")
  (dolist (row '((1 "[1,0,0]") (2 "[0,1,0]") (3 "[0.9,0.1,0]")))
    (conn:exec conn (format nil "INSERT INTO vec_t VALUES (~D, '~A')" (first row) (second row)))))

(test a-distance-query-actually-runs-and-returns-the-nearest-row
  "The claim the rendering tests cannot make: Postgres accepts this SQL and the ordering
means what it is supposed to mean. Row 1 is [1,0,0]; row 3 is [0.9,0.1,0] and is nearer to
it than row 2, which is orthogonal."
  (%with-pgvector (c)
    (%fresh-vector-table c)
    (let ((rows (handler-bind ((q:unindexed-vector-distance #'muffle-warning))
                  (q:fetch c (list :select '(:id) :from '("vec_t")
                                   :order-by (list (list (list :<-> :embedding "[1,0,0]")))
                                   :limit 2)
                           :dialect :postgres))))
      (is (= 2 (length rows)) "expected two rows, got ~S" rows)
      (is (= 1 (second (first rows))) "the query vector's own row should be nearest")
      (is (= 3 (second (second rows)))
          "[0.9,0.1,0] is nearer to [1,0,0] than the orthogonal [0,1,0]; got ~S" rows))))

(test all-three-distance-operators-are-accepted-by-postgres
  "Each is a real pgvector operator, not a string we invented that happens to parse."
  (%with-pgvector (c)
    (%fresh-vector-table c)
    (dolist (op '(:<-> :<=> :<#>))
      (let ((rows (handler-bind ((q:unindexed-vector-distance #'muffle-warning))
                    (q:fetch c (list :select '(:id) :from '("vec_t")
                                     :order-by (list (list (list op :embedding "[1,0,0]")))
                                     :limit 1)
                             :dialect :postgres))))
        (is (= 1 (length rows)) "~A did not run: ~S" op rows)))))

(test the-generated-vector-index-ddl-is-accepted-by-postgres
  "The DDL tests assert the string. This asserts pgvector accepts it -- an operator class
that does not exist, or a WITH option that is not an option, fails only here."
  (%with-pgvector (c)
    (%fresh-vector-table c)
    (finishes
      (conn:exec c (ddl:ddl '(:create-index :name :idx_vec_cos :on :vec_t
                              :columns (:embedding)
                              :using :hnsw :opclass :vector_cosine_ops
                              :with (:m 16 :ef_construction 64))
                            :dialect "postgres")))
    (finishes
      (conn:exec c (ddl:ddl '(:create-index :name :idx_vec_l2 :on :vec_t
                              :columns (:embedding)
                              :using :ivfflat :opclass :vector_l2_ops :with (:lists 1))
                            :dialect "postgres")))
    (is (= 2 (or (getf (first (conn:query c "select count(*) as n from pg_indexes where tablename='vec_t' and indexname like 'idx_vec_%'")) :|n|) 0))
        "both indexes should exist on the server")))

;;; MOVED HERE FROM tests/query.lisp, and the move is a load-order fact rather than a
;;; tidiness preference. These need TEST-PG-URL and +PG-URL-VAR+, which tests/backends.lisp
;;; defines -- and mnemosyne.asd loads query BEFORE backends, so compiling them there
;;; produced `undefined variable: +PG-URL-VAR+'. The suite still passed and still reported
;;; 532 checks; the gate is what caught it, because verify-tree reads the child's output for
;;; `caught WARNING' rather than trusting the exit code.

;;; --- an extension's precondition, against a real server (#258) --------------
;;;
;;; The rendering tests in ddl.lisp prove we emit the statement we meant to. These ask a
;;; server the two questions a deployment actually has: does it OFFER the extension, and has
;;; this database CREATED it. Reporting the second when asked the first is how a fresh
;;; database looks like an unsupported server.

(defmacro %with-pg-conn ((conn) &body body)
  "Bind CONN to a Postgres connection, or skip with a named reason."
  `(let ((url (test-pg-url)))
     (if (null url)
         (skip "no ~A: extension preconditions need a Postgres (#258)" +pg-url-var+)
         (let ((,conn (conn:connect (mnemosyne/url:backend-from-url url))))
           (unwind-protect (progn ,@body)
             (conn:disconnect ,conn))))))

(test an-extension-the-server-does-not-offer-is-absent-not-unprivileged
  "The negative direction, and the one that needs no privileges to test: a name no server
carries. The two failures have two different fixes -- an install versus a role -- so
reporting both as `no pgvector' sends half the readers to the wrong place."
  (%with-pg-conn (c)
    (is-false (mig:extension-available-p c "mnemosyne_no_such_extension")
              "the server does not offer it")
    (is-false (mig:extension-present-p c "mnemosyne_no_such_extension")
              "and this database has not created it")
    (handler-case (progn (mig:require-extension c "mnemosyne_no_such_extension")
                         (fail "require-extension must refuse an extension the server lacks"))
      (mig:extension-unavailable (e)
        (is (eq :absent (mig:extension-unavailable-reason e))
            "absent, not unprivileged -- the fix is an install, not a role")
        (is (search "mnemosyne_no_such_extension" (princ-to-string e))
            "and the message names the extension")))))

(test requiring-pgvector-creates-it-once-and-is-idempotent
  "What a migration calls. Idempotent so every migration that depends on the extension can
ask for it, rather than one having to run first and the rest assuming."
  (%with-pg-conn (c)
    (if (not (%pgvector-available-p c))
        (skip "no pgvector on this host: extension-creation coverage is Linux-only (#258, macOS #371)")
        (progn
          (is (string= "vector" (string-downcase (string (mig:require-extension c "vector")))))
          (is-true (mig:extension-present-p c "vector")
                   "and it is present in this database afterwards")
          (is (string= "vector" (string-downcase (string (mig:require-extension c "vector"))))
              "a second call is a no-op rather than an error")))))

(test the-two-questions-about-an-extension-are-different-questions
  "`pg_available_extensions' answers what the server offers; `pg_extension' answers what this
database has. A precondition that asked the second would report a fresh database as an
unsupported server, which is the wrong fix for the wrong problem."
  (%with-pg-conn (c)
    (if (not (%pgvector-available-p c))
        (skip "no pgvector on this host (#258, macOS #371)")
        (progn
          (conn:exec c "DROP EXTENSION IF EXISTS vector CASCADE")
          (is-true (mig:extension-available-p c "vector")
                   "the server still offers it after the database drops it")
          (is-false (mig:extension-present-p c "vector")
                    "while the database no longer has it -- the two answers have diverged,
which is the whole point of asking the right one")
          (mig:require-extension c "vector")
          (is-true (mig:extension-present-p c "vector") "and requiring it puts it back")))))

;;; --- the changeset path reaching a real vector column (#258) -----------------
;;;
;;; The cast tests in schema.lisp prove what `cast' produces. This proves POSTGRES ACCEPTS
;;; IT -- a producer checking its own output cannot see a producer/consumer disagreement, and
;;; the disagreement here is precisely the one that was found by measurement: a bound Lisp
;;; list arrives as `{1.0,0.0,0.0}' and is refused, which no rendering test could have shown.

(sch:defschema vec-row (:table "vec_cs_t")
  (:id        :integer :primary t)
  (:embedding :vector  :dimensions 3))

(test a-vector-inserted-through-the-changeset-path-is-accepted-and-comes-back
  (%with-pgvector (c)
    (conn:exec c "DROP TABLE IF EXISTS vec_cs_t")
    (conn:exec c (sch:schema-ddl (sch:find-schema 'vec-row) :dialect "postgres"))
    ;; :POSTGRES here and "postgres" above, deliberately: schema-ddl takes the string
    ;; spelling and the query module takes the keyword. Writing the string here is what found
    ;; %CHECK-DIALECT -- it took the SQLite branch and reported that Postgres has no vector
    ;; column type, to a test running on Postgres.
    (let ((cs (cs:cast 'vec-row (list :id 1 :embedding (list 1.0d0 0.5d0 0.0d0))
                       '(:id :embedding))))
      (is-true (cs:changeset-valid-p cs) "errors: ~S" (cs:changeset-errors cs))
      (is (= 1 (cs:insert! cs c :dialect :postgres))
          "Postgres accepts the literal cast produced -- which a rendering test cannot say"))
    (let ((row (first (conn:query c "SELECT embedding FROM vec_cs_t WHERE id = 1"))))
      (is (string= "[1,0.5,0]" (second row))
          "and the value that comes back is the one that went in, as pgvector prints it"))
    ;; The loop closed: a distance query over a row this path inserted.
    (let ((rows (handler-bind ((q:unindexed-vector-distance #'muffle-warning))
                  (q:fetch c (list :select '(:id) :from '("vec_cs_t")
                                   :order-by (list (list (list :<=> :embedding "[1,0.5,0]")))
                                   :limit 1)
                           :dialect :postgres))))
      (is (= 1 (length rows)) "the row is findable by nearest-neighbour search")
      (is (eql 1 (second (first rows)))))))

(test a-wrong-width-vector-never-reaches-the-database
  "The point of casting at the edge: the refusal happens before any SQL runs, so the error
names the schema rather than the column."
  (%with-pgvector (c)
    (conn:exec c "DROP TABLE IF EXISTS vec_cs_t")
    (conn:exec c (sch:schema-ddl (sch:find-schema 'vec-row) :dialect "postgres"))
    (let ((cs (cs:cast 'vec-row (list :id 2 :embedding (list 1.0 0.0)) '(:id :embedding))))
      (is-false (cs:changeset-valid-p cs))
      (signals error (cs:insert! cs c :dialect :postgres)))
    (is (zerop (second (first (conn:query c "SELECT count(*) FROM vec_cs_t"))))
        "nothing was written")))

;;; --- reading a column out of a row (#489) ----------------------------------
;;;
;;; The rows here are built with INTERN rather than written as `:|content|', because that is
;;; what the driver does and a literal would let a reader assume the case is incidental.

(defun %driver-row (&rest pairs)
  "A row the way a driver hands one over: column keys interned LOWERCASE."
  (loop for (name value) on pairs by #'cddr
        collect (intern (string-downcase (string name)) :keyword)
        collect value))

(test row-value-folds-case-because-the-driver-interns-lowercase
  "THE DEFECT THIS EXISTS FOR. A row arrives as (:|content| \"hi\"), so `(getf row :content)'
looks up :|CONTENT|, misses, and returns the default -- silently, because an absent column
and an empty string are the same answer to every caller that does not compare content."
  (let ((row (%driver-row :content "hi" :tokens 3)))
    (is (string= "hi" (mnemosyne/param:row-value row :content)))
    (is (= 3 (mnemosyne/param:row-value row :tokens)))
    (is (null (getf row :content))
        "the control: plain GETF must still miss, or this test is about nothing")))

(test row-value-signals-for-a-column-that-is-not-there
  "A MISS SIGNALS, and that is the half that generalises. Case is one spelling hazard and
there will be others; a reader that refuses to answer about a column it cannot find is loud
for all of them, including the ones nobody has thought of yet."
  (let ((row (%driver-row :content "hi")))
    (signals mnemosyne/param:unknown-column (mnemosyne/param:row-value row :nope))
    (handler-case (progn (mnemosyne/param:row-value row :nope) (fail "expected a signal"))
      (mnemosyne/param:unknown-column (c)
        (is (eq :nope (mnemosyne/param:unknown-column-key c)))
        (is (member :|content| (mnemosyne/param:unknown-column-available c))
            "the condition must name what IS there -- a reader who misspelt a column needs
to see the spelling that exists, not just that theirs does not")))))

(test row-value-does-not-fold-a-hyphen-into-an-underscore
  "DELIBERATE, and the reason is that the alternative builds a second vocabulary.

MNEMOSYNE/DDL's %IDENT does not quote identifiers -- a keyword becomes a bare word -- so
`:valid-until' is emitted as `valid-until', which Postgres reads as a subtraction. A
hyphenated column cannot be DECLARED through mnemosyne, so accepting one on READ would give
callers a read spelling with no write counterpart. That is the two-vocabulary defect
ADR-0003 has just finished removing from the dialect, rebuilt one module over."
  (let ((row (%driver-row :valid_until 42)))
    (is (= 42 (mnemosyne/param:row-value row :valid_until))
        "the SQL spelling works")
    (signals mnemosyne/param:unknown-column
      (mnemosyne/param:row-value row :valid-until))))

(test row-value-tells-an-absent-column-from-a-null-one
  "THE DISTINCTION THAT WAS NOT AVAILABLE BEFORE, and the reason the signal is worth its cost.

A column that is present and NULL is a fact about the row; a column that is not there is a
fact about the QUERY. They were the same answer -- NIL -- and that is why praxeon/memory-db
read every column back as its default while every count assertion passed."
  (let ((row (%driver-row :superseded_by nil :content "hi")))
    (is (null (mnemosyne/param:row-value row :superseded_by))
        "a NULL column answers NIL and must not signal")
    (signals mnemosyne/param:unknown-column
      (mnemosyne/param:row-value row :superseded_at))))

(test row-value-if-missing-is-the-escape-for-a-caller-that-expects-absence
  "For the caller who genuinely expects a column to be missing -- an older catalog, a table
this code did not create. Stated at the call site rather than by weakening the default."
  (let ((row (%driver-row :content "hi")))
    (is (null (mnemosyne/param:row-value row :nope :if-missing nil)))
    (is (eq :gone (mnemosyne/param:row-value row :nope :if-missing :gone)))
    (is (string= "hi" (mnemosyne/param:row-value row :content :if-missing :gone))
        "and it must not change the found case")))
