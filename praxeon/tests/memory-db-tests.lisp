;;;; memory-db-tests.lisp --- observational memory in a real database (#138).
;;;;
;;;; AGAINST A REAL POSTGRES WITH pgvector, or not at all. The whole claim is that
;;;; similarity recall works through mnemosyne against the backend the docs tell you to
;;;; deploy on; a suite that exercised it against SQLite would be testing a backend that
;;;; refuses the vector column outright, and one that mocked the database would be testing
;;;; the mock. Without MNEMOSYNE_TEST_PG_URL these skip and say so -- a skip that names its
;;;; reason is honest, a green that ran nothing is not.
;;;;
;;;; A FRESH TABLE PER RUN, never a reused one cleaned up afterwards. A fixture that cleans
;;;; up is RELYING on cleanup, and that dependency is invisible until the run where it did
;;;; not happen. The name carries the pid and a random suffix, so two runs cannot collide
;;;; even if one left its table behind.

(cl:defpackage #:praxeon/memory-db/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:mem #:praxeon/memory)
                    (#:mdb #:praxeon/memory-db)
                    (#:llm #:praxeon/llm)
                    (#:cnd #:praxeon/conditions)
                    (#:conn #:mnemosyne/conn)
                    (#:url #:mnemosyne/url)
                    (#:q #:mnemosyne/query))
  (:export #:run-tests))

(in-package #:praxeon/memory-db/tests)

;;; --- writing to memory in tests (#150) --------------------------------------
;;;
;;; Provenance is REQUIRED on every write, so every test that writes must supply one. These
;;; wrappers supply a fixed source so that the tests about supersession, budgets and erasure
;;; stay about those things rather than each acquiring a provenance argument that is noise
;;; to what they assert.
;;;
;;; THE REQUIREMENT ITSELF IS ASSERTED SEPARATELY, in the tests named for it. A helper that
;;; makes the common case easy would otherwise make the adversarial case easy too, and the
;;; adversarial case here is a write with no source at all -- which must stay refused.

(defun test-provenance (&optional (turn 1) (conversation "conv-test"))
  (mem:make-provenance conversation turn))

(defun remember* (store subject content &rest args)
  "MEM:REMEMBER with a test provenance."
  (apply #'mem:remember store subject content :provenance (test-provenance) args))

(defun supersede* (store observation content &rest args)
  "MEM:SUPERSEDE with a test provenance, in a LATER turn than the observation it replaces --
a correction happens after the thing it corrects, and the store records that rather than
inheriting the original's source."
  (apply #'mem:supersede store observation content :provenance (test-provenance 2) args))

(def-suite memory-db :description "Observational memory in a database, with similarity.")
(in-suite memory-db)

(defun run-tests ()
  "Run the suite, report its Postgres coverage for the gate, and return T on success.

Every test here uses Postgres, through WITH-STORE. Without MNEMOSYNE_TEST_PG_URL they all
skip, and a suite whose checks skip reports no failures, which reads as a pass. So this
prints a BACKEND-CHECKS line, the format scripts/verify-tree.lisp reads from mnemosyne's
suite: the number of checks that ran, or SKIPPED with the reason. The gate then fails the
run, or lists the gap under NOT COVERED when OURANOS_ALLOW_NO_PG excuses it (#171).

The number is every check that ran while Postgres was configured. That includes one check
that does not need it (that the in-memory store has no RECALL-SIMILAR method), so it is one
more than the checks that touched the database. The gate only asks whether it is above zero.
FIVEAM::TEST-SKIPPED is internal; FiveAM exports no way to tell a skip from a result."
  (let* ((url (%pg-url))
         (results (run 'memory-db)))
    (explain! results)
    (if url
        (format t "~&BACKEND-CHECKS postgres ~D~%"
                (count-if-not (lambda (r) (typep r 'fiveam::test-skipped)) results))
        (format t "~&BACKEND-CHECKS postgres SKIPPED (MNEMOSYNE_TEST_PG_URL is not set)~%"))
    (finish-output)
    (results-status results)))

;;; --- a deterministic embedder ----------------------------------------------

(defparameter +basis+
  '(("the member prefers mornings"      . 0)
    ("the member's budget is tight"     . 1)
    ("the member dislikes phone calls"  . 2)
    ("mornings suit the member best"    . 0))   ; same basis as the first: a near neighbour
  "Content -> basis index. AN EXPLICIT TABLE, NOT A HASH.

A hash would collide unpredictably at this width and the test would then pass or fail for a
reason no reader could see. Stated here, the geometry is part of the fixture: the first and
the last are the SAME direction, which is what makes `nearest' a meaningful question.")

(defclass basis-embedder (llm:embedding-provider) ())
(defmethod llm:embedding-dimensions ((p basis-embedder)) 4)
(defmethod llm:embedding-model-of ((p basis-embedder)) "basis")
(defmethod llm:embed ((p basis-embedder) text)
  (let ((v (make-array 4 :element-type 'double-float :initial-element 0.0d0))
        (i (or (cdr (assoc text +basis+ :test #'string=)) 3)))
    (setf (aref v i) 1.0d0)
    v))

;;; --- the fixture ------------------------------------------------------------

(defun %pg-url () (uiop:getenv "MNEMOSYNE_TEST_PG_URL"))

(defmacro with-store ((store-var) &body body)
  "A fresh table, a fresh store, and a connection that is closed afterwards."
  `(let ((url (%pg-url)))
     (if (not url)
         (skip "MNEMOSYNE_TEST_PG_URL is not set -- this says nothing about the backend")
         (let* ((table (format nil "praxeon_obs_~36R_~36R"
                               (sb-posix:getpid)
                               (random (expt 2 32) (make-random-state t))))
                (connection (conn:connect (url:backend-from-url url))))
           (unwind-protect
                (let ((,store-var (mdb:make-db-memory-store
                                   connection
                                   :embedder (make-instance 'basis-embedder)
                                   :table table :dialect :postgres :ensure t)))
                  ,@body)
             (ignore-errors
              (conn:exec connection (format nil "DROP TABLE IF EXISTS ~A" table)))
             (conn:disconnect connection))))))

;;; --- the tests --------------------------------------------------------------

(test the-schema-is-built-from-the-embedder-not-from-a-literal
  "#150: a schema hard-coding 1536 has hard-coded OpenAI's text-embedding-3-small.

The store's width comes from the injected provider, so a 4-wide test embedder produces a
4-wide column. A DEFSCHEMA could not have expressed that without knowing the deployment."
  ;; The checks are INSIDE WITH-STORE. When Postgres is absent it skips and returns FiveAM's
  ;; skip object; bound outside, that object was tested for truth and then passed to SOME,
  ;; which is how the suite errored instead of skipping (#171).
  (with-store (store)
    (let ((store-ddl (mdb::store-ddl store)))
      (is (some (lambda (s) (search "vector(4)" s)) store-ddl)
          "the CREATE TABLE must size the column from the embedder, got:~%~{~A~%~}" store-ddl)
      (is (some (lambda (s) (search "vector_cosine_ops" s)) store-ddl)
          "and the index must name the operator class that serves `<=>' (pre-publication issue 258)"))))

(test an-observation-round-trips-through-the-database
  (with-store (store)
    (let ((o (remember* store "member-1" "the member prefers mornings" :kind :preference)))
      (is (string= "member-1" (mem:observation-subject o)))
      (let ((back (mem:observations-of store "member-1")))
        (is (= 1 (length back)))
        (is (string= "the member prefers mornings" (mem:observation-content (first back))))
        (is (eq :preference (mem:observation-kind (first back)))
            "the kind must survive the round trip -- a correction is more reliable than an
observation and recall has to be able to tell them apart")))))

(test a-superseded-observation-stops-being-current-but-stays-readable
  "Supersession is not erasure: the old one is still there for an :as-of view, and that is
what makes a correction a replacement rather than a second opinion competing in a ranking."
  (with-store (store)
    (let* ((first-obs (remember* store "member-2" "the member prefers mornings"))
           (replacement (supersede* store first-obs "mornings suit the member best")))
      (is (string= (mem:observation-id replacement)
                   (mem:observation-superseded-by first-obs)))
      (let ((current (mem:observations-of store "member-2")))
        (is (= 1 (length current)) "only the replacement is current")
        (is (string= "mornings suit the member best" (mem:observation-content (first current)))))
      (let ((all (mem:observations-of store "member-2" :include-superseded t)))
        (is (= 2 (length all)) "and both are still there to be read")))))

(test recall-similar-ranks-by-distance-and-the-in-memory-store-has-no-such-method
  "THE POINT OF THE WHOLE SLICE, and the structural absence beside it.

Three observations in three directions; the query is the direction of one of them. The
nearest must come back first. The fixture's geometry is explicit in +BASIS+ rather than
emergent from a hash, so a reader can see why this is the right answer.

And RECALL-SIMILAR on an in-memory store is NOT an error message -- it is no applicable
method, because a store that cannot rank by distance must not quietly fall back to recency
and return plausible rows."
  (with-store (store)
    (remember* store "member-3" "the member prefers mornings")
    (remember* store "member-3" "the member's budget is tight")
    (remember* store "member-3" "the member dislikes phone calls")
    (let* ((embedder (make-instance 'basis-embedder))
           (query (llm:embed embedder "the member's budget is tight")))
      ;; LIMIT 1 tests the DATABASE's ranking with nothing else in the way. Asserting the
      ;; order of a larger result would test `ctx:assemble' as well, which emits
      ;; chronologically on purpose -- and an assertion that fails for two possible reasons
      ;; tells you neither.
      (let ((nearest (mem:recall-similar store "member-3" query :budget 1000 :limit 1)))
        (is (= 1 (length nearest)))
        (is (search "budget" (praxeon/context:ctx-item-content (first nearest)))
            "the single nearest row must be the one sharing the query's direction, got: ~S"
            (mapcar #'praxeon/context:ctx-item-content nearest)))
      ;; And proximity must survive the BUDGET, which selects by value. Before the rank was
      ;; carried into value, the database's ranking was computed and then discarded here,
      ;; so a distant observation could displace the nearest and the answer still looked
      ;; plausible. A budget with room for one item is what exposes that.
      (let ((tight (mem:recall-similar store "member-3" query :budget 8 :limit 3)))
        (is (= 1 (length tight)) "a budget with room for one must return one, got ~D"
            (length tight))
        (is (search "budget" (praxeon/context:ctx-item-content (first tight)))
            "and the one it keeps must be the NEAREST, not whichever the ranking dropped: ~S"
            (mapcar #'praxeon/context:ctx-item-content tight)))))
  (is-false (compute-applicable-methods
             #'mem:recall-similar
             (list (mem:make-in-memory-store) "s" (vector 1.0d0)))
            "an in-memory store must have NO method rather than a fallback"))

(test a-query-vector-of-the-wrong-width-is-refused-before-it-reaches-the-database
  "The width guard applies to the SEARCH ARGUMENT, not only to stored rows.

Same cast, same refusal. A wrong-width query is the same misconfiguration as a wrong-width
row, and it should not arrive at Postgres to be refused there in the language of columns."
  (with-store (store)
    (remember* store "member-4" "the member prefers mornings")
    (signals error
      (mem:recall-similar store "member-4"
                          (make-array 7 :element-type 'double-float :initial-element 1.0d0)))))

(test erasure-removes-the-rows-including-from-the-historical-view
  "#150: a memory store without a defensible erasure story is a liability an app cannot fix
later. Erasure is not a tombstone -- :include-superseded must not find them either."
  (with-store (store)
    (let ((o (remember* store "member-5" "the member prefers mornings")))
      (supersede* store o "mornings suit the member best"))
    (is (= 2 (length (mem:observations-of store "member-5" :include-superseded t))))
    (is (= 2 (mem:forget-subject store "member-5")) "both rows are removed")
    (is (null (mem:observations-of store "member-5" :include-superseded t))
        "and nothing survives in the historical view")))

(test provenance-round-trips-through-the-database-columns
  "Stored as REAL COLUMNS, not a blob: `which conversation' has to be answerable as a query,
so a member disputing one claim can be shown everything else from the same turn."
  (with-store (store)
    (mem:remember store "member-6" "the member prefers mornings"
                  :provenance (mem:make-provenance "conv-xyz" 4 :at 999))
    (let ((back (first (mem:observations-of store "member-6"))))
      (is (string= "conv-xyz" (mem:provenance-conversation (mem:observation-provenance back))))
      (is (= 4 (mem:provenance-turn (mem:observation-provenance back))))
      (is (= 999 (mem:provenance-at (mem:observation-provenance back)))))))

(test an-unrecorded-source-time-comes-back-absent-rather-than-zero
  "NIL means the source time was not recorded; 0 would be a time. The database round trip is
where that distinction is easiest to lose, because a NULL integer column and a 0 look the
same to anything that coerces."
  (with-store (store)
    (mem:remember store "member-7" "the member's budget is tight"
                  :provenance (mem:make-provenance "conv-xyz" 4))
    (let ((back (first (mem:observations-of store "member-7"))))
      (is (null (mem:provenance-at (mem:observation-provenance back)))
          "an unrecorded source time must survive as NIL, got ~S"
          (mem:provenance-at (mem:observation-provenance back)))
      (is (= 4 (mem:provenance-turn (mem:observation-provenance back)))
          "while the turn, which WAS recorded, is still there"))))

(test provenance-is-read-from-the-columns-not-parsed-out-of-the-content
  "#138's HARD RULE, asserted rather than trusted:

  > The traceable provenance is never reconstructed from the rendered text. A passage's
  > document, version and locator come from what retrieval returned, and from nothing else.

The content here contains a plausible-looking citation that contradicts the columns. A code
path that parsed provenance back out of prose would return the decoy; the columns are the
record. This is the only arrangement that can tell the two apart -- content and columns
agreeing would pass either way."
  (with-store (store)
    (mem:remember store "member-8"
                  "the member prefers mornings (conversation conv-DECOY, turn 99)"
                  :provenance (mem:make-provenance "conv-real" 1))
    (let ((p (mem:observation-provenance (first (mem:observations-of store "member-8")))))
      (is (string= "conv-real" (mem:provenance-conversation p))
          "the columns are the record; the prose is not, got ~S"
          (mem:provenance-conversation p))
      (is (= 1 (mem:provenance-turn p))))))

(test a-database-write-with-no-provenance-is-refused-before-it-embeds
  "The refusal is the same for both stores, and it happens BEFORE the embedding call -- so a
write with no source costs nothing and, more to the point, cannot half-succeed by spending a
provider call and then failing at the insert."
  (with-store (store)
    (signals cnd:missing-provenance
      (mem:remember store "member-9" "no source"))
    (is (null (mem:observations-of store "member-9"))
        "and nothing was written")))

(test the-database-store-cites-the-same-way-the-in-memory-one-does
  "One constructor, so the two stores cannot disagree about whether an item is citable.

Both had their own inline ctx-item construction before #150; a citation added to one and
not the other gives a caller a store whose items can be cited and another whose cannot,
for no reason they could predict. Asserted on the DATABASE store because it is the one
whose items make a round trip through columns first."
  (with-store (store)
    (mem:remember store "member-10" "the member prefers mornings"
                  :provenance (mem:make-provenance "conv-db" 7 :at 424242))
    (let* ((items (mem:recall store "member-10" :budget 1000))
           (source (praxeon/context:ctx-item-source (first items))))
      (is (= 1 (length items)))
      (is-true source "a recalled item from the database must carry its source")
      (let ((p (mem:observation-provenance source)))
        (is (string= "conv-db" (mem:provenance-conversation p)))
        (is (= 7 (mem:provenance-turn p)))
        (is (= 424242 (mem:provenance-at p))
            "including the source time, through the column round trip")))))

(test a-similarity-recall-is-citable-too
  "RECALL-SIMILAR goes through a different path -- a SQL distance ranking rather than the
budgeted list -- so it needs its own assertion. A citable `recall' and an uncitable
`recall-similar' is the shape this would fail in."
  (with-store (store)
    (mem:remember store "member-11" "the member's budget is tight"
                  :provenance (mem:make-provenance "conv-sim" 2))
    (let* ((query (llm:embed (make-instance 'basis-embedder) "the member's budget is tight"))
           (items (mem:recall-similar store "member-11" query :budget 1000 :limit 3)))
      (is (plusp (length items)))
      (let ((source (praxeon/context:ctx-item-source (first items))))
        (is-true source "a similarity-recalled item must carry its source too")
        (is (string= "conv-sim"
                     (mem:provenance-conversation (mem:observation-provenance source))))))))
