;;;; extra-body-tests.lisp --- vendor-specific fields in a provider's request body (#1172)
;;;;
;;;; A provider adds the fields of its :EXTRA-BODY, and of PRAXEON/LLM:*EXTRA-BODY* when it is
;;;; bound, to the JSON body it sends. These tests read the body that is built, and the body a
;;;; stub server receives with and without streaming, because a field that is accepted and then
;;;; left out of the request is the failure that matters: the field can be a request not to
;;;; store the conversation.

(cl:in-package #:praxeon/tests)

(def-suite llm-extra-body
  :description "praxeon/llm: vendor-specific fields in a provider's request body (#1172)."
  :in praxeon)
(in-suite llm-extra-body)

(defparameter +msgs+ '((:role :user :content "hi")))

(defun %anthropic-with (&rest initargs)
  (apply #'make-instance 'llm:anthropic :api-key "k" :model "m" initargs))

(defun %openai-with (&rest initargs)
  (apply #'make-instance 'llm:openai-compatible :base-url "http://x" :model "m" initargs))

(defun %body-json (p)
  "The JSON of the request body P builds for +MSGS+."
  (%json-of (if (typep p 'llm:anthropic)
                (llm:anthropic-request-body p +msgs+)
                (llm:openai-request-body p +msgs+))))

(defun %parsed-body (p)
  (jzon:parse (%body-json p)))

(test a-provider-s-extra-body-reaches-both-request-bodies
  (let ((o (%parsed-body (%openai-with :extra-body "{\"store\": false}")))
        (a (%parsed-body (%anthropic-with :extra-body "{\"metadata\": {\"user_id\": \"u-1\"}}"))))
    (multiple-value-bind (value present) (gethash "store" o)
      (is-true present "store is in the OpenAI body")
      (is (eq nil value) "and it is false"))
    (is (equal "u-1" (gethash "user_id" (gethash "metadata" a))))
    (is (equal "m" (gethash "model" o)) "the fields praxeon builds are still there")))

(test a-nested-field-is-sent-as-the-object-it-was-given
  "OpenRouter's routing setting is an object inside an object."
  (let* ((p (%openai-with :extra-body "{\"provider\": {\"data_collection\": \"deny\", \"zdr\": true}}"))
         (provider (gethash "provider" (%parsed-body p))))
    (is (equal "deny" (gethash "data_collection" provider)))
    (is (eq t (gethash "zdr" provider)))))

(test a-hash-table-is-taken-as-well-as-a-string
  (let ((h (make-hash-table :test #'equal)))
    (setf (gethash "store" h) t)
    (let ((p (%openai-with :extra-body h)))
      (is (eq t (gethash "store" (%parsed-body p))))
      (setf (gethash "store" h) "changed later")
      (is (eq t (gethash "store" (%parsed-body p)))
          "the provider keeps a copy, so changing the table afterwards changes nothing"))))

(test the-per-call-fields-are-added-and-replace-the-provider-s-field-of-the-same-name
  (let ((p (%openai-with :extra-body "{\"store\": true, \"user\": \"app\"}")))
    (let ((body (let ((llm:*extra-body* "{\"store\": false, \"seed\": 7}"))
                  (%parsed-body p))))
      (is (eq nil (gethash "store" body)) "the call's store replaces the provider's")
      (is (equal "app" (gethash "user" body)) "the provider's other field stays")
      (is (eql 7 (gethash "seed" body)) "the call's own field is added"))
    (is (eq t (gethash "store" (%parsed-body p))) "outside the binding, the provider's value")))

(test no-extra-fields-leave-the-request-byte-identical
  "Control for the tests above: a provider made without fields, or with an empty object, builds
the same bytes as before, so no existing caller sees a change."
  (let ((plain (%body-json (%openai-with))))
    (is (string= plain (%body-json (%openai-with :extra-body "{}"))))
    (is (string= plain (let ((llm:*extra-body* "{}")) (%body-json (%openai-with))))))
  (is (string= (%body-json (%anthropic-with)) (%body-json (%anthropic-with :extra-body nil)))))

(test a-field-the-provider-builds-itself-is-refused
  "model, messages, stream and the rest are set through COMPLETE's arguments. Letting an extra
field replace one would change what the neutral arguments mean on one backend only."
  (dolist (field '("model" "messages" "max_tokens" "temperature" "tools" "tool_choice" "stream"))
    (let ((json (format nil "{~S: 1}" field)))
      (signals cnd:invalid-extra-body (%body-json (%openai-with :extra-body json)))
      (signals cnd:invalid-extra-body (%body-json (%anthropic-with :extra-body json)))
      (signals cnd:invalid-extra-body
        (let ((llm:*extra-body* json)) (%body-json (%openai-with))))))
  (signals cnd:invalid-extra-body (%body-json (%openai-with :extra-body "{\"response_format\": 1}")))
  (signals cnd:invalid-extra-body (%body-json (%openai-with :extra-body "{\"stream_options\": 1}")))
  (signals cnd:invalid-extra-body (%body-json (%anthropic-with :extra-body "{\"system\": 1}"))))

(test fields-that-are-not-a-json-object-are-refused-when-the-provider-is-made
  "A mistake in the setting is found when the provider is made, not at the first request. The
message names the problem and never quotes the value."
  (dolist (case '(("{\"store\": fals" "not valid JSON")
                  ("[1, 2]" "not an object")
                  ("\"secret-ish\"" "not an object")))
    (destructuring-bind (value expected) case
      (let ((c (handler-case (progn (%openai-with :extra-body value) nil)
                 (cnd:invalid-extra-body (c) c))))
        (is (typep c 'cnd:invalid-extra-body) "~S was accepted" value)
        (when c
          (is (search expected (princ-to-string c)) "~S: ~A" value c)
          (is (not (search "secret-ish" (princ-to-string c))) "~A" c)))))
  (signals cnd:invalid-extra-body (%anthropic-with :extra-body 42))
  (let ((h (make-hash-table :test #'equal)))
    (setf (gethash :store h) nil)
    (signals cnd:invalid-extra-body (%openai-with :extra-body h))))

(test the-environment-sets-a-backend-s-fields
  (with-emb-env (("PRAXEON_LLM_IMPL" "openrouter")
                 ("PRAXEON_OPENROUTER_API_KEY" "test-key")
                 ("PRAXEON_OPENROUTER_EXTRA_BODY" "{\"provider\": {\"data_collection\": \"deny\"}}")
                 ("PRAXEON_LLM_EXTRA_BODY" nil))
    (let ((p (llm:make-provider-from-env)))
      (is (typep p 'llm:openai-compatible))
      (is (equal "deny" (gethash "data_collection"
                                 (gethash "provider" (%parsed-body p)))))))
  (with-emb-env (("PRAXEON_LLM_IMPL" "openrouter")
                 ("PRAXEON_OPENROUTER_API_KEY" "test-key")
                 ("PRAXEON_OPENROUTER_EXTRA_BODY" "not json"))
    (signals cnd:invalid-extra-body (llm:make-provider-from-env))))

(defclass %no-extra-body-provider (llm:provider)
  ((called :initform nil :accessor no-extra-body-called)))

(defmethod llm:complete ((p %no-extra-body-provider) messages &key system tools max-tokens
                                                                   temperature tool-choice)
  (declare (ignore messages system tools max-tokens temperature tool-choice))
  (setf (no-extra-body-called p) t)
  (llm:make-completion :text "ok" :stop-reason :end-turn))

(test a-provider-that-cannot-add-fields-signals-rather-than-dropping-them
  "Sending the request without the fields would do what the caller asked not to happen."
  (let ((p (make-instance '%no-extra-body-provider)))
    (is-false (llm:supports-extra-body-p p) "the default is no")
    (let ((c (handler-case (let ((llm:*extra-body* "{\"store\": false}"))
                             (llm:complete p +msgs+))
               (cnd:extra-body-unsupported (c) c))))
      (is (typep c 'cnd:extra-body-unsupported))
      (is (equal '("store") (and c (cnd:extra-body-unsupported-fields c))))
      (is-false (no-extra-body-called p) "nothing was asked of the provider"))))

(test the-same-provider-completes-without-extra-fields
  "Control for the test above: unbound, or bound to an empty object, the call goes through."
  (let ((p (make-instance '%no-extra-body-provider)))
    (is (equal "ok" (llm:completion-text (llm:complete p +msgs+))))
    (is (equal "ok" (llm:completion-text
                     (let ((llm:*extra-body* "{}")) (llm:complete p +msgs+)))))))

(test both-real-providers-declare-they-can-add-fields
  (is-true (llm:supports-extra-body-p (%anthropic-with)))
  (is-true (llm:supports-extra-body-p (%openai-with))))

(test the-fields-reach-the-server-with-and-without-streaming
  "The bodies the stub server received, for both providers, sent whole and as a stream."
  (dolist (case (list (list #'%streaming-anthropic +anthropic-whole+ +anthropic-events+)
                      (list #'%streaming-openai +openai-whole+ +openai-events+)))
    (destructuring-bind (provider-at whole events) case
      (multiple-value-bind (plain streamed pieces bodies)
          (let ((llm:*extra-body* "{\"store\": false}"))
            (%streamed-and-whole provider-at whole events))
        (declare (ignore plain streamed pieces))
        (is (= 2 (length bodies)))
        (dolist (body bodies)
          (multiple-value-bind (value present) (gethash "store" (jzon:parse body))
            (is-true present "~A" body)
            (is (eq nil value) "~A" body)))
        (is (search "\"stream\":true" (second bodies)) "the second request was streamed")))))

(test a-thread-started-through-aion-dynamic-carries-the-per-call-fields
  "An agent's parallel children run on threads of their own; their calls carry the same fields."
  (let ((seen :unset))
    (let ((llm:*extra-body* "{\"store\": false}"))
      (sb-thread:join-thread
       (sb-thread:make-thread
        (aion/dynamic:inheriting
         (lambda ()
           (aion/dynamic:unblock-interrupts)
           (setf seen llm:*extra-body*))))))
    (is (equal "{\"store\": false}" seen))))
