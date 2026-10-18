;;;; image.lisp --- image generation behind a neutral protocol, and a generate-image means (#758).
;;;;
;;;; An app gives an agent the means "generate-image". The model calls it with a prompt and,
;;;; optionally, a shape and a quality. The means asks an IMAGE-PROVIDER for the image, hands
;;;; the result to a function the app supplies, and tells the model what was made in a few
;;;; words. The model never sees the image bytes: a means returns a string to the model, and
;;;; the bytes belong to the app, which stores and serves them (praxeon persists nothing).
;;;;
;;;; THE BYTES ARE PASSED THROUGH AS THE PROVIDER SENT THEM. They are decoded from base64 and
;;;; never re-encoded, so provenance metadata a provider embeds in the file, such as C2PA,
;;;; reaches the app unchanged.
;;;;
;;;; A CONTENT-POLICY REFUSAL IS A TYPED RESULT. IMAGE-REFUSED is a TOOL-ERROR-RESULT, so inside a
;;;; turn the model is told the request was refused and can explain that, and the turn goes on.
;;;; A caller of GENERATE-IMAGE outside a turn handles IMAGE-REFUSED like any condition. Any other
;;;; failed request is PROVIDER-REQUEST-FAILED, as for the chat providers (#719).
;;;;
;;;; USAGE. Each request emits one :IMAGE-USAGE event through praxeon/event, with the provider,
;;;; the model, the number of images, the size and quality the provider reports, the token counts
;;;; it reports, and :COST only when the provider reports a cost. OpenAI reports none, so :COST is
;;;; absent rather than 0.
;;;;
;;;; LOGGING follows docs/logging.md: kinds, counts, lengths, status and durations. The prompt,
;;;; the revised prompt and the image bytes are never logged.
;;;;
;;;; This first version generates from a prompt. An edit or variation from a reference image
;;;; (OpenAI's /images/edits, a multipart request) is the follow-up to #758.

(cl:defpackage #:praxeon/image
  (:use #:cl)
  (:local-nicknames (#:actor #:praxeon/actor)
                    (#:cnd #:praxeon/conditions)
                    (#:evt #:praxeon/event)
                    (#:llm #:praxeon/llm)
                    (#:http #:aion/http-client)
                    (#:jzon #:com.inuoe.jzon)
                    (#:b64 #:cl-base64)
                    (#:log #:aion/log))
  (:export
   ;; the protocol
   #:image-provider #:image-provider-name #:image-model-of #:generate-images
   #:image-request #:make-image-request #:image-request-prompt #:image-request-size
   #:image-request-quality #:image-request-count
   #:image-result #:image-result-octets #:image-result-media-type
   #:image-result-revised-prompt #:image-result-provider #:image-result-model
   #:image-result-size #:image-result-quality #:image-result-cost
   #:generate-image
   ;; a refusal
   #:image-refused #:image-refused-provider #:image-refused-code #:image-refused-stage
   #:image-refused-categories
   ;; OpenAI
   #:openai-images #:make-openai-images #:openai-images-from-env #:image-post
   #:openai-image-request-body #:*openai-image-model* #:*openai-images-base-url*
   ;; the means
   #:register #:register-openai-image #:*description*))

(cl:in-package #:praxeon/image)

;;; --- the protocol -------------------------------------------------------------------------

(defclass image-provider () ()
  (:documentation "A service that turns a prompt into images. A backend subclasses this and
supplies a method for GENERATE-IMAGES, IMAGE-PROVIDER-NAME and IMAGE-MODEL-OF."))

(defgeneric image-provider-name (provider)
  (:documentation "The provider's name, a lowercase string such as \"openai\", for events and
logs."))

(defgeneric image-model-of (provider)
  (:documentation "The model PROVIDER sends requests to, as a string."))

(defgeneric generate-images (provider request)
  (:documentation "Ask PROVIDER for the images REQUEST describes. Returns two values: a list of
IMAGE-RESULTs, and a plist of what the provider reported about the request, with the keys
:SIZE, :QUALITY, :INPUT-TOKENS, :OUTPUT-TOKENS and :COST, each present only when reported.
Signals IMAGE-REFUSED for a content-policy refusal and PROVIDER-REQUEST-FAILED for any other
failed request. Call GENERATE-IMAGE rather than this: it emits the usage event and logs."))

(defstruct (image-request (:constructor make-image-request
                              (&key prompt (size :auto) (quality :auto) (count 1))))
  "What to generate. PROMPT is a string. SIZE is :SQUARE, :PORTRAIT, :LANDSCAPE, :AUTO or a
\"WIDTHxHEIGHT\" string the provider accepts. QUALITY is :LOW, :MEDIUM, :HIGH or :AUTO, or a
string the provider accepts. COUNT is the number of images."
  prompt size quality count)

(defstruct (image-result (:constructor %make-image-result))
  "One generated image. OCTETS are the file's bytes as the provider sent them, and MEDIA-TYPE
their type, such as \"image/png\". REVISED-PROMPT is the prompt the provider says it used, or
NIL. SIZE and QUALITY are as the provider reported them, or NIL. COST is the cost the provider
reported, or NIL when it reported none."
  octets media-type revised-prompt provider model size quality cost)

(define-condition image-refused (cnd:tool-error-result)
  ((provider :initarg :provider :initform nil :reader image-refused-provider)
   (code :initarg :code :initform nil :reader image-refused-code)
   (stage :initarg :stage :initform nil :reader image-refused-stage)
   (categories :initarg :categories :initform '() :reader image-refused-categories))
  (:report (lambda (c stream)
             (format stream "The ~A image provider refused the request under its content policy~@[ (code ~A)~]~@[ at the ~A stage~]~@[, categories: ~{~A~^, ~}~]."
                     (image-refused-provider c) (image-refused-code c) (image-refused-stage c)
                     (image-refused-categories c))))
  (:documentation "The provider refused to generate the image under its content policy (#758).

CODE is the provider's error code, such as \"moderation_blocked\". STAGE is where the provider
says it refused, such as \"input\" or \"output\", or NIL. CATEGORIES are the coarse labels it
gave, such as \"violence\", as strings. None of them holds the prompt.

It is a TOOL-ERROR-RESULT, so when the generate-image means signals it inside a turn the model
is told, in TEXT, that the request was refused and why, and the turn goes on. A caller of
GENERATE-IMAGE outside a turn handles it as any condition."))

(defun %refusal-text (provider code stage categories)
  (format nil "The ~A image provider refused to create this image under its content policy~@[ (code ~A)~]~@[ at the ~A stage~]~@[; categories: ~{~A~^, ~}~]. No image was made. Tell the user it was refused, and do not retry the same request."
          provider code stage categories))

(defun %size-name (size)
  "SIZE as text for an event or a log: a keyword downcased, a string as is."
  (if (keywordp size) (string-downcase (symbol-name size)) size))

(defun generate-image (provider prompt &key (size :auto) (quality :auto) (count 1))
  "Generate COUNT images from PROMPT with PROVIDER. Returns a list of IMAGE-RESULTs.

SIZE is :SQUARE, :PORTRAIT, :LANDSCAPE, :AUTO or a \"WIDTHxHEIGHT\" string; QUALITY is :LOW,
:MEDIUM, :HIGH or :AUTO, or a string the provider accepts. Emits one :IMAGE-USAGE event for a
request that succeeded. Signals IMAGE-REFUSED for a content-policy refusal and
PROVIDER-REQUEST-FAILED for any other failure."
  (check-type prompt string)
  (check-type count (integer 1))
  (let ((request (make-image-request :prompt prompt :size size :quality quality :count count))
        (name (image-provider-name provider))
        (model (image-model-of provider))
        (start (get-internal-real-time)))
    (flet ((ms () (round (* 1000 (- (get-internal-real-time) start))
                         internal-time-units-per-second)))
      (log:debug "image request" :provider name :model model :count count
                                 :size (%size-name size) :quality (%size-name quality)
                                 :prompt-length (length prompt))
      (multiple-value-bind (results reported)
          (handler-bind
              ((image-refused
                 (lambda (c)
                   (log:warn "image request refused" :provider name :model model
                                                     :code (image-refused-code c)
                                                     :stage (image-refused-stage c) :ms (ms))))
               (cnd:provider-request-failed
                 (lambda (c)
                   (log:warn "image request failed" :provider name :model model
                                                    :status (cnd:provider-request-failed-status c)
                                                    :error-type (cnd:provider-request-failed-error-type c)
                                                    :error-code (cnd:provider-request-failed-error-code c)
                                                    :ms (ms)))))
            (generate-images provider request))
        (log:debug "image response" :provider name :model model :count (length results)
                                   :bytes (reduce #'+ results
                                                  :key (lambda (r) (length (image-result-octets r))))
                                   :media-type (and results (image-result-media-type (first results)))
                                   :ms (ms))
        (apply #'evt:emit :image-usage
               :provider name :model model :count (length results)
               (append (list :size (or (getf reported :size) (%size-name size))
                             :quality (or (getf reported :quality) (%size-name quality)))
                       (loop for key in '(:input-tokens :output-tokens :cost)
                             for value = (getf reported key)
                             when value append (list key value))))
        results))))

;;; --- OpenAI -------------------------------------------------------------------------------

(defparameter *openai-image-model* "gpt-image-2.5-flare"
  "The OpenAI image model used when none is given. GPT Image 2.5 Flare, the variant OpenAI's
image-generation guide recommends for everyday generation, confirmed by the maintainer as praxeon's
default (2026-10-18). An app can pass any other model id as :MODEL, or set PRAXEON_IMAGE_MODEL: for
example gpt-image-1-mini, at about a quarter of the per-token price, until OpenAI shuts it down
on 2026-12-01. gpt-image-1 shuts down on 2026-10-23, and gpt-image-1.5 and chatgpt-image-latest
on 2026-12-01; OpenAI lists the 2.5 models as their replacements. upstream.sexp pins this value.")

(defparameter *openai-images-base-url* "https://api.openai.com/v1"
  "OpenAI's API base URL. The provider appends /images/generations to it.")

(defparameter *openai-sizes*
  '((:square . "1024x1024") (:portrait . "1024x1536") (:landscape . "1536x1024") (:auto . "auto"))
  "The size OpenAI is sent for each shape keyword. A string size is sent as given.")

(defparameter *refusal-codes* '("moderation_blocked" "content_policy_violation")
  "The error codes with which OpenAI's image API refuses a request under its content policy.
gpt-image models send moderation_blocked; content_policy_violation is DALL-E's.")

(defclass openai-images (image-provider)
  ((api-key :initarg :api-key :reader openai-images-api-key)
   (model :initarg :model :initform *openai-image-model* :reader image-model-of)
   (base-url :initarg :base-url :initform *openai-images-base-url* :reader openai-images-base-url)
   (read-timeout :initarg :read-timeout :initform 300 :reader openai-images-read-timeout))
  (:documentation "OpenAI's Image API, POST BASE-URL/images/generations, as an image provider.
API-KEY is sent as a bearer token. READ-TIMEOUT is in seconds: a high-quality image can take
over a minute."))

(defmethod image-provider-name ((p openai-images)) "openai")

(defun %getenv (name)
  (let ((v (uiop:getenv name)))
    (and v (plusp (length v)) v)))

(defun %env-key ()
  "The OpenAI image key from the environment: PRAXEON_IMAGE_API_KEY, then PRAXEON_OPENAI_API_KEY.
NIL when neither is set."
  (or (%getenv "PRAXEON_IMAGE_API_KEY") (%getenv "PRAXEON_OPENAI_API_KEY")))

(defun make-openai-images (&key (api-key nil api-key-p) model base-url)
  "An OPENAI-IMAGES provider. An API-KEY that is given is used, NIL included; the environment
is read only when none is given (PRAXEON_IMAGE_API_KEY, then PRAXEON_OPENAI_API_KEY). MODEL
defaults to PRAXEON_IMAGE_MODEL, then *OPENAI-IMAGE-MODEL*; BASE-URL to PRAXEON_IMAGE_BASE_URL,
then *OPENAI-IMAGES-BASE-URL*. Signals MISSING-PROVIDER-KEY when there is no key, because every
request would fail."
  (let ((key (if api-key-p api-key (%env-key))))
    (unless key
      (error 'cnd:missing-provider-key
             :impl "openai images"
             :variables (if api-key-p
                            '(":API-KEY")
                            '("PRAXEON_IMAGE_API_KEY" "PRAXEON_OPENAI_API_KEY"))))
    (make-instance 'openai-images
                   :api-key key
                   :model (or model (%getenv "PRAXEON_IMAGE_MODEL") *openai-image-model*)
                   :base-url (or base-url (%getenv "PRAXEON_IMAGE_BASE_URL")
                                 *openai-images-base-url*))))

(defun openai-images-from-env (&key (api-key nil api-key-p) model base-url)
  "An OPENAI-IMAGES provider as MAKE-OPENAI-IMAGES builds it, or NIL when there is no key, so a
caller can leave the means unregistered rather than register one that cannot work."
  (let ((key (if api-key-p api-key (%env-key))))
    (and key (make-openai-images :api-key key :model model :base-url base-url))))

(defun openai-image-request-body (provider request)
  "The JSON body, as a hash table, of the request for REQUEST. Separate from the POST so a test
can read the body that is built."
  (let ((body (make-hash-table :test #'equal))
        (size (image-request-size request))
        (quality (image-request-quality request)))
    (setf (gethash "model" body) (image-model-of provider)
          (gethash "prompt" body) (image-request-prompt request)
          (gethash "n" body) (image-request-count request)
          (gethash "size" body) (if (stringp size)
                                    size
                                    (or (cdr (assoc size *openai-sizes*))
                                        (error "~S is not an image size: use ~{~S~^, ~} or a \"WIDTHxHEIGHT\" string."
                                               size (mapcar #'car *openai-sizes*))))
          (gethash "quality" body) (if (stringp quality)
                                       quality
                                       (string-downcase (symbol-name quality))))
    body))

(defgeneric image-post (provider body)
  (:documentation "Send BODY to PROVIDER and return the parsed JSON reply. The transport, as a
generic function so that a test can answer in its place."))

(defun %refusal-details (body)
  "The stage and categories from the error JSON BODY of a refusal, as two values. Only short
identifiers are kept, because anything longer could carry the request."
  (let* ((parsed (and (stringp body) (handler-case (jzon:parse body) (error () nil))))
         (err (and (hash-table-p parsed) (gethash "error" parsed)))
         (details (and (hash-table-p err) (gethash "moderation_details" err))))
    (flet ((short (x) (and (stringp x) (<= (length x) 32)
                           (every (lambda (ch) (or (alphanumericp ch) (find ch "-_."))) x)
                           x)))
      (if (hash-table-p details)
          (values (short (gethash "moderation_stage" details))
                  (let ((cats (gethash "categories" details)))
                    (and (vectorp cats) (remove nil (map 'list #'short cats)))))
          (values nil '())))))

(defmethod image-post ((p openai-images) body)
  (let ((url (concatenate 'string (openai-images-base-url p) "/images/generations")))
    (handler-case
        (jzon:parse
         (http:response-body
          (http:send-request
           (http:make-request :method :post :url url
                              :headers (list '("content-type" . "application/json")
                                             (cons "authorization"
                                                   (format nil "Bearer ~A" (openai-images-api-key p))))
                              :content (jzon:stringify body)
                              :read-timeout (openai-images-read-timeout p))
           (list (http:ensure-2xx "openai images")))))
      (http:http-error (e)
        (let ((failure (llm:request-failure "openai images" e)))
          (if (member (cnd:provider-request-failed-error-code failure) *refusal-codes*
                      :test #'equal)
              (multiple-value-bind (stage categories)
                  (%refusal-details (cnd:provider-request-failed-body failure))
                (let ((code (cnd:provider-request-failed-error-code failure)))
                  (error 'image-refused :provider "openai" :code code :stage stage
                                        :categories categories :outcome :error
                                        :text (%refusal-text "openai" code stage categories))))
              (error failure)))))))

(defun %media-type (format)
  (cond ((equal format "jpeg") "image/jpeg")
        ((equal format "webp") "image/webp")
        (t "image/png")))

(defun %reported (parsed key)
  (let ((v (gethash key parsed)))
    (and (stringp v) v)))

(defmethod generate-images ((p openai-images) request)
  (let* ((parsed (image-post p (openai-image-request-body p request)))
         (data (gethash "data" parsed))
         (usage (gethash "usage" parsed))
         (media-type (%media-type (%reported parsed "output_format")))
         (size (%reported parsed "size"))
         (quality (%reported parsed "quality")))
    (unless (and (vectorp data) (plusp (length data)))
      (error 'cnd:provider-request-failed
             :detail "openai images: the reply has no images in data"))
    (values
     (map 'list
          (lambda (item)
            (let ((encoded (gethash "b64_json" item)))
              (unless (stringp encoded)
                (error 'cnd:provider-request-failed
                       :detail "openai images: an image in the reply has no b64_json"))
              (%make-image-result
               :octets (b64:base64-string-to-usb8-array encoded)
               :media-type media-type
               :revised-prompt (let ((r (gethash "revised_prompt" item)))
                                 (and (stringp r) (plusp (length r)) r))
               :provider "openai" :model (image-model-of p)
               :size size :quality quality :cost nil)))
          data)
     (append (and size (list :size size))
             (and quality (list :quality quality))
             (and (hash-table-p usage)
                  (append (let ((v (gethash "input_tokens" usage)))
                            (and (integerp v) (list :input-tokens v)))
                          (let ((v (gethash "output_tokens" usage)))
                            (and (integerp v) (list :output-tokens v)))))))))

;;; --- the means ----------------------------------------------------------------------------

(defparameter *description*
  "Create an image from a text description. Describe the image fully in the prompt: subject,
style, composition, colours and any text it must contain. The image is delivered to the user;
you are told only that it was made. Optionally choose a shape (square, portrait or landscape)
and a quality (low, medium or high).")

(defun %enum (values description)
  (let ((h (make-hash-table :test 'equal)))
    (setf (gethash "type" h) "string"
          (gethash "enum" h) (coerce values 'vector)
          (gethash "description" h) description)
    h))

(defun %schema ()
  "The JSON input schema: a required PROMPT, and an optional SIZE and QUALITY."
  (let ((prompt (make-hash-table :test 'equal))
        (props (make-hash-table :test 'equal))
        (schema (make-hash-table :test 'equal)))
    (setf (gethash "type" prompt) "string"
          (gethash "description" prompt) "A full description of the image to create.")
    (setf (gethash "prompt" props) prompt
          (gethash "size" props) (%enum '("square" "portrait" "landscape" "auto")
                                        "The image's shape. auto lets the provider choose.")
          (gethash "quality" props) (%enum '("low" "medium" "high" "auto")
                                           "Higher quality takes longer and costs more."))
    (setf (gethash "type" schema) "object"
          (gethash "properties" schema) props
          (gethash "required" schema) (vector "prompt"))
    schema))

(defun %keyword-arg (args name allowed)
  "The argument NAME from the tool ARGS as a keyword in ALLOWED, or :AUTO when it is absent or
not one of them."
  (let ((v (gethash name args)))
    (or (and (stringp v)
             (find v allowed :key #'symbol-name :test #'string-equal))
        :auto)))

(defun %summary (result reference)
  (format nil "Created an image (~A, ~D bytes~@[, ~A~])~@[ and delivered it as ~A~].~@[ The provider revised the prompt to: ~A~]"
          (image-result-media-type result) (length (image-result-octets result))
          (image-result-size result) reference (image-result-revised-prompt result)))

(defun register (agent provider &key on-image (name "generate-image") capability source)
  "Register the generate-image means on AGENT, generating with PROVIDER, an IMAGE-PROVIDER.
Returns NAME.

ON-IMAGE is required: a function of one IMAGE-RESULT that stores or shows the image and returns
a short string the model may see as a reference to it, such as an id, or NIL. The model is told
the media type, the size in bytes, that reference and the revised prompt, never the bytes.
CAPABILITY and SOURCE are as for ACTOR:REGISTER-MEANS.

An app normally calls REGISTER-OPENAI-IMAGE, which registers nothing when there is no key."
  (check-type provider image-provider)
  (unless (functionp on-image)
    (error "REGISTER needs :ON-IMAGE, a function that receives each generated image; without one the image would be made, paid for and lost."))
  (actor:register-means
   agent name *description*
   (lambda (args)
     (let ((prompt (gethash "prompt" args)))
       ;; Refused before any request, as an error result the model can correct: an empty
       ;; prompt would cost a round trip and come back as a failed request that ends the turn.
       (unless (and (stringp prompt) (plusp (length (string-trim " " prompt))))
         (error 'cnd:tool-error-result :outcome :not-run
                                       :text "generate-image needs a prompt describing the image."))
     (let* ((results (generate-image provider prompt
                                     :size (%keyword-arg args "size"
                                                         '(:square :portrait :landscape :auto))
                                     :quality (%keyword-arg args "quality"
                                                            '(:low :medium :high :auto)))))
       (format nil "~{~A~^~%~}"
               (mapcar (lambda (r) (%summary r (funcall on-image r))) results)))))
   :schema (%schema) :capability capability :source source))

(defun register-openai-image (agent &key on-image (api-key nil api-key-p) model base-url
                                         (name "generate-image") capability source)
  "Register the generate-image means on AGENT with OpenAI's Image API, when there is a key.
Returns NAME, or NIL when there is no key, in which case nothing is registered. This is the way
to register it: a means without a key could only fail.

The key is API-KEY when given, NIL included, and otherwise PRAXEON_IMAGE_API_KEY, then
PRAXEON_OPENAI_API_KEY. ON-IMAGE is as for REGISTER. MODEL and BASE-URL are as for
MAKE-OPENAI-IMAGES."
  (let ((provider (if api-key-p
                      (openai-images-from-env :api-key api-key :model model :base-url base-url)
                      (openai-images-from-env :model model :base-url base-url))))
    (and provider
         (register agent provider :on-image on-image :name name
                                  :capability capability :source source))))
