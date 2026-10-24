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

(defun %start-server (handler &key tls)
  "A server on 127.0.0.1 answering with HANDLER, a function of (path head stream) that writes
the response. Records every request head. TLS T presents the certificate for pinned.test; TLS :IP
presents the one whose names are the addresses 127.0.0.1 and ::1."
  (let ((base (if (eq tls :ip) "ip-test" "pinned-test")))
    (aion/test-http:start-server
     (lambda (request stream)
       (funcall handler (aion/test-http:request-path request)
                (aion/test-http:request-head request) stream))
     :tls-certificate (and tls (%fixture (format nil "~A.crt" base)))
     :tls-key (and tls (%fixture (format nil "~A.key" base)))
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

;;; --- a pinned connection (not on Windows) -----------------------------------------------

(test a-pinned-connection-keeps-the-host-name-in-the-host-header
  "pinned.test does not resolve anywhere, so the request can only have reached the server
through CONNECT-ADDRESS; the server received the name, not the address."
  (skip-on-windows "a pinned connection is not available on Windows (WinHTTP)"
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
  (skip-on-windows "a pinned connection is not available on Windows (WinHTTP)"
    (with-server (s (lambda (path head stream)
                      (declare (ignore path head))
                      (%write-response stream 200 '() "over tls"))
                    :tls t)
      (flet ((get-as (host &key (ca (%fixture "pinned-test.crt")))
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
other.test is refused. (cl+ssl also accepts the common name, ip.test, even though the certificate
has subject alternative names, which RFC 6125 does not allow. That is unchanged here.)"
  (skip-on-windows "a pinned connection is not available on Windows (WinHTTP)"
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
        (signals http:http-error (get-as "other.test"))))))

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
  (skip-on-windows "fetch-public pins its connections, which Windows does not support here"
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
  (skip-on-windows "fetch-public pins its connections, which Windows does not support here"
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
  (skip-on-windows "fetch-public pins its connections, which Windows does not support here"
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
  (skip-on-windows "fetch-public pins its connections, which Windows does not support here"
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
  (skip-on-windows "fetch-public pins its connections, which Windows does not support here"
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
