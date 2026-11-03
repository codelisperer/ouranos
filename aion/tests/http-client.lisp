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

;;; --- aion/test-http :concurrent (#999) ---------------------------------------------------

(defun %answered-past-an-idle-connection-p (concurrent)
  "Whether a server started with CONCURRENT answers a request while another connection to it is
open and has sent nothing: true when the answer's first byte arrives within two seconds."
  (aion/test-http:with-server (s (lambda (request stream)
                                   (declare (ignore request))
                                   (aion/test-http:write-response stream 200 '() "answered"))
                                 :concurrent concurrent)
    (let ((idle (usocket:socket-connect "127.0.0.1" (aion/test-http:server-port s)
                                        :element-type '(unsigned-byte 8)))
          (asking nil))
      (unwind-protect
           (progn
             (sleep 0.3)                ; the server takes the idle connection first
             (setf asking (usocket:socket-connect "127.0.0.1" (aion/test-http:server-port s)
                                                  :element-type '(unsigned-byte 8)))
             (let ((out (usocket:socket-stream asking)))
               (write-sequence (sb-ext:string-to-octets
                                (format nil "GET / HTTP/1.1~C~CHost: x~C~C~C~C"
                                        #\Return #\Newline #\Return #\Newline #\Return #\Newline)
                                :external-format :latin-1)
                               out)
               (finish-output out))
             (and (usocket:wait-for-input asking :timeout 2 :ready-only t) t))
        ;; Closing the idle connection lets a server that serves one at a time go on, so its
        ;; thread can be stopped.
        (ignore-errors (usocket:socket-close idle))
        (when asking (ignore-errors (usocket:socket-close asking)))))))

(test a-concurrent-test-server-answers-while-another-connection-is-idle
  "#999, from the hub's review: aion/test-http's :CONCURRENT serves each connection on its own
thread, so a connection that sends nothing does not hold up the next request. The control is the
default server, which serves one connection at a time and does not answer meanwhile. A browser
opens such connections, and the window test that needs this runs only on CI."
  (is-true (%answered-past-an-idle-connection-p t) "with :concurrent, the request is answered")
  (is-false (%answered-past-an-idle-connection-p nil)
            "control: one connection at a time, the request waits behind the idle one"))

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
      (is (string= "the end" (http:response-body all))))
    ;; #1063: a pinned request follows none, whatever FOLLOW-REDIRECTS says, as MAKE-REQUEST's
    ;; docstring says; its 3xx is the response.
    (let ((pinned (http:send-request (http:make-request :url (%local s "/") :connect-address "127.0.0.1"
                                                        :read-timeout 5)
                                     '())))
      (is (= 302 (http:response-status pinned)) "a pinned request with the default of 5"))))

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

(test a-read-that-returns-after-the-timer-fired-is-not-a-timeout
  "#1063: on Windows a pinned request's read timeout is a timer that closes the socket
(%IDLE-WATCHED-STREAM). A read that returned its data was reported as SB-SYS:IO-TIMEOUT when the
timer fired before the read's own clean-up unscheduled it. The window is forced here with a read
that keeps going past the timeout and then returns without touching the socket: it must return
its value. The control is a read that fails once the timer has closed the socket, as a real
blocked read does, which must still signal the timeout."
  #-os-windows (skip "the watched stream is Windows-only; elsewhere the socket's receive timeout ends a read")
  #+os-windows
  (flet ((watched ()
           ;; An inner stream with nothing to LISTEN to, so the read is watched; no socket, so
           ;; the timer's close does nothing here.
           (make-instance 'aion/http-client::%idle-watched-stream
                          :inner (make-string-input-stream "") :socket nil :seconds 0.2)))
    (let ((s (watched)))
      (is (eql 42 (aion/http-client::%call-watched s (lambda () (sleep 0.6) 42)))
          "a read that returned after the timer fired returns its value")
      (is-true (aion/http-client::%timed-out s) "the timer did fire, so the window was reached"))
    ;; Control: a read the timer's close ended is still a timeout.
    (let ((s (watched)))
      (signals sb-sys:io-timeout
        (aion/http-client::%call-watched
         s (lambda ()
             (loop until (aion/http-client::%timed-out s) do (sleep 0.02))
             (error "the socket was closed")))))
    (let ((s (watched)))
      (is (eql 7 (aion/http-client::%call-watched s (lambda () 7))))
      (sleep 0.4)
      (is (null (aion/http-client::%timed-out s))
          "a read that finished first leaves the timer nothing to do"))))

(test a-timer-that-fires-after-the-read-finished-does-nothing
  "#1063, from the review of #1070: the other half of the window. The timer can fire after the
read has recorded that it finished and before the read unschedules it. Its callback,
%WATCH-FIRE, is called here with the read's state already :DONE, which is that moment: it must
neither mark the stream timed out nor close the socket. The control calls it with the state
still :READING, when it must do both. The socket is a real listening socket, which signals once
it is closed."
  #-os-windows (skip "the watched stream is Windows-only; elsewhere the socket's receive timeout ends a read")
  #+os-windows
  (flet ((watched (socket)
           (make-instance 'aion/http-client::%idle-watched-stream
                          :inner (make-string-input-stream "") :socket socket :seconds 60))
         (open-p (socket)
           (handler-case (progn (usocket:get-local-port socket) t)
             (error () nil))))
    (let* ((socket (usocket:socket-listen "127.0.0.1" 0))
           (s (watched socket))
           (state (list :done)))
      (unwind-protect
           (progn
             (aion/http-client::%watch-fire s state)
             (is (eq :done (car state)))
             (is (null (aion/http-client::%timed-out s)) "a finished read is not marked timed out")
             (is-true (open-p socket) "and its socket is not closed"))
        (ignore-errors (usocket:socket-close socket))))
    (let* ((socket (usocket:socket-listen "127.0.0.1" 0))
           (s (watched socket))
           (state (list :reading)))
      (unwind-protect
           (progn
             (aion/http-client::%watch-fire s state)
             (is (eq :fired (car state)))
             (is-true (aion/http-client::%timed-out s) "control: a read still waiting is timed out")
             (is (null (open-p socket)) "control: and its socket is closed"))
        (ignore-errors (usocket:socket-close socket))))))

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
;;; --- a response read as it arrives, and cancelling it (#984) --------------------------------

(defun %octets-of (string) (sb-ext:string-to-octets string :external-format :utf-8))

(defun %events-of (text)
  "Every event READ-EVENT finds in TEXT, as lists (DATA EVENT ID)."
  (let ((in (make-instance 'http::%octets-input :octets (%octets-of text))))
    (loop for (data event id) = (multiple-value-list (http:read-event in))
          while data collect (list data event id))))

(test read-event-reads-data-event-and-id-and-skips-comments
  "Data lines are joined with newlines; a comment, an event with no data and a CR before the LF are
dropped; the event and id fields belong to their own event only."
  (is (equal '(("one" "start" "7") ("two" nil nil) ("a
b" nil nil) ("é" nil nil))
             (%events-of (concatenate
                          'string
                          (format nil ": hello~%event: start~%id: 7~%data: one~%~%data:two~%~%")
                          (format nil "event: empty~%~%data: a~C~%data: b~C~%~C~%data: é~%~%"
                                  #\Return #\Return #\Return))))))

(test read-event-discards-an-event-the-stream-ends-in
  "An event with no blank line after it when the stream ends is not returned, whether the stream
ends after a whole data line or in the middle of one: the connection dropped before the event was
finished. The events before it are returned."
  (is (equal '(("whole" nil nil)) (%events-of (format nil "data: whole~%~%data: cut~%"))))
  (is (equal '(("whole" nil nil)) (%events-of (format nil "data: whole~%~%data: {\"a\":"))))
  (is (null (%events-of (format nil "event: x~%data: only~%")))))

(test read-event-refuses-an-event-over-its-limit
  "An event longer than *MAX-EVENT-OCTETS* signals HTTP-ERROR rather than being read whole."
  (let ((http:*max-event-octets* 16))
    (signals http:http-error (%events-of (format nil "data: ~A~%~%" (make-string 40 :initial-element #\x))))
    (is (equal '(("short" nil nil)) (%events-of (format nil "data: short~%~%"))))))

(defun %sse-server-handler (first-sent next-allowed)
  "A handler that sends one event, sets FIRST-SENT's car, waits until NEXT-ALLOWED's car is true
(at most 10 seconds), then sends a second event and ends the stream."
  (lambda (path head stream)
    (declare (ignore path head))
    (ignore-errors
     (aion/test-http:write-head stream 200 '(("Content-Type" . "text/event-stream")
                                             ("Connection" . "close")))
     (write-sequence (%octets-of (format nil "data: first~%~%")) stream)
     (finish-output stream)
     (setf (car first-sent) t)
     (loop repeat 100 until (car next-allowed) do (sleep 0.1))
     (write-sequence (%octets-of (format nil "data: second~%~%")) stream)
     (finish-output stream))))

(test a-streamed-response-gives-each-event-before-the-next-is-sent
  "OPEN-RESPONSE-STREAM returns once the head has arrived, and READ-EVENT returns the first event
while the server is still holding back the second."
  (let ((first-sent (list nil)) (next-allowed (list nil)))
    (with-server (s (%sse-server-handler first-sent next-allowed))
      (multiple-value-bind (body status headers)
          (http:open-response-stream (http:make-request :url (%local s "/events") :read-timeout 15))
        (unwind-protect
             (progn
               (is (= 200 status))
               (is (equal "text/event-stream" (http:header-value headers "content-type")))
               (is (equal "first" (http:read-event body)))
               (is (null (car next-allowed)) "the second event had not been allowed yet")
               (setf (car next-allowed) t)
               (is (equal "second" (http:read-event body)))
               (is (null (http:read-event body)) "then the stream ends"))
          (setf (car next-allowed) t)
          (close body)))
      (is (search "Accept-Encoding: identity" (first (server-heads s)))
          "the request asks for an uncompressed body"))))

(test a-streamed-error-response-is-returned-with-its-body
  "A non-2xx is returned with its status, and its body can be read."
  (with-server (s (lambda (path head stream)
                    (declare (ignore path head))
                    (%write-response stream 429 '() "{\"error\":\"slow down\"}")))
    (multiple-value-bind (body status)
        (http:open-response-stream (http:make-request :url (%local s "/") :read-timeout 5))
      (unwind-protect
           (progn
             (is (= 429 status))
             (is (equal "{\"error\":\"slow down\"}"
                        (sb-ext:octets-to-string
                         (coerce (loop for b = (read-byte body nil nil) while b collect b)
                                 '(vector (unsigned-byte 8)))
                         :external-format :utf-8))))
        (close body)))))

(defun %silent-handler (closed-at)
  "A handler that sends one event and then sends nothing, the way a provider's connection is quiet
while the model thinks, for at most 10 seconds. A thread of its own reads the connection, and
when the read returns, because the client closed the connection or shut it down, stores the time
in CLOSED-AT's car. The handler returns once that happens or the 10 seconds pass."
  (lambda (path head stream)
    (declare (ignore path head))
    (ignore-errors
     (aion/test-http:write-head stream 200 '(("Content-Type" . "text/event-stream")
                                             ("Connection" . "close")))
     (write-sequence (%octets-of (format nil "data: first~%~%")) stream)
     (finish-output stream)
     (let* ((ending (list nil))
            ;; THREAD-LIFETIME: blocks reading the connection until the client closes it, or
            ;; until this handler returns and the server closes it. The JOIN below waits for it.
            (watcher (bt:make-thread
                      (lambda ()
                        (ignore-errors (read-byte stream nil nil))
                        (unless (car ending) (setf (car closed-at) (get-internal-real-time))))
                      :name "test server close watcher")))
       (loop repeat 100 until (car closed-at) do (sleep 0.1))
       (setf (car ending) t)
       (unless (car closed-at)
         ;; The client has not closed it: close it from here, so the watcher's read returns.
         (ignore-errors (close stream :abort t)))
       (aion/test-threads:join watcher :timeout 15)))))

(test cancelling-a-streamed-request-closes-its-connection
  "A thread blocked reading a stream that the server keeps open is woken by CANCEL-REQUEST from
another thread, with REQUEST-CANCELLED, and the server sees the connection close within two
seconds of the cancel. The server sends nothing after the first event, so the reader is blocked
in a read when the cancel comes: a cancel that only marked the request would leave it there, and
the connection open, until the server gave up after 10 seconds."
  (let ((closed-at (list nil))
        (cancel (http:make-request-cancel)))
    (with-server (s (%silent-handler closed-at))
      (let* ((outcome (list nil))
             (first (list nil))
             ;; THREAD-LIFETIME: reads the stream until the cancel below wakes it with
             ;; REQUEST-CANCELLED, or until the server ends the stream after 10 seconds; it then
             ;; closes the body and returns. The JOIN waits for it.
             (reader (bt:make-thread
                      (lambda ()
                        (multiple-value-bind (body)
                            (http:open-response-stream
                             (http:make-request :url (%local s "/") :read-timeout 30)
                             :cancel cancel)
                          (unwind-protect
                               (handler-case
                                   (progn (setf (car first) (http:read-event body))
                                          (http:read-event body)
                                          (setf (car outcome) :ended))
                                 (http:request-cancelled () (setf (car outcome) :cancelled)))
                            (close body))))
                      :name "streamed request reader")))
        (loop repeat 50 until (car first) do (sleep 0.1))
        (is (equal "first" (car first)) "the first event arrived before the cancel")
        (sleep 0.3)
        (is (null (car closed-at)) "the connection was open before the cancel")
        (let ((cancelled-at (get-internal-real-time)))
          (http:cancel-request cancel)
          (is (http:request-cancelled-p cancel))
          (aion/test-threads:join reader :timeout 15)
          (is (eq :cancelled (car outcome)) "the reader was woken with REQUEST-CANCELLED")
          (loop repeat 30 until (car closed-at) do (sleep 0.1))
          (is-true (car closed-at) "the server saw the connection close")
          (when (car closed-at)
            (is (< (/ (- (car closed-at) cancelled-at) internal-time-units-per-second) 2)
                "within two seconds of the cancel")))))))

(defun %cancellable-reader (server cancel first outcome)
  "A thread that opens a stream to SERVER with CANCEL, stores its first event in FIRST's car, then
reads on and stores :CANCELLED or :ENDED in OUTCOME's car."
  ;; THREAD-LIFETIME: reads the stream until a cancel wakes it with REQUEST-CANCELLED, or until
  ;; the server ends the stream after 10 seconds; it then closes the body and returns. The caller
  ;; joins it.
  (bt:make-thread
   (lambda ()
     (multiple-value-bind (body)
         (http:open-response-stream (http:make-request :url (%local server "/") :read-timeout 30)
                                    :cancel cancel)
       (unwind-protect
            (handler-case
                (progn (setf (car first) (http:read-event body))
                       (http:read-event body)
                       (setf (car outcome) :ended))
              (http:request-cancelled () (setf (car outcome) :cancelled)))
         (close body))))
   :name "streamed request reader"))

(test one-cancel-stops-every-request-opened-with-it
  "Two threads each have a stream open with the same REQUEST-CANCEL, the way two calls made under
one turn's cancel would. One CANCEL-REQUEST wakes both with REQUEST-CANCELLED, and both servers
see their connection close. When both bodies are closed the handle holds no request."
  (let ((closed-a (list nil)) (closed-b (list nil))
        (cancel (http:make-request-cancel)))
    (with-server (sa (%silent-handler closed-a))
      (with-server (sb (%silent-handler closed-b))
        (let* ((first-a (list nil)) (first-b (list nil))
               (outcome-a (list nil)) (outcome-b (list nil))
               (reader-a (%cancellable-reader sa cancel first-a outcome-a))
               (reader-b (%cancellable-reader sb cancel first-b outcome-b)))
          (loop repeat 50 until (and (car first-a) (car first-b)) do (sleep 0.1))
          (is (equal '("first" "first") (list (car first-a) (car first-b)))
              "both first events arrived before the cancel")
          (http:cancel-request cancel)
          (aion/test-threads:join reader-a :timeout 15)
          (aion/test-threads:join reader-b :timeout 15)
          (is (equal '(:cancelled :cancelled) (list (car outcome-a) (car outcome-b)))
              "both readers were woken with REQUEST-CANCELLED")
          (loop repeat 30 until (and (car closed-a) (car closed-b)) do (sleep 0.1))
          (is-true (car closed-a) "the first server saw its connection close")
          (is-true (car closed-b) "the second server saw its connection close")
          (is (null (http::request-cancel-watches cancel))
              "the closed bodies took their requests back from the handle"))))))

(test a-request-cancelled-before-it-is-opened-never-connects
  "OPEN-RESPONSE-STREAM with a handle that was already cancelled signals REQUEST-CANCELLED and
sends nothing."
  (with-server (s (lambda (path head stream)
                    (declare (ignore path head))
                    (%write-response stream 200 '() "x")))
    (let ((cancel (http:make-request-cancel)))
      (http:cancel-request cancel)
      (signals http:request-cancelled
        (http:open-response-stream (http:make-request :url (%local s "/") :read-timeout 5)
                                   :cancel cancel))
      (sleep 0.2)
      (is (zerop (%requests s)) "no request reached the server"))))

(test closing-a-streamed-body-closes-its-connection
  "Closing the body before the response has ended closes the connection, so the server stops."
  (let ((closed-at (list nil)))
    (with-server (s (%silent-handler closed-at))
      (multiple-value-bind (body)
          (http:open-response-stream (http:make-request :url (%local s "/") :read-timeout 5))
        (is (equal "first" (http:read-event body)))
        (close body))
      (loop repeat 30 until (car closed-at) do (sleep 0.1))
      (is-true (car closed-at) "the server saw the connection close"))))

;;; --- one rule for whether a host may be sent requests in the clear (#1082) ---------------

(test local-host-p-answers-for-names-literals-and-the-forms-that-look-local
  "#1082: hermes core and hermes/blob each wrote this rule, for a Twilio API base and an S3
endpoint, and the two copies acquired different holes -- see #1089 and the review of #1084. It
lives here now, next to the primitives it uses, so there is one implementation to get right."
  ;; Local: the name, and every literal whose category says so.
  (dolist (host '("localhost" "LOCALHOST" "127.0.0.1" "127.1.2.3" "::1" "10.0.0.5"
                  "172.17.0.2" "192.168.1.9" "169.254.1.2" "fc00::1" "fe80::1"))
    (is-true (http:local-host-p host) "~A is local" host))
  ;; Not local: public literals, and a name that does not resolve.
  (dolist (host '("8.8.8.8" "93.184.216.34" "2606:2800:220:1:248:1893:25c8:1946"
                  "nothing-here.invalid" "a.b.c.invalid"))
    (is-false (http:local-host-p host) "~A is not local" host))
  ;; 6TO4 IS NOT LOCAL, whatever address it carries. ADDRESS-CATEGORY answers about it by the
  ;; IPv4 address inside, which is the right conservative answer for a guard deciding whether a
  ;; destination may be reached at all, and the wrong answer for this question: 6to4 reaches its
  ;; destination through a public relay (the review of #1084).
  (dolist (host '("2002:7f00:1::" "2002:a00:5::" "2002:c0a8:109::"))
    (is-true (member (http:address-category host) '(:loopback :private))
             "control: ~A still reports a non-public category, which the SSRF guard needs" host)
    (is-false (http:local-host-p host) "but ~A is not local, because 6to4 goes over a relay" host))
  ;; NAT64 IS NOT LOCAL either, and for the same reason: reaching the IPv4 address means going
  ;; through a gateway that is often the carrier's (the review of #1094). Both the well-known
  ;; prefix and RFC 8215's local-use one.
  (dolist (host '("64:ff9b::7f00:1" "64:ff9b::a00:5"))
    (is-true (member (http:address-category host) '(:loopback :private))
             "control: ~A still reports a non-public category for the SSRF guard" host)
    (is-false (http:local-host-p host) "but ~A is not local, because NAT64 goes through a gateway" host))
  ;; RFC 8215's local-use prefix, 64:ff9b:1::/48, is NOT one ADDRESS-CATEGORY recognises:
  ;; %EMBEDDED-IPV4 handles only the well-known /96, so 64:ff9b:1::7f00:1 reports :PUBLIC and was
  ;; never local. Measured, after a control of mine asserted it was :LOOPBACK and failed. The
  ;; LOCAL-HOST-P exclusion covers it anyway, so the answer does not depend on which of the two
  ;; reasons applies.
  (is (eq :public (http:address-category "64:ff9b:1::7f00:1"))
      "the local-use NAT64 prefix is not read as carrying an IPv4 address")
  (is-false (http:local-host-p "64:ff9b:1::7f00:1"))
  ;; An IPv4-mapped loopback address IS local: there is no relay or gateway, it is the same stack.
  (is-true (http:local-host-p "::ffff:127.0.0.1"))
  ;; A LEADING ZERO IN A DOTTED QUAD IS NOT LOCAL, whatever the octets say. This is the one IPv4
  ;; spelling where PARSE-ADDRESS and the system resolver can disagree, and the connection
  ;; follows the resolver. 010.8.8.8 is the case that matters: PARSE-ADDRESS reads it as
  ;; 10.8.8.8 and calls it private (the review of #1094).
  (dolist (host '("010.8.8.8" "010.0.0.1" "0127.0.0.1" "127.000.0.1"))
    (is-false (http:local-host-p host) "~A is not local: its spelling is ambiguous" host))
  (is (eq :private (http:address-category "010.8.8.8"))
      "control: PARSE-ADDRESS does read 010.8.8.8 as a private address, which is the disagreement")
  ;; THE OTHER NON-CANONICAL SPELLINGS ARE KEPT, deliberately: they fail PARSE-ADDRESS, so they
  ;; go to RESOLVE-HOST -- the same resolver the connection uses -- and there is no second parser
  ;; to disagree with. If the resolver says loopback, the connection goes to loopback.
  ;;
  ;; ASSERTED UNCONDITIONALLY, AGAINST WHAT THE RESOLVER SAYS. An earlier version of this ran the
  ;; assertion only (WHEN RESOLVED), so a platform whose resolver declined these spellings turned
  ;; the check into nothing rather than into a failure -- the same shape as the empty-host case
  ;; above, which passed on three legs and failed on Windows for a reason unrelated to the
  ;; property it names. The expectation is now derived from the resolver's own answer, so it holds
  ;; whichever way a platform goes and still fails if LOCAL-HOST-P disagrees with it.
  ;;
  ;; %LOCAL-ADDRESS-P is the function LOCAL-HOST-P itself uses, not a copy of the rule written
  ;; here: what is being asserted is that LOCAL-HOST-P is RESOLVE-HOST composed with that
  ;; predicate, which is its contract. A control that re-derived locality would be checking a
  ;; copy of the thing under test.
  (dolist (host '("127.1" "0x7f.0.0.1" "2130706433" "localhost"))
    (let* ((addresses (http:resolve-host host))
           (expected (and addresses (every #'http::%local-address-p addresses) t)))
      (is (eq expected (and (http:local-host-p host) t))
          "~A: this resolver answers ~S, so LOCAL-HOST-P must be ~S" host addresses expected)))
  (is-false (http:local-host-p nil) "no host is not a local host")
  ;; AN EMPTY OR BLANK HOST IS REFUSED ON EVERY PLATFORM, which it was not before. On Linux
  ;; usocket:get-hosts-by-name "" signals NS-HOST-NOT-FOUND-ERROR, so the answer was NIL by
  ;; accident; on Windows getaddrinfo resolves an empty node name to the loopback address, so the
  ;; answer was T. This check passed on three legs and failed on Windows, which is the shape of a
  ;; test that is really asking what the local resolver does (#1082).
  (dolist (host (list "" " " "   " (format nil "~C" #\Tab)))
    (is-false (http:local-host-p host) "~S is not a local host" host))
  ;; The control: a name that does resolve locally is still local, so the refusal above is about
  ;; the host being empty and not about names having stopped working.
  (let ((resolved (http:resolve-host "localhost")))
    (is-true (and resolved (http:local-host-p "localhost"))
             "control: localhost is still local")))

(test local-host-p-requires-every-resolved-address-to-be-local
  "The review of #1094, and the sharpest finding in it: nothing exercised a name with more than
one resolved address, so changing EVERY to SOME in LOCAL-HOST-P passed the whole suite.
Measured before writing this -- 493 checks, Fail 0, with SOME in place.

That is the property that matters. A name resolving to one private address AND one public one
must NOT be local: the connection may go to either, so approving it would allow plaintext to a
public host on the strength of a loopback entry beside it.

RESOLUTION IS STUBBED rather than arranged in DNS, because the cases that matter -- mixed,
public-only, a resolution error -- cannot be conjured from a real resolver on a build machine,
and a test that waits for the network to produce them is a test that silently stops running."
  (let ((original (fdefinition 'http:resolve-host)))
    (unwind-protect
         (flet ((answering (addresses)
                  ;; ADDRESSES is a list, or :ERROR to make resolution signal.
                  (setf (fdefinition 'http:resolve-host)
                        (lambda (host)
                          (declare (ignore host))
                          (if (eq addresses :error)
                              (error "aion/http-client/tests: the resolver failed")
                              addresses)))))
           (dolist (case '((:all-local ((127 0 0 1)) t)
                           (:all-local-several ((127 0 0 1) (10 0 0 5) (192 168 1 9)) t)
                           (:public-only ((8 8 8 8)) nil)
                           (:public-several ((8 8 8 8) (93 184 216 34)) nil)
                           ;; THE CASE THAT KILLS "SOME": one local, one public. EVERY says no,
                           ;; SOME says yes, and the connection may use either address.
                           (:mixed-local-first ((127 0 0 1) (8 8 8 8)) nil)
                           (:mixed-public-first ((8 8 8 8) (127 0 0 1)) nil)
                           (:mixed-private-and-public ((10 0 0 5) (93 184 216 34)) nil)
                           (:empty () nil)))
             (destructuring-bind (name octet-lists expected) case
               (answering (mapcar (lambda (o) (coerce o 'vector)) octet-lists))
               (is (eq expected (and (http:local-host-p "a-name.invalid") t))
                   "~A: a name resolving to ~S is ~:[not ~;~]local"
                   name octet-lists expected)))
           ;; 6to4 among the answers: not local, however local the address it carries looks.
           (answering (list (http:parse-address "2002:7f00:1::")))
           (is-false (http:local-host-p "a-name.invalid")
                     "a name resolving only to 6to4 is not local")
           (answering (list (http:parse-address "127.0.0.1") (http:parse-address "2002:7f00:1::")))
           (is-false (http:local-host-p "a-name.invalid")
                     "nor is one resolving to a loopback address and a 6to4 address")
           ;; NAT64 likewise.
           (answering (list (http:parse-address "64:ff9b::7f00:1")))
           (is-false (http:local-host-p "a-name.invalid")
                     "nor one resolving only to NAT64")
           ;; A resolution error is not a local answer. LOCAL-HOST-P swallows it, so the point is
           ;; that it swallows it to NIL and not to T.
           (answering :error)
           (is-false (http:local-host-p "a-name.invalid")
                     "a name whose resolution signals is not local"))
      (setf (fdefinition 'http:resolve-host) original)))
  ;; The control: with resolution restored, a name that really does resolve locally is local
  ;; again, so the cases above were about the fixture and not about the stub being left in place.
  (is-true (http:local-host-p "localhost") "control: resolution is restored"))

(test url-host-reads-the-host-quri-would-connect-to
  "#1082: both callers had written this, and both got it wrong in their own way. QURI is used
because it is the parser dexador parses a request URL with, and the brackets come off because
every caller feeds the result to PARSE-ADDRESS or ADDRESS-CATEGORY."
  (dolist (case '(("http://localhost:9000/x" . "localhost")
                  ("http://127.0.0.1:9000" . "127.0.0.1")
                  ("http://[::1]:9000/x" . "::1")
                  ("https://[2606:2800::1]/x" . "2606:2800::1")
                  ("http://minio:9000" . "minio")
                  ;; The bypass that started #1089: a bracketed IPv6 in the userinfo. A parser
                  ;; that stripped brackets returned "::1" here and the request went elsewhere.
                  ("http://[::1]@evil.invalid/x" . "evil.invalid")
                  ("http://[::1]:80@evil.invalid/x" . "evil.invalid")
                  ("http://user:pw@evil.invalid" . "evil.invalid")))
    (is (equal (cdr case) (http:url-host (car case)))
        "~A has the host ~A" (car case) (cdr case)))
  (is-false (http:url-host "not a url at all") "a value with no host reads as none")
  ;; A bare authority has no scheme, and QURI reads the host as a scheme: callers prepend one.
  (is-false (equal "localhost" (http:url-host "localhost:9000"))
            "control: a bare host:port is NOT a URL, which is why callers add a scheme first"))

(test proxy-arguments-decides-without-resolving-a-name
  "The review of #1094. This decision used to call LOCAL-HOST-P, which resolves a name, on every
plaintext request. Two problems: a blocking lookup on the send path that CONNECT-TIMEOUT does not
cover, and a rebinding window -- a name that answers private now can answer public at connect
time, and the request would then skip a configured egress proxy on the strength of a resolution
that no longer holds. The decision is made for \"localhost\" and IP literals only; deciding by
name belongs at configuration time, where a wrong answer is a refusal rather than a silently
unproxied request."
  (let ((looked-up '())
        (original (fdefinition 'http:resolve-host)))
    (unwind-protect
         (progn
           (setf (fdefinition 'http:resolve-host)
                 (lambda (host) (push host looked-up) (funcall original host)))
           (dolist (url '("http://127.0.0.1:9000/x" "http://localhost/x" "http://[::1]/x"
                          "http://10.0.0.5/x" "http://a-name.invalid/x" "https://a-name.invalid/x"
                          "http://8.8.8.8/x"))
             (http:proxy-arguments url))
           (is (null looked-up)
               "no name was resolved to decide how to proxy: ~S" looked-up)
           ;; THE APPROVAL PATH RESOLVES NOTHING EITHER, and nothing asserted that until the
           ;; review of #1134. The whole point of carrying a recorded verdict is that the send
           ;; path does no lookup; a lookup added to this branch alone would have satisfied every
           ;; assertion above, because none of them set an approval. Both schemes, because the
           ;; https case takes a different exit and could resolve on the way to it.
           (dolist (url '("http://approved.invalid/x" "https://approved.invalid/x"
                          "http://other.invalid/x"))
             (http::call-with-approved-local-host "approved.invalid"
                                                  (lambda () (http:proxy-arguments url))))
           (is (null looked-up)
               "no name was resolved with an approval set either: ~S" looked-up)
           ;; The control: the stub does fire when something asks LOCAL-HOST-P about a name, so
           ;; the assertions above are about this path and not about an unreachable stub.
           (http:local-host-p "another-name.invalid")
           (is-true (member "another-name.invalid" looked-up :test #'string=)
                    "control: LOCAL-HOST-P does resolve a name: ~S" looked-up))
      (setf (fdefinition 'http:resolve-host) original)))
  ;; A DNS name keeps whatever proxy is configured, local-looking or not.
  (dolist (url '("http://a-name.invalid/x" "http://minio/x"))
    (is (null (http:proxy-arguments url))
        "~A is a name, so its proxy is left alone" url)))

(test a-plaintext-request-to-a-local-host-is-not-sent-through-a-proxy
  "#1091: dexador sets *DEFAULT-PROXY* from HTTPS_PROXY or HTTP_PROXY when it loads and honours
no NO_PROXY, and %DEX-ARGS never passed :PROXY. So a caller that had checked its destination was
local -- hermes for a Twilio API base, hermes/blob for an S3 endpoint -- could still have its
credentials carried off the machine in the clear, because the bytes went to the proxy instead of
to the host that was checked.

The assertion is on what dexador is given, not on what a request returns: a fixture whose proxy
is unreachable would pass for the wrong reason."
  (flet ((proxy-arg (url)
           ;; Through %DEX-ARGS, which is the path AION/HTTP-CLIENT:SEND-REQUEST takes. The
           ;; decision itself is PROXY-ARGUMENTS, which hermes/blob's direct dexador call uses
           ;; too -- when it lived only here, that backend was not covered (the review of #1094).
           (let ((args (http::%dex-args (http:make-request :method :get :url url))))
             (if (member :proxy args) (list :passed (getf args :proxy)) :not-passed))))
    ;; Exempted: plaintext to a local host, by name or by address.
    (dolist (url '("http://127.0.0.1:9000/x" "http://localhost/x" "http://[::1]:9000/x"
                   "http://10.0.0.5/x" "http://169.254.1.2/x"))
      (is (equal '(:passed nil) (proxy-arg url))
          "~A is sent with :proxy nil, so no proxy can see it" url))
    ;; Not exempted: https anywhere, because a proxied https request is a CONNECT tunnel and the
    ;; credentials are inside TLS; and plaintext to a host that is not local, where whoever
    ;; configured it is already sending in the clear.
    (dolist (url '("https://127.0.0.1/x" "https://api.example.invalid/x" "http://8.8.8.8/x"
                   ;; A NAME keeps its proxy now, even one that might resolve locally: see
                   ;; PROXY-ARGUMENTS-DECIDES-WITHOUT-RESOLVING-A-NAME.
                   "http://api.example.invalid/x" "http://minio/x"))
      (is (eq :not-passed (proxy-arg url))
          "~A keeps whatever proxy is configured" url))
    ;; 6to4 is not local, so it is not exempted either.
    (is (eq :not-passed (proxy-arg "http://2002:7f00:1::/x"))
        "a 6to4 address is not local, so its request is not exempted")))

(test an-approval-exempts-only-its-own-host-and-follows-no-redirect
  "The review of #1134, which found two ways the recorded approval reached a request it was not
about.

THE APPROVAL IS A HOST, NOT A BOOLEAN. As a boolean it said only that something had been
approved, which is not a statement about the request being sent: a provider whose URL had moved
on, or a verdict recorded for one host and read while another sat in the slot, exempted a request
to a host nothing had approved. It now has to equal the URL's host.

AN EXEMPTED REQUEST FOLLOWS NO REDIRECT. dexador follows a redirect to a DIFFERENT host by
recursing with the same arguments and the same headers -- it prepends a new Host and keeps the
rest, in the cross-host branch of its redirect handling in src/backend/usocket.lisp -- so a 307
from the approved host to http://public.example/ would be fetched with :PROXY NIL AND with the
Authorization header built for the approved host. That is the credential leaving the machine, not
merely a proxy being skipped. The exemption is about a destination this machine reaches by
itself, and a redirect leaves that destination, so :MAX-REDIRECTS 0 travels with it.

THE LITERAL PATH KEEPS FOLLOWING REDIRECTS. It has the same hazard in principle -- a 307 from
127.0.0.1 can name a public host just as easily -- but the cause is dexador carrying headers
across a cross-host redirect rather than anything about this rule, the literal rule is what every
caller of this client gets, and following a redirect to a local server is behaviour this client
documents and tests. Turning it off here broke REDIRECTS-CAN-BE-REFUSED-CAPPED-OR-FOLLOWED, which
follows redirects against a test server at 127.0.0.1. APPROVED-LOCAL, by contrast, is passed only
by a configuration step about to send a credential, and none of those callers follows redirects."
  ;; The host has to match.
  (flet ((with-approval (host url)
           (http::call-with-approved-local-host host (lambda () (http:proxy-arguments url)))))
    (is (null (with-approval "approved.invalid" "http://other.invalid/x"))
        "an approval for one host does not exempt a request to another")
    (is (equal '(:proxy nil :max-redirects 0)
               (with-approval "approved.invalid" "http://approved.invalid/x"))
        "and does exempt its own host, with redirects off")
    (is (null (with-approval "approved.invalid" "https://approved.invalid/x"))
        "https is never exempted, approval or not")
    ;; T is not a host, so the old boolean shape grants nothing rather than everything.
    (is (null (with-approval t "http://approved.invalid/x"))
        "T is not a host and grants no exemption"))

  ;; And what a request actually hands dexador.
  (flet ((args (url &key approved-local)
           (http::call-with-approved-local-host
            approved-local
            (lambda ()
              (http::%dex-args (http:make-request :method :get :url url
                                                  :follow-redirects 5))))))
    (let ((exempt (args "http://approved.invalid/x" :approved-local "approved.invalid"))
          (literal (args "http://127.0.0.1:9000/x"))
          (ordinary (args "http://public.invalid/x"))
          (mismatched (args "http://other.invalid/x" :approved-local "approved.invalid")))
      (is (eql 0 (getf exempt :max-redirects))
          "an exempted request is given :max-redirects 0: ~S" exempt)
      (is (= 1 (count :max-redirects exempt))
          ":max-redirects is passed once, so the value cannot depend on argument order: ~S"
          exempt)
      (is (eql 5 (getf literal :max-redirects))
          "while one exempted by an IP literal still follows redirects: ~S" literal)
      (is (equal '(:proxy nil) (http:proxy-arguments "http://127.0.0.1:9000/x"))
          "the literal rule exempts the proxy and says nothing about redirects")
      ;; The controls: a request that is not exempt keeps the redirect budget it asked for.
      (is (eql 5 (getf ordinary :max-redirects))
          "control: an ordinary request still follows redirects: ~S" ordinary)
      (is-false (member :proxy ordinary)
                "control: and is not given :proxy at all: ~S" ordinary)
      (is (eql 5 (getf mismatched :max-redirects))
          "control: a mismatched approval changes neither argument: ~S" mismatched)
      (is-false (member :proxy mismatched)
                "control: and leaves the proxy alone: ~S" mismatched))))

(test the-exported-surface-cannot-claim-a-host-is-local
  "The re-review of #1134. The approval used to be :APPROVED-LOCAL, a keyword on MAKE-REQUEST and
on PROXY-ARGUMENTS, both of which are exported -- so any caller could assert it for any host:

  (make-request :url \"http://public.example/x\" :approved-local \"public.example\"
                :headers <an Authorization header>)

got :PROXY NIL and :MAX-REDIRECTS 0 for a public host, which is the same door that was closed by
taking the initarg off hermes/blob's slot, left open one layer down. The approval is now
*APPROVED-LOCAL-HOST*, which is not exported and is not an argument to anything exported.

THIS TEST IS ABOUT THE EXPORTED SURFACE, so it uses only exported symbols to try to produce the
exemption, and asserts that it cannot. The framework's own senders reach the internal binder with
a double colon, which is the line this codebase draws around anything a caller is not meant to
use; that path has its own tests."
  ;; PROXY-ARGUMENTS takes one argument, so passing the old keyword to it is a PROGRAM-ERROR.
  (signals program-error
    (funcall (fdefinition 'http:proxy-arguments)
             "http://public.example/x" :approved-local "public.example"))
  ;; MAKE-REQUEST REJECTS IT TOO. SBCL signals SB-EXT:UNKNOWN-KEYWORD-ARGUMENT, which is a
  ;; subtype of PROGRAM-ERROR: (subtypep (quote sb-ext:unknown-keyword-argument)
  ;; (quote program-error)) answers T, measured rather than assumed, and the behaviour is the
  ;; same compiled or interpreted.
  ;;
  ;; A COMMENT HERE ONCE CLAIMED THE OPPOSITE -- that the constructor accepted the keyword and
  ;; ignored it -- on the strength of a script that printed "RETURNED NORMALLY". That script had
  ;; loaded a STALE FASL, built before the keyword was removed, so what it measured was the old
  ;; constructor accepting its own keyword. THE SUITE AGREED WITH THE SCRIPT for the same reason,
  ;; in a worktree whose fasls were equally stale, and the first thing to disagree was a CI leg,
  ;; which always builds cold. A measurement taken outside a cold build is worth only as much as
  ;; the build it ran against -- and so is one taken inside a warm one.
  (signals program-error
    (funcall (fdefinition 'http:make-request)
             :method :get :url "http://public.example/x" :approved-local "public.example"))
  ;; And nothing an exported call can do produces the exemption for a public host.
  (is (null (http:proxy-arguments "http://public.example/x"))
      "a public host is not exempted")
  (let ((args (http::%dex-args (http:make-request :method :get :url "http://public.example/x"
                                                  :headers '(("Authorization" . "Bearer x"))))))
    (is-false (member :proxy args)
              "and a request built through the exported surface is given no :proxy: ~S" args)
    ;; 5 is MAKE-REQUEST's default FOLLOW-REDIRECTS, so this asserts the redirect cap is left
    ;; exactly as the caller's request asked for it.
    (is (eql 5 (getf args :max-redirects))
        "with its own redirect setting untouched: ~S" args))
  ;; The control: the internal binder DOES produce it, so the assertions above are about the
  ;; exported surface and not about the exemption having been removed altogether.
  (is (equal '(:proxy nil :max-redirects 0)
             (http::call-with-approved-local-host
              "public.example"
              (lambda () (http:proxy-arguments "http://public.example/x"))))
      "control: the internal binding still grants it"))

(defun %hops-for (url target &key (headers '(("Authorization" . "Bearer secret")
                                             ("Cookie" . "session=secret")
                                             ("Content-Type" . "application/json")))
                                  (method :post) (follow 5) content)
  "Send one request that is answered with a 307 to TARGET, and return what dexador was given for
each hop: a list of (url . headers), in order.

THE STUB ANSWERS DEXADOR'S OWN CONVENTION -- (values body status headers) with a hash-table of
lowercased header names -- because that is what %HTTP-ONCE reads. The assertion downstream is on
the SECOND entry: the first hop is identical whatever the fix does."
  (let ((seen '())
        (original (fdefinition 'dex:request)))
    (unwind-protect
         (progn
           (setf (fdefinition 'dex:request)
                 (lambda (u &rest args)
                   (push (cons u (getf args :headers)) seen)
                   (if (= 1 (length seen))
                       (values "" 307 (let ((h (make-hash-table :test #'equal)))
                                        (setf (gethash "location" h) target)
                                        h))
                       (values "done" 200 (make-hash-table :test #'equal)))))
           (http:send-request (http:make-request :method method :url url :headers headers
                                                 :content content :follow-redirects follow)
                              '()))
      (setf (fdefinition 'dex:request) original))
    (reverse seen)))

(defun %carried (hop name)
  (cdr (assoc name (cdr hop) :test #'string-equal)))

(test a-cross-origin-redirect-does-not-carry-the-credential
  "#1139. dexador follows a redirect to a DIFFERENT host by recursing into its own REQUEST with
the same arguments and the same headers -- it prepends a new Host and keeps the rest, in the
cross-host branch of src/backend/usocket.lisp -- so an Authorization header built for one host
was delivered to whatever a 3xx named. Nothing in this tree would have noticed: the configuration
checks in #1077, #1092 and #1106 check the base a request is sent TO, which is the right thing to
check and a different thing from where a redirect then leads.

THE ASSERTION IS ON WHAT THE SECOND REQUEST CARRIED, not on whether the request succeeded. A
fixture whose redirect target is unreachable would pass for the wrong reason, because the first
hop looks identical either way.

BOTH DIRECTIONS, and the same-origin one is why this is not simply `stop following redirects': an
API that renames a path answers 301 and expects the credential to follow it. Origin is scheme,
host and port, so a change in any of the three drops the headers -- including a hop from https to
http on the same host, which is the one a reader is most likely to assume is safe."
  ;; A hop to another host: the credential headers are gone, the others stay.
  (let ((hops (%hops-for "https://api.example.com/v1/x" "https://evil.example/collect")))
    (is (= 2 (length hops)) "both hops reached dexador: ~S" hops)
    (is (equal "Bearer secret" (%carried (first hops) "authorization"))
        "the first hop carries the credential, as it must: ~S" (first hops))
    (is-false (%carried (second hops) "authorization")
              "and the second does not: ~S" (second hops))
    (is-false (%carried (second hops) "cookie")
              "nor the cookie: ~S" (second hops))
    (is (equal "application/json" (%carried (second hops) "content-type"))
        "while a header that is not a credential survives: ~S" (second hops))
    (is (equal "https://evil.example/collect" (car (second hops)))
        "and the hop went where the Location said: ~S" (second hops)))
  ;; A hop within the same origin keeps them.
  (let ((hops (%hops-for "https://api.example.com/v1/x" "https://api.example.com/v2/x")))
    (is (equal "Bearer secret" (%carried (second hops) "authorization"))
        "a same-origin redirect keeps the credential: ~S" (second hops))
    (is (equal "session=secret" (%carried (second hops) "cookie"))
        "and the cookie: ~S" (second hops)))
  ;; A relative Location is resolved against the URL it came from, and stays same-origin.
  (let ((hops (%hops-for "https://api.example.com/v1/x" "/v2/x")))
    (is (equal "https://api.example.com/v2/x" (car (second hops)))
        "a relative Location is merged with the URL it came from: ~S" (second hops))
    (is (equal "Bearer secret" (%carried (second hops) "authorization"))
        "and is still the same origin, so the credential follows: ~S" (second hops)))
  ;; THE THREE PARTS OF AN ORIGIN, each on its own. The scheme and port cases are the ones a
  ;; reader is most likely to think safe, because the host has not changed.
  (dolist (case '(("https://api.example.com/v1/x" . "http://api.example.com/v1/x")
                  ("https://api.example.com/v1/x" . "https://api.example.com:8443/v1/x")
                  ("https://api.example.com/v1/x" . "https://other.example.com/v1/x")))
    (let ((hops (%hops-for (car case) (cdr case))))
      (is-false (%carried (second hops) "authorization")
                "~A -> ~A is a different origin, so the credential is dropped: ~S"
                (car case) (cdr case) (second hops))))
  ;; A request with no credential is left on dexador's own path: one call, with the redirect
  ;; followed inside dexador rather than here.
  (let ((hops (%hops-for "https://api.example.com/v1/x" "https://evil.example/collect"
                         :headers '(("Content-Type" . "application/json")))))
    (is (= 1 (length hops))
        "a request carrying no credential is not followed hop by hop here: ~S" hops))
  ;; And FOLLOW-REDIRECTS NIL still returns the 3xx itself rather than following it.
  (let ((hops (%hops-for "https://api.example.com/v1/x" "https://evil.example/collect"
                         :follow nil)))
    (is (= 1 (length hops)) "follow-redirects NIL follows nothing: ~S" hops)))

(test a-redirect-chain-is-bounded-and-changes-method-as-dexador-does
  "#1139, the two properties the hop loop has to preserve now that it is this client's loop
rather than dexador's.

THE CAP IS THE REQUEST'S OWN FOLLOW-REDIRECTS, counted in hops, so a server answering a redirect
for ever cannot keep this going. THE METHOD CHANGES ON 301, 302 AND 303 and is kept on 307 and
308, which is what dexador does, what browsers do, and the entire reason 307 and 308 exist; a
loop that silently turned a POST into a GET on a 307, or kept a POST on a 303, would be a
different client than the one every caller was written against."
  (let ((seen '())
        (original (fdefinition 'dex:request)))
    (unwind-protect
         (progn
           ;; A server that always redirects, to a new path each time.
           (setf (fdefinition 'dex:request)
                 (lambda (u &rest args)
                   (push (list u (getf args :method)) seen)
                   (values "" 307 (let ((h (make-hash-table :test #'equal)))
                                    (setf (gethash "location" h)
                                          (format nil "https://api.example.com/~D" (length seen)))
                                    h))))
           (http:send-request
            (http:make-request :method :post :url "https://api.example.com/start"
                               :headers '(("Authorization" . "Bearer secret"))
                               :follow-redirects 3)
            '()))
      (setf (fdefinition 'dex:request) original))
    (is (= 4 (length seen))
        "a cap of 3 makes 4 requests in all -- the first and three hops: ~D" (length seen))
    (is (every (lambda (call) (eq :post (second call))) seen)
        "and a 307 keeps the method throughout: ~S" (reverse seen)))
  ;; 303 turns a POST into a GET; 307 does not. Asserted on what the second hop was given.
  (dolist (case '((303 . :get) (302 . :get) (301 . :get) (307 . :post) (308 . :post)))
    (let ((seen '())
          (original (fdefinition 'dex:request)))
      (unwind-protect
           (progn
             (setf (fdefinition 'dex:request)
                   (lambda (u &rest args)
                     (push (list u (getf args :method)) seen)
                     (if (= 1 (length seen))
                         (values "" (car case)
                                 (let ((h (make-hash-table :test #'equal)))
                                   (setf (gethash "location" h) "https://api.example.com/next")
                                   h))
                         (values "done" 200 (make-hash-table :test #'equal)))))
             (http:send-request
              (http:make-request :method :post :url "https://api.example.com/start"
                                 :headers '(("Authorization" . "Bearer secret"))
                                 :follow-redirects 5)
              '()))
        (setf (fdefinition 'dex:request) original))
      (is (eq (cdr case) (second (second (reverse seen))))
          "a ~D sends the next hop as ~S: ~S" (car case) (cdr case) (reverse seen)))))

(test every-credential-header-this-tree-sends-is-dropped-across-an-origin
  "The review of #1141. The first version of this decided the path and stripped the headers from
two lists written separately -- Authorization and Cookie -- so Anthropic's x-api-key
(praxeon/src/llm.lisp) and Google's x-goog-api-key (praxeon/src/image-google.lisp), both of which
go through SEND-REQUEST, were still forwarded to whatever a cross-host 307 named. PRINT-OBJECT
had named all four since #844, one screen away.

+CREDENTIAL-HEADERS+ is the one list now, read by both.

THE NAMES ARE WRITTEN OUT HERE, not read from that list. A first version of this test walked
+CREDENTIAL-HEADERS+, which made it VACUOUS IN THE DIRECTION THAT MATTERS: shrinking the list
back to Authorization and Cookie shrank the test with it and still passed, so it could not have
caught the defect it was written for. My own control is what showed that. The four names are a
claim about what this tree sends -- Authorization and Cookie anywhere, x-api-key in
praxeon/src/llm.lisp, x-goog-api-key in praxeon/src/image-google.lisp -- and a claim about the
tree has to be written down, not derived from the thing under test. The list-walk is kept as a
second loop, so a name added to the list without being handled fails too."
  (dolist (name '("authorization" "cookie" "x-api-key" "x-goog-api-key"))
    (let ((hops (%hops-for "https://api.example.com/v1/x" "https://evil.example/collect"
                           :headers (list (cons name "secret")
                                          (cons "Content-Type" "application/json")))))
      (is (= 2 (length hops))
          "a request carrying ~A is followed hop by hop here: ~S" name hops)
      (is (equal "secret" (%carried (first hops) name))
          "~A is sent on the first hop, as it must be: ~S" name (first hops))
      (is-false (%carried (second hops) name)
                "~A does not reach the other origin: ~S" name (second hops))
      (is (equal "application/json" (%carried (second hops) "content-type"))
          "while a header that is not a credential survives: ~S" (second hops))))
  ;; Every name the list holds, so one added there without being handled fails as well. This is
  ;; the loop that cannot catch a name MISSING from the list, which is why the names above are
  ;; written out.
  (dolist (name http::+credential-headers+)
    (let ((hops (%hops-for "https://api.example.com/v1/x" "https://evil.example/collect"
                           :headers (list (cons name "secret")))))
      (is (= 2 (length hops)) "~A is recognised as a credential header: ~S" name hops)
      (is-false (%carried (second hops) name)
                "~A does not reach the other origin: ~S" name (second hops))))
  ;; The control: a header that is NOT on the list is carried across, so the assertions above
  ;; are about the list and not about every header being stripped.
  (let ((hops (%hops-for "https://api.example.com/v1/x" "https://evil.example/collect"
                         :headers '(("Authorization" . "Bearer s")
                                    ("X-Request-Id" . "abc123")))))
    (is (equal "abc123" (%carried (second hops) "x-request-id"))
        "control: a header that identifies nobody is still carried: ~S" (second hops))))

(test a-body-is-not-repeated-to-another-origin
  "The review of #1141, and the half that stripping headers says nothing about: A CREDENTIAL CAN
BE IN THE BODY. Facebook's POST carries access_token in the form body, so a 307 or 308 across
origin would have handed it over with every header correctly removed.

307 and 308 repeat the request as it was, body included. There is no way to follow such a hop
safely -- the body is the caller's to re-send or not -- so the 3xx is returned and the caller
decides. 301, 302 and 303 turn a non-GET into a GET, and the body goes with the method: a GET
carrying the old form body and its Content-Type is neither what the server will read nor what the
caller sent."
  ;; A cross-origin 307 with a body: not followed, and the 3xx is the answer.
  (let ((hops (%hops-for "https://api.example.com/v1/x" "https://evil.example/collect"
                         :content "access_token=secret&message=hi")))
    (is (= 1 (length hops))
        "a cross-origin 307 carrying a body is not followed: ~S" hops))
  ;; The control: the same hop WITHIN the origin is followed, with the body intact, because
  ;; nothing leaves the origin that sent it.
  (let ((hops (%hops-for "https://api.example.com/v1/x" "https://api.example.com/v2/x"
                         :content "access_token=secret&message=hi")))
    (is (= 2 (length hops))
        "control: a same-origin 307 with a body is still followed: ~S" hops)
    (is (equal "Bearer secret" (%carried (second hops) "authorization"))
        "control: and still carries the credential: ~S" (second hops)))
  ;; And a cross-origin 307 with NO body is followed, headers stripped -- so the refusal above is
  ;; about the body and not about 307 itself.
  (let ((hops (%hops-for "https://api.example.com/v1/x" "https://evil.example/collect"
                         :content nil)))
    (is (= 2 (length hops))
        "control: a cross-origin 307 with no body is followed: ~S" hops)
    (is-false (%carried (second hops) "authorization")
              "control: with the credential dropped: ~S" (second hops))))

(test a-redirect-that-becomes-a-get-drops-the-body-and-its-content-type
  "The review of #1141. The loop turned a POST into a GET on 301, 302 and 303 -- which is right,
and what dexador and every browser do -- and kept the content and the Content-Type, which is
not. A GET carrying the previous request's form body is neither what the server will read nor
what the caller sent, and when the body holds a credential it is one more place for it to go."
  (dolist (status '(301 302 303))
    (let ((seen '())
          (original (fdefinition 'dex:request)))
      (unwind-protect
           (progn
             (setf (fdefinition 'dex:request)
                   (lambda (u &rest args)
                     (push (list u (getf args :method) (getf args :content)
                                 (getf args :headers))
                           seen)
                     (if (= 1 (length seen))
                         (values "" status
                                 (let ((h (make-hash-table :test #'equal)))
                                   (setf (gethash "location" h) "https://api.example.com/next")
                                   h))
                         (values "done" 200 (make-hash-table :test #'equal)))))
             (http:send-request
              (http:make-request :method :post :url "https://api.example.com/start"
                                 :headers '(("Authorization" . "Bearer secret")
                                            ("Content-Type" . "application/x-www-form-urlencoded"))
                                 :content "access_token=secret"
                                 :follow-redirects 5)
              '()))
        (setf (fdefinition 'dex:request) original))
      (let ((second (second (reverse seen))))
        (is (eq :get (second second)) "a ~D sends the next hop as a GET: ~S" status second)
        (is-false (third second) "with no body: ~S" status second)
        (is-false (cdr (assoc "content-type" (fourth second) :test #'string-equal))
                  "and no Content-Type: ~S" second))))
  ;; The control: a 307 keeps the method, the body and the Content-Type, within the origin.
  (let ((seen '())
        (original (fdefinition 'dex:request)))
    (unwind-protect
         (progn
           (setf (fdefinition 'dex:request)
                 (lambda (u &rest args)
                   (push (list u (getf args :method) (getf args :content)) seen)
                   (if (= 1 (length seen))
                       (values "" 307 (let ((h (make-hash-table :test #'equal)))
                                        (setf (gethash "location" h)
                                              "https://api.example.com/next")
                                        h))
                       (values "done" 200 (make-hash-table :test #'equal)))))
           (http:send-request
            (http:make-request :method :post :url "https://api.example.com/start"
                               :headers '(("Authorization" . "Bearer secret"))
                               :content "x=1" :follow-redirects 5)
            '()))
      (setf (fdefinition 'dex:request) original))
    (let ((second (second (reverse seen))))
      (is (eq :post (second second)) "control: a 307 keeps the method: ~S" second)
      (is (equal "x=1" (third second)) "control: and the body: ~S" second))))

(test an-approved-local-request-still-follows-no-redirect
  "The review of #1141, and a rule of #1134's that this loop bypassed. PROXY-ARGUMENTS answers
:MAX-REDIRECTS 0 for a request to a host a configuration step approved as local, because dexador
carries both the proxy exemption and the credential across a cross-host redirect. dexador obeyed
that -- and then %HTTP-FOLLOWING-REDIRECTS followed the 3xx itself, so the rule held for every
request except the ones it was written for. The docstring in fetch.lisp saying a 3xx is the
response for such a request was false while that was so.

The dispatch sends an approved request down the single-shot path instead, which keeps the rule
where it already lives rather than restating it here, so the two cannot drift.

THE ASSERTION GOES THROUGH SEND-REQUEST, not through PROXY-ARGUMENTS: the bypass was in the
layer above it, so asking PROXY-ARGUMENTS would have answered correctly while the request was
still followed."
  (let ((seen '())
        (original (fdefinition 'dex:request)))
    (unwind-protect
         (progn
           ;; THE STUB TERMINATES, answering 200 once the redirect has been taken. Answering 307
           ;; to everything made the control follow until its budget ran out, and an assertion on
           ;; the number of calls then measured the budget rather than the approval.
           (setf (fdefinition 'dex:request)
                 (lambda (u &rest args)
                   (push (list u (getf args :max-redirects)) seen)
                   (if (search "collect" u)
                       (values "done" 200 (make-hash-table :test #'equal))
                       (values "" 307 (let ((h (make-hash-table :test #'equal)))
                                        (setf (gethash "location" h)
                                              "http://evil.example/collect")
                                        h)))))
           ;; Under an approval for this host.
           (http::call-with-approved-local-host
            "approved.invalid"
            (lambda ()
              (http:send-request
               (http:make-request :method :get :url "http://approved.invalid/v1/x"
                                  :headers '(("Authorization" . "Bearer secret"))
                                  :follow-redirects 5)
               '())))
           ;; And the control, with no approval: the same 3xx IS followed, hop by hop.
           (http:send-request
            (http:make-request :method :get :url "http://other.invalid/v1/x"
                               :headers '(("Authorization" . "Bearer secret"))
                               :follow-redirects 5)
            '()))
      (setf (fdefinition 'dex:request) original))
    (let ((calls (reverse seen)))
      (is (equal '("http://approved.invalid/v1/x" 0) (first calls))
          "an approved request is sent once, with :max-redirects 0: ~S" (first calls))
      (is (equal "http://other.invalid/v1/x" (first (second calls)))
          "control: an unapproved request starts the same way: ~S" (second calls))
      (is (= 3 (length calls))
          "and is followed, so the approval is what stopped the first: ~S" calls))))
