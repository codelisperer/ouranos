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
the response. Records every request head. TLS presents the test certificate."
  (aion/test-http:start-server
   (lambda (request stream)
     (funcall handler (aion/test-http:request-path request)
              (aion/test-http:request-head request) stream))
   :tls-certificate (and tls (%fixture "pinned-test.crt"))
   :tls-key (and tls (%fixture "pinned-test.key"))
   :name "http-client test server"))

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
