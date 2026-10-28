;;;; server-uv-tls-tests.lisp --- HTTPS in hyperion/server-uv, over real sockets (#125).
;;;;
;;;; Every success here has a refusal beside it that differs in one thing, because a test that
;;;; checks only that a request worked cannot tell TLS from plaintext on the same port. The
;;;; certificates are made in each run by aion/tls, in a directory that has never existed
;;;; before, so nothing in the tree expires and no private key is committed. The client is
;;;; aion/tls's blocking stream over an sb-bsd-sockets connection, and one test uses curl,
;;;; which is not mbedTLS, so a disagreement between our server and another client can show.

(cl:defpackage #:hyperion/server-uv/tls/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:srv #:hyperion/server-uv)
                    (#:https #:hyperion/server-uv/tls)
                    (#:tls #:aion/tls)
                    (#:secret #:aion/secret)
                    (#:sock #:sb-bsd-sockets)
                    (#:ports #:hyperion/test-ports))
  (:export #:run-tests))

(cl:in-package #:hyperion/server-uv/tls/tests)

(def-suite server-uv-tls :description "HTTPS in hyperion/server-uv (#125).")
(in-suite server-uv-tls)

(defun run-tests ()
  "Run the suite; return T on success (for asdf:test-system)."
  (run! 'server-uv-tls))

(defparameter +io-timeout+ 10)

;;; --- certificates ----------------------------------------------------------------------

(defstruct (pki (:constructor %make-pki) (:copier nil))
  "A CA, a server certificate for localhost and 127.0.0.1 that it signed, a second CA that
signed nothing, and where they were written."
  dir ca-pem other-ca-pem cert-path key-path cert-pem key-pem)

(defun %write-octets (path octets)
  (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                            :if-exists :supersede)
    (write-sequence octets out))
  path)

(defun make-pki (&key (not-after (+ (get-universal-time) (* 30 86400)))
                      (not-before (- (get-universal-time) 3600)))
  "A fresh PKI in a directory of its own."
  (let* ((dir (aion/fs:make-temporary-directory "uv-tls"))
         (ca-key (tls:generate-private-key))
         (other-key (tls:generate-private-key))
         (server-key (tls:generate-private-key)))
    (unwind-protect
         (let* ((ca-pem (tls:issue-certificate :subject "CN=Test CA" :subject-key ca-key :ca t))
                (other-pem (tls:issue-certificate :subject "CN=Other CA" :subject-key other-key :ca t))
                (cert-pem (tls:issue-certificate :subject "CN=localhost" :subject-key server-key
                                                 :issuer "CN=Test CA" :issuer-key ca-key
                                                 :dns-name "localhost" :ipv4 #(127 0 0 1)
                                                 :not-before not-before :not-after not-after))
                (key-pem (tls:private-key-pem server-key)))
           (%make-pki :dir dir :ca-pem ca-pem :other-ca-pem other-pem
                     :cert-pem cert-pem :key-pem key-pem
                     :cert-path (%write-octets (merge-pathnames "server.pem" dir) cert-pem)
                     :key-path (%write-octets (merge-pathnames "server.key" dir) key-pem)))
      (tls:free-private-key ca-key)
      (tls:free-private-key other-key)
      (tls:free-private-key server-key))))

(defun %sha256 (octets)
  (ironclad:byte-array-to-hex-string
   (ironclad:digest-sequence :sha256 (coerce octets '(simple-array (unsigned-byte 8) (*))))))

(defun %leaf-der (pem)
  (let ((chain (tls:make-certificate-chain pem)))
    (unwind-protect (tls:certificate-chain-der chain)
      (tls:free-certificate-chain chain))))

;;; --- the server and the client ----------------------------------------------------------

(defun %app (env)
  (declare (ignore env))
  (list 200 '(:content-type "text/plain") (list "hello over tls")))

(defmacro with-https-server ((server port set) &body body)
  "Start %APP with :TLS SET on an ephemeral port, and always stop it. STOP frees SET."
  `(let* ((,server (srv:start #'%app :port 0 :tls ,set))
          (,port (srv:server-port ,server)))
     (unwind-protect (progn ,@body)
       (srv:stop ,server))))

(defun %connect (port)
  (let ((s (make-instance 'sock:inet-socket :type :stream :protocol :tcp)))
    (sock:socket-connect s #(127 0 0 1) port)
    (values s (sock:socket-make-stream s :input t :output t :element-type '(unsigned-byte 8)))))

(defun %read-all (stream)
  (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (loop for b = (read-byte stream nil nil) while b do (vector-push-extend b out))
    (sb-ext:octets-to-string (coerce out '(simple-array (unsigned-byte 8) (*)))
                             :external-format :latin-1)))

(defparameter +request+
  (format nil "GET / HTTP/1.1~C~CHost: localhost~C~CConnection: close~C~C~C~C"
          #\Return #\Newline #\Return #\Newline #\Return #\Newline #\Return #\Newline))

(defun https-get (port trusted-pem &key (hostname "localhost") alpn)
  "GET / over TLS, trusting the CA certificates in TRUSTED-PEM. Returns (values RESPONSE-TEXT
PEER-CERTIFICATE-DER ALPN-PROTOCOL). Signals the handshake's TLS-ERROR."
  (let ((trusted (tls:make-certificate-chain trusted-pem)))
    (unwind-protect
         (let ((config (tls:make-client-config trusted :alpn alpn)))
           (unwind-protect
                (multiple-value-bind (socket stream) (%connect port)
                  (unwind-protect
                       (ports:with-deadline (+io-timeout+ "an HTTPS GET")
                         (let* ((tls-stream (tls:make-tls-stream stream config :hostname hostname))
                                (engine (tls:tls-stream-engine tls-stream)))
                           (write-sequence (sb-ext:string-to-octets +request+ :external-format :latin-1)
                                           tls-stream)
                           (force-output tls-stream)
                           (let ((peer (tls:engine-peer-certificate-der engine))
                                 (protocol (tls:engine-alpn-protocol engine))
                                 (text (%read-all tls-stream)))
                             (ignore-errors (close tls-stream))
                             (values text peer protocol))))
                    (ignore-errors (sock:socket-close socket))))
             (tls:free-config config)))
      (tls:free-certificate-chain trusted))))

(defun %raw-exchange (port octets)
  "Send OCTETS on a new plain TCP connection and return everything the server sends back until
it closes, as octets."
  (multiple-value-bind (socket stream) (%connect port)
    (unwind-protect
         (ports:with-deadline (+io-timeout+ "a raw exchange")
           (write-sequence octets stream)
           (force-output stream)
           (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
             (handler-case (loop for b = (read-byte stream nil nil) while b do (vector-push-extend b out))
               (stream-error () nil))
             (coerce out '(simple-array (unsigned-byte 8) (*)))))
      (ignore-errors (sock:socket-close socket)))))

(defun %wait-until (predicate &key (seconds +io-timeout+))
  (loop with deadline = (+ (get-internal-real-time) (* seconds internal-time-units-per-second))
        for result = (funcall predicate)
        until (or result (> (get-internal-real-time) deadline))
        do (sleep 0.01)
        finally (return result)))

(defun %report-value (server key)
  (getf (https:server-tls-report server) key))

;;; --- the tests -------------------------------------------------------------------------

(test a-client-that-trusts-the-ca-gets-the-page-over-tls
  (let* ((pki (make-pki))
         (set (https:make-certificate-set :certificate (pki-cert-path pki) :key (pki-key-path pki))))
    (with-https-server (server port set)
      (multiple-value-bind (text peer protocol)
          (https-get port (pki-ca-pem pki) :alpn '("h2" "http/1.1"))
        (is (search "200" text) "the status: ~S" text)
        (is (search "hello over tls" text) "the body: ~S" text)
        (is (equal "http/1.1" protocol) "ALPN chose http/1.1 from h2 and http/1.1: ~S" protocol)
        (is (equalp (%leaf-der (pki-cert-pem pki)) peer) "the client received our certificate"))
      (is (%wait-until (lambda () (= 1 (%report-value server :handshakes))))
          "one handshake completed: ~S" (https:server-tls-report server)))))

(test a-client-that-trusts-another-ca-is-refused-at-verification
  (let* ((pki (make-pki))
         (set (https:make-certificate-set :certificate (pki-cert-path pki) :key (pki-key-path pki))))
    (with-https-server (server port set)
      (let ((e (handler-case (progn (https-get port (pki-other-ca-pem pki)) nil)
                 (tls:tls-error (e) e)
                 (ports:no-response (e) e))))
        (is (typep e 'tls:tls-verify-error)
            "a certificate-verification failure, not a timeout or another error: ~A" e))
      (is (search "200" (https-get port (pki-ca-pem pki)))
          "control: the same server answers a client that trusts its CA"))))

(test a-client-asking-for-another-name-is-refused
  (let* ((pki (make-pki))
         (set (https:make-certificate-set :certificate (pki-cert-path pki) :key (pki-key-path pki))))
    (with-https-server (server port set)
      (is (typep (handler-case (progn (https-get port (pki-ca-pem pki) :hostname "elsewhere.test") nil)
                   (tls:tls-error (e) e))
                 'tls:tls-verify-error)
          "the certificate names localhost, not elsewhere.test"))))

(test plaintext-http-to-the-tls-port-gets-no-http-response
  "The control without which TLS cannot be told apart from plaintext on the same port: an HTTP
request in the clear gets no HTTP response, and the handshake failure is counted."
  (let* ((pki (make-pki))
         (set (https:make-certificate-set :certificate (pki-cert-path pki) :key (pki-key-path pki))))
    (with-https-server (server port set)
      (let* ((reply (%raw-exchange port (sb-ext:string-to-octets +request+ :external-format :latin-1)))
             (text (sb-ext:octets-to-string reply :external-format :latin-1)))
        (is (null (search "HTTP/1.1" text)) "no HTTP response: ~S" text)
        ;; IS-TRUE, not IS: IS evaluates each argument of the form to report it, and (AREF
        ;; REPLY 0) on an empty reply is an error rather than a false.
        (is-true (or (zerop (length reply)) (= #x15 (aref reply 0)))
                 "nothing, or a TLS alert record: ~S" reply))
      (is (%wait-until (lambda () (= 1 (%report-value server :handshake-failures))))
          "the failure is counted: ~S" (https:server-tls-report server)))
    (let ((plain (srv:start #'%app :port 0)))
      (unwind-protect
           (is (search "HTTP/1.1 200"
                       (sb-ext:octets-to-string
                        (%raw-exchange (srv:server-port plain)
                                       (sb-ext:string-to-octets +request+ :external-format :latin-1))
                        :external-format :latin-1))
               "control: the same request to a server without TLS is answered")
        (srv:stop plain)))))

(defun %tls-1.1-client-hello ()
  "A ClientHello offering TLS 1.1 and nothing later, written out by hand as in aion/tls's tests,
because no client we have can offer TLS 1.1."
  (let* ((body (concatenate '(vector (unsigned-byte 8))
                            #(#x03 #x02)
                            (make-array 32 :element-type '(unsigned-byte 8) :initial-element 7)
                            #(#x00)
                            #(#x00 #x02 #xC0 #x09)
                            #(#x01 #x00)))
         (n (length body))
         (handshake (concatenate '(vector (unsigned-byte 8))
                                 (vector 1 0 (ash n -8) (logand n #xff)) body))
         (m (length handshake)))
    (concatenate '(vector (unsigned-byte 8))
                 (vector #x16 #x03 #x01 (ash m -8) (logand m #xff)) handshake)))

(test a-client-offering-only-tls-1.1-is-refused-with-an-alert
  (let* ((pki (make-pki))
         (set (https:make-certificate-set :certificate (pki-cert-path pki) :key (pki-key-path pki))))
    (with-https-server (server port set)
      (let ((reply (%raw-exchange port (%tls-1.1-client-hello))))
        (is-true (and (plusp (length reply)) (= #x15 (aref reply 0)))
                 "the server answers with an alert record: ~S" reply))
      (is (%wait-until (lambda () (= 1 (%report-value server :handshake-failures))))
          "and counts the failure"))))

(test a-client-offering-only-h2-is-refused
  "ALPN accepts http/1.1 only, so a client that offers h2 and nothing else is refused. The
control is the first test, where a client offering h2 and http/1.1 gets http/1.1."
  (let* ((pki (make-pki))
         (set (https:make-certificate-set :certificate (pki-cert-path pki) :key (pki-key-path pki))))
    (with-https-server (server port set)
      (is (typep (handler-case (progn (https-get port (pki-ca-pem pki) :alpn '("h2")) nil)
                   (tls:tls-error (e) e))
                 'tls:tls-error)))))

(test the-report-says-which-certificate-the-server-loaded
  "Provenance (#125's acceptance): the fingerprint of the certificate the client received equals
the one SERVER-TLS-REPORT gives and the SHA-256 of the leaf in the file the test wrote, and the
report names that file."
  (let* ((pki (make-pki))
         (set (https:make-certificate-set :certificate (pki-cert-path pki) :key (pki-key-path pki))))
    (with-https-server (server port set)
      (multiple-value-bind (text peer) (https-get port (pki-ca-pem pki))
        (declare (ignore text))
        (let ((report (https:server-tls-report server)))
          (is (equal (%sha256 peer) (getf report :leaf-sha256)) "received = reported: ~S" report)
          (is (equal (%sha256 (%leaf-der (pki-cert-pem pki))) (getf report :leaf-sha256))
              "reported = the leaf the test wrote")
          (is (equal (%sha256 (pki-cert-pem pki)) (getf report :certificate-sha256))
              "the octets read are the file's")
          (is (equal (uiop:native-namestring (truename (pki-cert-path pki)))
                     (getf report :certificate-source))
              "the source is the file: ~S" (getf report :certificate-source))
          (is (equal (uiop:native-namestring (truename (pki-key-path pki)))
                     (getf report :key-source))))))))

(test a-key-given-as-a-secret-serves-and-is-never-printed
  (let* ((pki (make-pki))
         (key-text (sb-ext:octets-to-string (pki-key-pem pki) :external-format :utf-8))
         (set (https:make-certificate-set :certificate (pki-cert-pem pki)
                                          :key (secret:make-secret key-text))))
    (with-https-server (server port set)
      (is (search "200" (https-get port (pki-ca-pem pki))))
      (let ((report (https:server-tls-report server)))
        (is (equal "secret" (getf report :key-source)))
        (is (equal "octets" (getf report :certificate-source)))
        (is (null (search "PRIVATE KEY" (format nil "~S ~S" set report)))
            "neither the set's printed form nor the report holds the key")))))

(test a-mismatched-or-expired-certificate-set-is-refused-with-its-reason
  (let* ((pki (make-pki))
         (other (make-pki))
         (old (make-pki :not-before (- (get-universal-time) (* 3 86400))
                        :not-after (- (get-universal-time) 86400))))
    (let ((e (handler-case (progn (https:make-certificate-set :certificate (pki-cert-path pki)
                                                              :key (pki-key-path other))
                                  nil)
               (https:certificate-set-error (e) e))))
      (is (and e (search "not the key" (https:certificate-set-error-reason e)))
          "a key from another certificate: ~A" e))
    (let ((e (handler-case (progn (https:make-certificate-set :certificate (pki-cert-path old)
                                                              :key (pki-key-path old))
                                  nil)
               (https:certificate-set-error (e) e))))
      (is (and e (search "expired" (https:certificate-set-error-reason e)))
          "an expired leaf: ~A" e))
    (let ((set (https:make-certificate-set :certificate (pki-cert-path pki) :key (pki-key-path pki))))
      (is (typep set 'https:certificate-set) "control: the matching, current pair is accepted")
      (https:free-certificate-set set))))

(test a-client-that-sends-nothing-is-closed-at-the-handshake-timeout
  "The hub's ruling on #125: a client that connects and sends nothing cannot hold a connection
open. With the handshake timeout at 300 ms, the server closes such a connection in well under
the 5 s keep-alive timeout, and counts it. The control is the same silent client on a server
without TLS, whose connection is still open after a second. The keep-alive timeout is left at
its default, because it is read on the loop thread, where a binding here is not seen."
  (let* ((pki (make-pki))
         (set (https:make-certificate-set :certificate (pki-cert-path pki) :key (pki-key-path pki)))
         (https:*handshake-timeout-ms* 300))
    (is (= 5000 srv:*keep-alive-timeout-ms*) "the keep-alive timeout this test is measured against")
    (with-https-server (server port set)
      (multiple-value-bind (socket stream) (%connect port)
        (unwind-protect
             (let ((start (get-internal-real-time)))
               (is (null (ports:with-deadline (5 "a silent TLS client")
                           (handler-case (read-byte stream nil nil) (stream-error () nil))))
                   "the server closed the connection")
               (is (< (/ (- (get-internal-real-time) start) internal-time-units-per-second) 4)
                   "within the handshake timeout, not the keep-alive timeout"))
          (ignore-errors (sock:socket-close socket))))
      (is (%wait-until (lambda () (= 1 (%report-value server :handshake-timeouts))))
          "the timeout is counted: ~S" (https:server-tls-report server))
      (is (%wait-until (lambda () (zerop (%report-value server :live-connections))))
          "and its engine freed"))
    (let ((plain (srv:start #'%app :port 0)))
      (unwind-protect
           (multiple-value-bind (socket stream) (%connect (srv:server-port plain))
             (unwind-protect
                  (is (typep (handler-case (ports:with-deadline (1 "a silent plain client")
                                             (read-byte stream nil nil))
                               (ports:no-response (e) e))
                             'ports:no-response)
                      "control: without TLS the silent connection is still open after a second")
               (ignore-errors (sock:socket-close socket))))
        (srv:stop plain)))))

(test every-engine-is-freed-when-its-connection-ends
  (let* ((pki (make-pki))
         (set (https:make-certificate-set :certificate (pki-cert-path pki) :key (pki-key-path pki))))
    (with-https-server (server port set)
      (dotimes (i 5) (https-get port (pki-ca-pem pki)))
      (ignore-errors (https-get port (pki-other-ca-pem pki)))
      (is (%wait-until (lambda () (zerop (%report-value server :live-connections))))
          "no engine is left after six connections end: ~S" (https:server-tls-report server))
      (is (= 5 (%report-value server :handshakes)))
      (is (= 1 (%report-value server :handshake-failures))))))

(test a-failed-handshake-is-logged-without-certificate-or-key-material
  (let* ((pki (make-pki))
         (set (https:make-certificate-set :certificate (pki-cert-path pki) :key (pki-key-path pki)))
         (out (make-string-output-stream)))
    (unwind-protect
         (progn
           (aion/log:setup :env :prod :level :info :stream out)
           (with-https-server (server port set)
             (%raw-exchange port (%tls-1.1-client-hello))
             (%wait-until (lambda () (= 1 (%report-value server :handshake-failures))))))
      (aion/log:setup :env :dev :level :warn :stream *standard-output*))
    (let ((text (get-output-stream-string out)))
      (is (search "handshake failed" text) "the failure is logged: ~A" text)
      (is (search "\"failures\":1" text) "with its count: ~A" text)
      (is (search "127.0.0.1" text) "and the remote address: ~A" text)
      (is (null (search "BEGIN" text)) "no PEM: ~A" text)
      (is (null (search (subseq (%sha256 (%leaf-der (pki-cert-pem pki))) 0 16) text))
          "and nothing from the certificate"))))

;;; --- a client that is not mbedTLS ------------------------------------------------------

(defun %curl ()
  (let ((exe (if (uiop:os-windows-p) "curl.exe" "curl")))
    (and (ignore-errors (zerop (nth-value 2 (uiop:run-program (list exe "--version")
                                                               :ignore-error-status t))))
         exe)))

(test curl-completes-a-request-with-the-test-ca
  "Every other check here has mbedTLS on both ends, and a producer checking its own output
cannot find a disagreement with a different consumer. curl, given the test CA with --cacert,
gets the page; given the other CA, it is refused."
  (let ((curl (%curl)))
    (if (null curl)
        (skip "curl is not on this machine, so no client but mbedTLS was tried")
        (let* ((pki (make-pki))
               (set (https:make-certificate-set :certificate (pki-cert-path pki) :key (pki-key-path pki)))
               (ca (%write-octets (merge-pathnames "ca.pem" (pki-dir pki)) (pki-ca-pem pki)))
               (other (%write-octets (merge-pathnames "other.pem" (pki-dir pki)) (pki-other-ca-pem pki))))
          (with-https-server (server port set)
            (flet ((curl (cafile)
                     (multiple-value-bind (out err code)
                         ;; Windows' curl uses Schannel, which by default also asks whether
                         ;; the certificate was revoked, and a test CA publishes no revocation
                         ;; list, so the answer is "unknown" and curl refuses (exit 60, measured
                         ;; here). --ssl-no-revoke skips only that question; the chain is still
                         ;; verified against --cacert.
                         (uiop:run-program (append (list curl "-sS" "--max-time" "10"
                                                         "--cacert" (uiop:native-namestring cafile))
                                                   (when (uiop:os-windows-p) (list "--ssl-no-revoke"))
                                                   (list (format nil "https://localhost:~D/" port)))
                                           :output :string :error-output :string
                                           :ignore-error-status t)
                       (values out err code))))
              (multiple-value-bind (out err code) (curl ca)
                (is (and (eql 0 code) (search "hello over tls" out))
                    "curl with the test CA: exit ~A, ~S, ~S" code out err))
              (multiple-value-bind (out err code) (curl other)
                (is (not (eql 0 code))
                    "control: curl with the other CA is refused: exit ~A, ~S, ~S" code out err))))))))
