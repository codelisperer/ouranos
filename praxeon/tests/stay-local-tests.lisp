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

;;; --- the image providers (#1302) -----------------------------------------------------------
;;;
;;; OPENAI-IMAGES and GOOGLE-IMAGES send the prompt too, so they take :STAY-LOCAL the same way.
;;; Each case below runs for both classes; the reply a local server answers with is each
;;; provider's own, from image-tests and image-google-tests.

(defun %stay-local-image-providers (base-url-for &key stay-local)
  "An OPENAI-IMAGES and a GOOGLE-IMAGES provider, as (name . provider) pairs, made with
STAY-LOCAL and the base URL (funcall BASE-URL-FOR name)."
  (list (cons "openai"
              (praxeon/image:make-openai-images :api-key "k" :stay-local stay-local
                                                :base-url (funcall base-url-for "openai")))
        (cons "google"
              (praxeon/image:make-google-images :api-key "k" :stay-local stay-local
                                                :base-url (funcall base-url-for "google")))))

(defun %stay-local-image-reply (name)
  (if (equal name "openai") (%image-reply) (%google-reply)))

(defun %generate (provider)
  (praxeon/image:generate-image provider "a lighthouse at dusk"))

(test an-image-provider-takes-stay-local-and-the-default-is-nil
  "Both image provider classes answer PROVIDER-STAY-LOCAL: NIL unless set, and T when set
through MAKE-*, *-FROM-ENV or MAKE-INSTANCE."
  (is (null (llm:provider-stay-local (praxeon/image:make-openai-images :api-key "k"))))
  (is (null (llm:provider-stay-local (praxeon/image:make-google-images :api-key "k"))))
  (is (eq t (llm:provider-stay-local
             (praxeon/image:make-openai-images :api-key "k" :stay-local t))))
  (is (eq t (llm:provider-stay-local
             (praxeon/image:make-google-images :api-key "k" :stay-local t))))
  (is (eq t (llm:provider-stay-local
             (praxeon/image:openai-images-from-env :api-key "k" :stay-local t))))
  (is (eq t (llm:provider-stay-local
             (praxeon/image:google-images-from-env :api-key "k" :stay-local t))))
  (is (eq t (llm:provider-stay-local
             (make-instance 'praxeon/image:openai-images :api-key "k" :stay-local t)))))

(test a-stay-local-image-provider-whose-endpoint-is-not-loopback-signals-the-refusal-itself
  "Each image provider, set to stay local with a base URL whose host is not loopback, signals
STAY-LOCAL-REFUSED: not IMAGE-REQUEST-FAILED, which would tell the agent to try again later, and
not PROVIDER-REQUEST-FAILED. Control: without the setting, a 500 from a local server is still a
provider failure."
  (loop for (name . p) in (%stay-local-image-providers
                           (lambda (name) (format nil "https://~A.example.invalid/v1" name))
                           :stay-local t)
        do (let ((outcome (%outcome (lambda () (%generate p)))))
             (is-true (%refused-p outcome) "~A: ~S" name outcome)
             (is-false (typep (second outcome) 'praxeon/image:image-request-failed) "~A" name)
             (is-false (typep (second outcome) 'cnd:provider-request-failed) "~A" name)))
  (aion/test-http:with-server (s (%stay-local-server :status 500 :body "{}"))
    (loop for (name . p) in (%stay-local-image-providers
                             (lambda (name) (declare (ignore name))
                               (aion/test-http:server-url s "/v1")))
          do (let ((outcome (%outcome (lambda () (%generate p)))))
               (is (typep (second outcome) 'cnd:provider-request-failed)
                   "control, ~A: a 500 is still a provider failure: ~S" name outcome)))))

(test a-stay-local-image-provider-redirected-off-the-machine-signals-the-refusal-itself
  "A local server that answers the image request with a 307 to a host that is not loopback: the
provider set to stay local signals STAY-LOCAL-REFUSED naming that target, so the prompt is not
sent there. Control: a local server that answers with an image is used as before."
  (aion/test-http:with-server (s (%stay-local-server :status 307
                                                     :location "http://images.example.invalid/x"
                                                     :body ""))
    (loop for (name . p) in (%stay-local-image-providers
                             (lambda (name) (declare (ignore name))
                               (aion/test-http:server-url s "/v1"))
                             :stay-local t)
          do (let ((outcome (%outcome (lambda () (%generate p)))))
               (is-true (%refused-p outcome) "~A: ~S" name outcome)
               (is (equal "http://images.example.invalid/x"
                          (and (%refused-p outcome)
                               (aion/http-client:stay-local-refused-url (second outcome))))
                   "~A" name))))
  (dolist (name '("openai" "google"))
    (aion/test-http:with-server (s (%stay-local-server :body (%stay-local-image-reply name)))
      (let* ((p (cdr (assoc name (%stay-local-image-providers
                                  (lambda (name) (declare (ignore name))
                                    (aion/test-http:server-url s "/v1"))
                                  :stay-local t)
                            :test #'equal)))
             (results (%generate p)))
        (is (= 1 (length results)) "control, ~A: a loopback endpoint answers" name)
        (is (= 1 (length (aion/test-http:server-requests s))) "~A" name)))))

;;; --- through praxeon: a redirect off the machine, and HTTPS_PROXY (#1341) -------------------
;;;
;;; #1341 asks for two things to be shown through praxeon's providers rather than only through
;;; aion/http-client: that a provider made with :STAY-LOCAL T refuses a 307 from a local server
;;; to another host, and that it does not send an https request to a loopback endpoint through
;;; the proxy HTTPS_PROXY configures. Both are shown for an embedding provider, whose request
;;; carries the text being embedded, and for an OPENAI-COMPATIBLE chat provider. Each has a
;;; control, so a test that passed because nothing was redirected or nothing was proxied would
;;; fail its control. A redirect to a second local server is covered too: it is loopback, so
;;; :STAY-LOCAL does not refuse it, and the text is kept from it by #1139's rule instead.

(defparameter +stay-local-embedding-reply+
  "{\"object\":\"list\",\"data\":[{\"object\":\"embedding\",\"index\":0,\"embedding\":[0.1,0.2,0.3]}],
    \"model\":\"m\",\"usage\":{\"prompt_tokens\":1,\"total_tokens\":1}}")

(defun %stay-local-embedder (base-url &key stay-local)
  (make-instance 'llm:openai-compatible-embeddings :base-url base-url :dimensions 3
                                                   :stay-local stay-local))

(defun %stay-local-chat (base-url &key stay-local)
  (make-instance 'llm:openai-compatible :model "m" :base-url base-url :stay-local stay-local))

(defun %stay-local-calls (base-url &key stay-local)
  "The two calls #1341 is about, as (name . thunk): an embedding of a private paragraph, and a
completion, each from a provider at BASE-URL made with STAY-LOCAL."
  (list (cons "embeddings"
              (lambda () (llm:embed (%stay-local-embedder base-url :stay-local stay-local)
                                    "a private paragraph")))
        (cons "chat"
              (lambda () (llm:complete (%stay-local-chat base-url :stay-local stay-local)
                                       (list (llm:msg "user" "a private paragraph")))))))

(test an-embedding-provider-set-to-stay-local-refuses-a-redirect-off-the-machine
  "A local server answers the embedding request with a 307 to a host that is not loopback, as
#1341's scenario has it for an embedder at Ollama's address. The provider signals
STAY-LOCAL-REFUSED naming that target, so the text is not re-sent there. Control: the same
provider against a local server that answers returns the vector."
  (aion/test-http:with-server (s (%stay-local-server :status 307
                                                     :location "https://elsewhere.example.invalid/v1/embeddings"
                                                     :body ""))
    (let ((outcome (%outcome (lambda ()
                               (llm:embed (%stay-local-embedder (aion/test-http:server-url s "/v1")
                                                                :stay-local t)
                                          "a private paragraph")))))
      (is-true (%refused-p outcome) "~S" outcome)
      (is (equal "https://elsewhere.example.invalid/v1/embeddings"
                 (and (%refused-p outcome)
                      (aion/http-client:stay-local-refused-url (second outcome)))))
      (is (= 1 (length (aion/test-http:server-requests s)))
          "the local server received ~D requests" (length (aion/test-http:server-requests s)))))
  (aion/test-http:with-server (s (%stay-local-server :body +stay-local-embedding-reply+))
    (let ((vector (llm:embed (%stay-local-embedder (aion/test-http:server-url s "/v1")
                                                   :stay-local t)
                             "a private paragraph")))
      (is (= 3 (length vector)) "control: a loopback endpoint answers: ~S" vector))))

(defun %redirecting-server (location-for &key (reply +stay-local-embedding-reply+))
  "A handler that answers a request under /v1/ with a 307 to (funcall LOCATION-FOR path), and any
other request with REPLY."
  (lambda (request stream)
    (let ((path (aion/test-http:request-path request)))
      (if (eql 0 (search "/v1/" path))
          (aion/test-http:write-response stream 307
                                         `(("Location" . ,(funcall location-for path))) "")
          (aion/test-http:write-response stream 200 '(("Content-Type" . "application/json"))
                                         reply)))))

(test a-redirect-to-another-local-origin-does-not-carry-the-text-with-or-without-stay-local
  "#1341's scenario has the client re-send the POST, text included, to wherever a 307 points. On
main it does not: since #1139, aion/http-client never re-sends a request body to another origin,
so the 307 is the answer. This holds for both providers with and without :STAY-LOCAL, so the
setting is not what protects the text from a redirect to a second local server, which is
loopback and so not refused. The target is a second local server that records what it receives,
and it receives nothing. Without the setting, the call signals PROVIDER-REQUEST-FAILED, not
STAY-LOCAL-REFUSED.

Control: a 307 to another path on the same server is followed, by the embedding provider, so a
target that received nothing above was reachable by a followed redirect."
  (aion/test-http:with-server (target (%stay-local-server :body +stay-local-embedding-reply+))
    (aion/test-http:with-server (s (%redirecting-server
                                    (lambda (path) (aion/test-http:server-url target path))))
      (dolist (stay-local '(nil t))
        (loop for (name . call) in (%stay-local-calls (aion/test-http:server-url s "/v1")
                                                      :stay-local stay-local)
              do (let ((outcome (%outcome call)))
                   (is (typep (second outcome) 'cnd:provider-request-failed)
                       "~A, stay-local ~A: the 307 is the answer: ~S" name stay-local outcome)
                   (is (= 0 (length (aion/test-http:server-requests target)))
                       "~A, stay-local ~A: the other origin received ~D requests"
                       name stay-local (length (aion/test-http:server-requests target))))))))
  (aion/test-http:with-server (s (%redirecting-server (lambda (path)
                                                        (format nil "/v2/~A" (subseq path 4)))))
    (dolist (stay-local '(nil t))
      (let ((vector (llm:embed (%stay-local-embedder (aion/test-http:server-url s "/v1")
                                                     :stay-local stay-local)
                               "a private paragraph")))
        (is (= 3 (length vector)) "control, stay-local ~A: a same-origin 307 is followed: ~S"
            stay-local vector))
      (is (= (if stay-local 4 2) (length (aion/test-http:server-requests s)))
          "control, stay-local ~A: the server saw the request and the followed one"
          stay-local))))

(defun %unused-local-port ()
  "A port on 127.0.0.1 that nothing listens on: one a test server was given and then gave up."
  (let ((s (aion/test-http:start-server (lambda (request stream)
                                          (declare (ignore request stream))))))
    (prog1 (aion/test-http:server-port s)
      (aion/test-http:stop-server s))))

(test a-stay-local-provider-sends-an-https-loopback-request-past-the-proxy
  "An https endpoint on 127.0.0.1 with a proxy configured, as HTTPS_PROXY configures it: dexador
reads HTTPS_PROXY into DEXADOR.UTIL:*DEFAULT-PROXY* when it loads, so the test binds that, as
aion/http-client's own test does. The proxy is a local server that records what it receives. The
endpoint is a port nothing listens on, so a direct request fails to connect, and the test reads
only where the request went. Set to stay local, both providers send nothing to the proxy.
Control: without the setting, each sends a CONNECT to the proxy, which is the default and stays
so until the maintainer rules on #1341's first part.

Skipped on Windows, where dexador's WinHTTP backend never uses *DEFAULT-PROXY* (#914), so the
control could not see the proxy used."
  (if (uiop:os-windows-p)
      (skip "WinHTTP ignores dexador's *DEFAULT-PROXY* (#914)")
      (aion/test-http:with-server (proxy (%stay-local-server :status 502 :body "proxy"))
        (let ((dexador.util:*default-proxy* (aion/test-http:server-url proxy ""))
              (endpoint (format nil "https://127.0.0.1:~D/v1" (%unused-local-port))))
          (flet ((proxied () (length (aion/test-http:server-heads proxy))))
            (loop for (name . call) in (%stay-local-calls endpoint :stay-local t)
                  do (let ((outcome (%outcome call)))
                       (is (eq :signalled (first outcome))
                           "~A: nothing listens there, so the call cannot succeed: ~S"
                           name outcome)
                       (is (= 0 (proxied)) "~A: the proxy received ~D requests"
                           name (proxied))))
            (loop for (name . call) in (%stay-local-calls endpoint)
                  do (let ((before (proxied)))
                       (%outcome call)
                       (is (= (1+ before) (proxied))
                           "control, ~A: without :STAY-LOCAL the request goes to the proxy" name)
                       (is-true (search "CONNECT" (or (first (aion/test-http:server-heads proxy)) ""))
                                "control, ~A: as a CONNECT: ~S"
                                name (first (aion/test-http:server-heads proxy))))))))))
