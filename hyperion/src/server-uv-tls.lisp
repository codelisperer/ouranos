;;;; server-uv-tls.lisp --- HTTPS for hyperion/server-uv, over the mbedTLS aion/tls binds (#125).
;;;;
;;;; An app makes a CERTIFICATE-SET from a certificate chain and its private key, and passes it
;;;; to HYPERION/SERVER-UV:START as :TLS. Each accepted connection then gets a TLS-TRANSPORT,
;;;; which server-uv calls for every octet it sends or receives (the transport section of
;;;; server-uv.lisp). The transport runs an aion/tls engine on the connection's loop thread:
;;;; ciphertext from the socket is fed to the engine, the handshake and the records run in
;;;; memory, and what the engine writes goes to the socket. The HTTP code sees only plaintext.
;;;;
;;;; What is settled on #125 and enforced here:
;;;; - TLS 1.2 is the minimum and 1.3 is enabled, with forward-secret AEAD suites only (aion/tls
;;;;   sets both on every config). Renegotiation is off. ALPN accepts http/1.1 only, until there
;;;;   is HTTP/2.
;;;; - A handshake that has not finished within *HANDSHAKE-TIMEOUT-MS* ends the connection, so
;;;;   a client that connects and sends nothing cannot hold it open.
;;;; - A failed handshake is logged with the number of failures so far, mbedTLS's description of
;;;;   the error and the remote address. Never key material, never a certificate's contents.
;;;; - A set whose key is not its leaf certificate's key, or whose leaf has expired, is refused
;;;;   when it is made, with the reason.
;;;; - The set records where its certificate and key came from and the certificate's
;;;;   fingerprints, and SERVER-TLS-REPORT returns them with the handshake counts, so a test or
;;;;   an operator can check which certificate a server loaded rather than infer it from a
;;;;   handshake that worked.

(cl:defpackage #:hyperion/server-uv/tls
  (:use #:cl)
  (:local-nicknames (#:srv #:hyperion/server-uv)
                    (#:tls #:aion/tls)
                    (#:net #:aion/uv/net)
                    (#:uv #:aion/uv)
                    (#:secret #:aion/secret)
                    (#:log #:aion/log))
  (:documentation
   "HTTPS for hyperion/server-uv (#125). MAKE-CERTIFICATE-SET, then pass the set to
HYPERION/SERVER-UV:START as :TLS. SERVER-TLS-REPORT says which certificate a server serves.")
  (:export #:certificate-set #:make-certificate-set #:free-certificate-set
           #:certificate-set-report #:server-tls-report
           #:certificate-set-error #:certificate-set-error-reason
           #:*handshake-timeout-ms* #:+alpn-protocols+))

(cl:in-package #:hyperion/server-uv/tls)

(defvar *handshake-timeout-ms* 10000
  "How long a connection may take to finish its TLS handshake, in milliseconds, counted from
when it is accepted. Read when HYPERION/SERVER-UV:START is called, on the caller's thread, so
binding it around START applies to that server.")

(defparameter +alpn-protocols+ '("http/1.1")
  "The application protocols the server accepts through ALPN. A client that offers only others,
such as h2 alone, is refused with the no_application_protocol alert.")

;;; --- certificate sets ------------------------------------------------------------------

(define-condition certificate-set-error (error)
  ((reason :initarg :reason :reader certificate-set-error-reason))
  (:report (lambda (c stream)
             (format stream "hyperion/server-uv/tls: the certificate set was refused: ~A"
                     (certificate-set-error-reason c))))
  (:documentation "MAKE-CERTIFICATE-SET refused what it was given. REASON says why, in words,
and never contains key material."))

(defstruct (%counts (:copier nil))
  "Counts shared by every loop thread, so each slot is a word that SB-EXT:ATOMIC-INCF can
update."
  (handshakes 0 :type sb-ext:word)
  (failures 0 :type sb-ext:word)
  (timeouts 0 :type sb-ext:word)
  (live 0 :type sb-ext:word))

(defclass certificate-set ()
  ((config :initarg :config :accessor %config)
   (chain :initarg :chain :accessor %chain)
   (key :initarg :key :accessor %key)
   (record :initarg :record :reader %record)
   (counts :initform (make-%counts) :reader %counts))
  (:documentation "A certificate chain, its private key and the server config made from them,
with a record of where they came from. Made by MAKE-CERTIFICATE-SET. A server given one with
:TLS owns it, and STOP frees it."))

(defmethod print-object ((set certificate-set) stream)
  (print-unreadable-object (set stream :type t :identity t)
    (format stream "~A" (getf (%record set) :leaf-sha256))))

(defun %hex (octets)
  (ironclad:byte-array-to-hex-string octets))

(defun %sha256 (octets)
  (%hex (ironclad:digest-sequence :sha256 (coerce octets '(simple-array (unsigned-byte 8) (*))))))

(defun %iso-time (universal-time)
  (multiple-value-bind (s m h d mo y) (decode-universal-time universal-time 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ" y mo d h m s)))

(defun %read-octets (path)
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let* ((octets (make-array (file-length in) :element-type '(unsigned-byte 8)))
           (n (read-sequence octets in)))
      (subseq octets 0 n))))

(defun %certificate-octets (certificate)
  "CERTIFICATE as octets, and a description of where they came from."
  (typecase certificate
    (pathname (values (%read-octets certificate)
                      (uiop:native-namestring (truename certificate))))
    ((vector (unsigned-byte 8)) (values (copy-seq certificate) "octets"))
    (t (error 'certificate-set-error
              :reason (format nil "the certificate must be a pathname or octets, not a ~(~A~)"
                              (type-of certificate))))))

(defun %key-octets (key)
  "KEY as octets the caller of this may overwrite, and a description of where they came from.
A string is refused rather than guessed at: it could be a path or a PEM text."
  (cond ((pathnamep key) (values (%read-octets key) (uiop:native-namestring (truename key))))
        ((typep key '(vector (unsigned-byte 8))) (values (copy-seq key) "octets"))
        ((secret:secretp key)
         (values (sb-ext:string-to-octets (secret:reveal key) :external-format :utf-8) "secret"))
        (t (error 'certificate-set-error
                  :reason "the key must be a pathname, octets, or an aion/secret:secret holding a PEM key"))))

(defun make-certificate-set (&key certificate key password (now (get-universal-time)))
  "A CERTIFICATE-SET for HYPERION/SERVER-UV:START's :TLS.

CERTIFICATE is the chain the server presents, leaf first: a pathname, or octets, PEM or DER.
KEY is the leaf's private key: a pathname, octets, or an AION/SECRET:SECRET holding the PEM
text, such as HADES/CREDENTIALS:FETCH-CREDENTIAL returns. A DER key is given as a pathname or
octets. PASSWORD decrypts an encrypted key.

Signals CERTIFICATE-SET-ERROR, with the reason, when the key is not the leaf certificate's key,
or the leaf certificate expired before NOW. The octets of the key read here are overwritten with
zeros once mbedTLS has parsed them."
  (multiple-value-bind (cert-octets cert-source) (%certificate-octets certificate)
    (multiple-value-bind (key-octets key-source) (%key-octets key)
      (let ((chain nil) (private nil) (config nil))
        (handler-bind ((error (lambda (e)
                                (declare (ignore e))
                                (when config (tls:free-config config))
                                (when private (tls:free-private-key private))
                                (when chain (tls:free-certificate-chain chain)))))
          (setf chain (tls:make-certificate-chain cert-octets))
          (unwind-protect (setf private (tls:make-private-key key-octets :password password))
            (fill key-octets 0))
          (unless (tls:certificate-chain-matches-key-p chain private)
            (error 'certificate-set-error
                   :reason "the private key is not the key of the leaf certificate"))
          (let ((leaf (tls:certificate-chain-der chain)))
            (multiple-value-bind (not-before not-after) (tls:certificate-validity leaf)
              (when (< not-after now)
                (error 'certificate-set-error
                       :reason (format nil "the leaf certificate expired at ~A"
                                       (%iso-time not-after))))
              (setf config (tls:make-server-config chain private :alpn +alpn-protocols+))
              (make-instance 'certificate-set
                             :config config :chain chain :key private
                             :record (list :certificate-source cert-source
                                           :certificate-sha256 (%sha256 cert-octets)
                                           :leaf-sha256 (%sha256 leaf)
                                           :not-before (%iso-time not-before)
                                           :not-after (%iso-time not-after)
                                           :key-source key-source)))))))))

(defun free-certificate-set (set)
  "Free SET's config, chain and key, in that order, because the config points at the other two.
Idempotent. Only for a set no server owns: STOP frees the one a server was given."
  (let ((config (%config set)) (chain (%chain set)) (key (%key set)))
    (setf (%config set) nil (%chain set) nil (%key set) nil)
    (when config (tls:free-config config))
    (when chain (tls:free-certificate-chain chain))
    (when key (tls:free-private-key key)))
  (values))

(defun certificate-set-report (set)
  "A plist about SET: where its certificate and key came from, the SHA-256 of the certificate
octets it read and of the leaf certificate's DER, the leaf's validity, the protocols it accepts,
and how many handshakes have completed, failed and timed out on it, with how many connections
use it now. Nothing in it is key material."
  (let ((counts (%counts set)))
    (append (%record set)
            (list :alpn +alpn-protocols+
                  :handshakes (%counts-handshakes counts)
                  :handshake-failures (%counts-failures counts)
                  :handshake-timeouts (%counts-timeouts counts)
                  :live-connections (%counts-live counts)))))

(defun server-tls-report (server)
  "CERTIFICATE-SET-REPORT for the set SERVER was started with, or NIL for a server without TLS
or one that has stopped."
  (let ((set (srv:server-tls server)))
    (and set (certificate-set-report set))))

;;; --- the transport ---------------------------------------------------------------------

(defclass tls-transport (srv:transport)
  ((set :initarg :set :reader %set)
   (engine :initarg :engine :accessor %engine)
   ;; :HANDSHAKING until the handshake is done, then :OPEN; :CLOSED once it failed, timed
   ;; out or sent close_notify, after which nothing more is read or written.
   (state :initform :handshaking :accessor %state)
   (finish :initform nil :accessor %finish)
   (peer-ended :initform nil :accessor %peer-ended)
   (timer :initform nil :accessor %timer)
   (timeout-ms :initarg :timeout-ms :reader %timeout-ms)
   (remote :initform nil :accessor %remote))
  (:documentation "One connection's TLS: an aion/tls engine and its handshake deadline."))

(defmethod srv:tls-transport-maker ((set certificate-set))
  (unless (%config set)
    (error "hyperion/server-uv/tls: this certificate set has been freed"))
  ;; Read here, on the thread that called START: the function below runs on a loop thread,
  ;; where the caller's bindings are not seen.
  (let ((timeout-ms *handshake-timeout-ms*))
    (lambda (conn)
      (declare (ignore conn))
      (let ((engine (tls:make-engine (%config set))))
        (sb-ext:atomic-incf (%counts-live (%counts set)))
        (make-instance 'tls-transport :set set :engine engine :timeout-ms timeout-ms)))))

(defmethod srv:tls-release ((set certificate-set))
  (free-certificate-set set))

(defun %remote-of (conn)
  (multiple-value-bind (host port) (ignore-errors (net:peer-address conn))
    (if host (format nil "~A:~A" host port) "unknown")))

(defun %stop-timer (tr)
  (let ((timer (%timer tr)))
    (when timer
      (setf (%timer tr) nil)
      (ignore-errors (uv:close-handle timer)))))

(defmethod srv:transport-attach ((tr tls-transport) conn &key finish peer-ended)
  (setf (%finish tr) finish
        (%peer-ended tr) peer-ended
        (%remote tr) (%remote-of conn))
  (let ((timer (uv:make-timer (net:connection-loop conn)
                              (lambda (timer)
                                (declare (ignore timer))
                                (when (eq (%state tr) :handshaking)
                                  (setf (%state tr) :closed)
                                  (let ((n (sb-ext:atomic-incf
                                            (%counts-timeouts (%counts (%set tr))))))
                                    (log:info "server-uv/tls: handshake timed out"
                                              :timeouts (1+ n) :remote (%remote tr)
                                              :timeout-ms (%timeout-ms tr)))
                                  (%stop-timer tr)
                                  (funcall finish))))))
    (setf (%timer tr) timer)
    (uv:start-timer timer :after (%timeout-ms tr))))

(defun %flush (tr conn &rest keys &key on-complete on-error)
  "Send what the engine has written, if anything."
  (declare (ignore on-complete on-error))
  (let ((out (tls:engine-take-output (%engine tr))))
    (when (plusp (length out))
      (apply #'net:write-bytes conn out keys))))

(defun %fail (tr conn condition)
  "The handshake or a record failed: send the alert the engine wrote, log, and end the
connection once the alert has gone out."
  (setf (%state tr) :closed)
  (%stop-timer tr)
  (let ((n (sb-ext:atomic-incf (%counts-failures (%counts (%set tr))))))
    (log:info "server-uv/tls: handshake failed"
              :failures (1+ n) :remote (%remote tr)
              :alert (tls:tls-error-description condition)
              :code (tls:tls-error-code condition)))
  (let ((finish (%finish tr)))
    (handler-case
        (progn
          (%flush tr conn)
          (net:shutdown-write conn :on-complete (lambda (&rest _) (declare (ignore _)) (funcall finish))
                                   :on-error (lambda (&rest _) (declare (ignore _)) (funcall finish))))
      (error () (funcall finish)))))

(defmethod srv:transport-receive ((tr tls-transport) conn octets)
  (unless (eq (%state tr) :closed)
    (let ((engine (%engine tr)))
      (tls:engine-feed engine octets)
      (handler-case
          (progn
            (when (eq (%state tr) :handshaking)
              (let ((result (tls:engine-handshake engine)))
                (%flush tr conn)
                (when (eq result :done)
                  (setf (%state tr) :open)
                  (%stop-timer tr)
                  (sb-ext:atomic-incf (%counts-handshakes (%counts (%set tr)))))))
            (when (eq (%state tr) :open)
              (let ((plain (tls:engine-read engine)))
                (%flush tr conn)
                (cond ((eq plain :eof)
                       (setf (%state tr) :closed)
                       (funcall (%peer-ended tr))
                       nil)
                      ((plusp (length plain)) plain)
                      (t nil)))))
        (tls:tls-error (e)
          (%fail tr conn e)
          nil)))))

(defmethod srv:transport-write ((tr tls-transport) conn octets &key on-complete on-error)
  (if (eq (%state tr) :open)
      (let ((engine (%engine tr)))
        (dolist (piece (if (listp octets) octets (list octets)))
          (tls:engine-write engine (if (stringp piece)
                                       (sb-ext:string-to-octets piece :external-format :utf-8)
                                       piece)))
        (net:write-bytes conn (tls:engine-take-output engine)
                         :on-complete on-complete :on-error on-error))
      ;; Nothing is written on a connection whose handshake has not finished or that has
      ;; closed. The server does not try to: it writes only in answer to a request, and a
      ;; request arrives only after the handshake.
      (when on-error (funcall on-error (make-condition 'simple-error
                                                       :format-control "the TLS connection is not open"
                                                       :format-arguments '())))))

(defmethod srv:transport-saturated-p ((tr tls-transport) conn)
  (net:saturated-p conn))

(defmethod srv:transport-shutdown-write ((tr tls-transport) conn &key on-complete on-error)
  (when (eq (%state tr) :open)
    (setf (%state tr) :closed)
    (ignore-errors (tls:engine-close-notify (%engine tr)) (%flush tr conn)))
  (net:shutdown-write conn :on-complete on-complete :on-error on-error))

(defmethod srv:transport-free ((tr tls-transport) conn)
  (declare (ignore conn))
  (setf (%state tr) :closed)
  (%stop-timer tr)
  (let ((engine (%engine tr)))
    (when engine
      (setf (%engine tr) nil)
      (tls:free-engine engine)
      (sb-ext:atomic-decf (%counts-live (%counts (%set tr)))))))
