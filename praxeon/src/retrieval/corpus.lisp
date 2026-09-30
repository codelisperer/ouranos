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
DERIVED-FROM  for a translation, the id of the section it translates, in the same document (for
              an app that stores a translation as another locale of the same section, its own ID)

A section is identified by DOCUMENT-ID, ID and LOCALE together, so two documents may use the
same section id.
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

(defclass paragraph-chunker ()
  ((long-section :initarg :long-section :initform 1500 :reader chunker-long-section)
   (target :initarg :target :initform 900 :reader chunker-target))
  (:documentation "A section of LONG-SECTION characters or fewer is one chunk, claiming
:WHOLE-SECTION, as with SECTION-CHUNKER. A longer one is cut at blank lines into runs of whole
paragraphs of up to about TARGET characters each, claiming :WHOLE-PARAGRAPH, with sub-locators
\"part 1\", \"part 2\" and so on (#322).

A paragraph is never split: one longer than TARGET is a chunk on its own. A long section with
no blank line in it stays one :WHOLE-SECTION chunk. Each chunk's text is the section's own text
from the start of its first paragraph to the end of its last, so the blank lines between its
paragraphs are kept as written.

Why: one embedding for a long section represents it badly. A consuming app's contract corpus
opens with a preamble of about 6,400 characters holding every defined term; kept whole, questions
of the form \"what is X\" found it in the top 5 for 43% of a fixed question set. Cut this way,
with these defaults, 93%."))

(defmethod initialize-instance :after ((c paragraph-chunker) &key)
  (flet ((check (name value)
           (unless (and (integerp value) (plusp value))
             (error "praxeon/retrieval: a paragraph-chunker's ~(~A~) must be a positive integer, not ~S"
                    name value))))
    (check :long-section (chunker-long-section c))
    (check :target (chunker-target c))))

(defun %blank-line-p (text start end)
  (loop for i from start below end
        always (member (char text i) '(#\Space #\Tab #\Return #\Page))))

(defun %paragraph-spans (text)
  "(start . end) of each paragraph in TEXT, in order: a run of lines that are not blank,
separated from the next by one or more blank lines. A line holding only spaces, tabs or a
carriage return is blank."
  (let ((spans '()) (para-start nil) (para-end nil) (pos 0) (n (length text)))
    (loop while (<= pos n) do
      (let ((eol (or (position #\Newline text :start pos) n)))
        (if (%blank-line-p text pos eol)
            (when para-start
              (push (cons para-start para-end) spans)
              (setf para-start nil))
            (progn (unless para-start (setf para-start pos))
                   ;; On a CRLF line the last character is #\Return; the paragraph ends before it.
                   (setf para-end (if (and (> eol pos) (char= (char text (1- eol)) #\Return))
                                      (1- eol)
                                      eol))))
        (setf pos (1+ eol))))
    (when para-start (push (cons para-start para-end) spans))
    (nreverse spans)))

(defun %pack-spans (spans target)
  "SPANS grouped greedily into runs whose extent, from the first span's start to the last's end,
stays within TARGET characters. A span longer than TARGET is a run on its own."
  (let ((runs '()) (current '()))
    (dolist (span spans)
      (if (and current (<= (- (cdr span) (car (first current))) target))
          (setf current (append current (list span)))
          (progn (when current (push current runs))
                 (setf current (list span)))))
    (when current (push current runs))
    (nreverse runs)))

(defmethod chunk-section ((c paragraph-chunker) section)
  (let* ((text (section-text section))
         (runs (and (> (length text) (chunker-long-section c))
                    (%pack-spans (%paragraph-spans text) (chunker-target c)))))
    (if (<= (length runs) 1)
        (list (make-chunk :text text :sub-locator nil :boundary :whole-section))
        (loop for run in runs
              for i from 1
              collect (make-chunk :text (subseq text (car (first run)) (cdr (first (last run))))
                                  :sub-locator (format nil "part ~D" i)
                                  :boundary :whole-paragraph)))))

(defmethod chunker-id ((c paragraph-chunker))
  ;; The settings are part of the id, so changing either re-chunks the corpus on its next sync.
  (format nil "paragraph/1:~D:~D" (chunker-long-section c) (chunker-target c)))

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
    ;; BM25 (#316): the number of terms the tokenizer found in TEXT, and which tokenizer. The
    ;; terms themselves are in the store's terms table.
    (:term_count         :integer)
    (:terms_tokenizer    :string)
    ;; Contexts and document order (#316, step 3). SECTION_INDEX is the section's position in
    ;; its document and locale as the app handed the sections in. DOCUMENT_FINGERPRINT is
    ;; %DOCUMENT-FINGERPRINT of that document and locale's chunks, written by every sync that
    ;; changes them. A context is current while CONTEXT_DERIVER is the corpus's contextualizer
    ;; and CONTEXT_DOCUMENT_FINGERPRINT is the chunk's DOCUMENT_FINGERPRINT. INPUT_FINGERPRINT
    ;; is SECTION-FINGERPRINT of what is embedded and indexed (%EMBED-INPUT); an embedding
    ;; whose fingerprint differs from it is stale.
    (:section_index      :integer)
    (:document_fingerprint :string)
    (:context            :text)
    (:context_deriver    :string)
    (:context_document_fingerprint :string)
    (:input_fingerprint  :string)
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

(defparameter *whole-limit* 200000
  "The size, in estimated tokens, at which an :AUTO corpus stops being retrieved whole and is
searched instead (#316). The figure is the one Anthropic's contextual-retrieval article gives
for a knowledge base better put in the prompt than searched. The right figure for an app depends
on its chat model's context window and on what each query may cost, since a cached prompt is
still paid for at the cache-read price on every call, so MAKE-CORPUS takes :WHOLE-LIMIT.")

(defclass corpus ()
  ((store :initarg :store :reader corpus-store)
   (name :initarg :name :reader corpus-name)
   (chunker :initarg :chunker :reader corpus-chunker)
   (strategy :initarg :strategy :reader corpus-strategy)
   (whole-limit :initarg :whole-limit :reader corpus-whole-limit)
   (expected-tokens :initarg :expected-tokens :reader corpus-expected-tokens)
   (contextualizer :initarg :contextualizer :reader corpus-contextualizer)
   (backfill :initarg :backfill :reader corpus-backfill))
  (:documentation "A named set of documents searched together. Its rows are in its store's
table, marked with its NAME. Creating one writes nothing: a corpus exists once it has rows.
MAKE-CORPUS describes the other slots."))

(defun make-corpus (store name &key (chunker (make-instance 'section-chunker))
                                    (strategy :auto) (whole-limit *whole-limit*)
                                    expected-tokens contextualizer (backfill :automatic))
  "The corpus NAME (a non-empty string) in STORE. Cheap, and runs no SQL.

STRATEGY is how RETRIEVE answers a query (#316):
  :WHOLE   every chunk, in document order, for the app to put in the prompt before a cache
           marker (RETRIEVE-WHOLE).
  :HYBRID  embedding similarity and BM25 merged (RETRIEVE-HYBRID), over chunks that carry a
           context when the corpus has a CONTEXTUALIZER.
  :AUTO    :WHOLE while the corpus is smaller than WHOLE-LIMIT estimated tokens, and :HYBRID
           from then on. The default.

EXPECTED-TOKENS is the size the app expects the corpus to reach. When it is WHOLE-LIMIT or more,
an :AUTO corpus is :HYBRID from its first sync, so its chunks get contexts from the start and
nothing has to be done again when it grows.

CONTEXTUALIZER, from PRAXEON/RETRIEVAL:MAKE-CONTEXTUALIZER, writes a context for each chunk of a
:HYBRID corpus (CONTEXTUALIZE-PENDING). NIL, the default, writes none, and hybrid retrieval then
searches the chunks' text alone.

BACKFILL says when an :AUTO corpus that has grown past WHOLE-LIMIT gets its contexts written:
:AUTOMATIC (the default) at the next CONTEXTUALIZE-PENDING, or :EXPLICIT only after the app calls
START-BACKFILL. That backfill writes a context for every chunk and re-embeds every chunk, which
is the one large cost of this design."
  (unless (and (stringp name) (plusp (length name)))
    (error "praxeon/retrieval: a corpus name must be a non-empty string, not ~S" name))
  (unless (member strategy '(:auto :whole :hybrid))
    (error "praxeon/retrieval: :strategy must be :AUTO, :WHOLE or :HYBRID, not ~S" strategy))
  (unless (typep whole-limit '(integer 1))
    (error "praxeon/retrieval: :whole-limit must be a positive integer, not ~S" whole-limit))
  (unless (or (null expected-tokens) (typep expected-tokens '(integer 0)))
    (error "praxeon/retrieval: :expected-tokens must be a non-negative integer or NIL, not ~S"
           expected-tokens))
  (unless (member backfill '(:automatic :explicit))
    (error "praxeon/retrieval: :backfill must be :AUTOMATIC or :EXPLICIT, not ~S" backfill))
  (make-instance 'corpus :store store :name name :chunker chunker :strategy strategy
                         :whole-limit whole-limit :expected-tokens expected-tokens
                         :contextualizer contextualizer :backfill backfill))

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

(defun terms-table (store)
  "The table holding STORE's chunk terms for BM25: the chunk table's name with \"_terms\"."
  (format nil "~A_terms" (store-table store)))

(defun %terms-ddl (store)
  "The terms table: one row per term of a chunk, with how often it occurs (TF). CORPUS and
TOKENIZER are copied from the chunk so that the document frequency of a term in a corpus is one
indexed count over this table."
  (list (format nil "CREATE TABLE IF NOT EXISTS ~A (chunk_id TEXT NOT NULL, corpus TEXT NOT NULL, tokenizer TEXT NOT NULL, term TEXT NOT NULL, tf INTEGER NOT NULL, PRIMARY KEY (chunk_id, term))"
                (terms-table store))
        (format nil "CREATE INDEX IF NOT EXISTS ~A_corpus_term_idx ON ~A (corpus, tokenizer, term)"
                (terms-table store) (terms-table store))))

(defun corpora-table (store)
  "The table recording, for each corpus in STORE, its size in estimated tokens and the strategy
the last sync chose: the chunk table's name with \"_corpora\" (#316)."
  (format nil "~A_corpora" (store-table store)))

(defun %corpora-ddl (store)
  "One row per corpus. STRATEGY and TOKENS are what the last sync measured; CHANGED_AT is when
STRATEGY last changed, in universal time. BACKFILL_STARTED_AT is set by START-BACKFILL."
  (format nil "CREATE TABLE IF NOT EXISTS ~A (corpus TEXT PRIMARY KEY, strategy TEXT NOT NULL, tokens BIGINT NOT NULL, changed_at BIGINT NOT NULL, backfill_started_at BIGINT)"
          (corpora-table store)))

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
      ;; A table made before #316 has neither BM25 column. Its chunks then count as not
      ;; indexed until INDEX-PENDING writes their terms. Postgres answers IF NOT EXISTS on an
      ;; object that exists with a notice, which cl-postgres signals as a warning; that is the
      ;; expected case on every start after the first, so it is muffled here and nowhere else.
      ;; The same holds for the columns #316's step 3 added: a chunk of an older table has no
      ;; context and no document fingerprint, and is contextualized like a new one.
      (handler-bind ((warning #'muffle-warning))
        (dolist (column '("term_count INTEGER" "terms_tokenizer TEXT"
                          "section_index INTEGER" "document_fingerprint TEXT" "context TEXT"
                          "context_deriver TEXT" "context_document_fingerprint TEXT"
                          "input_fingerprint TEXT"))
          (conn:exec c (format nil "ALTER TABLE ~A ADD COLUMN IF NOT EXISTS ~A" table column)))
        (dolist (statement (%terms-ddl store))
          (conn:exec c statement))
        (conn:exec c (%corpora-ddl store)))
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
  "What a sync did, counted in sections (a section being one locale of one section id). SIZE is
the corpus's size afterwards in estimated tokens (CORPUS-SIZE), and STRATEGY is the one RETRIEVE
follows at that size, :WHOLE or :HYBRID (#316)."
  (added 0) (replaced 0) (updated 0) (unchanged 0) (removed 0) size strategy)

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
  "The chunk's primary key. A section is identified by its document, its id and its locale,
because a section id is stable within its document and need not be unique across documents."
  (der:content-fingerprint (list (corpus-name corpus) (section-document-id section)
                                 (section-id section) (section-locale section) position)
                           :hash #'%sha256-hex))

(defun %section-key (section)
  (list (section-document-id section) (section-id section) (section-locale section)))

(defun %row-key (row)
  (list (param:row-value row :document_id) (param:row-value row :section_id)
        (param:row-value row :locale)))

(defun %embed-input (context text)
  "What is embedded and indexed for BM25 for a chunk with TEXT and CONTEXT: the context, a blank
line and the text, or the text alone when there is no context (#316). The passage a reader sees
is TEXT alone."
  (if (and context (plusp (length context)))
      (concatenate 'string context (string #\Newline) (string #\Newline) text)
      text))

(defun %write-terms (corpus chunk-id text locale)
  "Write CHUNK-ID's terms, tokenized from TEXT in LOCALE, and return how many terms there were.
TEXT is the chunk's %EMBED-INPUT. Called with the store's database lock held, inside the
caller's transaction."
  (multiple-value-bind (counts total) (term-counts text :locale locale)
    (when counts
      (%run (corpus-store corpus)
            (list :insert-into (terms-table (corpus-store corpus))
                  :values (mapcar (lambda (entry)
                                    (list :chunk_id chunk-id
                                          :corpus (corpus-name corpus)
                                          :tokenizer +tokenizer-id+
                                          :term (car entry)
                                          :tf (cdr entry)))
                                  counts))))
    total))

(defun %delete-terms (corpus chunk-where)
  "Delete the terms of CORPUS's chunks that CHUNK-WHERE selects."
  (%run (corpus-store corpus)
        (list :delete-from (terms-table (corpus-store corpus))
              :where (corpus-where corpus
                                   (list :in :chunk_id
                                         (list :select '(:id)
                                               :from (list (store-table (corpus-store corpus)))
                                               :where chunk-where))))))

(defun %insert-section (corpus section fingerprint section-index)
  (let* ((chunker (corpus-chunker corpus))
         (chunks (chunk-section chunker section)))
    (loop for ch in chunks
          for position from 0
          for id = (%chunk-id corpus section position)
          do (unless (member (chunk-boundary ch) +boundaries+)
               (error "praxeon/retrieval: chunker ~A returned boundary ~S (one of ~{~S~^, ~})"
                      (chunker-id chunker) (chunk-boundary ch) +boundaries+))
             (%run (corpus-store corpus)
                   (list :insert-into (store-table (corpus-store corpus))
                         :values (list (append
                                        (list :id id
                                              :corpus (corpus-name corpus)
                                              :section_id (section-id section)
                                              :locale (section-locale section)
                                              :chunk_index position
                                              :sub_locator (chunk-sub-locator ch)
                                              :chunker (chunker-id chunker)
                                              :boundary (string-downcase
                                                         (symbol-name (chunk-boundary ch)))
                                              :text (chunk-text ch)
                                              :section_fingerprint fingerprint
                                              :section_index section-index
                                              ;; No context yet, so the input is the text.
                                              :input_fingerprint (section-fingerprint
                                                                  (chunk-text ch)))
                                        (%section-provenance section)))))
             ;; The terms are written with the chunk, in the sync's transaction, so a synced
             ;; chunk is indexed for BM25 as soon as the sync commits.
             (let ((total (%write-terms corpus id (chunk-text ch) (section-locale section))))
               (%run (corpus-store corpus)
                     (list :update (store-table (corpus-store corpus))
                           :set (list :term_count total :terms_tokenizer +tokenizer-id+)
                           :where (corpus-where corpus (list := :id id))))))))

(defun %section-where (corpus key)
  "The WHERE clause for one section of CORPUS, KEY being (document-id section-id locale)."
  (destructuring-bind (document-id section-id locale) key
    (corpus-where corpus (list := :document_id document-id) (list := :section_id section-id)
                  (list := :locale locale))))

(defun %delete-section (corpus key)
  (%delete-terms corpus (%section-where corpus key))
  (%run (corpus-store corpus)
        (list :delete-from (store-table (corpus-store corpus))
              :where (%section-where corpus key))))

(defun %section-indexes (sections)
  "SECTION -> its position among the sections of its document and locale in SECTIONS."
  (let ((next (make-hash-table :test #'equal))
        (index (make-hash-table :test #'eq)))
    (dolist (s sections index)
      (let ((group (list (section-document-id s) (section-locale s))))
        (setf (gethash s index) (gethash group next 0))
        (incf (gethash group next 0))))))

(defun %document-rows (corpus document-id locale &optional (columns '(:text)))
  "COLUMNS of the chunks of DOCUMENT-ID in LOCALE, in document order."
  (%fetch (corpus-store corpus)
          (list :select columns
                :from (list (store-table (corpus-store corpus)))
                :where (corpus-where corpus (list := :document_id document-id)
                                     (list := :locale locale))
                :order-by '(:section_index :section_id :chunk_index))))

(defun %document-fingerprint (texts)
  "The fingerprint of a document in one locale, from its chunks' TEXTS in document order. A
context is written against it, so any change to it makes every context of that document stale."
  (der:content-fingerprint texts :hash #'%sha256-hex))

(defun %refresh-document-fingerprint (corpus document-id locale)
  "Recompute DOCUMENT-ID's fingerprint in LOCALE from its stored chunks and write it on each of
them where it differs. Returns the fingerprint, or NIL when the document has no chunks."
  (let ((rows (%document-rows corpus document-id locale)))
    (when rows
      (let ((fp (%document-fingerprint (mapcar (lambda (r) (param:row-value r :text)) rows))))
        (%run (corpus-store corpus)
              (list :update (store-table (corpus-store corpus))
                    :set (list :document_fingerprint fp)
                    :where (corpus-where corpus (list := :document_id document-id)
                                         (list := :locale locale)
                                         (list :or (list :is-null :document_fingerprint)
                                               (list :<> :document_fingerprint fp)))))
        fp))))

(defun %sync (corpus sections scope-clause)
  "Make CORPUS's chunks within SCOPE-CLAUSE match SECTIONS exactly. See SYNC-DOCUMENT."
  (mapc #'%check-section sections)
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (s sections)
      (let ((key (%section-key s)))
        (when (gethash key seen)
          (error 'invalid-section :section s
                                  :problem (format nil "it appears twice in document ~A for locale ~A"
                                                   (section-document-id s) (section-locale s))))
        (setf (gethash key seen) t))))
  (let* ((store (corpus-store corpus))
         (report (%make-sync-report))
         (chunker-id (chunker-id (corpus-chunker corpus)))
         (indexes (%section-indexes sections))
         ;; (document-id locale) pairs whose chunks changed, so whose document fingerprint must
         ;; be recomputed after the writes.
         (changed (make-hash-table :test #'equal))
         (previous nil))
    (flet ((touch (key) (setf (gethash (list (first key) (third key)) changed) t)))
      (with-corpus-lock (corpus)
        (with-db (store)
          (conn:with-transaction ((store-connection store))
            (let ((existing (make-hash-table :test #'equal)))
              (dolist (row (%fetch store (list :select (append '(:section_id :locale
                                                                  :section_fingerprint :chunker
                                                                  :section_index
                                                                  :document_fingerprint)
                                                                +provenance-columns+)
                                               :from (list (store-table store))
                                               :where (if scope-clause
                                                          (corpus-where corpus scope-clause)
                                                          (corpus-where corpus)))))
                ;; A chunk synced before #316's step 3 has no document fingerprint yet.
                (unless (param:row-value row :document_fingerprint)
                  (touch (%row-key row)))
                (setf (gethash (%row-key row) existing) row))
              (dolist (s sections)
                (let* ((key (%section-key s))
                       (row (gethash key existing))
                       (fp (section-fingerprint (section-text s)))
                       (index (gethash s indexes)))
                  (remhash key existing)
                  (cond
                    ((and row
                          (equal fp (param:row-value row :section_fingerprint))
                          (equal chunker-id (param:row-value row :chunker)))
                     (let ((moved (not (eql index (param:row-value row :section_index)))))
                       (if (or moved (%provenance-differs-p row s))
                           (progn
                             ;; Provenance and position can change without the text changing.
                             ;; Both are updated in place, and the embedding is kept. A section
                             ;; that moved changes its document, so the document's contexts
                             ;; become stale.
                             (%run store (list :update (store-table store)
                                               :set (append (%section-provenance s)
                                                            (list :section_index index))
                                               :where (%section-where corpus key)))
                             (when moved (touch key))
                             (incf (sync-report-updated report)))
                           (incf (sync-report-unchanged report)))))
                    (t
                     (%delete-section corpus key)
                     (%insert-section corpus s fp index)
                     (touch key)
                     (if row
                         (incf (sync-report-replaced report))
                         (incf (sync-report-added report)))))))
              ;; Whatever is left in scope was not handed in, so it no longer exists.
              (maphash (lambda (key row)
                         (declare (ignore row))
                         (%delete-section corpus key)
                         (touch key)
                         (incf (sync-report-removed report)))
                       existing))
            (maphash (lambda (group v)
                       (declare (ignore v))
                       (%refresh-document-fingerprint corpus (first group) (second group)))
                     changed)
            (multiple-value-bind (size strategy was) (%record-strategy corpus)
              (setf (sync-report-size report) size
                    (sync-report-strategy report) strategy
                    previous was))))
        ;; Logged after the commit, so a sync that rolled back logs nothing.
        (%log-strategy-change corpus previous (sync-report-strategy report)
                              (sync-report-size report))))
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

;;; --- size and strategy (#316) ----------------------------------------------------------
;;;
;;; An :AUTO corpus is retrieved whole while it is small and searched once it is large. The size
;;; is measured by each sync and recorded in the corpora table with the strategy it implies, so
;;; the crossing is logged once however many processes sync the corpus, and a query reads the
;;; strategy without measuring the corpus again.

(defun corpus-size (corpus)
  "CORPUS's size in estimated tokens: its chunks' characters divided by four, rounded up. That is
the estimate PASSAGE->CTX-ITEM uses; the exact count depends on the model's tokenizer."
  (let ((row (first (%fetch (corpus-store corpus)
                            (list :select (list (list :as (list :coalesce (list :sum (list :length :text)) 0)
                                                      :n))
                                  :from (list (store-table (corpus-store corpus)))
                                  :where (corpus-where corpus))))))
    (ceiling (or (and row (param:row-value row :n)) 0) 4)))

(defun %expected-large-p (corpus)
  (let ((expected (corpus-expected-tokens corpus)))
    (and expected (>= expected (corpus-whole-limit corpus)))))

(defun %strategy-for (corpus size)
  "The strategy CORPUS follows at SIZE estimated tokens: :WHOLE or :HYBRID."
  (ecase (corpus-strategy corpus)
    (:whole :whole)
    (:hybrid :hybrid)
    (:auto (if (or (%expected-large-p corpus) (>= size (corpus-whole-limit corpus)))
               :hybrid
               :whole))))

(defun %recorded-row (corpus)
  (first (%fetch (corpus-store corpus)
                 (list :select '(:strategy :tokens :changed_at :backfill_started_at)
                       :from (list (corpora-table (corpus-store corpus)))
                       :where (corpus-where corpus)))))

(defun %record-strategy (corpus)
  "Measure CORPUS and record its size and strategy. Returns the size, the strategy, and the
strategy recorded before, or NIL when there was none. Called inside the sync's transaction."
  (let* ((size (corpus-size corpus))
         (strategy (%strategy-for corpus size))
         (row (%recorded-row corpus))
         (was (and row (%keyword (param:row-value row :strategy)))))
    (%run (corpus-store corpus)
          (list :insert-into (corpora-table (corpus-store corpus))
                :values (list (list :corpus (corpus-name corpus)
                                    :strategy (string-downcase (symbol-name strategy))
                                    :tokens size
                                    :changed_at (if (eq was strategy)
                                                    (param:row-value row :changed_at)
                                                    (get-universal-time))))
                :on-conflict '(:corpus)
                :do-update '(:strategy (:excluded :strategy) :tokens (:excluded :tokens)
                             :changed_at (:excluded :changed_at))))
    (values size strategy was)))

(defun %log-strategy-change (corpus was now size)
  "Log, once, that an :AUTO corpus changed strategy. A corpus's first sync at :WHOLE is the
normal start and is not logged."
  (when (and (eq (corpus-strategy corpus) :auto)
             (not (eq was now))
             (not (and (null was) (eq now :whole))))
    (log:info "retrieval corpus changed strategy"
              :corpus (corpus-name corpus)
              :from (if was (string-downcase (symbol-name was)) "none")
              :to (string-downcase (symbol-name now))
              :tokens size
              :whole-limit (corpus-whole-limit corpus))))

(defun corpus-effective-strategy (corpus)
  "The strategy RETRIEVE follows for CORPUS now: :WHOLE or :HYBRID. For an :AUTO corpus it is
decided by the size its last sync recorded, or by CORPUS-SIZE when no sync has recorded one."
  (if (eq (corpus-strategy corpus) :auto)
      (let ((row (%recorded-row corpus)))
        (%strategy-for corpus (if row (param:row-value row :tokens) (corpus-size corpus))))
      (corpus-strategy corpus)))

(defun %backfill-held-p (corpus)
  "True when CORPUS is :HYBRID only because it grew past its limit, the app asked for the
backfill to be started explicitly, and it has not been."
  (and (eq (corpus-backfill corpus) :explicit)
       (eq (corpus-strategy corpus) :auto)
       (not (%expected-large-p corpus))
       (let ((row (%recorded-row corpus)))
         (not (and row (param:row-value row :backfill_started_at))))))

(defun start-backfill (corpus)
  "Allow CONTEXTUALIZE-PENDING to write the contexts of CORPUS, an :AUTO corpus made with
:BACKFILL :EXPLICIT, once it has grown past its limit. Recorded in the database, so it holds for
every process. Returns CORPUS."
  (let ((store (corpus-store corpus))
        (now (get-universal-time)))
    (with-corpus-lock (corpus)
      (let ((size (corpus-size corpus)))
        (%run store
              (list :insert-into (corpora-table store)
                    :values (list (list :corpus (corpus-name corpus)
                                        :strategy (string-downcase
                                                   (symbol-name (%strategy-for corpus size)))
                                        :tokens size :changed_at now :backfill_started_at now))
                    :on-conflict '(:corpus)
                    :do-update '(:backfill_started_at (:excluded :backfill_started_at))))))
    corpus))

;;; --- passages and results ------------------------------------------------------------

(defstruct (provenance (:constructor %make-provenance))
  "Where a passage came from, read from its chunk row and never from its text.

TRANSLATION is NIL for an original. For a translation it is :CURRENT when the original it was
made from is the original stored now, :OLDER-ORIGINAL when the original has changed since, and
:UNKNOWN when the app recorded no SOURCE-FINGERPRINT or the original is not in the corpus."
  corpus document-id document-version section-id locator sub-locator locale locale-role
  derived-from translation chunker boundary)

(defstruct (passage (:constructor %make-passage))
  "A retrieved chunk. DISTANCE is the cosine distance for a similarity result, NIL otherwise.
SCORE is a keyword or hybrid result's score, higher meaning a better match, NIL otherwise: the
BM25 score from RETRIEVE-KEYWORD, the reciprocal-rank-fusion score from RETRIEVE-HYBRID, or the
reranker's score when a reranker ordered the result. They are on different scales, so compare
scores only within one result. CONTEXT is the context the
corpus's contextualizer wrote for the chunk, or NIL (#316). TEXT is always the chunk's own text,
without the context."
  text provenance distance score context)

(defstruct (complete (:constructor make-complete))
  "Every chunk of the corpus was a candidate, and nothing was cut off.")

(defstruct (truncated (:constructor make-truncated (&key reason pending)))
  "Not every candidate is in the result. REASON is :LIMIT (more matches than the limit),
:NOT-EMBEDDED (PENDING chunks have no embedding by the current model yet, so similarity could
not consider them) or :NOT-INDEXED (PENDING chunks have no terms from the current tokenizer, so
keyword search could not consider them; INDEX-PENDING writes them). A hybrid result that is
missing both says :NOT-EMBEDDED, and PENDING counts every chunk missing either."
  reason pending)

(defstruct (retrieval-result (:constructor %make-retrieval-result (passages completeness)))
  "PASSAGES and a COMPLETENESS value: a COMPLETE or a TRUNCATED."
  passages completeness)

(defparameter +passage-columns+
  '(:text :section_id :document_id :document_version :locator :sub_locator :locale
    :locale_role :derived_from :source_fingerprint :chunker :boundary :context)
  "What a retrieval selects. Never the embedding.")

(defun %qualified (alias columns)
  "COLUMNS as ALIAS.column identifiers, for a query that joins the chunk table to others."
  (mapcar (lambda (c) (intern (format nil "~:@(~A.~A~)" alias c) :keyword)) columns))

(defun %keyword (s) (and s (intern (string-upcase s) :keyword)))

(defun %source-key (row)
  "For a translation's ROW, the (document-id section-id) of the original it translates, which is
in the same document."
  (list (param:row-value row :document_id) (param:row-value row :derived_from)))

(defun %source-fingerprints (corpus rows)
  "(document-id section-id) -> the stored fingerprint of that section's source-locale text, for
the originals that ROWS' translations name."
  (let* ((wanted (remove-duplicates
                  (loop for r in rows
                        when (equal (param:row-value r :locale_role) "derived")
                          collect (%source-key r))
                  :test #'equal))
         (table (make-hash-table :test #'equal)))
    (when wanted
      (dolist (row (%fetch (corpus-store corpus)
                           (list :select '(:document_id :section_id :section_fingerprint)
                                 :from (list (store-table (corpus-store corpus)))
                                 :where (corpus-where
                                         corpus
                                         (list := :locale_role "source")
                                         (list :in :document_id
                                               (remove-duplicates (mapcar #'first wanted)
                                                                  :test #'equal))
                                         (list :in :section_id
                                               (remove-duplicates (mapcar #'second wanted)
                                                                  :test #'equal))))))
        (setf (gethash (list (param:row-value row :document_id) (param:row-value row :section_id))
                       table)
              (param:row-value row :section_fingerprint))))
    table))

(defun %translation-status (row sources)
  (when (equal (param:row-value row :locale_role) "derived")
    (let ((recorded (param:row-value row :source_fingerprint))
          (current (gethash (%source-key row) sources)))
      (cond ((or (null recorded) (null current)) :unknown)
            ((equal recorded current) :current)
            (t :older-original)))))

(defun %rows->passages (corpus rows &key with-distance scores)
  "Passages for ROWS. WITH-DISTANCE reads each row's DISTANCE column. SCORES, when given, is a
list of scores parallel to ROWS."
  (let ((sources (%source-fingerprints corpus rows)))
    (mapcar (lambda (row score)
              (%make-passage
               :text (param:row-value row :text)
               :context (param:row-value row :context)
               :score (and score (coerce score 'double-float))
               :distance (and with-distance
                              (let ((d (param:row-value row :distance :if-missing nil)))
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
            rows
            (or scores (make-list (length rows) :initial-element nil)))))

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

;;; --- the whole corpus (#316) ----------------------------------------------------------

(defgeneric retrieve-whole (corpus)
  (:documentation "Every chunk of CORPUS, in document order: by document, then locale, then the
order the app handed the sections in, then position within the section. The result is always
COMPLETE. This is what RETRIEVE returns for a corpus whose strategy is :WHOLE, for the app to put
in the prompt before a cache marker. Needs no provider, and neither selects nor compares the
embedding column."))

(defmethod retrieve-whole ((corpus corpus))
  (%make-retrieval-result
   (%rows->passages corpus
                    (%fetch (corpus-store corpus)
                            (list :select +passage-columns+
                                  :from (list (store-table (corpus-store corpus)))
                                  :where (corpus-where corpus)
                                  :order-by '(:document_id :locale :section_index :section_id
                                              :chunk_index))))
   (make-complete)))

;;; --- keyword retrieval: BM25 (#316) --------------------------------------------------

(defparameter *bm25-k1* 1.2d0 "BM25's term-frequency saturation, #316's starting value.")
(defparameter *bm25-b* 0.75d0 "BM25's document-length normalisation, #316's starting value.")

(defun %unindexed-clause ()
  "Chunks with no terms from the current tokenizer: synced before #316, or indexed by an older
TOKENIZE."
  (list :or (list :is-null :terms_tokenizer) (list :<> :terms_tokenizer +tokenizer-id+)))

(defun %unindexed-count (corpus)
  (let ((row (first (%fetch (corpus-store corpus)
                            (list :select (list (list :as (list :count :*) :n))
                                  :from (list (store-table (corpus-store corpus)))
                                  :where (corpus-where corpus (%unindexed-clause)))))))
    (or (and row (param:row-value row :n)) 0)))

(defun index-pending (corpus &key (batch-size 200))
  "Write the BM25 terms of every chunk of CORPUS that has none from the current tokenizer, in
batches of BATCH-SIZE chunks. Returns the number of chunks indexed.

A sync writes the terms of the chunks it inserts, so this is needed only for chunks synced
before #316 and after a change of tokenizer (+TOKENIZER-ID+). Needs no model and no provider.
Serialised per corpus with the syncs (WITH-CORPUS-LOCK)."
  (unless (typep batch-size '(integer 1))
    (error "praxeon/retrieval: :batch-size must be a positive integer, not ~S" batch-size))
  (let ((store (corpus-store corpus))
        (count 0))
    (with-corpus-lock (corpus)
      (loop
        (let ((rows (%fetch store (list :select '(:id :text :context :locale)
                                        :from (list (store-table store))
                                        :where (corpus-where corpus (%unindexed-clause))
                                        :order-by '(:id)
                                        :limit batch-size))))
          (when (null rows) (return count))
          (with-db (store)
            (conn:with-transaction ((store-connection store))
              (dolist (row rows)
                (let ((id (param:row-value row :id)))
                  (%delete-terms corpus (list := :id id))
                  (%run store (list :update (store-table store)
                                    :set (list :term_count
                                               (%write-terms corpus id
                                                             (%embed-input
                                                              (param:row-value row :context)
                                                              (param:row-value row :text))
                                                             (param:row-value row :locale))
                                               :terms_tokenizer +tokenizer-id+)
                                    :where (corpus-where corpus (list := :id id))))
                  (incf count))))))))))

(defun %bm25-expression ()
  "The BM25 score of one matched term in one chunk, as SQL over the aliases of %BM25-QUERY: M
the matched term row, D its document frequency, C2 the chunk, ST the corpus statistics. IDF is
the non-negative form, ln((N - df + 0.5) / (df + 0.5) + 1). Only numbers this file sets are
formatted in; nothing an app or a user supplies reaches this string."
  (format nil "LN((st.n - d.df + 0.5) / (d.df + 0.5) + 1) * (m.tf * ~F) / (m.tf + ~F * (1 - ~F + ~F * c2.term_count / NULLIF(st.avgdl, 0)))"
          (+ *bm25-k1* 1) *bm25-k1* *bm25-b* *bm25-b*))

(defun %bm25-query (corpus terms limit)
  "One SELECT returning the LIMIT chunks of CORPUS with the highest BM25 score for TERMS, best
first, each with its passage columns, its ID and its SCORE. Each piece reads one table through
CORPUS-WHERE: the matched terms, their document frequencies, and the corpus's chunk count and
average length."
  (let* ((store (corpus-store corpus))
         (chunks (store-table store))
         (terms-table (terms-table store))
         (term-rows (lambda (&rest more)
                      (apply #'corpus-where corpus (list := :tokenizer +tokenizer-id+)
                             (list :in :term terms) more)))
         (matches (list :select '(:chunk_id :term :tf)
                        :from (list terms-table)
                        :where (funcall term-rows)))
         (frequencies (list :select '(:term (:as (:count :*) :df))
                            :from (list terms-table)
                            :where (funcall term-rows)
                            :group-by '(:term)))
         (stats (list :select '((:as (:count :*) :n) (:as (:avg :term_count) :avgdl))
                      :from (list chunks)
                      :where (corpus-where corpus (list := :terms_tokenizer +tokenizer-id+))))
         (scored (list :select (list :m.chunk_id
                                     (list :as (list :sum (list :raw (%bm25-expression))) :score))
                       :from (list (list :as matches :m))
                       :join (list (list :inner (list :as frequencies :d) '(:= :d.term :m.term))
                                   (list :inner (list :as chunks :c2) '(:= :c2.id :m.chunk_id))
                                   (list :cross (list :as stats :st)))
                       :group-by '(:m.chunk_id))))
    (list :select (append (%qualified "c" +passage-columns+) '(:c.id :s.score))
          :from (list (list :as chunks :c))
          :join (list (list :inner (list :as scored :s) '(:= :s.chunk_id :c.id)))
          :where (corpus-where corpus)
          :order-by '((:s.score :desc) :c.id)
          :limit limit)))

(defun %keyword-rows (corpus query limit locale)
  "The rows of the LIMIT best BM25 matches for QUERY, best first. NIL when QUERY has no terms."
  (let ((terms (remove-duplicates (tokenize query :locale locale) :test #'string= :from-end t)))
    (and terms
         (%fetch (corpus-store corpus) (%bm25-query corpus terms limit)))))

(defgeneric retrieve-keyword (corpus query &key limit locale)
  (:documentation "The LIMIT chunks of CORPUS that best match QUERY by BM25, best first, each
with its SCORE (#316). QUERY is tokenized as a chunk is (TOKENIZE); LOCALE chooses the stop words
dropped from it, and NIL drops none. Needs no embedding provider.

Returns a RETRIEVAL-RESULT. COMPLETE means every chunk of the corpus was a candidate. TRUNCATED
with reason :NOT-INDEXED gives the number of chunks that have no terms from the current
tokenizer; INDEX-PENDING writes them. A query whose words are all stop words matches nothing."))

(defmethod retrieve-keyword ((corpus corpus) query &key (limit 20) locale)
  (let ((store (corpus-store corpus))
        rows pending)
    ;; One snapshot for the candidates and the count of chunks that could not be candidates,
    ;; for the reason RETRIEVE-SIMILAR gives.
    (with-db (store)
      (conn:with-transaction ((store-connection store))
        (conn:exec (store-connection store) "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        (setf rows (%keyword-rows corpus query limit locale)
              pending (%unindexed-count corpus))))
    (%make-retrieval-result
     (%rows->passages corpus rows :scores (mapcar (lambda (r) (param:row-value r :score)) rows))
     (if (plusp pending)
         (make-truncated :reason :not-indexed :pending pending)
         (make-complete)))))
