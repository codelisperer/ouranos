;;;; memory-db.lisp --- observational memory in a database, with similarity recall (#138).
;;;;
;;;; AN AUX SYSTEM, AND THE DAG IS NOT THE REASON. mnemosyne sits to praxeon's LEFT, so
;;;; `praxeon -> mnemosyne' is a leftward dependency the DAG permits outright. Recording
;;;; "the DAG forbids it" would be recording something false, and the next person to check
;;;; would find the dependency legal and reasonably reopen a decision that was right for a
;;;; different reason.
;;;;
;;;; What forbids it is the design rule, stated twice in places that already bind. pre-publication issue 258's
;;;; deliverable 2, which this work descends from: "a praxeon-side seam for storing and
;;;; querying embeddings inside a workflow, WITHOUT PRAXEON GROWING A DATASTORE OF ITS OWN."
;;;; And praxeon/CLAUDE.md: "anything an agent sends or stores externally reaches praxeon as
;;;; an injected seam, never a dependency." praxeon's core `:depends-on' is ("aion/log") and
;;;; nothing else; web, web-search and elise are already aux. A database-backed memory store
;;;; is the hermes shape -- something an agent stores externally, reaching praxeon through a
;;;; protocol praxeon owns.
;;;;
;;;; THE SCHEMA IS BUILT AT RUNTIME, WHICH IS THE POINT RATHER THAN AN INCONVENIENCE (#150).
;;;; A vector column carries its width in its type, and that width follows from which
;;;; embedding model an operator configured. A literal `(:embedding :vector :dimensions
;;;; 1536)' in a DEFSCHEMA has hard-coded OpenAI's text-embedding-3-small into the schema.
;;;; So the width comes from the injected provider and the schema is assembled from it.
;;;;
;;;; WRITES GO THROUGH cast -> validate -> insert!, the path AGENTS.md names for external
;;;; input, which is also what renders a vector into the form pgvector accepts -- measured,
;;;; not assumed: a Lisp list bound as a parameter reaches Postgres as array syntax and is
;;;; refused. THE QUERY VECTOR GOES THROUGH `cast' TOO, so the width refusal that protects
;;;; stored rows protects the search argument with the same code.
;;;;
;;;; THE INDEX MATCHES THE OPERATOR IT SERVES. `<=>' is cosine distance, so the HNSW index
;;;; is built with `vector_cosine_ops'. pre-publication issue 258's named trap is that an index built for one
;;;; distance operator does not serve a query written with another -- no error, correct
;;;; rows, and a sequential scan over the whole table. Choosing both in one file is how they
;;;; are kept in agreement.
;;;;
;;;; ON SQLITE (#425) there is no vector type. The embedding is stored as text in pgvector's
;;;; form ([x,y,...], PRAXEON/LLM:VECTOR-TEXT), and RECALL-SIMILAR reads the subject's current
;;;; observations with their embeddings and ranks them by cosine distance in Lisp. That is an
;;;; exact scan over one subject's observations, which is what an index would narrow to on
;;;; Postgres anyway at one user's scale. There is no index and no extension to check.

(cl:defpackage #:praxeon/memory-db
  (:use #:cl)
  (:local-nicknames (#:mem #:praxeon/memory)
                    (#:llm #:praxeon/llm)
                    (#:ctx #:praxeon/context)
                    (#:q #:mnemosyne/query)
                    (#:cs #:mnemosyne/changeset)
                    (#:param #:mnemosyne/param)
                    (#:schema #:mnemosyne/schema)
                    (#:ddl #:mnemosyne/ddl)
                    (#:mig #:mnemosyne/migrate)
                    (#:conn #:mnemosyne/conn)
                    (#:bt #:bordeaux-threads))
  (:documentation
   "Observational memory persisted through mnemosyne, with similarity recall over pgvector,
    or on SQLite over embeddings stored as text (#425).

    Implements praxeon/memory's store protocol, so a caller swaps it for the in-memory store
    without changing. Adds RECALL-SIMILAR, which the in-memory store does not answer.")
  (:export #:db-memory-store #:make-db-memory-store
           #:ensure-schema #:check-vector-extension #:store-schema #:store-table #:store-dimensions
           #:*table*))

(in-package #:praxeon/memory-db)

(defvar *table* "praxeon_observations"
  "Default table name.")

(defun %schema-fields (dimensions dialect)
  "The observation columns, with the embedding sized for the configured provider. On SQLite
the embedding is text (#425).

Underscores rather than hyphens: a field name becomes a SQL identifier unquoted, and
`valid-from' is not one."
  `((:id           :string  :primary t)
    (:subject      :string  :required t)
    (:content      :text    :required t)
    (:kind         :string)
    (:value        :float)
    (:tokens       :integer)
    (:valid_from   :integer)
    (:recorded_at  :integer)
    (:supersedes   :string)
    (:superseded_by :string)
    (:superseded_at :integer)
    ;; PROVENANCE AS REAL COLUMNS (#150), not a blob: "which conversation" has to be
    ;; answerable as a query -- show me everything this conversation put in the store, so a
    ;; member disputing one claim can see the rest from the same turn.
    (:source_conversation :string)
    (:source_turn  :integer)
    (:source_at    :integer)
    ;; THE SCOPE AND THE WINDOW (#317). THREAD is NULL for a fact about the subject and a
    ;; thread's id for an observation of that thread; SOURCE_THROUGH is the last turn of the
    ;; window an observation came from. Added to an existing table by ENSURE-SCHEMA.
    (:thread       :string)
    (:source_through :integer)
    ,(if (eq dialect :sqlite)
         '(:embedding :text)
         `(:embedding :vector :dimensions ,dimensions))))

;;; THE OBSERVER'S PROGRESS ON EACH THREAD (#317), one row per subject and thread, in a table of
;;; its own beside the observations: see PRAXEON/MEMORY:THREAD-PROGRESS for why it is recorded
;;; rather than worked out from them. SKIPPED is the windows given up on, "FROM-THROUGH-TRIES"
;;; joined by commas, with "-closed" after a closed one.
(defparameter +progress-fields+
  '((:id         :string  :primary t)
    (:subject    :string  :required t)
    (:thread     :string  :required t)
    (:observed   :integer :required t)
    (:skipped    :text)
    (:updated_at :integer)))

(defun %progress-table (table) (format nil "~A_progress" table))

(defun %progress-id (subject thread)
  "One key for a subject and a thread. The subject's length comes first, so no pair of strings
gives another pair's key."
  (format nil "~D:~A~A" (length subject) subject thread))

;;; --- the store --------------------------------------------------------------

(defclass db-memory-store (mem:memory-store)
  ((connection :initarg :connection :reader store-connection)
   (dialect :initarg :dialect :initform :postgres :reader store-dialect)
   (table :initarg :table :initform *table* :reader store-table)
   (embedder :initarg :embedder :reader store-embedder)
   (dimensions :initarg :dimensions :reader store-dimensions)
   (schema :initarg :schema :reader store-schema)
   (schema-name :initarg :schema-name :reader store-schema-name)
   (progress-schema :initarg :progress-schema :reader store-progress-schema)
   ;; Recursive because SUPERSEDE holds it around REMEMBER, so the check that the observation
   ;; is still current and the writes that replace it are one step.
   (lock :initform (bt:make-recursive-lock "praxeon-memory-db") :reader store-lock))
  (:documentation "Observations in a mnemosyne-backed table, embedded on write."))

(defun make-db-memory-store (connection &key embedder (table *table*) (dialect :postgres)
                                          ensure)
  "A store over CONNECTION. EMBEDDER is an LLM:EMBEDDING-PROVIDER and decides the width.

EMBEDDER IS INJECTED, NOT RESOLVED HERE. `make-embedding-provider-from-env' reads
`*provider-role*', and #158 records that resolving across a thread boundary falls through to
the shared level without erroring -- the wrong model, quietly. Resolve it where the role is
bound and hand it in; then no path through this store can resolve one."
  (check-type table string)
  (unless embedder
    (error "praxeon/memory-db: an embedder is required -- the column's width comes from it"))
  (unless (member dialect '(:postgres :sqlite))
    (error "praxeon/memory-db: :dialect is :postgres or :sqlite, not ~S" dialect))
  (let* ((dimensions (llm:embedding-dimensions embedder))
         ;; The dialect is in the name because the schema differs by dialect: a Postgres and a
         ;; SQLite store over tables of the same name must not replace each other's schema.
         (name (intern (format nil "~:@(~A~)-~A" table dialect) '#:praxeon/memory-db))
         (sch (schema:register-schema
               (schema:make-schema name table (%schema-fields dimensions dialect))))
         (progress (schema:register-schema
                    (schema:make-schema (intern (format nil "~:@(~A~)-PROGRESS-~A" table dialect) '#:praxeon/memory-db)
                                        (%progress-table table) +progress-fields+)))
         (store (make-instance 'db-memory-store
                               :connection connection :dialect dialect :table table
                               :embedder embedder :dimensions dimensions
                               :schema sch :schema-name name :progress-schema progress)))
    (when ensure (ensure-schema store))
    store))

(defun store-ddl (store)
  "Every statement this store's table needs, in order. Returns a list of SQL strings."
  (let ((table (store-table store)))
    (append
     ;; No CREATE EXTENSION here (#138). The extension is a deployment fact, and on a managed
     ;; Postgres the application's role usually cannot create it. ENSURE-SCHEMA checks that it
     ;; is present instead; see CHECK-VECTOR-EXTENSION.
     (list (schema:schema-ddl (store-schema store) :dialect (store-dialect store))
           (schema:schema-ddl (store-progress-schema store) :dialect (store-dialect store)))
     ;; THE INDEX IS BUILT FOR THE OPERATOR THIS STORE QUERIES WITH. `<=>' is cosine, so
     ;; vector_cosine_ops. An index built for a different operator is not an error and not
     ;; slow-and-obvious -- it is correct rows and a sequential scan (pre-publication issue 258).
     (when (eq (store-dialect store) :postgres)
       (list (ddl:ddl (list :create-index
                            :name (intern (string-upcase
                                           (format nil "~A_embedding_idx" table)) :keyword)
                            :on (intern (string-upcase table) :keyword)
                            :columns '(:embedding)
                            :using :hnsw
                            :opclass :vector_cosine_ops)
                      :dialect (store-dialect store)))))))

(defun check-vector-extension (connection)
  "Signal PRAXEON/CONDITIONS:VECTOR-EXTENSION-MISSING unless the `vector' extension is
installed in CONNECTION's database. Reads pg_extension and never creates it (#138)."
  (unless (mig:extension-present-p connection "vector")
    (error 'praxeon/conditions:vector-extension-missing
           :database (param:row-value (first (conn:query connection
                                                         "SELECT current_database() AS db"))
                                      :db))))

(defparameter +added-columns+ '((:thread . :string) (:source_through . :integer))
  "Columns added after a table may already exist, with their schema field types: the thread scope
and the window's last turn (#317). ENSURE-SCHEMA adds each one a table lacks.")

(defun %add-column-sql (store name type)
  "The ALTER TABLE statement adding column NAME of field TYPE to STORE's table, in mnemosyne's
own types for the dialect, so a migrated column matches what a new table gets (on SQLite an
:integer is INTEGER; mnemosyne's introspection reports anything else as drift). On Postgres it
says ADD COLUMN IF NOT EXISTS, which needs no catalogue query and cannot race another process
starting at the same moment."
  (let ((sql (ddl:ddl (list :alter-table (intern (string-upcase (store-table store)) :keyword)
                            (list :add-column name type))
                      :dialect (string-downcase (symbol-name (store-dialect store))))))
    (if (eq (store-dialect store) :postgres)
        (let ((at (search "ADD COLUMN " sql)))
          (concatenate 'string (subseq sql 0 (+ at 11)) "IF NOT EXISTS " (subseq sql (+ at 11))))
        sql)))

(defun %sqlite-columns (store)
  "The lowercased names of the columns STORE's SQLite table has."
  (mapcar (lambda (row) (string-downcase (param:row-value row :name)))
          (conn:query (store-connection store) (format nil "PRAGMA table_info(~A)" (store-table store)))))

(defun ensure-schema (store)
  "Create the table, its index and the observer's progress table (#317) if they are not there,
and add the columns +ADDED-COLUMNS+ names to a table made before them. Returns STORE. On Postgres the `vector' extension must
already be installed; see CHECK-VECTOR-EXTENSION.

EVERY READ NEEDS THOSE COLUMNS, not only a thread's: a read of the subject's facts selects them
and filters on THREAD IS NULL. So an app must run this at start, or add the columns in its own
migration, before it reads from a table made before #317."
  (when (eq (store-dialect store) :postgres)
    (check-vector-extension (store-connection store)))
  (dolist (statement (store-ddl store))
    (conn:exec (store-connection store) statement))
  (let ((have (and (eq (store-dialect store) :sqlite) (%sqlite-columns store))))
    (loop for (name . type) in +added-columns+
          unless (member (string-downcase (symbol-name name)) have :test #'string=)
            ;; Postgres answers an existing column with a notice, which the driver signals as
            ;; a warning; it is the expected case on every start after the first.
            do (handler-bind ((warning #'muffle-warning))
                 (handler-case (conn:exec (store-connection store) (%add-column-sql store name type))
                   ;; ON SQLITE, ANOTHER PROCESS MAY ADD THE COLUMN between the read of the
                   ;; columns above and this statement; SQLite has no IF NOT EXISTS for it. A
                   ;; failure is accepted only when the column is there afterwards.
                   (error (e)
                     (unless (and (eq (store-dialect store) :sqlite)
                                  (member (string-downcase (symbol-name name)) (%sqlite-columns store)
                                          :test #'string=))
                       (error e)))))))
  store)

;;; --- rows <-> observations ---------------------------------------------------

;;; The local case-insensitive reader that lived here is now MNEMOSYNE/PARAM:ROW-VALUE
;;; (pre-publication issue 489) -- this store's `%row-get' was the fourth independent copy of it, and the defect
;;; it was written for was found HERE: GETF missed every column because the driver interns
;;; keys lowercase, every column read back as its default, and every count assertion passed.
;;;
;;; The shared one SIGNALS on a key that matches nothing, where this returned NIL. That is
;;; the behaviour worth having and it is safe here: every key below is a column this store's
;;; own schema declares, and +COLUMNS+ selects all of them. A miss would mean the table is
;;; not the one this store made -- which is worth a condition rather than an observation
;;; silently restored with an empty subject.

(defun %row->observation (row)
  (mem::%make-observation
   :id (or (param:row-value row :id) "")
   :subject (or (param:row-value row :subject) "")
   :content (or (param:row-value row :content) "")
   :kind (let ((k (param:row-value row :kind)))
           (if (and k (plusp (length k))) (intern (string-upcase k) :keyword) :observation))
   :value (or (param:row-value row :value) 1)
   :tokens (or (param:row-value row :tokens) 0)
   :valid-from (or (param:row-value row :valid_from) 0)
   :recorded-at (or (param:row-value row :recorded_at) 0)
   :supersedes (param:row-value row :supersedes)
   :superseded-by (param:row-value row :superseded_by)
   :superseded-at (param:row-value row :superseded_at)
   ;; READ BACK FROM THE COLUMNS, never reconstructed from the content. #138's hard rule:
   ;; "the traceable provenance is never reconstructed from the rendered text" -- a citation
   ;; parsed back out of prose is a guess about what the model was told, not a record of
   ;; what was stored.
   :thread (let ((th (param:row-value row :thread))) (and (stringp th) th))
   :provenance (mem:make-provenance (or (param:row-value row :source_conversation) "")
                                    (or (param:row-value row :source_turn) 0)
                                    :at (param:row-value row :source_at)
                                    :through (param:row-value row :source_through))))

(defparameter +columns+
  '(:id :subject :content :kind :value :tokens :valid_from :recorded_at
    :supersedes :superseded_by :superseded_at
    :source_conversation :source_turn :source_at :thread :source_through)
  "What a read selects. NOT the embedding: it is large, it is never shown to anyone, and
selecting it would pull a megabyte of floats through every recall to be discarded.")

(defun %vector-text (store vector &key (field :embedding))
  "VECTOR in the text form pgvector accepts, through mnemosyne's own cast. On SQLite, where
the column is text and a cast would take any string, PRAXEON/LLM:VECTOR-TEXT does the width
check instead (#425).

THE QUERY VECTOR IS CAST LIKE A STORED ONE, on purpose. Casting is where a wrong width is
refused, and a search argument of the wrong width is the same misconfiguration as a stored
row of the wrong width -- it should not reach the database to be refused there in the
language of columns."
  (when (eq (store-dialect store) :sqlite)
    (return-from %vector-text (llm:vector-text vector (store-dimensions store))))
  (let ((changeset (cs:cast (store-schema-name store) (list field vector) (list field))))
    (unless (cs:changeset-valid-p changeset)
      (error 'praxeon/conditions:deliberation-failure
             :detail (format nil "embedding rejected by cast: ~S" (cs:changeset-errors changeset))))
    (cs:get-change changeset field)))

;;; --- the protocol ------------------------------------------------------------

(defun %now () (get-universal-time))

(defvar *embedded* nil
  "(CONTENT . EMBEDDING), computed before the store's lock was taken, for the REMEMBER that
SUPERSEDE calls under it. The embedding model is a network call, and a request's read waits for
the lock (#462's third review: 997 ms behind a 1 s embedder).")

(defun %embed-before-lock (store content)
  "CONTENT's embedding, as *EMBEDDED* holds it."
  (cons content (first (llm:embed-documents (store-embedder store) (list content)))))

(defmethod mem:remember ((store db-memory-store) subject content
                         &key provenance (kind :observation) (value 1) tokens valid-from thread)
  (mem:check-provenance provenance "remember" subject)
  (let* ((id (format nil "obs-~36R-~36R" (get-universal-time) (random (expt 2 32))))
         (now (%now))
         (embedding (if (and *embedded* (string= (car *embedded*) content))
                        (cdr *embedded*)
                        (first (llm:embed-documents (store-embedder store) (list content)))))
         (observation (mem::%make-observation
                       :id id :subject subject :content content :kind kind :value value
                       :tokens (or tokens (max 1 (ceiling (length content) 4)))
                       :valid-from (or valid-from now) :recorded-at now
                       :thread thread :provenance provenance)))
    (bt:with-recursive-lock-held ((store-lock store))
      ;; AN UNRECORDED SOURCE TIME IS OMITTED, NOT CAST. `cast' refuses NIL for an integer
      ;; field -- correctly, because NIL is not an integer -- and the tempting fixes are
      ;; both wrong: coercing it to 0 invents a time, and widening the column's type to
      ;; accept NIL would make every integer field in the tree accept a non-integer. A field
      ;; simply absent from the params is absent from the INSERT, so the column is NULL
      ;; because nothing was written to it. That is the same distinction the value carries
      ;; in Lisp, kept intact through the write rather than restored afterwards.
      (let* ((at (mem:provenance-at provenance))
             (through (mem:provenance-through provenance))
             (changeset (cs:cast (store-schema-name store)
                                 (append
                                  (list :id id :subject subject :content content
                                        :kind (string-downcase (symbol-name kind))
                                        :value (float value 1.0d0)
                                        :tokens (mem:observation-tokens observation)
                                        :valid_from (mem:observation-valid-from observation)
                                        :recorded_at now
                                        :source_conversation (mem:provenance-conversation provenance)
                                        :source_turn (mem:provenance-turn provenance)
                                        :embedding (if (eq (store-dialect store) :sqlite)
                                                       (%vector-text store embedding)
                                                       embedding))
                                  (when at (list :source_at at))
                                  (when through (list :source_through through))
                                  (when thread (list :thread thread)))
                                 (append
                                  '(:id :subject :content :kind :value :tokens
                                    :valid_from :recorded_at :embedding
                                    :source_conversation :source_turn)
                                  (when at '(:source_at))
                                  (when through '(:source_through))
                                  (when thread '(:thread))))))
        (cs:insert! changeset (store-connection store) :dialect (store-dialect store))))
    observation))

(defmethod mem:supersede ((store db-memory-store) observation content
                          &key provenance kind value tokens valid-from)
  (mem:check-provenance provenance "supersede" (mem:observation-subject observation))
  ;; THE CHECK AND THE WRITES ARE ONE STEP (#462's second review). Under the store's lock no
  ;; other thread of this process can supersede OBSERVATION between the check and the update,
  ;; and in one transaction a failure part-way through, or a thread ended by STOP-OBSERVER,
  ;; leaves neither the replacement nor a half-made link behind. Another process is held off
  ;; by the UPDATE itself, which only changes a row that is still current and must change one.
  ;; The embedding is computed first, outside the lock.
  (let ((*embedded* (%embed-before-lock store content)))
    (bt:with-recursive-lock-held ((store-lock store))
      (conn:with-transaction ((store-connection store))
        (let ((row (first (q:fetch (store-connection store)
                                   (list :select '(:superseded_by)
                                         :from (list (store-table store))
                                         :where (list := :id (mem:observation-id observation)))
                                   :dialect (store-dialect store)))))
          (unless row
            (error 'praxeon/conditions:praxeon-error
                   :detail (format nil "cannot supersede ~A: it is not in this store" (mem:observation-id observation))))
          (when (param:row-value row :superseded_by)
            (error 'praxeon/conditions:praxeon-error
                   :detail (format nil "~A was already superseded by ~A" (mem:observation-id observation)
                                   (param:row-value row :superseded_by)))))
        (let ((replacement (mem:remember store (mem:observation-subject observation) content
                                         :thread (mem:observation-thread observation)
                                         :provenance provenance
                                         :kind (or kind (mem:observation-kind observation))
                                         :value (or value (mem:observation-value observation))
                                         :tokens tokens :valid-from valid-from)))
          (unless (eql 1 (q:run (store-connection store)
                                (list :update (store-table store)
                                      :set (list :superseded_by (mem:observation-id replacement)
                                                 :superseded_at (mem:observation-recorded-at replacement))
                                      :where (list :and (list := :id (mem:observation-id observation))
                                                   (list :is-null :superseded_by)))
                                :dialect (store-dialect store)))
            (error 'praxeon/conditions:praxeon-error
                   :detail (format nil "~A was superseded by another process meanwhile" (mem:observation-id observation))))
          (q:run (store-connection store)
                 (list :update (store-table store)
                       :set (list :supersedes (mem:observation-id observation))
                       :where (list := :id (mem:observation-id replacement)))
                 :dialect (store-dialect store))
          (setf (mem:observation-superseded-by observation) (mem:observation-id replacement)
                (mem:observation-superseded-at observation) (mem:observation-recorded-at replacement)
                (mem:observation-supersedes replacement) (mem:observation-id observation))
          replacement)))))

(defun %where-current (subject as-of include-superseded &optional thread)
  "The WHERE clause for a subject's observations in the scope THREAD names: NIL for facts about
the subject, a thread's id for that thread, :ALL for both.

AS-OF answers what the store believed then: recorded by then, and superseded only if the
supersession had happened by then. A row superseded LATER was still current at that time,
which is the whole point of keeping the old one."
  (let ((clauses (list (list := :subject subject))))
    (cond ((eq thread :all))
          ((null thread) (push (list :is-null :thread) clauses))
          (t (push (list := :thread thread) clauses)))
    (when as-of
      (push (list :<= :recorded_at as-of) clauses))
    (unless include-superseded
      (push (if as-of
                (list :or (list :is-null :superseded_by) (list :> :superseded_at as-of))
                (list :is-null :superseded_by))
            clauses))
    (if (rest clauses) (cons :and (nreverse clauses)) (first clauses))))

(defmethod mem:observations-of ((store db-memory-store) subject &key as-of include-superseded thread)
  (bt:with-recursive-lock-held ((store-lock store))
    (mapcar #'%row->observation
            (q:fetch (store-connection store)
                     (list :select +columns+
                           :from (list (store-table store))
                           :where (%where-current subject as-of include-superseded thread)
                           :order-by '(:recorded_at))
                     :dialect (store-dialect store)))))

(defun %rank-as-value (observations)
  "OBSERVATIONS, nearest first, with VALUE set from rank. Returns them.

WHY THE RANK HAS TO BE CARRIED. The database ranks by distance; `ctx:assemble' then selects
what fits the budget BY VALUE and emits chronologically. Left alone, those two steps
disagree: the ranking is computed, discarded, and the budget keeps whichever rows happened
to carry a high value -- so a distant observation can displace the nearest one, and the
result still looks like a plausible answer. Found by a test asserting the nearest came back,
which it did not.

So proximity becomes the value the budget selects on. The EMITTED order stays chronological,
the same as RECALL, because that is a presentation choice and a prompt reads better in time
order; what proximity decides is WHICH observations are there at all."
  (let ((n (length observations)))
    (loop for o in observations
          for rank from 0
          do (setf (mem:observation-value o) (- n rank)))
    observations))

(defun %assemble (observations budget kind)
  "OBSERVATIONS through the same budgeted assembly the in-memory store uses.

Memory competes for prompt space on the same terms as everything else rather than on terms
of its own -- which is why this is ctx:assemble and not a LIMIT."
  (let ((wanted (if kind
                    (remove-if-not (lambda (o) (eq (mem:observation-kind o) kind)) observations)
                    observations))
        (context (ctx:make-context :budget budget)))
    (dolist (o wanted)
      ;; THE SHARED CONSTRUCTOR (#150), not a second copy. This store had its own inline
      ;; version of the same five fields; a citation added to one and not the other is
      ;; exactly the drift that produces a store whose items can be cited and another
      ;; whose cannot, for no reason a caller could predict.
      (ctx:add-item context (mem:observation->ctx-item o)))
    (ctx:assemble context)))

(defmethod mem:recall ((store db-memory-store) subject &key (budget 1000) kind as-of thread)
  (%assemble (mem:observations-of store subject :as-of as-of :thread thread) budget kind))

(defmethod mem:recall-similar ((store db-memory-store) subject embedding
                               &key (budget 1000) kind as-of (limit 20) thread)
  "Nearest by COSINE distance, then budgeted.

TWO STAGES, AND THE ORDER MATTERS. The database ranks by distance and takes LIMIT rows,
because that is the part an index can serve; the budget is applied afterwards in the same
assembly every other context source uses. Budgeting first would mean fetching everything to
throw most of it away, and ranking in Lisp would mean the index served nothing.

ONE SCOPE: THREAD :ALL is refused, as RECALL refuses it, since a recall builds a prompt (#317)."
  (when (eq thread :all)
    (error 'praxeon/conditions:praxeon-error
           :detail "recall-similar takes one scope: NIL for the subject's facts, or a thread's id; :all is for observations-of"))
  (let ((rows (if (eq (store-dialect store) :sqlite)
                  (%sqlite-nearest store subject embedding as-of limit thread)
                  (bt:with-recursive-lock-held ((store-lock store))
                    (q:fetch (store-connection store)
                             (list :select +columns+
                                   :from (list (store-table store))
                                   :where (%where-current subject as-of nil thread)
                                   :order-by (list (list (list :<=> :embedding
                                                               (%vector-text store embedding))))
                                   :limit limit)
                             :dialect (store-dialect store))))))
    (%assemble (%rank-as-value (mapcar #'%row->observation rows)) budget kind)))

(defun %sqlite-nearest (store subject embedding as-of limit &optional thread)
  "RECALL-SIMILAR's ranking on SQLite (#425): the subject's current observations with their
embeddings, the LIMIT nearest EMBEDDING by cosine distance, nearest first, ties by id. The
query vector is checked for width as a stored one is. An observation with no embedding sorts
after every other, as NULL does in Postgres's ascending ORDER BY. REMEMBER always writes one,
so that case needs a row written some other way."
  (let* ((query (llm:parse-vector-text (%vector-text store embedding)))
         (rows (bt:with-recursive-lock-held ((store-lock store))
                 (q:fetch (store-connection store)
                          (list :select (append +columns+ '(:embedding))
                                :from (list (store-table store))
                                :where (%where-current subject as-of nil thread))
                          :dialect :sqlite)))
         (scored (mapcar (lambda (row)
                           (let ((text (param:row-value row :embedding)))
                             (cons (if text
                                       (llm:cosine-distance query (llm:parse-vector-text text))
                                       most-positive-double-float)
                                   row)))
                         rows))
         (sorted (sort scored (lambda (a b)
                                (or (< (car a) (car b))
                                    (and (= (car a) (car b))
                                         (string< (param:row-value (cdr a) :id)
                                                  (param:row-value (cdr b) :id))))))))
    (mapcar #'cdr (subseq sorted 0 (min limit (length sorted))))))

(defmethod mem:forget ((store db-memory-store) observation)
  (bt:with-recursive-lock-held ((store-lock store))
    ;; Unlink the forward pointer first, or a surviving predecessor claims to be superseded
    ;; by something no longer there and can never be current again. Same rule as the
    ;; in-memory store; stated here because the storage does not enforce it.
    (q:run (store-connection store)
           (list :update (store-table store)
                 ;; NIL, not :NULL. In this DSL a keyword is an IDENTIFIER, so `:null'
                 ;; would render as the bare word null -- which Postgres happens to read as
                 ;; the literal, making it right by accident. NIL is a value and binds as
                 ;; SQL NULL through the parameter path, which is right on purpose.
                 :set (list :superseded_by nil :superseded_at nil)
                 :where (list := :superseded_by (mem:observation-id observation)))
           :dialect (store-dialect store))
    (let ((n (q:run (store-connection store)
                    (list :delete-from (store-table store)
                          :where (list := :id (mem:observation-id observation)))
                    :dialect (store-dialect store))))
      (and (integerp n) (plusp n)))))

(defmethod mem:forget-subject ((store db-memory-store) subject)
  "ERASURE, NOT SUPERSESSION -- the rows are gone, including from :as-of views (#150)."
  (bt:with-recursive-lock-held ((store-lock store))
    (let ((n (q:run (store-connection store)
                    (list :delete-from (store-table store)
                          :where (list := :subject subject))
                    :dialect (store-dialect store))))
      ;; THE PROGRESS TABLE MAY NOT EXIST: an app with its own migrations needs it only to use
      ;; praxeon/observe. It is looked for first rather than a failed delete caught, because on
      ;; Postgres a failed statement would abort a transaction the app wrapped around this call.
      ;; Each of the subject's progress rows keeps its mark and loses its skipped windows, the
      ;; only part of it that described the conversation (#462, the maintainer's ruling).
      (when (%table-exists-p store (%progress-table (store-table store)))
        (q:run (store-connection store)
               (list :update (%progress-table (store-table store))
                     :set (list :skipped "" :updated_at (get-universal-time))
                     :where (list := :subject subject))
               :dialect (store-dialect store)))
      (if (integerp n) n 0))))

(defun %table-exists-p (store table)
  "Whether TABLE exists in STORE's database, found the way an unquoted name in a statement is: on
Postgres through the search path (TO_REGCLASS), on SQLite without regard to case."
  (not (null (conn:query (store-connection store)
                         (if (eq (store-dialect store) :sqlite)
                             (format nil "SELECT name FROM sqlite_master WHERE type = 'table' AND name = '~A' COLLATE NOCASE" table)
                             (format nil "SELECT 1 AS present WHERE to_regclass('~A') IS NOT NULL" table))))))

(defun %skipped->text (skipped)
  "SKIPPED as \"FROM-THROUGH-TRIES\" entries joined by commas, with \"-closed\" after a closed one."
  (format nil "~{~A~^,~}"
          (mapcar (lambda (e) (format nil "~D-~D-~D~:[~;-closed~]" (first e) (second e) (third e)
                                      (eq (fourth e) :closed)))
                  skipped)))

(defun %text->skipped (text)
  (when (and text (plusp (length text)))
    (loop for entry in (uiop:split-string text :separator ",")
          collect (destructuring-bind (from through tries &optional status)
                      (uiop:split-string entry :separator "-")
                    (append (mapcar #'parse-integer (list from through tries))
                            (when (equal status "closed") (list :closed)))))))

(defmethod mem:thread-progress ((store db-memory-store) subject thread)
  (let ((row (bt:with-recursive-lock-held ((store-lock store))
               (first (q:fetch (store-connection store)
                               (list :select '(:observed :skipped)
                                     :from (list (%progress-table (store-table store)))
                                     :where (list := :id (%progress-id subject thread)))
                               :dialect (store-dialect store))))))
    (if row
        (values (param:row-value row :observed) (%text->skipped (param:row-value row :skipped)))
        (values nil nil))))

(defmethod mem:record-thread-progress ((store db-memory-store) subject thread mark skipped)
  (let ((text (%skipped->text skipped)))
    (bt:with-recursive-lock-held ((store-lock store))
      (q:run (store-connection store)
             (list :insert-into (%progress-table (store-table store))
                   :values (list (list :id (%progress-id subject thread) :subject subject :thread thread
                                       :observed mark :skipped text :updated_at (get-universal-time)))
                   :on-conflict '(:id)
                   :do-update (list :observed mark :skipped text :updated_at (get-universal-time)))
             :dialect (store-dialect store))))
  mark)
