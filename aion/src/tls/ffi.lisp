;;;; ffi.lisp --- the raw binding: one Lisp function per C function aion/tls calls.
;;;;
;;;; Nothing is interpreted here. Return codes come back as the negative integers mbedTLS
;;;; produced, and contexts as foreign pointers. Contexts are made and freed only through the
;;;; ouranos_tls_*_new and _free functions in aion/src/tls/c/ouranos_tls.c, because mbedTLS
;;;; exports no struct sizes (#125). Constants are copied from the mbedTLS 4.1.1 headers, with
;;;; the header named at each.

(in-package #:aion/tls)

;;; --- constants ---------------------------------------------------------------------

;;; include/mbedtls/ssl.h
(defconstant +is-client+ 0)
(defconstant +is-server+ 1)
(defconstant +transport-stream+ 0)
(defconstant +preset-default+ 0)
(defconstant +verify-none+ 0)
(defconstant +verify-required+ 2)
(defconstant +err-want-read+ (- #x6900))
(defconstant +err-want-write+ (- #x6880))
(defconstant +err-peer-close-notify+ (- #x7880))
(defconstant +err-received-new-session-ticket+ (- #x7B00))
(defconstant +err-conn-eof+ (- #x7280))
(defconstant +err-bad-protocol-version+ (- #x6E80))
;;; mbedtls_ssl_protocol_version
(defconstant +tls-1.2+ #x0303 "TLS 1.2, as mbedTLS encodes a protocol version.")
(defconstant +tls-1.3+ #x0304 "TLS 1.3, as mbedTLS encodes a protocol version.")

;;; include/mbedtls/x509.h and x509_crt.h
(defconstant +err-x509-cert-verify-failed+ (- #x2700))
(defconstant +x509-crt-version-3+ 2)
(defconstant +ku-digital-signature+ #x80)
(defconstant +ku-key-cert-sign+ #x04)

;;; tf-psa-crypto/include/mbedtls/md.h
(defconstant +md-sha256+ #x09)

;;; --- ours (aion/src/tls/c/ouranos_tls.c) -----------------------------------------------

(cffi:defcfun ("ouranos_tls_shim_version" %shim-version) :int)
(cffi:defcfun ("ouranos_tls_threading_kind" %threading-kind) :int)
(cffi:defcfun ("ouranos_tls_setup" %setup) :int)

(cffi:defcfun ("ouranos_tls_ssl_new" %ssl-new) :pointer)
(cffi:defcfun ("ouranos_tls_ssl_free" %ssl-free) :void (p :pointer))
(cffi:defcfun ("ouranos_tls_config_new" %config-new) :pointer)
(cffi:defcfun ("ouranos_tls_config_free" %config-free) :void (p :pointer))
(cffi:defcfun ("ouranos_tls_crt_new" %crt-new) :pointer)
(cffi:defcfun ("ouranos_tls_crt_free" %crt-free) :void (p :pointer))
(cffi:defcfun ("ouranos_tls_pk_new" %pk-new) :pointer)
(cffi:defcfun ("ouranos_tls_pk_free" %pk-free) :void (p :pointer))
(cffi:defcfun ("ouranos_tls_x509write_new" %x509write-new) :pointer)
(cffi:defcfun ("ouranos_tls_x509write_free" %x509write-free) :void (p :pointer))

(cffi:defcfun ("ouranos_tls_conf_version_range" %conf-version-range) :void
  (conf :pointer) (min :int) (max :int))
(cffi:defcfun ("ouranos_tls_version_number" %version-number) :int (ssl :pointer))
(cffi:defcfun ("ouranos_tls_handshake_over" %handshake-over) :int (ssl :pointer))
(cffi:defcfun ("ouranos_tls_crt_der" %crt-der) :pointer (crt :pointer) (len :pointer))
(cffi:defcfun ("ouranos_tls_crt_check_key" %crt-check-key) :int (crt :pointer) (key :pointer))
(cffi:defcfun ("ouranos_tls_pk_generate_ec_p256" %pk-generate-ec-p256) :int (pk :pointer))
(cffi:defcfun ("ouranos_tls_x509write_set_san" %x509write-set-san) :int
  (ctx :pointer) (dns-name :pointer) (ipv4 :pointer))

;;; --- mbedTLS and PSA ---------------------------------------------------------------------

(cffi:defcfun ("psa_crypto_init" %psa-crypto-init) :int)
(cffi:defcfun ("mbedtls_strerror" %mbedtls-strerror) :void (err :int) (buf :pointer) (len :size))

(cffi:defcfun ("mbedtls_ssl_config_defaults" %ssl-config-defaults) :int
  (conf :pointer) (endpoint :int) (transport :int) (preset :int))
(cffi:defcfun ("mbedtls_ssl_conf_authmode" %ssl-conf-authmode) :void (conf :pointer) (mode :int))
(cffi:defcfun ("mbedtls_ssl_conf_ca_chain" %ssl-conf-ca-chain) :void
  (conf :pointer) (ca :pointer) (crl :pointer))
(cffi:defcfun ("mbedtls_ssl_conf_own_cert" %ssl-conf-own-cert) :int
  (conf :pointer) (crt :pointer) (key :pointer))
(cffi:defcfun ("mbedtls_ssl_conf_ciphersuites" %ssl-conf-ciphersuites) :void
  (conf :pointer) (list :pointer))
(cffi:defcfun ("mbedtls_ssl_get_ciphersuite_id" %ssl-get-ciphersuite-id) :int (name :string))
(cffi:defcfun ("mbedtls_ssl_get_ciphersuite_name" %ssl-get-ciphersuite-name) :string (id :int))
(cffi:defcfun ("mbedtls_ssl_list_ciphersuites" %ssl-list-ciphersuites) :pointer)

(cffi:defcfun ("mbedtls_ssl_setup" %ssl-setup) :int (ssl :pointer) (conf :pointer))
(cffi:defcfun ("mbedtls_ssl_set_hostname" %ssl-set-hostname) :int (ssl :pointer) (name :string))
(cffi:defcfun ("mbedtls_ssl_set_bio" %ssl-set-bio) :void
  (ssl :pointer) (ctx :pointer) (send :pointer) (recv :pointer) (recv-timeout :pointer))
(cffi:defcfun ("mbedtls_ssl_handshake" %ssl-handshake) :int (ssl :pointer))
(cffi:defcfun ("mbedtls_ssl_read" %ssl-read) :int (ssl :pointer) (buf :pointer) (len :size))
(cffi:defcfun ("mbedtls_ssl_write" %ssl-write) :int (ssl :pointer) (buf :pointer) (len :size))
(cffi:defcfun ("mbedtls_ssl_close_notify" %ssl-close-notify) :int (ssl :pointer))
(cffi:defcfun ("mbedtls_ssl_get_verify_result" %ssl-get-verify-result) :uint32 (ssl :pointer))
(cffi:defcfun ("mbedtls_ssl_get_peer_cert" %ssl-get-peer-cert) :pointer (ssl :pointer))
(cffi:defcfun ("mbedtls_ssl_get_ciphersuite" %ssl-get-ciphersuite) :string (ssl :pointer))

(cffi:defcfun ("mbedtls_x509_crt_parse" %x509-crt-parse) :int
  (crt :pointer) (buf :pointer) (len :size))
(cffi:defcfun ("mbedtls_x509_crt_verify_info" %x509-crt-verify-info) :int
  (buf :pointer) (size :size) (prefix :string) (flags :uint32))
(cffi:defcfun ("mbedtls_pk_parse_key" %pk-parse-key) :int
  (pk :pointer) (key :pointer) (keylen :size) (pwd :pointer) (pwdlen :size))
(cffi:defcfun ("mbedtls_pk_write_key_pem" %pk-write-key-pem) :int
  (pk :pointer) (buf :pointer) (size :size))

(cffi:defcfun ("mbedtls_x509write_crt_set_version" %x509write-set-version) :void
  (ctx :pointer) (version :int))
(cffi:defcfun ("mbedtls_x509write_crt_set_serial_raw" %x509write-set-serial-raw) :int
  (ctx :pointer) (serial :pointer) (len :size))
(cffi:defcfun ("mbedtls_x509write_crt_set_validity" %x509write-set-validity) :int
  (ctx :pointer) (not-before :string) (not-after :string))
(cffi:defcfun ("mbedtls_x509write_crt_set_subject_name" %x509write-set-subject-name) :int
  (ctx :pointer) (name :string))
(cffi:defcfun ("mbedtls_x509write_crt_set_issuer_name" %x509write-set-issuer-name) :int
  (ctx :pointer) (name :string))
(cffi:defcfun ("mbedtls_x509write_crt_set_subject_key" %x509write-set-subject-key) :void
  (ctx :pointer) (key :pointer))
(cffi:defcfun ("mbedtls_x509write_crt_set_issuer_key" %x509write-set-issuer-key) :void
  (ctx :pointer) (key :pointer))
(cffi:defcfun ("mbedtls_x509write_crt_set_md_alg" %x509write-set-md-alg) :void
  (ctx :pointer) (md :int))
(cffi:defcfun ("mbedtls_x509write_crt_set_basic_constraints" %x509write-set-basic-constraints) :int
  (ctx :pointer) (is-ca :int) (max-pathlen :int))
(cffi:defcfun ("mbedtls_x509write_crt_set_key_usage" %x509write-set-key-usage) :int
  (ctx :pointer) (usage :uint))
(cffi:defcfun ("mbedtls_x509write_crt_pem" %x509write-crt-pem) :int
  (ctx :pointer) (buf :pointer) (size :size))
