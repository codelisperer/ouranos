;;;; trust-tests.lisp --- macOS's verdict on a TLS server's certificates (#905).
;;;;
;;;; The real Security.framework call, with no network: each certificate here is refused for a
;;;; reason macOS decides without fetching anything. A trusted chain is checked against public
;;;; servers by aion/http-client's opt-in test, which runs on GitHub Actions.

(in-package #:aion/darwin/tests)
(in-suite darwin)

(defun %pem-der (pem)
  "The DER octets of the first certificate in PEM, a string."
  (let* ((begin (search "-----BEGIN CERTIFICATE-----" pem))
         (start (and begin (1+ (position #\Newline pem :start begin))))
         (end (and start (search "-----END CERTIFICATE-----" pem :start2 start)))
         (alphabet "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
         (out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
         (bits 0) (count 0))
    (assert end () "no certificate in the PEM text")
    (loop for ch across (subseq pem start end)
          for v = (position ch alphabet)
          when v do (setf bits (logior (ash bits 6) v)) (incf count 6)
                    (when (>= count 8)
                      (decf count 8)
                      (vector-push-extend (ldb (byte 8 count) bits) out)
                      (setf bits (ldb (byte count 0) bits))))
    (coerce out '(simple-array (unsigned-byte 8) (*)))))

(defun %fixture-der (name)
  (%pem-der (uiop:read-file-string
             (asdf:system-relative-pathname "aion" (format nil "tests/fixtures/http-client/~A" name)))))

(defun %system-root-der (name)
  "The DER octets of the root certificate NAME from macOS's own list of roots."
  (%pem-der (uiop:run-program (list "security" "find-certificate" "-c" name "-p"
                                    "/System/Library/Keychains/SystemRootCertificates.keychain")
                              :output :string)))

(test trust-codes-map-to-verdicts
  (loop for (code . verdict) in '((0 . :trusted) (-67818 . :expired) (-67819 . :expired)
                                  (-67843 . :untrusted-root) (-67602 . :name-mismatch)
                                  (-67820 . :revoked) (-67635 . :revocation-unknown)
                                  (-67654 . :distrusted) (-25318 . :chain-incomplete)
                                  (-67609 . :wrong-usage) (-67901 . :rejected) (-1 . :rejected))
        do (is (eq verdict (d:trust-verdict code)) "~D" code)))

(test macos-does-not-trust-the-self-signed-test-certificate
  "The fixture is under no root this machine trusts. macOS reports the most serious of its
problems, which for this certificate is its validity period (errSecCertificateValidityPeriodTooLong,
-67901), so the verdict is :REJECTED; what matters is that it is not :TRUSTED."
  (multiple-value-bind (verdict code)
      (d:verify-server-certificate-chain (list (%fixture-der "pinned-test.crt")) "pinned.test")
    (is (not (eq :trusted verdict)) "~S ~D" verdict code)
    (is (not (zerop code)))))

(test a-root-certificate-is-not-accepted-as-a-server-certificate
  "ISRG Root X1 is a root macOS trusts, but it is a certificate authority's, not a server's, so
the SSL policy refuses it as :WRONG-USAGE. CONTROL for the case above: this one is refused for
its use, not for being unknown, which shows the policy is the SSL one."
  (multiple-value-bind (verdict code)
      (d:verify-server-certificate-chain (list (%system-root-der "ISRG Root X1")) "example.com")
    (is (eq :wrong-usage verdict) "~S ~D" verdict code)
    (is (= -67609 code))))

(test a-certificate-that-does-not-parse-signals
  (signals d:darwin-error
    (d:verify-server-certificate-chain
     (list (make-array 8 :element-type '(unsigned-byte 8) :initial-element 1)) "x.test"))
  (signals error (d:verify-server-certificate-chain '() "x.test")))
