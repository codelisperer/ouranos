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

(defun %image-reply (&key (octets +image-octets+) (count 1) (format "png") revised-prompt)
  "The JSON text OpenAI's Image API sends for COUNT images of OCTETS."
  (let ((reply (make-hash-table :test #'equal))
        (usage (make-hash-table :test #'equal)))
    (setf (gethash "input_tokens" usage) 50
          (gethash "output_tokens" usage) 1056
          (gethash "total_tokens" usage) 1106)
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
      (is (null (praxeon/image:image-result-cost r)) "OpenAI reports no cost"))
    (destructuring-bind (request-line headers body) (first requests)
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

(test a-request-emits-one-image-usage-event-and-no-cost-it-was-not-given
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
        (is-false (member :cost e) "a cost that was not reported is absent, not 0: ~S" e)))))

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
