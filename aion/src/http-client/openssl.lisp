;;;; openssl.lisp --- aion/http-client: a patch to cl+ssl for OpenSSL 4 (#706).

(in-package #:aion/http-client)

;;; THE ONE PLACE aion PATCHES cl+ssl. Remove this file, its test
;;; (the-cl+ssl-patch-for-openssl-4-is-in-place) and its line in aion.asd once the pinned cl+ssl
;;; contains cl-plus-ssl pull request 202, and record that in CHANGELOG.md (#706).
;;;
;;; cl+ssl reads the bytes of a certificate's names with ASN1_STRING_data. OpenSSL 4 removed
;;; that function. Where the default libcrypto is OpenSSL 4, the first call to it fails, and so
;;; does every pinned TLS connection (FETCH's :CONNECT-ADDRESS), because checking the host name
;;; reads the certificate's names. ASN1_STRING_get0_data returns the same pointer and exists in
;;; OpenSSL 1.1, 3 and 4. cl+ssl calls ASN1-STRING-DATA by name, so pointing that name at
;;; ASN1_STRING_get0_data fixes every caller.
;;;
;;; The patch is applied when this file loads, which is after cl+ssl. A later load of cl+ssl
;;; would put the old definition back; the test above checks that it has not.
#-os-windows
(progn
  (cl+ssl::define-crypto-function ("ASN1_STRING_get0_data" cl+ssl::asn1-string-get0-data)
      :pointer
    (asn1-string :pointer))
  (setf (fdefinition 'cl+ssl::asn1-string-data) #'cl+ssl::asn1-string-get0-data))
