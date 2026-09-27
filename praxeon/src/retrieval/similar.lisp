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
  "SYNC-CORPUS, then EMBED-PENDING. Returns the SYNC-REPORT and the number embedded."
  (let ((report (sync-corpus corpus sections)))
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
        (setf rows (let ((q:*warn-unindexed-vector-distance* nil)) ; the exact scan is the design
                     (rc::%fetch store
                                 (list :select (append rc::+passage-columns+
                                                       (list (list :as (list :<=> :embedding vector-text)
                                                                   :distance)))
                                       :from (list (store-table store))
                                       :where (corpus-where corpus
                                                            (list := :embedding_deriver deriver)
                                                            (list :is-not-null :embedding))
                                       :order-by '(:distance)
                                       :limit limit))))
        (when *between-similar-reads* (funcall *between-similar-reads*))
        (setf pending (%pending-count corpus deriver))))
    (rc::%make-retrieval-result
     (rc::%rows->passages corpus rows :with-distance t)
     (if (plusp pending)
         (make-truncated :reason :not-embedded :pending pending)
         (make-complete)))))
