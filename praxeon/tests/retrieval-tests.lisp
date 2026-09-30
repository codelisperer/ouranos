;;;; retrieval-tests.lisp --- praxeon/retrieval against Postgres with pgvector, and SQLite (#138, #369).
;;;;
;;;; RETRIEVAL runs twice: on Postgres, which skips every test with the reason when
;;;; MNEMOSYNE_TEST_PG_URL is not set, and on SQLite, in a fresh database file per test. A test
;;;; about something only Postgres has (pgvector's extension and widths, advisory locks,
;;;; REPEATABLE READ) skips on SQLite and says so. Each Postgres test gets a fresh table, named
;;;; with the pid and a random suffix, and drops it after.
;;;; The embedder is a deterministic stand-in: the protocol, the width checks, the store and the
;;;; SQL are the real code.

(cl:defpackage #:praxeon/retrieval/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:rt #:praxeon/retrieval)
                    (#:rc #:praxeon/retrieval/corpus)
                    (#:llm #:praxeon/llm)
                    (#:cnd #:praxeon/conditions)
                    (#:ctx #:praxeon/context)
                    (#:actor #:praxeon/actor)
                    (#:ceiling #:praxeon/ceiling)
                    (#:conn #:mnemosyne/conn)
                    (#:url #:mnemosyne/url)
                    (#:be #:mnemosyne/backend)
                    (#:mig #:mnemosyne/migrate)
                    (#:param #:mnemosyne/param)
                    (#:q #:mnemosyne/query)
                    (#:bt #:bordeaux-threads)
                    (#:tt #:aion/test-threads)
                    (#:fusion #:praxeon/retrieval/fusion))
  (:export #:run-tests))

(in-package #:praxeon/retrieval/tests)

(def-suite retrieval :description "Document retrieval over corpora (#138).")
(in-suite retrieval)

(defun %pg-url () (uiop:getenv "MNEMOSYNE_TEST_PG_URL"))

(defvar *backend* :postgres
  "Which backend RETRIEVAL is running on: :POSTGRES or :SQLITE (#369).")

(defvar *sqlite-file* nil
  "The database file of the SQLite test running now, so a test's second connection opens the
same database.")

(defun %sqlite-p () (eq *backend* :sqlite))

(defmacro postgres-only ((reason) &body body)
  "BODY, except on SQLite, where the test skips and says what it is about."
  `(if (%sqlite-p)
       (skip "Postgres only: ~A" ,reason)
       (progn ,@body)))

(def-suite chunkers :description "Tests that need no database: the chunkers (#322) and the text the search means writes (#138).")

(defun run-tests ()
  "Run CHUNKERS, and RETRIEVAL on each backend, and print each backend's coverage in the form
scripts/verify-tree.lisp reads. On Postgres every check in RETRIEVAL needs the server, so a run
without it skips them all, and the BACKEND-CHECKS line is what keeps that from reading as a pass
(#171). CHUNKERS needs no database, so its checks are not counted in either line."
  (let* ((url (%pg-url))
         (chunker-results (run 'chunkers))
         (results (let ((*backend* :postgres)) (run 'retrieval)))
         (sqlite-results (let ((*backend* :sqlite)) (run 'retrieval))))
    (explain! (append chunker-results results sqlite-results))
    (flet ((ran (rs) (count-if-not (lambda (r) (typep r 'fiveam::test-skipped)) rs)))
      (if url
          (format t "~&BACKEND-CHECKS postgres ~D~%" (ran results))
          (format t "~&BACKEND-CHECKS postgres SKIPPED (MNEMOSYNE_TEST_PG_URL is not set)~%"))
      (format t "~&BACKEND-CHECKS sqlite ~D~%" (ran sqlite-results))
      ;; Which SQLite file those checks ran against, and its version, in the line
      ;; scripts/verify-tree.lisp reads (#129).
      (format t "~&SQLITE-LIBRARY ~A~%" (mnemosyne/sqlite-library:describe-loaded-library)))
    (finish-output)
    (and (results-status chunker-results) (results-status results)
         (results-status sqlite-results))))

;;; --- a deterministic embedder ------------------------------------------------------
;;;
;;; Four dimensions: how often a text mentions payouts, refunds and privacy, plus a constant so
;;; that no vector is zero, whose cosine distance is undefined. It records which call embedded
;;; what, so a test can see documents and queries arrive by different calls.

(defclass word-embedder (llm:embedding-provider)
  ((model :initarg :model :initform "words" :reader word-model)
   (width :initarg :width :initform 4 :reader word-width)
   (calls :initform '() :accessor recorded-calls)
   (before-documents :initarg :before-documents :initform nil :reader before-documents)))

(defmethod llm:embedding-dimensions ((p word-embedder)) (word-width p))
(defmethod llm:embedding-model-of ((p word-embedder)) (word-model p))

(defun %count-of (word text)
  (loop with start = 0
        for at = (search word text :start2 start :test #'char-equal)
        while at count t do (setf start (1+ at))))

(defmethod llm:embed ((p word-embedder) text)
  (let ((v (make-array (word-width p) :element-type 'double-float :initial-element 0.0d0)))
    (setf (aref v 0) (float (%count-of "payout" text) 1d0)
          (aref v 1) (float (%count-of "refund" text) 1d0)
          (aref v 2) (float (%count-of "privacy" text) 1d0)
          (aref v 3) 0.1d0)
    v))

(defmethod llm:embed-documents :before ((p word-embedder) texts)
  (push (cons :documents (length texts)) (recorded-calls p))
  (when (before-documents p) (funcall (before-documents p))))

(defmethod llm:embed-query :before ((p word-embedder) text)
  (push (cons :query text) (recorded-calls p)))

;;; --- fixtures ----------------------------------------------------------------------

(defun %table-name ()
  (string-downcase (format nil "praxeon_chunks_~36R_~36R" (sb-posix:getpid)
                           (random (expt 2 32) (make-random-state t)))))

(defun %connect ()
  (conn:connect (if (%sqlite-p)
                    (be:make-sqlite (namestring *sqlite-file*))
                    (url:backend-from-url (%pg-url)))))

(defun %fresh-sqlite-file ()
  (merge-pathnames (format nil "praxeon-retrieval-~36R-~36R.db" (sb-posix:getpid)
                           (random (expt 2 40) (make-random-state t)))
                   (uiop:temporary-directory)))

(defun %delete-sqlite-files (file)
  (dolist (suffix '("" "-journal" "-wal" "-shm"))
    (let ((f (probe-file (concatenate 'string (namestring file) suffix))))
      (when f (delete-file f)))))

(defmacro with-store ((store-var &key (dimensions 4) (table '(%table-name))) &body body)
  "A fresh chunk table and a store over it; the table is dropped afterwards. On SQLite the
table is in a fresh database file, deleted afterwards."
  (let ((c (gensym "CONN")) (tb (gensym "TABLE")))
    `(if (%sqlite-p)
         (let ((*sqlite-file* (%fresh-sqlite-file)))
           (unwind-protect
                (let ((,c (%connect)))
                  (unwind-protect
                       (let ((,store-var (rt:make-chunk-store ,c :table ,table
                                                                 :dimensions ,dimensions
                                                                 :ensure t)))
                         ,@body)
                    (conn:disconnect ,c)))
             (%delete-sqlite-files *sqlite-file*)))
     (if (not (%pg-url))
         (skip "MNEMOSYNE_TEST_PG_URL is not set -- this says nothing about the backend")
         (let* ((,tb ,table)
                (,c (%connect)))
           (unwind-protect
                (progn
                  ;; The store does not create the extension. The test role is privileged,
                  ;; so it plays the cluster administrator here.
                  (mig:require-extension ,c "vector")
                  (let ((,store-var (rt:make-chunk-store ,c :table ,tb :dimensions ,dimensions
                                                            :ensure t)))
                    ,@body))
             (ignore-errors (conn:exec ,c (format nil "DROP TABLE IF EXISTS ~A" ,tb)))
             (ignore-errors (conn:exec ,c (format nil "DROP TABLE IF EXISTS ~A_terms" ,tb)))
             (ignore-errors (conn:exec ,c (format nil "DROP TABLE IF EXISTS ~A_corpora" ,tb)))
             (conn:disconnect ,c)))))))

(defun sec (id text &rest keys &key (document-id "doc-1") (locale "en") &allow-other-keys)
  (apply #'rt:make-section :id id :text text :document-id document-id :locale locale
         :locator (format nil "§~A" id)
         (loop for (k v) on keys by #'cddr
               unless (member k '(:document-id :locale)) append (list k v))))

(defun ids (result)
  (mapcar (lambda (p) (rt:provenance-section-id (rt:passage-provenance p)))
          (rt:retrieval-result-passages result)))

(defun %drop-columns (store columns)
  "Drop COLUMNS from STORE's table, one statement each, since SQLite drops one per ALTER TABLE."
  (dolist (column columns)
    (conn:exec (rt:store-connection store)
               (format nil "ALTER TABLE ~A DROP COLUMN ~A" (rt:store-table store) column))))

(defun %column-count (store where-sql &rest params)
  (param:row-value (first (apply #'conn:query (rt:store-connection store)
                                 (format nil "SELECT count(*) AS n FROM ~A WHERE ~A"
                                         (rt:store-table store) where-sql)
                                 params))
                   :n))

(defparameter +policy+
  (list (sec "1" "A payout is sent on the first business day of the month.")
        (sec "2" "A refund is issued within 30 days of the request.")
        (sec "3" "Privacy: we never sell your data.")))

;;; --- the extension ------------------------------------------------------------------

(defun %url-with-database (url database)
  (let* ((query (position #\? url))
         (slash (position #\/ url :end query :from-end t)))
    (concatenate 'string (subseq url 0 (1+ slash)) database (if query (subseq url query) ""))))

(test ensure-schema-reports-a-missing-extension-instead-of-creating-it
  "On a managed Postgres the app's role cannot run CREATE EXTENSION, so ENSURE-SCHEMA reads
pg_extension and signals VECTOR-EXTENSION-MISSING, naming the database. The extension is still
absent afterwards. Control: once it is installed, the same call succeeds. Uses a scratch
database, because the test database already has the extension."
  (postgres-only ("the vector extension")
  (if (not (%pg-url))
      (skip "MNEMOSYNE_TEST_PG_URL is not set -- this says nothing about the backend")
      (let ((admin (%connect))
            (name (string-downcase (format nil "praxeon_scratch_~36R"
                                           (random (expt 2 40) (make-random-state t)))))
            (made nil))
        (unwind-protect
             (if (not (ignore-errors (conn:exec admin (format nil "CREATE DATABASE ~A" name))
                                     (setf made t)))
                 (skip "the test role cannot create a database here")
                 (let ((c (conn:connect (url:backend-from-url
                                         (%url-with-database (%pg-url) name)))))
                   (unwind-protect
                        (let ((store (rt:make-chunk-store c :dimensions 4)))
                          (handler-case (progn (rt:ensure-schema store)
                                               (fail "expected VECTOR-EXTENSION-MISSING"))
                            (cnd:vector-extension-missing (e)
                              (is (string= name (cnd:vector-extension-missing-database e)))))
                          (is-false (mig:extension-present-p c "vector"))
                          (mig:require-extension c "vector")
                          (is (eq store (rt:ensure-schema store))))
                     (conn:disconnect c))))
          (when made (ignore-errors (conn:exec admin (format nil "DROP DATABASE ~A" name))))
          (conn:disconnect admin))))))

;;; --- exact retrieval -------------------------------------------------------------------

(test exact-retrieval-works-on-a-corpus-that-was-never-embedded
  "Sync needs no provider, and exact retrieval does not reach the embedding path. Nothing in
this test creates an embedder, every embedding column is NULL, and the matches come back,
case-insensitively, from the text or the locator."
  (with-store (store)
    (let ((corpus (rt:make-corpus store "policy")))
      (rt:sync-corpus corpus +policy+)
      (is (= 3 (%column-count store "embedding IS NULL")) "nothing was embedded")
      (is (equal '("2") (ids (rt:retrieve-exact corpus "REFUND"))))
      (is (equal '("3") (ids (rt:retrieve-exact corpus "§3"))) "the locator is searched too")
      (is (equal '("1") (ids (rt:retrieve-exact corpus '("payout" "month"))))
          "every term must match")
      (is (null (ids (rt:retrieve-exact corpus '("payout" "refund"))))))))

(test exact-retrieval-matches-percent-and-underscore-literally
  "The caller's % and _ are escaped, so they match themselves. Control: the same text without
them is not matched by the escaped term."
  (with-store (store)
    (let ((corpus (rt:make-corpus store "fees")))
      (rt:sync-corpus corpus (list (sec "a" "a fee of 50% applies")
                                   (sec "b" "a fee of 50 dollars applies")
                                   (sec "c" "see field_name")
                                   (sec "d" "see fieldXname")))
      (is (equal '("a") (ids (rt:retrieve-exact corpus "50%"))))
      (is (equal '("c") (ids (rt:retrieve-exact corpus "field_name")))))))

(test exact-retrieval-says-when-the-limit-cut-it-off
  "LIMIT + 1 rows are fetched. More than LIMIT is TRUNCATED with reason :LIMIT; LIMIT or fewer
is COMPLETE, so `no more matches' means there are none."
  (with-store (store)
    (let ((corpus (rt:make-corpus store "policy")))
      (rt:sync-corpus corpus +policy+)
      (let ((cut (rt:retrieve-exact corpus "a" :limit 2))
            (whole (rt:retrieve-exact corpus "a" :limit 3)))
        (is (= 2 (length (rt:retrieval-result-passages cut))))
        (is (rt:truncated-p (rt:retrieval-result-completeness cut)))
        (is (eq :limit (rt:truncated-reason (rt:retrieval-result-completeness cut))))
        (is (= 3 (length (rt:retrieval-result-passages whole))))
        (is (rt:complete-p (rt:retrieval-result-completeness whole)))))))

;;; --- corpus isolation (the ruling's requirement) ------------------------------------------

(test the-corpus-predicate-is-bound-as-a-parameter
  "CORPUS-WHERE is the one place the predicate is written, and the corpus name is a bound
parameter, never part of the SQL text. A name with a quote in it shows that."
  (with-store (store)
    (let ((corpus (rt:make-corpus store "com'munity")))
      (multiple-value-bind (sql params)
          (q:sql (list :select '(:id) :from (list (rt:store-table store))
                       :where (rt:corpus-where corpus (list := :locale "en")))
                 :dialect :postgres)
        (is (search "corpus = ?" sql))
        (is-false (search "munity" sql) "the name is not in the SQL")
        (is (equal '("com'munity" "en") params)))
      (rt:sync-corpus corpus +policy+)
      (is (= 3 (length (rt:retrieval-result-passages (rt:retrieve-exact corpus "a"))))))))

(test two-corpora-with-the-same-text-never-see-each-other
  "Access is per corpus. Two corpora in one table hold the same text under different section
ids. Both retrieval calls are run against each corpus, and each returns only its own chunks: A
never sees B's, and B never sees A's."
  (with-store (store)
    (let* ((a (rt:make-corpus store "community-a"))
           (b (rt:make-corpus store "community-b"))
           (embedder (make-instance 'word-embedder)))
      (rt:sync-corpus a (list (sec "a-1" "A refund is issued within 30 days.")
                              (sec "a-2" "A payout is sent monthly.")))
      (rt:sync-corpus b (list (sec "b-1" "A refund is issued within 30 days.")
                              (sec "b-2" "A payout is sent monthly.")))
      (rt:embed-pending a embedder)
      (rt:embed-pending b embedder)
      (flet ((corpora-of (result)
               (remove-duplicates
                (mapcar (lambda (p) (rt:provenance-corpus (rt:passage-provenance p)))
                        (rt:retrieval-result-passages result))
                :test #'equal)))
        (let ((exact-a (rt:retrieve-exact a "refund"))
              (exact-b (rt:retrieve-exact b "refund"))
              (similar-a (rt:retrieve-similar a embedder "refund" :limit 10))
              (similar-b (rt:retrieve-similar b embedder "refund" :limit 10)))
          (is (equal '("a-1") (ids exact-a)))
          (is (equal '("b-1") (ids exact-b)))
          (is (equal '("a-1" "a-2") (ids similar-a)) "A's two chunks, nearest first, none of B's")
          (is (equal '("b-1" "b-2") (ids similar-b)) "B's two chunks, none of A's")
          (is (equal '("community-a") (corpora-of similar-a)))
          (is (equal '("community-b") (corpora-of similar-b))))))))

;;; --- sync --------------------------------------------------------------------------

(test a-sync-replaces-only-what-changed-and-keeps-other-embeddings
  "An unchanged section is not re-chunked and keeps its embedding. A changed one is replaced
and waits for EMBED-PENDING. A provenance-only change is updated in place and keeps its
embedding, because the embedding depends on the text alone."
  (with-store (store)
    (let ((corpus (rt:make-corpus store "policy"))
          (embedder (make-instance 'word-embedder)))
      (rt:sync-corpus corpus +policy+)
      (is (= 3 (rt:embed-pending corpus embedder)))
      (is (= 0 (rt:embed-pending corpus embedder)) "nothing is pending twice")
      (let ((report (rt:sync-document corpus "doc-1"
                                      (list (first +policy+)
                                            (sec "2" "A refund is issued within 14 days.")
                                            (sec "3" "Privacy: we never sell your data."
                                                 :document-version "v2")))))
        (is (= 1 (rt:sync-report-unchanged report)))
        (is (= 1 (rt:sync-report-replaced report)))
        (is (= 1 (rt:sync-report-updated report))))
      (is (= 1 (%column-count store "embedding IS NULL")) "only the edited section lost its vector")
      (is (= 1 (%column-count store "document_version = ? AND embedding IS NOT NULL" "v2")))
      (is (= 1 (rt:embed-pending corpus embedder))))))

(test a-sync-removes-what-it-was-not-given
  "SYNC-DOCUMENT removes the document's sections that are not in the list, and an empty list
removes the document. SYNC-CORPUS removes every document it was not given. Other documents are
untouched by SYNC-DOCUMENT."
  (with-store (store)
    (let ((corpus (rt:make-corpus store "policy")))
      (rt:sync-corpus corpus (append +policy+
                                     (list (sec "9" "Another document." :document-id "doc-2"))))
      (is (= 1 (rt:sync-report-removed
                (rt:sync-document corpus "doc-1" (subseq +policy+ 0 2)))))
      (is (= 3 (%column-count store "true")))
      (rt:sync-document corpus "doc-1" '())
      (is (= 1 (%column-count store "true")) "doc-2 is still there")
      (rt:sync-corpus corpus (list (sec "1" "Back." :document-id "doc-3")))
      (is (= 0 (%column-count store "document_id = ?" "doc-2")) "doc-2 was not handed in")
      (is (= 1 (%column-count store "true"))))))

(test an-invalid-section-writes-nothing
  "A section missing its text, a duplicate section, or a section of another document in a
SYNC-DOCUMENT is refused before anything is written."
  (with-store (store)
    (let ((corpus (rt:make-corpus store "policy")))
      (signals rt:invalid-section
        (rt:sync-corpus corpus (list (first +policy+) (rt:make-section :id "x" :document-id "d"
                                                                       :locale "en"))))
      (signals rt:invalid-section
        (rt:sync-corpus corpus (list (first +policy+) (first +policy+))))
      (signals rt:invalid-section
        (rt:sync-document corpus "doc-9" +policy+))
      (signals rt:invalid-section
        (rt:sync-corpus corpus (list (sec "t" "Traducción." :locale "es"
                                                            :locale-role :derived))))
      (is (= 0 (%column-count store "true"))))))

(test an-original-and-its-translation-are-two-chunks
  "A translation is another locale of the same section, so the chunk key includes the locale.
Both are stored, and a passage from the translation says whether it was made from the original
stored now: :CURRENT, :OLDER-ORIGINAL when the original changed since, :UNKNOWN when the app
recorded nothing. An original has no translation status."
  (with-store (store)
    (let* ((corpus (rt:make-corpus store "terms"))
           (original "4.2 A refund is issued within 30 days.")
           (older "4.2 A refund is issued within 60 days."))
      (rt:sync-corpus corpus
                      (list (sec "4.2" original)
                            (sec "4.2" "4.2 Un reembolso se emite en 30 días." :locale "es"
                                 :locale-role :derived :derived-from "4.2"
                                 :source-fingerprint (rt:section-fingerprint original))
                            (sec "5.1" "5.1 Refund exceptions.")
                            (sec "5.1" "5.1 Excepciones de reembolso." :locale "es"
                                 :locale-role :derived :derived-from "5.1"
                                 :source-fingerprint (rt:section-fingerprint older))
                            (sec "6.0" "6.0 Refund forms.")
                            (sec "6.0" "6.0 Formularios de reembolso." :locale "es"
                                 :locale-role :derived :derived-from "6.0")))
      (let ((by-key (make-hash-table :test #'equal)))
        (dolist (p (rt:retrieval-result-passages (rt:retrieve-exact corpus "e" :limit 10)))
          (let ((pv (rt:passage-provenance p)))
            (setf (gethash (list (rt:provenance-section-id pv) (rt:provenance-locale pv)) by-key)
                  pv)))
        (is (= 6 (hash-table-count by-key)))
        (is (null (rt:provenance-translation (gethash '("4.2" "en") by-key))))
        (is (eq :source (rt:provenance-locale-role (gethash '("4.2" "en") by-key))))
        (is (eq :current (rt:provenance-translation (gethash '("4.2" "es") by-key))))
        (is (eq :older-original (rt:provenance-translation (gethash '("5.1" "es") by-key))))
        (is (eq :unknown (rt:provenance-translation (gethash '("6.0" "es") by-key))))
        (is (equal "4.2" (rt:provenance-derived-from (gethash '("4.2" "es") by-key))))))))

;;; --- embedding and similarity ------------------------------------------------------------

(test similarity-is-nearest-first-and-says-what-it-could-not-consider
  "Nearest first by cosine distance, each with its distance. After a sync adds a section,
the result is TRUNCATED with reason :NOT-EMBEDDED and the number pending, until EMBED-PENDING
catches up, and then COMPLETE. Documents and queries are embedded by their own calls."
  (with-store (store)
    (let ((corpus (rt:make-corpus store "policy"))
          (embedder (make-instance 'word-embedder)))
      (rt:ingest corpus +policy+ embedder)
      (let ((r (rt:retrieve-similar corpus embedder "when is my refund" :limit 3)))
        (is (equal "2" (first (ids r))))
        (is (every #'rt:passage-distance (rt:retrieval-result-passages r)))
        (is (apply #'<= (mapcar #'rt:passage-distance (rt:retrieval-result-passages r))))
        (is (rt:complete-p (rt:retrieval-result-completeness r))))
      (rt:sync-document corpus "doc-1" (append +policy+ (list (sec "4" "Refund refund refund."))))
      (let ((c (rt:retrieval-result-completeness
                (rt:retrieve-similar corpus embedder "refund"))))
        (is (rt:truncated-p c))
        (is (eq :not-embedded (rt:truncated-reason c)))
        (is (= 1 (rt:truncated-pending c))))
      (rt:embed-pending corpus embedder)
      (is (rt:complete-p (rt:retrieval-result-completeness
                          (rt:retrieve-similar corpus embedder "refund"))))
      (is (find :documents (recorded-calls embedder) :key #'car))
      (is (find "refund" (recorded-calls embedder) :key #'cdr :test #'equal)
          "the query went through EMBED-QUERY"))))

(test a-model-change-re-embeds-and-the-old-model-sees-nothing
  "The deriver is the model and the width. After a change of model every chunk is pending,
EMBED-PENDING re-embeds them all, and a query embedded by the old model is compared with none
of them, because vectors from two models are not comparable."
  (with-store (store)
    (let ((corpus (rt:make-corpus store "policy"))
          (old (make-instance 'word-embedder :model "words-v1"))
          (new (make-instance 'word-embedder :model "words-v2")))
      (rt:ingest corpus +policy+ old)
      (is (equal "words-v2/4" (rt:deriver-of new)))
      (is (= 3 (rt:embed-pending corpus new)))
      (let ((r (rt:retrieve-similar corpus old "refund")))
        (is (null (rt:retrieval-result-passages r)))
        (is (= 3 (rt:truncated-pending (rt:retrieval-result-completeness r)))))
      (is (= 3 (length (rt:retrieval-result-passages
                        (rt:retrieve-similar corpus new "refund"))))))))

(test an-embedder-of-another-width-is-refused-before-any-call
  "The store's width is a deployment fact. An embedder of another width is refused before a
request is made."
  (with-store (store)
    (let ((corpus (rt:make-corpus store "policy"))
          (wide (make-instance 'word-embedder :width 8)))
      (rt:sync-corpus corpus +policy+)
      (signals cnd:embedding-dimension-mismatch (rt:embed-pending corpus wide))
      (signals cnd:embedding-dimension-mismatch (rt:retrieve-similar corpus wide "refund"))
      (is (null (recorded-calls wide))))))

(defclass short-embedder (word-embedder) ()
  (:documentation "Says it is four wide and returns three numbers."))

(defmethod llm:embed ((p short-embedder) text)
  (subseq (call-next-method) 0 3))

(test a-vector-shorter-than-the-provider-says-is-refused-before-it-is-stored
  "The width check before the call trusts what the provider says its width is, so the reply is
checked too, and nothing is stored. This matters most on SQLite (#369), whose embedding column is
text and would hold any list of numbers."
  (with-store (store)
    (let ((corpus (rt:make-corpus store "policy")))
      (rt:sync-corpus corpus +policy+)
      (signals cnd:embedding-dimension-mismatch
        (rt:embed-pending corpus (make-instance 'short-embedder)))
      (is (= 3 (%column-count store "embedding IS NULL")) "nothing was stored")
      (is (= 3 (rt:embed-pending corpus (make-instance 'word-embedder))) "control: four numbers are"))))

(test (a-stored-vector-reads-back-as-the-numbers-written :suite chunkers)
  "The text a SQLite store keeps for a vector (#369) reads back as the same doubles, including
numbers written with an exponent. Text that is not a vector is refused rather than read as one."
  (let* ((store (make-instance 'rc::chunk-store :dimensions 4))
         (numbers #(0.1d0 -2.5d0 1.0d-7 3.0d12))
         (text (rt::%sqlite-vector-text store numbers)))
    (is (char= #\[ (char text 0)))
    (is (equalp numbers (rt::%parse-vector-text text)))
    (is (< (abs (- 0.1d0 (aref (rt::%parse-vector-text
                                (rt::%sqlite-vector-text store (vector 0.1f0 0 1 2)))
                               0)))
           1d-6)
        "single floats and integers are written as doubles")
    (signals cnd:deliberation-failure (rt::%sqlite-vector-text store #(1d0 2d0)))
    (signals cnd:deliberation-failure (rt::%parse-vector-text "1,2,3"))
    (signals cnd:deliberation-failure (rt::%parse-vector-text "[1,#.(quit),3]"))
    (is (= 0d0 (rt::%cosine-distance #(1d0 0d0) #(2d0 0d0))))
    (is (= 1d0 (rt::%cosine-distance #(1d0 0d0) #(0d0 1d0))))
    (is (= 1d0 (rt::%cosine-distance #(0d0 0d0) #(1d0 0d0))) "a zero vector is distance 1")))

(test a-vector-for-replaced-text-is-dropped
  "A vector is written only if its chunk still holds the text that was embedded. Here the
section is replaced while its batch is being embedded; the old vector is not written, the new
chunk stays pending, and the next run embeds it."
  (with-store (store)
    (let* ((corpus (rt:make-corpus store "policy"))
           (once nil)
           (embedder (make-instance
                      'word-embedder
                      :before-documents
                      (lambda ()
                        (unless once
                          (setf once t)
                          (rt:sync-document corpus "doc-1"
                                            (list (sec "1" "A payout is sent weekly."))))))))
      (rt:sync-corpus corpus (list (sec "1" "A payout is sent monthly.")))
      (is (= 0 (rt:embed-pending corpus embedder)) "the vector for the old text was dropped")
      (is (= 1 (%column-count store "embedding IS NULL")))
      (is (= 1 (rt:embed-pending corpus embedder)))
      (is (= 1 (%column-count store "text = ? AND embedding IS NOT NULL"
                              "A payout is sent weekly."))))))

(test a-changed-width-is-reported-with-a-restart-that-recreates-the-column
  "A vector of one width cannot be stored in a column of another. ENSURE-SCHEMA compares the
live column with the store's width and signals EMBEDDING-WIDTH-CHANGED. The restart recreates
the column empty at the new width and clears every deriver, so everything is pending again."
  (postgres-only ("a pgvector column's width")
  (with-store (store)
    (let ((corpus (rt:make-corpus store "policy")))
      (rt:ingest corpus +policy+ (make-instance 'word-embedder))
      (let ((wider (rt:make-chunk-store (rt:store-connection store)
                                        :table (rt:store-table store) :dimensions 8)))
        (handler-case (progn (rt:ensure-schema wider) (fail "expected EMBEDDING-WIDTH-CHANGED"))
          (rt:embedding-width-changed (c)
            (is (equal "vector(4)" (rt:embedding-width-changed-stored c)))
            (is (= 8 (rt:embedding-width-changed-configured c)))))
        (handler-bind ((rt:embedding-width-changed
                         (lambda (c) (invoke-restart (find-restart 'rt:recreate-embedding-column c)))))
          (rt:ensure-schema wider))
        (is (= 3 (%column-count store "embedding IS NULL AND embedding_deriver IS NULL")))
        (is (eq wider (rt:ensure-schema wider)) "and the check now passes"))))))

;;; --- serialising ingest ---------------------------------------------------------------

(defmacro %recording-errors ((errors guard) &body body)
  "A thread function running BODY that records any error in ERRORS instead of letting it
reach the thread's toplevel, where it would end the whole test image."
  `(lambda ()
     (handler-case (progn ,@body)
       (error (e) (bt:with-lock-held (,guard) (push e ,errors))))))

(test ingest-into-one-corpus-is-serialised-across-sessions
  "Two database sessions, as two web processes or an old and a new version during a deploy
would be. While one holds a corpus's lock, a sync of that corpus from the other waits, and
finishes once the lock is released. Control: a sync of another corpus from the second session
does not wait. Postgres advisory locks belong to sessions, so two connections are two
processes as far as the lock can tell."
  (postgres-only ("the corpus lock is an advisory lock")
  (with-store (store-a)
    (let* ((conn-b (%connect))
           (store-b (rt:make-chunk-store conn-b :table (rt:store-table store-a) :dimensions 4))
           (held (rt:make-corpus store-a "policy"))
           (waiting (rt:make-corpus store-b "policy"))
           (errors '()) (guard (bt:make-lock))
           (release nil) (acquired nil) (done nil) (other-done nil)
           (threads '()))
      (unwind-protect
           (progn
             (push (bt:make-thread (%recording-errors (errors guard)
                                     (rt:with-corpus-lock (held)
                                       (setf acquired t)
                                       (loop until release do (sleep 0.02)))))
                   threads)
             (loop repeat 250 until (or acquired errors) do (sleep 0.02))
             (is-true acquired "the first session holds the lock")
             (push (bt:make-thread (%recording-errors (errors guard)
                                     (rt:sync-corpus waiting +policy+) (setf done t)))
                   threads)
             (sleep 0.5)
             (is-false done "the second session's sync of the same corpus waits")
             ;; The control runs while the first session still holds the lock, on the same
             ;; connection as the waiting sync. That connection is busy waiting for the lock,
             ;; so the control gets its own session.
             (let* ((conn-c (%connect))
                    (store-c (rt:make-chunk-store conn-c :table (rt:store-table store-a)
                                                         :dimensions 4)))
               (unwind-protect
                    (progn (rt:sync-corpus (rt:make-corpus store-c "other") +policy+)
                           (setf other-done t))
                 (conn:disconnect conn-c)))
             (is-true other-done "a sync of another corpus is not blocked")
             (is-false done "and the waiting sync is still waiting")
             (setf release t)
             (tt:join-all threads)
             (setf threads '())
             (is (null errors) "~{~A~^; ~}" errors)
             (is-true done "it finishes once the lock is released")
             (is (= 3 (%column-count store-a "corpus = ?" "policy")))
             (is (= 3 (%column-count store-a "corpus = ?" "other"))))
        (setf release t)
        ;; A deadline here too, and its failure ignored: the test's own failure is the one
        ;; worth reporting, and cleanup must still close the connection.
        (ignore-errors (tt:join-all threads))
        (conn:disconnect conn-b))))))

(test concurrent-syncs-of-one-corpus-do-not-collide
  "The case the ruling named: two sessions replacing the same sections at once. Without
serialisation the second insert of a chunk id fails on the primary key. Each session syncs a
different version of the same sections several times; every sync succeeds, and the table holds
exactly one version at the end."
  (with-store (store-a)
    (let* ((conn-b (%connect))
           (store-b (rt:make-chunk-store conn-b :table (rt:store-table store-a) :dimensions 4))
           (errors '())
           (guard (bt:make-lock)))
      (unwind-protect
           (flet ((worker (store tag)
                    (%recording-errors (errors guard)
                      (let ((corpus (rt:make-corpus store "policy")))
                        (dotimes (i 5)
                          (rt:sync-corpus corpus
                                          (loop for n below 20
                                                collect (sec (format nil "~D" n)
                                                             (format nil "~A ~D ~D" tag i n)))))))))
             (let ((threads (list (bt:make-thread (worker store-a "a"))
                                  (bt:make-thread (worker store-b "b")))))
               (tt:join-all threads))
             (is (null errors) "~{~A~^; ~}" errors)
             (is (= 20 (%column-count store-a "corpus = ?" "policy"))))
        (conn:disconnect conn-b)))))

;;; --- into context ----------------------------------------------------------------------

(test a-passage-enters-context-only-through-a-render-the-caller-chose
  "RENDER is required, so the caller decides at the call site how the citation reads. The
item's source is the passage, whose provenance was read from its row."
  (with-store (store)
    (let ((corpus (rt:make-corpus store "policy")))
      (rt:sync-corpus corpus +policy+)
      (let* ((p (first (rt:retrieval-result-passages (rt:retrieve-exact corpus "refund"))))
             (item (rt:passage->ctx-item
                    p (lambda (p) (format nil "[~A] ~A"
                                          (rt:provenance-locator (rt:passage-provenance p))
                                          (rt:passage-text p))))))
        (is (string= "[§2] A refund is issued within 30 days of the request."
                     (ctx:ctx-item-content item)))
        (is (eq p (ctx:ctx-item-source item)))
        (signals error (rt:passage->ctx-item p nil))))))

;;; --- review follow-ups on #306 --------------------------------------------------------

(test two-documents-may-use-the-same-section-id
  "A section is identified by its document, its id and its locale. Two documents that both
number their sections from 1 coexist, and a sync of one document never touches the other's
rows: doc-2's section keeps its embedding while doc-1's is replaced."
  (with-store (store)
    (let ((corpus (rt:make-corpus store "policy"))
          (embedder (make-instance 'word-embedder)))
      (rt:sync-corpus corpus (list (sec "1" "Refunds take 30 days." :document-id "doc-1")
                                   (sec "1" "Payouts are monthly." :document-id "doc-2")))
      (is (= 2 (%column-count store "section_id = ?" "1")))
      (rt:embed-pending corpus embedder)
      (let ((report (rt:sync-document corpus "doc-1"
                                      (list (sec "1" "Refunds take 14 days." :document-id "doc-1")))))
        (is (= 1 (rt:sync-report-replaced report)))
        (is (= 0 (rt:sync-report-removed report))))
      (is (= 1 (%column-count store "document_id = ? AND embedding IS NOT NULL" "doc-2"))
          "doc-2's section was not deleted or re-chunked")
      (is (= 1 (%column-count store "document_id = ? AND embedding IS NULL" "doc-1")))
      (rt:sync-document corpus "doc-1" '())
      (is (= 1 (%column-count store "true")) "removing doc-1 leaves doc-2's section 1"))))

(test a-translation-is-matched-to-the-original-in-its-own-document
  "Two documents with a section 4.2 each, one of them edited since its translation was made.
Each translation's status is computed against the original in its own document."
  (with-store (store)
    (let* ((corpus (rt:make-corpus store "terms"))
           (a "4.2 Refunds take 30 days.")
           (b "4.2 Payouts are monthly."))
      (rt:sync-corpus corpus
                      (list (sec "4.2" a :document-id "doc-a")
                            (sec "4.2" "4.2 Reembolsos en 30 días." :document-id "doc-a" :locale "es"
                                 :locale-role :derived :derived-from "4.2"
                                 :source-fingerprint (rt:section-fingerprint a))
                            (sec "4.2" b :document-id "doc-b")
                            (sec "4.2" "4.2 Pagos mensuales." :document-id "doc-b" :locale "es"
                                 :locale-role :derived :derived-from "4.2"
                                 :source-fingerprint (rt:section-fingerprint "an older original"))))
      (let ((status (make-hash-table :test #'equal)))
        (dolist (p (rt:retrieval-result-passages (rt:retrieve-exact corpus "4.2" :limit 10)))
          (let ((pv (rt:passage-provenance p)))
            (when (equal "es" (rt:provenance-locale pv))
              (setf (gethash (rt:provenance-document-id pv) status)
                    (rt:provenance-translation pv)))))
        (is (eq :current (gethash "doc-a" status)))
        (is (eq :older-original (gethash "doc-b" status)))))))

(test embed-pending-refuses-a-batch-size-that-is-not-positive
  "A batch size of zero would query LIMIT 0 and report nothing embedded, as if nothing were
pending. It is refused before any query. Control: 1 works."
  (with-store (store)
    (let ((corpus (rt:make-corpus store "policy"))
          (embedder (make-instance 'word-embedder)))
      (rt:sync-corpus corpus +policy+)
      (signals error (rt:embed-pending corpus embedder :batch-size 0))
      (signals error (rt:embed-pending corpus embedder :batch-size -1))
      (is (null (recorded-calls embedder)))
      (is (= 3 (rt:embed-pending corpus embedder :batch-size 1))))))

(test completeness-and-candidates-come-from-one-snapshot
  "Between the candidate query and the count of chunks not yet embedded, another session
embeds the pending chunk and commits. Both reads use one snapshot, so the result, which left
that chunk out, still says TRUNCATED with one pending, not COMPLETE. Postgres only: on SQLite
the reading transaction's lock keeps another connection from committing until the reads end,
so there is no moment between them in which the other session could commit."
  (postgres-only ("another session committing between two reads of one transaction")
  (with-store (store)
    (let* ((corpus (rt:make-corpus store "policy"))
           (embedder (make-instance 'word-embedder))
           (conn-b (%connect))
           (other (rt:make-corpus (rt:make-chunk-store conn-b :table (rt:store-table store)
                                                               :dimensions 4)
                                  "policy")))
      (unwind-protect
           (progn
             (rt:ingest corpus +policy+ embedder)
             (rt:sync-document corpus "doc-1" (append +policy+ (list (sec "4" "Refund refund."))))
             (let* ((rt::*between-similar-reads*
                      (lambda () (rt:embed-pending other embedder)))
                    (r (rt:retrieve-similar corpus embedder "refund" :limit 10)))
               (is (= 3 (length (rt:retrieval-result-passages r))) "the new chunk was not a candidate")
               (is (rt:truncated-p (rt:retrieval-result-completeness r)))
               (is (eql 1 (rt:truncated-pending (rt:retrieval-result-completeness r)))))
             (is (= 0 (%column-count store "embedding IS NULL")) "the other session's embedding committed")
             (is (rt:complete-p (rt:retrieval-result-completeness
                                 (rt:retrieve-similar corpus embedder "refund")))
                 "and the next search sees it"))
        (conn:disconnect conn-b))))))

(test on-sqlite-no-session-commits-between-the-two-reads
  "The SQLite counterpart of the test above (#369). Between the candidate query and the count of
chunks not yet embedded, another session tries to embed the pending chunk. The reading
transaction holds SQLite's lock, so that session is refused, and the result counts the chunk as
pending. The other session waits no time for the lock, so the refusal comes at once. Control:
after the search, the same call succeeds and the next search is COMPLETE."
  (if (not (%sqlite-p))
      (skip "SQLite only: the Postgres test above covers REPEATABLE READ")
      (with-store (store)
        (let* ((corpus (rt:make-corpus store "policy"))
               (embedder (make-instance 'word-embedder))
               (conn-b (%connect))
               (other (rt:make-corpus (rt:make-chunk-store conn-b :table (rt:store-table store)
                                                                   :dimensions 4)
                                      "policy"))
               (refused nil))
          (unwind-protect
               (progn
                 (conn:exec conn-b "PRAGMA busy_timeout = 0")
                 (rt:ingest corpus +policy+ embedder)
                 (rt:sync-document corpus "doc-1" (append +policy+ (list (sec "4" "Refund refund."))))
                 (let* ((rt::*between-similar-reads*
                          (lambda ()
                            (handler-case (rt:embed-pending other embedder)
                              (error () (setf refused t)))))
                        (r (rt:retrieve-similar corpus embedder "refund" :limit 10)))
                   (is-true refused "the other session could not commit during the reads")
                   (is (= 3 (length (rt:retrieval-result-passages r))))
                   (is (eql 1 (rt:truncated-pending (rt:retrieval-result-completeness r)))))
                 (is (= 1 (rt:embed-pending other embedder)) "control: afterwards it can")
                 (is (rt:complete-p (rt:retrieval-result-completeness
                                     (rt:retrieve-similar corpus embedder "refund")))))
            (conn:disconnect conn-b))))))

;;; --- the paragraph chunker (#322) ----------------------------------------------------
;;;
;;; The first six need no database and are in the CHUNKERS suite; the last syncs a corpus.

(defun %para (tag length)
  "A paragraph of exactly LENGTH characters that starts with TAG, so it can be found."
  (let ((s (make-string length :initial-element #\x)))
    (replace s tag)
    s))

(defun %join-paras (paras &optional (separator (format nil "~%~%")))
  (format nil (concatenate 'string "~{~A~^" separator "~}") paras))

(defun %chunks (text &rest settings)
  (rt:chunk-section (apply #'make-instance 'rt:paragraph-chunker settings) (sec "p" text)))

(test (a-section-up-to-the-long-section-length-is-one-whole-section-chunk :suite chunkers)
  (let* ((text (%join-paras (list (%para "a" 749) (%para "b" 749))))   ; 1500 characters
         (chunks (%chunks text)))
    (is (= 1500 (length text)))
    (is (= 1 (length chunks)))
    (is (eq :whole-section (rt:chunk-boundary (first chunks))))
    (is (null (rt:chunk-sub-locator (first chunks))))
    (is (string= text (rt:chunk-text (first chunks))))))

(test (a-long-section-is-cut-at-blank-lines-into-runs-of-whole-paragraphs :suite chunkers)
  ;; Six paragraphs of 400: two fit in 900 (400 + 2 + 400), a third does not.
  (let* ((paras (loop for i from 1 to 6 collect (%para (format nil "p~D" i) 400)))
         (chunks (%chunks (%join-paras paras))))
    (is (equal '("part 1" "part 2" "part 3") (mapcar #'rt:chunk-sub-locator chunks)))
    (is (every (lambda (c) (eq :whole-paragraph (rt:chunk-boundary c))) chunks))
    (is (equal (list (%join-paras (subseq paras 0 2)) (%join-paras (subseq paras 2 4))
                     (%join-paras (subseq paras 4 6)))
               (mapcar #'rt:chunk-text chunks))
        "each chunk is whole paragraphs, with the blank lines between them kept")))

(test (a-paragraph-longer-than-the-target-is-a-chunk-of-its-own-and-never-split :suite chunkers)
  (let* ((big (%para "big" 1200))
         (paras (list (%para "a" 300) big (%para "c" 300)))
         (chunks (%chunks (%join-paras paras))))
    (is (= 3 (length chunks)))
    (is (string= big (rt:chunk-text (second chunks))))
    (is (every (lambda (c) (member (rt:chunk-text c) paras :test #'string=)) chunks)
        "no chunk holds part of a paragraph")))

(test (a-long-section-with-no-blank-line-stays-one-whole-section-chunk :suite chunkers)
  (let* ((text (format nil "~A~%~A" (%para "a" 1000) (%para "b" 1000)))
         (chunks (%chunks text)))
    (is (= 1 (length chunks)))
    (is (eq :whole-section (rt:chunk-boundary (first chunks))))
    (is (string= text (rt:chunk-text (first chunks))))))

(test (whitespace-only-and-crlf-lines-count-as-blank-and-edges-make-no-empty-chunk :suite chunkers)
  (let* ((crlf-blank (format nil "~C~%  ~C~%" #\Return #\Return))
         (paras (list (%para "a" 800) (%para "b" 800)))
         (text (concatenate 'string (format nil "~%~%") (%join-paras paras crlf-blank)
                            (format nil "~%  ~%")))
         (chunks (%chunks text)))
    (is (= 2 (length chunks)))
    (is (equal paras (mapcar #'rt:chunk-text chunks)))))

(test (a-paragraph-chunker-refuses-bad-settings-and-names-them-in-its-id :suite chunkers)
  (signals error (make-instance 'rt:paragraph-chunker :target 0))
  (signals error (make-instance 'rt:paragraph-chunker :long-section "1500"))
  (is (string= "paragraph/1:1500:900" (rt:chunker-id (make-instance 'rt:paragraph-chunker))))
  (is (string/= (rt:chunker-id (make-instance 'rt:paragraph-chunker))
                (rt:chunker-id (make-instance 'rt:paragraph-chunker :target 600)))
      "a change of setting is a change of id, so the corpus is re-chunked"))

(test a-long-section-is-stored-and-found-as-whole-paragraph-chunks
  "The chunks a corpus stores, and what a match on one of them reports: its sub-locator, its
boundary, the chunker, and the chunk's own text. A short section in the same corpus stays one
chunk."
  (with-store (store)
    (let* ((paras (loop for i from 1 to 6 collect (%para (format nil "para~D" i) 400)))
           (corpus (rt:make-corpus store "contracts"
                                   :chunker (make-instance 'rt:paragraph-chunker)))
           (short (sec "short" "A refund is issued within 30 days.")))
      (rt:sync-corpus corpus (list (sec "preamble" (%join-paras paras)) short))
      (is (= 4 (%column-count store "corpus = ?" "contracts")) "three parts and one short")
      (let* ((hit (first (rt:retrieval-result-passages (rt:retrieve-exact corpus "para5"))))
             (prov (and hit (rt:passage-provenance hit))))
        (is (equal "preamble" (and prov (rt:provenance-section-id prov))))
        (is (equal "part 3" (and prov (rt:provenance-sub-locator prov))))
        (is (eq :whole-paragraph (and prov (rt:provenance-boundary prov))))
        (is (equal "paragraph/1:1500:900" (and prov (rt:provenance-chunker prov))))
        (is (equal (%join-paras (subseq paras 4 6)) (and hit (rt:passage-text hit)))))
      (let ((prov (rt:passage-provenance
                   (first (rt:retrieval-result-passages (rt:retrieve-exact corpus "refund"))))))
        (is (eq :whole-section (rt:provenance-boundary prov)))
        (is (null (rt:provenance-sub-locator prov)))))))

;;; --- the retrieve entry point and the agent's search means (#138) ---------------------

(defun %render (passage)
  "What a test app shows the model: the section's locator, then the passage text."
  (format nil "[~A] ~A" (rt:provenance-locator (rt:passage-provenance passage))
          (rt:passage-text passage)))

(defun %args (&rest pairs)
  "A tool-call argument table, as the loop hands one to a means."
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on pairs by #'cddr do (setf (gethash k h) v))
    h))

(defun %expected-text (result)
  (format nil "~{~A~^~%~%~}" (mapcar #'%render (rt:retrieval-result-passages result))))

(test retrieve-on-a-hybrid-corpus-is-retrieve-hybrid-with-a-default-limit-of-20
  (with-store (store)
    (let ((corpus (rt:make-corpus store "many" :strategy :hybrid))
          (embedder (make-instance 'word-embedder)))
      ;; Section I mentions "refund" I times, so every section is at a different distance from
      ;; the query and the order has no ties.
      (rt:ingest corpus (loop for i from 1 to 25
                              collect (sec (format nil "~D" i)
                                           (with-output-to-string (out)
                                             (write-string "Rule:" out)
                                             (dotimes (k i) (write-string " refund" out)))))
                 embedder)
      (let ((default (rt:retrieve corpus embedder "refund")))
        (is (= 20 (length (rt:retrieval-result-passages default))))
        (is (equal (ids (rt:retrieve-hybrid corpus embedder "refund" :limit 20)) (ids default))
            "the same passages in the same order as RETRIEVE-HYBRID at 20"))
      (is (equal (ids (rt:retrieve-hybrid corpus embedder "refund" :limit 3))
                 (ids (rt:retrieve corpus embedder "refund" :limit 3)))
          ":limit is passed through"))))

(test the-search-means-shows-the-rendered-passages-in-order-and-reports-the-result
  (with-store (store)
    (let* ((corpus (rt:make-corpus store "policy"))
           (embedder (make-instance 'word-embedder))
           (agent (actor:make-agent :name "searcher"))
           (seen '()))
      (rt:ingest corpus +policy+ embedder)
      (is (equal "search-documents"
                 (rt:register-corpus-search agent corpus embedder #'%render
                                            :on-result (lambda (q r) (push (cons q r) seen)))))
      (let ((text (actor:act agent "search-documents" (%args "query" "refund")))
            (expected (rt:retrieve corpus embedder "refund")))
        (is (string= (%expected-text expected) text)
            "every passage, rendered by the app, in the order RETRIEVE returned them")
        (is (search "[§2] A refund is issued" text) "the best match is in it")
        (is (= 1 (length seen)))
        (is (equal "refund" (car (first seen))))
        (is (equal (ids expected) (ids (cdr (first seen))))
            "ON-RESULT receives the result the model was shown")))))

(test a-search-by-words-uses-exact-retrieval-and-embeds-nothing
  (with-store (store)
    (let* ((corpus (rt:make-corpus store "policy"))
           (embedder (make-instance 'word-embedder))
           (agent (actor:make-agent)))
      (rt:ingest corpus +policy+ embedder)
      (rt:register-corpus-search agent corpus embedder #'%render)
      (setf (recorded-calls embedder) '())
      (let ((text (actor:act agent "search-documents" (%args "query" "30  DAYS" "match" "words"))))
        (is (string= (%expected-text (rt:retrieve-exact corpus '("30" "DAYS"))) text))
        (is (search "[§2]" text))
        (is (null (recorded-calls embedder)) "a search by words never calls the embedder")))))

(test with-no-embedder-the-means-offers-and-runs-a-search-by-words-only
  (with-store (store)
    (let* ((corpus (rt:make-corpus store "policy"))
           (agent (actor:make-agent)))
      (rt:sync-corpus corpus +policy+)
      (rt:register-corpus-search agent corpus nil #'%render :name "policy")
      (let* ((spec (find "policy" (actor:agent-tool-specs agent)
                         :key #'llm:tool-spec-name :test #'string=))
             (props (gethash "properties" (llm:tool-spec-schema spec))))
        (is (gethash "query" props))
        (is (null (gethash "match" props)) "no \"match\" is offered without an embedder"))
      (is (string= (%expected-text (rt:retrieve-exact corpus '("refund")))
                   (actor:act agent "policy" (%args "query" "refund"))))
      (let* ((agent2 (actor:make-agent))
             (corpus2 (rt:make-corpus store "policy")))
        (rt:register-corpus-search agent2 corpus2 (make-instance 'word-embedder) #'%render)
        (is (equalp #("meaning" "words")
                    (gethash "enum" (gethash "match" (gethash "properties"
                                                              (llm:tool-spec-schema
                                                               (first (actor:agent-tool-specs agent2)))))))
            "with an embedder, both kinds are offered")))))

(test the-model-is-told-when-a-search-result-is-truncated
  (with-store (store)
    (let* ((corpus (rt:make-corpus store "policy" :strategy :hybrid))
           (embedder (make-instance 'word-embedder))
           (agent (actor:make-agent)))
      ;; Synced and never embedded: the similarity half of a hybrid search has no candidates,
      ;; and the result says why. The keyword half still finds the best refund passage.
      (rt:sync-corpus corpus (list (sec "1" "A refund is issued.") (sec "2" "Refund rules.")
                                   (sec "3" "Privacy.")))
      (rt:register-corpus-search agent corpus embedder #'%render :limit 1)
      (let ((text (actor:act agent "search-documents" (%args "query" "refund"))))
        (is (search (format nil "~%~%3 parts of this collection could not be searched by meaning yet, so this result may be missing passages. A search with \"match\": \"words\" covers every part.")
                    text))
        (is (= 1 (count #\[ text)) "one passage, found by keyword"))
      ;; Two passages contain "refund" and the limit is 1.
      (let ((text (actor:act agent "search-documents" (%args "query" "refund" "match" "words"))))
        (is (search "More passages matched than are shown here." text))
        (is (= 1 (count #\[ text)) "one passage, as :limit 1 asks")))))

(test (every-truncation-reason-gets-a-sentence-for-the-model :suite chunkers)
  ;; Checked directly, with a TRUNCATED value built for each reason, so every reason has a
  ;; sentence whether or not a test's corpus can be brought into that state.
  (flet ((note (reason &optional pending)
           (rt::%completeness-note
            (rc::%make-retrieval-result '() (rt:make-truncated :reason reason :pending pending)))))
    (is (null (rt::%completeness-note (rc::%make-retrieval-result '() (rt:make-complete)))))
    (is (string= "More passages matched than are shown here. A narrower query would show others."
                 (note :limit)))
    (let ((meaning "2 parts of this collection could not be searched by meaning yet, so this result may be missing passages. A search with \"match\": \"words\" covers every part."))
      (is (string= meaning (note :not-embedded 2)))
      (is (string= meaning (note :not-indexed 2)) ":not-indexed says the same as :not-embedded"))
    (is (search "1 part of" (note :not-indexed 1)) "one part is singular")
    (is (stringp (note :some-later-reason 3)) "an unknown reason is a sentence, not an error")))

(test the-search-means-refuses-bad-registration-and-bad-arguments
  (with-store (store)
    (let* ((corpus (rt:make-corpus store "policy"))
           (embedder (make-instance 'word-embedder))
           (agent (actor:make-agent)))
      (signals error (rt:register-corpus-search agent corpus embedder nil))
      (signals error (rt:register-corpus-search agent "policy" embedder #'%render))
      (signals error (rt:register-corpus-search agent corpus embedder #'%render :limit 0))
      (signals error (rt:register-corpus-search agent corpus embedder #'%render :on-result t))
      (rt:register-corpus-search agent corpus embedder #'%render)
      (signals cnd:means-failure (actor:act agent "search-documents" (%args "query" "   ")))
      (signals cnd:means-failure (actor:act agent "search-documents" (%args)))
      (signals cnd:means-failure
        (actor:act agent "search-documents" (%args "query" "refund" "match" "fuzzy"))))))

;;; --- the tokenizer (#316) -----------------------------------------------------------------
;;;
;;; Pure: these need no Postgres.

(test the-tokenizer-keeps-an-identifier-whole-and-in-parts
  (is (equal '("error" "ts-999" "ts" "999" "renewal")
             (rt:tokenize "Error TS-999 on renewal." :locale "en")))
  (is (equal '("praxeon_embed_model" "praxeon" "embed" "model")
             (rt:tokenize "PRAXEON_EMBED_MODEL" :locale "en")))
  (is (equal '("v1.2.3" "v1" "2" "3") (rt:tokenize "v1.2.3." :locale "en"))
      "a trailing full stop is not part of the identifier"))

(test the-tokenizer-drops-stop-words-only-for-a-language-it-has-a-list-for
  (is (equal '("refund" "policy") (rt:tokenize "The refund policy" :locale "en-GB"))
      "en-GB uses the en list")
  (is (equal '("the" "refund" "policy") (rt:tokenize "The refund policy"))
      "no locale drops nothing")
  (is (equal '("the" "refund" "policy") (rt:tokenize "The refund policy" :locale "xx"))
      "a language with no list drops nothing")
  (is (equal '("café" "straße") (rt:tokenize "Café Straße" :locale "de"))
      "letters outside ASCII are kept and lowercased"))

(test the-tokenizer-drops-a-term-longer-than-the-limit
  (let ((blob (make-string 65 :initial-element #\a)))
    (is (equal '("short") (rt:tokenize (format nil "~A short" blob))))))

(test term-counts-gives-each-term-once-with-its-count-and-the-length
  (multiple-value-bind (counts total) (rt:term-counts "refund Refund policy the" :locale "en")
    (is (equal '(("refund" . 2) ("policy" . 1)) counts))
    (is (= 3 total))))

;;; --- reciprocal rank fusion (#316), pure --------------------------------------------------

(test fusion-sums-reciprocal-ranks-and-keeps-each-id-once
  (let ((rankings '(("a" "b" "c") ("c" "d" "a"))))
    (is (equal '("a" "c" "b" "d") (fusion:fused-ids 60 rankings))
        "a and c tie, and a appears first; b and d tie, and b appears first")
    (let ((scores (fusion:fused-scores 60 rankings)))
      (is (< (abs (- (first scores) (+ (/ 1d0 61) (/ 1d0 63)))) 1d-12)
          "a: first in one list, third in the other")
      (is (< (abs (- (third scores) (/ 1d0 62))) 1d-12) "b: second in one list only")
      (is (apply #'>= scores) "best first"))))

(test fusion-counts-an-id-once-per-list-at-its-first-position
  (is (equal '("x" "y") (fusion:fused-ids 60 '(("x" "y" "x")))))
  (is (< (abs (- (first (fusion:fused-scores 60 '(("x" "y" "x")))) (/ 1d0 61))) 1d-12)))

(test fusion-of-nothing-is-nothing
  (is (null (fusion:fused-ids 60 '())))
  (is (null (fusion:fused-ids 60 '(() ())))))

;;; --- BM25 against Postgres (#316) ---------------------------------------------------------

(defun %bm25 (tf dl n df avgdl &key (k1 1.2d0) (b 0.75d0))
  "BM25 for one term, computed here independently of the SQL."
  (* (log (+ (/ (+ (- n df) 0.5d0) (+ df 0.5d0)) 1))
     (/ (* tf (+ k1 1)) (+ tf (* k1 (+ (- 1 b) (* b (/ dl avgdl))))))))

(defun %scores-by-id (result)
  (mapcar (lambda (p) (cons (rt:provenance-section-id (rt:passage-provenance p)) (rt:passage-score p)))
          (rt:retrieval-result-passages result)))

(test bm25-scores-match-a-hand-computed-example
  (with-store (store)
    (let ((corpus (rt:make-corpus store "fruit")))
      (rt:sync-document corpus "doc-1" (list (sec "1" "apple banana")
                                             (sec "2" "apple apple cherry")
                                             (sec "3" "banana date")))
      (let* ((r (rt:retrieve-keyword corpus "apple" :locale "en"))
             (scores (%scores-by-id r))
             (avgdl (/ 7d0 3)))
        (is (equal '("2" "1") (mapcar #'car scores)) "the chunk with apple twice ranks first")
        (is (< (abs (- (cdr (assoc "2" scores :test #'equal)) (%bm25 2 3 3 2 avgdl))) 1d-9))
        (is (< (abs (- (cdr (assoc "1" scores :test #'equal)) (%bm25 1 2 3 2 avgdl))) 1d-9))
        (is (rt:complete-p (rt:retrieval-result-completeness r))))
      (let ((scores (%scores-by-id (rt:retrieve-keyword corpus "apple date" :locale "en")))
            (avgdl (/ 7d0 3)))
        (is (< (abs (- (cdr (assoc "3" scores :test #'equal)) (%bm25 1 2 3 1 avgdl))) 1d-9)
            "a rarer term weighs more: date is in one chunk of three")))))

(test keyword-search-finds-an-identifier-that-similarity-does-not
  ;; The word embedder sees payouts, refunds and privacy, and nothing else, so a query for a
  ;; refund and an error code lands on the refund policy by similarity, and on the error code
  ;; by keyword.
  (with-store (store)
    (let ((corpus (rt:make-corpus store "support"))
          (embedder (make-instance 'word-embedder)))
      (rt:ingest corpus (append +policy+ (list (sec "4" "Error TS-999 appears when a card expires.")))
                 embedder)
      (is (equal "4" (first (ids (rt:retrieve-keyword corpus "refund TS-999" :locale "en"))))
          "keyword search puts the error code first")
      (is (not (equal "4" (first (ids (rt:retrieve-similar corpus embedder "refund TS-999")))))
          "control: similarity with the test embedder does not"))))

(test a-query-of-stop-words-matches-nothing
  (with-store (store)
    (let ((corpus (rt:make-corpus store "policy")))
      (rt:sync-corpus corpus +policy+)
      (let ((r (rt:retrieve-keyword corpus "the of and" :locale "en")))
        (is (null (rt:retrieval-result-passages r)))
        (is (rt:complete-p (rt:retrieval-result-completeness r)))))))

(test keyword-search-and-its-statistics-stay-within-one-corpus
  (with-store (store)
    (let ((a (rt:make-corpus store "a"))
          (b (rt:make-corpus store "b")))
      (rt:sync-document a "doc-1" (list (sec "1" "apple banana") (sec "2" "cherry")))
      (rt:sync-document b "doc-1" (list (sec "1" "apple") (sec "2" "apple") (sec "3" "apple")))
      (let ((scores (%scores-by-id (rt:retrieve-keyword a "apple"))))
        (is (equal '("1") (mapcar #'car scores)) "only corpus a's chunk")
        (is (< (abs (- (cdar scores) (%bm25 1 2 2 1 (/ 3d0 2)))) 1d-9)
            "N, df and the average length are corpus a's, not the table's")))))

(defun %count-table-in (store table)
  (param:row-value (first (conn:query (rt:store-connection store)
                                      (format nil "SELECT count(*) AS n FROM ~A" table)))
                   :n))

(test a-sync-keeps-the-terms-in-step-with-the-text
  (with-store (store)
    (let ((corpus (rt:make-corpus store "policy")))
      (rt:sync-document corpus "doc-1" (list (sec "1" "apple banana")))
      (is (= 2 (%count-table-in store (rt:terms-table store))))
      (rt:sync-document corpus "doc-1" (list (sec "1" "cherry")))
      (is (= 1 (%count-table-in store (rt:terms-table store))) "the old text's terms are gone")
      (is (equal '("1") (ids (rt:retrieve-keyword corpus "cherry"))))
      (is (null (ids (rt:retrieve-keyword corpus "apple"))))
      (rt:sync-document corpus "doc-1" '())
      (is (= 0 (%count-table-in store (rt:terms-table store))) "a removed section takes its terms"))))

(test chunks-without-current-terms-are-reported-and-index-pending-writes-them
  (with-store (store)
    (let ((corpus (rt:make-corpus store "policy")))
      (rt:sync-corpus corpus +policy+)
      ;; As a table synced before #316, or by an older tokenizer, would be.
      (conn:exec (rt:store-connection store)
                 (format nil "UPDATE ~A SET terms_tokenizer = 'terms/0'" (rt:store-table store)))
      (let ((c (rt:retrieval-result-completeness (rt:retrieve-keyword corpus "refund"))))
        (is (rt:truncated-p c))
        (is (eq :not-indexed (rt:truncated-reason c)))
        (is (= 3 (rt:truncated-pending c))))
      (is (= 3 (rt:index-pending corpus)))
      (is (= 0 (rt:index-pending corpus)) "and nothing is left to do")
      (let ((r (rt:retrieve-keyword corpus "refund")))
        (is (rt:complete-p (rt:retrieval-result-completeness r)))
        (is (equal '("2") (ids r)))))))

(test ensure-schema-upgrades-a-table-made-before-bm25
  (with-store (store)
    (let ((corpus (rt:make-corpus store "policy"))
          (c (rt:store-connection store)))
      (rt:sync-corpus corpus +policy+)
      (%drop-columns store '("term_count" "terms_tokenizer"))
      (conn:exec c (format nil "DROP TABLE ~A" (rt:terms-table store)))
      (rt:ensure-schema store)
      (is (= 0 (%count-table-in store (rt:terms-table store))) "the terms table is back, empty")
      (is (eq :not-indexed (rt:truncated-reason (rt:retrieval-result-completeness
                                                 (rt:retrieve-keyword corpus "refund")))))
      (is (= 3 (rt:index-pending corpus)))
      (is (equal '("2") (ids (rt:retrieve-keyword corpus "refund")))))))

;;; --- hybrid retrieval (#316) ---------------------------------------------------------------

(test hybrid-merges-both-searches-and-lists-each-chunk-once
  (with-store (store)
    (let ((corpus (rt:make-corpus store "support"))
          (embedder (make-instance 'word-embedder)))
      (rt:ingest corpus (append +policy+ (list (sec "4" "Error TS-999 appears when a card expires.")))
                 embedder)
      (let* ((r (rt:retrieve-hybrid corpus embedder "refund TS-999" :limit 2 :locale "en"))
             (got (ids r)))
        (is (equal '("2" "4") (sort (copy-list got) #'string<))
            "the similarity winner and the keyword winner are the top two")
        (is (every #'rt:passage-score (rt:retrieval-result-passages r)))
        (is (notany #'rt:passage-distance (rt:retrieval-result-passages r)))
        (is (rt:complete-p (rt:retrieval-result-completeness r))))
      (let ((all (ids (rt:retrieve-hybrid corpus embedder "refund TS-999" :limit 20 :locale "en"))))
        (is (= 4 (length all)) "every chunk once, though both searches returned them")
        (is (= 4 (length (remove-duplicates all :test #'equal))))))))

(test hybrid-says-what-it-could-not-consider
  (with-store (store)
    (let ((corpus (rt:make-corpus store "policy"))
          (embedder (make-instance 'word-embedder)))
      (rt:ingest corpus +policy+ embedder)
      (rt:sync-document corpus "doc-1" (append +policy+ (list (sec "4" "Refund again."))))
      (let ((c (rt:retrieval-result-completeness (rt:retrieve-hybrid corpus embedder "refund"))))
        (is (eq :not-embedded (rt:truncated-reason c)))
        (is (= 1 (rt:truncated-pending c))))
      (rt:embed-pending corpus embedder)
      (conn:exec (rt:store-connection store)
                 (format nil "UPDATE ~A SET terms_tokenizer = NULL WHERE section_id = '1'"
                         (rt:store-table store)))
      (let ((c (rt:retrieval-result-completeness (rt:retrieve-hybrid corpus embedder "refund"))))
        (is (eq :not-indexed (rt:truncated-reason c)) "every chunk embedded, one not indexed")
        (is (= 1 (rt:truncated-pending c)))))))

;;; --- the evaluation helper (#316) ----------------------------------------------------------

(test evaluate-retrieval-reports-top-k-hits-per-strategy
  (with-store (store)
    (let ((corpus (rt:make-corpus store "support"))
          (embedder (make-instance 'word-embedder)))
      (rt:ingest corpus (append +policy+ (list (sec "4" "Error TS-999 appears when a card expires.")))
                 embedder)
      (let* ((questions (list (rt:make-eval-question :query "refund TS-999" :document-id "doc-1"
                                                     :section-id "4")
                              (rt:make-eval-question :query "when is my payout" :document-id "doc-1"
                                                     :section-id "1")))
             (report (rt:evaluate-retrieval corpus embedder questions :k 1 :locale "en"))
             (by (lambda (s) (find s report :key (lambda (r) (getf r :strategy))))))
        (is (equal '(:similar :keyword :hybrid) (mapcar (lambda (r) (getf r :strategy)) report)))
        (is (= 1 (getf (funcall by :similar) :hits)) "similarity finds the payout, not the error code")
        (is (= 2 (getf (funcall by :keyword) :hits)) "keywords find both")
        (is (= 1/2 (getf (funcall by :similar) :recall)))
        (is (every (lambda (r) (and (= 2 (getf r :questions)) (= 0 (getf r :incomplete)) (= 1 (getf r :k))))
                   report))))))

;;; --- contexts (#316, step 3) ----------------------------------------------------------------
;;;
;;; The chat model is a stand-in that answers with the first line of the document it was given,
;;; so a chunk's context carries a word its own text may lack, and a test can see that word reach
;;; the BM25 terms and the embedding. It reports a cache write for the first call with a document
;;; and a cache read for every later one, as a provider with a prefix cache does.

(defclass context-writer (llm:provider)
  ((model :initarg :model :initform "writer-1" :reader writer-model)
   (answer :initarg :answer :initform nil :reader writer-answer)
   (stop :initarg :stop :initform :end :reader writer-stop)
   (calls :initform '() :accessor writer-calls)
   (seen :initform (make-hash-table :test 'equal) :reader writer-seen)))

(defmethod llm:model-of ((p context-writer)) (writer-model p))

(defun %document-first-line (document-text)
  "The first line inside \"<document>...\"."
  (let* ((start (1+ (position #\Newline document-text)))
         (end (position #\Newline document-text :start start)))
    (subseq document-text start end)))

(defmethod llm:complete ((p context-writer) messages
                         &key system tools max-tokens temperature tool-choice)
  (declare (ignore system tools temperature tool-choice))
  (let* ((parts (llm:content (first messages)))
         (document (getf (first parts) :text))
         (hit (gethash document (writer-seen p))))
    (setf (gethash document (writer-seen p)) t)
    (push (list :parts parts :max-tokens max-tokens) (writer-calls p))
    (llm:make-completion
     :text (if (writer-answer p)
               (funcall (writer-answer p) document)
               (format nil "  This passage is from the document that begins: ~A~%"
                       (%document-first-line document)))
     :stop-reason (writer-stop p)
     :input-tokens 20 :output-tokens 10
     :cache-read-tokens (if hit 50 0) :cache-write-tokens (if hit 0 50))))

(defun %contextual (store name &rest keys &key (writer (make-instance 'context-writer))
                    &allow-other-keys)
  "A corpus NAME whose contextualizer is WRITER, :HYBRID unless KEYS say otherwise."
  (apply #'rt:make-corpus store name
         :contextualizer (rt:make-contextualizer writer)
         (append (loop for (k v) on keys by #'cddr unless (eq k :writer) append (list k v))
                 (list :strategy :hybrid))))

(defparameter +handbook+
  (list (sec "1" "Payout rules.")
        (sec "2" "It is sent on the first business day of the month.")
        (sec "3" "Refund rules." :document-id "doc-2")
        (sec "4" "It is issued within 30 days." :document-id "doc-2")))

(defun %sync-handbook (corpus)
  (rt:sync-document corpus "doc-1" (subseq +handbook+ 0 2))
  (rt:sync-document corpus "doc-2" (subseq +handbook+ 2 4)))

(defun %passage (result section-id)
  (find section-id (rt:retrieval-result-passages result)
        :key (lambda (p) (rt:provenance-section-id (rt:passage-provenance p))) :test #'equal))

(test each-chunk-gets-a-context-with-its-document-in-the-cached-prefix
  (with-store (store)
    (let* ((writer (make-instance 'context-writer))
           (corpus (%contextual store "handbook" :writer writer)))
      (%sync-handbook corpus)
      (multiple-value-bind (n status) (rt:contextualize-pending corpus)
        (is (= 4 n))
        (is (eq :done status)))
      (let* ((calls (reverse (writer-calls writer)))
             (documents (mapcar (lambda (c) (getf (first (getf c :parts)) :text)) calls)))
        (is (= 4 (length calls)) "one call per chunk")
        (dolist (call calls)
          (destructuring-bind (document chunk) (getf call :parts)
            (is (llm:cache-boundary-p document) "the document ends the cacheable prefix")
            (is (not (llm:cache-boundary-p chunk)) "the chunk and the instruction come after it")
            (is (search "<chunk>" (getf chunk :text)))
            (is (= 200 (getf call :max-tokens)))))
        (is (search (format nil "Payout rules.~%~%It is sent on the first business day")
                    (first documents))
            "the whole document, its chunks in order")
        (is (and (equal (first documents) (second documents))
                 (equal (third documents) (fourth documents))
                 (not (equal (first documents) (third documents))))
            "one document's chunks are asked for together, so the cached document is reused"))
      (let* ((r (rt:retrieve-whole corpus))
             (second (%passage r "2")))
        (is (equal '("1" "2" "3" "4") (ids r)))
        (is (equal "It is sent on the first business day of the month." (rt:passage-text second))
            "the passage is the chunk's own text")
        (is (equal "This passage is from the document that begins: Payout rules."
                   (rt:passage-context second))
            "and its context, trimmed, is beside it"))
      (is (= 0 (rt:contextualize-pending corpus)) "nothing is left to do")
      (is (= 4 (length (writer-calls writer)))))))

(test a-context-is-searched-with-its-chunk-by-keyword-and-by-similarity
  (with-store (store)
    (let ((embedder (make-instance 'word-embedder))
          (plain (rt:make-corpus store "plain" :strategy :hybrid))
          (contextual (%contextual store "contextual")))
      (rt:ingest plain +handbook+ embedder)
      (rt:ingest contextual +handbook+ embedder)
      (is (equal '("1") (ids (rt:retrieve-keyword plain "payout" :locale "en")))
          "control: without contexts, only the section that says payout")
      (is (equal '("1" "2") (sort (ids (rt:retrieve-keyword contextual "payout" :locale "en"))
                                  #'string<))
          "with contexts, the section after it as well")
      ;; The test embedder's query vector for "payout" points along the payout axis. Section 2's
      ;; text alone has no payout component; with its context it has.
      (let ((plain-2 (%passage (rt:retrieve-similar plain embedder "payout") "2"))
            (contextual-2 (%passage (rt:retrieve-similar contextual embedder "payout") "2")))
        (is (> (rt:passage-distance plain-2) 0.5d0))
        (is (< (rt:passage-distance contextual-2) 1d-9))))))

(test an-edit-makes-every-context-of-its-document-stale-and-only-those
  (with-store (store)
    (let* ((writer (make-instance 'context-writer))
           (corpus (%contextual store "handbook" :writer writer)))
      (%sync-handbook corpus)
      (is (= 4 (rt:contextualize-pending corpus)))
      (setf (writer-calls writer) '())
      (rt:sync-document corpus "doc-1" (list (first +handbook+)
                                             (sec "2" "It is sent on the second business day.")))
      (is (= 2 (rt:contextualize-pending corpus))
          "both chunks of the edited document, including the one whose text did not change")
      (is (every (lambda (c) (search "second business day" (getf (first (getf c :parts)) :text)))
                 (writer-calls writer))
          "each was written against the new document")
      (let ((report (rt:sync-document corpus "doc-1"
                                      (list (sec "2" "It is sent on the second business day.")
                                            (first +handbook+)))))
        (is (= 2 (rt:sync-report-updated report)) "a change of order is an update in place"))
      (is (= 2 (rt:contextualize-pending corpus)) "and it changes the document")
      (is (equal '("2" "1" "3" "4") (ids (rt:retrieve-whole corpus))) "in the new order")
      (rt:sync-document corpus "doc-2" (list (third +handbook+)))
      (is (= 1 (rt:contextualize-pending corpus)) "a removed section changes its document")
      (rt:sync-document corpus "doc-2" (list (third +handbook+)))
      (is (= 0 (rt:contextualize-pending corpus)) "an unchanged sync changes nothing"))))

(test a-new-model-or-instruction-makes-every-context-stale
  (with-store (store)
    (let ((first (%contextual store "handbook")))
      (%sync-handbook first)
      (is (= 4 (rt:contextualize-pending first)))
      (flet ((again (&rest keys)
               (rt:contextualize-pending
                (rt:make-corpus store "handbook" :strategy :hybrid
                                :contextualizer (apply #'rt:make-contextualizer
                                                       (make-instance 'context-writer
                                                                      :model "writer-2")
                                                       keys)))))
        (is (= 4 (again)) "another model")
        (is (= 4 (again :instruction "Say where this chunk sits in the document.")) "another instruction")
        (is (= 0 (again :instruction "Say where this chunk sits in the document.")) "the same again")
        (is (= 4 (again :instruction "Say where this chunk sits in the document." :max-tokens 100))
            "another answer limit")))))

(test a-changed-context-is-embedded-again-and-an-unchanged-one-is-not
  (with-store (store)
    (let ((embedder (make-instance 'word-embedder)))
      (flet ((corpus (model tag)
               (%contextual store "handbook"
                            :writer (make-instance 'context-writer
                                                   :model model
                                                   :answer (lambda (document)
                                                             (format nil "~A: ~A" tag
                                                                     (%document-first-line document)))))))
        (rt:ingest (corpus "writer-1" "one") +handbook+ embedder)
        (let ((c (corpus "writer-1" "one")))
          (is (= 0 (rt:embed-pending c embedder)) "contexts are written before the embeddings")
          (let ((c2 (corpus "writer-2" "two")))
            (is (= 4 (rt:contextualize-pending c2)))
            (let ((completeness (rt:retrieval-result-completeness
                                 (rt:retrieve-similar c2 embedder "payout"))))
              (is (eq :not-embedded (rt:truncated-reason completeness)))
              (is (= 4 (rt:truncated-pending completeness))))
            (is (= 4 (rt:embed-pending c2 embedder)) "a new context is embedded again")
            (is (rt:complete-p (rt:retrieval-result-completeness
                                (rt:retrieve-similar c2 embedder "payout")))))
          ;; Another model that writes the same words: the contexts are rewritten, and what is
          ;; embedded is unchanged, so nothing is embedded again.
          (let ((c3 (corpus "writer-3" "two")))
            (is (= 4 (rt:contextualize-pending c3)))
            (is (= 0 (rt:embed-pending c3 embedder)))))))))

(test retrieve-follows-the-corpus-strategy
  (with-store (store)
    (let ((embedder (make-instance 'word-embedder))
          (whole (rt:make-corpus store "whole" :strategy :whole))
          (hybrid (rt:make-corpus store "hybrid" :strategy :hybrid)))
      (rt:sync-document whole "doc-1" (list (sec "b" "Second.") (sec "a" "First.") (sec "c" "Third.")))
      (let ((r (rt:retrieve whole nil "anything" :limit 1)))
        (is (equal '("b" "a" "c") (ids r)) "every chunk, in the order the app handed them in")
        (is (rt:complete-p (rt:retrieval-result-completeness r))))
      (is (eq :whole (rt:corpus-effective-strategy whole)))
      (rt:ingest hybrid +policy+ embedder)
      (is (eq :hybrid (rt:corpus-effective-strategy hybrid)))
      (is (equal (ids (rt:retrieve-hybrid hybrid embedder "refund" :locale "en"))
                 (ids (rt:retrieve hybrid embedder "refund" :locale "en"))))
      (is (equal (ids (rt:retrieve-keyword hybrid "refund"))
                 (ids (rt:retrieve hybrid nil "refund")))
          "with no embedder, keyword search"))))

(defun %lines-containing (text stream)
  (remove-if-not (lambda (line) (search text line))
                 (uiop:split-string (get-output-stream-string stream) :separator '(#\Newline))))

(test an-auto-corpus-changes-strategy-at-its-limit-and-logs-that-once
  (with-store (store)
    (let* ((writer (make-instance 'context-writer))
           (corpus (%contextual store "growing" :writer writer :strategy :auto :whole-limit 20))
           (out (make-string-output-stream))
           (long (make-string 80 :initial-element #\x)))
      (unwind-protect
           (progn
             (aion/log:setup :env :dev :level :info :stream out)
             (let ((report (rt:sync-document corpus "doc-1" (list (sec "1" "Payout rules.")))))
               (is (= 4 (rt:sync-report-size report)) "13 characters is 4 estimated tokens")
               (is (eq :whole (rt:sync-report-strategy report))))
             (is (eq :whole (rt:corpus-effective-strategy corpus)))
             (multiple-value-bind (n status) (rt:contextualize-pending corpus)
               (is (= 0 n))
               (is (eq :whole status)))
             (is (null (writer-calls writer)) "a :WHOLE corpus needs no contexts")
             (let ((report (rt:sync-document corpus "doc-2" (list (sec "2" long :document-id "doc-2")))))
               (is (= 24 (rt:sync-report-size report)) "93 characters")
               (is (= 24 (rt:corpus-size corpus)))
               (is (eq :hybrid (rt:sync-report-strategy report))))
             (rt:sync-document corpus "doc-2" (list (sec "2" long :document-id "doc-2")))
             (is (eq :hybrid (rt:corpus-effective-strategy corpus)))
             (is (= 2 (rt:contextualize-pending corpus)) "the backfill includes the older chunk")
             (let ((lines (%lines-containing "changed strategy" out)))
               (is (= 1 (length lines)) "logged once, though the corpus was synced again: ~S" lines)
               (is (search "corpus=growing" (first lines)))
               (is (search "from=whole" (first lines)))
               (is (search "to=hybrid" (first lines)))
               (is (search "tokens=24" (first lines)))))
        (aion/log:setup :env :dev :level :warn :stream *standard-output*)))))

(defun %ledger (&key (token-cap 100000) (call-cap 2))
  "A ledger for a grant built with the ceiling's own constructor. What is tested here is how the
contextualizer consults and charges a ledger; how a grant is verified is praxeon/tests's."
  (ceiling:make-ledger (ceiling::%make-grant :principal "ingest" :group "app"
                                             :token-cap token-cap :call-cap call-cap
                                             :expires-at (+ (get-universal-time) 3600))))

(test a-backfill-stops-at-the-ledger-s-ceiling-and-keeps-what-it-wrote
  (with-store (store)
    (let* ((writer (make-instance 'context-writer))
           (corpus (%contextual store "handbook" :writer writer))
           (ledger (%ledger :call-cap 2)))
      (%sync-handbook corpus)
      (signals ceiling:budget-exhausted (rt:contextualize-pending corpus :ledger ledger))
      (is (= 2 (length (writer-calls writer))) "the third call was refused before it was made")
      (is (= 2 (%column-count store "context IS NOT NULL")) "the two written are kept")
      (let ((lines (ceiling:usage-report ledger)))
        (is (= 2 (length lines)))
        (is (every (lambda (l) (equal "contextualize" (getf l :means))) lines))
        (is (equal '(0 50) (mapcar (lambda (l) (getf l :cache-read)) lines))
            "the cache counts reach the ledger"))
      (is (= 2 (rt:contextualize-pending corpus :ledger (%ledger :call-cap 2)))
          "the next run carries on where the last stopped")
      (setf (writer-calls writer) '())
      (let ((other (%contextual store "other" :writer writer)))
        (rt:sync-document other "doc-1" (list (first +handbook+)))
        (signals ceiling:budget-exhausted
          (rt:contextualize-pending other :ledger (%ledger :token-cap 10)))
        (is (null (writer-calls writer)) "a call the tokens cannot cover is not made")))))

(test an-explicit-backfill-waits-for-start-backfill
  (with-store (store)
    (let* ((writer (make-instance 'context-writer))
           (corpus (%contextual store "held" :writer writer :strategy :auto :whole-limit 5
                                             :backfill :explicit)))
      (%sync-handbook corpus)
      (is (eq :hybrid (rt:corpus-effective-strategy corpus)))
      (multiple-value-bind (n status) (rt:contextualize-pending corpus)
        (is (= 0 n))
        (is (eq :backfill-not-started status)))
      (is (null (writer-calls writer)))
      (is (eq corpus (rt:start-backfill corpus)))
      (is (= 4 (rt:contextualize-pending corpus)))
      ;; Control: a corpus the app said would be large is :HYBRID from its first sync, so there
      ;; is no backfill to hold.
      (let ((expected (%contextual store "expected" :strategy :auto :whole-limit 1000
                                                    :expected-tokens 5000 :backfill :explicit)))
        (let ((report (rt:sync-document expected "doc-1" (subseq +handbook+ 0 2))))
          (is (< (rt:sync-report-size report) 1000))
          (is (eq :hybrid (rt:sync-report-strategy report))))
        (is (= 2 (rt:contextualize-pending expected)))))))

(test a-table-made-before-contexts-keeps-its-embeddings-and-gets-contexts
  (with-store (store)
    (let ((embedder (make-instance 'word-embedder))
          (c (rt:store-connection store)))
      (rt:ingest (rt:make-corpus store "handbook" :strategy :hybrid) +handbook+ embedder)
      (%drop-columns store '("section_index" "document_fingerprint" "context" "context_deriver"
                             "context_document_fingerprint" "input_fingerprint"))
      (conn:exec c (format nil "DROP TABLE ~A" (rt:corpora-table store)))
      (rt:ensure-schema store)
      (let ((plain (rt:make-corpus store "handbook" :strategy :hybrid)))
        (is (= 0 (rt:embed-pending plain embedder)) "an embedding made before contexts stays current")
        (is (equal '("1" "2" "3" "4") (ids (rt:retrieve-whole plain)))))
      (let ((contextual (%contextual store "handbook")))
        (is (= 4 (rt:contextualize-pending contextual)))
        (is (= 4 (rt:embed-pending contextual embedder)))
        (is (equal '("1" "2") (sort (ids (rt:retrieve-keyword contextual "payout" :locale "en"))
                                    #'string<)))))))

(test evaluate-retrieval-measures-what-contexts-add
  ;; The maintainer's rule on #316: contexts become a default only if the evaluation shows they
  ;; keep recall at least as high. An app measures that by evaluating the same questions on a
  ;; corpus without contexts and on one with them.
  (with-store (store)
    (let ((embedder (make-instance 'word-embedder))
          (plain (rt:make-corpus store "plain" :strategy :hybrid))
          (contextual (%contextual store "contextual"))
          (questions (list (rt:make-eval-question :query "payout sent" :document-id "doc-1"
                                                  :section-id "2"))))
      (rt:ingest plain +handbook+ embedder)
      (rt:ingest contextual +handbook+ embedder)
      (flet ((hits (corpus)
               (getf (first (rt:evaluate-retrieval corpus embedder questions :k 1 :locale "en"
                                                                               :strategies '(:keyword)))
                     :hits)))
        (is (= 0 (hits plain)) "without contexts, the shorter chunk that says payout ranks first")
        (is (= 1 (hits contextual)) "with them, the chunk that says both words")))))

(test a-context-cut-off-at-the-answer-limit-is-not-stored
  "#338's rule for every caller of COMPLETE: a context that stopped at the output limit is not
written as though it were whole."
  (with-store (store)
    (let* ((writer (make-instance 'context-writer :stop :max-tokens))
           (corpus (%contextual store "handbook" :writer writer)))
      (%sync-handbook corpus)
      (signals cnd:deliberation-failure (rt:contextualize-pending corpus))
      (is (= 0 (%column-count store "context IS NOT NULL")) "nothing was stored"))))

;;; --- reranking (#316, step 4) ---------------------------------------------------------------
;;;
;;; A stand-in reranker scores a document by how often it contains WORD, so a test can make it
;;; disagree with the fused order on purpose. It records what it was sent.

(defclass word-reranker (llm:reranker)
  ((word :initarg :word :reader reranker-word)
   (calls :initform '() :accessor reranker-calls)))

(defmethod llm:rerank ((r word-reranker) query documents)
  (push (list query documents) (reranker-calls r))
  (stable-sort (loop for d in documents for i from 0
                     collect (cons i (float (%count-of (reranker-word r) d) 1d0)))
               #'> :key #'cdr))

(defparameter +support+
  (append +policy+ (list (sec "4" "Error TS-999 appears when a card expires."))))

(test a-reranker-reorders-the-merged-candidates-before-the-limit-is-taken
  (with-store (store)
    (let ((corpus (rt:make-corpus store "support" :strategy :hybrid))
          (embedder (make-instance 'word-embedder))
          (reranker (make-instance 'word-reranker :word "expires")))
      (rt:ingest corpus +support+ embedder)
      (is (not (equal "4" (first (ids (rt:retrieve-hybrid corpus embedder "refund" :limit 1)))))
          "control: without the reranker, the refund policy comes first")
      (let ((r (rt:retrieve-hybrid corpus embedder "refund" :limit 1 :reranker reranker)))
        (is (equal '("4") (ids r)) "the reranker's choice, then the limit")
        (is (= 1d0 (rt:passage-score (first (rt:retrieval-result-passages r))))
            "the score is the reranker's")
        (is (rt:complete-p (rt:retrieval-result-completeness r))))
      (destructuring-bind (query documents) (first (reranker-calls reranker))
        (is (equal "refund" query))
        (is (= 4 (length documents)) "every merged candidate, up to the rerank limit"))
      (rt:retrieve-hybrid corpus embedder "refund" :limit 1 :reranker reranker :rerank-candidates 2)
      (is (= 2 (length (second (first (reranker-calls reranker)))))
          ":rerank-candidates caps what the reranker is sent"))))

(test a-reranker-reads-each-candidate-s-context-and-text
  (with-store (store)
    (let ((corpus (%contextual store "handbook"))
          (embedder (make-instance 'word-embedder))
          (reranker (make-instance 'word-reranker :word "first business day")))
      (rt:ingest corpus +handbook+ embedder)
      (let ((r (rt:retrieve-hybrid corpus embedder "payout" :reranker reranker)))
        (is (equal "2" (first (ids r))))
        (is (equal "It is sent on the first business day of the month."
                   (rt:passage-text (first (rt:retrieval-result-passages r))))
            "the passage is still the chunk's own text"))
      (is (find (format nil "This passage is from the document that begins: Payout rules.~%~%It is sent on the first business day of the month.")
                (second (first (reranker-calls reranker))) :test #'equal)
          "what the reranker read was the context, a blank line and the text"))))

(test retrieve-passes-the-reranker-for-a-hybrid-corpus-and-not-a-whole-one
  (with-store (store)
    (let ((hybrid (rt:make-corpus store "hybrid" :strategy :hybrid))
          (whole (rt:make-corpus store "whole" :strategy :whole))
          (embedder (make-instance 'word-embedder))
          (reranker (make-instance 'word-reranker :word "expires")))
      (rt:ingest hybrid +support+ embedder)
      (rt:ingest whole +support+ embedder)
      (is (equal '("4") (ids (rt:retrieve hybrid embedder "refund" :limit 1 :reranker reranker))))
      (is (not (equal '("4") (ids (rt:retrieve hybrid nil "refund card" :limit 1))))
          "control: keyword search alone puts the refund policy first")
      (is (equal '("4") (ids (rt:retrieve hybrid nil "refund card" :limit 1 :reranker reranker)))
          "with no embedder, the keyword candidates are reranked")
      (setf (reranker-calls reranker) '())
      (is (= 4 (length (ids (rt:retrieve whole embedder "refund" :limit 1 :reranker reranker)))))
      (is (null (reranker-calls reranker)) "a whole corpus is not reranked"))))

(test the-search-means-passes-its-reranker-to-retrieve
  (with-store (store)
    (let* ((corpus (rt:make-corpus store "support" :strategy :hybrid))
           (embedder (make-instance 'word-embedder))
           (reranker (make-instance 'word-reranker :word "expires"))
           (agent (actor:make-agent)))
      (rt:ingest corpus +support+ embedder)
      (signals error (rt:register-corpus-search agent corpus embedder #'%render :reranker t))
      (rt:register-corpus-search agent corpus embedder #'%render :limit 1 :reranker reranker)
      (is (search "[§4]" (actor:act agent "search-documents" (%args "query" "refund"))))
      (setf (reranker-calls reranker) '())
      (actor:act agent "search-documents" (%args "query" "refund" "match" "words"))
      (is (null (reranker-calls reranker)) "a search by words is not reranked"))))

(test evaluate-retrieval-reports-the-reranked-configuration
  (with-store (store)
    (let ((corpus (rt:make-corpus store "support" :strategy :hybrid))
          (embedder (make-instance 'word-embedder))
          (reranker (make-instance 'word-reranker :word "expires")))
      (rt:ingest corpus +support+ embedder)
      (let* ((questions (list (rt:make-eval-question :query "refund card" :document-id "doc-1"
                                                     :section-id "4")))
             (report (rt:evaluate-retrieval corpus embedder questions :k 1 :locale "en"
                                                                      :reranker reranker))
             (by (lambda (s) (find s report :key (lambda (r) (getf r :strategy))))))
        (is (equal '(:similar :keyword :hybrid :reranked)
                   (mapcar (lambda (r) (getf r :strategy)) report))
            "a reranker adds the :reranked configuration")
        (is (= 0 (getf (funcall by :similar) :hits)))
        (is (= 1 (getf (funcall by :reranked) :hits))))
      (is (equal '(:similar :keyword :hybrid)
                 (mapcar (lambda (r) (getf r :strategy))
                         (rt:evaluate-retrieval corpus embedder '() :k 1)))
          "control: without one, the three configurations of step 2"))))
