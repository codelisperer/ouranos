;;;; macos-tls.lisp --- aion/http-client: dexador's https over aion/tls on macOS (#905).

(in-package #:aion/http-client)

;;; ON macOS THIS CLIENT LOADS NO cl+ssl. Since #905, every https request this client makes on macOS
;;; goes over aion/tls (mbedTLS, built from mbedtls.pin), and Security.framework decides whether
;;; to trust the server's certificate, through *SERVER-CERTIFICATE-VERIFIER*. A pinned request
;;; does that in %REQUEST-PINNED, as on Windows. Every other request goes through DEX:REQUEST,
;;; and dexador does all of its TLS in one function, DEXADOR.BACKEND.USOCKET::MAKE-SSL-STREAM.
;;; This file replaces that function on macOS, so dexador keeps its connection pool, its proxy
;;; CONNECT tunnel, redirects and content decoding, and only the TLS under them changes. The
;;; precedent for patching a library here is openssl.lisp (#706).
;;;
;;; The other half is the feature :DEXADOR-NO-SSL, which aion.asd (and every other .asd in the
;;; tree that names dexador) pushes on macOS before dexador's plan is made. With it, dexador
;;; neither depends on cl+ssl nor imports it, and so no libssl or libcrypto is opened, which is
;;; what a desktop bundle needs (#905, #191): verify-bundle-macos.sh refuses a process that
;;; loaded an OpenSSL the bundle does not carry.
;;;
;;; A DEXADOR COMPILED WITHOUT THE FEATURE is the case the check below catches. The feature is
;;; read when dexador is compiled, and ASDF does not recompile dexador when a feature changes,
;;; so a fasl of dexador cached on this machine before #905, or built later by another project
;;; that loads dexador without aion, still imports cl+ssl. Loading this system then fails here
;;; with what to delete, rather than loading OpenSSL without saying so.

#+os-macosx
(defun %dexador-fasl-directory ()
  "The directory ASDF compiles dexador into on this machine, as ASDF's output translations say."
  (let ((source (ignore-errors (asdf:system-source-directory "dexador"))))
    (and source (asdf:apply-output-translations source))))

#+os-macosx
(defun %dexador-uses-cl+ssl-p ()
  "Whether the loaded dexador was compiled with cl+ssl: its usocket backend then imports cl+ssl's
MAKE-SSL-CLIENT-STREAM."
  (let ((package (find-package "DEXADOR.BACKEND.USOCKET")))
    (and package
         (let ((symbol (find-symbol "MAKE-SSL-CLIENT-STREAM" package)))
           (and symbol (symbol-package symbol)
                (string= "CL+SSL" (package-name (symbol-package symbol))))))))

#+os-macosx
(when (%dexador-uses-cl+ssl-p)
  (error "~{~A~%~}"
         (list "aion/http-client: this dexador was compiled with cl+ssl, so it loads OpenSSL."
               (concatenate 'string
                            "On macOS, aion/http-client makes https requests over aion/tls and needs"
                            " dexador compiled with :DEXADOR-NO-SSL on *FEATURES*, which aion.asd"
                            " sets (#905). ASDF does not recompile dexador when that feature"
                            " changes, so a copy compiled before it is still in use.")
               ""
               "Delete dexador's compiled files and load again:"
               (format nil "  ~A" (or (%dexador-fasl-directory)
                                      "(ASDF could not find dexador's source directory)"))
               ""
               "If dexador was loaded into this image before aion.asd was read, start a fresh image instead.")))

#+os-macosx
(defvar *%ca-path-configs* (make-hash-table :test 'equal)
  "aion/tls client configs for dexador's CA-PATH, keyed by the file's truename and its write date.
They are kept for the life of the image, because a connection in dexador's pool may use one long
after the request that made it; one config per distinct file.")

#+os-macosx
(defvar *%ca-path-configs-lock* (sb-thread:make-mutex :name "aion/http-client ca-path configs"))

#+os-macosx
(defun %ca-path-config-for-dexador (path)
  (let* ((truename (or (probe-file path)
                       (error 'http-error :detail (format nil "ca-path ~A does not exist" path))))
         (key (cons (namestring truename) (file-write-date truename))))
    (sb-thread:with-mutex (*%ca-path-configs-lock*)
      (or (gethash key *%ca-path-configs*)
          (setf (gethash key *%ca-path-configs*) (values (%ca-path-config truename)))))))

#+os-macosx
(defun %dexador-tls-stream (stream ca-path ssl-key-file ssl-cert-file ssl-key-password hostname
                            insecure)
  "DEXADOR.BACKEND.USOCKET::MAKE-SSL-STREAM on macOS: an aion/tls stream over STREAM to HOSTNAME,
verified by *SERVER-CERTIFICATE-VERIFIER*, or by the CA certificates in CA-PATH (or dexador's
*CA-BUNDLE*) when one is given. A client certificate and :INSECURE are refused: nothing in the
tree uses them, and aion/tls has no configuration that skips verification."
  (declare (ignore ssl-key-password))
  (when (or ssl-key-file ssl-cert-file)
    (error 'http-error :detail "a client certificate is not supported for https on macOS (#905)"))
  (when insecure
    (error 'http-error :detail "an https request that skips verification is not supported on macOS (#905)"))
  (let* ((bundle (symbol-value (find-symbol "*CA-BUNDLE*" "DEXADOR.BACKEND.USOCKET")))
         (ca (or ca-path (and bundle (probe-file bundle) bundle))))
    (aion/tls:make-tls-stream stream
                              (if ca (%ca-path-config-for-dexador ca) (%verifying-config))
                              :hostname (nth-value 1 (%tls-names hostname)))))

#+os-macosx
(defvar *%dexador-own-make-ssl-stream*
  (fdefinition (find-symbol "MAKE-SSL-STREAM" "DEXADOR.BACKEND.USOCKET"))
  "dexador's own MAKE-SSL-STREAM, as compiled with :DEXADOR-NO-SSL: it signals that SSL is not
supported. Kept for the test that shows the replacement below is what makes https work.")

#+os-macosx
(setf (fdefinition (find-symbol "MAKE-SSL-STREAM" "DEXADOR.BACKEND.USOCKET"))
      #'%dexador-tls-stream)
