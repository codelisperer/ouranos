;;;; memory-db-tests.lisp --- observational memory in a real database (#138, #425).
;;;;
;;;; AGAINST REAL DATABASES: Postgres with pgvector, and SQLite (#425). The suite runs once
;;;; per backend. On Postgres it needs MNEMOSYNE_TEST_PG_URL, and without it every test skips
;;;; and says so -- a skip that names its reason is honest, a green that ran nothing is not.
;;;; SQLite needs nothing, so it always runs, in a fresh database file per test. A test about
;;;; something only Postgres has (the vector extension) skips on SQLite and says why.
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
                    (#:be #:mnemosyne/backend)
                    (#:mig #:mnemosyne/migrate)
                    (#:param #:mnemosyne/param)
                    (#:q #:mnemosyne/query)
                    (#:obs #:praxeon/observe)
                    (#:distil #:praxeon/distil)
                    (#:ctx #:praxeon/context))
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

(defvar *backend* :postgres
  "Which backend the suite is running on: :POSTGRES or :SQLITE (#425).")

(defun %sqlite-p () (eq *backend* :sqlite))

(defun run-tests ()
  "Run the suite on each backend, report each backend's coverage for the gate, and return T
on success.

Every test uses a database, through WITH-STORE. On Postgres, without MNEMOSYNE_TEST_PG_URL
they all skip, and a suite whose checks skip reports no failures, which reads as a pass. So
this prints a BACKEND-CHECKS line per backend, the format scripts/verify-tree.lisp reads from
mnemosyne's suite: the number of checks that ran, or SKIPPED with the reason. The gate then
fails the run, or lists the gap under NOT COVERED when OURANOS_ALLOW_NO_PG excuses it (#171).

Each number is every check that ran on that backend. That includes one check that needs no
database (that the in-memory store has no RECALL-SIMILAR method), so it is one more than the
checks that touched the database. The gate only asks whether it is above zero.
FIVEAM::TEST-SKIPPED is internal; FiveAM exports no way to tell a skip from a result."
  (let* ((url (%pg-url))
         (results (let ((*backend* :postgres)) (run 'memory-db)))
         (sqlite-results (let ((*backend* :sqlite)) (run 'memory-db))))
    (explain! (append results sqlite-results))
    (flet ((ran (rs) (count-if-not (lambda (r) (typep r 'fiveam::test-skipped)) rs)))
      (if url
          (format t "~&BACKEND-CHECKS postgres ~D~%" (ran results))
          (format t "~&BACKEND-CHECKS postgres SKIPPED (MNEMOSYNE_TEST_PG_URL is not set)~%"))
      (format t "~&BACKEND-CHECKS sqlite ~D~%" (ran sqlite-results))
      ;; Which SQLite file those checks ran against, and its version, in the line
      ;; scripts/verify-tree.lisp reads (#129).
      (format t "~&SQLITE-LIBRARY ~A~%" (mnemosyne/sqlite-library:describe-loaded-library)))
    (finish-output)
    (and (results-status results) (results-status sqlite-results))))

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

(defun %fresh-sqlite-file ()
  (merge-pathnames (format nil "praxeon-memory-~36R-~36R.db" (sb-posix:getpid)
                           (random (expt 2 40) (make-random-state t)))
                   (uiop:temporary-directory)))

(defun %delete-sqlite-files (file)
  (dolist (suffix '("" "-journal" "-wal" "-shm"))
    (let ((f (probe-file (concatenate 'string (namestring file) suffix))))
      (when f (delete-file f)))))

(defmacro with-store ((store-var &optional (embedder '(make-instance 'basis-embedder)))
                      &body body)
  "A fresh table, a fresh store over EMBEDDER, and a connection that is closed afterwards.
On SQLite the table is in a fresh database file, deleted afterwards."
  `(if (%sqlite-p)
       (let ((file (%fresh-sqlite-file)))
         (unwind-protect
              (let ((connection (conn:connect (be:make-sqlite (namestring file)))))
                (unwind-protect
                     (let ((,store-var (mdb:make-db-memory-store
                                        connection :embedder ,embedder
                                                   :table "praxeon_observations"
                                                   :dialect :sqlite :ensure t)))
                       ,@body)
                  (conn:disconnect connection)))
           (%delete-sqlite-files file)))
   (let ((url (%pg-url)))
     (if (not url)
         (skip "MNEMOSYNE_TEST_PG_URL is not set -- this says nothing about the backend")
         (let* ((table (format nil "praxeon_obs_~36R_~36R"
                               (sb-posix:getpid)
                               (random (expt 2 32) (make-random-state t))))
                (connection (conn:connect (url:backend-from-url url))))
           (unwind-protect
                (let ((,store-var
                        (progn
                          ;; The store no longer creates the extension (#138). The test role
                          ;; is privileged, so it plays the cluster administrator here.
                          (mig:require-extension connection "vector") (mdb:make-db-memory-store
                                   connection
                                   :embedder ,embedder
                                   :table table :dialect :postgres :ensure t))))
                  ,@body)
             (ignore-errors
              (conn:exec connection (format nil "DROP TABLE IF EXISTS ~A" table)))
             (ignore-errors
              (conn:exec connection (format nil "DROP TABLE IF EXISTS ~A_progress" table)))
             (conn:disconnect connection)))))))

;;; --- the tests --------------------------------------------------------------

;;; A database that has never had the extension installed. The test database has it by now,
;;; so the absence is made in a scratch database, which is dropped afterwards.

(defun %url-with-database (url database)
  "URL with its database name replaced by DATABASE."
  (let* ((query (position #\? url))
         (slash (position #\/ url :end query :from-end t)))
    (concatenate 'string (subseq url 0 (1+ slash)) database (if query (subseq url query) ""))))

(defmacro with-scratch-database ((conn-var) &body body)
  "Bind CONN-VAR to a connection to a new, empty database, dropped afterwards. Skips when
there is no Postgres, or when the test role cannot create a database."
  (let ((admin (gensym "ADMIN")) (name (gensym "NAME")) (made (gensym "MADE")))
    `(let ((url (%pg-url)))
       (if (not url)
           (skip "MNEMOSYNE_TEST_PG_URL is not set -- this says nothing about the backend")
           (let* ((,name (string-downcase (format nil "praxeon_scratch_~36R" (random (expt 2 40) (make-random-state t)))))
                  (,admin (conn:connect (url:backend-from-url url)))
                  (,made nil))
             (unwind-protect
                  (if (not (ignore-errors (conn:exec ,admin (format nil "CREATE DATABASE ~A" ,name))
                                          (setf ,made t)))
                      (skip "the test role cannot create a database, so a database without the extension cannot be made here")
                      (let ((,conn-var (conn:connect (url:backend-from-url
                                                      (%url-with-database url ,name)))))
                        (unwind-protect (progn ,@body)
                          (conn:disconnect ,conn-var))))
               (when ,made
                 (ignore-errors (conn:exec ,admin (format nil "DROP DATABASE ~A" ,name))))
               (conn:disconnect ,admin)))))))

(test ensure-schema-reports-a-missing-extension-instead-of-creating-it
  "#138: on a managed Postgres the application's role cannot run CREATE EXTENSION, so the
store checks pg_extension and signals a condition naming the database. Afterwards the
extension is still absent, which shows the store did not try to create it. Control: once it
is installed, ENSURE-SCHEMA succeeds."
  (if (%sqlite-p)
      (skip "Postgres only: the vector extension")
  (with-scratch-database (c)
    (let ((store (mdb:make-db-memory-store c :embedder (make-instance 'basis-embedder)
                                             :table "praxeon_noext_obs")))
      (handler-case (progn (mdb:ensure-schema store) (fail "expected VECTOR-EXTENSION-MISSING"))
        (cnd:vector-extension-missing (e)
          (is (search "praxeon_scratch_" (cnd:vector-extension-missing-database e)))))
      (is-false (mig:extension-present-p c "vector") "the store did not create it")
      (mig:require-extension c "vector")
      (is (eq store (mdb:ensure-schema store)))))))

(test the-schema-is-built-from-the-embedder-not-from-a-literal
  "#150: a schema hard-coding 1536 has hard-coded OpenAI's text-embedding-3-small.

The store's width comes from the injected provider, so a 4-wide test embedder produces a
4-wide column. A DEFSCHEMA could not have expressed that without knowing the deployment."
  ;; The checks are INSIDE WITH-STORE. When Postgres is absent it skips and returns FiveAM's
  ;; skip object; bound outside, that object was tested for truth and then passed to SOME,
  ;; which is how the suite errored instead of skipping (#171).
  ;;
  ;; ON SQLITE (#425) the column is text and there is no index, so the width is checked when a
  ;; vector is written or queried instead. This asserts the SQLite table's shape; the refusal is
  ;; asserted by A-QUERY-VECTOR-OF-THE-WRONG-WIDTH-IS-REFUSED-BEFORE-IT-REACHES-THE-DATABASE.
  (with-store (store)
    (let ((store-ddl (mdb::store-ddl store)))
      (if (%sqlite-p)
          (progn
            (is (= 2 (length store-ddl))
                "on SQLite, the observations table and the observer's progress table, and no index, got:~%~{~A~%~}" store-ddl)
            (is (notany (lambda (s) (search "vector" s :test #'char-equal)) store-ddl)
                "and no vector type, which SQLite does not have: ~{~A~%~}" store-ddl))
          (progn
            (is (some (lambda (s) (search "vector(4)" s)) store-ddl)
                "the CREATE TABLE must size the column from the embedder, got:~%~{~A~%~}" store-ddl)
            (is (some (lambda (s) (search "vector_cosine_ops" s)) store-ddl)
                "and the index must name the operator class that serves `<=>' (pre-publication issue 258)"))))))

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

(defclass call-recording-embedder (basis-embedder)
  ((calls :initform '() :accessor recorded-calls)))
(defmethod llm:embed-documents :before ((p call-recording-embedder) texts)
  (push (cons :documents texts) (recorded-calls p)))
(defmethod llm:embed-query :before ((p call-recording-embedder) text)
  (push (cons :query text) (recorded-calls p)))

(test remember-embeds-its-content-as-a-document
  "#286: a service like Voyage embeds documents and queries differently, so the store says
which one it is embedding. REMEMBER stores text to be searched later, which is a document."
  (let ((embedder (make-instance 'call-recording-embedder)))
    (with-store (store embedder)
      (remember* store "member-1" "the member prefers mornings")
      (is (equal '((:documents "the member prefers mornings")) (recorded-calls embedder))
          "one EMBED-DOCUMENTS call with the content, and no EMBED-QUERY"))))

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

;;; --- the thread scope and a provenance's range (#317) --------------------------------------------

(test a-thread-observation-round-trips-and-stays-out-of-the-subjects-facts
  "The thread and the window's last turn are columns, read back as written. A recall of the
subject's facts does not return a thread observation, and the reverse."
  (with-store (store)
    (mem:remember store "member-5" "Prefers mornings." :provenance (test-provenance))
    (mem:remember store "member-5" "Asked about the refund here." :thread "conv-7"
                  :provenance (mem:make-provenance "conv-7" 3 :through 9))
    (is (equal '("Prefers mornings.")
               (mapcar #'mem:observation-content (mem:observations-of store "member-5"))))
    (let ((o (first (mem:observations-of store "member-5" :thread "conv-7"))))
      (is (string= "Asked about the refund here." (mem:observation-content o)))
      (is (string= "conv-7" (mem:observation-thread o)))
      (is (= 3 (mem:provenance-turn (mem:observation-provenance o))))
      (is (= 9 (mem:provenance-through (mem:observation-provenance o))))
      (is (string= "conv-7" (mem:observation-thread
                             (supersede* store o "Asked about the refund twice.")))
          "a supersession stays in the thread"))
    (is (= 2 (length (mem:observations-of store "member-5" :thread :all))))))

(test ensure-schema-adds-the-thread-columns-to-a-table-made-before-them
  "A table made before #317 has no thread or source_through column. Every read fails on it, not
only a thread's, because a read of the subject's facts filters on THREAD IS NULL; that is why
the CHANGELOG says to run ENSURE-SCHEMA before reading. ENSURE-SCHEMA adds the columns, and the
row written before them reads back as a fact about its subject. Running it again changes
nothing."
  (with-store (store)
    (mem:remember store "member-6" "Written before the upgrade." :provenance (test-provenance))
    (dolist (column '("thread" "source_through"))
      (conn:exec (mdb::store-connection store)
                 (format nil "ALTER TABLE ~A DROP COLUMN ~A" (mdb:store-table store) column)))
    (signals error (mem:observations-of store "member-6") "a plain read fails before the upgrade")
    (mdb:ensure-schema store)
    (mdb:ensure-schema store)
    (is (equal '("Written before the upgrade.")
               (mapcar #'mem:observation-content (mem:observations-of store "member-6")))
        "the old row is a fact about its subject")
    (mem:remember store "member-6" "y" :thread "conv-1" :provenance (test-provenance))
    (is (= 1 (length (mem:observations-of store "member-6" :thread "conv-1"))))))

;;; --- the observer and distil's thread scope on the SQL store (#317) --------------------------

(defclass scripted-provider (llm:provider)
  ((replies :initarg :replies :accessor scripted-replies)))

(defmethod llm:complete ((p scripted-provider) messages &key system tools max-tokens temperature tool-choice)
  (declare (ignore messages system tools max-tokens temperature tool-choice))
  (or (pop (scripted-replies p)) (llm:make-completion :text "" :stop-reason :end)))

(defmethod llm:supports-tool-choice-p ((p scripted-provider)) t)

(defun %observations-call (&rest contents)
  "A completion whose record_observations call proposes CONTENTS, each a fact."
  (llm:make-completion
   :stop-reason :tool-use
   :tool-calls (list (llm:make-tool-call
                      :id "c1" :name "record_observations"
                      :arguments (let ((h (make-hash-table :test #'equal)))
                                   (setf (gethash "observations" h)
                                         (coerce (loop for c in contents
                                                       collect (let ((o (make-hash-table :test #'equal)))
                                                                 (setf (gethash "content" o) c (gethash "kind" o) "fact")
                                                                 o))
                                                 'vector))
                                   h)))))

(defun %chat (n)
  (loop for i from 1 to n
        collect (llm:msg (if (oddp i) "user" "assistant")
                         (format nil "message ~D: ~{~A~^ ~}" i (make-list 60 :initial-element "word")))))

(test the-observer-writes-a-threads-observations-to-the-sql-store
  "The observer against the SQL store: the window's observations land in the thread's scope with
their message range, the mark moves, and a new observer resumes from the stored mark."
  (with-store (store)
    (let* ((step (praxeon/prompt:messages-tokens (%chat 6)))
           (observer (obs:make-observer (make-instance 'scripted-provider
                                                       :replies (list (%observations-call "Has a dog." "Lives in Lisbon.")))
                                        store "member-8" "conv-9" :step step)))
      (obs:observe-turn observer (%chat 6))
      (is-true (obs:await-observer observer :timeout 20))
      (let ((written (mem:observations-of store "member-8" :thread "conv-9")))
        (is (equal '("Has a dog." "Lives in Lisbon.")
                   (sort (mapcar #'mem:observation-content written) #'string<)))
        (is (= 6 (mem:provenance-through (mem:observation-provenance (first written))))))
      (is (null (mem:observations-of store "member-8")) "nothing in the subject's facts")
      (is (= 6 (obs:observer-mark (obs:make-observer (make-instance 'scripted-provider :replies nil)
                                                     store "member-8" "conv-9" :step step)))
          "a new observer resumes from the mark the store holds"))))

(test apply-distillation-writes-into-a-thread-on-the-sql-store
  (with-store (store)
    (let ((d (distil:distil (make-instance 'scripted-provider :replies (list (%observations-call "Prefers mornings.")))
                            "member-9" (%chat 1))))
      (distil:apply-distillation store d :provenance (test-provenance) :thread "conv-3")
      (is (equal '("Prefers mornings.")
                 (mapcar #'mem:observation-content (mem:observations-of store "member-9" :thread "conv-3"))))
      (is (null (mem:observations-of store "member-9"))))))

(test recall-similar-keeps-to-one-scope
  "Similarity recall over a thread returns only that thread's observations, and over the subject
only the subject's facts. :ALL is refused, since a recall builds a prompt."
  (with-store (store)
    (mem:remember store "member-10" "the member prefers mornings" :provenance (test-provenance))
    (mem:remember store "member-10" "the member's budget is tight" :thread "conv-4" :provenance (test-provenance))
    (let ((query (llm:embed (make-instance 'basis-embedder) "the member prefers mornings")))
      (is (equal '("the member prefers mornings")
                 (mapcar #'ctx:ctx-item-content (mem:recall-similar store "member-10" query :limit 5))))
      (is (equal '("the member's budget is tight")
                 (mapcar #'ctx:ctx-item-content (mem:recall-similar store "member-10" query :limit 5 :thread "conv-4"))))
      (signals cnd:praxeon-error (mem:recall-similar store "member-10" query :thread :all))
      (signals cnd:praxeon-error (mem:recall store "member-10" :thread :all)))))

(test thread-progress-round-trips-and-is-erased-with-the-subject
  "The observer's progress on a thread, kept in its own table: replaced by each record, separate
per thread, and erased by FORGET-SUBJECT with the observations."
  (with-store (store)
    (is (null (mem:thread-progress store "member-12" "conv-1")) "nothing recorded yet")
    (mem:record-thread-progress store "member-12" "conv-1" 6 '((1 6 1)))
    (mem:record-thread-progress store "member-12" "conv-1" 12 '((1 6 2) (7 12 1)))
    (mem:record-thread-progress store "member-12" "conv-2" 3 '())
    (multiple-value-bind (mark skipped) (mem:thread-progress store "member-12" "conv-1")
      (is (= 12 mark))
      (is (equal '((1 6 2) (7 12 1)) skipped)))
    (multiple-value-bind (mark skipped) (mem:thread-progress store "member-12" "conv-2")
      (is (= 3 mark))
      (is (null skipped)))
    (mem:forget-subject store "member-12")
    (is (null (mem:thread-progress store "member-12" "conv-1")))
    (is (null (mem:thread-progress store "member-12" "conv-2")))))

(test supersede-refuses-an-observation-already-superseded-on-the-sql-store
  "The SQL store checks, under its lock and in the same transaction as its writes, that the
observation is still current, as the in-memory store does. A second supersession of the same
observation, from a copy that does not know about the first, is refused and writes nothing."
  (with-store (store)
    (let* ((porto (mem:remember store "member-13" "Lives in Porto." :provenance (test-provenance)))
           (stale (copy-structure porto)))
      (mem:supersede store porto "Lives in Lisbon." :provenance (test-provenance 2))
      (signals cnd:praxeon-error (mem:supersede store stale "Lives in Faro." :provenance (test-provenance 3)))
      (is (equal '("Lives in Lisbon.")
                 (mapcar #'mem:observation-content (mem:observations-of store "member-13")))))))

;;; --- after #462's third review ------------------------------------------------------------

(defclass slow-embedder (basis-embedder) ()
  (:documentation "Takes 0.6 s to embed a text beginning \"Slowly\", as a remote embedding model
would."))

(defmethod llm:embed :before ((p slow-embedder) text)
  (when (and (>= (length text) 6) (string= "Slowly" text :end2 6))
    (sleep 0.6)))

(test supersede-embeds-before-it-takes-the-stores-lock
  "A supersession whose embedding takes 0.6 s does not hold the store's lock meanwhile, so a
read made during it returns at once rather than waiting for the model."
  (with-store (store (make-instance 'slow-embedder))
    (let* ((porto (mem:remember store "member-14" "Lives in Porto." :provenance (test-provenance)))
           (worker (bt:make-thread (lambda ()
                                     (mem:supersede store porto "Slowly moved to Lisbon."
                                                    :provenance (test-provenance 2)))
                                   :name "supersede-test")))
      (sleep 0.15)
      (let ((began (get-internal-real-time)))
        (mem:observations-of store "member-14")
        (let ((waited (/ (- (get-internal-real-time) began) internal-time-units-per-second)))
          (is (< waited 0.3) "the read waited ~,3F s" waited)))
      (bt:join-thread worker)
      (is (equal '("Slowly moved to Lisbon.")
                 (mapcar #'mem:observation-content (mem:observations-of store "member-14")))))))

(test forget-subject-works-without-the-progress-table
  "An installation that added the two columns in its own migration but not the progress table,
which it needs only for praxeon/observe, can still erase a subject."
  (with-store (store)
    (mem:remember store "member-15" "Lives in Porto." :provenance (test-provenance))
    (conn:exec (mdb::store-connection store) (format nil "DROP TABLE ~A_progress" (mdb:store-table store)))
    (is (= 1 (mem:forget-subject store "member-15")))
    (is (null (mem:observations-of store "member-15")))))

(defvar *superseded-meanwhile* nil
  "The id of an observation INTERRUPTED-STORE marks superseded after its next REMEMBER.")

(defclass interrupted-store (mdb:db-memory-store) ()
  (:documentation "Marks *SUPERSEDED-MEANWHILE* superseded after a REMEMBER, as another process
superseding the same observation between SUPERSEDE's check and its update would."))

(defmethod mem:remember :after ((store interrupted-store) subject content
                                &key provenance kind value tokens valid-from thread)
  (declare (ignore subject content provenance kind value tokens valid-from thread))
  (when *superseded-meanwhile*
    (conn:exec (mdb::store-connection store)
               (format nil "UPDATE ~A SET superseded_by = 'obs-elsewhere' WHERE id = '~A'"
                       (mdb:store-table store) *superseded-meanwhile*))))

(test supersede-refuses-what-another-process-superseded-after-its-check
  "SUPERSEDE's UPDATE changes the row only while it is still current and must change one, so a
supersession that passed its check, and lost the row to another process before its update, is
refused and its replacement rolled back."
  (with-store (store)
    (let ((porto (mem:remember store "member-16" "Lives in Porto." :provenance (test-provenance))))
      (change-class store 'interrupted-store)
      (let ((*superseded-meanwhile* (mem:observation-id porto)))
        (signals cnd:praxeon-error
          (mem:supersede store porto "Lives in Lisbon." :provenance (test-provenance 2))))
      (change-class store 'mdb:db-memory-store)
      (is (equal '("Lives in Porto.")
                 (mapcar #'mem:observation-content
                         (mem:observations-of store "member-16" :include-superseded t)))
          "the replacement was rolled back"))))
