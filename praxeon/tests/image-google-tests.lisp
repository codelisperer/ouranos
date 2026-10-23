;;;; image-google-tests.lisp --- praxeon/image's Google provider (#758).
;;;;
;;;; No request leaves the machine. The Gemini API's replies are served from 127.0.0.1 by
;;;; %SERVE-REPLIES and are built from the shapes Google's generateContent reference documents:
;;;; candidates[].content.parts[] with inlineData (mimeType, data) and the thought flag,
;;;; candidates[].finishReason, promptFeedback.blockReason with safetyRatings, and usageMetadata
;;;; with promptTokenCount, candidatesTokenCount, thoughtsTokenCount and candidatesTokensDetails.
;;;; None of it was recorded from a live call. The image helpers (%PNG, %REF, %IMAGE-BYTES,
;;;; %COLLECTING-EVENTS, %UPSTREAM-ENTRIES) are image-tests.lisp's, which loads first.

(cl:in-package #:praxeon/tests)

(in-suite image)

(defparameter +google-image+ (%image-bytes (%png 4 3) "SynthID-stand-in-758")
  "The image the stub sends: a PNG, with a marker standing for the watermark Google embeds.")

(defparameter +google-interim-image+ (%image-bytes (%png 2 2) "interim-thought-image")
  "An interim image a thinking model sends, marked thought; it must not be the result.")

(defun %google-hash (&rest kvs)
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on kvs by #'cddr do (setf (gethash k h) v))
    h))

(defun %google-image-part (octets &key thought (mime-type "image/png"))
  (let ((part (%google-hash "inlineData"
                            (%google-hash "mimeType" mime-type
                                          "data" (cl-base64:usb8-array-to-base64-string octets)))))
    (when thought (setf (gethash "thought" part) t))
    part))

(defun %google-reply (&key (parts (list (%google-image-part +google-image+)))
                           (finish-reason "STOP") (prompt-tokens 12) (candidate-tokens 1120)
                           (thought-tokens 200) (image-tokens 1120) block-reason ratings)
  "The JSON text the Gemini API sends. With BLOCK-REASON, a blocked prompt and no candidates;
otherwise one candidate with PARTS and FINISH-REASON. IMAGE-TOKENS NIL leaves out the split by
modality."
  (jzon:stringify
   (if block-reason
       (%google-hash "promptFeedback"
                     (%google-hash "blockReason" block-reason
                                   "safetyRatings" (coerce (or ratings '()) 'vector)))
       (%google-hash
        "candidates" (vector (%google-hash "content" (%google-hash "role" "model"
                                                                   "parts" (coerce parts 'vector))
                                           "finishReason" finish-reason
                                           "safetyRatings" (coerce (or ratings '()) 'vector)))
        "usageMetadata" (let ((u (%google-hash "promptTokenCount" prompt-tokens
                                               "candidatesTokenCount" candidate-tokens
                                               "thoughtsTokenCount" thought-tokens
                                               "totalTokenCount" (+ prompt-tokens candidate-tokens
                                                                    thought-tokens))))
                          (when image-tokens
                            (setf (gethash "candidatesTokensDetails" u)
                                  (vector (%google-hash "modality" "IMAGE"
                                                        "tokenCount" image-tokens))))
                          u)))))

(defun %google-provider (port &optional (model praxeon/image:*google-image-model*))
  (praxeon/image:make-google-images :api-key "g-test-758" :model model
                                    :base-url (format nil "http://127.0.0.1:~D/v1" port)))

(defun %with-google-server (replies fn &key (model praxeon/image:*google-image-model*))
  "Serve REPLIES and call FN with a Google provider pointed at them. Returns FN's value and the
requests the server received."
  (multiple-value-bind (port server) (%serve-replies replies)
    (let ((value nil) (requests nil))
      (unwind-protect (setf value (funcall fn (%google-provider port model)))
        (setf requests (aion/test-threads:join server :timeout 10)))
      (values value requests))))

(defun %google-condition (reply &rest args)
  "Serve REPLY, call GENERATE-IMAGE with ARGS, and return the condition it signals, or NIL."
  (%with-google-server (list reply)
                       (lambda (p)
                         (handler-case (progn (apply #'praxeon/image:generate-image p "x" args) nil)
                           (error (c) c)))))

(defun %google-closed-port-provider ()
  "A Google provider pointed at a closed port, for checks that must refuse before any request."
  (praxeon/image:make-google-images :api-key "k" :base-url "http://127.0.0.1:9/v1"))

;;; --- the request ---------------------------------------------------------------------------

(test google-sends-generate-content-with-its-key-and-image-config
  (multiple-value-bind (results requests)
      (%with-google-server (list (%google-reply))
                           (lambda (p) (praxeon/image:generate-image p "a red fox"
                                                                     :size :landscape :quality :low)))
    (is (= 1 (length results)))
    (destructuring-bind (request-line headers body &rest rest) (first requests)
      (declare (ignore rest))
      (is (search "POST /v1/models/gemini-nano-banana-2.1:generateContent" request-line)
          "~A" request-line)
      (is (equal "g-test-758" (cdr (assoc "x-goog-api-key" headers :test #'string=))))
      (is-false (assoc "authorization" headers :test #'string=) "the key is not a bearer token")
      (let* ((json (jzon:parse body))
             (parts (gethash "parts" (aref (gethash "contents" json) 0)))
             (config (gethash "generationConfig" json)))
        (is (equal "a red fox" (gethash "text" (aref parts 0))))
        (is (equalp #("IMAGE") (gethash "responseModalities" config)))
        (is (equal "3:2" (gethash "aspectRatio" (gethash "imageConfig" config))))
        (is (equal "1K" (gethash "imageSize" (gethash "imageConfig" config))))))))

(test google-auto-shape-and-quality-send-no-image-config
  (let ((body (praxeon/image:google-image-request-body
               (praxeon/image:make-google-images :api-key "k")
               (praxeon/image:make-image-request :prompt "x"))))
    (is-false (nth-value 1 (gethash "imageConfig" (gethash "generationConfig" body))))))

(test google-sends-reference-images-as-inline-data-byte-for-byte
  (let ((png (%png 8 6)))
    (multiple-value-bind (results requests)
        (%with-google-server (list (%google-reply))
                             (lambda (p)
                               (praxeon/image:generate-image
                                p "in winter" :references (list (%ref png) (%ref +jpeg-octets+)))))
      (declare (ignore results))
      (let* ((parts (gethash "parts" (aref (gethash "contents" (jzon:parse (third (first requests))))
                                           0)))
             (first-image (gethash "inline_data" (aref parts 1)))
             (second-image (gethash "inline_data" (aref parts 2))))
        (is (= 3 (length parts)) "the prompt, then two images")
        (is (equal "image/png" (gethash "mime_type" first-image)))
        (is (equalp png (cl-base64:base64-string-to-usb8-array (gethash "data" first-image))))
        (is (equal "image/jpeg" (gethash "mime_type" second-image)))
        (is (equalp +jpeg-octets+ (cl-base64:base64-string-to-usb8-array
                                   (gethash "data" second-image))))))))

(test google-refuses-what-it-cannot-send-before-any-request
  "Each of these is refused as IMAGE-INPUT-INVALID before any request: the provider points at a
closed port, so a request would fail to connect instead."
  (let ((p (%google-closed-port-provider)))
    (flet ((reason (&rest args)
             (handler-case (progn (apply #'praxeon/image:generate-image p "x" args) "no refusal")
               (praxeon/image:image-input-invalid (c) (cnd:tool-error-result-text c)))))
      (is (search "takes no mask" (reason :references (list (%ref (%png 8 6)))
                                          :mask (%ref (%png 8 6))))
          "Google's edit takes no mask")
      (is (search "at most 14" (reason :references (loop repeat 15 collect (%ref (%png 1 1))))))
      (is (search "one image per request" (reason :count 2)))
      (is (search "no shape huge" (reason :size :huge))))))

;;; --- the reply -----------------------------------------------------------------------------

(test google-returns-the-final-image-and-skips-interim-thought-images
  "A thinking model sends an interim image marked thought before its result. Only the result is
returned, its bytes untouched, with the media type read from the bytes."
  (let ((results (%with-google-server
                  (list (%google-reply :parts (list (%google-image-part +google-interim-image+
                                                                        :thought t)
                                                    (%google-hash "text" "Here is your fox.")
                                                    (%google-image-part +google-image+))))
                  (lambda (p) (praxeon/image:generate-image p "x")))))
    (is (= 1 (length results)))
    (is (equalp +google-image+ (praxeon/image:image-result-octets (first results))))
    (is (equal "image/png" (praxeon/image:image-result-media-type (first results))))
    (is (equal "google" (praxeon/image:image-result-provider (first results))))))

(test google-a-blocked-prompt-is-image-refused-at-the-input-stage
  (let ((c (%google-condition
            (%google-reply :block-reason "SAFETY"
                           :ratings (list (%google-hash "category" "HARM_CATEGORY_DANGEROUS_CONTENT"
                                                        "probability" "HIGH" "blocked" t)
                                          (%google-hash "category" "HARM_CATEGORY_HARASSMENT"
                                                        "probability" "LOW"))))))
    (is (typep c 'praxeon/image:image-refused) "~S" c)
    (when (typep c 'praxeon/image:image-refused)
      (is (typep c 'cnd:tool-error-result))
      (is (equal "SAFETY" (praxeon/image:image-refused-code c)))
      (is (equal "input" (praxeon/image:image-refused-stage c)))
      (is (equal '("HARM_CATEGORY_DANGEROUS_CONTENT") (praxeon/image:image-refused-categories c))
          "only the categories Google marked blocked"))))

(test google-a-candidate-stopped-for-image-safety-is-image-refused-at-the-output-stage
  (let ((c (%google-condition (%google-reply :parts '() :finish-reason "IMAGE_SAFETY"))))
    (is (typep c 'praxeon/image:image-refused) "~S" c)
    (when (typep c 'praxeon/image:image-refused)
      (is (equal "IMAGE_SAFETY" (praxeon/image:image-refused-code c)))
      (is (equal "output" (praxeon/image:image-refused-stage c))))))

(test google-a-reply-with-no-image-for-another-reason-is-image-not-made
  (let ((c (%google-condition (%google-reply :parts (list (%google-hash "text" "I cannot."))
                                             :finish-reason "NO_IMAGE"))))
    (is (typep c 'praxeon/image:image-not-made) "~S" c)
    (when (typep c 'praxeon/image:image-not-made)
      (is (typep c 'cnd:tool-error-result))
      (is (eq :error (cnd:tool-error-result-outcome c)) "the request ran and may be charged")
      (is (equal "NO_IMAGE" (praxeon/image:image-not-made-reason c)))
      (is (search "No image was made" (cnd:tool-error-result-text c))))))

(test google-a-busy-service-is-image-request-failed
  (let ((c (%google-condition (list "429 Too Many Requests"
                                    "{\"error\":{\"code\":429,\"status\":\"RESOURCE_EXHAUSTED\"}}"
                                    '(("Retry-After" . "12"))))))
    (is (typep c 'praxeon/image:image-request-failed) "~S" c)
    (when (typep c 'praxeon/image:image-request-failed)
      (is (eq :rate-limited (praxeon/image:image-request-failed-kind c)))
      (is (eql 12 (praxeon/image:image-request-failed-retry-after c)))
      (is (search "google images" (princ-to-string c)) "the report names the provider: ~A" c))))

;;; --- cost ----------------------------------------------------------------------------------

(test google-cost-prices-image-output-and-text-and-thinking-at-their-own-rates
  "gemini-nano-banana-2.1: input 1.50, text and thinking output 7.50, image output 30, per 10^6.
12 input + 1120 image + (1120 - 1120 + 200 thinking) text:
(12 x 3/2 + 1120 x 30 + 200 x 15/2) / 10^6 = (18 + 33600 + 1500) / 10^6 = 35118 / 10^6."
  (is (eql 17559/500000
           (praxeon/image:google-image-cost
            "gemini-nano-banana-2.1" '(:input-tokens 12 :output-tokens 1320
                                       :output-image-tokens 1120))))
  ;; Not split by modality: all 1320 output tokens at the higher rate, 30.
  ;; (18 + 39600) / 10^6 = 39618 / 10^6.
  (is (eql 19809/500000
           (praxeon/image:google-image-cost "gemini-nano-banana-2.1"
                                            '(:input-tokens 12 :output-tokens 1320))))
  ;; gemini-3.1-flash-lite-image, the low-cost model: input 1/4, image output 30.
  ;; (100 x 1/4 + 1120 x 30) / 10^6 = 33625 / 10^6.
  (is (eql 269/8000
           (praxeon/image:google-image-cost
            "gemini-3.1-flash-lite-image" '(:input-tokens 100 :output-tokens 1120
                                            :output-image-tokens 1120))))
  (is (null (praxeon/image:google-image-cost "an-unpriced-model"
                                             '(:input-tokens 1 :output-tokens 1)))))

(test google-usage-carries-the-estimated-cost
  (let ((events (nth-value 1 (%collecting-events
                              (lambda ()
                                (%with-google-server (list (%google-reply))
                                                     (lambda (p)
                                                       (praxeon/image:generate-image p "x"))))))))
    (let ((e (find :image-usage events :key #'evt:event-type)))
      (is-true e)
      (when e
        (is (equal "google" (getf e :provider)))
        (is (equal "gemini-nano-banana-2.1" (getf e :model)))
        (is (eql 12 (getf e :input-tokens)))
        (is (eql 1320 (getf e :output-tokens)) "candidates and thinking together")
        (is (eql 17559/500000 (getf e :cost)) "~S" e)
        (is (eq t (getf e :estimated)))))))

(test every-google-price-row-has-an-upstream-entry-with-a-review-date
  (let ((entries (%upstream-entries)))
    (is (plusp (length praxeon/image:*google-image-prices*)))
    (dolist (row praxeon/image:*google-image-prices*)
      (let* ((name (format nil "Google image prices: ~A" (car row)))
             (entry (find name entries :key (lambda (e) (getf e :name)) :test #'equal)))
        (is-true entry "no upstream.sexp entry named ~S" name)
        (is (stringp (getf entry :reviewed)) "~S has no :reviewed date" name)
        (dolist (key '(:input :text-output :image-output))
          (is (typep (getf (cdr row) key) '(rational (0))) "~A ~S" (car row) key))))))

;;; --- keys ----------------------------------------------------------------------------------

(test google-reads-only-its-own-key-variables
  "An app configured for OpenAI must not have its key sent to Google."
  (with-emb-env (("PRAXEON_IMAGE_API_KEY" "openai-key") ("PRAXEON_OPENAI_API_KEY" "openai-key")
                 ("PRAXEON_GOOGLE_API_KEY" nil) ("GEMINI_API_KEY" nil))
    (is (null (praxeon/image:google-images-from-env))
        "PRAXEON_IMAGE_API_KEY and PRAXEON_OPENAI_API_KEY are not Google's")
    (setf (uiop:getenv "GEMINI_API_KEY") "gemini-key")
    (is (equal "gemini-key" (praxeon/image::google-images-api-key
                             (praxeon/image:make-google-images))))
    (setf (uiop:getenv "PRAXEON_GOOGLE_API_KEY") "google-key")
    (is (equal "google-key" (praxeon/image::google-images-api-key
                             (praxeon/image:make-google-images)))
        "PRAXEON_GOOGLE_API_KEY comes first")
    (is (null (praxeon/image:google-images-from-env :api-key "")) "an empty key is no key")))

;;; --- in a turn -----------------------------------------------------------------------------

(test google-in-a-turn-the-app-gets-the-image-and-a-refusal-keeps-the-turn
  (dolist (case (list (list (%google-reply) nil)
                      (list (%google-reply :block-reason "SAFETY") t)))
    (destructuring-bind (reply refused) case
      (let ((received '()))
        (multiple-value-bind (port server) (%serve-replies (list reply))
          (unwind-protect
               (let ((ag (actor:make-agent
                          :name "designer"
                          :provider (make-instance
                                     'scripted
                                     :script (list (%call-completion "generate-image"
                                                                     (%args "prompt" "a fox"))
                                                   (llm:make-completion :text "Done."
                                                                        :stop-reason :end))))))
                 (with-emb-env (("PRAXEON_GOOGLE_API_KEY" nil) ("GEMINI_API_KEY" nil))
                   (is (equal "generate-image"
                              (praxeon/image:register-google-image
                               ag :api-key "g-test-758"
                                  :base-url (format nil "http://127.0.0.1:~D/v1" port)
                                  :on-image (lambda (r) (push r received) "img-1")))))
                 (multiple-value-bind (text events)
                     (%collecting-events (lambda () (actor:run-turn ag "draw a fox")))
                   (is (equal "Done." text))
                   (let ((result (find :tool-result events :key #'evt:event-type)))
                     (if refused
                         (progn (is (null received))
                                (is (and result (getf result :is-error))))
                         (progn (is (= 1 (length received)))
                                (is (and result (not (getf result :is-error)))))))))
            (aion/test-threads:join server :timeout 10)))))))
