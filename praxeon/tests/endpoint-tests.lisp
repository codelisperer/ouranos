;;;; endpoint-tests.lisp --- where each provider sends its requests (#1034).
;;;;
;;;; PROVIDER-ENDPOINT is how an app checks that a request stays on this machine, so these tests
;;;; check three things: that URLs are read the way a request uses them, that every provider
;;;; class answers (with its defaults), and that the URL each provider builds for its requests
;;;; has the scheme, host and port the function reports. No request is sent.

(cl:in-package #:praxeon/tests)

(def-suite endpoint :description "Where each provider sends its requests (#1034)." :in praxeon)
(in-suite endpoint)

(defun %endpoint-list (e)
  (and e (list (llm:endpoint-scheme e) (llm:endpoint-host e) (llm:endpoint-port e))))

(test parse-endpoint-reads-the-scheme-host-and-port-a-request-uses
  (flet ((reads (url want)
           (is (equal want (%endpoint-list (llm:parse-endpoint url))) "~A" url)))
    (reads "http://localhost:11434/v1" '("http" "localhost" 11434))
    (reads "https://API.Example.COM/v1" '("https" "api.example.com" 443))
    (reads "http://api.example.com" '("http" "api.example.com" 80))
    (reads "HTTP://127.0.0.1:8080" '("http" "127.0.0.1" 8080))
    (reads "http://[::1]:8080/v1" '("http" "::1" 8080))
    (reads "https://[::1]/v1" '("https" "::1" 443))
    (reads "https://user:p%40ss@host.example:8443/x?y=1#z" '("https" "host.example" 8443))
    (reads "http://host.example:/v1" '("http" "host.example" 80))
    (reads "http://host.example/v1?next=http://other:9/" '("http" "host.example" 80)))
  (dolist (bad '("ftp://host.example/" "localhost:11434" "http:///v1" "http://:80/v1"
                 "http://host.example:0/" "http://host.example:65536/" "http://host.example:12a/"
                 "http://[::1/v1" "http://[::1]x/v1" nil))
    (signals error (llm:parse-endpoint bad))))

(test endpoint-loopback-p-answers-for-localhost-127-0-0-0-8-and-1
  (flet ((loopback (host) (llm:endpoint-loopback-p (llm:parse-endpoint
                                                     (if (find #\: host)
                                                         (format nil "http://[~A]/" host)
                                                         (format nil "http://~A/" host))))))
    (dolist (host '("localhost" "LOCALHOST" "127.0.0.1" "127.255.0.9" "::1" "0:0:0:0:0:0:0:1"
                    "::ffff:127.0.0.1"))
      (is-true (loopback host) "~A is a loopback address" host))
    (dolist (host '("api.example.com" "10.0.0.1" "128.0.0.1" "126.255.255.255" "::2"
                    "::ffff:10.0.0.1" "localhost.example.com" "127.0.0.1.nip.io" "0.0.0.0"))
      (is (null (loopback host)) "~A is not a loopback address" host)))
  (is (null (llm:endpoint-loopback-p nil)) "an unknown endpoint is not on this machine"))

(defun %every-provider ()
  "One of each provider class, as (name provider endpoint request-url): the endpoint it should
report and the URL it builds for a request."
  (let ((anthropic (make-instance 'llm:anthropic :api-key "k"))
        (anthropic-local (make-instance 'llm:anthropic :api-key "k"
                                                       :endpoint "http://127.0.0.1:8001/v1/messages"))
        (oai (make-instance 'llm:openai-compatible :impl "ollama" :model "m" :api-key "k"
                                                   :base-url "http://[::1]:11434/v1"))
        (embed (make-instance 'llm:openai-compatible-embeddings
                              :base-url "https://embed.example.com:8443/v1"))
        (voyage (make-instance 'llm:voyage-embeddings :api-key "k"))
        (rerank (make-instance 'llm:voyage-reranker :api-key "k"))
        (image (praxeon/image:make-openai-images :api-key "k" :base-url "http://localhost:9000/v1"))
        (google (praxeon/image:make-google-images :api-key "k")))
    (list (list "anthropic, default" anthropic '("https" "api.anthropic.com" 443)
                (llm::anthropic-endpoint anthropic))
          (list "anthropic, local" anthropic-local '("http" "127.0.0.1" 8001)
                (llm::anthropic-endpoint anthropic-local))
          (list "openai-compatible" oai '("http" "::1" 11434) (llm::%oai-chat-url oai))
          (list "openai-compatible embeddings" embed '("https" "embed.example.com" 8443)
                (llm::%embeddings-url embed))
          (list "voyage embeddings, default" voyage '("https" "api.voyageai.com" 443)
                (llm::%embeddings-url voyage))
          (list "voyage reranker, default" rerank '("https" "api.voyageai.com" 443)
                (llm::%rerank-url rerank))
          (list "openai images" image '("http" "localhost" 9000)
                (praxeon/image::%openai-images-url image "/images/generations"))
          (list "google images, default" google '("https" "generativelanguage.googleapis.com" 443)
                (praxeon/image::%google-images-url google)))))

(test every-provider-reports-its-endpoint-with-defaults-applied
  (loop for (name provider want) in (%every-provider)
        do (is (equal want (%endpoint-list (llm:provider-endpoint provider)))
               "~A reports ~S" name (%endpoint-list (llm:provider-endpoint provider)))))

(test the-url-a-provider-builds-goes-to-the-endpoint-it-reports
  "An app's check and the request must not disagree, so the endpoint is compared with the URL
the provider actually builds for a request."
  (loop for (name provider nil url) in (%every-provider)
        do (is (equalp (llm:parse-endpoint url) (llm:provider-endpoint provider))
               "~A builds ~A, but reports ~S" name url
               (%endpoint-list (llm:provider-endpoint provider)))))

(test a-provider-whose-destination-is-unknown-reports-nil
  "A provider class with no method, such as one that runs in this process, answers NIL, and NIL
is not a loopback endpoint, so a check that requires one refuses it."
  (let ((p (make-instance 'scripted :script '())))
    (is (null (llm:provider-endpoint p)))
    (is (null (llm:endpoint-loopback-p (llm:provider-endpoint p))))))
