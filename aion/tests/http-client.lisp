;;;; tests/http-client.lisp --- the interceptor-shaped HTTP client (pre-publication issue 202).
;;;;
;;;; Like the interceptor pipeline before it (pre-publication issue 177), this code was written, used in
;;;; production paths by two providers, and moved -- with NO TESTS AT ALL. That is the same
;;;; finding twice: the tree's reusable pieces keep arriving covered by nothing, inside
;;;; systems reporting green.
;;;;
;;;; None of these touch the network. SEND-REQUEST takes its effect as a parameter, which is
;;;; both how it is tested here and how a consuming app stubs it -- the app that reported
;;;; pre-publication issue 202 had independently arrived at the same shape, calling it "an injectable var".

(cl:defpackage #:aion/http-client/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:http #:aion/http-client)
                    (#:bt #:bordeaux-threads))
  (:export #:run-tests))
(cl:in-package #:aion/http-client/tests)

(def-suite http-client :description "The interceptor-shaped HTTP client.")
(defun run-tests () (run! 'http-client))
(in-suite http-client)

(defun %ok (&key (status 200) (body "") headers)
  "An effect that answers with a fixed response, ignoring the request."
  (lambda (req) (declare (ignore req))
    (http:make-response :status status :body body :headers headers)))

(defun %echo ()
  "An effect that reports the request it was given, so ENTER stages are observable."
  (lambda (req)
    (http:make-response
     :status 200
     :body (format nil "~A ~A |~{~A=~A~^,~}|"
                   (http:request-method req) (http:request-url req)
                   (loop for (k . v) in (reverse (http:request-headers req))
                         append (list k v))))))

;;; --- stage order -----------------------------------------------------------

(test enter-stages-run-forward-before-the-effect
  (let ((resp (http:send-request
               (http:make-request :method :post :url "https://example.invalid/x")
               (list (http:add-header "A" "1") (http:add-header "B" "2"))
               :perform (%echo))))
    (is (search "A=1" (http:response-body resp)))
    (is (search "B=2" (http:response-body resp)))
    (is (search "POST" (http:response-body resp))
        "the effect sees the built request, not the original")))

(test leave-stages-run-in-reverse-so-the-outermost-wraps
  ;; The property most easily got backwards, and one that still appears to work until a
  ;; stage depends on an outer one having already run.
  (let* ((mark (lambda (s)
                 (http:make-interceptor
                  s :leave (lambda (r)
                             (http:make-response
                              :status (http:response-status r)
                              :body (concatenate 'string (http:response-body r) s))))))
         (resp (http:send-request (http:make-request :url "u")
                                  (list (funcall mark "<a") (funcall mark "<b"))
                                  :perform (%ok :body "body"))))
    (is (string= "body<b<a" (http:response-body resp))
        "inner stage leaves first; got ~S" (http:response-body resp))))

(test a-stage-with-no-leave-is-transparent
  (let ((resp (http:send-request (http:make-request :url "u")
                                 (list (http:add-header "A" "1"))
                                 :perform (%ok :body "unchanged"))))
    (is (string= "unchanged" (http:response-body resp)))))

;;; --- status handling -------------------------------------------------------

(test a-2xx-passes-through-ensure-2xx
  (dolist (status '(200 201 204 299))
    (is (= status (http:response-status
                   (http:send-request (http:make-request :url "u")
                                      (list (http:ensure-2xx))
                                      :perform (%ok :status status)))))))

(test a-non-2xx-signals-and-carries-the-body
  ;; The body is where a service explains its own refusal, and is the part a caller most
  ;; wants in the report -- so it travels with the condition rather than being discarded.
  (handler-case
      (progn (http:send-request (http:make-request :url "u")
                                (list (http:ensure-2xx "acme"))
                                :perform (%ok :status 422 :body "card_declined"))
             (fail "should have signalled"))
    (http:http-error (e)
      (is (= 422 (http:http-error-status e)))
      (is (string= "card_declined" (http:http-error-body e)))
      (is (string= "acme" (http:http-error-label e))
          "the label names which call failed"))))

(test a-non-2xx-without-ensure-2xx-is-just-a-response
  ;; dexador would signal on a 404; capturing it as a response is what lets a LEAVE stage
  ;; decide what a status MEANS, rather than the transport deciding for it.
  (let ((resp (http:send-request (http:make-request :url "u") '()
                                 :perform (%ok :status 404 :body "nope"))))
    (is (= 404 (http:response-status resp)))
    (is (string= "nope" (http:response-body resp)))))

;;; --- what the move changed -------------------------------------------------

(test failure-is-an-http-error-not-a-messaging-condition
  ;; The one thing that could not move verbatim. The original signalled hermes'
  ;; DELIVERY-FAILURE from a general HTTP client, which is precisely what made it
  ;; unreusable -- a client has no business asserting that a *delivery* failed.
  (signals http:http-error
    (http:send-request (http:make-request :url "u") (list (http:ensure-2xx))
                       :perform (%ok :status 500))))

(test timeouts-survive-an-enter-stage
  ;; Added because the client's second consumer needed them and its first did not: praxeon
  ;; hand-rolled dexador partly because this could not express a read timeout. A header
  ;; stage rebuilds the request, so it must carry them or they are silently lost.
  (let ((seen nil))
    (http:send-request
     (http:make-request :url "u" :connect-timeout 3 :read-timeout 42)
     (list (http:add-header "A" "1"))
     :perform (lambda (req) (setf seen req) (http:make-response :status 200)))
    (is (= 3 (http:request-connect-timeout seen)))
    (is (= 42 (http:request-read-timeout seen))
        "a header stage must not reset the timeouts")))

;;; --- helpers ---------------------------------------------------------------

(test header-lookup-is-case-insensitive
  (let ((h (make-hash-table :test #'equal)))
    (setf (gethash "x-message-id" h) "abc")
    (is (string= "abc" (http:header-value h "X-Message-Id")))
    (is (null (http:header-value h "absent")))
    (is (null (http:header-value nil "anything")) "no headers is not an error")))

(test an-empty-chain-is-just-the-effect
  (is (string= "raw" (http:response-body
                      (http:send-request (http:make-request :url "u") '()
                                         :perform (%ok :body "raw"))))))

;;; --- pre-publication issue 223: the bytes that arrived, exactly ----------------------------------
;;;
;;; The client used to decode every body to a UTF-8 string and keep nothing else, so there
;;; was no path to the octets at all. A signed update cannot go through that: the signature
;;; is over the exact bytes of a file, and a decode is the re-encoding that invalidates it
;;; -- at a customer, on a version bump, months after anyone touched the code.

(defparameter +binary+
  (make-array 8 :element-type '(unsigned-byte 8)
                :initial-contents '(#xff #xd8 #xff #xe0 #x00 #x10 #x4a #x46))
  "The first eight bytes of a JPEG. Deliberately NOT valid UTF-8 -- #xff cannot begin a
UTF-8 sequence -- because that is the case the old contract silently destroyed.")

(defun %binary-ok (bytes)
  (lambda (req) (declare (ignore req)) (http:make-response :status 200 :bytes bytes)))

(test the-bytes-that-arrived-survive-byte-for-byte
  (let ((resp (http:send-request (http:make-request :url "https://x.example")
                                 (list (http:ensure-2xx)) :perform (%binary-ok +binary+))))
    (is (equalp +binary+ (http:response-bytes resp))
        "the octets were altered in transit through the client")))

(test the-old-contract-would-have-destroyed-those-bytes
  ;; Not a test of the client -- a test of the CLAIM the client is built on, so that the
  ;; reason for this design is checkable rather than asserted. Decode-then-re-encode is
  ;; exactly what a string-only response body did, and it is not the identity.
  (let ((round-tripped (sb-ext:string-to-octets
                        (sb-ext:octets-to-string
                         +binary+ :external-format '(:utf-8 :replacement #\ufffd))
                        :external-format :utf-8)))
    (is (not (equalp +binary+ round-tripped))
        "if this ever passes, the premise of pre-publication issue 223 is wrong and the design should be revisited")))

(test the-string-view-is-still-available-and-is-total
  ;; RESPONSE-BODY must not signal on bytes that are not UTF-8: ENSURE-2XX puts the body
  ;; into the condition it raises, so a strict decode breaks the error path on exactly the
  ;; responses one most needs reported.
  (let ((resp (http:make-response :status 200 :bytes +binary+)))
    (is (stringp (http:response-body resp)))
    ;; ...and the bytes are untouched by having asked for the lossy view.
    (is (equalp +binary+ (http:response-bytes resp)))))

(test a-non-2xx-with-a-binary-body-is-an-http-error-not-a-decode-error
  ;; The latent bug this contract change also fixes. The old code decoded strictly, INSIDE
  ;; a handler-case handler -- where a signal escapes the handler-case entirely -- so a
  ;; proxy's binary error page raised INVALID-UTF8-STARTER-BYTE instead of describing the
  ;; 502 that actually happened.
  (let ((perform (lambda (req) (declare (ignore req))
                   (http:make-response :status 502 :bytes +binary+))))
    (handler-case
        (progn (http:send-request (http:make-request :url "https://x.example")
                                  (list (http:ensure-2xx)) :perform perform)
               (fail "expected an HTTP-ERROR"))
      (http:http-error (e)
        (is (= 502 (http:http-error-status e)))
        ;; and it must be REPORTABLE -- the whole point of a total decode
        (is (stringp (format nil "~A" e))))
      (error (e)
        (fail "got ~A instead of HTTP-ERROR -- the decode failed, not the request"
              (type-of e))))))

(test a-string-body-still-round-trips-for-every-existing-consumer
  ;; hermes and praxeon pass strings to MAKE-RESPONSE in their stubs and read strings back.
  (let ((resp (http:make-response :status 200 :body "{\"ok\":true}")))
    (is (string= "{\"ok\":true}" (http:response-body resp)))
    (is (equalp (sb-ext:string-to-octets "{\"ok\":true}" :external-format :utf-8)
                (http:response-bytes resp)))))

(test multi-byte-utf-8-decodes-as-utf-8-and-not-as-latin-1
  ;; Guards the decode itself: "€" is three bytes, and a latin-1 reading would give three
  ;; characters rather than one.
  (let* ((text "price: €10")
         (resp (http:make-response :status 200
                                   :bytes (sb-ext:string-to-octets
                                           text :external-format :utf-8))))
    (is (string= text (http:response-body resp)))
    (is (= (length text) (length (http:response-body resp))))))

(test printing-a-response-does-not-dump-the-body
  ;; A response can now legitimately hold an installer; the default structure printer would
  ;; put megabytes of integers into any backtrace unwinding through it.
  (let ((printed (format nil "~S" (http:make-response :status 200 :bytes +binary+))))
    (is (null (search "255" printed)) "the printer dumped the body: ~S" printed)
    (is (search "200" printed))
    (is (search "8 bytes" printed))))

;;; === fetching a URL a user supplied (#295) ==========================================
;;;
;;; The tests below that need a transport run a small HTTP server on 127.0.0.1 inside this
;;; image, and a TLS one presenting the test certificate in tests/fixtures/http-client/. None
;;; reaches the network. FETCH-PUBLIC refuses loopback, so the tests that go through it to the
;;; server pass an ADDRESS-POLICY allowing exactly 127.0.0.1, and a RESOLVE that maps made-up
;;; names to chosen addresses.

(defun %fixture (name)
  (asdf:system-relative-pathname :aion/http-client/tests
                                 (format nil "tests/fixtures/http-client/~A" name)))

(defun %head-header (head name)
  (loop for line in (uiop:split-string head :separator (string #\Newline))
        for colon = (position #\: line)
        when (and colon (string-equal (string-trim " " (subseq line 0 colon)) name))
          return (string-trim '(#\Space #\Return) (subseq line (1+ colon)))))

;;; The server itself is aion/test-http's (#527). These wrappers keep this file's handlers in
;;; the shape they were written in, a function of (path head stream).

(defun %write-response (stream status headers body &key (content-length t))
  (aion/test-http:write-response stream status headers body :content-length content-length))

(defun server-port (server) (aion/test-http:server-port server))
(defun server-heads (server) (aion/test-http:server-heads server))

(defparameter +tls-certificate+
  #+os-windows "pinned-test-ec.crt" #-os-windows "pinned-test.crt"
  "The test server's certificate: an EC one on Windows, where aion/tls serves TLS and cannot
present the RSA one (see fixtures/http-client/README.md), the RSA one elsewhere.")
(defparameter +tls-key+ #+os-windows "pinned-test-ec.key" #-os-windows "pinned-test.key")

(defun %start-server (handler &key tls)
  "A server on 127.0.0.1 answering with HANDLER, a function of (path head stream) that writes
the response. Records every request head. TLS T presents the certificate for pinned.test
(+TLS-CERTIFICATE+, an EC one on Windows); TLS :IP presents the one whose names are the addresses
127.0.0.1 and ::1; a string names another fixture pair, \"cn-only-test\" for one such pair."
  (multiple-value-bind (certificate key)
      (cond ((stringp tls) (values (format nil "~A.crt" tls) (format nil "~A.key" tls)))
            ((eq tls :ip) (values "ip-test.crt" "ip-test.key"))
            (t (values +tls-certificate+ +tls-key+)))
    (aion/test-http:start-server
     (lambda (request stream)
       (funcall handler (aion/test-http:request-path request)
                (aion/test-http:request-head request) stream))
     :tls-certificate (and tls (%fixture certificate))
     :tls-key (and tls (%fixture key))
     :name "http-client test server")))

(defun %stop-server (server) (aion/test-http:stop-server server))

(defmacro with-server ((var handler &key tls) &body body)
  `(let ((,var (%start-server ,handler :tls ,tls)))
     (unwind-protect (progn ,@body) (%stop-server ,var))))

(defun %local (server path &optional (host "127.0.0.1") (scheme "http"))
  (format nil "~A://~A:~D~A" scheme host (server-port server) path))

(defun %requests (server) (length (server-heads server)))

(defmacro skip-on-windows (reason &body body)
  #+os-windows `(skip ,reason)
  #-os-windows `(progn ,@body))

;;; --- addresses ----------------------------------------------------------------------

(test address-categories
  "Every address fetch-public must not reach, and the public ones it may. The IPv6 forms that
carry an IPv4 address are classified by that address, so none of them is a way around the
IPv4 list."
  (dolist (case '(("127.0.0.1" :loopback) ("127.255.0.9" :loopback)
                  ("10.1.2.3" :private) ("172.16.0.1" :private) ("172.31.255.255" :private)
                  ("192.168.1.1" :private)
                  ("169.254.169.254" :link-local) ("169.254.0.1" :link-local)
                  ("100.64.0.1" :shared) ("0.0.0.0" :unspecified) ("0.1.2.3" :unspecified)
                  ("255.255.255.255" :broadcast) ("224.0.0.1" :multicast)
                  ("192.0.2.1" :documentation) ("198.18.0.1" :benchmarking)
                  ("240.0.0.1" :reserved)
                  ("::1" :loopback) ("::" :unspecified) ("[::1]" :loopback)
                  ("fe80::1" :link-local) ("fd00:ec2::254" :private) ("fc00::1" :private)
                  ("ff02::1" :multicast) ("2001:db8::1" :documentation)
                  ("::ffff:127.0.0.1" :loopback) ("::ffff:169.254.169.254" :link-local)
                  ("64:ff9b::a00:1" :private) ("2002:a9fe:a9fe::" :link-local)
                  ;; public
                  ("8.8.8.8" :public) ("172.32.0.1" :public) ("100.128.0.1" :public)
                  ("1.1.1.1" :public) ("::ffff:8.8.8.8" :public)
                  ("2606:4700:4700::1111" :public)))
    (is (eq (second case) (http:address-category (first case)))
        "~A should be ~S, got ~S" (first case) (second case)
        (http:address-category (first case)))))

(test only-an-address-parses-as-one
  (dolist (junk '("1.2.3" "256.1.1.1" "1.2.3.4.5" "example.com" "1::2::3" "12345::" "01.2.3.x"
                  ;; review of #312: a dotted part only as the last 32 bits
                  "1.2.3.4::" "1.2.3.4::5" "::1.2.3.4:5"))
    (is (null (http:parse-address junk)) "~S parsed as an address" junk))
  (is (equalp #(0 0 0 0 0 0 0 0 0 0 255 255 1 2 3 4) (http:parse-address "::ffff:1.2.3.4"))
      "control: a dotted part as the last 32 bits parses")
  ;; review of #312: anything that is not text or octets is not an address, and says so with
  ;; NIL rather than a type error
  (dolist (other (list nil 42 :localhost #(1 2 3 4 5)))
    (is (null (http:parse-address other)) "~S" other))
  (is (equalp #(10 0 0 5) (http:parse-address "10.0.0.5")))
  (is (string= "0:0:0:0:0:0:0:1" (http:address-string (http:parse-address "::1")))))

;;; --- redirect control and the body cap (every platform) ------------------------------

(defun %redirecting (path head stream)
  (declare (ignore head))
  (cond ((string= path "/") (%write-response stream 302 '(("Location" . "/next")) ""))
        ((string= path "/next") (%write-response stream 302 '(("Location" . "/end")) ""))
        (t (%write-response stream 200 '() "the end"))))

(test redirects-can-be-refused-capped-or-followed
  "FOLLOW-REDIRECTS NIL returns the 3xx itself; a cap stops after that many hops and returns
the 3xx it stopped at; the default follows to the end."
  (with-server (s #'%redirecting)
    (let ((none (http:send-request (http:make-request :url (%local s "/") :follow-redirects nil
                                                      :read-timeout 5)
                                   '())))
      (is (= 302 (http:response-status none)))
      (is (= 1 (%requests s))))
    (let ((one (http:send-request (http:make-request :url (%local s "/") :follow-redirects 1
                                                     :read-timeout 5)
                                  '())))
      (is (= 302 (http:response-status one)) "stopped at the second redirect")
      (is (= 3 (%requests s))))
    (let ((all (http:send-request (http:make-request :url (%local s "/") :read-timeout 5) '())))
      (is (= 200 (http:response-status all)))
      (is (string= "the end" (http:response-body all))))))

(test a-body-over-the-cap-is-refused-with-or-without-content-length
  "A declared Content-Length over the cap is refused before the body is read. Without one, the
read stops at the cap. Control: a body exactly at the cap is returned whole."
  (let ((body (make-array 5000 :element-type '(unsigned-byte 8) :initial-element 65)))
    (with-server (s (lambda (path head stream)
                      (declare (ignore head))
                      (%write-response stream 200 '() body
                                       :content-length (string= path "/declared"))))
      (dolist (path '("/declared" "/undeclared"))
        (handler-case
            (progn (http:send-request (http:make-request :url (%local s path) :max-body-bytes 1000
                                                         :read-timeout 5)
                                      '())
                   (fail "expected RESPONSE-TOO-LARGE for ~A" path))
          (http:response-too-large (e)
            (is (= 1000 (http:response-too-large-limit e))))))
      (let ((ok (http:send-request (http:make-request :url (%local s "/declared")
                                                      :max-body-bytes 5000 :read-timeout 5)
                                   '())))
        (is (= 5000 (length (http:response-bytes ok))))))))

;;; --- a pinned connection -----------------------------------------------

(test a-pinned-connection-keeps-the-host-name-in-the-host-header
  "pinned.test does not resolve anywhere, so the request can only have reached the server
through CONNECT-ADDRESS; the server received the name, not the address."
  (progn
    (with-server (s (lambda (path head stream)
                      (declare (ignore path head))
                      (%write-response stream 200 '() "pinned")))
      (let ((r (http:send-request (http:make-request :url (%local s "/" "pinned.test")
                                                     :connect-address "127.0.0.1"
                                                     :read-timeout 5)
                                  '())))
        (is (string= "pinned" (http:response-body r)))
        (is (string= (format nil "pinned.test:~D" (server-port s))
                     (%head-header (first (server-heads s)) "Host")))))))

(test a-pinned-tls-connection-verifies-the-host-name-not-the-address
  "Connected to 127.0.0.1, the certificate for pinned.test is accepted for https://pinned.test
and refused for https://other.test, so verification used the URL's name. Control for the trust
root: without CA-PATH the self-signed certificate is refused as well."
  (progn
    (with-server (s (lambda (path head stream)
                      (declare (ignore path head))
                      (%write-response stream 200 '() "over tls"))
                    :tls t)
      (flet ((get-as (host &key (ca (%fixture +tls-certificate+)))
               (http:send-request (http:make-request :url (%local s "/" host "https")
                                                     :connect-address "127.0.0.1"
                                                     :ca-path ca :read-timeout 5)
                                  '())))
        (let ((r (get-as "pinned.test")))
          (is (string= "over tls" (http:response-body r)))
          (is (string= (format nil "pinned.test:~D" (server-port s))
                       (%head-header (first (server-heads s)) "Host"))))
        (signals http:http-error (get-as "other.test"))
        (signals http:http-error (get-as "pinned.test" :ca nil))))))

(test a-pinned-tls-connection-to-an-ip-literal-verifies-the-address-without-brackets
  "#915: for https://[::1]/ the client sends no SNI name, since RFC 6066 does not allow an
address there, and verifies the certificate against ::1, the address without the brackets the URL
puts round it. The certificate's names are the addresses 127.0.0.1 and ::1. Before the fix the name
verified was \"[::1]\", which no certificate holds, so this request was refused. Controls: [::2],
an address the certificate does not name, is refused; the IPv4 literal is accepted; the host name
other.test and ip.test are refused. ip.test is the certificate's common name, which cl+ssl's own
check accepts; since #917 a certificate with alternative names must match one of them."
  (skip-on-windows "ip-test.key is a PKCS#8 RSA key, which the aion/tls test server refuses (#914)"
    (with-server (s (lambda (path head stream)
                      (declare (ignore path head))
                      (%write-response stream 200 '() "over tls"))
                    :tls :ip)
      (flet ((get-as (host)
               (http:send-request (http:make-request :url (%local s "/" host "https")
                                                     :connect-address "127.0.0.1"
                                                     :ca-path (%fixture "ip-test.crt")
                                                     :read-timeout 5)
                                  '())))
        (is (string= "over tls" (http:response-body (get-as "[::1]"))))
        (is (string= "over tls" (http:response-body (get-as "[0:0:0:0:0:0:0:1]"))))
        (is (string= "over tls" (http:response-body (get-as "127.0.0.1"))))
        (signals http:http-error (get-as "[::2]"))
        (signals http:http-error (get-as "127.0.0.2"))
        (signals http:http-error (get-as "other.test"))
        (signals http:http-error (get-as "ip.test"))))))

(defun %get-pinned-as (server host ca)
  "A GET of https://HOST:port/ from SERVER, pinned to 127.0.0.1 and trusting the fixture CA."
  (http:send-request (http:make-request :url (%local server "/" host "https")
                                        :connect-address "127.0.0.1"
                                        :ca-path (%fixture ca) :read-timeout 5)
                     '()))

(test a-certificate-with-alternative-names-is-not-matched-by-its-common-name
  "#917: the certificate's common name is cn.test and its only alternative name is san.test.
https://san.test/ is accepted and https://cn.test/ is refused, because a certificate with
alternative names must match one of them (RFC 6125 section 6.4.4). cl+ssl's own check accepts
cn.test through the common name; before #917 nothing else was checked, so it was accepted."
  (skip-on-windows "a pinned connection is not available on Windows (WinHTTP)"
    (with-server (s (lambda (path head stream)
                      (declare (ignore path head))
                      (%write-response stream 200 '() "over tls"))
                    :tls "cn-and-san-test")
      (is (string= "over tls"
                   (http:response-body (%get-pinned-as s "san.test" "cn-and-san-test.crt"))))
      (is (string= "over tls"
                   (http:response-body (%get-pinned-as s "SAN.test" "cn-and-san-test.crt")))
          "matched as cl+ssl matches, ignoring case")
      (signals http:http-error (%get-pinned-as s "cn.test" "cn-and-san-test.crt")))))

(test a-certificate-without-alternative-names-is-matched-by-its-common-name
  "#917: a certificate with no alternative names, whose common name is cn-only.test, is accepted
for https://cn-only.test/. Control: it is refused for other.test."
  (skip-on-windows "a pinned connection is not available on Windows (WinHTTP)"
    (with-server (s (lambda (path head stream)
                      (declare (ignore path head))
                      (%write-response stream 200 '() "over tls"))
                    :tls "cn-only-test")
      (is (string= "over tls"
                   (http:response-body (%get-pinned-as s "cn-only.test" "cn-only-test.crt"))))
      (signals http:http-error (%get-pinned-as s "other.test" "cn-only-test.crt")))))

(test tls-names-gives-no-sni-name-for-an-ip-literal
  "#915: the SNI name and the name verified, for each kind of host."
  (flet ((names (host) (multiple-value-list (http::%tls-names host))))
    (is (equal '(nil "::1") (names "[::1]")))
    (is (equal '(nil "::1") (names "[0:0:0:0:0:0:0:1]")))
    (is (equal '(nil "127.0.0.1") (names "127.0.0.1")))
    (is (equal '("pinned.test" "pinned.test") (names "pinned.test")))))

(test the-cl+ssl-patch-for-openssl-4-is-in-place
  "#706: aion/http-client points cl+ssl's ASN1-STRING-DATA at ASN1_STRING_get0_data, because
OpenSSL 4 removed ASN1_STRING_data, which cl+ssl calls to read a certificate's names. This fails
when the patch is missing, and when a later load of cl+ssl has put the old definition back. On a
host whose libcrypto is OpenSSL 4, the pinned test above fails as well. Remove the patch and this
test once the pinned cl+ssl contains cl-plus-ssl pull request 202."
  (skip-on-windows "cl+ssl is not used on Windows"
    ;; Read only off Windows: there is no CL+SSL package on Windows.
    #-os-windows
    (is (eq (fdefinition 'cl+ssl::asn1-string-get0-data) (fdefinition 'cl+ssl::asn1-string-data))
        "cl+ssl::asn1-string-data is the call to ASN1_STRING_get0_data")))

;;; --- fetch-public ---------------------------------------------------------------------

(defun %resolver (table)
  "A RESOLVE for FETCH-PUBLIC: host name -> list of address strings, from TABLE."
  (lambda (host)
    (let ((entry (assoc host table :test #'string-equal)))
      (if entry
          (mapcar #'http:parse-address (cdr entry))
          (http:resolve-host host)))))

(defun %never-called ()
  (lambda (req) (fail "no connection should have been made, but one was, to ~A" (http:request-url req))
    (http:make-response :status 599)))

(test fetch-public-refuses-before-connecting
  "Loopback, private, link-local and metadata addresses, a name resolving to any of them even
alongside a public one, a scheme that is not http or https, and a name that does not resolve.
Nothing connects."
  (let ((resolve (%resolver '(("internal.test" "10.0.0.5")
                              ("metadata.test" "169.254.169.254")
                              ("both.test" "8.8.8.8" "10.0.0.1")
                              ("nowhere.test")))))
    (dolist (case '(("http://internal.test/" :private)
                    ("http://metadata.test/latest/meta-data/" :link-local)
                    ("http://169.254.169.254/" :link-local)
                    ("http://127.0.0.1:8080/" :loopback)
                    ("http://[::1]/" :loopback)
                    ("http://[::ffff:127.0.0.1]/" :loopback)
                    ("http://both.test/" :private)
                    ("http://nowhere.test/" :unresolvable)
                    ("file:///etc/passwd" :scheme)
                    ("gopher://example.com/" :scheme)))
      (handler-case (progn (http:fetch-public (first case) :resolve resolve :perform (%never-called))
                           (fail "~A was not refused" (first case)))
        (http:fetch-refused (e)
          (is (eq (second case) (http:fetch-refused-reason e))
              "~A: expected ~S, got ~S" (first case) (second case) (http:fetch-refused-reason e)))))))

(test fetch-public-pins-the-address-it-checked
  (let ((seen nil))
    (http:fetch-public "http://public.test/" :resolve (%resolver '(("public.test" "93.184.216.34")))
                                             :perform (lambda (req) (setf seen req)
                                                        (http:make-response :status 200)))
    (is (equalp #(93 184 216 34) (http:request-connect-address seen)))
    (is (null (http:request-follow-redirects seen)) "dexador follows nothing itself")
    (is (= http:*fetch-public-max-body-bytes* (http:request-max-body-bytes seen)))))

(defun %loopback-allowed (address)
  "Test policy: the test server's 127.0.0.1 counts as public; everything else as usual."
  (if (equalp address #(127 0 0 1)) :public (http:address-category address)))

(test fetch-public-keeps-the-body-of-an-error-response
  "The body of a 400 fetched over a pinned connection is the body the server sent. It used to
be lost, because the connection was closed before the body was read (#527)."
  (progn
    (with-server (s (lambda (path head stream)
                      (declare (ignore path head))
                      (%write-response stream 400 '(("Content-Type" . "application/json"))
                                       "{\"error\":\"invalid_grant\"}")))
      (let ((r (http:fetch-public (%local s "/token" "start.test")
                                  :resolve (%resolver '(("start.test" "127.0.0.1")))
                                  :address-policy #'%loopback-allowed :read-timeout 5)))
        (is (= 400 (http:response-status r)))
        (is (equal "{\"error\":\"invalid_grant\"}" (http:response-body r)))))))

(defun %slow-handler (done)
  "A handler that declares a 10-byte body and then sends one byte every 2 seconds, until DONE,
a function of no arguments, returns true."
  (lambda (path head stream)
    (declare (ignore path head))
    (ignore-errors
     (aion/test-http:write-head stream 200 '(("Content-Type" . "text/plain")
                                             ("Content-Length" . 10) ("Connection" . "close")))
     (loop repeat 10 until (funcall done)
           do (write-byte 97 stream)
              (finish-output stream)
              (loop repeat 20 until (funcall done) do (sleep 0.1))))))

(defun %slow-fetch (server &rest options)
  (apply #'http:fetch-public (%local server "/" "slow.test")
         :resolve (%resolver '(("slow.test" "127.0.0.1")))
         :address-policy #'%loopback-allowed :read-timeout 5
         options))

(test fetch-public-stops-at-its-deadline-while-a-fetch-without-one-is-still-reading
  "A server that sends a byte every 2 seconds never trips a 5-second read timeout. With
:DEADLINE 3 the fetch signals FETCH-DEADLINE-EXCEEDED after about 3 seconds; a fetch of the
same kind of server with no deadline is still reading at that point (#807)."
  (progn
    (let ((done nil))
      (with-server (slow (%slow-handler (lambda () done)))
        (with-server (other (%slow-handler (lambda () done)))
          ;; THREAD-LIFETIME: reads OTHER until the cleanup below sets DONE, which ends the
          ;; handler and closes the connection, so the fetch fails and the thread returns; the
          ;; JOIN waits for that.
          (let ((control (bt:make-thread (lambda () (ignore-errors (%slow-fetch other)))
                                         :name "fetch without a deadline")))
            (unwind-protect
                 (let* ((start (get-internal-real-time))
                        (c (handler-case (progn (%slow-fetch slow :deadline 3) nil)
                             (http:fetch-deadline-exceeded (c) c)))
                        (seconds (/ (- (get-internal-real-time) start)
                                    internal-time-units-per-second)))
                   (is (typep c 'http:fetch-deadline-exceeded))
                   (is (< 2.5 seconds 6) "it ended after ~,1F seconds" seconds)
                   (is (eql 3 (and c (http:fetch-deadline-exceeded-deadline c))))
                   (is (bt:thread-alive-p control)
                       "the fetch without a deadline is still reading"))
              (setf done t)
              (aion/test-threads:join control))))))))

(defun %deadline-timers ()
  (remove "fetch-public deadline" (sb-ext:list-all-timers)
          :key #'sb-ext:timer-name :test-not #'equal))

(defun %deadline-threads ()
  (remove "fetch-public deadline" (bt:all-threads) :key #'bt:thread-name :test-not #'equal))

(test a-fetch-that-ends-before-its-deadline-leaves-no-timer-or-thread
  "The deadline's timer is unscheduled whether the fetch returns or signals, so no timer is left
to fire later and no thread is started for it (#807)."
  (progn
    (with-server (s (lambda (path head stream)
                      (declare (ignore path head))
                      (%write-response stream 200 '(("Content-Type" . "text/plain")) "ok")))
      (is (null (%deadline-timers)) "none before")
      (let ((r (http:fetch-public (%local s "/" "fast.test")
                                  :resolve (%resolver '(("fast.test" "127.0.0.1")))
                                  :address-policy #'%loopback-allowed
                                  :read-timeout 5 :deadline 30)))
        (is (equal "ok" (http:response-body r))))
      (is (null (%deadline-timers)) "none after a fetch that returned")
      (signals http:fetch-refused
        (http:fetch-public "http://10.0.0.1/" :deadline 30 :perform (%never-called)))
      (is (null (%deadline-timers)) "none after a fetch that signalled")
      (is (null (%deadline-threads)) "no thread was started"))))

(test a-deadline-works-on-every-platform-and-leaves-no-timer
  "With a stub effect, a fetch with a deadline returns, or signals the effect's own failure, and
leaves no timer scheduled. This runs on Windows too, where a form the reader dropped once left
the deadline number where the watch belonged (#807)."
  (let ((resolve (%resolver '(("public.test" "93.184.216.34")))))
    (is (= 200 (http:response-status
                (http:fetch-public "http://public.test/" :deadline 30 :resolve resolve
                                                         :perform (%ok :body "x")))))
    (is (null (%deadline-timers)) "none after a fetch that returned")
    (signals http:http-error
      (http:fetch-public "http://public.test/" :deadline 30 :resolve resolve
                                               :perform (lambda (req)
                                                          (declare (ignore req))
                                                          (error 'http:http-error :detail "stub"))))
    (is (null (%deadline-timers)) "none after a fetch whose effect signalled")))

(test fetch-public-returns-an-empty-response
  "A 404 with an empty body is an ordinary response: status 404, no bytes. It used to fail with
CLOSED-STREAM-ERROR, because the connection was closed before the body was read (#527)."
  (progn
    (with-server (s (lambda (path head stream)
                      (declare (ignore path head))
                      (%write-response stream 404 '() "")))
      (let ((r (http:fetch-public (%local s "/missing" "start.test")
                                  :resolve (%resolver '(("start.test" "127.0.0.1")))
                                  :address-policy #'%loopback-allowed :read-timeout 5)))
        (is (= 404 (http:response-status r)))
        (is (zerop (length (http:response-bytes r))))))))

(test every-redirect-hop-is-checked-again
  "A public-looking URL redirects to one that resolves to the metadata address; that hop is
refused, and the server saw only the first request. Control: a redirect to an allowed host is
followed."
  (progn
    (with-server (s (lambda (path head stream)
                      (declare (ignore head))
                      (cond ((string= path "/to-metadata")
                             (%write-response stream 302 '(("Location" . "http://metadata.test/latest")) ""))
                            ((string= path "/to-self")
                             (%write-response stream 302 `(("Location" . "/ok")) ""))
                            (t (%write-response stream 200 '() "ok")))))
      (let ((resolve (%resolver '(("start.test" "127.0.0.1") ("metadata.test" "169.254.169.254")))))
        (handler-case
            (progn (http:fetch-public (%local s "/to-metadata" "start.test")
                                      :resolve resolve :address-policy #'%loopback-allowed
                                      :read-timeout 5)
                   (fail "the redirect to metadata.test was followed"))
          (http:fetch-refused (e)
            (is (eq :link-local (http:fetch-refused-reason e)))
            (is (string= "metadata.test" (http:fetch-refused-host e)))))
        (is (= 1 (%requests s)))
        (let ((r (http:fetch-public (%local s "/to-self" "start.test")
                                    :resolve resolve :address-policy #'%loopback-allowed
                                    :read-timeout 5)))
          (is (= 200 (http:response-status r)))
          (is (= 3 (%requests s))))))))

(test fetch-public-stops-after-max-redirects
  (let ((calls 0))
    (handler-case
        (progn
          (http:fetch-public "http://loop.test/" :max-redirects 3
                                                 :resolve (%resolver '(("loop.test" "93.184.216.34")))
                                                 :perform (lambda (req) (declare (ignore req)) (incf calls)
                                                            (http:make-response
                                                             :status 302 :headers (%headers "location" "/again"))))
          (fail "expected TOO-MANY-REDIRECTS"))
      (http:too-many-redirects (e)
        (is (= 3 (http:too-many-redirects-limit e)))))
    (is (= 4 calls) "the first request and three redirects")))

(defun %headers (&rest kvs)
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on kvs by #'cddr do (setf (gethash k h) v))
    h))

(test a-redirect-to-another-origin-drops-credentials-and-a-303-becomes-a-get
  "Authorization and Cookie are not sent to a host the caller did not name. A 303 after a
POST is followed with a GET and no body. Control: a 307 on the same origin keeps both."
  (let ((seen '())
        (resolve (%resolver '(("a.test" "93.184.216.34") ("b.test" "93.184.216.35")))))
    (flet ((perform (req)
             (push req seen)
             (let ((url (quri:uri-path (quri:uri (http:request-url req)))))
               (cond ((string= "/start" url)
                      (http:make-response :status 303 :headers (%headers "location" "http://b.test/landing")))
                     ((string= "/same" url)
                      (http:make-response :status 307 :headers (%headers "location" "/same-2")))
                     (t (http:make-response :status 200))))))
      (http:fetch-public "http://a.test/start" :method :post :content "x=1"
                                                :headers '(("Authorization" . "Bearer k") ("Cookie" . "s=1")
                                                           ("Accept" . "text/html"))
                                                :resolve resolve :perform #'perform)
      (let ((second (first seen)) (first-req (second seen)))
        (is (assoc "Authorization" (http:request-headers first-req) :test #'string-equal))
        (is (string= "http://b.test/landing" (http:request-url second)))
        (is (eq :get (http:request-method second)))
        (is (null (http:request-content second)))
        (is (null (assoc "Authorization" (http:request-headers second) :test #'string-equal)))
        (is (null (assoc "Cookie" (http:request-headers second) :test #'string-equal)))
        (is (assoc "Accept" (http:request-headers second) :test #'string-equal)))
      (setf seen '())
      (http:fetch-public "http://a.test/same" :method :post :content "x=1"
                                               :headers '(("Authorization" . "Bearer k"))
                                               :resolve resolve :perform #'perform)
      (let ((second (first seen)))
        (is (eq :post (http:request-method second)))
        (is (equal "x=1" (http:request-content second)))
        (is (assoc "Authorization" (http:request-headers second) :test #'string-equal))))))

(test fetch-public-returns-the-url-of-the-last-hop
  "The second value is the URL the response came from: the redirect's target, resolved against
the URL that redirected, and the URL itself when nothing redirected (#757)."
  (let ((resolve (%resolver '(("a.test" "93.184.216.34") ("b.test" "93.184.216.35")))))
    (flet ((perform (req)
             (let ((path (quri:uri-path (quri:uri (http:request-url req)))))
               (cond ((string= "/start" path)
                      (http:make-response :status 301 :headers (%headers "location" "http://b.test/moved")))
                     ((string= "/moved" path)
                      (http:make-response :status 302 :headers (%headers "location" "final?x=1")))
                     (t (http:make-response :status 200))))))
      (multiple-value-bind (r url) (http:fetch-public "http://a.test/start" :resolve resolve
                                                                            :perform #'perform)
        (is (= 200 (http:response-status r)))
        (is (string= "http://b.test/final?x=1" url)))
      (is (string= "http://a.test/plain"
                   (nth-value 1 (http:fetch-public "http://a.test/plain" :resolve resolve
                                                                         :perform #'perform)))))))

(test a-url-without-a-port-connects-to-its-scheme-default
  "Review of #312: QURI-PORT is NIL when the URL gives no port, and the pinned connection must
then use 80 for http and 443 for https, not NIL. Checked on the function that chooses the port,
since binding 80 or 443 in a test needs privileges."
  (is (= 80 (http::%port-of (quri:uri "http://example.com/path"))))
  (is (= 443 (http::%port-of (quri:uri "https://example.com/"))))
  (is (= 8443 (http::%port-of (quri:uri "https://example.com:8443/"))) "an explicit port wins")
  (is (equal (http::%origin (quri:uri "https://example.com/"))
             (http::%origin (quri:uri "https://example.com:443/x")))
      "the default port and the same port written out are one origin"))

;;; --- a request prints without its secrets (#844) ---------------------------------

(defparameter +printed-secrets+ '("Bearer SECRET-auth-111" "SECRET-goog-222" "SECRET-api-333"
                                  "session=SECRET-cookie-444"))

(defun %secret-request (&rest args)
  (apply #'http:make-request
         :method :post
         :headers (list (cons "authorization" "Bearer SECRET-auth-111")
                        (cons "x-goog-api-key" "SECRET-goog-222")
                        (cons "x-api-key" "SECRET-api-333")
                        (cons "cookie" "session=SECRET-cookie-444")
                        (cons "X-Custom-Token" "SECRET-custom-555"))
         args))

(defun %printings (object)
  "OBJECT printed every way a log line, an error report or a debugger prints it."
  (list (prin1-to-string object) (princ-to-string object)
        (format nil "~A ~S" object object) (format nil "~A" (list object))
        (let ((*print-escape* nil)) (prin1-to-string object))))

(defun %leaked (text)
  (remove-if-not (lambda (s) (search s text))
                 '("SECRET-auth-111" "SECRET-goog-222" "SECRET-api-333" "SECRET-cookie-444"
                   "SECRET-custom-555" "SECRET-query-666" "SECRET-pass-777" "SECRET-body-888")))

(test a-printed-request-hides-every-header-value
  "Every header's value is hidden, not only known ones: X-Custom-Token stands for a provider's own
key header. The names stay, so a reader can see which headers were sent."
  (let ((req (%secret-request :url "https://api.example.com/v1/images")))
    (dolist (text (%printings req))
      (is (null (%leaked text)) "~S in ~A" (%leaked text) text)
      (is (search "authorization=<hidden>" text) "~A" text)
      (is (search "x-goog-api-key=<hidden>" text) "~A" text)
      (is (search "X-Custom-Token=<hidden>" text) "~A" text)
      (is (search "https://api.example.com/v1/images" text) "the URL is shown: ~A" text)
      (is (search "POST" text)))))

(test a-printed-request-hides-query-values-the-user-part-and-the-body
  (let ((req (%secret-request :url "https://user:SECRET-pass-777@api.example.com/v1/x?key=SECRET-query-666&model=fast"
                              :content "{\"prompt\":\"SECRET-body-888\"}")))
    (dolist (text (%printings req))
      (is (null (%leaked text)) "~S in ~A" (%leaked text) text)
      (is (search "https://<hidden>@api.example.com/v1/x?key=<hidden>&model=<hidden>" text) "~A" text)
      (is (search "body: 28 characters" text) "the body's size, not the body: ~A" text)))
  (is (search "body: 3 bytes" (prin1-to-string (http:make-request :url "https://x.example" :content (make-array 3 :element-type '(unsigned-byte 8))))))
  (is (search "body: 2 fields" (prin1-to-string (http:make-request :url "https://x.example" :content '(("a" . "SECRET-body-888") ("b" . "2"))))))
  (is (null (%leaked (prin1-to-string (http:make-request :url "https://x.example" :content '(("a" . "SECRET-body-888")))))))
  (is (string= "#<AION/HTTP-CLIENT:REQUEST GET https://x.example>"
               (let ((*package* (find-package :cl-user))) (prin1-to-string (http:make-request :url "https://x.example"))))
      "the control: a request with nothing to hide prints its method and URL"))

(defun %fail-holding (req)
  "Signal while REQ is this frame's argument, as SEND-REQUEST's frames hold it while a request is
sent."
  (declare (optimize (debug 2)))
  (when (http:request-p req)
    (error "the transport failed"))
  req)

(test a-backtrace-through-a-frame-holding-a-request-shows-no-secret
  "A debugger or a logged backtrace prints each frame's arguments; a request among them used to
print with its headers."
  (let ((trace (with-output-to-string (out)
                 (handler-case
                     (handler-bind ((error (lambda (c) (declare (ignore c))
                                             (sb-debug:print-backtrace :stream out :count 30))))
                       (%fail-holding (%secret-request :url "https://api.example.com/v1/x?key=SECRET-query-666")))
                   (error () nil)))))
    (is (search "%FAIL-HOLDING" trace) "the frame is in the backtrace")
    (is (search "REQUEST POST" trace)
        "precondition: the request is printed in it, so the next check is not vacuous: ~A"
        (subseq trace 0 (min 600 (length trace))))
    (is (null (%leaked trace)) "~S in the backtrace" (%leaked trace))))

;;; --- a body of octets with a multipart type arrives as sent (#828) ---------------------

(defun %multipart-octets (boundary)
  "A multipart/form-data body with a text field and a binary file part, encoded by hand."
  (flet ((text (control &rest args)
           (sb-ext:string-to-octets (apply #'format nil control args) :external-format :utf-8)))
    (let ((crlf (format nil "~C~C" #\Return #\Linefeed)))
      (concatenate '(vector (unsigned-byte 8))
                   (text "--~A~A" boundary crlf)
                   (text "Content-Disposition: form-data; name=\"prompt\"~A~A" crlf crlf)
                   (text "a red kite~A--~A~A" crlf boundary crlf)
                   (text "Content-Disposition: form-data; name=\"image\"; filename=\"kite.png\"~A"
                         crlf)
                   (text "Content-Type: image/png~A~A" crlf crlf)
                   (coerce '(137 80 78 71 13 10 26 10 0 255 254 1) '(vector (unsigned-byte 8)))
                   (text "~A--~A--~A" crlf boundary crlf)))))

(defun %send-and-capture (content content-type)
  "Send CONTENT with CONTENT-TYPE through the real client to a local server; return the
request the server read."
  (aion/test-http:with-server
      (server (lambda (request stream) (declare (ignore request))
                (aion/test-http:write-response stream 200 '() "ok")))
    (http:send-request (http:make-request :method :post
                                          :url (aion/test-http:server-url server "/edits")
                                          :headers (list (cons "Content-Type" content-type))
                                          :content content :read-timeout 10)
                       (list (http:ensure-2xx)))
    (first (aion/test-http:server-requests server))))

(test multipart-octets-arrive-as-sent
  "A body the caller encoded as multipart/form-data reaches the server byte for byte, and its
Content-Type value is the one given (#828). Dexador's usocket backend would otherwise rebuild the
body from an alist and fail on these octets; this test is what notices if a dexador update
changes that check. The control sends octets of another type, whose header is untouched."
  (let* ((boundary "hermes-Kq7xV2-boundary")
         (body (%multipart-octets boundary))
         (type (format nil "multipart/form-data; boundary=~A" boundary))
         (got (%send-and-capture body type))
         (header (aion/test-http:request-header got "Content-Type")))
    (is (equalp body (aion/test-http:request-body got)) "the body arrives byte for byte")
    (is (string= type (string-trim " " header))
        "the Content-Type value is the one given: ~S" header)
    (is (search (format nil "boundary=~A" boundary) (aion/test-http:request-head got))
        "with the caller's boundary, not one of dexador's"))
  (let* ((body (coerce '(1 2 3 4) '(vector (unsigned-byte 8))))
         (got (%send-and-capture body "application/octet-stream")))
    (is (equalp body (aion/test-http:request-body got)))
    (is (search (format nil "Content-Type: application/octet-stream~C" #\Return)
                (aion/test-http:request-head got))
        "the control: another type is sent exactly, with no added space")))

(test the-multipart-workaround-applies-only-where-dexador-needs-it
  (flet ((sent-type (content type)
           (let ((req (http:make-request :url "https://x.example" :content content
                                         :headers (list (cons "Content-Type" type)))))
             (cdr (assoc "Content-Type" (http::%dex-headers req) :test #'string-equal)))))
    (let ((octets (coerce '(1 2) '(vector (unsigned-byte 8))))
          (form "multipart/form-data; boundary=x"))
      #-os-windows
      (progn
        (is (string= (concatenate 'string " " form) (sent-type octets form)))
        (is (string= " Multipart/Mixed; boundary=x"
                     (sent-type octets "Multipart/Mixed; boundary=x"))
            "in any case"))
      #+os-windows
      (is (string= form (sent-type octets form))
          "WinHTTP sends octets as given, so Windows' header is unchanged")
      (is (string= "application/json" (sent-type octets "application/json"))
          "only a multipart type")
      (is (string= "multipart/form-data" (sent-type "a string body" "multipart/form-data"))
          "only a body of octets: dexador's own multipart handling of other bodies is left alone")
      (is (string= "multipart/form-data"
                   (sent-type '(("field" . "value")) "multipart/form-data"))))))

;;; --- the HTTP/1.1 exchange a pinned connection uses on Windows (#536) ---------------------
;;;
;;; http1.lisp reads responses from servers a user named, so these feed it well-formed and
;;; malformed responses from memory. Compiled and run on every platform, though only Windows'
;;; pinned path uses it. Every refusal must be MALFORMED-RESPONSE, an HTTP-ERROR, so that %HTTP
;;; passes it on as itself.

(defclass %octet-input (sb-gray:fundamental-binary-input-stream)
  ((octets :initarg :octets :reader %octets)
   (at :initform 0 :accessor %at)))

(defmethod stream-element-type ((s %octet-input)) '(unsigned-byte 8))

(defmethod sb-gray:stream-read-byte ((s %octet-input))
  (if (< (%at s) (length (%octets s)))
      (prog1 (aref (%octets s) (%at s)) (incf (%at s)))
      :eof))

(defun %crlf (&rest lines)
  "LINES joined with CRLF, as octets. A line that is a vector of octets is used as it is."
  (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (dolist (l lines (coerce out '(simple-array (unsigned-byte 8) (*))))
      (loop for b across (if (stringp l) (sb-ext:string-to-octets l :external-format :latin-1) l)
            do (vector-push-extend b out))
      (vector-push-extend 13 out)
      (vector-push-extend 10 out))))

(defun %parse (octets &key (method :get))
  "Read the response in OCTETS: (values STATUS FIELDS BODY-OCTETS)."
  (let ((in (make-instance '%octet-input :octets octets)))
    (multiple-value-bind (status fields) (http::read-response-head in)
      (let ((body (http::response-body-stream in (http::response-framing method status fields)
                                              (lambda () nil))))
        (values status fields
                (coerce (loop for b = (read-byte body nil nil) while b collect b)
                        '(vector (unsigned-byte 8))))))))

(defun %text (octets) (sb-ext:octets-to-string (coerce octets '(vector (unsigned-byte 8))) :external-format :latin-1))

(test http1-reads-each-framing
  (multiple-value-bind (status fields body)
      (%parse (%crlf "HTTP/1.1 200 OK" "Content-Length: 5" "X-A: 1" "x-a: 2" "" "helloEXTRA"))
    (is (= 200 status))
    (is (string= "hello" (%text body)) "Content-Length stops the body: ~S" (%text body))
    (is (string= "1, 2" (gethash "x-a" fields)) "repeated fields are joined as dexador joins them"))
  (multiple-value-bind (status fields body)
      (%parse (%crlf "HTTP/1.1 200 OK" "Transfer-Encoding: chunked" ""
                     "3;ext=1" "abc" "A" "0123456789" "0" "Trailer-X: t" ""))
    (declare (ignore fields))
    (is (= 200 status))
    (is (string= "abc0123456789" (%text body))))
  (is (string= "to the close"
               (%text (nth-value 2 (%parse (concatenate '(vector (unsigned-byte 8))
                                                        (%crlf "HTTP/1.1 200 OK" "")
                                                        (sb-ext:string-to-octets "to the close")))))))
  (is (zerop (length (nth-value 2 (%parse (%crlf "HTTP/1.1 204 No Content" "Content-Length: 7" "" "ignored"))))))
  (is (zerop (length (nth-value 2 (%parse (%crlf "HTTP/1.1 200 OK" "Content-Length: 7" "" "ignored")
                                          :method :head)))))
  (is (= 200 (%parse (%crlf "HTTP/1.1 100 Continue" "" "HTTP/1.1 200 OK" "Content-Length: 0" "")))
      "an interim response is skipped")
  (is (string= "abc" (%text (nth-value 2 (%parse (%crlf "HTTP/1.1 200 OK" "Content-Length: 3, 3" "" "abc")))))
      "Content-Length sent twice with one value is that value"))

(defun %refused-p (octets &key (method :get))
  "Whether reading OCTETS signals MALFORMED-RESPONSE. Any other error is a test failure."
  (handler-case (progn (%parse octets :method method) nil)
    (http:malformed-response () t)))

(test http1-refuses-what-could-be-framed-two-ways
  "Request smuggling needs a response a proxy and a client frame differently."
  (is-true (%refused-p (%crlf "HTTP/1.1 200 OK" "Content-Length: 3" "Transfer-Encoding: chunked" "" "0" "")))
  (is-true (%refused-p (%crlf "HTTP/1.1 200 OK" "Transfer-Encoding: gzip, chunked" "" "0" "")))
  (is-true (%refused-p (%crlf "HTTP/1.1 200 OK" "Content-Length: 3" "Content-Length: 4" "" "abcd")))
  (is-true (%refused-p (%crlf "HTTP/1.1 200 OK" "Content-Length: 3, 4" "" "abcd")))
  (is-true (%refused-p (%crlf "HTTP/1.1 200 OK" "Content-Length: +3" "" "abc")))
  (is-true (%refused-p (%crlf "HTTP/1.1 200 OK" "Content-Length: 0x3" "" "abc")))
  (is-true (%refused-p (%crlf "HTTP/1.1 200 OK" "Content-Length: 99999999999999999999" "" "abc"))))

(test http1-refuses-a-head-outside-the-grammar
  (dolist (bad (list (%crlf "HTTP/2 200 OK" "" "")
                     (%crlf "HTTP/1.1 20 OK" "")
                     (%crlf "HTTP/1.1 2000 OK" "")
                     (%crlf "ICY 200 OK" "")
                     (%crlf "HTTP/1.1 200 OK" "No colon here" "")
                     (%crlf "HTTP/1.1 200 OK" "Bad Name: x" "")
                     (%crlf "HTTP/1.1 200 OK" ": no name" "")
                     (%crlf "HTTP/1.1 200 OK" "X-A: 1" " folded" "")
                     (%crlf "HTTP/1.1 200 OK" (format nil "X-A: a~Cb" (code-char 0)) "")
                     (sb-ext:string-to-octets (format nil "HTTP/1.1 200 OK~CX-A: 1~C~C~C" #\Return #\Return #\Return #\Newline))
                     (sb-ext:string-to-octets "HTTP/1.1 200 OK")
                     (%crlf "HTTP/1.1 200 OK" "X-A: 1")))
    (is-true (%refused-p bad) "accepted: ~S" (%text (subseq bad 0 (min 60 (length bad)))))))

(test http1-refuses-a-head-past-its-limits
  (let ((long (make-string (1+ http::+max-line-octets+) :initial-element #\a)))
    (is-true (%refused-p (%crlf "HTTP/1.1 200 OK" (concatenate 'string "X-Long: " long) "")))
    (is-true (%refused-p (%crlf (concatenate 'string "HTTP/1.1 200 " long) ""))))
  (is-true (%refused-p (apply #'%crlf "HTTP/1.1 200 OK"
                              (append (loop for i from 0 to http::+max-header-fields+
                                            collect (format nil "X-~D: v" i))
                                      (list "")))))
  (is-true (%refused-p (apply #'%crlf
                              (append (loop repeat (1+ http::+max-interim-responses+)
                                            append (list "HTTP/1.1 100 Continue" ""))
                                      (list "HTTP/1.1 200 OK" "Content-Length: 0" "")))))
  (let ((field (concatenate 'string "X-Big: " (make-string 60000 :initial-element #\b))))
    (is-true (%refused-p (apply #'%crlf "HTTP/1.1 200 OK"
                                (append (loop repeat 5 collect field) (list ""))))
             "five fields under the line limit still pass the head's limit"))
  (is (= 200 (%parse (%crlf "HTTP/1.1 200 OK"
                            (concatenate 'string "Content-Security-Policy: " (make-string 20000 :initial-element #\c))
                            "Content-Length: 0" "")))
      "a header line longer than 8 KiB, as GitHub sends, is read"))

(test http1-refuses-a-chunked-body-outside-the-grammar
  (dolist (bad (list (%crlf "HTTP/1.1 200 OK" "Transfer-Encoding: chunked" "" "zz" "")
                     (%crlf "HTTP/1.1 200 OK" "Transfer-Encoding: chunked" "" "-1" "")
                     (%crlf "HTTP/1.1 200 OK" "Transfer-Encoding: chunked" "" "" "")
                     (%crlf "HTTP/1.1 200 OK" "Transfer-Encoding: chunked" "" "1000000000000000" "")
                     (%crlf "HTTP/1.1 200 OK" "Transfer-Encoding: chunked" "" "3 x" "abc" "0" "")
                     (%crlf "HTTP/1.1 200 OK" "Transfer-Encoding: chunked" "" "3" "abcd" "0" "")
                     (%crlf "HTTP/1.1 200 OK" "Transfer-Encoding: chunked" "" "5" "ab")
                     (%crlf "HTTP/1.1 200 OK" "Transfer-Encoding: chunked" ""
                            (concatenate 'string "1;" (make-string 2000 :initial-element #\e)) "a" "0" "")
                     (%crlf "HTTP/1.1 200 OK" "Content-Length: 10" "" "short")))
    (is-true (%refused-p bad) "accepted: ~S" (%text (subseq bad 0 (min 80 (length bad)))))))

(test http1-never-signals-anything-but-a-malformed-response-on-garbage
  "Seeded mutations of a valid response, and random octets: each read either returns or signals
MALFORMED-RESPONSE, never another error, and always ends."
  (let ((rs (sb-ext:seed-random-state 536))
        (valid (%crlf "HTTP/1.1 200 OK" "Transfer-Encoding: chunked" "X-A: 1" "" "3" "abc" "0" ""))
        (other '()))
    (dotimes (i 400)
      (let ((octets (if (evenp i)
                        (let ((v (copy-seq valid)))
                          (dotimes (k (1+ (random 4 rs)))
                            (setf (aref v (random (length v) rs)) (random 256 rs)))
                          v)
                        (let ((v (make-array (random 300 rs) :element-type '(unsigned-byte 8))))
                          (dotimes (k (length v) v) (setf (aref v k) (random 256 rs)))))))
        (handler-case (%parse octets)
          (http:malformed-response () nil)
          (error (e) (push (list i (type-of e)) other)))))
    (is (null other) "other errors: ~S" (subseq other 0 (min 5 (length other))))))

(test http1-writes-a-request-that-cannot-be-split
  (flet ((written (headers &optional content)
           (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
             (with-open-stream (s (make-instance '%octet-output :sink out))
               (http::write-request s :post (quri:uri "https://h.test:8443/p?q=1") headers content))
             (%text out))))
    (let ((text (written (list (cons "Host" "evil.test") (cons "Content-Length" "999")
                               (cons "Connection" "keep-alive") (cons "X-Ok" "1"))
                         (list (cons "a" "b c")))))
      (is (eql 0 (search (format nil "POST /p?q=1 HTTP/1.1~C~CHost: h.test:8443~C~C" #\Return #\Newline #\Return #\Newline) text))
          "the request line, then the URL's host: ~S" text)
      (is (not (search "evil.test" text)) "the caller's Host is not sent")
      (is (not (search "999" text)) "the caller's Content-Length is not sent")
      (is (search "Connection: close" text))
      (is (search "Content-Type: application/x-www-form-urlencoded" text))
      (is (search "Content-Length: 7" text) "a=b+c or a=b%20c is seven octets: ~S" text))
    (signals http:http-error (written (list (cons "X-Bad" (format nil "a~C~CX-Injected: 1" #\Return #\Newline)))))
    (signals http:http-error (written (list (cons "Bad Name" "x"))))))

(defclass %octet-output (sb-gray:fundamental-binary-output-stream)
  ((sink :initarg :sink :reader %sink)))

(defmethod stream-element-type ((s %octet-output)) '(unsigned-byte 8))
(defmethod sb-gray:stream-write-byte ((s %octet-output) b) (vector-push-extend b (%sink s)) b)

;;; --- Windows: the certificate decision is Windows' (#536) ---------------------------------

(test every-certificate-verdict-has-its-own-condition
  "Each reason a platform verifier gives is signalled as its own subclass of
CERTIFICATE-REJECTED, and an unknown one as CERTIFICATE-REJECTED itself, never a generic error."
  (loop for (verdict . class) in '((:expired . http:certificate-expired)
                                   (:untrusted-root . http:certificate-untrusted-root)
                                   (:name-mismatch . http:certificate-name-mismatch)
                                   (:revoked . http:certificate-revoked)
                                   (:revocation-unknown . http:certificate-revocation-unknown)
                                   (:distrusted . http:certificate-distrusted)
                                   (:chain-incomplete . http:certificate-chain-incomplete)
                                   (:wrong-usage . http:certificate-wrong-usage))
        do (is (eq class (http::certificate-condition-class verdict)) "~S" verdict)
           (is (subtypep class 'http:certificate-rejected))
           (is (subtypep class 'http:http-error) "so %HTTP passes it on as itself"))
  (is (eq 'http:certificate-rejected (http::certificate-condition-class :rejected))))

#+os-windows
(test windows-maps-its-policy-errors-to-verdicts
  (loop for (code . verdict) in '((0 . :trusted) (#x800B0101 . :expired) (#x800B0109 . :untrusted-root)
                                  (#x800B010F . :name-mismatch) (#x80092010 . :revoked)
                                  (#x80092013 . :revocation-unknown) (#x800B0111 . :distrusted)
                                  (#x800B010A . :chain-incomplete) (#x800B0110 . :wrong-usage)
                                  (#x80096004 . :rejected))
        do (is (eq verdict (aion/windows::policy-verdict code)) "#x~8,'0X" code)))

#+os-windows
(defun %fixture-octets (name)
  (with-open-file (in (%fixture name) :element-type '(unsigned-byte 8))
    (let* ((v (make-array (file-length in) :element-type '(unsigned-byte 8)))
           (n (read-sequence v in)))
      (subseq v 0 n))))

#+os-windows
(test windows-does-not-trust-a-self-signed-certificate
  "The real crypt32 call, with no network: the self-signed fixture is not under any root this
machine trusts. And the chain is judged for the name it is given."
  (let* ((chain (aion/tls:make-certificate-chain (%fixture-octets +tls-certificate+)))
         (der (aion/tls:certificate-chain-der chain)))
    (unwind-protect
         (multiple-value-bind (verdict code)
             (aion/windows:verify-server-certificate-chain (list der) "pinned.test")
           (is (eq :untrusted-root verdict) "~S #x~8,'0X" verdict code)
           (is (= #x800B0109 code)))
      (aion/tls:free-certificate-chain chain)))
  (signals aion/windows:win32-error
    (aion/windows:verify-server-certificate-chain
     (list (make-array 8 :element-type '(unsigned-byte 8) :initial-element 1)) "x.test")))

#+os-windows
(test a-pinned-connection-on-windows-asks-windows-and-honours-its-answer
  "Without CA-PATH, the pinned TLS connection gives the server's chain and the URL's host to the
verifier and obeys it. A verifier that accepts gets the response; one that answers :EXPIRED
makes the request signal CERTIFICATE-EXPIRED with Windows' code; and the real verifier refuses
the self-signed test certificate as CERTIFICATE-UNTRUSTED-ROOT."
  (with-server (s (lambda (path head stream)
                    (declare (ignore path head))
                    (%write-response stream 200 '() "verified by the caller"))
                  :tls t)
    (flet ((get-it () (http:send-request (http:make-request :url (%local s "/" "pinned.test" "https")
                                                            :connect-address "127.0.0.1"
                                                            :read-timeout 5)
                                         '())))
      (let* ((seen '())
             (http::*server-certificate-verifier*
               (lambda (chain host) (push (list (length chain) host) seen) :trusted)))
        (is (string= "verified by the caller" (http:response-body (get-it))))
        (is (equal '((1 "pinned.test")) seen) "the verifier saw ~S" seen))
      (let ((http::*server-certificate-verifier*
              (lambda (chain host) (declare (ignore chain host)) (values :expired #x800B0101))))
        (handler-case (progn (get-it) (fail "an :EXPIRED verdict was not refused"))
          (http:certificate-expired (e)
            (is (string= "pinned.test" (http:certificate-rejected-host e)))
            (is (= #x800B0101 (http:certificate-rejected-code e))))))
      (signals http:certificate-untrusted-root (get-it)))))

;;; --- the opt-in check against public servers (GitHub Actions only) ------------------------

(defun %runner-network-failure-p (condition)
  "Whether CONDITION is a failure of the runner's network rather than of this client: the host
did not resolve, a socket could not connect or timed out, or the fetch ran past its deadline. A
TLS error, a refused certificate or a malformed response is not one of these, and still fails the
test below (#931).

The client wraps a transport failure, such as a USOCKET:TIMEOUT-ERROR, in an HTTP:HTTP-ERROR
whose HTTP-ERROR-PHASE is :CONNECT or :RESPONSE, and that counts too (#976). It failed the
Windows leg of train 78 when only the unwrapped types were matched. An HTTP-ERROR with a status,
or one the client raised itself before sending, has no phase and does not count."
  (or (and (typep condition 'http:fetch-refused)
           (eq :unresolvable (http:fetch-refused-reason condition)))
      ;; A MALFORMED-RESPONSE carries :RESPONSE too, when the connection ended early or WinHTTP
      ;; refused the reply (12152), and it is this client's or the server's doing, not the
      ;; network's (the hub's review of #979).
      (and (typep condition 'http:http-error)
           (not (typep condition 'http:malformed-response))
           (member (http:http-error-phase condition) '(:connect :response))
           t)
      (typep condition '(or http:fetch-deadline-exceeded usocket:socket-condition
                         usocket:ns-condition sb-sys:io-timeout))))

(test public-https-through-the-pinned-path
  "Against servers on the internet: a public https page is fetched through FETCH-PUBLIC's pinned
connection, and on Windows an expired certificate is refused as CERTIFICATE-EXPIRED by Windows'
own policy. It needs the network, so it runs only on GitHub's runners (GITHUB_ACTIONS), never
by default on a developer's machine.

ANY HTTP STATUS PASSES. A response of any status means the TLS handshake, the verification of
the server's certificate and the reading of an HTTP response all happened through the pinned
connection, which is what this test is for. example.com once answered a runner with 503, and
requiring 200 failed a run whose change could not have caused it (#931).

A FAILURE OF THE RUNNER'S NETWORK IS A SKIP, with the condition as its reason: a host that does
not resolve, a connection that fails or times out, or the deadline passing
(%RUNNER-NETWORK-FAILURE-P). Those are not this client's doing. Every other condition fails the
test."
  (if (not (uiop:getenvp "GITHUB_ACTIONS"))
      (skip "Runs only on GitHub Actions (GITHUB_ACTIONS is not set here): it uses the network")
      (block network
        (handler-bind ((error (lambda (e)
                                (when (%runner-network-failure-p e)
                                  (skip "~A" (format nil "the runner's network failed: ~A" e))
                                  (return-from network)))))
          (let* ((r (http:fetch-public "https://example.com/" :read-timeout 30 :deadline 60))
                 (status (http:response-status r)))
            (is (and (integerp status) (<= 100 status 599)) "the status was ~S" status))
          #+os-windows
          (signals http:certificate-expired
            (http:fetch-public "https://expired.badssl.com/" :read-timeout 30 :deadline 60))))))

(test the-runner-network-failures-are-told-apart-from-this-clients
  "#931: what PUBLIC-HTTPS-THROUGH-THE-PINNED-PATH skips and what it fails on. A host that does
not resolve and a passed deadline are the runner's network; a refused certificate, a malformed
response and a refused private address are not."
  (is-true (%runner-network-failure-p
            (make-condition 'http:fetch-refused :url "https://x.test/" :reason :unresolvable)))
  (is-true (%runner-network-failure-p
            (make-condition 'http:fetch-deadline-exceeded :url "https://x.test/" :deadline 1)))
  (is-false (%runner-network-failure-p
             (make-condition 'http:fetch-refused :url "https://x.test/" :reason :private)))
  (is-false (%runner-network-failure-p
             (make-condition 'http:certificate-expired :host "x.test" :verdict :expired :code 0)))
  (is-false (%runner-network-failure-p (make-condition 'http:malformed-response :detail "x")))
  (is-false (%runner-network-failure-p
             (make-condition 'http:malformed-response :detail "the connection ended" :phase :response))
            "a malformed response is not the network's, though it carries :RESPONSE")
  (is-true (%runner-network-failure-p
            (make-condition 'http:http-error :detail "transport error" :phase :response))
           "control: another :RESPONSE transport failure is")
  #+os-windows
  (is (eq 'http::malformed-response
          (http::%transport-error-class (make-condition 'winhttp::win-error :code 12152)))
      "WinHTTP's 12152 is signalled as a MALFORMED-RESPONSE")
  #+os-windows
  (is (eq 'http:http-error
          (http::%transport-error-class (make-condition 'winhttp::win-error :code 12002)))
      "control: a WinHTTP timeout is not"))

(test a-wrapped-transport-failure-is-a-runner-network-failure
  "#976: the client wraps a socket timeout in an HTTP-ERROR, \"transport error\". A refused
connection on 127.0.0.1 comes back that way, wrapping USOCKET:TIMEOUT-ERROR on Linux, which is
the condition from the Windows leg of train 78."
  (let* ((port (let ((s (usocket:socket-listen "127.0.0.1" 0)))
                 (prog1 (usocket:get-local-port s) (usocket:socket-close s))))
         (wrapped (handler-case (progn (http:send-request
                                        (http:make-request :url (format nil "http://127.0.0.1:~D/" port)
                                                           :connect-timeout 2 :read-timeout 2)
                                        '())
                                       nil)
                    (http:http-error (e) e))))
    (is (typep wrapped 'http:http-error) "control: the failure arrived wrapped: ~S" wrapped)
    (is-true (%runner-network-failure-p wrapped)))
  (is-true (%runner-network-failure-p (make-condition 'http:http-error :phase :response
                                                                       :detail "transport error: read timed out"))
           "a failure after the request was sent, such as a read timeout, counts too")
  (is-false (%runner-network-failure-p (make-condition 'http:http-error :status 503 :body "busy"))
            "an HTTP status is the server's answer, not the runner's network")
  (is-false (%runner-network-failure-p (make-condition 'http:http-error :detail "not a header name: \"a b\""))
            "nor is a failure the client raised before sending"))

;;; --- the hub's review of #913 ---------------------------------------------------------------

(test a-redirect-to-a-path-with-a-space-arrives-percent-encoded
  "F1: a server redirects to \"/a b\". The next request's line must be \"GET /a%20b HTTP/1.1\": a
raw space would split the request line for any proxy in between. On every platform, because
FETCH-PUBLIC encodes each hop's URL before the request is made."
  (with-server (s (lambda (path head stream)
                    (declare (ignore head))
                    (if (string= path "/start")
                        (%write-response stream 302 '(("Location" . "/a b")) "")
                        (%write-response stream 200 '() "arrived"))))
    (let ((r (http:fetch-public (%local s "/start" "start.test")
                                :resolve (%resolver '(("start.test" "127.0.0.1")))
                                :address-policy #'%loopback-allowed :read-timeout 5)))
      (is (= 200 (http:response-status r)))
      (let ((line (let ((h (first (server-heads s)))) (subseq h 0 (position #\Return h)))))
        (is (string= "GET /a%20b HTTP/1.1" line) "the request line was ~S" line)))))

(test the-request-target-is-percent-encoded-outside-printable-ascii
  "F1: a space, a TAB, a control character, a Latin-1 character and one above U+00FF are each
sent as their UTF-8 octets, percent-encoded; an existing escape and printable ASCII are kept."
  (is (string= "/a%20b%09c%01d%C3%A9e%E2%98%BAf%2Fg?q=1&r=%22"
               (http::%encode-target (format nil "/a b~Cc~Cd~Ce~Cf%2Fg?q=1&r=%22"
                                             #\Tab (code-char 1) (code-char #xE9) (code-char #x263A)))))
  (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (with-open-stream (s (make-instance '%octet-output :sink out))
      (http::write-request s :get (quri:uri (format nil "https://h.test/x y~C" (code-char #x263A)))
                           nil nil))
    (is (eql 0 (search "GET /x%20y%E2%98%BA HTTP/1.1" (%text out))) "~S" (%text out)))
  (signals http:http-error
    (http::%host-safe (format nil "h~C.test" (code-char #xE9)))))

(test a-field-name-must-be-ascii-and-a-value-holds-no-control-characters
  "F4 and F5: an accented letter is not a tchar; a value may hold HTAB and obs-text, but no other
control character and no DEL."
  (is-true (%refused-p (%crlf "HTTP/1.1 200 OK" (format nil "X-~C: 1" (code-char #xE9)) "")))
  (dolist (c (list (code-char 1) (code-char 27) (code-char 127)))
    (is-true (%refused-p (%crlf "HTTP/1.1 200 OK" (format nil "X-A: a~Cb" c) "Content-Length: 0" ""))
             "accepted char ~D" (char-code c)))
  (multiple-value-bind (status fields)
      (%parse (%crlf "HTTP/1.1 200 OK" (format nil "X-A: a~Cb~Cc" #\Tab (code-char #xE9))
                     "Content-Length: 0" ""))
    (is (= 200 status))
    (is (string= (format nil "a~Cb~Cc" #\Tab (code-char #xE9)) (gethash "x-a" fields)))))

#+os-windows
(test a-pinned-connection-to-an-ipv6-literal-asks-about-the-bare-address
  "F3: QURI keeps the brackets of https://[::1]/; the verifier is asked about ::1, the name a
certificate's IP address entry holds. The same address written out in full, [0:0:0:0:0:0:0:1], is
also asked about as ::1, the form %TLS-NAMES gives and the one Linux and macOS verify (#921)."
  (with-server (s (lambda (path head stream)
                    (declare (ignore path head))
                    (%write-response stream 200 '() "v6"))
                  :tls t)
    (dolist (host '("[::1]" "[0:0:0:0:0:0:0:1]"))
      (let* ((seen '())
             (http::*server-certificate-verifier*
               (lambda (chain host) (declare (ignore chain)) (push host seen) :trusted)))
        (http:send-request (http:make-request :url (format nil "https://~A:~D/" host (server-port s))
                                              :connect-address "127.0.0.1" :read-timeout 5)
                           '())
        (is (equal '("::1") seen) "for ~A the verifier was asked about ~S" host seen)))))

;;; --- what aion/retry reads from an HTTP-ERROR (#79) ------------------------------

(defun %refusal (status &optional retry-after)
  "The HTTP-ERROR ENSURE-2XX signals for a response with STATUS and, when given, a Retry-After
header RETRY-AFTER."
  (let ((headers (make-hash-table :test #'equal)))
    (when retry-after (setf (gethash "retry-after" headers) retry-after))
    (handler-case (progn (http:send-request (http:make-request :url "u") (list (http:ensure-2xx))
                                            :perform (%ok :status status :headers headers))
                         nil)
      (http:http-error (e) e))))

(test ensure-2xx-reads-retry-after
  (is (eql 30 (http:http-error-retry-after (%refusal 429 "30"))))
  (is (eql 30 (aion/retry:retry-after (%refusal 429 "30"))) "and AION/RETRY:RETRY-AFTER reads it")
  (is (null (http:http-error-retry-after (%refusal 429))) "no header is NIL")
  (is (null (http:http-error-retry-after (%refusal 503 "later"))) "nor is one it cannot read"))

(test transience-of-an-http-error-follows-its-status
  (dolist (status '(408 425 429 503 529))
    (is (eq :transient (aion/retry:transience (%refusal status))) "~D" status))
  (dolist (status '(500 502 504))
    (is (eq :unknown (aion/retry:transience (%refusal status))) "~D" status))
  (dolist (status '(400 401 403 404 409 422))
    (is (null (aion/retry:transience (%refusal status))) "~D" status)))

(test transience-of-a-transport-failure-follows-how-far-it-got
  (is (eq :transient (aion/retry:transience (make-condition 'http:http-error :phase :connect))))
  (is (eq :unknown (aion/retry:transience (make-condition 'http:http-error :phase :response))))
  (is (null (aion/retry:transience (make-condition 'http:http-error :detail "a refused header")))
      "a failure this client raised before sending is not transient"))

(test a-refused-connection-is-a-connect-phase-failure
  ;; A port nothing listens on: bound, then closed, so nothing can answer. The connect timeout
  ;; is well above the time the refusal takes to arrive. Windows retries a refused connect to
  ;; 127.0.0.1 for about two seconds before it reports the refusal, so with a two-second
  ;; timeout WinHTTP reported 12002 (a timeout) on the CI Windows leg, not 12029 (#974, run
  ;; 40653707988), and the test measured a timeout instead of a refusal.
  (let ((port (let ((s (usocket:socket-listen "127.0.0.1" 0)))
                (prog1 (usocket:get-local-port s) (usocket:socket-close s)))))
    ;; A POST, which never uses dexador's connection pool (the hub's review of #974), so a
    ;; refusal shows the request was not sent. A GET's refusal may have followed a send on a
    ;; pooled connection, and is :RESPONSE on the dexador path.
    (let ((e (handler-case (progn (http:send-request
                                   (http:make-request :method :post
                                                      :url (format nil "http://127.0.0.1:~D/" port)
                                                      :content "x"
                                                      :connect-timeout 15 :read-timeout 15)
                                   (list (http:ensure-2xx)))
                                  nil)
               (http:http-error (e) e))))
      ;; Each message names the failure, so a platform whose transport signals a type the
      ;; classifier does not know shows which one (#974: WinHTTP's 12029 on Windows).
      (is (typep e 'http:http-error) "got ~S" e)
      (is (eq :connect (and e (http:http-error-phase e))) "phase ~S for: ~A"
          (and e (http:http-error-phase e)) e)
      (is (aion/retry:transient-p e) "so the default policy retries it: ~A" e))))

;;; --- where a pinned connection failed, from the call that failed (review of #974) -------

(defun %pinned-failure (port &key (scheme "http") (read-timeout 2))
  "The HTTP-ERROR a pinned request to 127.0.0.1:PORT signals."
  (handler-case (progn (http:send-request
                        (http:make-request :url (format nil "~A://pinned.test:~D/" scheme port)
                                           :connect-address "127.0.0.1"
                                           :connect-timeout 2 :read-timeout read-timeout)
                        '())
                       nil)
    (http:http-error (e) e)))

(defmacro with-silent-listener ((port-var &key reply) &body body)
  "Run BODY with PORT-VAR bound to a port on 127.0.0.1 whose server accepts one connection,
writes REPLY (a string) when given, and then sends nothing more until BODY ends."
  (let ((listener (gensym)) (thread (gensym)))
    `(let* ((,listener (usocket:socket-listen "127.0.0.1" 0 :reuse-address t))
            (,port-var (usocket:get-local-port ,listener))
            (,thread (bt:make-thread
                      (lambda ()
                        (ignore-errors
                         (let ((c (usocket:socket-accept ,listener :element-type '(unsigned-byte 8))))
                           (when ,reply
                             (write-sequence (sb-ext:string-to-octets ,reply)
                                             (usocket:socket-stream c))
                             (finish-output (usocket:socket-stream c)))
                           (sleep 5)
                           (usocket:socket-close c)))))))
       (unwind-protect (progn ,@body)
         (ignore-errors (bt:destroy-thread ,thread))
         (usocket:socket-close ,listener)))))

(test a-pinned-connection-that-was-refused-is-a-connect-failure
  (let* ((port (let ((s (usocket:socket-listen "127.0.0.1" 0)))
                 (prog1 (usocket:get-local-port s) (usocket:socket-close s))))
         (e (%pinned-failure port)))
    (is (typep e 'http:http-error))
    (is (eq :connect (and e (http:http-error-phase e))))))

(test a-pinned-failure-after-connecting-is-a-response-failure-whatever-its-type
  ;; The connection is made and the request sent; the server never answers, and the read times
  ;; out. It happened after the connection was made, so it is :RESPONSE, and a POST is not
  ;; resent. Before #985 the condition that arrived here was dexador's attempt to reconnect by
  ;; resolving pinned.test, a USOCKET:NS-HOST-NOT-FOUND-ERROR, which by its type is :CONNECT.
  (with-silent-listener (port)
    (let ((e (%pinned-failure port :read-timeout 1)))
      (is (typep e 'http:http-error) "got ~S" e)
      (is (eq :response (and e (http:http-error-phase e))) "got ~S: ~A" (and e (http:http-error-phase e)) e)
      (is (not (aion/retry:transient-p e)) "the default policy does not resend it"))))

#-os-windows
(test a-tls-failure-on-a-pinned-connection-has-no-phase
  ;; A server that answers the TLS handshake with plain text. Retrying cannot fix that, so it
  ;; must not be classed as a transport failure either way.
  (with-silent-listener (port :reply (format nil "HTTP/1.1 400 Bad Request~C~C~C~C" #\Return #\Linefeed #\Return #\Linefeed))
    (let ((e (%pinned-failure port :scheme "https")))
      (is (typep e 'http:http-error) "got ~S" e)
      (is (null (and e (http:http-error-phase e))) "got ~S: ~A" (and e (http:http-error-phase e)) e)
      (is (not (aion/retry:transient-or-unknown-p e))))))

;;; --- a pinned request uses one connection (#985) -----------------------------------------

(defmacro with-counting-listener ((port-var count-var) &body body)
  "Run BODY with PORT-VAR bound to a port on 127.0.0.1 whose server accepts every connection and
never answers, and COUNT-VAR to a function returning how many connections it accepted."
  (let ((listener (gensym)) (thread (gensym)) (accepted (gensym)) (held (gensym)))
    `(let* ((,listener (usocket:socket-listen "127.0.0.1" 0 :reuse-address t :backlog 8))
            (,port-var (usocket:get-local-port ,listener))
            (,accepted 0)
            (,held '())
            (,thread (bt:make-thread
                      (lambda ()
                        (ignore-errors
                         (loop (let ((c (usocket:socket-accept ,listener)))
                                 (incf ,accepted)
                                 (push c ,held)))))))
            (,count-var (lambda () ,accepted)))
       (unwind-protect (progn ,@body)
         (ignore-errors (bt:destroy-thread ,thread))
         (dolist (c ,held) (ignore-errors (usocket:socket-close c)))
         (usocket:socket-close ,listener)))))

(test a-pinned-request-that-times-out-uses-one-connection
  "#985: the URL names localhost, which resolves, and the request is pinned to 127.0.0.1. The
server accepts and never answers. Before #985, dexador reconnected through DNS after the read
timed out and sent the request again, and this server counted two connections."
  (with-counting-listener (port accepted)
    (let ((e (handler-case
                 (progn (http:send-request
                         (http:make-request :url (format nil "http://localhost:~D/" port)
                                            :connect-address "127.0.0.1"
                                            :connect-timeout 2 :read-timeout 1)
                         '())
                        nil)
               (http:http-error (e) e))))
      (sleep 0.5)                       ; a second connection, if one were made, has arrived
      (is (= 1 (funcall accepted)) "the server accepted ~D connections" (funcall accepted))
      (is (typep e 'http:http-error))
      (is (eq :response (and e (http:http-error-phase e))))
      (is (search "timeout" (string-downcase (or (and e (http:http-error-detail e)) "")))
          "the caller gets the read timeout: ~A" (and e (http:http-error-detail e))))))

(test fetch-public-stops-at-its-deadline-when-the-server-never-answers
  "#985: a real socket, not a stub. The server accepts and never answers, and there is no read
timeout, so only the deadline can end the fetch. On Windows the deadline used to shut the socket
down, which did not wake the read: the fetch was still waiting after 20 seconds. An outer limit
of 30 seconds makes that a failure here rather than a hang."
  (with-counting-listener (port accepted)
    (let* ((start (get-internal-real-time))
           (result (handler-case
                       (sb-ext:with-timeout 30
                         (handler-case
                             (progn (http:fetch-public (format nil "http://silent.test:~D/" port)
                                                       :resolve (%resolver '(("silent.test" "127.0.0.1")))
                                                       :address-policy #'%loopback-allowed
                                                       :deadline 2)
                                    :returned)
                           (http:fetch-deadline-exceeded () :deadline)))
                     (sb-ext:timeout () :still-waiting)))
           (seconds (/ (- (get-internal-real-time) start) internal-time-units-per-second)))
      (is (eq :deadline result) "got ~S after ~,1F s" result seconds)
      (is (< seconds 10) "and within a few seconds of the deadline: ~,1F s" seconds)
      (is (= 1 (funcall accepted)) "on one connection: ~D" (funcall accepted)))))

(test a-pinned-request-sends-dexadors-user-agent-and-accept-unless-given
  (with-server (s (lambda (path head stream)
                    (declare (ignore path head))
                    (%write-response stream 200 '() "ok")))
    (http:send-request (http:make-request :url (%local s "/" "pinned.test")
                                          :connect-address "127.0.0.1" :read-timeout 5)
                       '())
    (http:send-request (http:make-request :url (%local s "/" "pinned.test")
                                          :connect-address "127.0.0.1" :read-timeout 5
                                          :headers '(("User-Agent" . "probe/1")
                                                     ("Accept" . "text/html")))
                       '())
    (destructuring-bind (second first) (server-heads s)
      (is (string= dexador.util:*default-user-agent* (%head-header first "User-Agent"))
          "as a request through dexador sent")
      (is (string= "*/*" (%head-header first "Accept")))
      (is (string= "probe/1" (%head-header second "User-Agent")) "a caller's own wins")
      (is (string= "text/html" (%head-header second "Accept"))))))

(test a-pinned-request-frames-its-body-as-dexador-did
  "#985: string content without a Content-Type is text/plain, and a POST with no content says
Content-Length: 0, as dexador wrote them; a GET with no content says neither."
  (with-server (s (lambda (path head stream)
                    (declare (ignore path head))
                    (%write-response stream 200 '() "ok")))
    (flet ((send (&rest args)
             (http:send-request (apply #'http:make-request :url (%local s "/" "pinned.test")
                                       :connect-address "127.0.0.1" :read-timeout 5 args)
                                '())
             (first (server-heads s))))
      (let ((head (send :method :post :content "hello")))
        (is (string= "text/plain" (%head-header head "Content-Type")))
        (is (string= "5" (%head-header head "Content-Length"))))
      (let ((head (send :method :post :content "{}" :headers '(("Content-Type" . "application/json")))))
        (is (string= "application/json" (%head-header head "Content-Type")) "a caller's own wins"))
      (let ((head (send :method :post)))
        (is (string= "0" (%head-header head "Content-Length")))
        (is (null (%head-header head "Content-Type"))))
      (let ((head (send :method :get)))
        (is (null (%head-header head "Content-Length")))))))

;;; --- a pooled request's failure to connect is not known to be before the send (#974 review) --

(test a-request-that-may-have-used-a-pooled-connection-does-not-fail-in-the-connect-phase
  "dexador pools connections, and a request it sent on a pooled connection that then dropped is
sent again by dexador on a new one. A refusal of that new connection does not show the request
was not acted on. So on the dexador path a failure to connect is :CONNECT only for a request
that could not have used the pool, and a request that is not idempotent never uses it."
  (let ((refused (make-condition 'usocket:connection-refused-error :socket nil)))
    (is (eq :response (http::%transport-phase refused nil :pooled t))
        "a pooled request's refused reconnect is :RESPONSE")
    (is (eq :connect (http::%transport-phase refused nil :pooled nil))
        "control: a request on a new connection is :CONNECT"))
  (flet ((args (method) (http::%dex-args (http:make-request :method method :url "http://x.test/"))))
    (is (and (member :use-connection-pool (args :post))
             (null (getf (args :post) :use-connection-pool))
             (null (getf (args :post) :keep-alive)))
        "a POST gets a new connection: ~S" (args :post))
    (is (null (member :use-connection-pool (args :get)))
        "control: a GET may use the pool: ~S" (args :get))))
