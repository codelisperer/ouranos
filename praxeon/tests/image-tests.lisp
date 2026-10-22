;;;; image-tests.lisp --- praxeon/image: the generate-image means and the OpenAI provider (#758).
;;;;
;;;; No request leaves the machine. The OpenAI replies are served from 127.0.0.1 by
;;;; %SERVE-REPLIES (praxeon-tests.lisp) and are built from the shape OpenAI documents for
;;;; POST /v1/images/generations: data[].b64_json, data[].revised_prompt, output_format, size,
;;;; quality and usage. A refusal is the documented 400 with error.code "moderation_blocked" and
;;;; error.moderation_details. None of it was recorded from a live call.
;;;;
;;;; The image bytes are a fixed vector that is not valid UTF-8, with a marker standing for the
;;;; provenance metadata a provider embeds, so a test can see that the bytes reach the app exactly
;;;; as sent.

(cl:in-package #:praxeon/tests)

(def-suite image :description "praxeon/image: the generate-image means (#758)." :in praxeon)
(in-suite image)

(defparameter +image-octets+
  (concatenate '(vector (unsigned-byte 8))
               #(137 80 78 71 13 10 26 10 0 255 254 128)
               (sb-ext:string-to-octets "C2PA-provenance-758" :external-format :utf-8)
               #(0 1 2 3 250 251))
  "The image file the stub provider sends: a PNG signature, bytes that are not UTF-8, and a
marker standing for embedded provenance metadata.")

(defparameter +image-prompt-marker+ "MARKER-758-the-users-image-prompt")

(defun %image-reply (&key (octets +image-octets+) (count 1) (format "png") revised-prompt
                          input-details output-details)
  "The JSON text OpenAI's Image API sends for COUNT images of OCTETS. INPUT-DETAILS and
OUTPUT-DETAILS, when given, are (TEXT-TOKENS IMAGE-TOKENS) for usage.input_tokens_details and
usage.output_tokens_details."
  (let ((reply (make-hash-table :test #'equal))
        (usage (make-hash-table :test #'equal)))
    (setf (gethash "input_tokens" usage) 50
          (gethash "output_tokens" usage) 1056
          (gethash "total_tokens" usage) 1106)
    (loop for (name details) in (list (list "input_tokens_details" input-details)
                                      (list "output_tokens_details" output-details))
          when details
            do (let ((h (make-hash-table :test #'equal)))
                 (setf (gethash "text_tokens" h) (first details)
                       (gethash "image_tokens" h) (second details)
                       (gethash name usage) h)))
    (setf (gethash "created" reply) 1760000000
          (gethash "data" reply)
          (coerce (loop repeat count
                        collect (let ((item (make-hash-table :test #'equal)))
                                  (setf (gethash "b64_json" item)
                                        (cl-base64:usb8-array-to-base64-string octets))
                                  (when revised-prompt
                                    (setf (gethash "revised_prompt" item) revised-prompt))
                                  item))
                  'vector)
          (gethash "output_format" reply) format
          (gethash "size" reply) "1536x1024"
          (gethash "quality" reply) "high"
          (gethash "usage" reply) usage)
    (jzon:stringify reply)))

(defparameter +image-refusal+
  (cons "400 Bad Request"
        (format nil "{\"error\":{\"message\":\"Your request was rejected by the safety system: ~A\",\"type\":\"image_generation_user_error\",\"param\":null,\"code\":\"moderation_blocked\",\"moderation_details\":{\"moderation_stage\":\"input\",\"categories\":[\"violence\"]}}}"
                +image-prompt-marker+))
  "The documented refusal, with the prompt marker where a provider might repeat the request.")

(defun %image-provider (port)
  (praxeon/image:make-openai-images :api-key "sk-test-758"
                                    :base-url (format nil "http://127.0.0.1:~D/v1" port)))

(defun %with-image-server (replies fn)
  "Serve REPLIES and call FN with an OpenAI image provider pointed at them. Returns FN's value
and the requests the server received."
  (multiple-value-bind (port server) (%serve-replies replies)
    (let ((value nil) (requests nil))
      (unwind-protect (setf value (funcall fn (%image-provider port)))
        (setf requests (aion/test-threads:join server :timeout 10)))
      (values value requests))))

(defun %collecting-events (fn)
  "Call FN with an observer bound. Returns FN's value and the events emitted, oldest first."
  (let ((events '()))
    (values (evt:with-observer ((lambda (e) (push e events))) (funcall fn))
            (reverse events))))

;;; --- the request --------------------------------------------------------------------------

(test the-request-body-names-the-model-prompt-shape-and-quality
  (let ((p (praxeon/image:make-openai-images :api-key "k")))
    (let ((body (praxeon/image:openai-image-request-body
                 p (praxeon/image:make-image-request :prompt "a red fox" :size :landscape
                                                     :quality :high :count 2))))
      (is (equal praxeon/image:*openai-image-model* (gethash "model" body)))
      (is (equal "a red fox" (gethash "prompt" body)))
      (is (eql 2 (gethash "n" body)))
      (is (equal "1536x1024" (gethash "size" body)))
      (is (equal "high" (gethash "quality" body))))
    (let ((body (praxeon/image:openai-image-request-body
                 p (praxeon/image:make-image-request :prompt "x" :size "1536x864"))))
      (is (equal "1536x864" (gethash "size" body)) "a WIDTHxHEIGHT string is sent as given")
      (is (equal "auto" (gethash "quality" body))))
    (signals error (praxeon/image:openai-image-request-body
                    p (praxeon/image:make-image-request :prompt "x" :size :huge)))))

;;; --- the reply ----------------------------------------------------------------------------

(test an-image-reaches-the-caller-with-its-bytes-untouched
  "The bytes are the provider's file exactly, provenance marker included, with the media type,
the revised prompt and the size and quality the provider reported."
  (multiple-value-bind (results requests)
      (%with-image-server (list (%image-reply :revised-prompt "a red fox at dusk"))
                          (lambda (p) (praxeon/image:generate-image p "a red fox"
                                                                    :size :landscape)))
    (is (= 1 (length results)))
    (let ((r (first results)))
      (is (equalp +image-octets+ (praxeon/image:image-result-octets r)))
      (is (equal "image/png" (praxeon/image:image-result-media-type r)))
      (is (equal "a red fox at dusk" (praxeon/image:image-result-revised-prompt r)))
      (is (equal "1536x1024" (praxeon/image:image-result-size r)))
      (is (equal "high" (praxeon/image:image-result-quality r)))
      ;; OpenAI reports no cost; the reply's 50 input and 1056 output tokens are not split, so
      ;; each count is priced at the higher of its rates: (50 x 8 + 1056 x 30) / 10^6 dollars.
      (is (eql 401/12500 (praxeon/image:image-result-cost r)) "~S" (praxeon/image:image-result-cost r))
      (is-true (praxeon/image:image-result-cost-estimated-p r)))
    (destructuring-bind (request-line headers body &optional octets) (first requests)
      (declare (ignore octets))
      (is (search "POST /v1/images/generations" request-line) "~A" request-line)
      (is (equal "Bearer sk-test-758" (cdr (assoc "authorization" headers :test #'string=))))
      (is (equal "a red fox" (gethash "prompt" (jzon:parse body)))))))

(test the-media-type-follows-the-output-format
  (let ((results (%with-image-server (list (%image-reply :format "jpeg" :count 2))
                                     (lambda (p) (praxeon/image:generate-image p "x" :count 2)))))
    (is (= 2 (length results)))
    (is (every (lambda (r) (equal "image/jpeg" (praxeon/image:image-result-media-type r)))
               results))))

;;; --- refusal and failure ------------------------------------------------------------------

(test a-content-policy-refusal-is-image-refused
  "The documented moderation_blocked reply is IMAGE-REFUSED, a TOOL-ERROR-RESULT, with the code,
stage and categories. Neither the report nor the text the model sees repeats the provider's
message, which can carry the prompt."
  (let ((c (%with-image-server (list +image-refusal+)
                               (lambda (p)
                                 (handler-case (progn (praxeon/image:generate-image p "x") nil)
                                   (praxeon/image:image-refused (c) c))))))
    (is-true c "no IMAGE-REFUSED was signalled")
    (when c
      (is (typep c 'cnd:tool-error-result))
      (is (equal "moderation_blocked" (praxeon/image:image-refused-code c)))
      (is (equal "input" (praxeon/image:image-refused-stage c)))
      (is (equal '("violence") (praxeon/image:image-refused-categories c)))
      (is (search "refused" (cnd:tool-error-result-text c)))
      (is-false (search +image-prompt-marker+ (princ-to-string c)))
      (is-false (search +image-prompt-marker+ (cnd:tool-error-result-text c))))))

(test any-other-failed-request-is-provider-request-failed
  (let ((c (%with-image-server
            (list (cons "500 Internal Server Error"
                        "{\"error\":{\"type\":\"server_error\",\"code\":\"internal\"}}"))
            (lambda (p)
              (handler-case (progn (praxeon/image:generate-image p "x") nil)
                (cnd:provider-request-failed (c) c))))))
    (is-true c)
    (when c
      (is (eql 500 (cnd:provider-request-failed-status c)))
      (is-false (typep c 'praxeon/image:image-refused)))))

;;; --- usage --------------------------------------------------------------------------------

(test a-request-emits-one-image-usage-event-with-a-cost-marked-estimated
  "OpenAI reports no cost. For the default model, which is in the price table, the event carries
the cost computed from the reported tokens and :ESTIMATED T, so a ledger can tell it from a cost
the provider reported."
  (let ((events (nth-value 1 (%collecting-events
                              (lambda ()
                                (%with-image-server (list (%image-reply))
                                                    (lambda (p)
                                                      (praxeon/image:generate-image p "x"))))))))
    (let ((usage (remove :image-usage events :key #'evt:event-type :test-not #'eq)))
      (is (= 1 (length usage)) "events: ~S" events)
      (let ((e (first usage)))
        (is (equal "openai" (getf e :provider)))
        (is (equal praxeon/image:*openai-image-model* (getf e :model)))
        (is (eql 1 (getf e :count)))
        (is (equal "1536x1024" (getf e :size)))
        (is (equal "high" (getf e :quality)))
        (is (eql 50 (getf e :input-tokens)))
        (is (eql 1056 (getf e :output-tokens)))
        (is (eql 401/12500 (getf e :cost)) "~S" e)
        (is (eq t (getf e :estimated)) "~S" e)))))

(test a-model-with-no-price-row-has-no-cost-rather-than-0
  (multiple-value-bind (port server) (%serve-replies (list (%image-reply)))
    (let ((events '()) (results nil))
      (unwind-protect
           (setf events (nth-value 1 (%collecting-events
                                      (lambda ()
                                        (setf results
                                              (praxeon/image:generate-image
                                               (praxeon/image:make-openai-images
                                                :api-key "k" :model "an-unpriced-model"
                                                :base-url (format nil "http://127.0.0.1:~D/v1" port))
                                               "x"))))))
        (aion/test-threads:join server :timeout 10))
      (let ((e (find :image-usage events :key #'evt:event-type)))
        (is-true e)
        (is-false (member :cost e) "a cost nobody can know is absent, not 0: ~S" e)
        (is-false (member :estimated e) "~S" e))
      (is (null (praxeon/image:image-result-cost (first results))))
      (is-false (praxeon/image:image-result-cost-estimated-p (first results))))))

(test a-refused-request-emits-no-image-usage-event
  (let ((events (nth-value 1 (%collecting-events
                              (lambda ()
                                (%with-image-server
                                 (list +image-refusal+)
                                 (lambda (p)
                                   (handler-case (praxeon/image:generate-image p "x")
                                     (praxeon/image:image-refused () nil)))))))))
    (is-false (find :image-usage events :key #'evt:event-type))))

;;; --- logging ------------------------------------------------------------------------------

(test nothing-of-the-prompt-or-the-image-is-logged
  "Everything logged at debug, for a request that succeeds and one that is refused, is searched
for the prompt, the revised prompt and the image's base64. The log must still show the requests."
  (let ((out (make-string-output-stream))
        (encoded (cl-base64:usb8-array-to-base64-string +image-octets+)))
    (unwind-protect
         (progn
           (aion/log:setup :env :dev :level :debug :stream out)
           (%with-image-server (list (%image-reply :revised-prompt +image-prompt-marker+)
                                     +image-refusal+)
                               (lambda (p)
                                 (praxeon/image:generate-image p +image-prompt-marker+)
                                 (handler-case (praxeon/image:generate-image p +image-prompt-marker+)
                                   (praxeon/image:image-refused () nil)))))
      (aion/log:setup :env :dev :level :warn :stream *standard-output*))
    (let ((logged (get-output-stream-string out)))
      (is (search "image response" logged) "the successful request was not logged")
      (is (search "image request refused" logged) "the refusal was not logged")
      (is-false (search +image-prompt-marker+ logged) "the prompt reached the log")
      (is-false (search (subseq encoded 0 16) logged) "the image's base64 reached the log")
      (is-false (search "sk-test-758" logged) "the API key reached the log"))))

;;; --- keys and registration ----------------------------------------------------------------

(test an-explicit-key-is-used-and-an-explicit-nil-is-no-key
  (with-emb-env (("PRAXEON_IMAGE_API_KEY" "from-the-environment"))
    (is (equal "given" (praxeon/image::openai-images-api-key
                        (praxeon/image:make-openai-images :api-key "given"))))
    (signals cnd:missing-provider-key (praxeon/image:make-openai-images :api-key nil))
    (is (null (praxeon/image:openai-images-from-env :api-key nil)))
    (is (equal "from-the-environment"
               (praxeon/image::openai-images-api-key (praxeon/image:make-openai-images))))))

(test without-a-key-nothing-is-registered
  (with-emb-env (("PRAXEON_IMAGE_API_KEY" nil) ("PRAXEON_OPENAI_API_KEY" nil))
    (let ((ag (actor:make-agent :name "a" :provider (make-instance 'scripted :script '()))))
      (is (null (praxeon/image:register-openai-image ag :on-image #'identity)))
      (is (zerop (hash-table-count (actor:agent-means ag)))))))

(test with-a-key-the-means-is-registered
  (let ((ag (actor:make-agent :name "a" :provider (make-instance 'scripted :script '()))))
    (is (equal "generate-image"
               (praxeon/image:register-openai-image ag :api-key "k" :on-image #'identity)))
    (is (gethash "generate-image" (actor:agent-means ag)))
    (is (null (praxeon/image:register-openai-image ag :api-key nil :on-image #'identity))
        "an explicit NIL key registers nothing")))

(test registering-without-on-image-is-refused
  (let ((ag (actor:make-agent :name "a" :provider (make-instance 'scripted :script '()))))
    (signals error (praxeon/image:register ag (praxeon/image:make-openai-images :api-key "k")))))

;;; --- the means in a turn ------------------------------------------------------------------

(defun %image-turn (reply on-image &key (call-args (list "prompt" "a red fox" "size" "landscape"))
                                         register-args)
  "Run a turn in which the model calls generate-image once, with CALL-ARGS, and then answers,
with REPLY served as the provider's answer. REGISTER-ARGS go to REGISTER. Returns the final
text, the events, the images ON-IMAGE received, and the requests the server received."
  (let ((received '()) (value nil))
    (multiple-value-bind (port server) (%serve-replies (list reply))
      (let ((requests nil))
        (unwind-protect
             (let ((ag (actor:make-agent
                        :name "designer"
                        :provider (make-instance
                                   'scripted
                                   :script (list (%call-completion "generate-image"
                                                                   (apply #'%args call-args))
                                                 (llm:make-completion :text "Here it is."
                                                                      :stop-reason :end))))))
               (apply #'praxeon/image:register ag (%image-provider port)
                      :on-image (lambda (r) (push r received)
                                  (funcall on-image r))
                      register-args)
               (setf value (multiple-value-list
                            (%collecting-events (lambda () (actor:run-turn ag "draw a fox"))))))
          (setf requests (aion/test-threads:join server :timeout 10)))
        (values (first value) (second value) (reverse received) requests)))))

(test in-a-turn-the-app-gets-the-image-and-the-model-gets-a-summary
  (multiple-value-bind (text events received)
      (%image-turn (%image-reply :revised-prompt "a red fox at dusk") (constantly "img-1"))
    (is (equal "Here it is." text))
    (is (= 1 (length received)))
    (is (equalp +image-octets+ (praxeon/image:image-result-octets (first received))))
    (is (find :tool-call events :key #'evt:event-type))
    (let ((result (find :tool-result events :key #'evt:event-type)))
      (is-true result)
      (when result
        (let ((content (getf result :content)))
          (is (search "image/png" content) "~A" content)
          (is (search "img-1" content) "the app's reference reaches the model: ~A" content)
          (is (search "a red fox at dusk" content))
          (is-false (search (subseq (cl-base64:usb8-array-to-base64-string +image-octets+) 0 16)
                            content)
                    "the image bytes reached the model")
          (is-false (getf result :is-error)))))))

(test in-a-turn-a-refusal-is-an-error-result-the-model-can-explain
  (multiple-value-bind (text events received) (%image-turn +image-refusal+ (constantly nil))
    (is (equal "Here it is." text) "the turn goes on after a refusal")
    (is (null received) "nothing reached the app")
    (let ((result (find :tool-result events :key #'evt:event-type)))
      (is-true result)
      (when result
        (is (getf result :is-error))
        (is (search "refused" (getf result :content)))
        (is-false (search +image-prompt-marker+ (getf result :content)))))))

(test a-call-without-a-prompt-is-refused-before-any-request
  "No request is made, so no server is started: a request would fail to connect and end the turn."
  (let* ((ag (actor:make-agent
              :name "designer"
              :provider (make-instance 'scripted
                                       :script (list (%call-completion "generate-image"
                                                                       (%args "size" "square"))
                                                     (llm:make-completion :text "Sorry."
                                                                          :stop-reason :end)))))
         (calls 0))
    (praxeon/image:register ag (praxeon/image:make-openai-images
                                :api-key "k" :base-url "http://127.0.0.1:9/v1")
                            :on-image (lambda (r) (declare (ignore r)) (incf calls) nil))
    (multiple-value-bind (text events)
        (%collecting-events (lambda () (actor:run-turn ag "draw something")))
      (is (equal "Sorry." text) "the turn goes on")
      (is (zerop calls))
      (let ((result (find :tool-result events :key #'evt:event-type)))
        (is (and result (getf result :is-error)))
        (is (and result (eq :not-run (getf result :outcome))))))))

(defun %unexpected-reply-condition (reply)
  "Serve REPLY and return the condition GENERATE-IMAGE signals, or NIL when it signals none."
  (%with-image-server (list reply)
                      (lambda (p)
                        (handler-case (progn (praxeon/image:generate-image p "x") nil)
                          (error (c) c)))))

(test a-reply-of-an-unexpected-shape-is-provider-request-failed
  "Each of these 200 replies is not what OpenAI documents. Each must be PROVIDER-REQUEST-FAILED,
which praxeon handles, never an untyped error that ends the turn."
  (dolist (reply (list "{\"created\":1,\"data\":[]}"              ; no images
                       "{\"created\":1}"                           ; no data at all
                       "{\"data\":\"not a list\"}"
                       "{\"data\":[\"not an object\"]}"
                       "{\"data\":[{\"b64_json\":\"%%% not base64 %%%\"}]}"
                       "[1,2,3]"
                       "<html>not JSON</html>"))
    (let ((c (%unexpected-reply-condition reply)))
      (is (typep c 'cnd:provider-request-failed) "~S gave ~S" reply c))))

(test a-long-revised-prompt-is-cut-in-what-the-model-sees
  (let ((long (make-string 2000 :initial-element #\a)))
    (multiple-value-bind (text events received)
        (%image-turn (%image-reply :revised-prompt long) (constantly "img-1"))
      (declare (ignore text))
      (is (equal long (praxeon/image:image-result-revised-prompt (first received)))
          "the app gets the whole revised prompt")
      (let ((content (getf (find :tool-result events :key #'evt:event-type) :content)))
        (is (< (length content) 1000) "~D characters reached the model" (length content))
        (is (search "cut at 400 of 2000 characters" content) "~A" content)))))

(test a-prompt-of-only-whitespace-is-refused-before-any-request
  (let ((ag (actor:make-agent
             :name "designer"
             :provider (make-instance 'scripted
                                      :script (list (%call-completion
                                                     "generate-image"
                                                     (%args "prompt" (format nil " ~C~C~C " #\Tab #\Newline #\Return)))
                                                    (llm:make-completion :text "Sorry."
                                                                         :stop-reason :end))))))
    (praxeon/image:register ag (praxeon/image:make-openai-images
                                :api-key "k" :base-url "http://127.0.0.1:9/v1")
                            :on-image #'identity)
    (let ((result (find :tool-result (nth-value 1 (%collecting-events
                                                   (lambda () (actor:run-turn ag "draw"))))
                        :key #'evt:event-type)))
      (is (and result (eq :not-run (getf result :outcome)))))))

(test the-default-model-is-the-current-gpt-image-model
  "gpt-image-1 shuts down on 2026-10-23. The default must not be a model OpenAI has retired."
  (is (equal "gpt-image-2.5-flare" praxeon/image:*openai-image-model*)))

;;; --- the app bounds the cost (review of #775) ---------------------------------------------

(defun %schema-enum (agent property)
  (coerce (gethash "enum" (gethash property (gethash "properties"
                                                     (actor::means-entry-schema
                                                      (gethash "generate-image"
                                                               (actor:agent-means agent))))))
          'list))

(test the-schema-offers-only-the-qualities-the-app-allows
  (let ((ag (actor:make-agent :name "a" :provider (make-instance 'scripted :script '()))))
    (praxeon/image:register ag (praxeon/image:make-openai-images :api-key "k")
                            :on-image #'identity :qualities '(:low :medium)
                            :default-quality :low :default-size :square)
    (is (equal '("low" "medium") (%schema-enum ag "quality")))
    (is (equal '("square" "portrait" "landscape" "auto") (%schema-enum ag "size")))))

(test registering-a-default-quality-the-app-does-not-allow-is-refused
  (let ((ag (actor:make-agent :name "a" :provider (make-instance 'scripted :script '())))
        (p (praxeon/image:make-openai-images :api-key "k")))
    (signals error (praxeon/image:register ag p :on-image #'identity :qualities '(:low)
                                                :default-quality :high))
    (signals error (praxeon/image:register ag p :on-image #'identity :qualities '(:ultra)))
    (signals error (praxeon/image:register ag p :on-image #'identity :qualities '()))
    (signals error (praxeon/image:register ag p :on-image #'identity :default-size :huge))
    (is (zerop (hash-table-count (actor:agent-means ag))) "nothing was registered")))

(test a-quality-the-app-does-not-allow-is-refused-before-any-request
  "No server is started: the provider points at a closed port, so a request would end the turn
with a failure to connect rather than the :NOT-RUN result asserted here."
  (let ((ag (actor:make-agent
             :name "designer"
             :provider (make-instance 'scripted
                                      :script (list (%call-completion
                                                     "generate-image"
                                                     (%args "prompt" "a fox" "quality" "high"))
                                                    (llm:make-completion :text "Sorry."
                                                                         :stop-reason :end)))))
        (calls 0))
    (praxeon/image:register ag (praxeon/image:make-openai-images
                                :api-key "k" :base-url "http://127.0.0.1:9/v1")
                            :on-image (lambda (r) (declare (ignore r)) (incf calls) nil)
                            :qualities '(:low :medium))
    (multiple-value-bind (text events)
        (%collecting-events (lambda () (actor:run-turn ag "draw a fox")))
      (is (equal "Sorry." text) "the turn goes on")
      (is (zerop calls))
      (let ((result (find :tool-result events :key #'evt:event-type)))
        (is (and result (getf result :is-error)))
        (is (and result (eq :not-run (getf result :outcome))))
        (is (and result (search "low, medium" (getf result :content)))
            "the model is told the allowed values: ~S" result))
      (is-false (find :image-usage events :key #'evt:event-type)))))

(test with-no-quality-named-the-app-default-is-sent
  (multiple-value-bind (text events received requests)
      (%image-turn (%image-reply) (constantly nil)
                   :call-args (list "prompt" "a fox")
                   :register-args (list :qualities '(:low :medium) :default-quality :low
                                        :default-size :portrait))
    (declare (ignore text events received))
    (let ((body (jzon:parse (third (first requests)))))
      (is (equal "low" (gethash "quality" body)))
      (is (equal "1024x1536" (gethash "size" body))))))

;;; --- a busy, failing or silent service keeps the turn alive -------------------------------

(defparameter +image-rate-limited+
  (list "429 Too Many Requests"
        "{\"error\":{\"type\":\"rate_limit_error\",\"code\":\"rate_limit_exceeded\"}}"
        '(("Retry-After" . "30"))))

(test a-429-is-image-request-failed-with-the-retry-after-seconds
  (let ((c (%with-image-server (list +image-rate-limited+)
                               (lambda (p)
                                 (handler-case (progn (praxeon/image:generate-image p "x") nil)
                                   (praxeon/image:image-request-failed (c) c))))))
    (is-true c "no IMAGE-REQUEST-FAILED was signalled")
    (when c
      (is (typep c 'cnd:provider-request-failed) "a caller that handled the old condition still does")
      (is (eq :rate-limited (praxeon/image:image-request-failed-kind c)))
      (is (eql 30 (praxeon/image:image-request-failed-retry-after c)))
      (is (eql 429 (cnd:provider-request-failed-status c))))))

(test a-5xx-is-image-request-failed-of-kind-server-error
  (let ((c (%with-image-server
            (list (cons "503 Service Unavailable" "{\"error\":{\"type\":\"server_error\"}}"))
            (lambda (p)
              (handler-case (progn (praxeon/image:generate-image p "x") nil)
                (praxeon/image:image-request-failed (c) c))))))
    (is-true c)
    (when c
      (is (eq :server-error (praxeon/image:image-request-failed-kind c)))
      (is (null (praxeon/image:image-request-failed-retry-after c))))))

(test a-400-that-is-not-a-refusal-is-not-image-request-failed
  "Trying again later would not fix a bad request, so it stays a plain PROVIDER-REQUEST-FAILED
and still ends the turn."
  (let ((c (%with-image-server
            (list (cons "400 Bad Request"
                        "{\"error\":{\"type\":\"invalid_request_error\",\"code\":\"invalid_value\"}}"))
            (lambda (p)
              (handler-case (progn (praxeon/image:generate-image p "x") nil)
                (cnd:provider-request-failed (c) c))))))
    (is (typep c 'cnd:provider-request-failed))
    (is-false (typep c 'praxeon/image:image-request-failed))))

(test in-a-turn-a-429-is-an-error-result-that-names-the-wait
  (multiple-value-bind (text events received) (%image-turn +image-rate-limited+ (constantly nil))
    (is (equal "Here it is." text) "the turn goes on after a 429")
    (is (null received))
    (let ((result (find :tool-result events :key #'evt:event-type)))
      (is-true result)
      (when result
        (is (getf result :is-error))
        (is (eq :not-run (getf result :outcome)) "a 429 did no work")
        (is (search "busy" (getf result :content)) "~A" (getf result :content))
        (is (search "about 30 seconds" (getf result :content)) "~A" (getf result :content))))
    (is-false (find :image-usage events :key #'evt:event-type))))

(defun %serve-silence (seconds)
  "Listen on 127.0.0.1 at a free port, accept one connection, and hold it for SECONDS without
answering. Returns the port and the thread."
  (let ((listener (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (setf (sb-bsd-sockets:sockopt-reuse-address listener) t)
    (sb-bsd-sockets:socket-bind listener #(127 0 0 1) 0)
    (sb-bsd-sockets:socket-listen listener 1)
    (values
     (nth-value 1 (sb-bsd-sockets:socket-name listener))
     (sb-thread:make-thread
      (lambda ()
        (unwind-protect
             (let ((socket (sb-bsd-sockets:socket-accept listener)))
               (sleep seconds)
               (sb-bsd-sockets:socket-close socket)
               :held)
          (sb-bsd-sockets:socket-close listener)))
      :name "praxeon-tests image silence"))))

(test a-service-that-does-not-answer-in-the-read-timeout-keeps-the-turn-alive
  "The server accepts and never answers. With a read timeout of 1 second the request must fail
well before the server lets go after 9, so the elapsed time shows the timeout was what ended it."
  (multiple-value-bind (port server) (%serve-silence 9)
    (let* ((ag (actor:make-agent
                :name "designer"
                :provider (make-instance 'scripted
                                         :script (list (%call-completion "generate-image"
                                                                         (%args "prompt" "a fox"))
                                                       (llm:make-completion :text "Here it is."
                                                                            :stop-reason :end)))))
           (start (get-internal-real-time)))
      (unwind-protect
           (progn
             (praxeon/image:register ag (praxeon/image:make-openai-images
                                         :api-key "k" :read-timeout 1
                                         :base-url (format nil "http://127.0.0.1:~D/v1" port))
                                     :on-image #'identity)
             (multiple-value-bind (text events)
                 (%collecting-events (lambda () (actor:run-turn ag "draw a fox")))
               (let ((seconds (/ (- (get-internal-real-time) start)
                                 internal-time-units-per-second))
                     (result (find :tool-result events :key #'evt:event-type)))
                 (is (equal "Here it is." text) "the turn goes on after a timeout")
                 (is (< seconds 7) "the request took ~,1F seconds; the read timeout did not end it"
                     seconds)
                 (is (and result (getf result :is-error)))
                 (is (and result (eq :unknown (getf result :outcome)))
                     "the request may have reached the service: ~S" result)
                 (is (and result (search "did not answer" (getf result :content)))))))
        (aion/test-threads:join server :timeout 15)))))

;;; --- bounds -------------------------------------------------------------------------------

(test count-is-bounded-to-one-through-ten
  (let ((p (praxeon/image:make-openai-images :api-key "k" :base-url "http://127.0.0.1:9/v1")))
    (signals type-error (praxeon/image:generate-image p "x" :count 0))
    (signals type-error (praxeon/image:generate-image p "x" :count 11))))

(test a-reply-is-read-up-to-24-mb-per-image
  (is (= (* 24 1024 1024) praxeon/image:*max-bytes-per-image*)))

(test the-read-timeout-defaults-to-120-seconds-and-can-be-set
  (is (= 120 (praxeon/image::openai-images-read-timeout
              (praxeon/image:make-openai-images :api-key "k"))))
  (is (= 7 (praxeon/image::openai-images-read-timeout
            (praxeon/image:make-openai-images :api-key "k" :read-timeout 7)))))

;;; --- usage names the call, the principal and the agent ------------------------------------

(test in-a-turn-image-usage-carries-the-call-id-and-the-agent
  (multiple-value-bind (text events) (%image-turn (%image-reply) (constantly nil))
    (declare (ignore text))
    (let ((usage (find :image-usage events :key #'evt:event-type))
          (result (find :tool-result events :key #'evt:event-type)))
      (is-true usage)
      (when (and usage result)
        (is (equal "c1" (getf usage :id)))
        (is (equal (getf result :id) (getf usage :id)) "the same id as the call's :tool-result")
        (is (equal "designer" (getf usage :agent)))
        (is (member :principal usage) "a :principal key, as on :tool-result: ~S" usage)))))

;;; --- an empty key is no key ---------------------------------------------------------------

(test an-empty-api-key-is-no-key
  (with-emb-env (("PRAXEON_IMAGE_API_KEY" "from-the-environment"))
    (signals cnd:missing-provider-key (praxeon/image:make-openai-images :api-key ""))
    (is (null (praxeon/image:openai-images-from-env :api-key "")))
    (let ((ag (actor:make-agent :name "a" :provider (make-instance 'scripted :script '()))))
      (is (null (praxeon/image:register-openai-image ag :api-key "" :on-image #'identity)))
      (is (zerop (hash-table-count (actor:agent-means ag)))
          "an empty key does not fall back to the environment's"))))

;;; --- the price table (part two of #758) ---------------------------------------------------

(test the-cost-prices-each-reported-part-at-its-own-rate
  "Dollars per million tokens from *OPENAI-IMAGE-PRICES*. Each expected value is worked out by
hand in its comment, so a wrong rate or a wrong formula disagrees with it."
  ;; gpt-image-2.5-flare, split: 50 text x 5 + 0 image x 8 in; 0 text + 1056 image x 30 out.
  ;; (250 + 31680) / 10^6 = 31930 / 10^6.
  (is (eql 3193/100000
           (praxeon/image:openai-image-cost
            "gpt-image-2.5-flare" '(:input-tokens 50 :output-tokens 1056
                                    :input-text-tokens 50 :input-image-tokens 0
                                    :output-text-tokens 0 :output-image-tokens 1056))))
  ;; Not split: 50 in at the higher input rate, 8; 1056 out at the higher output rate, 30.
  ;; (400 + 31680) / 10^6 = 32080 / 10^6.
  (is (eql 401/12500
           (praxeon/image:openai-image-cost "gpt-image-2.5-flare"
                                            '(:input-tokens 50 :output-tokens 1056))))
  ;; gpt-image-1.5 lists a text output price: 20 text x 5 in; 10 text x 10 + 1000 image x 32 out.
  ;; (100 + 100 + 32000) / 10^6 = 32200 / 10^6.
  (is (eql 161/5000
           (praxeon/image:openai-image-cost
            "gpt-image-1.5" '(:input-tokens 20 :output-tokens 1010
                              :input-text-tokens 20 :input-image-tokens 0
                              :output-text-tokens 10 :output-image-tokens 1000))))
  ;; gpt-image-1-mini's image input is $2.50, an exact 5/2: 100 image x 5/2 + 0 text; 0 out.
  (is (eql 1/4000
           (praxeon/image:openai-image-cost
            "gpt-image-1-mini" '(:input-tokens 100 :output-tokens 0
                                 :input-text-tokens 0 :input-image-tokens 100)))))

(test there-is-no-cost-without-a-price-or-without-counts
  (is (null (praxeon/image:openai-image-cost "an-unpriced-model"
                                             '(:input-tokens 50 :output-tokens 1056))))
  (is (null (praxeon/image:openai-image-cost "gpt-image-2.5-flare" '(:input-tokens 50)))
      "no output count")
  (is (null (praxeon/image:openai-image-cost "gpt-image-2.5-flare" '()))))

(test a-reply-that-splits-its-tokens-is-priced-by-part-and-shared-among-its-images
  (multiple-value-bind (results)
      (%with-image-server (list (%image-reply :count 2 :input-details '(50 0)
                                              :output-details '(0 1056)))
                          (lambda (p) (praxeon/image:generate-image p "x" :count 2)))
    (is (= 2 (length results)))
    (is (every (lambda (r) (eql 3193/200000 (praxeon/image:image-result-cost r))) results)
        "each of 2 images carries half of 3193/100000: ~S"
        (mapcar #'praxeon/image:image-result-cost results))))

(defun %upstream-entries ()
  "The entries of the tree's upstream.sexp, read with *READ-EVAL* off, as the checker reads it."
  (with-open-file (in (asdf:system-relative-pathname :praxeon "../upstream.sexp"))
    (let ((*read-eval* nil))
      (loop for form = (read in nil in) until (eq form in) collect form))))

(test every-price-row-has-an-upstream-entry-with-a-review-date
  "A row added to *OPENAI-IMAGE-PRICES* without an upstream.sexp entry would be a price nobody
recorded reading. Each row needs \"OpenAI image prices: MODEL\" with a :reviewed date, and every
rate a row lists must be a positive rational."
  (let ((entries (%upstream-entries)))
    (is (plusp (length praxeon/image:*openai-image-prices*)))
    (dolist (row praxeon/image:*openai-image-prices*)
      (let* ((name (format nil "OpenAI image prices: ~A" (car row)))
             (entry (find name entries :key (lambda (e) (getf e :name)) :test #'equal)))
        (is-true entry "no upstream.sexp entry named ~S" name)
        (is (stringp (getf entry :reviewed)) "~S has no :reviewed date" name)
        (dolist (key '(:text-input :image-input :image-output))
          (is (typep (getf (cdr row) key) '(rational (0))) "~A ~S" (car row) key))))))

(test a-model-past-its-shutdown-date-is-still-priced
  "A cost is worked out for a request that already happened, so a shutdown date in upstream.sexp
does not stop a model being priced. gpt-image-1's entry says it shuts down on 2026-10-23.
100 input tokens unsplit at the higher input rate, 10, and 1000 output at 40:
(1000 + 40000) / 10^6 = 41/1000 dollars."
  (let ((entry (find "OpenAI image prices: gpt-image-1" (%upstream-entries)
                     :key (lambda (e) (getf e :name)) :test #'equal)))
    (is (equal "2026-10-23" (getf entry :retires)) "~S" entry))
  (is (eql 41/1000 (praxeon/image:openai-image-cost "gpt-image-1"
                                                    '(:input-tokens 100 :output-tokens 1000)))))

;;; --- reference images: edits and variations (part three of #758) ---------------------------
;;;
;;; The edit request is the multipart/form-data OpenAI documents for POST /v1/images/edits: the
;;; fields model, prompt, n, size and quality, one image[] part per reference image, and a mask
;;; part. The test server keeps the body's octets, so each file part is compared byte for byte.

(defun %octets (&rest parts)
  "One octet vector of PARTS, each a vector of bytes or a string encoded as ASCII."
  (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (dolist (p parts (coerce out '(simple-array (unsigned-byte 8) (*))))
      (loop for b across (if (stringp p) (sb-ext:string-to-octets p :external-format :ascii) p)
            do (vector-push-extend b out)))))

(defun %be32 (n)
  (vector (ldb (byte 8 24) n) (ldb (byte 8 16) n) (ldb (byte 8 8) n) (ldb (byte 8 0) n)))

(defun %png (width height &key (color-type 6) trns)
  "The start of a PNG file: its signature, an IHDR chunk for WIDTH x HEIGHT with COLOR-TYPE (6 is
colour with alpha, 2 colour without), a tRNS chunk when TRNS, then an empty IDAT and an IEND. The
checksums are zeros: the code reads the header, it does not decode the image."
  (%octets #(137 80 78 71 13 10 26 10)
           (%be32 13) "IHDR" (%be32 width) (%be32 height) (vector 8 color-type 0 0 0) (%be32 0)
           (if trns (%octets (%be32 2) "tRNS" #(0 0) (%be32 0)) #())
           (%be32 0) "IDAT" (%be32 0)
           (%be32 0) "IEND" (%be32 0)))

(defparameter +jpeg-octets+ (%octets #(255 216 255 224) "JFIF-marker-758" #(255 217)))
(defparameter +webp-octets+ (%octets "RIFF" #(20 0 0 0) "WEBPVP8 " "marker-758"))

(defun %ref (octets &optional (name "image"))
  (praxeon/image:make-reference-image octets :name name))

(defun %multipart-parts (octets boundary)
  "The parts of the multipart/form-data body OCTETS, split at BOUNDARY, as a list of
(HEADERS-TEXT . CONTENT-OCTETS)."
  (let ((marker (sb-ext:string-to-octets (format nil "--~A" boundary) :external-format :ascii))
        (crlf2 (%octets (string #\Return) (string #\Newline) (string #\Return) (string #\Newline)))
        (parts '()))
    (loop for start = (search marker octets) then next
          for next = (and start (search marker octets :start2 (+ start (length marker))))
          while next
          do (let* ((part (subseq octets (+ start (length marker) 2) (- next 2)))
                    (split (search crlf2 part)))
               (push (cons (sb-ext:octets-to-string (subseq part 0 split) :external-format :latin-1)
                           (subseq part (+ split 4)))
                     parts)))
    (nreverse parts)))

(defun %part-named (parts name)
  "The parts whose Content-Disposition names NAME."
  (remove-if-not (lambda (p) (search (format nil "name=\"~A\"" name) (car p))) parts))

(defun %edit-request (requests)
  "The request line, the boundary and the parts of the one request REQUESTS holds."
  (destructuring-bind (request-line headers body octets) (first requests)
    (declare (ignore body))
    (let* ((type (cdr (assoc "content-type" headers :test #'string=)))
           (boundary (subseq type (+ (search "boundary=" type) (length "boundary=")))))
      (values request-line type (%multipart-parts octets boundary)))))

(test a-reference-image-takes-its-media-type-from-its-own-bytes
  (is (equal "image/png" (praxeon/image:reference-image-media-type (%ref (%png 4 4)))))
  (is (equal "image/jpeg" (praxeon/image:reference-image-media-type (%ref +jpeg-octets+))))
  (is (equal "image/webp" (praxeon/image:reference-image-media-type (%ref +webp-octets+))))
  (is (equal "photo" (praxeon/image:reference-image-name (%ref +jpeg-octets+ "photo")))
      "the name is kept as given, as a label for refusals; it is never sent"))

(test a-reference-image-that-cannot-be-sent-is-refused-with-the-reason
  (flet ((refusal (fn)
           (handler-case (progn (funcall fn) nil)
             (praxeon/image:image-input-invalid (c) c))))
    (let ((gif (refusal (lambda () (%ref (%octets "GIF89a" #(1 0 1 0)) "anim")))))
      (is (typep gif 'cnd:tool-error-result))
      (is (eq :not-run (and gif (cnd:tool-error-result-outcome gif))))
      (is (search "not a PNG, JPEG or WebP" (and gif (cnd:tool-error-result-text gif)))))
    (is-true (refusal (lambda () (%ref (make-array 0 :element-type '(unsigned-byte 8))))) "empty")
    (let ((praxeon/image:*max-reference-bytes* 16))
      (let ((big (refusal (lambda () (%ref (%png 4 4))))))
        (is (search "over the limit of 16" (and big (cnd:tool-error-result-text big))))))))

(test reference-images-go-to-the-edits-endpoint-as-multipart-byte-for-byte
  "Two reference images, a PNG and a JPEG, sent with the generation fields. The reply reports its
input tokens split, 20 text and 500 image, so the image tokens are priced at the image input
rate: (20 x 5 + 500 x 8 + 1056 x 30) / 10^6 = 35780 / 10^6 dollars for gpt-image-2.5-flare."
  (let ((png (%png 8 6)))
    (multiple-value-bind (results requests)
        (%with-image-server (list (%image-reply :input-details '(20 500)))
                            (lambda (p)
                              (praxeon/image:generate-image
                               p "make the fox blue" :size :landscape :quality :low
                               :references (list (%ref png "fox") (%ref +jpeg-octets+ "style")))))
      (is (= 1 (length results)))
      (is (eql 1789/50000 (praxeon/image:image-result-cost (first results)))
          "~S" (praxeon/image:image-result-cost (first results)))
      (multiple-value-bind (request-line type parts) (%edit-request requests)
        (is (search "POST /v1/images/edits" request-line) "~A" request-line)
        (is (eql 0 (search "multipart/form-data; boundary=" type)) "~A" type)
        (flet ((field (name) (sb-ext:octets-to-string (cdr (first (%part-named parts name)))
                                                      :external-format :utf-8)))
          (is (equal praxeon/image:*openai-image-model* (field "model")))
          (is (equal "make the fox blue" (field "prompt")))
          (is (equal "1" (field "n")))
          (is (equal "1536x1024" (field "size")))
          (is (equal "low" (field "quality"))))
        (let ((images (%part-named parts "image[]")))
          (is (= 2 (length images)) "~S" (mapcar #'car parts))
          (is (equalp png (cdr (first images))) "the PNG arrives byte for byte, in order")
          (is (equalp +jpeg-octets+ (cdr (second images))))
          (is (search "filename=\"image-1.png\"" (car (first images))) "~A" (car (first images)))
          (is (search "filename=\"image-2.jpeg\"" (car (second images))) "~A" (car (second images)))
          (is (search "Content-Type: image/png" (car (first images))))
          (is (search "Content-Type: image/jpeg" (car (second images)))))
        (is (null (%part-named parts "mask")) "no mask part when none is given")))))

(test without-references-the-request-is-json-to-generations-as-before
  (multiple-value-bind (results requests)
      (%with-image-server (list (%image-reply)) (lambda (p) (praxeon/image:generate-image p "x")))
    (declare (ignore results))
    (destructuring-bind (request-line headers &rest rest) (first requests)
      (declare (ignore rest))
      (is (search "POST /v1/images/generations" request-line))
      (is (equal "application/json" (cdr (assoc "content-type" headers :test #'string=)))))))

(test a-mask-is-sent-after-the-references
  (let ((image (%png 8 6 :color-type 2))
        (mask (%png 8 6)))
    (multiple-value-bind (results requests)
        (%with-image-server (list (%image-reply))
                            (lambda (p)
                              (praxeon/image:generate-image p "replace the sky"
                                                            :references (list (%ref image))
                                                            :mask (%ref mask "mask"))))
      (declare (ignore results))
      (multiple-value-bind (request-line type parts) (%edit-request requests)
        (declare (ignore request-line type))
        (is (equalp mask (cdr (first (%part-named parts "mask")))))
        (is (eq (first (%part-named parts "mask")) (car (last parts))) "the mask is the last part")))))

(test a-mask-that-cannot-apply-is-refused-before-any-request
  "Each of these signals IMAGE-INPUT-INVALID from GENERATE-IMAGE before any request: the provider
points at a closed port, so a request would fail to connect instead."
  (let ((p (praxeon/image:make-openai-images :api-key "k" :base-url "http://127.0.0.1:9/v1")))
    (flet ((reason (&rest args)
             (handler-case (progn (apply #'praxeon/image:generate-image p "x" args) "no refusal")
               (praxeon/image:image-input-invalid (c) (cnd:tool-error-result-text c)))))
      (is (search "no reference image" (reason :mask (%ref (%png 8 6)))))
      (is (search "must both be PNG" (reason :references (list (%ref +jpeg-octets+))
                                             :mask (%ref (%png 8 6)))))
      (is (search "must be the same size" (reason :references (list (%ref (%png 8 6)))
                                                  :mask (%ref (%png 8 5)))))
      (is (search "no alpha channel" (reason :references (list (%ref (%png 8 6)))
                                             :mask (%ref (%png 8 6 :color-type 2)))))
      (let ((praxeon/image:*max-references* 2))
        (is (search "at most 2" (reason :references (list (%ref (%png 1 1)) (%ref (%png 1 1))
                                                          (%ref (%png 1 1))))))))))

(test a-mask-whose-transparency-is-a-trns-chunk-has-an-alpha-channel
  "A palette or colour PNG can carry its transparency in a tRNS chunk rather than in its colour
type. That counts as an alpha channel, so this mask passes the checks."
  (is (null (praxeon/image::%check-inputs (list (%ref (%png 8 6 :color-type 2)))
                                          (%ref (%png 8 6 :color-type 2 :trns t)))))
  (is (eq t (nth-value 2 (praxeon/image::%png-info (%png 8 6 :color-type 2 :trns t)))))
  (is (null (nth-value 2 (praxeon/image::%png-info (%png 8 6 :color-type 2))))))

(defun %references-agent (call-args resolve &key (max-references 4) (base-url nil))
  "An agent whose model calls generate-image once with CALL-ARGS and then answers, registered
with RESOLVE as :RESOLVE-REFERENCE, against BASE-URL, or a closed port when none is given so that
any request fails to connect. Returns the agent."
  (let ((ag (actor:make-agent
             :name "designer"
             :provider (make-instance 'scripted
                                      :script (list (%call-completion "generate-image"
                                                                      (apply #'%args call-args))
                                                    (llm:make-completion :text "Done."
                                                                         :stop-reason :end))))))
    (praxeon/image:register ag (praxeon/image:make-openai-images
                                :api-key "k" :base-url (or base-url "http://127.0.0.1:9/v1"))
                            :on-image (constantly "img-2") :resolve-reference resolve
                            :max-references max-references)
    ag))

(test the-schema-offers-reference-images-only-with-a-resolver
  (let ((with (actor:make-agent :name "a" :provider (make-instance 'scripted :script '())))
        (without (actor:make-agent :name "b" :provider (make-instance 'scripted :script '()))))
    (praxeon/image:register with (praxeon/image:make-openai-images :api-key "k")
                            :on-image #'identity :resolve-reference (constantly nil)
                            :max-references 3)
    (praxeon/image:register without (praxeon/image:make-openai-images :api-key "k")
                            :on-image #'identity)
    (flet ((property (agent)
             (gethash "reference_images"
                      (gethash "properties"
                               (actor::means-entry-schema
                                (gethash "generate-image" (actor:agent-means agent)))))))
      (is (eql 3 (gethash "maxItems" (property with))))
      (is (null (property without)) "no resolver, no reference_images"))
    (signals error (praxeon/image:register with (praxeon/image:make-openai-images :api-key "k")
                                           :on-image #'identity :max-references 17))))

(test in-a-turn-the-model-edits-an-image-it-names-by-its-reference
  "The model names img-1, which the app resolves to a PNG; the request to /images/edits carries
exactly those bytes, and the app receives the new image."
  (let ((png (%png 8 6))
        (asked '()))
    (multiple-value-bind (port server) (%serve-replies (list (%image-reply)))
      (let ((requests nil) (text nil) (events nil))
        (unwind-protect
             (let ((ag (%references-agent
                        (list "prompt" "make it blue" "reference_images" (vector "img-1"))
                        (lambda (ref) (push ref asked)
                          (and (equal ref "img-1") (%ref png "img-1")))
                        :base-url (format nil "http://127.0.0.1:~D/v1" port))))
               (multiple-value-setq (text events)
                 (%collecting-events (lambda () (actor:run-turn ag "make my fox blue")))))
          (setf requests (aion/test-threads:join server :timeout 10)))
        (is (equal "Done." text))
        (is (equal '("img-1") asked))
        (multiple-value-bind (request-line type parts) (%edit-request requests)
          (declare (ignore type))
          (is (search "/v1/images/edits" request-line))
          (is (equalp png (cdr (first (%part-named parts "image[]"))))))
        (let ((result (find :tool-result events :key #'evt:event-type)))
          (is (and result (not (getf result :is-error))) "~S" result))
        (is (eql 1 (getf (find :image-usage events :key #'evt:event-type) :references))
            "the usage event of an edit counts its references")))))

(test in-a-turn-a-reference-named-twice-is-resolved-and-sent-once
  (let ((asked '()))
    (multiple-value-bind (port server) (%serve-replies (list (%image-reply)))
      (let ((requests nil))
        (unwind-protect
             (let ((ag (%references-agent
                        (list "prompt" "x" "reference_images" (vector "img-1" "img-1"))
                        (lambda (ref) (push ref asked) (%ref (%png 2 2) ref))
                        :max-references 1
                        :base-url (format nil "http://127.0.0.1:~D/v1" port))))
               (%collecting-events (lambda () (actor:run-turn ag "x"))))
          (setf requests (aion/test-threads:join server :timeout 10)))
        (is (equal '("img-1") asked) "resolved once, and within a limit of 1: ~S" asked)
        (multiple-value-bind (request-line type parts) (%edit-request requests)
          (declare (ignore request-line type))
          (is (= 1 (length (%part-named parts "image[]")))))))))

(test in-a-turn-a-resolver-that-returns-something-else-is-refused-as-a-result
  "A resolver that returns a pathname, say, instead of a REFERENCE-IMAGE is the app's mistake,
but it must not end the turn with an untyped error."
  (let* ((ag (%references-agent (list "prompt" "x" "reference_images" (vector "img-1"))
                                (constantly #p"/tmp/img-1.png")))
         (events (nth-value 1 (%collecting-events (lambda () (actor:run-turn ag "x"))))))
    (let ((result (find :tool-result events :key #'evt:event-type)))
      (is (and result (eq :not-run (getf result :outcome))) "~S" result)
      (is (search "could not be read" (getf result :content)) "~A" (getf result :content)))))

(test the-file-name-sent-is-praxeons-not-the-callers
  "A name with a quote and a line break, as an app or a model might supply, never reaches the
part's header; the provider is given image-1.png."
  (multiple-value-bind (results requests)
      (%with-image-server (list (%image-reply))
                          (lambda (p)
                            (praxeon/image:generate-image
                             p "x" :references (list (%ref (%png 2 2)
                                                           (format nil "a\"b~%Content-Type: text/html"))))))
    (declare (ignore results))
    (multiple-value-bind (request-line type parts) (%edit-request requests)
      (declare (ignore request-line type))
      (let ((header (car (first (%part-named parts "image[]")))))
        (is (search "filename=\"image-1.png\"" header) "~A" header)
        (is-false (search "text/html" header) "~A" header)))))

(test a-prompt-cannot-add-a-field-of-its-own
  "The prompt carries what would end its part and start a quality part, if the boundary matched.
The boundary is chosen to occur in no field or file, so the body still has one quality field,
the one praxeon set, and the prompt arrives whole."
  (let ((prompt (format nil "a fox~C~C--praxeon-0~C~CContent-Disposition: form-data; name=\"quality\"~C~C~C~Chigh"
                        #\Return #\Newline #\Return #\Newline #\Return #\Newline #\Return #\Newline)))
    (multiple-value-bind (results requests)
        (%with-image-server (list (%image-reply))
                            (lambda (p)
                              (praxeon/image:generate-image p prompt :quality :low
                                                            :references (list (%ref (%png 2 2))))))
      (declare (ignore results))
      (multiple-value-bind (request-line type parts) (%edit-request requests)
        (declare (ignore request-line))
        (is-false (search (subseq type (+ (search "boundary=" type) 9)) prompt))
        (let ((quality (%part-named parts "quality")))
          (is (= 1 (length quality)) "~D quality parts" (length quality))
          (is (equal "low" (sb-ext:octets-to-string (cdr (first quality)) :external-format :utf-8))))
        (is (equal prompt (sb-ext:octets-to-string (cdr (first (%part-named parts "prompt")))
                                                   :external-format :utf-8)))))))

(test a-boundary-that-occurs-in-the-prompt-or-a-file-is-not-used
  "An edit body whose prompt contains praxeon-clash-1 and whose image contains praxeon-clash-2 is
encoded with boundaries proposed in that order and then praxeon-clean-3. The body must use the
third. Without the check on field values it would use the first, and the prompt could end its
own part and start another."
  (let* ((image (%ref (%octets (%png 2 2) "praxeon-clash-2")))
         (body (praxeon/image:openai-image-edit-body
                (praxeon/image:make-openai-images :api-key "k")
                (praxeon/image:make-image-request :prompt "draw --praxeon-clash-1 please"
                                                  :references (list image))))
         (proposals (list "praxeon-clash-1" "praxeon-clash-2" "praxeon-clean-3"))
         (asked 0))
    (multiple-value-bind (octets type)
        (praxeon/image::%multipart body (lambda () (incf asked) (pop proposals)))
      (is (equal "multipart/form-data; boundary=praxeon-clean-3" type) "~A" type)
      (is (= 3 asked) "each clashing proposal was refused in turn")
      (is (equal "draw --praxeon-clash-1 please"
                 (sb-ext:octets-to-string
                  (cdr (first (%part-named (%multipart-parts octets "praxeon-clean-3") "prompt")))
                  :external-format :utf-8))
          "the prompt arrives whole in its own part"))))

(test the-reference-images-of-one-request-are-capped-in-total
  (let ((praxeon/image:*max-reference-total-bytes* 100)
        (p (praxeon/image:make-openai-images :api-key "k" :base-url "http://127.0.0.1:9/v1")))
    (let ((text (handler-case (progn (praxeon/image:generate-image
                                      p "x" :references (list (%ref (%png 2 2)) (%ref (%png 2 2))
                                                              (%ref (%png 2 2))))
                                     "no refusal")
                  (praxeon/image:image-input-invalid (c) (cnd:tool-error-result-text c)))))
      (is (search "over the limit of 100 for one request" text) "~A" text))))

(test in-a-turn-a-reference-the-app-does-not-know-is-refused-before-any-request
  (let* ((ag (%references-agent (list "prompt" "edit it" "reference_images" (vector "img-404"))
                                (constantly nil)))
         (events (nth-value 1 (%collecting-events (lambda () (actor:run-turn ag "edit"))))))
    (let ((result (find :tool-result events :key #'evt:event-type)))
      (is (and result (getf result :is-error)))
      (is (and result (eq :not-run (getf result :outcome))))
      (is (search "\"img-404\" is not an image reference" (getf result :content))
          "~A" (getf result :content)))
    (is-false (find :image-usage events :key #'evt:event-type))))

(test in-a-turn-more-references-than-the-app-allows-are-refused
  (let* ((ag (%references-agent (list "prompt" "x" "reference_images" (vector "a" "b" "c"))
                                (lambda (ref) (%ref (%png 1 1) ref))
                                :max-references 2))
         (events (nth-value 1 (%collecting-events (lambda () (actor:run-turn ag "x"))))))
    (let ((result (find :tool-result events :key #'evt:event-type)))
      (is (and result (eq :not-run (getf result :outcome))))
      (is (search "at most 2" (getf result :content)) "~A" (getf result :content)))))

(test in-a-turn-a-resolved-file-that-is-not-an-image-is-refused-with-the-reason
  "The app's resolver returns a GIF, which MAKE-REFERENCE-IMAGE refuses; the model is told why."
  (let* ((ag (%references-agent (list "prompt" "x" "reference_images" (vector "anim"))
                                (lambda (ref) (%ref (%octets "GIF89a" #(1 0)) ref))))
         (events (nth-value 1 (%collecting-events (lambda () (actor:run-turn ag "x"))))))
    (let ((result (find :tool-result events :key #'evt:event-type)))
      (is (and result (eq :not-run (getf result :outcome))))
      (is (search "not a PNG, JPEG or WebP" (getf result :content)) "~A" (getf result :content)))))
