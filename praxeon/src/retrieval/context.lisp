;;;; retrieval/context.lisp --- a context for each chunk, written by a chat model (#316).
;;;;
;;;; A chunk often cannot be understood alone: "revenue grew 3%" does not say whose revenue or
;;;; which quarter. Before a chunk of a :HYBRID corpus is embedded and indexed for BM25, a chat
;;;; model writes one or two sentences placing it in its document, and those sentences are put
;;;; before the chunk's text in both. This is the method of Anthropic's article "Introducing
;;;; Contextual Retrieval" (19 September 2024), whose prompt CONTEXT-MESSAGES follows.
;;;;
;;;; ONE CALL PER CHUNK, AND THE DOCUMENT IS SENT EACH TIME. The document comes first and carries
;;;; the prompt-cache marker (praxeon/llm's `:cache t'), so on a provider with a prefix cache the
;;;; document is written to the cache by its first chunk's call and read from it by the others.
;;;; CONTEXTUALIZE-PENDING works through one document at a time for that reason.
;;;;
;;;; A CONTEXT DEPENDS ON THE WHOLE DOCUMENT. It is recorded with the document fingerprint it was
;;;; written against, and a sync that changes any chunk of the document changes that
;;;; fingerprint, so every context of the document is written again. It is also recorded with
;;;; the contextualizer's id, which covers the provider, the model and the prompt, so changing
;;;; any of them makes every context stale.
;;;;
;;;; THE PROVIDER IS PASSED IN, NEVER RESOLVED HERE, as for the embedder (#158). An app resolves
;;;; it with `praxeon/llm:make-provider-from-env' for the role it chooses (#290), and passes it
;;;; to MAKE-CONTEXTUALIZER.

(in-package #:praxeon/retrieval)

(defparameter *context-instruction*
  "Please give a short succinct context to situate this chunk within the overall document for the purposes of improving search retrieval of the chunk. Answer only with the succinct context and nothing else."
  "What the model is asked to do with the document and the chunk, from Anthropic's article. An
app that passes another to MAKE-CONTEXTUALIZER gets a contextualizer with another id, so every
context is written again.")

(defparameter +context-template+ "context/1"
  "The version of the message layout CONTEXT-MESSAGES builds. Part of every contextualizer's id,
so changing the layout makes every context stale.")

(defclass contextualizer ()
  ((provider :initarg :provider :reader contextualizer-provider)
   (instruction :initarg :instruction :reader contextualizer-instruction)
   (max-tokens :initarg :max-tokens :reader contextualizer-max-tokens))
  (:documentation "What writes a chunk's context: a chat PROVIDER, the INSTRUCTION it is given,
and the MAX-TOKENS of its answer. Built with MAKE-CONTEXTUALIZER and given to MAKE-CORPUS."))

(defun make-contextualizer (provider &key (instruction *context-instruction*) (max-tokens 200))
  "A contextualizer that asks PROVIDER, a PRAXEON/LLM:PROVIDER, for each chunk's context.
INSTRUCTION is what the model is asked, after the document and the chunk. MAX-TOKENS caps each
answer; the article's contexts are 50 to 100 tokens."
  (unless (typep provider 'llm:provider)
    (error "praxeon/retrieval: a contextualizer needs a PRAXEON/LLM:PROVIDER, not ~S" provider))
  (unless (and (stringp instruction) (plusp (length instruction)))
    (error "praxeon/retrieval: :instruction must be a non-empty string, not ~S" instruction))
  (unless (typep max-tokens '(integer 1))
    (error "praxeon/retrieval: :max-tokens must be a positive integer, not ~S" max-tokens))
  (make-instance 'contextualizer :provider provider :instruction instruction
                                 :max-tokens max-tokens))

(defun contextualizer-id (contextualizer)
  "The id recorded with each context CONTEXTUALIZER writes: the provider's type, its model, the
message layout, the answer limit and a fingerprint of the instruction, for example
\"anthropic/claude-haiku-4-5/context/1/200/3f2a9c01b7de\". A context recorded with another id is
stale."
  (let ((provider (contextualizer-provider contextualizer)))
    (format nil "~(~A~)/~A/~A/~D/~A"
            (type-of provider) (or (llm:model-of provider) "")
            +context-template+ (contextualizer-max-tokens contextualizer)
            (subseq (section-fingerprint (contextualizer-instruction contextualizer)) 0 12))))

(defun context-messages (contextualizer document chunk)
  "The messages that ask for CHUNK's context within DOCUMENT: one user message whose first part
is the document, marked as the end of the cacheable prefix, and whose second part is the chunk
and the instruction."
  (list (llm:msg "user"
                 (list (llm:text-part (format nil "<document>~%~A~%</document>" document)
                                      :cache t)
                       (llm:text-part
                        (format nil "Here is the chunk we want to situate within the whole document~%<chunk>~%~A~%</chunk>~%~A"
                                chunk (contextualizer-instruction contextualizer)))))))

(defun %estimate (contextualizer document chunk)
  "The tokens one call is assumed to cost before it runs: the whole prompt, cached part
included, since the ledger charges a cache read (PRAXEON/CEILING:BUDGET-GUARD), plus the
longest answer."
  (+ (ceiling (+ (length document) (length chunk)
                 (length (contextualizer-instruction contextualizer)) 100)
              4)
     (contextualizer-max-tokens contextualizer)))

(defun %ask (contextualizer ledger document chunk)
  "One context from the model, charged to LEDGER when there is one. Signals
PRAXEON/CEILING:BUDGET-EXHAUSTED, before calling the model, when LEDGER cannot afford the call."
  (let ((provider (contextualizer-provider contextualizer))
        (estimate (%estimate contextualizer document chunk)))
    (when (and ledger (not (ceiling:affordable-p ledger estimate)))
      (error 'ceiling:budget-exhausted
             :principal (ceiling:grant-principal (ceiling:ledger-grant ledger))
             :requested estimate
             :remaining (ceiling:remaining-tokens ledger)))
    (let ((completion (llm:complete provider (context-messages contextualizer document chunk)
                                    :max-tokens (contextualizer-max-tokens contextualizer))))
      (when ledger
        (ceiling:record-usage ledger
                              :input (or (llm:completion-input-tokens completion) 0)
                              :output (or (llm:completion-output-tokens completion) 0)
                              :cache-read (llm:completion-cache-read-tokens completion)
                              :cache-write (llm:completion-cache-write-tokens completion)
                              :model (or (llm:model-of provider) "")
                              :means "contextualize"))
      (when (eq (llm:completion-stop-reason completion) :refusal)
        (error 'praxeon/conditions:deliberation-failure
               :detail "the contextualizer's model refused to write a chunk's context"))
      (string-trim '(#\Space #\Tab #\Newline #\Return) (llm:completion-text completion)))))

(defun %context-stale-clause (deriver)
  "Chunks with no context from DERIVER against their document as it is now."
  (list :or (list :is-null :context)
        (list :is-null :context_deriver)
        (list :<> :context_deriver deriver)
        (list :is-null :document_fingerprint)
        (list :is-null :context_document_fingerprint)
        (list :<> :context_document_fingerprint :document_fingerprint)))

(defun %pending-documents (corpus deriver)
  "The (document-id locale) pairs of CORPUS that have a chunk without a current context."
  (mapcar (lambda (r) (list (param:row-value r :document_id) (param:row-value r :locale)))
          (rc::%fetch (corpus-store corpus)
                      (list :select '(:document_id :locale)
                            :from (list (store-table (corpus-store corpus)))
                            :where (corpus-where corpus (%context-stale-clause deriver))
                            :group-by '(:document_id :locale)
                            :order-by '(:document_id :locale)))))

(defun %write-context (corpus row context deriver document-fingerprint locale)
  "Write CONTEXT on ROW's chunk, and its terms from the context and the text, if the chunk and
its document are still the ones the context was written for. Returns true when it wrote."
  (let* ((store (corpus-store corpus))
         (table (store-table store))
         (id (param:row-value row :id))
         (input (rc::%embed-input context (param:row-value row :text))))
    (rc::with-db (store)
      (conn:with-transaction ((store-connection store))
        (let ((n (rc::%run store
                           (list :update table
                                 :set (list :context context
                                            :context_deriver deriver
                                            :context_document_fingerprint document-fingerprint
                                            :input_fingerprint (section-fingerprint input))
                                 :where (corpus-where
                                         corpus (list := :id id)
                                         (list := :section_fingerprint
                                               (param:row-value row :section_fingerprint))
                                         (list := :document_fingerprint document-fingerprint))))))
          (when (and (integerp n) (plusp n))
            ;; The BM25 terms are taken from what is embedded, so they change with the context.
            (rc::%delete-terms corpus (list := :id id))
            (rc::%run store (list :update table
                                  :set (list :term_count (rc::%write-terms corpus id input locale)
                                             :terms_tokenizer +tokenizer-id+)
                                  :where (corpus-where corpus (list := :id id))))
            t))))))

(defun %contextualize-document (corpus contextualizer ledger document-id locale)
  "Write every stale context of DOCUMENT-ID in LOCALE. Returns how many were written."
  (let* ((deriver (contextualizer-id contextualizer))
         (rows (rc::%document-rows corpus document-id locale
                                   '(:id :text :section_fingerprint :context :context_deriver
                                     :context_document_fingerprint :document_fingerprint)))
         (texts (mapcar (lambda (r) (param:row-value r :text)) rows))
         (fingerprint (rc::%document-fingerprint texts))
         (document (format nil "~{~A~^~%~%~}" texts))
         (count 0))
    ;; A chunk synced before #316's step 3 has no document fingerprint. It is computed from the
    ;; same rows, the same way a sync computes it.
    (when (some (lambda (r) (not (equal fingerprint (param:row-value r :document_fingerprint))))
                rows)
      (rc::with-db ((corpus-store corpus))
        (rc::%refresh-document-fingerprint corpus document-id locale)))
    (dolist (row rows count)
      (unless (and (param:row-value row :context)
                   (equal deriver (param:row-value row :context_deriver))
                   (equal fingerprint (param:row-value row :context_document_fingerprint)))
        (let ((context (%ask contextualizer ledger document (param:row-value row :text))))
          (when (%write-context corpus row context deriver fingerprint locale)
            (incf count)))))))

(defun contextualize-pending (corpus &key ledger)
  "Write a context for every chunk of CORPUS that has none from the corpus's contextualizer
against its document as it is now (#316). Returns the number written, and a second value saying
why nothing was attempted when that is the case:

  :NO-CONTEXTUALIZER      the corpus was made without one
  :WHOLE                  the corpus's strategy is :WHOLE, so no chunk needs a context
  :BACKFILL-NOT-STARTED   an :AUTO corpus made with :BACKFILL :EXPLICIT grew past its limit, and
                          the app has not called START-BACKFILL
  :DONE                   otherwise

Each context costs one chat call, with the whole document in the prompt; see this file's
commentary for how the prompt cache keeps that to one full read of each document. LEDGER, a
PRAXEON/CEILING:LEDGER, bounds the calls: each is charged to it, and before a call it cannot
afford this signals PRAXEON/CEILING:BUDGET-EXHAUSTED. The contexts written before that are kept,
and the next call carries on from them.

Each context is written with its chunk's BM25 terms, from the context and the text, and makes
the chunk's embedding stale, so EMBED-PENDING embeds it again. Serialised per corpus with the
syncs (WITH-CORPUS-LOCK); the model is called outside the database lock."
  (let ((contextualizer (corpus-contextualizer corpus)))
    (cond
      ((null contextualizer) (values 0 :no-contextualizer))
      ((not (typep contextualizer 'contextualizer))
       (error "praxeon/retrieval: the corpus ~A's contextualizer must come from MAKE-CONTEXTUALIZER, not ~S"
              (corpus-name corpus) contextualizer))
      ((eq (corpus-effective-strategy corpus) :whole) (values 0 :whole))
      ((rc::%backfill-held-p corpus) (values 0 :backfill-not-started))
      (t
       (let ((count 0))
         (with-corpus-lock (corpus)
           (dolist (group (%pending-documents corpus (contextualizer-id contextualizer)))
             (incf count (%contextualize-document corpus contextualizer ledger
                                                  (first group) (second group)))))
         (when (plusp count)
           (log:info "retrieval contexts written" :corpus (corpus-name corpus) :count count))
         (values count :done))))))
