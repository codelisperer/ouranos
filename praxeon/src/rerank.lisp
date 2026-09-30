;;;; rerank.lisp --- ordering search candidates by how well they answer a query, as a provider
;;;; call (#316).
;;;;
;;;; A reranker reads a query and a list of candidate passages together and scores each passage
;;;; against the query. That is slower than comparing vectors, so it runs on the few hundred
;;;; candidates a search has already found, and it orders them better than the search did.
;;;; Anthropic's contextual-retrieval article measured the share of queries whose answer was not
;;;; in the top 20 chunks falling from 2.9% to 1.9% when a reranker was added to contextual
;;;; embeddings and BM25.
;;;;
;;;; A SEPARATE HIERARCHY, NOT A CAPABILITY ON `PROVIDER', for the reason embedding.lisp gives:
;;;; Anthropic has no rerank endpoint, so a chat provider must not be something a caller can
;;;; hand where a reranker is needed.
;;;;
;;;; HOW A RERANKER FINDS ITS SETTINGS, following #290's rules for embeddings. For backend X each
;;;; setting resolves, most specific first:
;;;;   1. PRAXEON_<ROLE>_RERANK_<SETTING>, when a role is being resolved;
;;;;   2. PRAXEON_RERANK_<SETTING>;
;;;;   3. X's own variable: PRAXEON_<X>_API_KEY and PRAXEON_<X>_BASE_URL for the key and the
;;;;      endpoint, PRAXEON_<X>_RERANK_MODEL for the model;
;;;;   4. X's built-in default, which exists for the endpoint and the model, never for a key.
;;;; There is no default reranker: with no PRAXEON_<ROLE>_RERANK_IMPL or PRAXEON_RERANK_IMPL,
;;;; `make-reranker-from-env' signals NO-RERANKER.

(in-package #:praxeon/llm)

;;; --- the protocol ----------------------------------------------------------

(defclass reranker () ()
  (:documentation "Anything that can order texts by how well each answers a query. A separate
hierarchy from PROVIDER and EMBEDDING-PROVIDER; see this file's commentary."))

(defgeneric rerank (reranker query documents)
  (:documentation "DOCUMENTS, a list of strings, ordered by how well each answers QUERY, best
first, as a list of (INDEX . SCORE) conses. INDEX is the document's position in DOCUMENTS and
SCORE its relevance, a real number, higher being better. Every document appears exactly once.
A reply that names a document twice, leaves one out or names one that was not sent signals
PRAXEON/CONDITIONS:DELIBERATION-FAILURE."))

(defgeneric reranker-model-of (reranker)
  (:documentation "The model a reranker uses, or NIL when it has none to name.")
  (:method ((r reranker)) nil))

(defun %check-ranking (ranking count)
  "Signal unless RANKING holds each index below COUNT exactly once, each with a real score."
  (let ((seen (make-array count :initial-element nil)))
    (dolist (entry ranking)
      (let ((index (car entry)))
        (unless (and (integerp index) (< -1 index count) (realp (cdr entry))
                     (not (aref seen index)))
          (error 'praxeon/conditions:deliberation-failure
                 :detail (format nil "rerank reply entry ~S is not a new index below ~D with a score"
                                 entry count)))
        (setf (aref seen index) t)))
    (unless (every #'identity seen)
      (error 'praxeon/conditions:deliberation-failure
             :detail (format nil "rerank reply scored ~D of the ~D documents sent"
                             (count t seen) count)))
    ranking))

(defmethod rerank :around ((r reranker) query documents)
  (check-type query string)
  (if (null documents)
      '()
      (let ((start (get-internal-real-time))
            (ranking (%check-ranking (call-next-method) (length documents))))
        ;; Counts only, never the query or the documents, as for a completion.
        (log:debug "rerank" :reranker (string (type-of r)) :model (reranker-model-of r)
                            :documents (length documents) :ms (%ms-since start))
        ranking)))

;;; --- Voyage AI's rerank endpoint -------------------------------------------

(defparameter *voyage-rerank-limits*
  '(("rerank-2.5"      8000 32000 600000)
    ("rerank-2.5-lite" 8000 32000 600000)
    ("rerank-2"        4000 16000 600000)
    ("rerank-2-lite"   4000 16000 600000)
    ("rerank-1"        2000  8000 300000)
    ("rerank-lite-1"   1000  4000 300000))
  "Voyage's limits by model, as read from its rerank API reference on 2026-09-29: the query's
tokens, the query's and one document's tokens together, and the tokens of one request, counted
as the query's tokens times the number of documents plus every document's. Each request also
takes at most 1,000 documents. A model not listed here is given the smallest of these limits.")

(defparameter *voyage-rerank-max-documents* 1000
  "Voyage's limit on documents per rerank request.")

(defclass voyage-reranker (reranker)
  ((model :initarg :model :initform "rerank-2.5" :reader reranker-model)
   (base-url :initarg :base-url :initform *voyage-base-url* :reader reranker-base-url)
   (api-key :initarg :api-key :initform nil :reader reranker-api-key))
  (:documentation "Voyage AI's /rerank endpoint as a reranker.

Every request sends `truncation: false'. Voyage's default shortens a query or a document that is
over the model's limit and scores what is left; with false, such a request is an error instead
of a score for part of a document. Requests are split to stay within the documents and total
tokens a request may carry, estimated with ESTIMATE-TOKENS, which never undercounts."))

(defmethod reranker-model-of ((r voyage-reranker)) (reranker-model r))

(defun %voyage-rerank-total-limit (model)
  (third (rest (or (assoc model *voyage-rerank-limits* :test #'string=)
                   (first (last *voyage-rerank-limits*))))))

(defgeneric rerank-request-body (reranker query documents)
  (:documentation "The JSON body, as a hash-table, of one request scoring DOCUMENTS (a vector of
strings) against QUERY. Separate from the POST so a test can read the body that is built."))

(defgeneric rerank-post (reranker body)
  (:documentation "Send BODY to RERANKER's endpoint and return the parsed reply. The transport,
as a generic function so that a test can answer in its place without a network."))

(defmethod rerank-request-body ((r voyage-reranker) query documents)
  (let ((body (make-hash-table :test #'equal)))
    (setf (gethash "query" body) query
          (gethash "documents" body) documents
          (gethash "model" body) (reranker-model r)
          ;; jzon writes NIL as false.
          (gethash "truncation" body) nil)
    body))

(defmethod rerank-post ((r voyage-reranker) body)
  (let* ((payload (jzon:stringify body))
         (url (concatenate 'string (reranker-base-url r) "/rerank"))
         (headers (append '(("content-type" . "application/json"))
                          (when (reranker-api-key r)
                            (list (cons "authorization"
                                        (format nil "Bearer ~A" (reranker-api-key r))))))))
    (handler-case (jzon:parse (%post-json url headers payload))
      (praxeon/conditions:praxeon-error (e) (error e))
      (error (e)
        (error 'praxeon/conditions:deliberation-failure
               :detail (%http-error-detail (format nil "rerank request to ~A failed" url) e))))))

(defun %rerank-batches (query documents max-documents max-tokens)
  "DOCUMENTS as a list of (START . BATCH), in order, each BATCH within MAX-DOCUMENTS and within
MAX-TOKENS counted as the query's tokens once per document plus the documents' own. A document
that alone exceeds the limit is sent in a batch of its own, so that the service refuses it."
  (let ((q (estimate-tokens query))
        (batches '()) (current '()) (start 0) (count 0) (tokens 0))
    (loop for document in documents
          for i from 0
          for n = (+ q (estimate-tokens document))
          do (when (and current (or (>= count max-documents) (> (+ tokens n) max-tokens)))
               (push (cons start (nreverse current)) batches)
               (setf current '() start i count 0 tokens 0))
             (push document current)
             (incf count)
             (incf tokens n))
    (when current (push (cons start (nreverse current)) batches))
    (nreverse batches)))

(defmethod rerank ((r voyage-reranker) query documents)
  (let ((ranking '()))
    (dolist (batch (%rerank-batches query documents *voyage-rerank-max-documents*
                                    (%voyage-rerank-total-limit (reranker-model r))))
      (let ((data (gethash "data" (rerank-post r (rerank-request-body
                                                  r query (coerce (cdr batch) 'vector))))))
        (unless (vectorp data)
          (error 'praxeon/conditions:deliberation-failure
                 :detail "rerank reply carried no `data' array"))
        (loop for row across data
              for index = (gethash "index" row)
              do (push (cons (if (integerp index) (+ (car batch) index) index)
                             (gethash "relevance_score" row))
                       ranking))))
    ;; Scores from separate requests are comparable: each is the model's relevance of one
    ;; document to the query, not a rank within its request. A malformed entry is left for
    ;; the :AROUND method to refuse, so it is not sorted here.
    (if (every (lambda (e) (realp (cdr e))) ranking)
        (stable-sort (sort ranking #'< :key (lambda (e) (if (integerp (car e)) (car e) -1)))
                     #'> :key #'cdr)
        ranking)))

;;; --- selection -------------------------------------------------------------

(defvar *reranker-impls* '()
  "Alist of lowercased impl name -> a function of no arguments returning a fresh RERANKER.")

(defun register-reranker-impl (name constructor)
  "Register CONSTRUCTOR (a function of no arguments) under NAME. Returns NAME."
  (let ((key (string-downcase name)))
    (setf *reranker-impls*
          (acons key constructor (remove key *reranker-impls* :key #'car :test #'string=))))
  name)

(defun %rerank-env-for (impl setting)
  "The reranker SETTING (\"API_KEY\", \"BASE_URL\" or \"MODEL\") for backend IMPL, most
specific first; see this file's commentary. NIL when none is set."
  (or (and *provider-role*
           (%getenv (format nil "PRAXEON_~:@(~A~)_RERANK_~A" *provider-role* setting)))
      (%getenv (format nil "PRAXEON_RERANK_~A" setting))
      (%getenv (format nil "PRAXEON_~:@(~A~)_~:[~;RERANK_~]~A" impl
                       (string= setting "MODEL") setting))))

(defun make-reranker-from-env (&key role)
  "Construct the reranker for ROLE, or the process-wide one when ROLE is NIL. The backend is
named by PRAXEON_<ROLE>_RERANK_IMPL, then PRAXEON_RERANK_IMPL. There is no default: when neither
is set this signals NO-RERANKER before any request, and an app that can search without one
handles it. A name nothing is registered under signals DELIBERATION-FAILURE. Call it on the
thread that owns the role, as MAKE-EMBEDDING-PROVIDER-FROM-ENV says."
  (let* ((*provider-role* (and role (string role)))
         (impl (or (and *provider-role*
                        (%getenv (format nil "PRAXEON_~:@(~A~)_RERANK_IMPL" *provider-role*)))
                   (%getenv "PRAXEON_RERANK_IMPL")))
         (ctor (and impl
                    (cdr (assoc (string-downcase impl) *reranker-impls* :test #'string=)))))
    (unless impl
      (error 'praxeon/conditions:no-reranker :role *provider-role*))
    (unless ctor
      (error 'praxeon/conditions:deliberation-failure
             :detail (format nil "no reranker impl registered for impl=~A~@[ (role ~A)~]"
                             impl role)))
    (funcall ctor)))

(defun make-voyage-reranker-from-env ()
  "A VOYAGE-RERANKER, each setting found by %RERANK-ENV-FOR. A key is required:
PRAXEON_<ROLE>_RERANK_API_KEY, PRAXEON_RERANK_API_KEY or PRAXEON_VOYAGE_API_KEY."
  (make-instance
   'voyage-reranker
   :model (or (%rerank-env-for "voyage" "MODEL") "rerank-2.5")
   :base-url (or (%rerank-env-for "voyage" "BASE_URL") *voyage-base-url*)
   :api-key (or (%rerank-env-for "voyage" "API_KEY")
                (error 'praxeon/conditions:missing-provider-key
                       :impl "voyage" :role *provider-role*
                       :variables (append
                                   (and *provider-role*
                                        (list (format nil "PRAXEON_~:@(~A~)_RERANK_API_KEY"
                                                      *provider-role*)))
                                   (list "PRAXEON_RERANK_API_KEY" "PRAXEON_VOYAGE_API_KEY"))))))

(register-reranker-impl "voyage" #'make-voyage-reranker-from-env)
