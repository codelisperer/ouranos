;;;; certs.lisp --- errors, private keys and certificate chains.
;;;;
;;;; Keys and certificates are read FROM OCTETS, not from paths inside C. The caller reads the
;;;; file, so what was loaded is exactly the bytes the caller holds, and a server can report
;;;; the path, a hash of those bytes and the certificate's fingerprint (#125, section 7).
;;;;
;;;; OWNERSHIP IS EXPLICIT. Each object owns one mbedTLS context and frees it in its FREE-
;;;; function, which is idempotent. There are no finalizers: a config holds pointers into the
;;;; chain and key it was given, so freeing either behind its back from the GC would leave the
;;;; config pointing at freed memory. A config keeps its chain and key reachable instead.

(in-package #:aion/tls)

;;; --- errors ------------------------------------------------------------------------

(define-condition tls-error (error)
  ((code :initarg :code :reader tls-error-code)
   (operation :initarg :operation :reader tls-error-operation)
   (description :initarg :description :reader tls-error-description))
  (:report (lambda (c stream)
             (format stream "~A failed: ~A (mbedTLS error -0x~4,'0X)"
                     (tls-error-operation c) (tls-error-description c)
                     (- (tls-error-code c)))))
  (:documentation "An mbedTLS function returned an error. CODE is its negative return value;
DESCRIPTION is mbedtls_strerror's text for it."))

(define-condition tls-verify-error (tls-error)
  ((flags :initarg :flags :reader tls-verify-error-flags))
  (:report (lambda (c stream)
             (format stream "~A failed: the peer's certificate did not verify: ~A"
                     (tls-error-operation c) (tls-error-description c))))
  (:documentation "The handshake failed because the peer's certificate chain did not verify.
FLAGS are mbedTLS's verification flags; DESCRIPTION is mbedtls_x509_crt_verify_info's text."))

(defun %strerror (code)
  (cffi:with-foreign-object (buf :char 256)
    (%mbedtls-strerror code buf 256)
    (cffi:foreign-string-to-lisp buf)))

(defun %check (code operation)
  "Signal TLS-ERROR unless CODE is 0 or positive. Returns CODE."
  (when (minusp code)
    (error 'tls-error :code code :operation operation :description (%strerror code)))
  code)

;;; --- foreign octets ------------------------------------------------------------------

(defun %pem-p (octets)
  (let ((head "-----BEGIN"))
    (and (>= (length octets) (length head))
         (loop for i below (length head) always (= (aref octets i) (char-code (char head i)))))))

(defmacro %with-foreign-octets ((pointer length octets) &body body)
  "Bind POINTER to a foreign copy of OCTETS and LENGTH to the length to pass with it.

A PEM input gets a terminating NUL, and LENGTH COUNTS IT: mbedTLS's PEM parsers require
exactly that, and a PEM buffer passed without it is read as DER and refused."
  (let ((o (gensym "OCTETS")) (n (gensym "N")) (pem (gensym "PEM")))
    `(let* ((,o (coerce ,octets '(simple-array (unsigned-byte 8) (*))))
            (,pem (%pem-p ,o))
            (,n (length ,o))
            (,length (if ,pem (1+ ,n) ,n)))
       (cffi:with-foreign-object (,pointer :unsigned-char (max 1 ,length))
         (loop for i below ,n do (setf (cffi:mem-aref ,pointer :unsigned-char i) (aref ,o i)))
         (when ,pem (setf (cffi:mem-aref ,pointer :unsigned-char ,n) 0))
         ,@body))))

(defun %foreign-octets (pointer length)
  (let ((v (make-array length :element-type '(unsigned-byte 8))))
    (loop for i below length do (setf (aref v i) (cffi:mem-aref pointer :unsigned-char i)))
    v))

(defun %write-pem (writer operation &optional (size 16384))
  "Call WRITER with a buffer and its size; it fills the buffer with NUL-terminated PEM.
Returns the PEM as octets, without the NUL."
  (cffi:with-foreign-object (buf :unsigned-char size)
    (%check (funcall writer buf size) operation)
    (let ((n (loop for i from 0 below size
                   until (zerop (cffi:mem-aref buf :unsigned-char i))
                   finally (return i))))
      (%foreign-octets buf n))))

;;; --- private keys ------------------------------------------------------------------

(defclass private-key ()
  ((pointer :initarg :pointer :accessor %pointer))
  (:documentation "A private key, in an mbedtls_pk_context this object owns."))

(defun %new-key ()
  (ensure-loaded)
  (let ((p (%pk-new)))
    (when (cffi:null-pointer-p p) (error "aion/tls: out of memory allocating a key"))
    (make-instance 'private-key :pointer p)))

(defun make-private-key (octets &key password)
  "A PRIVATE-KEY parsed from OCTETS, PEM or DER. PASSWORD, a string, decrypts an encrypted key."
  (let ((key (%new-key)))
    (handler-bind ((error (lambda (e) (declare (ignore e)) (free-private-key key))))
      (%with-foreign-octets (p n octets)
        (if password
            (let ((pw (sb-ext:string-to-octets password :external-format :utf-8)))
              (cffi:with-foreign-object (pwp :unsigned-char (max 1 (length pw)))
                (loop for i below (length pw) do (setf (cffi:mem-aref pwp :unsigned-char i) (aref pw i)))
                (%check (%pk-parse-key (%pointer key) p n pwp (length pw)) "mbedtls_pk_parse_key")))
            (%check (%pk-parse-key (%pointer key) p n (cffi:null-pointer) 0) "mbedtls_pk_parse_key"))))
    key))

(defun generate-private-key ()
  "A new ECDSA private key on P-256."
  (let ((key (%new-key)))
    (handler-bind ((error (lambda (e) (declare (ignore e)) (free-private-key key))))
      (%check (%pk-generate-ec-p256 (%pointer key)) "ouranos_tls_pk_generate_ec_p256"))
    key))

(defun private-key-pem (key)
  "KEY written as PEM, as octets."
  (%write-pem (lambda (buf size) (%pk-write-key-pem (%pointer key) buf size))
              "mbedtls_pk_write_key_pem"))

(defun free-private-key (key)
  (let ((p (%pointer key)))
    (when p
      (setf (%pointer key) nil)
      (%pk-free p)))
  (values))

;;; --- certificate chains ----------------------------------------------------------

(defclass certificate-chain ()
  ((pointer :initarg :pointer :accessor %pointer))
  (:documentation "One or more X.509 certificates, in an mbedtls_x509_crt this object owns.
The first is the leaf."))

(defun make-certificate-chain (octets)
  "A CERTIFICATE-CHAIN parsed from OCTETS: one DER certificate, or any number of PEM ones.
The first certificate is the one ENGINE-PEER-CERTIFICATE-DER and CERTIFICATE-CHAIN-DER
report, and, for a server, the one it presents."
  (ensure-loaded)
  (let* ((p (%crt-new))
         (chain (make-instance 'certificate-chain :pointer p)))
    (when (cffi:null-pointer-p p) (error "aion/tls: out of memory allocating a certificate"))
    (handler-bind ((error (lambda (e) (declare (ignore e)) (free-certificate-chain chain))))
      (%with-foreign-octets (buf n octets)
        ;; A positive return is the number of PEM certificates that failed to parse. Any
        ;; failure is a failure: a chain missing an intermediate is not a chain to serve.
        (let ((rc (%x509-crt-parse p buf n)))
          (%check rc "mbedtls_x509_crt_parse")
          (when (plusp rc)
            (error 'tls-error :code 0 :operation "mbedtls_x509_crt_parse"
                              :description (format nil "~D of the certificates did not parse" rc))))))
    chain))

(defun %crt-pointer-der (crt)
  (cffi:with-foreign-object (len :size)
    (let ((p (%crt-der crt len)))
      (%foreign-octets p (cffi:mem-ref len :size)))))

(defun certificate-chain-der (chain)
  "The DER octets of CHAIN's first certificate."
  (%crt-pointer-der (%pointer chain)))

(defun certificate-chain-matches-key-p (chain key)
  "Whether KEY is the private key for CHAIN's first certificate."
  (zerop (%crt-check-key (%pointer chain) (%pointer key))))

(defun free-certificate-chain (chain)
  (let ((p (%pointer chain)))
    (when p
      (setf (%pointer chain) nil)
      (%crt-free p)))
  (values))

;;; --- issuing certificates ----------------------------------------------------------

(defun %validity-string (universal-time)
  "YYYYMMDDHHMMSS in UTC, the form mbedtls_x509write_crt_set_validity takes."
  (multiple-value-bind (s mi h d mo y) (decode-universal-time universal-time 0)
    (format nil "~4,'0D~2,'0D~2,'0D~2,'0D~2,'0D~2,'0D" y mo d h mi s)))

(defun issue-certificate (&key subject subject-key issuer issuer-key
                               (not-before (- (get-universal-time) 3600))
                               (not-after (+ (get-universal-time) (* 30 86400)))
                               dns-name ipv4 ca serial)
  "A certificate for SUBJECT-KEY, signed by ISSUER-KEY, as PEM octets.

SUBJECT and ISSUER are distinguished names such as \"CN=Test CA\". Leave ISSUER and
ISSUER-KEY out for a self-signed certificate. CA true makes it a CA certificate, which may
sign others; otherwise it is a leaf for DNS-NAME and IPV4 (a vector of four octets), its
subject alternative names. SERIAL defaults to 16 random octets. NOT-BEFORE and NOT-AFTER are
universal times; the defaults are an hour ago and thirty days from now.

For tests and for an operator's own CA. It writes only what those need: version 3, SHA-256,
basic constraints, key usage and subject alternative names."
  (ensure-loaded)
  (let ((ctx (%x509write-new))
        (issuer (or issuer subject))
        (issuer-key (or issuer-key subject-key))
        ;; From the OS generator, not CL:RANDOM, whose state can be recovered from its output
        ;; (aion/random's own header, pre-publication issue 95). A CA's serials are meant
        ;; to be unpredictable.
        (serial (copy-seq (or serial (aion/random:random-octets 16))))
        (op "issue-certificate"))
    (when (cffi:null-pointer-p ctx) (error "aion/tls: out of memory allocating a certificate writer"))
    (unwind-protect
         (progn
           ;; The first octet of a serial must not have its top bit set, or it reads as negative.
           (setf (aref serial 0) (logand (aref serial 0) #x7f))
           (%x509write-set-version ctx +x509-crt-version-3+)
           (%x509write-set-md-alg ctx +md-sha256+)
           (%x509write-set-subject-key ctx (%pointer subject-key))
           (%x509write-set-issuer-key ctx (%pointer issuer-key))
           (%check (%x509write-set-subject-name ctx subject) op)
           (%check (%x509write-set-issuer-name ctx issuer) op)
           (%check (%x509write-set-validity ctx (%validity-string not-before)
                                            (%validity-string not-after))
                   op)
           (cffi:with-foreign-object (sp :unsigned-char (length serial))
             (dotimes (i (length serial)) (setf (cffi:mem-aref sp :unsigned-char i) (aref serial i)))
             (%check (%x509write-set-serial-raw ctx sp (length serial)) op))
           (%check (%x509write-set-basic-constraints ctx (if ca 1 0) -1) op)
           (%check (%x509write-set-key-usage ctx (if ca
                                                     (logior +ku-key-cert-sign+ +ku-digital-signature+)
                                                     +ku-digital-signature+))
                   op)
           (when (or dns-name ipv4)
             (cffi:with-foreign-object (ip :unsigned-char 4)
               (when ipv4 (dotimes (i 4) (setf (cffi:mem-aref ip :unsigned-char i) (aref ipv4 i))))
               (cffi:with-foreign-string (dns (or dns-name ""))
                 (%check (%x509write-set-san ctx (if dns-name dns (cffi:null-pointer))
                                             (if ipv4 ip (cffi:null-pointer)))
                         op))))
           (%write-pem (lambda (buf size) (%x509write-crt-pem ctx buf size))
                       "mbedtls_x509write_crt_pem"))
      (%x509write-free ctx))))
