;;;; embedding.lisp --- turning text into a vector, as a provider call (#372, #415).
;;;;
;;;; praxeon owns provider calls. #415 states the reason a consuming app must not make this
;;;; one itself: "no consuming app should be making one directly, and every app that does
;;;; will make it differently."
;;;;
;;;; A SEPARATE HIERARCHY, NOT A CAPABILITY ON `PROVIDER', and the reason is the one
;;;; ADR-0001 records in mnemosyne. `embed' cannot be a generic every PROVIDER answers,
;;;; because ANTHROPIC HAS NO EMBEDDINGS ENDPOINT -- no model to name and no path to call;
;;;; Anthropic's own documentation points at third parties. A generic on PROVIDER would be
;;;; TOTAL IN ITS SIGNATURE AND PARTIAL IN FACT, so "this provider cannot do this" would not
;;;; be something the protocol declines to express -- it would be something it CANNOT
;;;; express, available only as a runtime signal from a method that had to exist.
;;;;
;;;; That is exactly the shape ADR-0001 was written about, one framework over, and the
;;;; answer is the same: make the absence structural. An `anthropic' is not an
;;;; EMBEDDING-PROVIDER, so the call site that needs one cannot be handed it.
;;;;
;;;; WHY NOT A PREDICATE LIKE `SUPPORTS-TOOL-CHOICE-P'. That guards an OPTION on an
;;;; operation the provider performs. This would guard WHETHER THE OPERATION EXISTS AT ALL.
;;;; A predicate makes those look like one question, and a caller who forgets to ask gets a
;;;; runtime signal where they should have had a type nobody offered them.
;;;;
;;;; THE COST THAT LOOKED LIKE AN ARGUMENT AGAINST THIS, MEASURED: none. `%env-for' already
;;;; resolves PRAXEON_<ROLE>_<SUFFIX> > PRAXEON_<IMPL>_<SUFFIX> > PRAXEON_LLM_<SUFFIX>, so
;;;; an embedding impl inherits BASE_URL and API_KEY from the shared level. The marginal
;;;; configuration is one variable, the model -- and that is not duplication, because
;;;; `text-embedding-3-small' and a chat model are necessarily different values.
;;;;
;;;; THE DIMENSION IS A PROPERTY OF THE DEPLOYMENT, NOT OF THE CODE (#415): "a schema
;;;; hard-coding 1536 has hard-coded OpenAI's text-embedding-3-small". So a provider
;;;; ADVERTISES its width, and a schema declaring a different one is a configuration error
;;;; that can be named at startup. mnemosyne refuses the wrong width again at cast time and
;;;; keeps doing so -- but that error names a column, which is a long way from the variable
;;;; that caused it.
;;;;
;;;; RESOLUTION HAPPENS ON THE CALLING THREAD. `EMBED' TAKES A PROVIDER AND NEVER RESOLVES
;;;; ONE. `make-embedding-provider-from-env' reads `*provider-role*', a special, and #430
;;;; records that nothing currently resolves a provider across a thread boundary -- latent
;;;; rather than live. Memory writes during a fanned-out turn are precisely where that would
;;;; stop being latent: inside a worker the role level falls through to impl and then to
;;;; shared, which is not an error, it is the WRONG MODEL, quietly, for that call -- and it
;;;; surfaces later as a width that does not match the column. Resolve once where the role
;;;; is bound and pass the provider in, and #430 cannot reach this seam at all.

(in-package #:praxeon/llm)

;;; --- the protocol ----------------------------------------------------------

(defclass embedding-provider () ()
  (:documentation "Something that turns text into a vector of numbers.

Deliberately NOT a subclass of PROVIDER, and PROVIDER is deliberately not a subclass of
this. One concrete class may be both if a vendor serves both, but that is a fact about the
vendor rather than about the protocol."))

(defgeneric embed (provider text)
  (:documentation "TEXT as a vector of DOUBLE-FLOATs of length (EMBEDDING-DIMENSIONS PROVIDER).

PROVIDER is passed, never resolved here -- see the note on #430 at the top of this file."))

(defgeneric embed-batch (provider texts)
  (:documentation "A list of vectors, one per text in TEXTS, in order.

One round trip where the endpoint allows it. Order is part of the contract: callers pair the
results back up with their inputs positionally, and a provider that returned them in
completion order would corrupt every caller silently."))

(defgeneric embedding-dimensions (provider)
  (:documentation "The width of the vectors PROVIDER produces. A deployment fact (#415)."))

(defgeneric embedding-model-of (provider)
  (:documentation "The model id PROVIDER embeds with, or NIL. The counterpart of MODEL-OF."))

(defmethod embedding-model-of ((p embedding-provider)) nil)

(defmethod embed-batch ((p embedding-provider) texts)
  "Fallback: one call per text. Correct for any provider, slower than a batching endpoint."
  (mapcar (lambda (text) (embed p text)) texts))

;;; --- the width guard -------------------------------------------------------

(defun %check-width (provider vector &optional source)
  "Signal unless VECTOR is as wide as PROVIDER advertises. Returns VECTOR.

THE PROVIDER IS A CLAIM AND THE VECTOR IS THE MEASUREMENT. A declared width is something
somebody configured; the length that came back is the only thing that was observed, and when
they disagree it is the configuration that is wrong rather than the row."
  (let ((expected (embedding-dimensions provider))
        (actual (length vector)))
    (unless (eql expected actual)
      (error 'praxeon/conditions:embedding-dimension-mismatch
             :provider (or (embedding-model-of provider) (type-of provider))
             :expected expected :actual actual
             :source (or source "the provider's reply")))
    vector))

(defmethod embed :around ((p embedding-provider) text)
  (declare (ignore text))
  (%check-width p (call-next-method)))

(defmethod embed-batch :around ((p embedding-provider) texts)
  (declare (ignore texts))
  (let ((vectors (call-next-method)))
    (dolist (v vectors vectors) (%check-width p v))))

(defun check-embedding-dimensions (provider declared &key source)
  "Signal unless PROVIDER produces vectors DECLARED wide. Returns DECLARED.

FOR STARTUP, which is the whole point. A schema declaring `:dimensions 1536' against a
provider configured for a 768-wide model is a configuration error, and this is where it can
still be said in those words. Left to the database it arrives as a cast refusal naming a
column, which is true and unhelpful."
  (let ((actual (embedding-dimensions provider)))
    (unless (eql declared actual)
      (error 'praxeon/conditions:embedding-dimension-mismatch
             :provider (or (embedding-model-of provider) (type-of provider))
             :expected declared :actual actual
             :source (or source "the declared schema"))))
  declared)

;;; --- OpenAI-compatible embeddings -----------------------------------------

(defclass openai-compatible-embeddings (embedding-provider)
  ((model :initarg :model
          :initform (or (uiop:getenv "PRAXEON_EMBED_MODEL") "text-embedding-3-small")
          :reader oai-embed-model)
   (base-url :initarg :base-url
             :initform (or (uiop:getenv "PRAXEON_EMBED_BASE_URL")
                           (uiop:getenv "PRAXEON_LLM_BASE_URL")
                           "http://localhost:11434/v1")
             :reader oai-embed-base-url)
   (api-key :initarg :api-key
            :initform (or (uiop:getenv "PRAXEON_EMBED_API_KEY")
                          (uiop:getenv "PRAXEON_LLM_API_KEY"))
            :reader oai-embed-api-key)
   (dimensions :initarg :dimensions
               :initform 1536
               :reader oai-embed-dimensions))
  (:documentation "Any OpenAI-compatible /embeddings endpoint as an embedding provider.

DIMENSIONS IS REQUIRED IN PRACTICE AND DEFAULTED ONLY FOR THE COMMON CASE. The endpoint does
not announce its width before you call it, so this is a declaration about the deployment,
checked against the first reply rather than trusted."))

(defmethod embedding-dimensions ((p openai-compatible-embeddings)) (oai-embed-dimensions p))
(defmethod embedding-model-of ((p openai-compatible-embeddings)) (oai-embed-model p))

(defun %embeddings-request-body (p input)
  "The request body, as a hash-table. INPUT is a string or a sequence of strings."
  (let ((body (make-hash-table :test #'equal)))
    (setf (gethash "model" body) (oai-embed-model p)
          (gethash "input" body) input)
    ;; text-embedding-3-* accept a narrower width; older models and most local servers
    ;; ignore it. Sent because when it IS honoured it makes the reply match the declaration
    ;; rather than merely be checked against it.
    (setf (gethash "dimensions" body) (oai-embed-dimensions p))
    body))

(defun %embeddings-post (p input)
  "POST INPUT to PROVIDER's /embeddings and return the parsed reply."
  (let* ((payload (jzon:stringify (%embeddings-request-body p input)))
         (url (concatenate 'string (oai-embed-base-url p) "/embeddings"))
         (headers (append '(("content-type" . "application/json"))
                          (when (oai-embed-api-key p)
                            (list (cons "authorization"
                                        (format nil "Bearer ~A" (oai-embed-api-key p))))))))
    (handler-case (jzon:parse (%post-json url headers payload))
      (praxeon/conditions:praxeon-error (e) (error e))
      (error (e)
        (error 'praxeon/conditions:deliberation-failure
               :detail (%http-error-detail
                        (format nil "embeddings request to ~A failed" url) e))))))

(defun %embedding-vectors (parsed)
  "The embeddings from a parsed reply, in the order the API reported, as a list of vectors.

SORTED BY `index', NOT TAKEN IN ARRAY ORDER. The field exists because the server does not
promise the array matches the input order, and a batch that came back permuted would attach
every embedding to the wrong text -- silently, and in a store that is then queried by
similarity, which is the one place a wrong answer looks like a plausible one."
  (let* ((data (gethash "data" parsed))
         (rows '()))
    (unless (and data (plusp (length data)))
      (error 'praxeon/conditions:deliberation-failure
             :detail "embeddings reply carried no `data' array"))
    (map nil (lambda (row) (push row rows)) data)
    (mapcar (lambda (row)
              (map '(simple-array double-float (*))
                   (lambda (n) (coerce n 'double-float))
                   (gethash "embedding" row)))
            (sort (nreverse rows) #'<
                  :key (lambda (row) (or (gethash "index" row) 0))))))

(defmethod embed ((p openai-compatible-embeddings) text)
  (first (%embedding-vectors (%embeddings-post p text))))

(defmethod embed-batch ((p openai-compatible-embeddings) texts)
  (when texts
    (%embedding-vectors (%embeddings-post p (coerce texts 'vector)))))

;;; --- selection, mirroring the completion side ------------------------------

(defvar *embedding-impls* '()
  "Alist of lowercased impl name -> a thunk returning a fresh EMBEDDING-PROVIDER.

Its own registry rather than an entry in *PROVIDER-IMPLS*: the two answer different
questions, and a single registry would let PRAXEON_LLM_IMPL select something that cannot
complete, or PRAXEON_EMBED_IMPL something that cannot embed.")

(defun register-embedding-impl (name constructor)
  "Register CONSTRUCTOR (a function of no arguments) under NAME. Returns NAME."
  (let ((key (string-downcase name)))
    (setf *embedding-impls*
          (acons key constructor
                 (remove key *embedding-impls* :key #'car :test #'string=))))
  name)

(defun make-embedding-provider-from-env (&key role)
  "Construct the embedding provider for ROLE, or the default when ROLE is NIL.

CALL THIS ON THE THREAD THAT OWNS THE ROLE. It reads `*provider-role*', and #430 records
that a resolution inside a worker thread falls through to the shared level without erroring
-- the wrong model, quietly. Resolve here and pass the provider to EMBED."
  (let* ((*provider-role* (and role (string role)))
         (impl (or (and *provider-role*
                        (uiop:getenv (format nil "PRAXEON_~:@(~A~)_EMBED_IMPL" *provider-role*)))
                   (uiop:getenv "PRAXEON_EMBED_IMPL")
                   "openai"))
         (ctor (cdr (assoc (string-downcase impl) *embedding-impls* :test #'string=))))
    (unless ctor
      (error 'praxeon/conditions:deliberation-failure
             :detail (format nil "no embedding impl registered for impl=~A~@[ (role ~A)~]"
                             impl role)))
    (funcall ctor)))

(defun make-openai-embeddings-from-env (impl &optional default-base-url)
  "An OPENAI-COMPATIBLE-EMBEDDINGS provider for IMPL, through the shared resolution chain.

`%env-for' is what makes the separate hierarchy free: BASE_URL and API_KEY fall through to
PRAXEON_LLM_* and are inherited from whatever the completion side already has. Only MODEL
and DIMENSIONS are genuinely this provider's own, and both have to be stated anyway."
  (let ((declared (%env-for impl "EMBED_DIMENSIONS")))
    (make-instance 'openai-compatible-embeddings
                   :model (or (%env-for impl "EMBED_MODEL") "text-embedding-3-small")
                   :base-url (or (%env-for impl "BASE_URL")
                                 default-base-url
                                 "http://localhost:11434/v1")
                   :api-key (%env-for impl "API_KEY")
                   :dimensions (if declared (parse-integer declared) 1536))))

(register-embedding-impl "openai" (lambda () (make-openai-embeddings-from-env "openai")))
(register-embedding-impl "ollama"
                         (lambda () (make-openai-embeddings-from-env
                                     "ollama" "http://localhost:11434/v1")))
(register-embedding-impl "openrouter"
                         (lambda () (make-openai-embeddings-from-env
                                     "openrouter" "https://openrouter.ai/api/v1")))
