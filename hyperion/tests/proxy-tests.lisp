;;;; proxy-tests.lisp --- the client's address and scheme behind a trusted proxy (#381).
;;;;
;;;; After ratelimit-tests.lisp, whose helpers (%RL-APP, %WITH-RL-CLOCK) the rate-limit checks use.

(in-package #:hyperion/tests)

(def-suite proxy :description "CLIENT-ADDRESS and REQUEST-SCHEME behind a trusted proxy (#381)." :in hyperion)
(in-suite proxy)

(defun %px-env (peer &rest headers)
  "An env from PEER, the TCP peer's address, with HEADERS (name value ...)."
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on headers by #'cddr do (setf (gethash (string-downcase k) h) v))
    (list :request-method :post :path-info "/sign-in" :remote-addr peer :headers h
          :url-scheme "http")))

(defun %px (env &rest trust-args)
  (hyperion/proxy:client-address env :trust (and trust-args
                                                 (apply #'hyperion/proxy:make-proxy-trust trust-args))))

(test addresses-and-ranges-are-parsed-and-matched
  (is (= #x0a000001 (hyperion/proxy:parse-address "10.0.0.1")))
  (is (equal '(1 128) (multiple-value-list (hyperion/proxy:parse-address "::1"))))
  (is (equal (list #xc0a80001 32) (multiple-value-list (hyperion/proxy:parse-address "::ffff:192.168.0.1")))
      "an IPv4-mapped IPv6 address is its IPv4 address")
  (is (null (hyperion/proxy:parse-address "300.1.1.1")))
  (is (null (hyperion/proxy:parse-address "1::2::3")))
  (is (null (hyperion/proxy:parse-address "evil")))
  (let ((v4 (hyperion/proxy:parse-cidr "10.0.0.0/8"))
        (v6 (hyperion/proxy:parse-cidr "2400:cb00::/32")))
    (is (hyperion/proxy:cidr-contains-p v4 "10.255.1.2"))
    (is (not (hyperion/proxy:cidr-contains-p v4 "11.0.0.1")))
    (is (hyperion/proxy:cidr-contains-p v6 "2400:cb00:2048::1"))
    (is (not (hyperion/proxy:cidr-contains-p v6 "10.0.0.1")) "the families do not mix")
    (is (hyperion/proxy:cidr-contains-p (hyperion/proxy:parse-cidr "0.0.0.0/0") "8.8.8.8")))
  (signals error (hyperion/proxy:parse-cidr "10.0.0.0/33"))
  (signals error (hyperion/proxy:parse-cidr "not-a-range")))

(test with-no-setting-the-answer-is-the-peer-whatever-the-headers-say
  (let ((env (%px-env "10.0.0.1" "X-Forwarded-For" "6.6.6.6" "CF-Connecting-IP" "7.7.7.7")))
    (is (string= "10.0.0.1" (%px env)))
    (is (string= "10.0.0.1" (hyperion/proxy:client-address env)) "the default setting is none")
    (is (eq :http (hyperion/proxy:request-scheme
                   (%px-env "10.0.0.1" "X-Forwarded-Proto" "https")))
        "and X-Forwarded-Proto is not believed")))

(test with-a-hop-count-a-forged-leftmost-entry-changes-nothing
  (is (string= "203.0.113.9" (%px (%px-env "10.0.0.1" "X-Forwarded-For" "203.0.113.9") :hops 1)))
  (is (string= "203.0.113.9"
               (%px (%px-env "10.0.0.1" "X-Forwarded-For" "6.6.6.6, 1.2.3.4, 203.0.113.9") :hops 1))
      "entries the client wrote on the left are not read")
  (is (string= "203.0.113.9"
               (%px (%px-env "10.0.0.1" "X-Forwarded-For" "6.6.6.6, 203.0.113.9, 172.16.0.5") :hops 2))
      "two proxies: the second entry from the right of the header and the peer")
  (is (string= "203.0.113.9"
               (%px (%px-env "10.0.0.1" "X-Forwarded-For" "203.0.113.9:51234") :hops 1))
      "a port is dropped, so one client is one key")
  (is (string= "10.0.0.1" (%px (%px-env "10.0.0.1") :hops 1))
      "with no header, the leftmost address there is"))

(test with-trusted-ranges-only-a-trusted-peer-s-header-is-read
  (let ((trusted '("10.0.0.0/8" "2400:cb00::/32")))
    (is (string= "6.6.6.6" (%px (%px-env "6.6.6.6" "X-Forwarded-For" "1.1.1.1") :cidrs trusted))
        "a peer outside the ranges is the client, whatever it forwards")
    (is (string= "203.0.113.9"
                 (%px (%px-env "10.0.0.1" "X-Forwarded-For" "6.6.6.6, 203.0.113.9, 10.0.0.7")
                      :cidrs trusted))
        "the rightmost address that is not a trusted proxy")
    (is (string= "2001:db8::5"
                 (%px (%px-env "2400:cb00::1" "X-Forwarded-For" "[2001:DB8::5]:443") :cidrs trusted))
        "an IPv6 entry loses its brackets and port and is lowercased")
    (is (string= "10.0.0.3"
                 (%px (%px-env "10.0.0.1" "X-Forwarded-For" "10.0.0.3, 10.0.0.2") :cidrs trusted))
        "every address trusted: the leftmost is as far as the chain goes")))

(test a-platform-header-is-honoured-only-from-a-trusted-peer
  (let ((cf '(:cidrs ("173.245.48.0/20") :header "CF-Connecting-IP")))
    (is (string= "198.51.100.4"
                 (apply #'%px (%px-env "173.245.48.10" "CF-Connecting-IP" "198.51.100.4"
                                       "X-Forwarded-For" "6.6.6.6")
                        cf)))
    (is (string= "203.0.113.50"
                 (apply #'%px (%px-env "203.0.113.50" "CF-Connecting-IP" "198.51.100.4") cf))
        "from a peer outside the ranges the header is ignored")
    (is (string= "198.51.100.7"
                 (apply #'%px (%px-env "173.245.48.10" "X-Forwarded-For" "198.51.100.7") cf))
        "without the header, X-Forwarded-For from the trusted peer")))

(test the-scheme-comes-from-x-forwarded-proto-only-through-a-trusted-proxy
  (let ((trust (hyperion/proxy:make-proxy-trust :cidrs '("10.0.0.0/8"))))
    (is (eq :https (hyperion/proxy:request-scheme (%px-env "10.0.0.1" "X-Forwarded-Proto" "https")
                                                  :trust trust)))
    (is (eq :http (hyperion/proxy:request-scheme (%px-env "6.6.6.6" "X-Forwarded-Proto" "https")
                                                 :trust trust)))
    (is (eq :https (hyperion/proxy:request-scheme (list* :url-scheme "https" (%px-env "6.6.6.6"))
                                                  :trust trust))
        "the env's own scheme otherwise")))

(test a-trust-setting-that-says-nothing-or-too-much-is-refused
  (signals error (hyperion/proxy:make-proxy-trust))
  (signals error (hyperion/proxy:make-proxy-trust :hops 1 :cidrs '("10.0.0.0/8")))
  (signals error (hyperion/proxy:make-proxy-trust :hops 0))
  (signals error (hyperion/proxy:make-proxy-trust :hops 1 :header "CF-Connecting-IP"))
  (signals error (hyperion/proxy:make-proxy-trust :cidrs '("10.0.0.0/99"))))

(defun %px-status (app peer xff)
  (first (funcall app (%px-env peer "X-Forwarded-For" xff))))

(test by-address-keys-per-real-client-behind-a-trusted-proxy
  "One sign-in allowed per address per minute, every request through the proxy 10.0.0.1."
  (%with-rl-clock ()
    (let ((app (rl:wrap-rate-limit (%rl-app)
                                   :limits (list (rl:make-limit :sign-in :capacity 1 :per 60
                                                                         :key (rl:by-address))))))
      (let ((hyperion/proxy:*trusted-proxy* (hyperion/proxy:make-proxy-trust :hops 1)))
        (is (= 200 (%px-status app "10.0.0.1" "203.0.113.1")))
        (is (= 200 (%px-status app "10.0.0.1" "203.0.113.2")) "another client has its own bucket")
        (is (= 429 (%px-status app "10.0.0.1" "6.6.6.6, 203.0.113.1"))
            "the first client again, with a forged entry in front, is still the first client"))
      (let ((app (rl:wrap-rate-limit (%rl-app)
                                     :limits (list (rl:make-limit :sign-in :capacity 1 :per 60
                                                                           :key (rl:by-address))))))
        (is (= 200 (%px-status app "10.0.0.1" "203.0.113.1")))
        (is (= 429 (%px-status app "10.0.0.1" "203.0.113.2"))
            "control: with no setting every client behind the proxy shares the proxy's bucket")))))

(test the-request-log-reports-the-client-address
  (let* ((app (hyperion/logging:wrap (lambda (env) (declare (ignore env))
                                       (list 200 '(:content-type "text/plain") '("ok")))))
         (out (%log-capture :debug
                            (lambda ()
                              (let ((hyperion/proxy:*trusted-proxy*
                                      (hyperion/proxy:make-proxy-trust :hops 1)))
                                (funcall app (%px-env "10.0.0.1" "X-Forwarded-For" "203.0.113.9")))))))
    (is (search "remote=203.0.113.9" out) "~S" out)))
