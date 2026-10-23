;;;; image-google.lisp --- Google's Gemini API as an image provider for praxeon/image (#758).
;;;;
;;;; THE API. Requests go to generateContent at v1:
;;;; POST {base}/models/{model}:generateContent, with the key in x-goog-api-key. Google titles
;;;; its documentation of this API "Legacy" and recommends its Interactions API for new work, but
;;;; only generateContent documents how a refusal arrives (promptFeedback.blockReason and the
;;;; candidate's finishReason), the token counts by modality (usageMetadata), and which parts are
;;;; the model's thinking (thought). Moving to Interactions waits for Google to document refusals
;;;; there.
;;;;
;;;; THE REQUEST is the prompt as a text part and each reference image as an inline_data part, in
;;;; one user turn, with generationConfig.responseModalities ["IMAGE"]. A shape is sent as
;;;; imageConfig.aspectRatio and a quality as imageConfig.imageSize, so the qualities an app
;;;; allows also bound the resolution, and with it the cost. Google's edit takes no mask, and one
;;;; request makes one image.
;;;;
;;;; THE REPLY. The image is the last inline-data part of the first candidate's parts that is not
;;;; marked thought: a thinking model can produce interim images, which are marked thought, and
;;;; Google's guide says the last image is the result. One request makes one image, so only that
;;;; one is returned. A blocked prompt or a candidate stopped for safety is IMAGE-REFUSED;
;;;; a reply with no image for any other reason is IMAGE-NOT-MADE.
;;;;
;;;; KEYS. This provider reads only its own variables, PRAXEON_GOOGLE_API_KEY and then
;;;; GEMINI_API_KEY, never PRAXEON_IMAGE_API_KEY or PRAXEON_OPENAI_API_KEY, so a key an app set
;;;; up for OpenAI is never sent to Google.

(cl:in-package #:praxeon/image)

(defparameter *google-image-model* "gemini-nano-banana-2.1"
  "The Google image model used when none is given. Google's image-generation guide recommends
Nano Banana 2.1 for all new projects (read 2026-10-23). gemini-3.1-flash-lite-image is the
low-cost choice: its image output costs the same per token, its input a sixth as much, and it
makes 1K images only. An app can pass any other model id as :MODEL, or set
PRAXEON_GOOGLE_IMAGE_MODEL. upstream.sexp pins this value.")

(defparameter *google-images-base-url* "https://generativelanguage.googleapis.com/v1"
  "The Gemini API base URL, with its version. The provider appends
/models/{model}:generateContent to it. upstream.sexp pins the version.")

(defparameter *google-max-references* 14
  "The most reference images one Google request may send. Google's image-generation page says up
to 14 reference images can be mixed; its per-model table may allow fewer for some models, so a
request with more than a model takes can still be refused by Google.")

(defparameter *google-aspect-ratios*
  '((:square . "1:1") (:portrait . "2:3") (:landscape . "3:2"))
  "The aspectRatio Google is sent for each shape keyword. :AUTO sends none, and Google chooses.
A string size of the form \"W:H\" is sent as given.")

(defparameter *google-image-sizes*
  '((:low . "1K") (:medium . "2K") (:high . "4K"))
  "The imageSize Google is sent for each quality keyword. :AUTO sends none. Google documents 1K,
2K and 4K, and 512 for gemini-3.1-flash-image only; gemini-3.1-flash-lite-image makes 1K only. A
string quality, such as \"2K\", is sent as given.")

(defparameter *google-refusal-reasons*
  '("SAFETY" "BLOCKLIST" "PROHIBITED_CONTENT" "SPII" "IMAGE_SAFETY" "IMAGE_PROHIBITED_CONTENT"
    "RECITATION" "IMAGE_RECITATION")
  "The finish reasons with which Google stops a candidate under its policies, as its
generateContent reference lists them. RECITATION and IMAGE_RECITATION stop output that repeats
existing material. A blocked prompt (promptFeedback.blockReason) is a refusal
whatever its reason.")

(defclass google-images (image-provider)
  ((api-key :initarg :api-key :reader google-images-api-key)
   (model :initarg :model :initform *google-image-model* :reader image-model-of)
   (base-url :initarg :base-url :initform *google-images-base-url* :reader google-images-base-url)
   (read-timeout :initarg :read-timeout :initform *openai-images-read-timeout*
                 :reader google-images-read-timeout)
   (connect-timeout :initarg :connect-timeout :initform 30
                    :reader google-images-connect-timeout))
  (:documentation "Google's Gemini API, generateContent at BASE-URL, as an image provider. API-KEY
is sent as x-goog-api-key. READ-TIMEOUT and CONNECT-TIMEOUT are in seconds."))

(defmethod image-provider-name ((p google-images)) "google")
(defmethod image-provider-max-references ((p google-images)) *google-max-references*)
(defmethod image-provider-accepts-mask-p ((p google-images)) nil)

(defun %google-env-key ()
  "The Google key from the environment: PRAXEON_GOOGLE_API_KEY, then GEMINI_API_KEY. NIL when
neither is set. PRAXEON_IMAGE_API_KEY is the OpenAI provider's and is not read here."
  (or (%getenv "PRAXEON_GOOGLE_API_KEY") (%getenv "GEMINI_API_KEY")))

(defun make-google-images (&key (api-key nil api-key-p) model base-url read-timeout)
  "A GOOGLE-IMAGES provider. An API-KEY that is given is used, NIL included; the environment is
read only when none is given (PRAXEON_GOOGLE_API_KEY, then GEMINI_API_KEY). A given key of NIL or
\"\" is no key. MODEL defaults to PRAXEON_GOOGLE_IMAGE_MODEL, then *GOOGLE-IMAGE-MODEL*; BASE-URL
to PRAXEON_GOOGLE_IMAGE_BASE_URL, then *GOOGLE-IMAGES-BASE-URL*; READ-TIMEOUT, in seconds, to
*OPENAI-IMAGES-READ-TIMEOUT*. Signals MISSING-PROVIDER-KEY when there is no key."
  (let ((key (%key api-key api-key-p #'%google-env-key)))
    (unless key
      (error 'cnd:missing-provider-key
             :impl "google images"
             :variables (if api-key-p
                            '(":API-KEY")
                            '("PRAXEON_GOOGLE_API_KEY" "GEMINI_API_KEY"))))
    (make-instance 'google-images
                   :api-key key
                   :model (or model (%getenv "PRAXEON_GOOGLE_IMAGE_MODEL") *google-image-model*)
                   :base-url (or base-url (%getenv "PRAXEON_GOOGLE_IMAGE_BASE_URL")
                                 *google-images-base-url*)
                   :read-timeout (or read-timeout *openai-images-read-timeout*))))

(defun google-images-from-env (&key (api-key nil api-key-p) model base-url read-timeout)
  "A GOOGLE-IMAGES provider as MAKE-GOOGLE-IMAGES builds it, or NIL when there is no key."
  (let ((key (%key api-key api-key-p #'%google-env-key)))
    (and key (make-google-images :api-key key :model model :base-url base-url
                                 :read-timeout read-timeout))))

;;; --- the request ---------------------------------------------------------------------------

(defun %google-option (value table what)
  "The string Google is sent for VALUE, a keyword in TABLE, :AUTO for none, or a string sent as
given. Any other keyword is refused as IMAGE-INPUT-INVALID, naming WHAT it was."
  (cond ((eq value :auto) nil)
        ((stringp value) value)
        ((cdr (assoc value table)))
        (t (%invalid "The google image provider has no ~A ~(~A~); use one of ~{~(~A~)~^, ~} or auto."
                     what value (mapcar #'car table)))))

(defun %inline-image (image)
  "The inline_data part that sends the REFERENCE-IMAGE IMAGE."
  (%hash "inline_data"
         (%hash "mime_type" (reference-image-media-type image)
                "data" (b64:usb8-array-to-base64-string (reference-image-octets image)))))

(defun %hash (&rest kvs)
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on kvs by #'cddr do (setf (gethash k h) v))
    h))

(defun google-image-request-body (provider request)
  "The JSON body, as a hash table, of the generateContent request for REQUEST. Separate from the
POST so a test can read the body that is built."
  (declare (ignore provider))
  (unless (= 1 (image-request-count request))
    (%invalid "The google image provider makes one image per request, and ~D were asked for."
              (image-request-count request)))
  (let ((aspect (%google-option (image-request-size request) *google-aspect-ratios* "shape"))
        (size (%google-option (image-request-quality request) *google-image-sizes* "quality"))
        (image-config (make-hash-table :test #'equal)))
    (when aspect (setf (gethash "aspectRatio" image-config) aspect))
    (when size (setf (gethash "imageSize" image-config) size))
    (%hash "contents"
           (vector (%hash "role" "user"
                          "parts" (coerce (cons (%hash "text" (image-request-prompt request))
                                                (mapcar #'%inline-image
                                                        (image-request-references request)))
                                          'vector)))
           "generationConfig"
           (let ((config (%hash "responseModalities" (vector "IMAGE"))))
             (when (plusp (hash-table-count image-config))
               (setf (gethash "imageConfig" config) image-config))
             config))))

(defmethod image-post ((p google-images) body)
  (%send "google images"
         (format nil "~A/models/~A:generateContent" (google-images-base-url p) (image-model-of p))
         (list (cons "content-type" "application/json")
               (cons "x-goog-api-key" (google-images-api-key p)))
         (jzon:stringify body)
         :read-timeout (google-images-read-timeout p)
         :connect-timeout (google-images-connect-timeout p)
         ;; Room for the interim images a thinking model sends, marked thought, before its result.
         :max-body-bytes (* 4 *max-bytes-per-image*)))

;;; --- the reply -----------------------------------------------------------------------------

(defun %field (table &rest names)
  "The first of NAMES present in the JSON object TABLE. Google's REST replies use camelCase, and
its examples also show snake_case, so both are read."
  (and (hash-table-p table)
       (loop for name in names
             for (value found) = (multiple-value-list (gethash name table))
             when found return value)))

(defun %short (x)
  "X when it is a short identifier, otherwise NIL, so that nothing that could carry the request
reaches a condition or a log."
  (and (stringp x) (<= (length x) 48)
       (every (lambda (ch) (or (alphanumericp ch) (find ch "-_."))) x)
       x))

(defun %blocked-categories (ratings)
  "The categories of the safety RATINGS Google marked blocked, as short identifiers."
  (and (vectorp ratings) (not (stringp ratings))
       (remove nil (map 'list (lambda (r)
                                (and (hash-table-p r) (eq t (%field r "blocked"))
                                     (%short (%field r "category"))))
                        ratings))))

(defun %google-refusal (reason stage ratings)
  (let ((categories (%blocked-categories ratings)))
    (error 'image-refused :provider "google" :code reason :stage stage
                          :categories categories :outcome :error
                          :text (%refusal-text "google" reason stage categories))))

(defun %google-images (parts)
  "The image among PARTS, the first candidate's content parts, as a list of at most one
(OCTETS . MEDIA-TYPE): the last inline-data part not marked thought. One request makes one
image; Google's guide says the last image is the result, so an earlier one is never returned,
passed to the app, counted or charged."
  (let ((data (loop with last = nil
                    for part across (if (and (vectorp parts) (not (stringp parts))) parts #())
                    for inline = (and (hash-table-p part) (not (eq t (%field part "thought")))
                                      (%field part "inlineData" "inline_data"))
                    when (hash-table-p inline) do (setf last inline)
                    finally (return last))))
    (when data
      (let* ((encoded (%field data "data"))
             (octets (if (stringp encoded)
                         (%decode-image encoded "google images")
                         (error (%unexpected-reply "has image data that is not a string"
                                                   "google images")))))
        (list (cons octets (or (%sniff-media-type octets)
                               (let ((type (%field data "mimeType" "mime_type")))
                                 (and (stringp type) (%short* type)))
                               "application/octet-stream")))))))

(defun %short* (type)
  "TYPE when it looks like a media type, such as image/png, otherwise NIL."
  (and (<= (length type) 48) (search "/" type)
       (every (lambda (ch) (or (alphanumericp ch) (find ch "/-+."))) type)
       type))

(defun %google-usage (usage)
  "The token counts in USAGE, the reply's usageMetadata, as a plist: :INPUT-TOKENS, :OUTPUT-TOKENS
(the candidates' tokens and the thinking tokens together, which is what Google bills as output),
and, when Google splits the candidates' tokens by modality, :OUTPUT-IMAGE-TOKENS. A count that is
not an integer is left out."
  (let* ((prompt (%field usage "promptTokenCount"))
         (candidates (%field usage "candidatesTokenCount"))
         ;; Absent, or JSON null (which parses as a symbol), means no thinking tokens.
         (thoughts (let ((v (%field usage "thoughtsTokenCount"))) (if (integerp v) v 0)))
         (details (%field usage "candidatesTokensDetails"))
         (image (and (vectorp details) (not (stringp details))
                     (loop for d across details
                           when (and (hash-table-p d) (equal "IMAGE" (%field d "modality"))
                                     (integerp (%field d "tokenCount")))
                             sum (%field d "tokenCount")))))
    (append (and (integerp prompt) (list :input-tokens prompt))
            (and (integerp candidates) (integerp thoughts)
                 (list :output-tokens (+ candidates thoughts)))
            (and (integerp candidates) (integerp image) (<= image candidates)
                 (list :output-image-tokens image)))))

(defparameter *google-image-prices*
  ;; US dollars per million tokens, from https://ai.google.dev/gemini-api/docs/pricing, paid
  ;; tier, Standard, "Last updated 2026-10-22". upstream.sexp pins each row with the date it was
  ;; read. Google prices text and image input alike; text output includes thinking.
  ;; gemini-2.5-flash-image is left out: the page says it shut down on 2026-10-02.
  '(("gemini-nano-banana-2.1" :input 3/2 :text-output 15/2 :image-output 30)
    ("gemini-3.1-flash-image" :input 1/2 :text-output 3 :image-output 60)
    ("gemini-3.1-flash-lite-image" :input 1/4 :text-output 3/2 :image-output 30)
    ("gemini-3-pro-image" :input 2 :text-output 12 :image-output 120))
  "Google's image model prices, as (MODEL . PRICES). PRICES is a plist of US dollars per million
tokens: :INPUT, :TEXT-OUTPUT (which covers thinking) and :IMAGE-OUTPUT, as exact rationals.
GOOGLE-IMAGE-COST turns the reply's token counts into a cost.")

(defun google-image-cost (model reported)
  "The cost in US dollars, as a rational, of a request to MODEL whose usage was REPORTED, a plist
from the reply as GENERATE-IMAGES reads it: :INPUT-TOKENS and :OUTPUT-TOKENS, and
:OUTPUT-IMAGE-TOKENS when Google split the output by modality. NIL when MODEL is not in
*GOOGLE-IMAGE-PRICES* or a count is missing.

Image output tokens are priced at :IMAGE-OUTPUT and the rest of the output, text and thinking, at
:TEXT-OUTPUT. When the output is not split, all of it is priced at the higher of the two, so the
approximation raises the estimate rather than lowering it."
  (let ((prices (cdr (assoc model *google-image-prices* :test #'equal)))
        (input (getf reported :input-tokens))
        (output (getf reported :output-tokens))
        (image (getf reported :output-image-tokens)))
    (when (and prices (integerp input) (integerp output))
      (let ((in (getf prices :input))
            (text-out (getf prices :text-output))
            (image-out (getf prices :image-output)))
        (/ (+ (* input in)
              (if (integerp image)
                  (+ (* image image-out) (* (- output image) text-out))
                  (* output (max image-out text-out))))
           1000000)))))

(defmethod generate-images ((p google-images) request)
  (let* ((parsed (image-post p (google-image-request-body p request)))
         (parsed (if (hash-table-p parsed)
                     parsed
                     (error (%unexpected-reply "is not a JSON object" "google images"))))
         (feedback (%field parsed "promptFeedback"))
         (block-reason (%short (%field feedback "blockReason")))
         (candidates (%field parsed "candidates"))
         (candidate (and (vectorp candidates) (not (stringp candidates)) (plusp (length candidates))
                         (aref candidates 0)))
         (finish (%short (%field candidate "finishReason")))
         (images (%google-images (%field (%field candidate "content") "parts")))
         (counts (%google-usage (%field parsed "usageMetadata")))
         (cost (google-image-cost (image-model-of p) counts)))
    (when block-reason
      (%google-refusal block-reason "input" (%field feedback "safetyRatings")))
    (unless images
      (if (member finish *google-refusal-reasons* :test #'equal)
          (%google-refusal finish "output" (%field candidate "safetyRatings"))
          (%not-made "google" finish)))
    (values
     (mapcar (lambda (image)
               (%make-image-result :octets (car image) :media-type (cdr image) :revised-prompt nil
                                   :provider "google" :model (image-model-of p)
                                   :size nil :quality nil
                                   :cost (and cost (/ cost (length images)))
                                   :cost-estimated-p (and cost t)))
             images)
     (append (loop for (key value) on counts by #'cddr
                   when (member key '(:input-tokens :output-tokens))
                     append (list key value))
             (and cost (list :cost cost :estimated t))))))

;;; --- registering the means ----------------------------------------------------------------

(defun register-google-image (agent &key on-image (api-key nil api-key-p) model base-url
                                         read-timeout (name "generate-image") capability source
                                         (qualities *qualities*) default-quality
                                         (default-size :auto) resolve-reference
                                         (max-references 4))
  "Register the generate-image means on AGENT with Google's Gemini API, when there is a key.
Returns NAME, or NIL when there is no key, in which case nothing is registered.

The key is API-KEY when given, NIL included, and otherwise PRAXEON_GOOGLE_API_KEY, then
GEMINI_API_KEY; PRAXEON_IMAGE_API_KEY, the OpenAI provider's, is not read. A given key of NIL or
\"\" is no key, and an empty string is logged at warn. ON-IMAGE, QUALITIES, DEFAULT-QUALITY,
DEFAULT-SIZE, RESOLVE-REFERENCE and MAX-REFERENCES are as for REGISTER; MAX-REFERENCES may be up
to *GOOGLE-MAX-REFERENCES*. MODEL, BASE-URL and READ-TIMEOUT are as for MAKE-GOOGLE-IMAGES."
  (when (and api-key-p (equal api-key ""))
    (log:warn "generate-image not registered: the :api-key given is the empty string"
              :name name :provider "google"))
  (let ((provider (if api-key-p
                      (google-images-from-env :api-key api-key :model model :base-url base-url
                                              :read-timeout read-timeout)
                      (google-images-from-env :model model :base-url base-url
                                              :read-timeout read-timeout))))
    (and provider
         (register agent provider :on-image on-image :name name
                                  :capability capability :source source
                                  :qualities qualities :default-quality default-quality
                                  :default-size default-size
                                  :resolve-reference resolve-reference
                                  :max-references max-references))))
