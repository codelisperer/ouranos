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
;;;; failed request is PROVIDER-REQUEST-FAILED, as for the chat providers (#719). When the
;;;; service is busy (429), fails on its side (5xx) or does not answer, the failure is an
;;;; IMAGE-REQUEST-FAILED, and inside a turn the means turns it into an error result that tells
;;;; the model to try again later, so the turn goes on. Nothing is retried automatically.
;;;;
;;;; COST. The app chooses which qualities the model may ask for (REGISTER's :QUALITIES), and the
;;;; tool schema offers only those. A request for any other quality is refused before it is sent.
;;;;
;;;; USAGE. Each request that succeeds emits one :IMAGE-USAGE event through praxeon/event, with
;;;; the provider, the model, the number of images, the size and quality the provider reports,
;;;; the token counts it reports, :COST when it is known, and the call's :ID, :PRINCIPAL and
;;;; :AGENT as on :TOOL-RESULT. OpenAI reports no cost, so for a model in *OPENAI-IMAGE-PRICES*
;;;; praxeon computes one from the token counts and OpenAI's published per-token prices, and the
;;;; event says so with :ESTIMATED T. For a model not in the table :COST is absent rather than 0.
;;;; A refused or failed request emits no :IMAGE-USAGE event, because the provider reports no
;;;; usage with an error; whether a provider charges for a refused request is its own policy,
;;;; which praxeon cannot see.
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
   #:image-result-cost-estimated-p
   #:generate-image
   ;; a refusal
   #:image-refused #:image-refused-provider #:image-refused-code #:image-refused-stage
   #:image-refused-categories
   ;; the service busy, failing or not answering
   #:image-request-failed #:image-request-failed-kind #:image-request-failed-retry-after
   ;; OpenAI
   #:openai-images #:make-openai-images #:openai-images-from-env #:image-post
   #:openai-image-request-body #:*openai-image-model* #:*openai-images-base-url*
   #:*openai-images-read-timeout* #:*max-bytes-per-image*
   #:*openai-image-prices* #:openai-image-cost
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
:SIZE, :QUALITY, :INPUT-TOKENS, :OUTPUT-TOKENS and :COST, each present only when known, and
:ESTIMATED T when the backend computed :COST from a price table rather than the provider
reporting it. :COST is in US dollars.
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
NIL. SIZE and QUALITY are as the provider reported them, or NIL. COST is this image's share of
the request's cost in US dollars, as a rational: the request's cost divided evenly among its
images. It is NIL when the cost is not known. COST-ESTIMATED-P is true when praxeon computed COST
from a price table rather than the provider reporting it."
  octets media-type revised-prompt provider model size quality cost cost-estimated-p)

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

(define-condition image-request-failed (cnd:provider-request-failed)
  ((kind :initarg :kind :initform nil :reader image-request-failed-kind)
   (retry-after :initarg :retry-after :initform nil :reader image-request-failed-retry-after))
  (:documentation "An image request failed in a way that may pass if it is tried again later.

KIND is :RATE-LIMITED for a 429, :SERVER-ERROR for a 5xx, and :NO-ANSWER when no response
arrived, such as after the read timeout or when the connection failed. RETRY-AFTER is the number
of seconds the service's Retry-After header asked the caller to wait, or NIL when it sent none or
sent a date.

It is a PROVIDER-REQUEST-FAILED, so a caller outside a turn handles it as before. Inside a turn
the generate-image means turns it into a TOOL-ERROR-RESULT, so the model can tell the user to try
again and the turn goes on. Praxeon does not retry the request."))

(defun %refusal-text (provider code stage categories)
  (format nil "The ~A image provider refused to create this image under its content policy~@[ (code ~A)~]~@[ at the ~A stage~]~@[; categories: ~{~A~^, ~}~]. No image was made. Tell the user it was refused, and do not retry the same request."
          provider code stage categories))

(defun %size-name (size)
  "SIZE as text for an event or a log: a keyword downcased, a string as is."
  (if (keywordp size) (string-downcase (symbol-name size)) size))

(defun generate-image (provider prompt &key (size :auto) (quality :auto) (count 1)
                                            (id actor:*tool-call-id*)
                                            (principal actor:*principal*) agent)
  "Generate COUNT images from PROMPT with PROVIDER. Returns a list of IMAGE-RESULTs.

SIZE is :SQUARE, :PORTRAIT, :LANDSCAPE, :AUTO or a \"WIDTHxHEIGHT\" string; QUALITY is :LOW,
:MEDIUM, :HIGH or :AUTO, or a string the provider accepts. COUNT is from 1 to 10, the range OpenAI's Image API accepts.
Emits one :IMAGE-USAGE event for a request that succeeded, carrying ID, PRINCIPAL and AGENT
(the agent's name) as a :TOOL-RESULT event does; ID and PRINCIPAL default to the running tool
call's. Signals IMAGE-REFUSED for a content-policy refusal, IMAGE-REQUEST-FAILED when the
service is busy, fails on its side or does not answer, and PROVIDER-REQUEST-FAILED for any other
failure."
  (check-type prompt string)
  (check-type count (integer 1 10))
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
               :id id :principal principal :agent agent
               :provider name :model model :count (length results)
               (append (list :size (or (getf reported :size) (%size-name size))
                             :quality (or (getf reported :quality) (%size-name quality)))
                       (loop for key in '(:input-tokens :output-tokens :cost :estimated)
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

(defparameter *openai-images-read-timeout* 120
  "Seconds to wait for OpenAI's reply before the request is IMAGE-REQUEST-FAILED with kind
:NO-ANSWER. A high-quality image can take over a minute; inside a turn the user is waiting, so
the wait is bounded. MAKE-OPENAI-IMAGES and REGISTER-OPENAI-IMAGE take :READ-TIMEOUT.")

(defclass openai-images (image-provider)
  ((api-key :initarg :api-key :reader openai-images-api-key)
   (model :initarg :model :initform *openai-image-model* :reader image-model-of)
   (base-url :initarg :base-url :initform *openai-images-base-url* :reader openai-images-base-url)
   (read-timeout :initarg :read-timeout :initform *openai-images-read-timeout*
                 :reader openai-images-read-timeout)
   (connect-timeout :initarg :connect-timeout :initform 30 :reader openai-images-connect-timeout))
  (:documentation "OpenAI's Image API, POST BASE-URL/images/generations, as an image provider.
API-KEY is sent as a bearer token. READ-TIMEOUT and CONNECT-TIMEOUT are in seconds; READ-TIMEOUT
defaults to *OPENAI-IMAGES-READ-TIMEOUT*. A reply is read up to *MAX-BYTES-PER-IMAGE* for each
image asked for; a longer one is PROVIDER-REQUEST-FAILED."))

(defparameter *max-bytes-per-image* (* 24 1024 1024)
  "The most bytes of reply read for each image requested. An image arrives as base64 inside JSON,
so the reply is about a third larger than the file. The largest documented size, 1536x1024, is
6.3 MB at four bytes a pixel before any compression and about 8.4 MB as base64, so 24 MB is far
above any image the API's documented sizes produce, and stops a reply that never ends from
filling the heap.")

(defmethod image-provider-name ((p openai-images)) "openai")

(defun %getenv (name)
  (let ((v (uiop:getenv name)))
    (and v (plusp (length v)) v)))

(defun %env-key ()
  "The OpenAI image key from the environment: PRAXEON_IMAGE_API_KEY, then PRAXEON_OPENAI_API_KEY.
NIL when neither is set."
  (or (%getenv "PRAXEON_IMAGE_API_KEY") (%getenv "PRAXEON_OPENAI_API_KEY")))

(defun %key (api-key api-key-p)
  "The key to use: API-KEY when given, otherwise the environment's. A given key that is NIL or
the empty string is no key; it never falls back to the environment, because the app chose it."
  (let ((key (if api-key-p api-key (%env-key))))
    (and (stringp key) (plusp (length key)) key)))

(defun make-openai-images (&key (api-key nil api-key-p) model base-url read-timeout)
  "An OPENAI-IMAGES provider. An API-KEY that is given is used, NIL included; the environment
is read only when none is given (PRAXEON_IMAGE_API_KEY, then PRAXEON_OPENAI_API_KEY). A given
key of NIL or \"\" is no key. MODEL defaults to PRAXEON_IMAGE_MODEL, then *OPENAI-IMAGE-MODEL*;
BASE-URL to PRAXEON_IMAGE_BASE_URL, then *OPENAI-IMAGES-BASE-URL*; READ-TIMEOUT, in seconds, to
*OPENAI-IMAGES-READ-TIMEOUT*. Signals MISSING-PROVIDER-KEY when there is no key, because every
request would fail."
  (let ((key (%key api-key api-key-p)))
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
                                 *openai-images-base-url*)
                   :read-timeout (or read-timeout *openai-images-read-timeout*))))

(defun openai-images-from-env (&key (api-key nil api-key-p) model base-url read-timeout)
  "An OPENAI-IMAGES provider as MAKE-OPENAI-IMAGES builds it, or NIL when there is no key, so a
caller can leave the means unregistered rather than register one that cannot work."
  (let ((key (%key api-key api-key-p)))
    (and key (make-openai-images :api-key key :model model :base-url base-url
                                 :read-timeout read-timeout))))

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

(defun %unexpected-reply (what)
  "A PROVIDER-REQUEST-FAILED for a 2xx reply that is not the documented shape. WHAT says how; it
never quotes the reply, which can repeat the request."
  (make-condition 'cnd:provider-request-failed
                  :detail (format nil "openai images: the reply ~A" what)))

(defun %parse-reply (text)
  "TEXT, a reply body, parsed as JSON, or PROVIDER-REQUEST-FAILED when it is not JSON."
  (handler-case (jzon:parse text)
    (error () (error (%unexpected-reply (format nil "is not JSON (~D characters)" (length text)))))))

(defun %retry-after-seconds (value)
  "The Retry-After header VALUE as a whole number of seconds, or NIL when it is absent or is an
HTTP date rather than a number of seconds."
  (and (stringp value)
       (let ((n (ignore-errors (parse-integer (string-trim " " value)))))
         (and n (>= n 0) n))))

(defun %failure-kind (e status)
  "The IMAGE-REQUEST-FAILED kind for the HTTP-ERROR E with STATUS, or NIL when trying again
later would not help, such as for a 400 or a reply over the size limit."
  (cond ((eql status 429) :rate-limited)
        ((and status (<= 500 status 599)) :server-error)
        ((and (null status) (not (typep e 'http:response-too-large))) :no-answer)))

(defun %request-failed (e retry-after)
  "The condition to signal for the failed HTTP request E that is not a refusal: an
IMAGE-REQUEST-FAILED when trying again later may help, otherwise PROVIDER-REQUEST-FAILED."
  (let* ((failure (llm:request-failure "openai images" e))
         (status (cnd:provider-request-failed-status failure))
         (kind (%failure-kind e status)))
    (if kind
        (make-condition 'image-request-failed
                        :kind kind :retry-after (%retry-after-seconds retry-after)
                        :status status
                        :error-type (cnd:provider-request-failed-error-type failure)
                        :error-code (cnd:provider-request-failed-error-code failure)
                        :body (cnd:provider-request-failed-body failure)
                        :detail (cnd:praxeon-error-detail failure))
        failure)))

(defmethod image-post ((p openai-images) body)
  (let ((url (concatenate 'string (openai-images-base-url p) "/images/generations"))
        (retry-after nil))
    (handler-case
        (%parse-reply
         (http:response-body
          (http:send-request
           (http:make-request :method :post :url url
                              :headers (list '("content-type" . "application/json")
                                             (cons "authorization"
                                                   (format nil "Bearer ~A" (openai-images-api-key p))))
                              :content (jzon:stringify body)
                              :read-timeout (openai-images-read-timeout p)
                              :connect-timeout (openai-images-connect-timeout p)
                              :max-body-bytes (* *max-bytes-per-image*
                                                 (max 1 (or (gethash "n" body) 1))))
           ;; Leave stages run last to first, so the header is read before ENSURE-2XX signals.
           (list (http:ensure-2xx "openai images")
                 (http:make-interceptor
                  "retry-after"
                  :leave (lambda (resp)
                           (setf retry-after (http:header-value (http:response-headers resp)
                                                                "retry-after"))
                           resp))))))
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
              (error (%request-failed e retry-after))))))))

(defun %media-type (format)
  (cond ((equal format "jpeg") "image/jpeg")
        ((equal format "webp") "image/webp")
        (t "image/png")))

(defun %reported (parsed key)
  (let ((v (gethash key parsed)))
    (and (stringp v) v)))

(defun %decode-image (encoded)
  "The octets ENCODED, a base64 string, stands for, or PROVIDER-REQUEST-FAILED when it is not
base64."
  (handler-case (b64:base64-string-to-usb8-array encoded)
    (error () (error (%unexpected-reply "has an image that is not valid base64")))))

(defparameter *openai-image-prices*
  ;; US dollars per million tokens, from https://developers.openai.com/api/docs/pricing, table
  ;; "Image generation models", Standard. upstream.sexp pins each row with the date it was read.
  ;; A price the page does not list is left out of its row, never guessed. A model's shutdown
  ;; date is its upstream.sexp entry's :retires; the row stays, so a request made before that
  ;; date can still be priced.
  '(("gpt-image-2" :text-input 5 :image-input 8 :image-output 30)
    ("gpt-image-2.5-flare" :text-input 5 :image-input 8 :image-output 30)
    ("gpt-image-2.5-sunburst" :text-input 5 :image-input 8 :image-output 30)
    ("gpt-image-1.5" :text-input 5 :image-input 8 :text-output 10 :image-output 32)
    ("gpt-image-1-mini" :text-input 2 :image-input 5/2 :image-output 8)
    ("gpt-image-1" :text-input 5 :image-input 10 :image-output 40)
    ("chatgpt-image-latest" :text-input 5 :image-input 8 :text-output 10 :image-output 32))
  "OpenAI's image model prices, as (MODEL . PRICES). PRICES is a plist of US dollars per million
tokens: :TEXT-INPUT, :IMAGE-INPUT, :IMAGE-OUTPUT and, when OpenAI lists it, :TEXT-OUTPUT. The
prices are exact rationals, so 5/2 is $2.50.

OpenAI publishes these per token, not per image: what an image costs depends on the tokens it
used, which the reply reports. OPENAI-IMAGE-COST turns those counts into a cost. An app that
bills from it should treat the result as an estimate (:ESTIMATED T on :IMAGE-USAGE). Each
approximation it makes raises the estimate rather than lowering it: cached input is priced at the
full input rate, and a count the reply does not split is priced at the higher of its two rates.
It is only as accurate as the token counts the reply reports.")

(defun %price-for (model)
  (cdr (assoc model *openai-image-prices* :test #'equal)))

(defun openai-image-cost (model reported)
  "The cost in US dollars, as a rational, of a request to MODEL whose usage was REPORTED, a plist
with :INPUT-TOKENS and :OUTPUT-TOKENS and, when the reply split them, :INPUT-TEXT-TOKENS,
:INPUT-IMAGE-TOKENS, :OUTPUT-TEXT-TOKENS and :OUTPUT-IMAGE-TOKENS. NIL when MODEL is not in
*OPENAI-IMAGE-PRICES* or the reply gave no token counts.

When the reply splits a count into text and image tokens, each part is priced at its own rate.
When it does not, the whole count is priced at the higher of the two rates. Output text tokens
are priced at :TEXT-OUTPUT, or at :IMAGE-OUTPUT when OpenAI lists no text output price."
  (let ((prices (%price-for model)))
    (flet ((n (key) (getf reported key))
           (rate (key) (getf prices key)))
      (let ((input (n :input-tokens))
            (output (n :output-tokens))
            (text-output (or (rate :text-output) (rate :image-output))))
        (when (and prices (integerp input) (integerp output))
          (/ (+ (if (and (n :input-text-tokens) (n :input-image-tokens))
                    (+ (* (n :input-text-tokens) (rate :text-input))
                       (* (n :input-image-tokens) (rate :image-input)))
                    (* input (max (rate :text-input) (rate :image-input))))
                (if (and (n :output-text-tokens) (n :output-image-tokens))
                    (+ (* (n :output-text-tokens) text-output)
                       (* (n :output-image-tokens) (rate :image-output)))
                    (* output (max text-output (rate :image-output)))))
             1000000))))))

(defun %usage-counts (usage)
  "The token counts in the reply's USAGE object, as a plist. A count that is not an integer is
left out."
  (flet ((count-of (table key name)
           (let ((v (and (hash-table-p table) (gethash name table))))
             (and (integerp v) (list key v)))))
    (let ((in (and (hash-table-p usage) (gethash "input_tokens_details" usage)))
          (out (and (hash-table-p usage) (gethash "output_tokens_details" usage))))
      (append (count-of usage :input-tokens "input_tokens")
              (count-of usage :output-tokens "output_tokens")
              (count-of in :input-text-tokens "text_tokens")
              (count-of in :input-image-tokens "image_tokens")
              (count-of out :output-text-tokens "text_tokens")
              (count-of out :output-image-tokens "image_tokens")))))

(defmethod generate-images ((p openai-images) request)
  (let* ((parsed (image-post p (openai-image-request-body p request)))
         (parsed (if (hash-table-p parsed)
                     parsed
                     (error (%unexpected-reply "is not a JSON object"))))
         (data (gethash "data" parsed))
         (counts (%usage-counts (gethash "usage" parsed)))
         (cost (openai-image-cost (image-model-of p) counts))
         (media-type (%media-type (%reported parsed "output_format")))
         (size (%reported parsed "size"))
         (quality (%reported parsed "quality")))
    (unless (and (vectorp data) (not (stringp data)) (plusp (length data)))
      (error (%unexpected-reply "has no images in data")))
    (values
     (map 'list
          (lambda (item)
            (let ((encoded (and (hash-table-p item) (gethash "b64_json" item))))
              (unless (stringp encoded)
                (error (%unexpected-reply "has an image with no b64_json")))
              (%make-image-result
               :octets (%decode-image encoded)
               :media-type media-type
               :revised-prompt (let ((r (gethash "revised_prompt" item)))
                                 (and (stringp r) (plusp (length r)) r))
               :provider "openai" :model (image-model-of p)
               :size size :quality quality
               :cost (and cost (/ cost (length data))) :cost-estimated-p (and cost t))))
          data)
     (append (and size (list :size size))
             (and quality (list :quality quality))
             (loop for (key value) on counts by #'cddr
                   when (member key '(:input-tokens :output-tokens))
                     append (list key value))
             (and cost (list :cost cost :estimated t))))))

;;; --- the means ----------------------------------------------------------------------------

(defparameter *description*
  "Create an image from a text description. Describe the image fully in the prompt: subject,
style, composition, colours and any text it must contain. The image is delivered to the user;
you are told only that it was made. Optionally choose a shape and a quality from the values the
input schema lists.")

(defparameter *sizes* '(:square :portrait :landscape :auto)
  "The shapes the means can offer the model.")

(defparameter *qualities* '(:low :medium :high :auto)
  "The qualities the means can offer the model. REGISTER's :QUALITIES picks among them.")

(defun %names (keywords)
  (mapcar (lambda (k) (string-downcase (symbol-name k))) keywords))

(defun %enum (values description)
  (let ((h (make-hash-table :test 'equal)))
    (setf (gethash "type" h) "string"
          (gethash "enum" h) (coerce values 'vector)
          (gethash "description" h) description)
    h))

(defun %schema (qualities default-size default-quality)
  "The JSON input schema: a required PROMPT, an optional SIZE, and an optional QUALITY offering
only QUALITIES. Each description names the value used when the model gives none."
  (let ((prompt (make-hash-table :test 'equal))
        (props (make-hash-table :test 'equal))
        (schema (make-hash-table :test 'equal)))
    (setf (gethash "type" prompt) "string"
          (gethash "description" prompt) "A full description of the image to create.")
    (setf (gethash "prompt" props) prompt
          (gethash "size" props)
          (%enum (%names *sizes*)
                 (format nil "The image's shape. auto lets the provider choose. Default: ~(~A~)."
                         default-size))
          (gethash "quality" props)
          (%enum (%names qualities)
                 (format nil "Higher quality takes longer and costs more. Default: ~(~A~)."
                         default-quality)))
    (setf (gethash "type" schema) "object"
          (gethash "properties" schema) props
          (gethash "required" schema) (vector "prompt"))
    schema))

(defun %choice (args name allowed default)
  "The argument NAME from the tool ARGS as a keyword in ALLOWED, or DEFAULT when it is absent.
Any other value is refused with an error result naming the allowed values, before any request,
so a quality the app did not allow is never sent."
  (let ((v (gethash name args)))
    (if (null v)
        default
        (or (and (stringp v) (find v allowed :key #'symbol-name :test #'string-equal))
            (error 'cnd:tool-error-result
                   :outcome :not-run
                   :text (format nil "generate-image: ~A must be one of ~{~A~^, ~}. No image was made."
                                 name (%names allowed)))))))

(defun %retry-text (c)
  "What the model is told when the image request failed with the IMAGE-REQUEST-FAILED C."
  (let ((wait (image-request-failed-retry-after c)))
    (format nil "~A No image was made. ~:[Try again shortly~;Try again in about ~:*~D seconds~], and tell the user if it keeps failing."
            (ecase (image-request-failed-kind c)
              (:rate-limited "The image service is busy and refused the request for now (HTTP 429).")
              (:server-error (format nil "The image service failed on its side (HTTP ~A)."
                                     (cnd:provider-request-failed-status c)))
              (:no-answer "The image service did not answer in time, or could not be reached."))
            wait)))

(defparameter *revised-prompt-chars* 400
  "The most characters of the provider's revised prompt the model is shown. The model wrote the
prompt, so it needs only enough to see what changed; the whole of it is in the IMAGE-RESULT.")

(defun %summary (result reference)
  (let* ((revised (image-result-revised-prompt result))
         (cut (and revised (> (length revised) *revised-prompt-chars*))))
    (format nil "Created an image (~A, ~D bytes~@[, ~A~])~@[ and delivered it as ~A~].~@[ The provider revised the prompt to: ~A~]~:[~;… (cut at ~D of ~D characters)~]"
            (image-result-media-type result) (length (image-result-octets result))
            (image-result-size result) reference
            (if cut (subseq revised 0 *revised-prompt-chars*) revised)
            cut *revised-prompt-chars* (and revised (length revised)))))

(defun register (agent provider &key on-image (name "generate-image") capability source
                                     (qualities *qualities*) default-quality (default-size :auto))
  "Register the generate-image means on AGENT, generating with PROVIDER, an IMAGE-PROVIDER.
Returns NAME.

ON-IMAGE is required: a function of one IMAGE-RESULT that stores or shows the image and returns
a short string the model may see as a reference to it, such as an id, or NIL. The model is told
the media type, the size in bytes, that reference and the revised prompt, never the bytes.
CAPABILITY and SOURCE are as for ACTOR:REGISTER-MEANS.

QUALITIES is the list of qualities the model may ask for, from :LOW, :MEDIUM, :HIGH and :AUTO,
so an app can bound what an image costs: '(:LOW :MEDIUM) never sends :HIGH. The tool schema
offers only these, and a call asking for any other is refused before a request is made.
DEFAULT-QUALITY is used when the model names none; it must be in QUALITIES, and defaults to
:AUTO when :AUTO is allowed and otherwise to the first of QUALITIES. DEFAULT-SIZE, one of
:SQUARE, :PORTRAIT, :LANDSCAPE and :AUTO, is used when the model names no shape.

When the service is busy, fails on its side or does not answer (IMAGE-REQUEST-FAILED), the
model is told so in an error result and the turn goes on; the request is not retried.

An app normally calls REGISTER-OPENAI-IMAGE, which registers nothing when there is no key."
  (check-type provider image-provider)
  (unless (functionp on-image)
    (error "REGISTER needs :ON-IMAGE, a function that receives each generated image; without one the image would be made, paid for and lost."))
  (unless (and qualities (listp qualities) (subsetp qualities *qualities*))
    (error "REGISTER's :QUALITIES must be a non-empty list of ~{~S~^, ~}, not ~S." *qualities* qualities))
  (let ((default-quality (or default-quality
                             (if (member :auto qualities) :auto (first qualities)))))
    (unless (member default-quality qualities)
      (error "REGISTER's :DEFAULT-QUALITY ~S is not one of its :QUALITIES ~S." default-quality qualities))
    (unless (member default-size *sizes*)
      (error "REGISTER's :DEFAULT-SIZE must be one of ~{~S~^, ~}, not ~S." *sizes* default-size))
    (%register agent provider on-image name capability source
               qualities default-quality default-size)))

(defun %register (agent provider on-image name capability source
                  qualities default-quality default-size)
  (actor:register-means
   agent name *description*
   (lambda (args)
     (let ((prompt (gethash "prompt" args)))
       ;; Refused before any request, as an error result the model can correct: an empty
       ;; prompt would cost a round trip and come back as a failed request that ends the turn.
       (unless (and (stringp prompt)
                    (plusp (length (string-trim '(#\Space #\Tab #\Newline #\Return #\Page)
                                                prompt))))
         (error 'cnd:tool-error-result :outcome :not-run
                                       :text "generate-image needs a prompt describing the image."))
     (let* ((size (%choice args "size" *sizes* default-size))
            (quality (%choice args "quality" qualities default-quality))
            (results
              (handler-bind
                  ((image-request-failed
                     (lambda (c)
                       ;; :UNKNOWN when the request may have reached the service and been
                       ;; charged; a 429 was refused before any work was done.
                       (error 'cnd:tool-error-result
                              :outcome (if (eq :rate-limited (image-request-failed-kind c))
                                           :not-run
                                           :unknown)
                              :text (%retry-text c)))))
                (generate-image provider prompt :size size :quality quality
                                                :agent (actor:agent-name agent)))))
       (format nil "~{~A~^~%~}"
               (mapcar (lambda (r) (%summary r (funcall on-image r))) results)))))
   :schema (%schema qualities default-size default-quality)
   :capability capability :source source))

(defun register-openai-image (agent &key on-image (api-key nil api-key-p) model base-url
                                         read-timeout (name "generate-image") capability source
                                         (qualities *qualities*) default-quality
                                         (default-size :auto))
  "Register the generate-image means on AGENT with OpenAI's Image API, when there is a key.
Returns NAME, or NIL when there is no key, in which case nothing is registered. This is the way
to register it: a means without a key could only fail.

The key is API-KEY when given, NIL included, and otherwise PRAXEON_IMAGE_API_KEY, then
PRAXEON_OPENAI_API_KEY. A given key of NIL or \"\" is no key, and nothing is registered; an
empty string is logged at warn, because it usually means the app's key setting is blank.
ON-IMAGE, QUALITIES, DEFAULT-QUALITY and DEFAULT-SIZE are as for REGISTER. MODEL, BASE-URL and
READ-TIMEOUT are as for MAKE-OPENAI-IMAGES."
  (when (and api-key-p (equal api-key ""))
    (log:warn "generate-image not registered: the :api-key given is the empty string"
              :name name))
  (let ((provider (if api-key-p
                      (openai-images-from-env :api-key api-key :model model :base-url base-url
                                              :read-timeout read-timeout)
                      (openai-images-from-env :model model :base-url base-url
                                              :read-timeout read-timeout))))
    (and provider
         (register agent provider :on-image on-image :name name
                                  :capability capability :source source
                                  :qualities qualities :default-quality default-quality
                                  :default-size default-size))))
