;;;; config.lisp --- server and client configurations: protocol range, cipher suites, and the
;;;; certificates and keys they present and trust.
;;;;
;;;; THE PROTOCOL RANGE IS TLS 1.2 TO TLS 1.3 (the maintainer's decision C on #125). mbedTLS 4.x
;;;; has no TLS 1.1 or older at all, so the floor is also the library's; it is set here anyway,
;;;; so the range is stated where it is enforced rather than inherited.
;;;;
;;;; THE CIPHER SUITES ARE A FIXED LIST, NOT mbedTLS'S DEFAULT. mbedTLS 4.1.1 enables 67 suites
;;;; by default (mbedtls_ssl_list_ciphersuites, on this tree's build): 5 for TLS 1.3 and 62 for
;;;; TLS 1.2. Of the 62, 32 use CBC, 19 are pre-shared-key suites without ECDHE, and 4 use CCM-8's
;;;; 64-bit tag. Decision C limits TLS 1.2 to forward-secret AEAD suites, so *CIPHERSUITES* keeps
;;;; the six ECDHE suites with AES-GCM or ChaCha20-Poly1305. For TLS 1.3 it keeps the three
;;;; suites RFC 8446 section 9.1 recommends and leaves out TLS_AES_128_CCM_SHA256 and
;;;; TLS_AES_128_CCM_8_SHA256, which IANA marks not recommended for general use.

(in-package #:aion/tls)

(defparameter *ciphersuites*
  '("TLS1-3-AES-256-GCM-SHA384"
    "TLS1-3-CHACHA20-POLY1305-SHA256"
    "TLS1-3-AES-128-GCM-SHA256"
    "TLS-ECDHE-ECDSA-WITH-AES-256-GCM-SHA384"
    "TLS-ECDHE-RSA-WITH-AES-256-GCM-SHA384"
    "TLS-ECDHE-ECDSA-WITH-CHACHA20-POLY1305-SHA256"
    "TLS-ECDHE-RSA-WITH-CHACHA20-POLY1305-SHA256"
    "TLS-ECDHE-ECDSA-WITH-AES-128-GCM-SHA256"
    "TLS-ECDHE-RSA-WITH-AES-128-GCM-SHA256")
  "The cipher suites every config offers, in preference order, by mbedTLS's names. See the
file header for how they were chosen from mbedTLS 4.1.1's 67 defaults.")

(defun ciphersuite-name (id)
  "mbedTLS's name for the cipher suite with IANA number ID."
  (ensure-loaded)
  (%ssl-get-ciphersuite-name id))

(defun %ciphersuite-array (names)
  "A foreign, zero-terminated int array of the IDs of NAMES, which mbedTLS keeps a pointer
to for as long as the config lives. Signals if a name is unknown to this build: a suite
that silently vanished from the list would change what we offer without saying so."
  (let* ((ids (mapcar (lambda (name)
                        (let ((id (%ssl-get-ciphersuite-id name)))
                          (when (zerop id)
                            (error "aion/tls: this mbedTLS build has no cipher suite named ~A" name))
                          id))
                      names))
         (array (cffi:foreign-alloc :int :count (1+ (length ids)))))
    (loop for id in ids for i from 0 do (setf (cffi:mem-aref array :int i) id))
    (setf (cffi:mem-aref array :int (length ids)) 0)
    array))

(defclass config ()
  ((pointer :initarg :pointer :accessor %pointer)
   (suites :initarg :suites :accessor %suites)
   (endpoint :initarg :endpoint :reader config-endpoint)
   (ciphersuites :initarg :ciphersuites :reader config-ciphersuites)
   ;; Kept reachable, because the mbedtls_ssl_config holds pointers into them.
   (holds :initarg :holds :reader %holds))
  (:documentation "An mbedtls_ssl_config, owned by this object, for :SERVER or :CLIENT use.
It holds references to the certificate chains and key it was made with, which must not be
freed while it is in use."))

(defun %make-config (endpoint holds)
  (ensure-loaded)
  (let ((p (%config-new)))
    (when (cffi:null-pointer-p p) (error "aion/tls: out of memory allocating a config"))
    (let ((config (make-instance 'config :pointer p :suites nil :endpoint endpoint
                                         :ciphersuites *ciphersuites* :holds holds)))
      (handler-bind ((error (lambda (e) (declare (ignore e)) (free-config config))))
        (%check (%ssl-config-defaults p (if (eq endpoint :server) +is-server+ +is-client+)
                                      +transport-stream+ +preset-default+)
                "mbedtls_ssl_config_defaults")
        (%conf-version-range p +tls-1.2+ +tls-1.3+)
        (setf (%suites config) (%ciphersuite-array *ciphersuites*))
        (%ssl-conf-ciphersuites p (%suites config)))
      config)))

(defun make-server-config (chain key)
  "A server config presenting CHAIN, whose first certificate must be KEY's. Refuses a key that
does not match the certificate, before anything is served with it."
  (unless (certificate-chain-matches-key-p chain key)
    (error "aion/tls: the private key is not the key of the certificate it was given with"))
  (let ((config (%make-config :server (list chain key))))
    (%ssl-conf-authmode (%pointer config) +verify-none+)
    (%check (%ssl-conf-own-cert (%pointer config) (%pointer chain) (%pointer key))
            "mbedtls_ssl_conf_own_cert")
    config))

(defun make-client-config (trusted)
  "A client config that trusts the CA certificates in the CERTIFICATE-CHAIN TRUSTED and
requires the server's certificate to verify against them. There is no option to skip
verification: a client that does not check who it is talking to is not using TLS for the
reason TLS exists."
  (let ((config (%make-config :client (list trusted))))
    (%ssl-conf-authmode (%pointer config) +verify-required+)
    (%ssl-conf-ca-chain (%pointer config) (%pointer trusted) (cffi:null-pointer))
    config))

(defun free-config (config)
  (let ((p (%pointer config)) (suites (%suites config)))
    (when p
      (setf (%pointer config) nil)
      (%config-free p))
    (when suites
      (setf (%suites config) nil)
      (cffi:foreign-free suites)))
  (values))
