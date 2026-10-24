;;;; certificate.lisp --- Windows' verdict on a TLS server's certificate chain (#536).
;;;;
;;;; VERIFY-SERVER-CERTIFICATE-CHAIN asks crypt32 the question WinHTTP asks before it trusts a
;;;; server: build a chain from the server's certificate, with the intermediates the server sent
;;;; as an additional store, for server authentication, then check it against the SSL policy and
;;;; the host name. The trust stores, automatic root download and the Disallowed store are
;;;; Windows', not ours. aion/tls's MAKE-VERIFYING-CLIENT-CONFIG calls it through
;;;; aion/http-client, so a pinned connection on Windows trusts what the rest of Windows trusts.
;;;;
;;;; NO REVOCATION CHECK, THE SAME AS WINHTTP'S AND CL+SSL'S DEFAULTS. Microsoft's "WinHTTP
;;;; Security Considerations" says: "Certificate-revocation checking must be explicitly
;;;; requested. By default, when performing certificate authentication, WinHTTP does not check
;;;; whether the server's certificate has been revoked." dexador's WinHTTP backend never turns it
;;;; on (it sets no WINHTTP_ENABLE_SSL_REVOCATION). So the chain is built with no
;;;; CERT_CHAIN_REVOCATION_CHECK_* flag, which keeps a pinned fetch on Windows deciding exactly as
;;;; an unpinned one does. Checking revocation, with a policy for when the list cannot be
;;;; fetched, is a possible later option, not one this file offers.
;;;;
;;;; A REFUSAL IS A VERDICT, NOT A SIGNAL. The function returns a keyword and Windows' own error
;;;; code, and leaves conditions to the caller, which knows what kind of request was refused. A
;;;; failure of crypt32 itself, such as a certificate that does not parse, does signal
;;;; WIN32-ERROR, because then there is no verdict.

(in-package #:aion/windows)

(defparameter +policy-verdicts+
  '((#x800B0101 . :expired)            ; CERT_E_EXPIRED
    (#x800B0109 . :untrusted-root)     ; CERT_E_UNTRUSTEDROOT
    (#x800B010D . :untrusted-root)     ; CERT_E_UNTRUSTEDTESTROOT
    (#x800B010F . :name-mismatch)      ; CERT_E_CN_NO_MATCH
    (#x80092010 . :revoked)            ; CRYPT_E_REVOKED
    (#x80092012 . :revocation-unknown) ; CRYPT_E_NO_REVOCATION_CHECK
    (#x80092013 . :revocation-unknown) ; CRYPT_E_REVOCATION_OFFLINE
    (#x800B0111 . :distrusted)         ; TRUST_E_EXPLICIT_DISTRUST, the Disallowed store
    (#x800B010A . :chain-incomplete)   ; CERT_E_CHAINING
    (#x800B0110 . :wrong-usage))       ; CERT_E_WRONG_USAGE
  "CertVerifyCertificateChainPolicy's error codes, each with the verdict it means. A code not
listed here is the verdict :REJECTED, with the code beside it.")

(defparameter +server-auth-oid+ "1.3.6.1.5.5.7.3.1"
  "szOID_PKIX_KP_SERVER_AUTH: the chain must be valid for authenticating a TLS server.")

(defun policy-verdict (code)
  "The verdict keyword for CertVerifyCertificateChainPolicy's dwError CODE: :TRUSTED for 0."
  (if (zerop code)
      :trusted
      (or (cdr (assoc code +policy-verdicts+)) :rejected)))

(defun %encoded-certificate (der)
  "A CERT_CONTEXT for the DER octets DER. Signals WIN32-ERROR when they do not parse."
  (cffi:with-pointer-to-vector-data (p (coerce der '(simple-array (unsigned-byte 8) (*))))
    (check-win32 (ffi:cert-create-certificate-context ffi:+x509-asn-encoding+ p (length der))
                 :operation "CertCreateCertificateContext"
                 :predicate (lambda (ptr) (not (cffi:null-pointer-p ptr))))))

(defun %memory-store (ders)
  "A new in-memory certificate store holding each DER certificate in DERS."
  (let ((store (check-win32 (ffi:cert-open-store (cffi:make-pointer ffi:+cert-store-prov-memory+)
                                                 0 (cffi:null-pointer) 0 (cffi:null-pointer))
                            :operation "CertOpenStore"
                            :predicate (lambda (ptr) (not (cffi:null-pointer-p ptr))))))
    (handler-bind ((error (lambda (e) (declare (ignore e)) (ffi:cert-close-store store 0))))
      (dolist (der ders)
        (let ((octets (coerce der '(simple-array (unsigned-byte 8) (*)))))
          (cffi:with-pointer-to-vector-data (p octets)
            (check-win32 (ffi:cert-add-encoded-certificate-to-store
                          store ffi:+x509-asn-encoding+ p (length octets)
                          ffi:+cert-store-add-always+ (cffi:null-pointer))
                         :operation "CertAddEncodedCertificateToStore"
                         :predicate #'plusp)))))
    store))

(defun verify-server-certificate-chain (chain hostname)
  "Windows' verdict on CHAIN, a TLS server's certificates as a list of DER octet vectors with the
leaf first, for a server named HOSTNAME. Returns (values VERDICT CODE): VERDICT is :TRUSTED, or
one of :EXPIRED, :UNTRUSTED-ROOT, :NAME-MISMATCH, :REVOKED, :REVOCATION-UNKNOWN, :DISTRUSTED,
:CHAIN-INCOMPLETE, :WRONG-USAGE or :REJECTED, and CODE is CertVerifyCertificateChainPolicy's
dwError, 0 when trusted.

The chain is built with CertGetCertificateChain for server authentication, the certificates
after the leaf in an additional store, and no revocation check (see the file's header), then
checked with CertVerifyCertificateChainPolicy and CERT_CHAIN_POLICY_SSL against HOSTNAME.
Signals WIN32-ERROR when a certificate does not parse or crypt32 cannot build a chain at all."
  (check-type hostname string)
  (when (null chain) (error "verify-server-certificate-chain: the server presented no certificate"))
  (let ((leaf (%encoded-certificate (first chain)))
        (store nil)
        (chain-context nil))
    (unwind-protect
         (progn
           (setf store (%memory-store (rest chain)))
           (cffi:with-foreign-objects ((para '(:struct ffi:cert-chain-para))
                                       (usages :pointer 1)
                                       (out :pointer))
             (cffi:with-foreign-string (oid +server-auth-oid+ :encoding :ascii)
               (setf (cffi:mem-aref usages :pointer 0) oid)
               (cffi:with-foreign-slots ((ffi:cb-size ffi:requested-usage) para
                                         (:struct ffi:cert-chain-para))
                 (setf ffi:cb-size (cffi:foreign-type-size '(:struct ffi:cert-chain-para))))
               (let ((match (cffi:foreign-slot-pointer para '(:struct ffi:cert-chain-para)
                                                      'ffi:requested-usage)))
                 (setf (cffi:foreign-slot-value match '(:struct ffi:cert-usage-match) 'ffi:dw-type)
                       ffi:+usage-match-type-and+)
                 (let ((usage (cffi:foreign-slot-pointer match '(:struct ffi:cert-usage-match)
                                                         'ffi:usage)))
                   (setf (cffi:foreign-slot-value usage '(:struct ffi:cert-enhkey-usage)
                                                  'ffi:c-usage-identifier) 1
                         (cffi:foreign-slot-value usage '(:struct ffi:cert-enhkey-usage)
                                                  'ffi:rgpsz-usage-identifier) usages)))
               ;; dwFlags 0: no CERT_CHAIN_REVOCATION_CHECK_* flag, as WinHTTP by default.
               (check-win32 (ffi:cert-get-certificate-chain (cffi:null-pointer) leaf
                                                            (cffi:null-pointer) store para 0
                                                            (cffi:null-pointer) out)
                            :operation "CertGetCertificateChain"
                            :predicate #'plusp)
               (setf chain-context (cffi:mem-ref out :pointer))))
           (with-wide-string (name hostname)
             (cffi:with-foreign-objects ((extra '(:struct ffi:ssl-extra-cert-chain-policy-para))
                                         (policy '(:struct ffi:cert-chain-policy-para))
                                         (status '(:struct ffi:cert-chain-policy-status)))
               (cffi:with-foreign-slots ((ffi:cb-size ffi:dw-auth-type ffi:fdw-checks
                                          ffi:pwsz-server-name)
                                         extra (:struct ffi:ssl-extra-cert-chain-policy-para))
                 (setf ffi:cb-size (cffi:foreign-type-size
                                    '(:struct ffi:ssl-extra-cert-chain-policy-para))
                       ffi:dw-auth-type ffi:+authtype-server+
                       ffi:fdw-checks 0
                       ffi:pwsz-server-name name))
               (cffi:with-foreign-slots ((ffi:cb-size ffi:dw-flags ffi:pv-extra-policy-para)
                                         policy (:struct ffi:cert-chain-policy-para))
                 (setf ffi:cb-size (cffi:foreign-type-size '(:struct ffi:cert-chain-policy-para))
                       ffi:dw-flags 0
                       ffi:pv-extra-policy-para extra))
               (setf (cffi:foreign-slot-value status '(:struct ffi:cert-chain-policy-status)
                                              'ffi:cb-size)
                     (cffi:foreign-type-size '(:struct ffi:cert-chain-policy-status)))
               (check-win32 (ffi:cert-verify-certificate-chain-policy
                             (cffi:make-pointer ffi:+cert-chain-policy-ssl+) chain-context
                             policy status)
                            :operation "CertVerifyCertificateChainPolicy"
                            :predicate #'plusp)
               (let ((code (cffi:foreign-slot-value status '(:struct ffi:cert-chain-policy-status)
                                                    'ffi:dw-error)))
                 (values (policy-verdict code) code)))))
      (when chain-context (ffi:cert-free-certificate-chain chain-context))
      (when store (ffi:cert-close-store store 0))
      (ffi:cert-free-certificate-context leaf))))
