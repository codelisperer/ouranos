;;;; retrieval/corpus.lisp --- document corpora, their chunks, and exact retrieval (#138).
;;;;
;;;; The design is #138's proposal as ruled, with the many-corpora change:
;;;;   https://github.com/codelisperer/ouranos/issues/138#issuecomment-5839103971  (proposal)
;;;;   https://github.com/codelisperer/ouranos/issues/138#issuecomment-5839134010  (ruling)
;;;;   https://github.com/codelisperer/ouranos/issues/138#issuecomment-5857190973  (many corpora)
;;;;
;;;; THIS PACKAGE DOES NOT USE PRAXEON/LLM. Syncing a corpus and exact retrieval need no
;;;; embedding provider, and keeping them in a package that cannot name one means exact
;;;; retrieval cannot reach the embedding path: its query never selects or compares the
;;;; embedding column, and nothing here can compute a vector. Embedding and similarity
;;;; retrieval are in praxeon/retrieval (similar.lisp).
;;;;
;;;; ONE CHUNK TABLE PER STORE, WITH A CORPUS COLUMN. An app creates corpora at runtime (one per
;;;; community or persona) without a deploy, so creating a corpus must not need DDL. A corpus
;;;; is therefore a name and its rows. Access is per corpus, so every query here is built with
;;;; CORPUS-WHERE, the one function that writes the corpus predicate, and it binds the corpus
;;;; name as a parameter.
;;;;
;;;; POSTGRES ONLY in this first build: the table has a `vector' column, which mnemosyne
;;;; reports as unsupported on SQLite, and exact retrieval uses ILIKE.

(in-package #:praxeon/retrieval/corpus)

;;; --- conditions --------------------------------------------------------------

(define-condition retrieval-error (praxeon/conditions:praxeon-error) ()
  (:documentation "Root of the conditions praxeon/retrieval signals."))

(define-condition invalid-section (retrieval-error)
  ((section :initarg :section :reader invalid-section-section)
   (problem :initarg :problem :reader invalid-section-problem))
  (:report (lambda (c s)
             (format s "Section ~S cannot be synced: ~A"
                     (let ((sec (invalid-section-section c)))
                       (if (section-p sec) (section-id sec) sec))
                     (invalid-section-problem c))))
  (:documentation "Signalled by a sync when a section record is incomplete or inconsistent.
Nothing from that sync is written."))

(define-condition embedding-width-changed (retrieval-error)
  ((table :initarg :table :reader embedding-width-changed-table)
   (stored :initarg :stored :reader embedding-width-changed-stored)
   (configured :initarg :configured :reader embedding-width-changed-configured))
  (:report
   (lambda (c s)
     (format s "The embedding column of ~A holds ~A, and the store is configured for vector(~D).~%~%A vector of one width cannot be stored in a column of another, so re-embedding cannot fix this. The RECREATE-EMBEDDING-COLUMN restart drops the column and creates it empty at the configured width, which clears every stored embedding in every corpus of this table; the next EMBED-PENDING fills it again. That is an operator's decision, so nothing takes it automatically."
             (embedding-width-changed-table c) (embedding-width-changed-stored c)
             (embedding-width-changed-configured c))))
  (:documentation "Signalled by ENSURE-SCHEMA when the live embedding column's width differs
from the store's. A RECREATE-EMBEDDING-COLUMN restart is established around it."))

;;; --- fingerprints --------------------------------------------------------------

(defun %sha256-hex (string)
  (ironclad:byte-array-to-hex-string
   (ironclad:digest-sequence :sha256 (sb-ext:string-to-octets string :external-format :utf-8))))

(defun section-fingerprint (text)
  "The fingerprint praxeon/retrieval records for section TEXT: SHA-256 over mnemosyne's framing
of the text (ADR-0002), as lowercase hex.

AN APP CALLS THIS, AND NOTHING ELSE, to fingerprint the original text a translation was made
from (a section's SOURCE-FINGERPRINT). A different hash or framing would disagree with the
fingerprint stored here, and every comparison would say `made from an older original' without
an error."
  (der:content-fingerprint (list text) :hash #'%sha256-hex))

;;; --- sections: what the app hands in -----------------------------------------

(defstruct (section (:constructor make-section
                        (&key id document-id document-version locator locale
                              (locale-role :source) derived-from source-fingerprint text)))
  "One section of an app's document, as the app hands it to a sync. Built with MAKE-SECTION.

ID            the section's stable id in the app
DOCUMENT-ID   the document it belongs to
DOCUMENT-VERSION  the app's version of that document, or NIL. Never filled in by praxeon.
LOCATOR       where the section sits, as a reader would cite it (a clause number, a heading)
LOCALE        the language of TEXT
LOCALE-ROLE   :SOURCE for the original, :DERIVED for a translation
DERIVED-FROM  for a translation, the id of the section it translates (for an app that stores a
              translation as another locale of the same section, its own ID)
SOURCE-FINGERPRINT  for a translation, SECTION-FINGERPRINT of the original text it was made
              from, or NIL when the app did not record it
TEXT          the section's text"
  id document-id document-version locator locale locale-role derived-from source-fingerprint
  text)

(defun %check-section (section)
  (flet ((bad (problem) (error 'invalid-section :section section :problem problem)))
    (unless (section-p section) (bad "it is not a section record; build it with MAKE-SECTION"))
    (dolist (slot '(section-id section-document-id section-locale section-text))
      (let ((v (funcall slot section)))
        (unless (and (stringp v) (plusp (length v)))
          (bad (format nil "~(~A~) must be a non-empty string, not ~S"
                       (subseq (symbol-name slot) 8) v)))))
    (case (section-locale-role section)
      (:source)
      (:derived (unless (and (stringp (section-derived-from section))
                             (plusp (length (section-derived-from section))))
                  (bad "a :derived section must name the section it translates in DERIVED-FROM")))
      (t (bad (format nil "locale-role must be :SOURCE or :DERIVED, not ~S"
                      (section-locale-role section)))))
    section))

;;; --- chunkers ----------------------------------------------------------------

(defstruct (chunk (:constructor make-chunk (&key text sub-locator boundary)))
  "One piece of a section as a chunker cut it. BOUNDARY is what the chunker claims about it:
:WHOLE-SECTION, :WHOLE-PARAGRAPH, :WHOLE-CLAUSE, or :WINDOW when it may split a unit."
  text sub-locator boundary)

(defparameter +boundaries+ '(:whole-section :whole-paragraph :whole-clause :window))

(defgeneric chunk-section (chunker section)
  (:documentation "SECTION's text as a list of CHUNKs, in order. A chunker must not claim more
than it did: a piece that may split a unit is a :WINDOW."))

(defgeneric chunker-id (chunker)
  (:documentation "The chunker's name and version as a string, recorded on every chunk it cut.
Changing it re-chunks every section of a corpus on the next sync."))

(defclass section-chunker () ()
  (:documentation "The whole section is one chunk, claiming :WHOLE-SECTION. The first build's
only chunker (#138): both of the first app's corpora store one unit per section."))

(defmethod chunk-section ((c section-chunker) section)
  (list (make-chunk :text (section-text section) :sub-locator nil :boundary :whole-section)))

(defmethod chunker-id ((c section-chunker)) "section/1")

;;; --- the store and its corpora -------------------------------------------------

(defvar *table* "praxeon_chunks" "Default chunk table name.")

(defclass chunk-store ()
  ((connection :initarg :connection :reader store-connection)
   (table :initarg :table :reader store-table)
   (dimensions :initarg :dimensions :reader store-dimensions)
   (schema-name :initarg :schema-name :reader store-schema-name)
   (db-lock :initform (bt:make-recursive-lock "praxeon-retrieval-db") :reader store-db-lock)
   (corpus-locks :initform (make-hash-table :test #'equal) :reader %corpus-locks)
   (corpus-locks-guard :initform (bt:make-lock "praxeon-retrieval-corpora")
                       :reader %corpus-locks-guard))
  (:documentation "One chunk table on one connection. Every corpus that shares an embedding
width can live in it.

STATEMENTS ON THE CONNECTION ARE SERIALISED by a lock, because one database connection cannot
run two statements at once. An ingest holds the connection for as long as a sync runs, so an
app that ingests while it serves searches gives each its own store over its own connection,
both naming the same table."))

(defun %schema-fields (dimensions)
  `((:id                 :string :primary t)
    (:corpus             :string :required t)
    (:section_id         :string :required t)
    (:locale             :string :required t)
    (:chunk_index        :integer :required t)
    (:document_id        :string :required t)
    (:document_version   :string)
    (:locator            :text)
    (:sub_locator        :string)
    (:locale_role        :string :required t)
    (:derived_from       :string)
    (:source_fingerprint :string)
    (:chunker            :string :required t)
    (:boundary           :string :required t)
    (:text               :text :required t)
    (:section_fingerprint :string :required t)
    (:embedding          :vector :dimensions ,dimensions :derived-from :text)))

(defun make-chunk-store (connection &key (table *table*) dimensions ensure)
  "A chunk store over CONNECTION (a Postgres connection) in TABLE, with embeddings DIMENSIONS
wide. DIMENSIONS is required: it is the width of the embedding model the app uses, for example
(praxeon/llm:embedding-dimensions embedder). With ENSURE, runs ENSURE-SCHEMA."
  (check-type table string)
  (unless (and (integerp dimensions) (plusp dimensions))
    (error "praxeon/retrieval: :dimensions must be the embedding width, a positive integer, not ~S"
           dimensions))
  (unless (eq (dbi:connection-driver-type connection) :postgres)
    (error "praxeon/retrieval: the first build runs on Postgres only (#138); this connection's driver is ~S"
           (dbi:connection-driver-type connection)))
  (let* ((name (intern (format nil "RETRIEVAL-~:@(~A~)" table) '#:praxeon/retrieval/corpus))
         (store (progn
                  (schema:register-schema
                   (schema:make-schema name table (%schema-fields dimensions)))
                  (make-instance 'chunk-store :connection connection :table table
                                              :dimensions dimensions :schema-name name))))
    (when ensure (ensure-schema store))
    store))

(defclass corpus ()
  ((store :initarg :store :reader corpus-store)
   (name :initarg :name :reader corpus-name)
   (chunker :initarg :chunker :reader corpus-chunker))
  (:documentation "A named set of documents searched together. Its rows are in its store's
table, marked with its NAME. Creating one writes nothing: a corpus exists once it has rows."))

(defun make-corpus (store name &key (chunker (make-instance 'section-chunker)))
  "The corpus NAME (a non-empty string) in STORE. Cheap, and runs no SQL."
  (unless (and (stringp name) (plusp (length name)))
    (error "praxeon/retrieval: a corpus name must be a non-empty string, not ~S" name))
  (make-instance 'corpus :store store :name name :chunker chunker))

(defun corpus-where (corpus &rest clauses)
  "The WHERE clause restricting a query to CORPUS, ANDed with CLAUSES.

THE ONLY PLACE THE CORPUS PREDICATE IS WRITTEN (#138). Access is per corpus, so a query that
lost this predicate would show one community another's material. The corpus name is a string,
which the query DSL always binds as a parameter."
  (let ((own (list := :corpus (corpus-name corpus))))
    (if clauses (list* :and own clauses) own)))

;;; --- schema --------------------------------------------------------------------

(defmacro with-db ((store) &body body)
  `(bt:with-recursive-lock-held ((store-db-lock ,store)) ,@body))

(defun %fetch (store query)
  (with-db (store) (q:fetch (store-connection store) query :dialect :postgres)))

(defun %run (store query)
  (with-db (store) (q:run (store-connection store) query :dialect :postgres)))

(defun check-vector-extension (connection)
  "Signal PRAXEON/CONDITIONS:VECTOR-EXTENSION-MISSING unless the `vector' extension is
installed in CONNECTION's database. Reads pg_extension and never creates it (#138)."
  (unless (mig:extension-present-p connection "vector")
    (error 'praxeon/conditions:vector-extension-missing
           :database (param:row-value (first (conn:query connection
                                                         "SELECT current_database() AS db"))
                                      :db))))

(defun %index-ddl (table suffix columns)
  (ddl:ddl (list :create-index
                 :name (intern (string-upcase (format nil "~A_~A_idx" table suffix)) :keyword)
                 :on (intern (string-upcase table) :keyword)
                 :columns columns
                 :if-not-exists t)
           :dialect "postgres"))

(defun %live-embedding-type (store)
  "The live embedding column's type, for example \"vector(1024)\", or NIL."
  (let ((row (first (conn:query (store-connection store)
                                "SELECT format_type(atttypid, atttypmod) AS t FROM pg_attribute WHERE attrelid = to_regclass(?) AND attname = 'embedding' AND NOT attisdropped"
                                (store-table store)))))
    (and row (param:row-value row :t))))

(defun %recreate-embedding-column (store)
  (let ((table (store-table store)))
    (with-db (store)
      (conn:with-transaction ((store-connection store))
        (conn:exec (store-connection store) (format nil "ALTER TABLE ~A DROP COLUMN embedding" table))
        (conn:exec (store-connection store)
                   (format nil "ALTER TABLE ~A ADD COLUMN embedding vector(~D)" table
                           (store-dimensions store)))
        (conn:exec (store-connection store)
                   (format nil "UPDATE ~A SET embedding_fingerprint = NULL, embedding_deriver = NULL"
                           table))))))

(defun ensure-schema (store)
  "Create STORE's table and indexes when they are absent, and check the live embedding width.
Returns STORE.

The `vector' extension must already be installed in the database. This checks pg_extension
and signals PRAXEON/CONDITIONS:VECTOR-EXTENSION-MISSING; it never runs CREATE EXTENSION,
because the app's role on a managed Postgres usually cannot (#138).

There is no vector index. Similarity within a corpus is an exact scan in the first build, so
every result is complete; an index would let the database drop rows after the corpus filter."
  (let ((c (store-connection store))
        (table (store-table store)))
    (with-db (store)
      (check-vector-extension c)
      (conn:exec c (schema:schema-ddl (schema:find-schema (store-schema-name store))
                                      :dialect "postgres"))
      (conn:exec c (%index-ddl table "corpus_deriver" '(:corpus :embedding_deriver)))
      (conn:exec c (%index-ddl table "corpus_document" '(:corpus :document_id)))
      (let ((live (%live-embedding-type store))
            (want (format nil "vector(~D)" (store-dimensions store))))
        (unless (equal live want)
          (restart-case (error 'embedding-width-changed :table table :stored live
                                                        :configured (store-dimensions store))
            (recreate-embedding-column ()
              :report "Drop the embedding column and create it empty at the configured width."
              (%recreate-embedding-column store))))))
    store))

;;; --- serialising ingest ----------------------------------------------------------

(defun %advisory-key (store corpus)
  "A signed 64-bit lock key for (table, corpus)."
  (let* ((digest (ironclad:digest-sequence
                  :sha256 (sb-ext:string-to-octets
                           (der:frame-inputs (list "praxeon/retrieval" (store-table store)
                                                   (corpus-name corpus)))
                           :external-format :utf-8)))
         (n (loop for i below 8 for b = (aref digest i) sum (ash b (* 8 i)))))
    (if (>= n (expt 2 63)) (- n (expt 2 64)) n)))

(defun %corpus-lock (store corpus)
  (bt:with-lock-held ((%corpus-locks-guard store))
    (or (gethash (corpus-name corpus) (%corpus-locks store))
        (setf (gethash (corpus-name corpus) (%corpus-locks store))
              (bt:make-recursive-lock (format nil "corpus ~A" (corpus-name corpus)))))))

(defun call-with-corpus-lock (corpus thunk)
  "Call THUNK holding CORPUS's ingest lock, in this process and across every other process
that uses the same database (#138).

Two locks, because they answer different questions. A Postgres advisory lock, keyed on the
table and the corpus, serialises sessions: a second web process, or the old and new versions
during a rolling deploy. It is a session lock, and a session already holding it is granted it
again, so it cannot serialise two threads sharing one connection; a lock per corpus in this
process does that."
  (let* ((store (corpus-store corpus))
         (key (%advisory-key store corpus)))
    (bt:with-recursive-lock-held ((%corpus-lock store corpus))
      (with-db (store) (conn:query (store-connection store) "SELECT pg_advisory_lock(?)" key))
      (unwind-protect (funcall thunk)
        (with-db (store)
          (conn:query (store-connection store) "SELECT pg_advisory_unlock(?)" key))))))

(defmacro with-corpus-lock ((corpus) &body body)
  `(call-with-corpus-lock ,corpus (lambda () ,@body)))

;;; --- sync --------------------------------------------------------------------------

(defstruct (sync-report (:constructor %make-sync-report))
  "What a sync did, counted in sections (a section being one locale of one section id)."
  (added 0) (replaced 0) (updated 0) (unchanged 0) (removed 0))

(defparameter +provenance-columns+
  '(:document_id :document_version :locator :locale_role :derived_from :source_fingerprint))

(defun %section-provenance (section)
  (list :document_id (section-document-id section)
        :document_version (section-document-version section)
        :locator (section-locator section)
        :locale_role (string-downcase (symbol-name (section-locale-role section)))
        :derived_from (section-derived-from section)
        :source_fingerprint (section-source-fingerprint section)))

(defun %provenance-differs-p (row section)
  (let ((want (%section-provenance section)))
    (loop for col in +provenance-columns+
            thereis (not (equal (param:row-value row col) (getf want col))))))

(defun %chunk-id (corpus section position)
  (der:content-fingerprint (list (corpus-name corpus) (section-id section)
                                 (section-locale section) position)
                           :hash #'%sha256-hex))

(defun %insert-section (corpus section fingerprint)
  (let* ((chunker (corpus-chunker corpus))
         (chunks (chunk-section chunker section)))
    (loop for ch in chunks
          for position from 0
          do (unless (member (chunk-boundary ch) +boundaries+)
               (error "praxeon/retrieval: chunker ~A returned boundary ~S (one of ~{~S~^, ~})"
                      (chunker-id chunker) (chunk-boundary ch) +boundaries+))
             (%run (corpus-store corpus)
                   (list :insert-into (store-table (corpus-store corpus))
                         :values (list (append
                                        (list :id (%chunk-id corpus section position)
                                              :corpus (corpus-name corpus)
                                              :section_id (section-id section)
                                              :locale (section-locale section)
                                              :chunk_index position
                                              :sub_locator (chunk-sub-locator ch)
                                              :chunker (chunker-id chunker)
                                              :boundary (string-downcase
                                                         (symbol-name (chunk-boundary ch)))
                                              :text (chunk-text ch)
                                              :section_fingerprint fingerprint)
                                        (%section-provenance section))))))))

(defun %delete-section (corpus section-id locale)
  (%run (corpus-store corpus)
        (list :delete-from (store-table (corpus-store corpus))
              :where (corpus-where corpus (list := :section_id section-id)
                                   (list := :locale locale)))))

(defun %sync (corpus sections scope-clause)
  "Make CORPUS's chunks within SCOPE-CLAUSE match SECTIONS exactly. See SYNC-DOCUMENT."
  (mapc #'%check-section sections)
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (s sections)
      (let ((key (cons (section-id s) (section-locale s))))
        (when (gethash key seen)
          (error 'invalid-section :section s
                                  :problem (format nil "it appears twice for locale ~A"
                                                   (section-locale s))))
        (setf (gethash key seen) t))))
  (let* ((store (corpus-store corpus))
         (report (%make-sync-report))
         (chunker-id (chunker-id (corpus-chunker corpus))))
    (with-corpus-lock (corpus)
      (with-db (store)
        (conn:with-transaction ((store-connection store))
          (let ((existing (make-hash-table :test #'equal)))
            (dolist (row (%fetch store (list :select (append '(:section_id :locale
                                                                :section_fingerprint :chunker)
                                                              +provenance-columns+)
                                             :from (list (store-table store))
                                             :where (if scope-clause
                                                        (corpus-where corpus scope-clause)
                                                        (corpus-where corpus)))))
              (setf (gethash (cons (param:row-value row :section_id)
                                   (param:row-value row :locale))
                             existing)
                    row))
            (dolist (s sections)
              (let* ((key (cons (section-id s) (section-locale s)))
                     (row (gethash key existing))
                     (fp (section-fingerprint (section-text s))))
                (remhash key existing)
                (cond
                  ((and row
                        (equal fp (param:row-value row :section_fingerprint))
                        (equal chunker-id (param:row-value row :chunker)))
                   (if (%provenance-differs-p row s)
                       (progn
                         ;; Provenance can change without the text changing. It is updated
                         ;; in place, and the embedding, which depends on the text alone, is
                         ;; kept.
                         (%run store (list :update (store-table store)
                                           :set (%section-provenance s)
                                           :where (corpus-where corpus
                                                                (list := :section_id (section-id s))
                                                                (list := :locale (section-locale s)))))
                         (incf (sync-report-updated report)))
                       (incf (sync-report-unchanged report))))
                  (t
                   ;; Deleted by section and locale in the whole corpus, not only in the
                   ;; scope, so a section that moved to another document is replaced rather
                   ;; than colliding with its old rows.
                   (%delete-section corpus (section-id s) (section-locale s))
                   (%insert-section corpus s fp)
                   (if row
                       (incf (sync-report-replaced report))
                       (incf (sync-report-added report)))))))
            ;; Whatever is left in scope was not handed in, so it no longer exists.
            (maphash (lambda (key row)
                       (declare (ignore row))
                       (%delete-section corpus (car key) (cdr key))
                       (incf (sync-report-removed report)))
                     existing)))))
    report))

(defun sync-document (corpus document-id sections)
  "Make CORPUS hold exactly SECTIONS for the document DOCUMENT-ID. The call on write.

SECTIONS is every current section of that document, in every locale. A section of the
document that is not in SECTIONS is removed, and an empty list removes the document. A section
whose text and chunker are unchanged is not re-chunked, and its embedding is kept; changed
provenance is updated in place. Needs no embedding provider: new and changed chunks wait for
EMBED-PENDING. Serialised per corpus (WITH-CORPUS-LOCK) and run in one transaction. Returns a
SYNC-REPORT."
  (dolist (s sections)
    (when (and (section-p s) (not (equal (section-document-id s) document-id)))
      (error 'invalid-section :section s
                              :problem (format nil "its document-id is ~S, and this sync is for ~S"
                                               (section-document-id s) document-id))))
  (%sync corpus sections (list := :document_id document-id)))

(defun sync-corpus (corpus sections)
  "Make CORPUS hold exactly SECTIONS, every current section of every document. The call at
boot. Anything in the corpus that is not in SECTIONS is removed. Otherwise as SYNC-DOCUMENT."
  (%sync corpus sections nil))

;;; --- passages and results ------------------------------------------------------------

(defstruct (provenance (:constructor %make-provenance))
  "Where a passage came from, read from its chunk row and never from its text.

TRANSLATION is NIL for an original. For a translation it is :CURRENT when the original it was
made from is the original stored now, :OLDER-ORIGINAL when the original has changed since, and
:UNKNOWN when the app recorded no SOURCE-FINGERPRINT or the original is not in the corpus."
  corpus document-id document-version section-id locator sub-locator locale locale-role
  derived-from translation chunker boundary)

(defstruct (passage (:constructor %make-passage))
  "A retrieved chunk. DISTANCE is the cosine distance for a similarity result, NIL otherwise."
  text provenance distance)

(defstruct (complete (:constructor make-complete))
  "Every chunk of the corpus was a candidate, and nothing was cut off.")

(defstruct (truncated (:constructor make-truncated (&key reason pending)))
  "Not every candidate is in the result. REASON is :LIMIT (more matches than the limit) or
:NOT-EMBEDDED (PENDING chunks have no embedding by the current model yet, so similarity
could not consider them)."
  reason pending)

(defstruct (retrieval-result (:constructor %make-retrieval-result (passages completeness)))
  "PASSAGES and a COMPLETENESS value: a COMPLETE or a TRUNCATED."
  passages completeness)

(defparameter +passage-columns+
  '(:text :section_id :document_id :document_version :locator :sub_locator :locale
    :locale_role :derived_from :source_fingerprint :chunker :boundary)
  "What a retrieval selects. Never the embedding.")

(defun %keyword (s) (and s (intern (string-upcase s) :keyword)))

(defun %source-fingerprints (corpus rows)
  "section-id -> the stored fingerprint of its source-locale text, for the originals that
ROWS' translations name."
  (let ((ids (remove-duplicates
              (loop for r in rows
                    when (equal (param:row-value r :locale_role) "derived")
                      collect (param:row-value r :derived_from))
              :test #'equal))
        (table (make-hash-table :test #'equal)))
    (when ids
      (dolist (row (%fetch (corpus-store corpus)
                           (list :select '(:section_id :section_fingerprint)
                                 :from (list (store-table (corpus-store corpus)))
                                 :where (corpus-where corpus
                                                      (list := :locale_role "source")
                                                      (list :in :section_id ids)))))
        (setf (gethash (param:row-value row :section_id) table)
              (param:row-value row :section_fingerprint))))
    table))

(defun %translation-status (row sources)
  (when (equal (param:row-value row :locale_role) "derived")
    (let ((recorded (param:row-value row :source_fingerprint))
          (current (gethash (param:row-value row :derived_from) sources)))
      (cond ((or (null recorded) (null current)) :unknown)
            ((equal recorded current) :current)
            (t :older-original)))))

(defun %rows->passages (corpus rows &key with-distance)
  (let ((sources (%source-fingerprints corpus rows)))
    (mapcar (lambda (row)
              (%make-passage
               :text (param:row-value row :text)
               :distance (and with-distance
                              (let ((d (param:row-value row :distance)))
                                (and d (coerce d 'double-float))))
               :provenance
               (%make-provenance
                :corpus (corpus-name corpus)
                :document-id (param:row-value row :document_id)
                :document-version (param:row-value row :document_version)
                :section-id (param:row-value row :section_id)
                :locator (param:row-value row :locator)
                :sub-locator (param:row-value row :sub_locator)
                :locale (param:row-value row :locale)
                :locale-role (%keyword (param:row-value row :locale_role))
                :derived-from (param:row-value row :derived_from)
                :translation (%translation-status row sources)
                :chunker (param:row-value row :chunker)
                :boundary (%keyword (param:row-value row :boundary)))))
            rows)))

(defun passage->ctx-item (passage render)
  "PASSAGE as a context item. RENDER is required: a function from the passage to the string
the model reads. The item's SOURCE is the passage itself, which is the provenance the caller
keeps. praxeon does not choose how a citation is written, so there is no default RENDER (#138)."
  (unless (functionp render)
    (error "praxeon/retrieval: PASSAGE->CTX-ITEM needs RENDER, a function from a passage to the text the model reads; ~S is not one"
           render))
  (let ((content (funcall render passage)))
    (check-type content string)
    (ctx:make-ctx-item :content content
                       :tokens (max 1 (ceiling (length content) 4))
                       :role :note
                       :source passage)))

;;; --- exact retrieval ---------------------------------------------------------------

(defun %like-pattern (term)
  "TERM as an ILIKE pattern matching it anywhere, with %, _ and \\ in TERM matched literally.
Backslash is Postgres's default escape character for LIKE and ILIKE."
  (with-output-to-string (s)
    (write-char #\% s)
    (loop for ch across term
          do (when (member ch '(#\% #\_ #\\)) (write-char #\\ s))
             (write-char ch s))
    (write-char #\% s)))

(defgeneric retrieve-exact (corpus terms &key limit)
  (:documentation "The chunks of CORPUS whose text or locator contains every one of TERMS,
ignoring case. TERMS is a string or a list of strings, matched literally (% and _ are not
wildcards). Returns a RETRIEVAL-RESULT, ordered by document, section, locale and position.

It does not reach the embedding path: it takes no provider, and its query neither selects nor
compares the embedding column. So it works on a corpus that has been synced and never
embedded. The result is COMPLETE when every match is in it, and TRUNCATED with reason :LIMIT
when there were more than LIMIT."))

(defmethod retrieve-exact ((corpus corpus) terms &key (limit 20))
  (let* ((terms (if (stringp terms) (list terms) terms))
         (clauses (mapcar (lambda (term)
                            (let ((pattern (%like-pattern term)))
                              (list :or (list :ilike :text pattern)
                                    (list :ilike :locator pattern))))
                          terms))
         (rows (%fetch (corpus-store corpus)
                       (list :select +passage-columns+
                             :from (list (store-table (corpus-store corpus)))
                             :where (apply #'corpus-where corpus clauses)
                             :order-by '(:document_id :section_id :locale :chunk_index)
                             :limit (1+ limit)))))
    (%make-retrieval-result
     (%rows->passages corpus (subseq rows 0 (min limit (length rows))))
     (if (> (length rows) limit)
         (make-truncated :reason :limit)
         (make-complete)))))
