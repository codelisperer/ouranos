;;;; trust.lisp --- macOS's verdict on a TLS server's certificate chain (#905).
;;;;
;;;; VERIFY-SERVER-CERTIFICATE-CHAIN asks Security.framework the question Safari and URLSession
;;;; ask before they trust a server: a SecTrust made from the server's certificates, leaf first,
;;;; with SecPolicyCreateSSL for the host name, evaluated with SecTrustEvaluateWithError. The
;;;; trusted roots, the user's and administrator's trust settings, and any certificate the system
;;;; distrusts are macOS's, not ours. aion/tls's MAKE-VERIFYING-CLIENT-CONFIG calls it through
;;;; aion/http-client, so an https request on macOS trusts what the rest of macOS trusts, and no
;;;; OpenSSL is loaded for it. It is the macOS counterpart of
;;;; AION/WINDOWS:VERIFY-SERVER-CERTIFICATE-CHAIN, with the same arguments and the same verdicts.
;;;;
;;;; REVOCATION is left to the SSL policy's own default, as URLSession leaves it; no revocation
;;;; policy is added. SecTrustEvaluateWithError may use the network to fetch a missing
;;;; intermediate certificate, which Apple's header says, so it can block for that long.
;;;;
;;;; A REFUSAL IS A VERDICT, NOT A SIGNAL, as on Windows. The function returns a keyword and the
;;;; OSStatus macOS gave, and leaves conditions to the caller. A failure to build the question at
;;;; all, such as a certificate that does not parse, signals DARWIN-ERROR, because then there is
;;;; no verdict.

(in-package #:aion/darwin)

(defparameter +trust-verdicts+
  '((-67818 . :expired)            ; errSecCertificateExpired
    (-67819 . :expired)            ; errSecCertificateNotValidYet
    (-67843 . :untrusted-root)     ; errSecNotTrusted
    (-67612 . :untrusted-root)     ; errSecInvalidRoot
    (-67602 . :name-mismatch)      ; errSecHostNameMismatch
    (-67820 . :revoked)            ; errSecCertificateRevoked
    (-67635 . :revocation-unknown) ; errSecIncompleteCertRevocationCheck
    (-67654 . :distrusted)         ; errSecTrustSettingDeny
    (-25318 . :chain-incomplete)   ; errSecCreateChainFailed
    (-67609 . :wrong-usage)        ; errSecInvalidExtendedKeyUsage
    (-67608 . :wrong-usage))       ; errSecInvalidKeyUsageForPolicy
  "SecTrustEvaluateWithError's error codes (OSStatus values from SecBase.h), each with the verdict
it means. A code not listed here is the verdict :REJECTED, with the code beside it.")

(defun trust-verdict (code)
  "The verdict keyword for CODE, the OSStatus of a failed trust evaluation: :TRUSTED for 0."
  (if (zerop code)
      :trusted
      (or (cdr (assoc code +trust-verdicts+)) :rejected)))

(defun %certificate (der)
  "An owned SecCertificate for the DER octets DER. Signals DARWIN-ERROR when they do not parse."
  (with-cf ((data (make-cf-data der)))
    (let ((certificate (ffi:sec-certificate-create-with-data (cffi:null-pointer) data)))
      (when (cffi:null-pointer-p certificate)
        (error 'darwin-error :operation :sec-certificate-create-with-data
                             :message "the certificate is not DER that macOS can parse"))
      certificate)))

(defun %cf-array (refs)
  "An owned CFArray of REFS, CF objects it retains, so the caller still releases its own."
  (let ((n (length refs)))
    (cffi:with-foreign-object (values :pointer (max 1 n))
      (loop for r in refs for i from 0 do (setf (cffi:mem-aref values :pointer i) r))
      (%created (ffi:cf-array-create (cffi:null-pointer) values n
                                     (cffi:foreign-symbol-pointer "kCFTypeArrayCallBacks"))
                :cf-array-create))))

(defun verify-server-certificate-chain (chain hostname)
  "macOS's verdict on CHAIN, a TLS server's certificates as a list of DER octet vectors with the
leaf first, for a server named HOSTNAME, a host name or an IP address. Returns (values VERDICT
CODE): VERDICT is :TRUSTED, or one of :EXPIRED, :UNTRUSTED-ROOT, :NAME-MISMATCH, :REVOKED,
:REVOCATION-UNKNOWN, :DISTRUSTED, :CHAIN-INCOMPLETE, :WRONG-USAGE or :REJECTED, and CODE is the
OSStatus of SecTrustEvaluateWithError's error, 0 when trusted.

Signals DARWIN-ERROR when a certificate does not parse or the SecTrust cannot be made."
  (check-type hostname string)
  (when (null chain) (error "verify-server-certificate-chain: the server presented no certificate"))
  (let ((certificates '()))
    (unwind-protect
         (progn
           (dolist (der chain)
             (push (%certificate (coerce der '(simple-array (unsigned-byte 8) (*)))) certificates))
           (setf certificates (nreverse certificates))
           (with-cf ((array (%cf-array certificates))
                     (name (make-cf-string hostname))
                     (policy (%created (ffi:sec-policy-create-ssl 1 name) :sec-policy-create-ssl))
                     (trust (cffi:with-foreign-object (out :pointer)
                              (setf (cffi:mem-ref out :pointer) (cffi:null-pointer))
                              (check-osstatus (ffi:sec-trust-create-with-certificates array policy out)
                                              :sec-trust-create-with-certificates)
                              (cffi:mem-ref out :pointer))))
             (cffi:with-foreign-object (err :pointer)
               (setf (cffi:mem-ref err :pointer) (cffi:null-pointer))
               (if (ffi:sec-trust-evaluate-with-error trust err)
                   (values :trusted 0)
                   (with-cf ((e (cffi:mem-ref err :pointer)))
                     (let ((code (if (cffi:null-pointer-p e) -1 (ffi:cf-error-get-code e))))
                       (values (trust-verdict code) code)))))))
      (mapc #'cf-release certificates))))
