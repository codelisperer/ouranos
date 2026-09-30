;;;; retrieval/similar.lisp --- embedding a corpus, and similarity retrieval (#138).
;;;;
;;;; The half of praxeon/retrieval that needs an embedding provider. Syncing and exact
;;;; retrieval are in corpus.lisp, in a package that cannot name one.
;;;;
;;;; THE PROVIDER IS PASSED IN, NEVER RESOLVED HERE (#158). An app resolves it once with
;;;; `praxeon/llm:make-embedding-provider-from-env' on the thread that owns the role, and
;;;; handles `praxeon/conditions:no-embedding-provider' there by using exact retrieval alone.
;;;;
;;;; SIMILARITY IS AN EXACT SCAN WITHIN ONE CORPUS in the first build. The query filters on the
;;;; corpus and on the deriver through a b-tree index, and computes the cosine distance of every
;;;; chunk that passes. There is no vector index, so no index can return fewer rows than asked
;;;; after the filter, and a result is COMPLETE whenever every chunk has a current embedding.
;;;; The pull request for #138 reports the scan's time at the first app's corpus sizes.

(in-package #:praxeon/retrieval)

(defun deriver-of (embedder)
  "The deriver recorded with an embedding: the model id and the width, for example
\"voyage-4/1024\". ADR-0002 counts a changed width as a changed deriver."
  (format nil "~A/~D"
          (or (llm:embedding-model-of embedder) (string-downcase (type-of embedder)))
          (llm:embedding-dimensions embedder)))

(defun %stale-clause (deriver)
  "Chunks with no embedding from DERIVER: never embedded, or embedded by another model."
  (list :or (list :is-null :embedding_fingerprint)
        (list :is-null :embedding_deriver)
        (list :<> :embedding_deriver deriver)))

(defun %check-width (corpus embedder)
  (llm:check-embedding-dimensions embedder (store-dimensions (corpus-store corpus))
                                  :source (format nil "the chunk store ~A"
                                                  (store-table (corpus-store corpus)))))

(defun %vector-text (store vector)
  "VECTOR in the text form pgvector accepts, through mnemosyne's cast, which also refuses a
vector of the wrong width before it reaches the database."
  (let ((changeset (cs:cast (rc::store-schema-name store) (list :embedding vector) '(:embedding))))
    (unless (cs:changeset-valid-p changeset)
      (error 'praxeon/conditions:deliberation-failure
             :detail (format nil "embedding rejected by cast: ~S" (cs:changeset-errors changeset))))
    (cs:get-change changeset :embedding)))

(defun embed-pending (corpus embedder &key (batch-size 64))
  "Embed every chunk of CORPUS that has no embedding from EMBEDDER's current model, as
documents, in batches of BATCH-SIZE texts. Returns the number of chunks embedded.

This is also the re-embed after a model change: every chunk whose recorded deriver differs is
pending. A vector is written only if its chunk still holds the text that was embedded, so a
chunk replaced by a sync in the meantime keeps its NULL embedding and is embedded next time.
Serialised per corpus with the syncs (WITH-CORPUS-LOCK). The provider is called outside the
database lock, so searches on the same store can run during the call."
  (unless (typep batch-size '(integer 1))
    (error "praxeon/retrieval: :batch-size must be a positive integer, not ~S" batch-size))
  (%check-width corpus embedder)
  (let* ((store (corpus-store corpus))
         (table (store-table store))
         (deriver (deriver-of embedder))
         (last-id nil)
         (count 0))
    (with-corpus-lock (corpus)
      (loop
        (let ((rows (rc::%fetch store
                                (list :select '(:id :text :section_fingerprint)
                                      :from (list table)
                                      :where (apply #'corpus-where corpus
                                                    (%stale-clause deriver)
                                                    (when last-id (list (list :> :id last-id))))
                                      :order-by '(:id)
                                      :limit batch-size))))
          (when (null rows) (return count))
          (let ((vectors (llm:embed-documents
                          embedder (mapcar (lambda (r) (param:row-value r :text)) rows))))
            (rc::with-db (store)
              (conn:with-transaction ((store-connection store))
                (loop for row in rows
                      for vector in vectors
                      for text = (param:row-value row :text)
                      for n = (rc::%run store
                                        (list :update table
                                              :set (list :embedding (%vector-text store vector)
                                                         ;; The embedding's input is the chunk
                                                         ;; text, so its fingerprint covers that
                                                         ;; text alone (ADR-0002).
                                                         :embedding_fingerprint
                                                         (section-fingerprint text)
                                                         :embedding_deriver deriver)
                                              :where (corpus-where
                                                      corpus
                                                      (list := :id (param:row-value row :id))
                                                      (list := :section_fingerprint
                                                            (param:row-value row :section_fingerprint)))))
                      do (when (and (integerp n) (plusp n)) (incf count)))))
            (setf last-id (param:row-value (car (last rows)) :id))))))))

(defun ingest (corpus sections embedder &key (batch-size 64))
  "SYNC-CORPUS, then INDEX-PENDING and EMBED-PENDING. Returns the SYNC-REPORT and the number
embedded. INDEX-PENDING finds nothing to do unless chunks were synced before #316 or the
tokenizer changed, since a sync writes the terms of what it inserts."
  (let ((report (sync-corpus corpus sections)))
    (index-pending corpus)
    (values report (embed-pending corpus embedder :batch-size batch-size))))

(defvar *between-similar-reads* nil
  "Test seam: a function called between RETRIEVE-SIMILAR's two reads, or NIL. The suite uses it
to commit an embedding from another session at that moment and check that the result still
describes one snapshot.")

(defun %pending-count (corpus deriver)
  (let ((row (first (rc::%fetch (corpus-store corpus)
                                (list :select (list (list :as (list :count :*) :n))
                                      :from (list (store-table (corpus-store corpus)))
                                      :where (corpus-where corpus (%stale-clause deriver)))))))
    (or (and row (param:row-value row :n)) 0)))

(defgeneric retrieve-similar (corpus embedder query &key limit)
  (:documentation "The LIMIT chunks of CORPUS nearest to QUERY by cosine distance, nearest
first, each with its DISTANCE. QUERY is text: EMBEDDER embeds it as a query, and only chunks
embedded by the same model and width are compared with it, because a vector from one model
compared with vectors from another gives well-formed, meaningless neighbours.

Returns a RETRIEVAL-RESULT. COMPLETE means every chunk of the corpus was a candidate.
TRUNCATED with reason :NOT-EMBEDDED gives the number of chunks that were not, because they have
no embedding from this model yet: the normal state while EMBED-PENDING catches up after a sync
or a model change."))

(defun %similar-rows (corpus deriver vector-text limit)
  "The rows of CORPUS's LIMIT chunks nearest VECTOR-TEXT among those DERIVER embedded, nearest
first, with their ID and DISTANCE."
  (let ((q:*warn-unindexed-vector-distance* nil)) ; the exact scan is the design
    (rc::%fetch (corpus-store corpus)
                (list :select (append rc::+passage-columns+
                                      (list :id (list :as (list :<=> :embedding vector-text)
                                                      :distance)))
                      :from (list (store-table (corpus-store corpus)))
                      :where (corpus-where corpus
                                           (list := :embedding_deriver deriver)
                                           (list :is-not-null :embedding))
                      :order-by '(:distance)
                      :limit limit))))

(defmethod retrieve-similar ((corpus corpus) embedder query &key (limit 10))
  (%check-width corpus embedder)
  (let* ((store (corpus-store corpus))
         (deriver (deriver-of embedder))
         (vector-text (%vector-text store (llm:embed-query embedder query)))
         rows pending)
    ;; ONE SNAPSHOT FOR BOTH READS. The candidates and the count of chunks that could not be
    ;; candidates are read in one REPEATABLE READ transaction. Read separately, an
    ;; EMBED-PENDING committing in between would fill a chunk after the candidate query missed
    ;; it and before the count, and the result would say COMPLETE while leaving that chunk out.
    (rc::with-db (store)
      (conn:with-transaction ((store-connection store))
        (conn:exec (store-connection store) "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        (setf rows (%similar-rows corpus deriver vector-text limit))
        (when *between-similar-reads* (funcall *between-similar-reads*))
        (setf pending (%pending-count corpus deriver))))
    (rc::%make-retrieval-result
     (rc::%rows->passages corpus rows :with-distance t)
     (if (plusp pending)
         (make-truncated :reason :not-embedded :pending pending)
         (make-complete)))))

;;; --- the entry point a caller searches through ----------------------------------------

(defgeneric retrieve (corpus embedder query &key limit)
  (:documentation "The passages of CORPUS that answer QUERY, best first, as a RETRIEVAL-RESULT:
the same type RETRIEVE-SIMILAR and RETRIEVE-EXACT return, with the same COMPLETE and TRUNCATED
values. This is the call an agent's search tool makes (REGISTER-CORPUS-SEARCH), so that how a
corpus is searched can change without changing the tool.

For a CORPUS it is RETRIEVE-SIMILAR with a default LIMIT of 20. A later version will choose the
method by the corpus's retrieval strategy (#316); a keyword added for that will default to NIL,
so a call written against this one keeps working."))

(defmethod retrieve ((corpus corpus) embedder query &key (limit 20))
  (retrieve-similar corpus embedder query :limit limit))

;;; --- hybrid retrieval (#316) -----------------------------------------------------------

(defparameter *hybrid-candidates* 150
  "How many candidates RETRIEVE-HYBRID takes from each search before merging them, #316's
figure.")

(defparameter *rrf-k* 60
  "The constant K in reciprocal rank fusion: each list contributes 1 / (K + rank).")

(defun %not-ready-count (corpus deriver)
  "Chunks of CORPUS that one of the two searches could not consider: no embedding from
DERIVER, or no terms from the current tokenizer."
  (let ((row (first (rc::%fetch (corpus-store corpus)
                                (list :select (list (list :as (list :count :*) :n))
                                      :from (list (store-table (corpus-store corpus)))
                                      :where (corpus-where corpus
                                                           (list :or (%stale-clause deriver)
                                                                 (rc::%unindexed-clause))))))))
    (or (and row (param:row-value row :n)) 0)))

(defgeneric retrieve-hybrid (corpus embedder query &key limit locale candidates)
  (:documentation "The LIMIT chunks of CORPUS that best match QUERY by embedding similarity and
BM25 together (#316). Each search contributes up to CANDIDATES chunks, and the two rankings are
merged by reciprocal rank fusion (PRAXEON/RETRIEVAL/FUSION), which uses ranks only, so the
distance and the BM25 score never have to be compared. A chunk found by both searches appears
once. Each passage's SCORE is its fused score; its DISTANCE is NIL. LOCALE chooses the stop
words dropped from QUERY for the keyword search, as in RETRIEVE-KEYWORD.

Returns a RETRIEVAL-RESULT. COMPLETE means every chunk was a candidate in both searches.
TRUNCATED counts, as PENDING, the chunks that have no embedding from this model or no terms from
the current tokenizer; its reason is :NOT-EMBEDDED if any chunk lacks an embedding, and
:NOT-INDEXED otherwise."))

(defmethod retrieve-hybrid ((corpus corpus) embedder query
                            &key (limit 20) locale (candidates *hybrid-candidates*))
  (%check-width corpus embedder)
  (let* ((store (corpus-store corpus))
         (deriver (deriver-of embedder))
         ;; The provider is called before the database lock is taken, as in RETRIEVE-SIMILAR.
         (vector-text (%vector-text store (llm:embed-query embedder query)))
         similar keyword not-ready not-embedded)
    (rc::with-db (store)
      (conn:with-transaction ((store-connection store))
        (conn:exec (store-connection store) "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        (setf similar (%similar-rows corpus deriver vector-text candidates)
              keyword (rc::%keyword-rows corpus query candidates locale)
              not-ready (%not-ready-count corpus deriver)
              not-embedded (%pending-count corpus deriver))))
    (let* ((by-id (make-hash-table :test #'equal))
           (rankings (list (mapcar (lambda (r) (param:row-value r :id)) similar)
                           (mapcar (lambda (r) (param:row-value r :id)) keyword))))
      (dolist (row (append keyword similar))
        (setf (gethash (param:row-value row :id) by-id) row))
      (let* ((rankings (boundary:check-elements rankings 'list
                                                :function 'fusion:fused-ids :argument 'rankings))
             (ids (fusion:fused-ids *rrf-k* rankings))
             (scores (fusion:fused-scores *rrf-k* rankings))
             (n (min limit (length ids))))
        (rc::%make-retrieval-result
         (rc::%rows->passages corpus
                              (mapcar (lambda (id) (gethash id by-id)) (subseq ids 0 n))
                              :scores (subseq scores 0 n))
         (cond ((zerop not-ready) (make-complete))
               ((plusp not-embedded) (make-truncated :reason :not-embedded :pending not-ready))
               (t (make-truncated :reason :not-indexed :pending not-ready))))))))

;;; --- measuring retrieval on an app's own questions (#316) ---------------------------------

(defstruct (eval-question (:constructor make-eval-question (&key query document-id section-id)))
  "A question for EVALUATE-RETRIEVAL: QUERY, and the section that answers it, named by its
DOCUMENT-ID and SECTION-ID (in any locale)."
  query document-id section-id)

(defun %answers-p (passage question)
  (let ((p (passage-provenance passage)))
    (and (equal (provenance-document-id p) (eval-question-document-id question))
         (equal (provenance-section-id p) (eval-question-section-id question)))))

(defun %retrieve-by (strategy corpus embedder query k locale)
  (ecase strategy
    (:similar (retrieve-similar corpus embedder query :limit k))
    (:keyword (retrieve-keyword corpus query :limit k :locale locale))
    (:hybrid (retrieve-hybrid corpus embedder query :limit k :locale locale))))

(defun evaluate-retrieval (corpus embedder questions
                           &key (k 20) locale (strategies '(:similar :keyword :hybrid)))
  "For each of STRATEGIES, how often the section that answers a question in QUESTIONS (a list
of EVAL-QUESTIONs) is among the top K passages (#316). Returns one plist per strategy:
(:strategy S :k K :questions N :hits H :recall H/N :incomplete I), where RECALL is a ratio and
INCOMPLETE counts the questions whose result was TRUNCATED, which means the corpus was not fully
embedded or indexed when the figure was taken.

The strategies are :SIMILAR (embeddings only), :KEYWORD (BM25 only) and :HYBRID (both, merged).
EMBEDDER is needed for :SIMILAR and :HYBRID. An app runs this on its own documents and questions
before choosing a default, as the maintainer's rule on #316 requires: a cheaper configuration
becomes the default only if its recall is at least as high."
  (loop for strategy in strategies
        collect (let ((hits 0) (incomplete 0))
                  (dolist (question questions)
                    (let ((result (%retrieve-by strategy corpus embedder
                                                (eval-question-query question) k locale)))
                      (when (truncated-p (retrieval-result-completeness result))
                        (incf incomplete))
                      (when (find-if (lambda (p) (%answers-p p question))
                                     (retrieval-result-passages result))
                        (incf hits))))
                  (list :strategy strategy :k k :questions (length questions) :hits hits
                        :recall (if questions (/ hits (length questions)) 0)
                        :incomplete incomplete))))
