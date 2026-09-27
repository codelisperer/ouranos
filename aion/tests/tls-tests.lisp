;;;; tls-tests.lisp --- aion/tls: the loader, keys and certificates, configs, the engine and
;;;; the blocking stream (#125, step 2).
;;;;
;;;; NO OPENSSL, AND NO CERTIFICATE IN THE TREE. Every key and certificate here is made by the
;;;; mbedTLS under test, in memory, for this run, so nothing expires in the tree and no private
;;;; key is committed.
;;;;
;;;; BOTH DIRECTIONS OF EVERY CONTROL. A handshake that succeeds proves little by itself; each
;;;; success here has a refusal beside it that differs in one thing: a client trusting the
;;;; wrong CA, a client asking for the wrong name, a key that is not the certificate's, a TLS
;;;; 1.2 client offering only a CBC suite, and a client offering only TLS 1.1. The TLS 1.1 client
;;;; is not mbedTLS at all: its ClientHello is written out octet by octet below, because
;;;; mbedTLS 4.x cannot speak TLS 1.1 and so could not be the client for that test.

(cl:defpackage #:aion/tls/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:tls #:aion/tls)
                    (#:sock #:sb-bsd-sockets))
  (:export #:run-tests))

(in-package #:aion/tls/tests)

(def-suite tls :description "aion/tls over the mbedTLS this tree builds.")
(in-suite tls)

(defun run-tests () (run! 'tls))

;;; --- a CA and a server certificate, made once per run ------------------------------------

(defvar *pki* nil)

(defun pki ()
  "A plist: :ca-key :ca-pem, :other-ca-pem (a CA that signed nothing we serve), :key and
:cert-pem for a server named localhost and 127.0.0.1, signed by the first CA."
  (or *pki*
      (setf *pki*
            (let* ((ca-key (tls:generate-private-key))
                   (ca-pem (tls:issue-certificate :subject "CN=aion/tls test CA" :subject-key ca-key :ca t))
                   (other-key (tls:generate-private-key))
                   (other-pem (tls:issue-certificate :subject "CN=aion/tls other CA" :subject-key other-key :ca t))
                   (key (tls:generate-private-key))
                   (cert-pem (tls:issue-certificate :subject "CN=localhost" :subject-key key
                                                    :issuer "CN=aion/tls test CA" :issuer-key ca-key
                                                    :dns-name "localhost" :ipv4 #(127 0 0 1))))
              (list :ca-key ca-key :ca-pem ca-pem :other-ca-pem other-pem :key key :cert-pem cert-pem)))))

(defun server-config ()
  (tls:make-server-config (tls:make-certificate-chain (getf (pki) :cert-pem)) (getf (pki) :key)))

(defun client-config (&key (ca :ca-pem))
  (tls:make-client-config (tls:make-certificate-chain (getf (pki) ca))))

(defun move (from to)
  (let ((octets (tls:engine-take-output from)))
    (when (plusp (length octets)) (tls:engine-feed to octets))))

(defun handshake (client server)
  "Run CLIENT's and SERVER's handshakes against each other until both are done. Returns T,
or signals whichever side's failure comes first."
  (loop repeat 50
        do (let ((c (tls:engine-handshake client)))
             (move client server)
             (let ((s (tls:engine-handshake server)))
               (move server client)
               (when (and (eq c :done) (eq s :done)) (return-from handshake t)))))
  (error "the handshake did not finish in 50 rounds"))

(defmacro with-engines ((client server &key (client-config '(client-config))
                                            (hostname "localhost"))
                        &body body)
  `(let* ((,client (tls:make-engine ,client-config :hostname ,hostname))
          (,server (tls:make-engine (server-config))))
     (unwind-protect (progn ,@body)
       (tls:free-engine ,client)
       (tls:free-engine ,server))))

(defun octets (string) (sb-ext:string-to-octets string :external-format :utf-8))
(defun text (octets) (sb-ext:octets-to-string octets :external-format :utf-8))

;;; --- the library --------------------------------------------------------------------

(test the-library-is-our-build
  (tls:ensure-loaded)
  (let ((path (tls:mbedtls-path)))
    ;; Provenance, not presence: which file loaded, so a system mbedTLS found first cannot pass.
    (is (search "vendor/mbedtls/lib/" (substitute #\/ #\\ path))
        "loaded ~A, not the tree's own build" path))
  (is (= tls:+shim-version+ (aion/tls::%shim-version)))
  (is (plusp (aion/tls::%threading-kind)) "a library with threading off must not be accepted"))

(defun libuv-path ()
  (probe-file (merge-pathnames
               #+darwin "vendor/libuv/lib/libuv.1.dylib"
               #+windows "vendor/libuv/lib/libuv.dll"
               #-(or darwin windows) "vendor/libuv/lib/libuv.so.1"
               (uiop:pathname-parent-directory-pathname (asdf:system-source-directory :aion)))))

(test a-library-without-our-c-is-refused
  ;; libuv loads as a shared library and has none of our C, so it stands in for a system
  ;; mbedTLS. It is loaded beside ours and asked about directly: the loader never reloads the
  ;; library in use, because every key and config points into it (see LOAD-MBEDTLS).
  (let ((libuv (libuv-path)))
    (if (null libuv)
        (skip "no built libuv to stand in for a foreign library")
        (let ((path (uiop:native-namestring libuv)))
          (cffi:load-foreign-library path)
          (let ((reason (aion/tls::%build-mismatch path)))
            (is (and reason (search "ouranos_tls_shim_version" reason))
                "a library without our C is refused, and the refusal says why: ~S" reason))
          (is (null (aion/tls::%build-mismatch (tls:mbedtls-path)))
              "and our own library is not")))))

(test a-candidate-whose-check-signals-leaves-nothing-loaded
  ;; The half of #282's Windows failure that moved it far from its cause. The library check
  ;; signalled (a TYPE-ERROR on Windows), but the loader had already recorded the library, so
  ;; every later caller got a library nobody had initialised and failed on another thread
  ;; with PSA_ERROR_SERVICE_FAILURE. Here the check is made to signal for a candidate, libuv,
  ;; so our own library, already loaded for the other tests, is never touched.
  (let ((libuv (libuv-path)))
    (if (null libuv)
        (skip "no built libuv to stand in for a candidate")
        (let ((saved-env (uiop:getenv "AION_TLS_LIBRARY"))
              (real-check (fdefinition 'aion/tls::%build-mismatch)))
          (unwind-protect
               (let ((aion/tls::*library* nil)
                     (aion/tls::*path* nil))
                 (setf (uiop:getenv "AION_TLS_LIBRARY") (uiop:native-namestring libuv))
                 (setf (fdefinition 'aion/tls::%build-mismatch)
                       (lambda (path) (declare (ignore path)) (error "the check itself failed")))
                 (is (typep (handler-case (progn (tls:load-mbedtls) nil) (error (e) e)) 'error)
                     "a check that signals makes the load signal")
                 (is (and (null (tls:mbedtls-loaded-p)) (null (tls:mbedtls-path)))
                     "and leaves no library recorded as loaded")
                 (setf (fdefinition 'aion/tls::%build-mismatch) real-check)
                 (is (typep (handler-case (progn (tls:load-mbedtls) nil) (error (e) e))
                            'tls:mbedtls-mismatch)
                     "the next load refuses the same candidate with a clear error")
                 (is (null (tls:mbedtls-loaded-p))
                     "and still records nothing, rather than handing out an uninitialised library"))
            (setf (fdefinition 'aion/tls::%build-mismatch) real-check)
            (setf (uiop:getenv "AION_TLS_LIBRARY") (or saved-env "")))
          (is (search "vendor/mbedtls/lib/" (substitute #\/ #\\ (tls:mbedtls-path)))
              "and the library the other tests use is still the one loaded")))))

(test loading-again-keeps-the-library-in-use
  (let ((before (tls:mbedtls-path)))
    (is (equal before (tls:load-mbedtls)))
    (let ((key (tls:generate-private-key)))
      (is-true key "keys can still be made after a second load")
      (tls:free-private-key key))))

(test a-psa-status-is-reported-by-name
  ;; mbedtls_strerror does not know PSA's statuses and printed -144 as two unknown codes.
  (is (string= "PSA_ERROR_SERVICE_FAILURE" (aion/tls::%strerror -144)))
  (is (search "SSL" (aion/tls::%strerror (- #x7880))) "an mbedTLS code still gets mbedTLS's text"))

;;; --- keys and certificates -------------------------------------------------------------

(test a-certificate-matches-its-own-key-and-no-other
  (let ((chain (tls:make-certificate-chain (getf (pki) :cert-pem))))
    (unwind-protect
         (progn
           (is-true (tls:certificate-chain-matches-key-p chain (getf (pki) :key)))
           (is-false (tls:certificate-chain-matches-key-p chain (getf (pki) :ca-key))
                     "the CA's key is not the server certificate's key"))
      (tls:free-certificate-chain chain))))

(test a-key-survives-a-pem-round-trip
  (let* ((pem (tls:private-key-pem (getf (pki) :key)))
         (back (tls:make-private-key pem))
         (chain (tls:make-certificate-chain (getf (pki) :cert-pem))))
    (unwind-protect
         (progn
           (is (search "-----BEGIN" (text pem)))
           (is-true (tls:certificate-chain-matches-key-p chain back)))
      (tls:free-private-key back)
      (tls:free-certificate-chain chain))))

(test a-server-config-refuses-a-key-that-is-not-the-certificates
  (let ((chain (tls:make-certificate-chain (getf (pki) :cert-pem))))
    (unwind-protect
         (signals error (tls:make-server-config chain (getf (pki) :ca-key)))
      (tls:free-certificate-chain chain))))

(test garbage-is-not-a-certificate
  (signals tls:tls-error (tls:make-certificate-chain (octets "not a certificate at all"))))

;;; --- the engine -------------------------------------------------------------------------

(test a-client-that-trusts-the-ca-completes-a-handshake-and-exchanges-data
  (with-engines (client server)
    (is-true (handshake client server))
    (is (= tls:+tls-1.3+ (tls:engine-version client)) "TLS 1.3 when both sides offer it")
    (is (member (tls:engine-ciphersuite client) tls:*ciphersuites* :test #'string=)
        "negotiated ~A, which is not on the list" (tls:engine-ciphersuite client))
    (tls:engine-write client (octets "hello from the client"))
    (move client server)
    (is (string= "hello from the client" (text (tls:engine-read server))))
    (tls:engine-write server (octets "and back"))
    (move server client)
    (is (string= "and back" (text (tls:engine-read client))))))

(test the-client-sees-exactly-the-certificate-the-server-was-given
  ;; Provenance: which certificate arrived, not that a handshake succeeded.
  (with-engines (client server)
    (handshake client server)
    (let ((chain (tls:make-certificate-chain (getf (pki) :cert-pem))))
      (unwind-protect
           (is (equalp (tls:certificate-chain-der chain) (tls:engine-peer-certificate-der client)))
        (tls:free-certificate-chain chain)))))

(test a-client-that-trusts-another-ca-is-refused
  (with-engines (client server :client-config (client-config :ca :other-ca-pem))
    (let ((e (handler-case (progn (handshake client server) nil)
               (tls:tls-error (e) e))))
      (is (typep e 'tls:tls-verify-error) "a certificate-verification failure, got ~A" e)
      (is (and (typep e 'tls:tls-verify-error) (plusp (tls:tls-verify-error-flags e)))))))

(test a-client-asking-for-another-name-is-refused
  (with-engines (client server :hostname "not-localhost.example")
    (is (typep (handler-case (progn (handshake client server) nil) (tls:tls-error (e) e))
               'tls:tls-verify-error))))

(test a-client-engine-without-a-hostname-is-refused
  (let ((config (client-config)))
    (signals error (tls:make-engine config))))

(test close-notify-reaches-the-peer-as-end-of-file
  (with-engines (client server)
    (handshake client server)
    (tls:engine-close-notify client)
    (move client server)
    (is (eq :eof (tls:engine-read server)))))

(test a-record-split-across-feeds-is-read-whole
  (with-engines (client server)
    (handshake client server)
    (tls:engine-write client (octets "split record"))
    (let ((wire (tls:engine-take-output client)))
      (tls:engine-feed server wire :end 5)
      (is (zerop (length (tls:engine-read server))) "nothing is readable from part of a record")
      (tls:engine-feed server wire :start 5)
      (is (string= "split record" (text (tls:engine-read server)))))))

;;; --- the protocol range and the cipher suites (decision C on #125) --------------------------

(defun tls-1.2-client-config ()
  "A client config limited to TLS 1.2. Set before any engine is made from it:
mbedtls_ssl_setup takes the version range from the config when the engine is made, so a
range set afterwards has no effect."
  (let ((config (client-config)))
    (aion/tls::%conf-version-range (aion/tls::%pointer config) tls:+tls-1.2+ tls:+tls-1.2+)
    config))

(test a-tls-1.2-client-gets-an-ecdhe-aead-suite
  (with-engines (client server :client-config (tls-1.2-client-config))
    (handshake client server)
    (is (= tls:+tls-1.2+ (tls:engine-version server)))
    (let ((suite (tls:engine-ciphersuite server)))
      (is (and (search "ECDHE" suite)
               (or (search "GCM" suite) (search "CHACHA20-POLY1305" suite)))
          "TLS 1.2 negotiated ~A" suite))))

(test a-tls-1.2-client-offering-only-cbc-is-refused
  ;; mbedTLS 4.1.1 enables 32 CBC suites for TLS 1.2 by default; ours offers none. The control
  ;; is the test above, the same client with the default list.
  (let* ((config (client-config))
         (p (aion/tls::%pointer config)))
    (aion/tls::%conf-version-range p tls:+tls-1.2+ tls:+tls-1.2+)
    (let ((suites (aion/tls::%ciphersuite-array '("TLS-ECDHE-ECDSA-WITH-AES-128-CBC-SHA256"))))
      (unwind-protect
           (progn
             (aion/tls::%ssl-conf-ciphersuites p suites)
             (with-engines (client server :client-config config)
               (signals tls:tls-error (handshake client server))))
        ;; The config still points at SUITES, so it is freed first.
        (tls:free-config config)
        (cffi:foreign-free suites)))))

(defun tls-1.1-client-hello ()
  "A ClientHello offering TLS 1.1 and nothing later: legacy version 0x0302, no
supported_versions extension, one TLS 1.1 cipher suite. Written out by hand, from RFC 4346
section 7.4.1.2, because no client we have can offer TLS 1.1."
  (let* ((body (concatenate '(vector (unsigned-byte 8))
                            #(#x03 #x02)                              ; client_version: TLS 1.1
                            (make-array 32 :element-type '(unsigned-byte 8) :initial-element 7) ; random
                            #(#x00)                                   ; session_id: empty
                            #(#x00 #x02 #xC0 #x09)                    ; one suite: ECDHE-ECDSA-AES128-CBC-SHA
                            #(#x01 #x00)))                            ; compression: null
         (n (length body))
         (handshake (concatenate '(vector (unsigned-byte 8))
                                 (vector 1 0 (ash n -8) (logand n #xff)) body))
         (m (length handshake)))
    (concatenate '(vector (unsigned-byte 8))
                 (vector #x16 #x03 #x01 (ash m -8) (logand m #xff)) handshake)))

(test a-client-offering-only-tls-1.1-is-refused
  (let ((server (tls:make-engine (server-config))))
    (unwind-protect
         (progn
           (tls:engine-feed server (tls-1.1-client-hello))
           (signals tls:tls-error (tls:engine-handshake server))
           (let ((out (tls:engine-take-output server)))
             (is (and (plusp (length out)) (= #x15 (aref out 0)))
                 "and the client is sent an alert record, got ~S" out)))
      (tls:free-engine server))))

(test a-well-formed-tls-1.2-hello-from-the-same-writer-is-not-refused-for-its-form
  ;; The control for the test above: the same hand-written hello with the version changed to
  ;; TLS 1.2 and an ECDHE-GCM suite gets past the version check, so the refusal above is about
  ;; the version and not about the hand-written octets. (It still fails later, because it
  ;; offers no curves or signature algorithms, which is not what this checks.)
  (let ((hello (tls-1.1-client-hello))
        (server (tls:make-engine (server-config))))
    (setf (aref hello 10) #x03)                       ; client_version: TLS 1.2
    (setf (aref hello 46) #xC0 (aref hello 47) #x2B)  ; ECDHE-ECDSA-AES128-GCM-SHA256
    (unwind-protect
         (let ((e (handler-case (progn (tls:engine-feed server hello) (tls:engine-handshake server) nil)
                    (tls:tls-error (e) e))))
           (is (or (null e) (/= (tls:tls-error-code e) aion/tls::+err-bad-protocol-version+))
               "refused for its version, which was not the change: ~A" e))
      (tls:free-engine server))))

;;; --- the blocking stream, over real TCP ------------------------------------------------

(test a-tls-stream-carries-data-both-ways-over-tcp
  (let* ((listener (make-instance 'sock:inet-socket :type :stream :protocol :tcp))
         (server-result nil))
    (setf (sock:sockopt-reuse-address listener) t)
    (sock:socket-bind listener #(127 0 0 1) 0)
    (sock:socket-listen listener 1)
    (let* ((port (nth-value 1 (sock:socket-name listener)))
           (thread (sb-thread:make-thread
                    (lambda ()
                      (let* ((conn (sock:socket-accept listener))
                             (raw (sock:socket-make-stream conn :input t :output t
                                                                :element-type '(unsigned-byte 8)))
                             (s (tls:make-tls-stream raw (server-config))))
                        (let ((buf (make-array 5 :element-type '(unsigned-byte 8))))
                          (read-sequence buf s)
                          (setf server-result (text buf))
                          (write-sequence (octets "world") s)
                          (force-output s)
                          (close s))))
                    :name "tls-stream test server")))
      (unwind-protect
           (let* ((conn (make-instance 'sock:inet-socket :type :stream :protocol :tcp)))
             (sock:socket-connect conn #(127 0 0 1) port)
             (let* ((raw (sock:socket-make-stream conn :input t :output t
                                                       :element-type '(unsigned-byte 8)))
                    (s (tls:make-tls-stream raw (client-config) :hostname "localhost")))
               (write-sequence (octets "hello") s)
               (force-output s)
               (let ((buf (make-array 5 :element-type '(unsigned-byte 8))))
                 (read-sequence buf s)
                 (is (string= "world" (text buf))))
               (is (eq :eof (read-byte s nil :eof)) "the server's close_notify ends the stream")
               (close s)))
        (sb-thread:join-thread thread :timeout 10 :default nil)
        (sock:socket-close listener))
      (is (equal "hello" server-result)))))

;;; --- nothing is left behind --------------------------------------------------------------

(test freed-engines-leave-nothing-in-the-registry
  (let ((before (hash-table-count aion/tls::*engines*)))
    (dotimes (i 20)
      (with-engines (client server) (handshake client server)))
    (is (= before (hash-table-count aion/tls::*engines*)))))
