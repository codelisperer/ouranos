;;;; embedding.lisp --- turning text into a vector, as a provider call (#138, #150).
;;;;
;;;; praxeon owns provider calls. #150 states the reason a consuming app must not make this
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
;;;; HOW AN EMBEDDING PROVIDER FINDS ITS SETTINGS (#290). An embedding provider reads
;;;; embedding variables only, never the chat ones (PRAXEON_<ROLE>_<SETTING>,
;;;; PRAXEON_LLM_<SETTING>). For backend X each setting resolves, most specific first:
;;;;   1. PRAXEON_<ROLE>_EMBED_<SETTING>, when a role is being resolved;
;;;;   2. PRAXEON_EMBED_<SETTING>;
;;;;   3. X's own variable: PRAXEON_<X>_API_KEY and PRAXEON_<X>_BASE_URL for the key and the
;;;;      endpoint, PRAXEON_<X>_EMBED_MODEL and PRAXEON_<X>_EMBED_DIMENSIONS for the model
;;;;      and the width (PRAXEON_<X>_MODEL names X's chat model where X also serves chat);
;;;;   4. X's built-in default, which exists for the endpoint, model and width, never for a
;;;;      key.
;;;; There is no default embedding provider: with no PRAXEON_<ROLE>_EMBED_IMPL or
;;;; PRAXEON_EMBED_IMPL, `make-embedding-provider-from-env' signals NO-EMBEDDING-PROVIDER.
;;;;
;;;; THE DIMENSION IS A PROPERTY OF THE DEPLOYMENT, NOT OF THE CODE (#150): "a schema
;;;; hard-coding 1536 has hard-coded OpenAI's text-embedding-3-small". So a provider
;;;; ADVERTISES its width, and a schema declaring a different one is a configuration error
;;;; that can be named at startup. mnemosyne refuses the wrong width again at cast time and
;;;; keeps doing so -- but that error names a column, which is a long way from the variable
;;;; that caused it.
;;;;
;;;; RESOLUTION HAPPENS ON THE CALLING THREAD. `EMBED' TAKES A PROVIDER AND NEVER RESOLVES
;;;; ONE. `make-embedding-provider-from-env' reads `*provider-role*', a special, and #158
;;;; records that nothing currently resolves a provider across a thread boundary -- latent
;;;; rather than live. Memory writes during a fanned-out turn are precisely where that would
;;;; stop being latent: inside a worker the role level falls through to the process-wide
;;;; PRAXEON_EMBED_* level, which is not an error, it is the WRONG MODEL, quietly, for that
;;;; call -- and it surfaces later as a width that does not match the column. Resolve once
;;;; where the role is bound and pass the provider in, and #158 cannot reach this seam at all.

(in-package #:praxeon/llm)

;;; --- the protocol ----------------------------------------------------------
;;;
;;; The class layout (#286):
;;;   EMBEDDING-PROVIDER          the protocol. EMBED, EMBED-BATCH, EMBED-DOCUMENTS,
;;;                               EMBED-QUERY, the width check, and the per-request limits
;;;                               that SPLIT-INTO-BATCHES works within.
;;;   REMOTE-EMBEDDING-PROVIDER   a service reached over HTTP: model, base URL, key and width,
;;;                               the POST with a bearer key, HTTP failures as praxeon
;;;                               conditions, and the `data[].embedding' + `index' reply. A
;;;                               kind that runs a model inside the process subclasses
;;;                               EMBEDDING-PROVIDER directly and does not inherit any of this.
;;;   OPENAI-COMPATIBLE-EMBEDDINGS, VOYAGE-EMBEDDINGS
;;;                               each states its endpoint default, its request body (field
;;;                               names, document/query, truncation), its limits, and its
;;;                               default model and width.

(defclass embedding-provider () ()
  (:documentation "Something that turns text into a vector of numbers.

Deliberately NOT a subclass of PROVIDER, and PROVIDER is deliberately not a subclass of
this. One concrete class may be both if a vendor serves both, but that is a fact about the
vendor rather than about the protocol."))

(defgeneric embed (provider text)
  (:documentation "TEXT as a vector of DOUBLE-FLOATs of length (EMBEDDING-DIMENSIONS PROVIDER).
It does not say whether TEXT is a document or a query; use EMBED-DOCUMENTS or EMBED-QUERY
for retrieval.

PROVIDER is passed, never resolved here -- see the note on #158 at the top of this file."))

(defgeneric embed-batch (provider texts)
  (:documentation "A list of vectors, one per text in TEXTS, in order.

One round trip where the endpoint allows it. Order is part of the contract: callers pair the
results back up with their inputs positionally, and a provider that returned them in
completion order would corrupt every caller silently."))

(defgeneric embed-documents (provider texts)
  (:documentation "A list of vectors, one per text in TEXTS, in order, for texts that will be
stored and searched later (ingest).

A service that embeds documents and queries differently (Voyage's `input_type') is told these
are documents. The texts are sent in as few requests as the provider's limits allow
(EMBEDDING-MAX-TEXTS, EMBEDDING-MAX-TOKENS). Two calls rather than one call with a flag,
following #138's ruling on exact and similarity retrieval (#286)."))

(defgeneric embed-query (provider text)
  (:documentation "The vector for TEXT, a search query, to compare against vectors made by
EMBED-DOCUMENTS. The counterpart of EMBED-DOCUMENTS (#286)."))

(defgeneric embedding-dimensions (provider)
  (:documentation "The width of the vectors PROVIDER produces. A deployment fact (#150)."))

(defgeneric embedding-model-of (provider)
  (:documentation "The model id PROVIDER embeds with, or NIL. The counterpart of MODEL-OF."))

(defgeneric embedding-max-texts (provider)
  (:documentation "The most texts one request to PROVIDER may carry, or NIL for no stated limit."))

(defgeneric embedding-max-tokens (provider)
  (:documentation "The most tokens one request to PROVIDER may carry in total, or NIL for no
stated limit. May depend on the model."))

(defmethod embedding-model-of ((p embedding-provider)) nil)
(defmethod embedding-max-texts ((p embedding-provider)) nil)
(defmethod embedding-max-tokens ((p embedding-provider)) nil)

(defmethod embed-batch ((p embedding-provider) texts)
  "Fallback: one call per text. Correct for any provider, slower than a batching endpoint."
  (mapcar (lambda (text) (embed p text)) texts))

(defmethod embed-documents ((p embedding-provider) texts)
  "Fallback for a kind that does not distinguish documents from queries."
  (embed-batch p texts))

(defmethod embed-query ((p embedding-provider) text)
  "Fallback for a kind that does not distinguish documents from queries."
  (embed p text))

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

(defmethod embed-query :around ((p embedding-provider) text)
  (declare (ignore text))
  (%check-width p (call-next-method)))

(defmethod embed-documents :around ((p embedding-provider) texts)
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

;;; --- a vector as text, for a store with no vector type (#425) ------------------
;;;
;;; SQLite has no vector column, so a store on SQLite keeps an embedding as text and computes
;;; similarity in Lisp. The text is pgvector's own form, [x,y,...], so one format serves both
;;; backends and a stored value can be read by eye. These are pure functions; the stores in
;;; praxeon/memory-db and praxeon/retrieval call them.

(defun vector-text (vector &optional dimensions)
  "VECTOR, a sequence of reals, as the text [x,y,...], each number written as a double. With
DIMENSIONS, signals PRAXEON/CONDITIONS:DELIBERATION-FAILURE unless VECTOR has that many
numbers, as mnemosyne's cast does for a pgvector column."
  (when (and dimensions (/= (length vector) dimensions))
    (error 'praxeon/conditions:deliberation-failure
           :detail (format nil "embedding rejected: ~D numbers where the store holds ~D"
                           (length vector) dimensions)))
  (with-standard-io-syntax
    (let ((*read-default-float-format* 'double-float))
      (format nil "[~{~A~^,~}]" (map 'list (lambda (x) (coerce x 'double-float)) vector)))))

(defun parse-vector-text (text)
  "The numbers of TEXT, written by VECTOR-TEXT, as a simple vector of doubles. Signals
PRAXEON/CONDITIONS:DELIBERATION-FAILURE if TEXT is not that form. Reads with *READ-EVAL* off
and accepts only reals."
  (flet ((bad () (error 'praxeon/conditions:deliberation-failure
                        :detail (format nil "a stored embedding is not a vector: ~S"
                                        (subseq text 0 (min 40 (length text)))))))
    (let ((n (length text)))
      (unless (and (> n 1) (char= (char text 0) #\[) (char= (char text (1- n)) #\]))
        (bad))
      (with-standard-io-syntax
        (let ((*read-default-float-format* 'double-float)
              (*read-eval* nil))
          (coerce (loop for start = 1 then (1+ end)
                        for end = (or (position #\, text :start start) (1- n))
                        collect (let ((x (ignore-errors (read-from-string text t nil
                                                                          :start start :end end))))
                                  (if (realp x) (coerce x 'double-float) (bad)))
                        while (< end (1- n)))
                  'simple-vector))))))

(defun cosine-distance (a b)
  "One minus the cosine of the angle between A and B, the value pgvector's <=> computes. A
vector of all zeros has no direction, and its distance from anything is taken as 1."
  (let ((dot 0d0) (na 0d0) (nb 0d0))
    (map nil (lambda (x y)
               (incf dot (* x y)) (incf na (* x x)) (incf nb (* y y)))
         a b)
    (if (or (zerop na) (zerop nb))
        1d0
        (- 1d0 (/ dot (sqrt (* na nb)))))))

;;; --- batching within a provider's limits -----------------------------------

(defun estimate-tokens (text)
  "An upper bound on the number of tokens TEXT becomes: its length in UTF-8 bytes.

A byte-level tokenizer produces at most one token per byte, so batches sized by this estimate
are smaller than they could be, never larger. If a request still exceeds a service's limit, the
service refuses it with an error, which reaches the caller as a DELIBERATION-FAILURE; no kind
here asks a service to shorten a text."
  (loop for ch across text
        sum (let ((code (char-code ch)))
              (cond ((< code #x80) 1)
                    ((< code #x800) 2)
                    ((< code #x10000) 3)
                    (t 4)))))

(defun split-into-batches (texts max-texts max-tokens)
  "TEXTS as a list of batches, in order, each holding at most MAX-TEXTS texts and at most
MAX-TOKENS tokens by ESTIMATE-TOKENS. NIL for either limit means none.

A text whose estimate alone exceeds MAX-TOKENS gets a batch to itself and is sent anyway, so
that the service refuses that text with an error. It is never dropped or shortened here."
  (let ((batches '()) (current '()) (count 0) (tokens 0))
    (dolist (text texts)
      (let ((n (estimate-tokens text)))
        (when (and current
                   (or (and max-texts (>= count max-texts))
                       (and max-tokens (> (+ tokens n) max-tokens))))
          (push (nreverse current) batches)
          (setf current '() count 0 tokens 0))
        (push text current)
        (incf count)
        (incf tokens n)))
    (when current (push (nreverse current) batches))
    (nreverse batches)))

;;; --- a service reached over HTTP ------------------------------------------

(defclass remote-embedding-provider (embedding-provider)
  ((model :initarg :model :reader %remote-model)
   (base-url :initarg :base-url :reader embedding-base-url)
   (api-key :initarg :api-key :initform nil :reader embedding-api-key)
   (dimensions :initarg :dimensions :reader %remote-dimensions))
  (:documentation "An embedding service reached over HTTP at BASE-URL/embeddings, with API-KEY
sent as a bearer token when set, replying with OpenAI's `data[].embedding' and `index' shape.
A subclass supplies EMBEDDING-REQUEST-BODY and its limits."))

(defmethod embedding-model-of ((p remote-embedding-provider)) (%remote-model p))
(defmethod embedding-dimensions ((p remote-embedding-provider)) (%remote-dimensions p))

(defgeneric embedding-request-body (provider texts input-type)
  (:documentation "The JSON body, as a hash-table, of one request embedding TEXTS (a vector of
strings). INPUT-TYPE is :DOCUMENT, :QUERY or NIL (not said). Separate from the POST so a test
can read the body that is actually built."))

(defgeneric embedding-post (provider body)
  (:documentation "Send BODY to PROVIDER's endpoint and return the parsed reply. The transport,
as a generic function so that a test can answer in its place without a network."))

(defmethod embedding-post ((p remote-embedding-provider) body)
  (let* ((payload (jzon:stringify body))
         (url (concatenate 'string (embedding-base-url p) "/embeddings"))
         (headers (append '(("content-type" . "application/json"))
                          (when (embedding-api-key p)
                            (list (cons "authorization"
                                        (format nil "Bearer ~A" (embedding-api-key p))))))))
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

(defun %remote-embed (p texts input-type)
  "Vectors for TEXTS, in order, sent in as many requests as P's limits require.
Each reply must carry exactly one vector per text sent; a reply with more or fewer would pair
vectors with the wrong texts, so it is refused."
  (loop for batch in (split-into-batches texts (embedding-max-texts p) (embedding-max-tokens p))
        append (let ((vectors (%embedding-vectors
                               (embedding-post p (embedding-request-body
                                                  p (coerce batch 'vector) input-type)))))
                 (unless (= (length vectors) (length batch))
                   (error 'praxeon/conditions:deliberation-failure
                          :detail (format nil "embeddings reply carried ~D vectors for ~D texts"
                                          (length vectors) (length batch))))
                 vectors)))

(defmethod embed ((p remote-embedding-provider) text)
  (first (%remote-embed p (list text) nil)))

(defmethod embed-batch ((p remote-embedding-provider) texts)
  (%remote-embed p texts nil))

(defmethod embed-documents ((p remote-embedding-provider) texts)
  (%remote-embed p texts :document))

(defmethod embed-query ((p remote-embedding-provider) text)
  (first (%remote-embed p (list text) :query)))

;;; --- OpenAI-compatible embeddings -----------------------------------------

(defclass openai-compatible-embeddings (remote-embedding-provider)
  ((model :initform (or (%getenv "PRAXEON_EMBED_MODEL") "text-embedding-3-small")
          :reader oai-embed-model)
   (base-url :initform (or (%getenv "PRAXEON_EMBED_BASE_URL") "http://localhost:11434/v1")
             :reader oai-embed-base-url)
   (api-key :initform (%getenv "PRAXEON_EMBED_API_KEY")
            :reader oai-embed-api-key)
   (dimensions :initform 1536
               :reader oai-embed-dimensions))
  (:documentation "Any OpenAI-compatible /embeddings endpoint as an embedding provider.
It does not distinguish documents from queries, so EMBED-DOCUMENTS and EMBED-QUERY send the
same request as EMBED-BATCH and EMBED.

DIMENSIONS IS REQUIRED IN PRACTICE AND DEFAULTED ONLY FOR THE COMMON CASE. The endpoint does
not announce its width before you call it, so this is a declaration about the deployment,
checked against the first reply rather than trusted."))

(defmethod embedding-max-texts ((p openai-compatible-embeddings))
  "OpenAI's limit on inputs per request."
  2048)

(defmethod embedding-max-tokens ((p openai-compatible-embeddings))
  "OpenAI's limit on tokens summed over one request's inputs."
  300000)

(defmethod embedding-request-body ((p openai-compatible-embeddings) texts input-type)
  (declare (ignore input-type))
  (let ((body (make-hash-table :test #'equal)))
    (setf (gethash "model" body) (oai-embed-model p)
          (gethash "input" body) texts)
    ;; text-embedding-3-* accept a narrower width; older models and most local servers
    ;; ignore it. Sent because when it IS honoured it makes the reply match the declaration
    ;; rather than merely be checked against it.
    (setf (gethash "dimensions" body) (oai-embed-dimensions p))
    body))

;;; --- Voyage AI embeddings (#286) -------------------------------------------

(defparameter *voyage-base-url* "https://api.voyageai.com/v1"
  "Voyage's API base URL. The class appends /embeddings to it.")

(defparameter *voyage-default-dimensions* 1024
  "The width the voyage-4 models return when no output_dimension is sent. pgvector indexes at
most 2,000 dimensions of `vector', so Voyage's 2,048 option cannot be indexed.")

(defparameter *voyage-max-tokens*
  '(("voyage-4-large" . 120000) ("voyage-4" . 320000) ("voyage-4-lite" . 1000000))
  "Voyage's limit on tokens per request, by model. A model not listed here is given the
smallest of these, which can only make its batches smaller than necessary.")

(defclass voyage-embeddings (remote-embedding-provider)
  ((model :initform "voyage-4")
   (base-url :initform *voyage-base-url*)
   (dimensions :initform *voyage-default-dimensions*))
  (:documentation "Voyage AI's /embeddings endpoint as an embedding provider.

Every request sends `truncation: false'. Voyage's default is to embed only the start of a text
that is too long; with false, such a text is an error instead of a vector for part of it.
EMBED-DOCUMENTS sends `input_type: \"document\"' and EMBED-QUERY `\"query\"', as Voyage's
documentation asks for retrieval. `output_dimension' is sent only when DIMENSIONS is not the
model's default width."))

(defmethod embedding-max-texts ((p voyage-embeddings))
  "Voyage's limit on texts per request."
  1000)

(defmethod embedding-max-tokens ((p voyage-embeddings))
  (or (cdr (assoc (embedding-model-of p) *voyage-max-tokens* :test #'string=))
      (reduce #'min *voyage-max-tokens* :key #'cdr)))

(defmethod embedding-request-body ((p voyage-embeddings) texts input-type)
  (let ((body (make-hash-table :test #'equal)))
    (setf (gethash "model" body) (embedding-model-of p)
          (gethash "input" body) texts
          ;; jzon writes NIL as false.
          (gethash "truncation" body) nil)
    (when input-type
      (setf (gethash "input_type" body) (ecase input-type
                                          (:document "document")
                                          (:query "query"))))
    (unless (eql (embedding-dimensions p) *voyage-default-dimensions*)
      (setf (gethash "output_dimension" body) (embedding-dimensions p)))
    body))

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

(defun %embed-env-for (impl setting)
  "The embedding SETTING (\"API_KEY\", \"BASE_URL\", \"MODEL\" or \"DIMENSIONS\") for
backend IMPL, most specific first: PRAXEON_<ROLE>_EMBED_<SETTING>, PRAXEON_EMBED_<SETTING>,
then IMPL's own variable. NIL when none is set; the caller supplies IMPL's default.

IMPL's own variable for the model and the width carries EMBED_ (PRAXEON_OPENAI_EMBED_MODEL),
because PRAXEON_<IMPL>_MODEL is the chat model of a backend that serves both. The key and the
endpoint are the backend's own (PRAXEON_VOYAGE_API_KEY). No chat variable is read (#290)."
  (or (and *provider-role*
           (%getenv (format nil "PRAXEON_~:@(~A~)_EMBED_~A" *provider-role* setting)))
      (%getenv (format nil "PRAXEON_EMBED_~A" setting))
      (%getenv (format nil "PRAXEON_~:@(~A~)_~:[~;EMBED_~]~A" impl
                       (member setting '("MODEL" "DIMENSIONS") :test #'string=)
                       setting))))

(defun %embed-required-key (impl)
  "The embedding API key for IMPL, or MISSING-PROVIDER-KEY listing the variables that would
supply one. For a hosted backend, where a request without a key cannot succeed."
  (or (%embed-env-for impl "API_KEY")
      (error 'praxeon/conditions:missing-provider-key
             :impl impl :role *provider-role*
             :variables (append
                         (and *provider-role*
                              (list (format nil "PRAXEON_~:@(~A~)_EMBED_API_KEY"
                                            *provider-role*)))
                         (list "PRAXEON_EMBED_API_KEY"
                               (format nil "PRAXEON_~:@(~A~)_API_KEY" impl))))))

(defun make-embedding-provider-from-env (&key role)
  "Construct the embedding provider for ROLE, or the process-wide one when ROLE is NIL.

The backend is named by PRAXEON_<ROLE>_EMBED_IMPL, then PRAXEON_EMBED_IMPL. There is no
default: when neither is set this signals NO-EMBEDDING-PROVIDER before any request, and an app
that can do without embeddings handles it (#290). A name nothing is registered under signals
DELIBERATION-FAILURE.

CALL THIS ON THE THREAD THAT OWNS THE ROLE. It reads `*provider-role*', and #158 records
that a resolution inside a worker thread falls through to the shared level without erroring
-- the wrong model, quietly. Resolve here and pass the provider to EMBED."
  (let* ((*provider-role* (and role (string role)))
         (impl (or (and *provider-role*
                        (%getenv (format nil "PRAXEON_~:@(~A~)_EMBED_IMPL" *provider-role*)))
                   (%getenv "PRAXEON_EMBED_IMPL")))
         (ctor (and impl
                    (cdr (assoc (string-downcase impl) *embedding-impls* :test #'string=)))))
    (unless impl
      (error 'praxeon/conditions:no-embedding-provider :role *provider-role*))
    (unless ctor
      (error 'praxeon/conditions:deliberation-failure
             :detail (format nil "no embedding impl registered for impl=~A~@[ (role ~A)~]"
                             impl role)))
    (funcall ctor)))

(defun make-openai-embeddings-from-env (impl &optional default-base-url key-required)
  "An OPENAI-COMPATIBLE-EMBEDDINGS provider for IMPL, each setting found by %EMBED-ENV-FOR.
KEY-REQUIRED is true for a hosted service, where a missing key is reported here rather than
by the first request."
  (let ((declared (%embed-env-for impl "DIMENSIONS")))
    (make-instance 'openai-compatible-embeddings
                   :model (or (%embed-env-for impl "MODEL") "text-embedding-3-small")
                   :base-url (or (%embed-env-for impl "BASE_URL")
                                 default-base-url
                                 "http://localhost:11434/v1")
                   :api-key (if key-required
                                (%embed-required-key impl)
                                (%embed-env-for impl "API_KEY"))
                   :dimensions (if declared (parse-integer declared) 1536))))

(defun make-voyage-embeddings-from-env ()
  "A VOYAGE-EMBEDDINGS provider, each setting found by %EMBED-ENV-FOR. A key is required:
PRAXEON_<ROLE>_EMBED_API_KEY, PRAXEON_EMBED_API_KEY or PRAXEON_VOYAGE_API_KEY."
  (let ((declared (%embed-env-for "voyage" "DIMENSIONS")))
    (make-instance 'voyage-embeddings
                   :model (or (%embed-env-for "voyage" "MODEL") "voyage-4")
                   :base-url (or (%embed-env-for "voyage" "BASE_URL") *voyage-base-url*)
                   :api-key (%embed-required-key "voyage")
                   :dimensions (if declared
                                   (parse-integer declared)
                                   *voyage-default-dimensions*))))

(register-embedding-impl "openai" (lambda () (make-openai-embeddings-from-env "openai")))
(register-embedding-impl "ollama"
                         (lambda () (make-openai-embeddings-from-env
                                     "ollama" "http://localhost:11434/v1")))
(register-embedding-impl "openrouter"
                         (lambda () (make-openai-embeddings-from-env
                                     "openrouter" "https://openrouter.ai/api/v1" t)))
(register-embedding-impl "voyage" #'make-voyage-embeddings-from-env)
