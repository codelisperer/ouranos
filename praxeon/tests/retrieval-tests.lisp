;;;; retrieval-tests.lisp --- praxeon/retrieval against a real Postgres with pgvector (#138).
;;;;
;;;; Every test needs Postgres, and skips with the reason when MNEMOSYNE_TEST_PG_URL is not set.
;;;; Each test gets a fresh table, named with the pid and a random suffix, and drops it after.
;;;; The embedder is a deterministic stand-in: the protocol, the width checks, the store and the
;;;; SQL are the real code.

(cl:defpackage #:praxeon/retrieval/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:rt #:praxeon/retrieval)
                    (#:rc #:praxeon/retrieval/corpus)
                    (#:llm #:praxeon/llm)
                    (#:cnd #:praxeon/conditions)
                    (#:ctx #:praxeon/context)
                    (#:conn #:mnemosyne/conn)
                    (#:url #:mnemosyne/url)
                    (#:mig #:mnemosyne/migrate)
                    (#:param #:mnemosyne/param)
                    (#:q #:mnemosyne/query)
                    (#:bt #:bordeaux-threads)
                    (#:tt #:aion/test-threads))
  (:export #:run-tests))

(in-package #:praxeon/retrieval/tests)

(def-suite retrieval :description "Document retrieval over corpora (#138).")
(in-suite retrieval)

(defun %pg-url () (uiop:getenv "MNEMOSYNE_TEST_PG_URL"))

(def-suite chunkers :description "Chunkers, which need no database (#322).")

(defun run-tests ()
  "Run both suites and print the Postgres coverage in the form scripts/verify-tree.lisp reads.
Every check in RETRIEVAL needs Postgres, so a run without it skips them all, and the
BACKEND-CHECKS line is what keeps that from reading as a pass (#171). CHUNKERS needs no
database, so its checks are not counted in that line."
  (let* ((url (%pg-url))
         (chunker-results (run 'chunkers))
         (results (run 'retrieval)))
    (explain! (append chunker-results results))
    (if url
        (format t "~&BACKEND-CHECKS postgres ~D~%"
                (count-if-not (lambda (r) (typep r 'fiveam::test-skipped)) results))
        (format t "~&BACKEND-CHECKS postgres SKIPPED (MNEMOSYNE_TEST_PG_URL is not set)~%"))
    (finish-output)
    (and (results-status chunker-results) (results-status results))))

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

(defun %connect () (conn:connect (url:backend-from-url (%pg-url))))

(defmacro with-store ((store-var &key (dimensions 4) (table '(%table-name))) &body body)
  "A fresh chunk table and a store over it; the table is dropped afterwards."
  (let ((c (gensym "CONN")) (tb (gensym "TABLE")))
    `(if (not (%pg-url))
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
             (conn:disconnect ,c))))))

(defun sec (id text &rest keys &key (document-id "doc-1") (locale "en") &allow-other-keys)
  (apply #'rt:make-section :id id :text text :document-id document-id :locale locale
         :locator (format nil "§~A" id)
         (loop for (k v) on keys by #'cddr
               unless (member k '(:document-id :locale)) append (list k v))))

(defun ids (result)
  (mapcar (lambda (p) (rt:provenance-section-id (rt:passage-provenance p)))
          (rt:retrieval-result-passages result)))

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
          (conn:disconnect admin)))))

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
        (is (eq wider (rt:ensure-schema wider)) "and the check now passes")))))

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
        (conn:disconnect conn-b)))))

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
that chunk out, still says TRUNCATED with one pending, not COMPLETE."
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
        (conn:disconnect conn-b)))))

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
