;;;; stay-local-tests.lisp --- a provider whose every request must stay on this machine (#1293)
;;;;
;;;; A provider made with :STAY-LOCAL T sends each request with aion/http-client's :STAY-LOCAL
;;;; (#1212). The client refuses a request to a host that is not loopback, before anything
;;;; connects, and a redirect to one. These tests check that the setting reaches the request,
;;;; and that the refusal reaches the caller as AION/HTTP-CLIENT:STAY-LOCAL-REFUSED, not wrapped
;;;; in PROVIDER-REQUEST-FAILED: the refusal means the configuration was broken, not that the
;;;; provider failed, so a caller that falls back to another provider on a provider failure must
;;;; not fall back on it. That the request then uses no proxy is aion/http-client's to test, and
;;;; it does (#1212).
;;;;
;;;; The hosts that are not loopback are names under .invalid and are never connected to: the
;;;; refusal comes before any lookup.

(cl:in-package #:praxeon/tests)

(def-suite llm-stay-local
  :description "praxeon/llm: a provider whose requests must stay on this machine (#1293)."
  :in praxeon)
(in-suite llm-stay-local)

(defparameter +stay-local-openai-reply+
  "{\"choices\":[{\"index\":0,\"finish_reason\":\"stop\",
     \"message\":{\"role\":\"assistant\",\"content\":\"local answer\"}}],
    \"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2}}")

(defun %stay-local-server (&key (status 200) (body +stay-local-openai-reply+) location)
  "A handler answering every request with STATUS and BODY, plus a Location header when LOCATION
is given."
  (lambda (request stream)
    (declare (ignore request))
    (aion/test-http:write-response stream status
                                   (append '(("Content-Type" . "application/json"))
                                           (and location `(("Location" . ,location))))
                                   body)))

(defun %outcome (thunk)
  "What calling THUNK did: (:RETURNED value), or (:SIGNALLED condition)."
  (handler-case (list :returned (funcall thunk))
    (error (e) (list :signalled e))))

(defun %refused-p (outcome)
  (and (eq :signalled (first outcome))
       (typep (second outcome) 'aion/http-client:stay-local-refused)))

(test provider-stay-local-is-nil-unless-set
  "Every provider class that sends requests over HTTP takes :STAY-LOCAL, and the default is NIL,
which keeps each request as it was. A provider class that has no such setting answers NIL."
  (is (null (llm:provider-stay-local (make-instance 'llm:anthropic :api-key "k" :model "m"))))
  (is (null (llm:provider-stay-local (make-instance 'llm:openai-compatible :model "m"))))
  (is (null (llm:provider-stay-local (make-instance 'llm:openai-compatible-embeddings))))
  (is (eq t (llm:provider-stay-local
             (make-instance 'llm:anthropic :api-key "k" :model "m" :stay-local t))))
  (is (eq t (llm:provider-stay-local (make-instance 'llm:openai-compatible :model "m"
                                                                           :stay-local t))))
  (is (eq t (llm:provider-stay-local (make-instance 'llm:openai-compatible-embeddings
                                                    :stay-local t))))
  (is (null (llm:provider-stay-local (make-instance 'llm:provider)))))

(test a-stay-local-provider-whose-endpoint-is-not-loopback-signals-the-refusal-itself
  "Each provider class, set to stay local and pointed at a host that is not loopback, signals
STAY-LOCAL-REFUSED, and not PROVIDER-REQUEST-FAILED, for a whole completion, a streamed one, and
an embedding. Control: without the setting, a failed request to a local server is still a
PROVIDER-REQUEST-FAILED."
  (let ((messages (list (llm:msg "user" "hi")))
        (cases
          (list (cons "anthropic"
                      (make-instance 'llm:anthropic :api-key "k" :model "m" :stay-local t
                                                    :endpoint "https://api.example.invalid/v1/messages"))
                (cons "openai-compatible"
                      (make-instance 'llm:openai-compatible :model "m" :stay-local t
                                                            :base-url "http://api.example.invalid/v1")))))
    (loop for (name . p) in cases
          do (let ((whole (%outcome (lambda () (llm:complete p messages))))
                   (streamed (%outcome (lambda ()
                                         (let ((llm:*on-text* (lambda (piece)
                                                                (declare (ignore piece)))))
                                           (llm:complete p messages))))))
               (is-true (%refused-p whole) "~A, whole: ~S" name whole)
               (is-true (%refused-p streamed) "~A, streamed: ~S" name streamed))))
  (let ((outcome (%outcome (lambda ()
                             (llm:embed (make-instance 'llm:openai-compatible-embeddings
                                                       :stay-local t
                                                       :base-url "http://api.example.invalid/v1")
                                        "text")))))
    (is-true (%refused-p outcome) "embeddings: ~S" outcome))
  (aion/test-http:with-server (s (%stay-local-server :status 500 :body "{}"))
    (let ((outcome (%outcome (lambda ()
                               (llm:complete (make-instance 'llm:openai-compatible
                                                            :model "m"
                                                            :base-url (aion/test-http:server-url s "/v1"))
                                             (list (llm:msg "user" "hi")))))))
      (is (typep (second outcome) 'cnd:provider-request-failed)
          "control: a 500 is still a provider failure: ~S" outcome))))

(test a-stay-local-provider-redirected-off-the-machine-signals-the-refusal-itself
  "A local server that redirects a completion to a host that is not loopback: the provider set
to stay local signals STAY-LOCAL-REFUSED naming the target. Control: a local server that
answers is used as before."
  (aion/test-http:with-server (s (%stay-local-server :status 307
                                                     :location "http://api.example.invalid/v1/chat/completions"
                                                     :body ""))
    (let ((outcome (%outcome (lambda ()
                               (llm:complete (make-instance 'llm:openai-compatible
                                                            :model "m" :stay-local t
                                                            :base-url (aion/test-http:server-url s "/v1"))
                                             (list (llm:msg "user" "hi")))))))
      (is-true (%refused-p outcome) "~S" outcome)
      (is (equal "http://api.example.invalid/v1/chat/completions"
                 (and (%refused-p outcome)
                      (aion/http-client:stay-local-refused-url (second outcome)))))))
  (aion/test-http:with-server (s (%stay-local-server))
    (is (equal "local answer"
               (llm:completion-text
                (llm:complete (make-instance 'llm:openai-compatible
                                             :model "m" :stay-local t
                                             :base-url (aion/test-http:server-url s "/v1"))
                              (list (llm:msg "user" "hi")))))
        "control: a loopback endpoint answers")))

(defun %complete-with-fallback (providers messages)
  "The fallback an app writes: try each of PROVIDERS in turn, moving to the next when one
signals PROVIDER-REQUEST-FAILED, and return the first completion."
  (loop for (p . rest) on providers
        do (handler-case (return (llm:complete p messages))
             (cnd:provider-request-failed (e)
               (unless rest (error e))))))

(test a-fallback-chain-does-not-pass-a-stay-local-refusal-to-the-next-provider
  "An app falls back to its next provider when one signals PROVIDER-REQUEST-FAILED. The first
provider is set to stay local and its request is refused; the next one stands for a remote
provider and records what it receives. The refusal reaches the app, and the next provider
receives nothing, because falling back to a remote provider would send the conversation off the
machine that the setting was there to keep it on. Control: when the first provider fails in an
ordinary way, a 500 from a local server, the chain does fall through."
  (let ((messages (list (llm:msg "user" "private"))))
    (aion/test-http:with-server (next (%stay-local-server))
      (let* ((remote (make-instance 'llm:openai-compatible
                                    :model "m" :base-url (aion/test-http:server-url next "/v1")))
             (outcome (%outcome
                       (lambda ()
                         (%complete-with-fallback
                          (list (make-instance 'llm:openai-compatible
                                               :model "m" :stay-local t
                                               :base-url "http://api.example.invalid/v1")
                                remote)
                          messages)))))
        (is-true (%refused-p outcome) "the refusal reaches the app: ~S" outcome)
        (is (= 0 (length (aion/test-http:server-requests next)))
            "the next provider received ~D requests"
            (length (aion/test-http:server-requests next))))
      (aion/test-http:with-server (failing (%stay-local-server :status 500 :body "{}"))
        (let ((before (length (aion/test-http:server-requests next))))
          (is (equal "local answer"
                     (llm:completion-text
                      (%complete-with-fallback
                       (list (make-instance 'llm:openai-compatible
                                            :model "m" :stay-local t
                                            :base-url (aion/test-http:server-url failing "/v1"))
                             (make-instance 'llm:openai-compatible
                                            :model "m"
                                            :base-url (aion/test-http:server-url next "/v1")))
                       messages)))
              "control: an ordinary failure falls through")
          (is (= (1+ before) (length (aion/test-http:server-requests next)))))))))

(test a-stay-local-refusal-is-not-retried
  "With *RETRY* set, a refused request is made once: the refusal is not a temporary failure, and
retrying it could only be refused again."
  (let ((scheduled 0)
        (llm:*retry* (aion/retry:make-retry-policy :max-attempts 3 :base-delay 0 :name "test")))
    (let ((outcome
            (handler-bind ((aion/retry:retry-scheduled (lambda (c) (declare (ignore c))
                                                         (incf scheduled))))
              (%outcome (lambda ()
                          (llm:complete (make-instance 'llm:openai-compatible
                                                       :model "m" :stay-local t
                                                       :base-url "http://api.example.invalid/v1")
                                        (list (llm:msg "user" "hi"))))))))
      (is-true (%refused-p outcome) "~S" outcome)
      (is (= 0 scheduled) "retries scheduled: ~D" scheduled))))
