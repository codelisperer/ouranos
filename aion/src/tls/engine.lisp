;;;; engine.lisp --- one TLS connection over memory buffers.
;;;;
;;;; mbedTLS reads and writes through two callbacks set with mbedtls_ssl_set_bio. Ours never
;;;; touch a socket. RECEIVE takes ciphertext from the engine's input buffer, which
;;;; ENGINE-FEED fills, and answers MBEDTLS_ERR_SSL_WANT_READ when it is empty. SEND appends
;;;; ciphertext to the output buffer, which ENGINE-TAKE-OUTPUT empties. The caller moves the
;;;; ciphertext: hyperion/server-uv over libuv, TLS-STREAM over a Lisp stream, a test from one
;;;; engine to another.
;;;;
;;;; ONE THREAD AT A TIME PER ENGINE. An engine is not locked. The server uses each engine
;;;; only on its loop thread, and a TLS-STREAM only on the thread using the stream. mbedTLS's
;;;; own shared state (PSA) is thread-safe, because ouranos_tls_config.h switches threading on
;;;; and the loader refuses a library built without it.

(in-package #:aion/tls)

;;; --- the callbacks and the registry they find engines through -------------------------

(defvar *engines* (make-hash-table) "Engine id -> ENGINE, for the callbacks.")
(defvar *engines-lock* (sb-thread:make-mutex :name "aion/tls engines"))
(defvar *next-engine-id* 0)

(defun %engine-by-id (id)
  (sb-thread:with-mutex (*engines-lock*) (gethash id *engines*)))

(defclass engine ()
  ((id :initarg :id :reader %id)
   (ssl :initarg :ssl :accessor %ssl)
   (context :initarg :context :accessor %context)   ; foreign intptr holding ID, passed to C
   (config :initarg :config :reader %config)
   (in :initform (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)
       :accessor %in)
   (in-start :initform 0 :accessor %in-start)
   (out :initform (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)
        :accessor %out)
   (peer-closed :initform nil :accessor %peer-closed)
   (hostname :initarg :hostname :initform nil :reader %hostname)
   ;; For a config with a verifier: T once it has accepted the server's chain (#536).
   (verified :initform nil :accessor %verified))
  (:documentation "One TLS connection, client or server by its config, over memory buffers."))

(cffi:defcallback %bio-send :int ((context :pointer) (buf :pointer) (len :size))
  (let ((engine (%engine-by-id (cffi:mem-ref context :intptr))))
    (if (null engine)
        -1
        (let ((out (%out engine)))
          (dotimes (i len) (vector-push-extend (cffi:mem-aref buf :unsigned-char i) out))
          len))))

(cffi:defcallback %bio-recv :int ((context :pointer) (buf :pointer) (len :size))
  (let ((engine (%engine-by-id (cffi:mem-ref context :intptr))))
    (if (null engine)
        -1
        (let* ((in (%in engine))
               (start (%in-start engine))
               (available (- (fill-pointer in) start)))
          (if (zerop available)
              +err-want-read+
              (let ((n (min len available)))
                (dotimes (i n) (setf (cffi:mem-aref buf :unsigned-char i) (aref in (+ start i))))
                (setf (%in-start engine) (+ start n))
                ;; Compact once everything fed has been consumed, so a long connection does not
                ;; keep every record it ever received.
                (when (= (%in-start engine) (fill-pointer in))
                  (setf (fill-pointer in) 0 (%in-start engine) 0))
                n))))))

;;; --- making and freeing ----------------------------------------------------------------

(defun make-engine (config &key hostname)
  "A new ENGINE for one connection under CONFIG. For a client, HOSTNAME is the name the
server's certificate must be valid for; it is required, because without it mbedTLS would
accept any certificate the trusted CAs signed, for any name."
  (ensure-loaded)
  (when (and (eq (config-endpoint config) :client) (null hostname))
    (error "aion/tls: a client engine needs the HOSTNAME the server's certificate must name"))
  (let* ((ssl (%ssl-new))
         (id (sb-thread:with-mutex (*engines-lock*) (incf *next-engine-id*)))
         (context (cffi:foreign-alloc :intptr :initial-element id))
         (engine (make-instance 'engine :id id :ssl ssl :context context :config config
                                        :hostname hostname)))
    (when (cffi:null-pointer-p ssl) (error "aion/tls: out of memory allocating a connection"))
    (sb-thread:with-mutex (*engines-lock*) (setf (gethash id *engines*) engine))
    (handler-bind ((error (lambda (e) (declare (ignore e)) (free-engine engine))))
      (%check (%ssl-setup ssl (%pointer config)) "mbedtls_ssl_setup")
      ;; mbedTLS sends SNI from the name set here and also verifies against it. RFC 6066 does
      ;; not allow an IP address as SNI, so with a caller's verifier, which does the name
      ;; check itself and gets HOSTNAME from the engine, an IP literal is not set at all. A
      ;; config that trusts CA certificates needs the name set to verify it, and mbedTLS has no
      ;; way to verify against a name it does not also send.
      (when (and hostname (not (and (config-verifier config) (ip-literal-p hostname))))
        (%check (%ssl-set-hostname ssl hostname) "mbedtls_ssl_set_hostname"))
      (%ssl-set-bio ssl context (cffi:callback %bio-send) (cffi:callback %bio-recv)
                    (cffi:null-pointer)))
    engine))

(defun ip-literal-p (name)
  "Whether NAME is an IP address rather than a host name: four dot-separated decimal numbers, or
anything holding a colon (an IPv6 address, without the brackets a URL puts round it)."
  (or (find #\: name)
      (let ((parts (uiop:split-string name :separator ".")))
        (and (= 4 (length parts))
             (every (lambda (p) (and (plusp (length p)) (every #'digit-char-p p))) parts)))))

(defun free-engine (engine)
  "Free ENGINE's mbedTLS context. Idempotent. Its config is not freed."
  (let ((ssl (%ssl engine)) (context (%context engine)))
    (sb-thread:with-mutex (*engines-lock*) (remhash (%id engine) *engines*))
    (when ssl (setf (%ssl engine) nil) (%ssl-free ssl))
    (when context (setf (%context engine) nil) (cffi:foreign-free context)))
  (values))

;;; --- moving ciphertext -----------------------------------------------------------------

(defun engine-feed (engine octets &key (start 0) (end (length octets)))
  "Give ENGINE ciphertext the peer sent: OCTETS from START to END."
  (let ((in (%in engine)))
    (loop for i from start below end do (vector-push-extend (aref octets i) in)))
  (values))

(defun engine-output-pending-p (engine)
  (plusp (fill-pointer (%out engine))))

(defun engine-take-output (engine)
  "The ciphertext ENGINE has produced for the peer since the last call, as a fresh octet
vector, possibly empty. The caller must send it, in order."
  (let* ((out (%out engine))
         (octets (make-array (fill-pointer out) :element-type '(unsigned-byte 8))))
    (replace octets out)
    (setf (fill-pointer out) 0)
    octets))

;;; --- the connection --------------------------------------------------------------------

(defun %handshake-error (engine code)
  "The condition for a handshake that failed with CODE: TLS-VERIFY-ERROR when the peer's
certificate did not verify, with mbedTLS's own description of why, else TLS-ERROR."
  (let ((flags (%ssl-get-verify-result (%ssl engine))))
    (if (and (= code +err-x509-cert-verify-failed+) (plusp flags))
        (make-condition 'tls-verify-error
                        :code code :operation "mbedtls_ssl_handshake" :flags flags
                        :description (cffi:with-foreign-object (buf :char 512)
                                       (%x509-crt-verify-info buf 512 "" flags)
                                       (string-trim '(#\Newline #\Space)
                                                    (cffi:foreign-string-to-lisp buf))))
        (make-condition 'tls-error :code code :operation "mbedtls_ssl_handshake"
                                   :description (%strerror code)))))

(defun engine-handshake (engine)
  "Advance the handshake with whatever ciphertext has been fed. Returns :DONE once it has
finished, or :WANT-READ when it needs more from the peer. Either way, send
ENGINE-TAKE-OUTPUT afterwards. Signals TLS-ERROR, or TLS-VERIFY-ERROR, if it fails; the
alert telling the peer so is then in the output."
  (let ((code (%ssl-handshake (%ssl engine))))
    (cond ((zerop code) (%run-verifier engine) :done)
          ((or (= code +err-want-read+) (= code +err-want-write+)) :want-read)
          (t (error (%handshake-error engine code))))))

(defun engine-peer-certificate-chain-der (engine)
  "The DER octets of every certificate the peer presented, the leaf first, as a list; NIL if
it presented none."
  (loop for crt = (%ssl-get-peer-cert (%ssl engine)) then (%crt-next crt)
        until (cffi:null-pointer-p crt)
        collect (%crt-pointer-der crt)))

(defun %run-verifier (engine)
  "Once per engine whose config has a verifier: give it the peer's chain and the hostname, and
mark the engine verified only when it accepts. A condition it signals goes to the caller."
  (let ((verify (config-verifier (%config engine))))
    (when (and verify (not (%verified engine)))
      (let ((chain (engine-peer-certificate-chain-der engine)))
        (unless (and chain (funcall verify chain (%hostname engine)))
          (error 'tls-verify-error
                 :code 0 :operation "the caller's certificate verifier" :flags 0
                 :description (if chain
                                  "the verifier refused the server's certificate chain"
                                  "the server presented no certificate"))))
      (setf (%verified engine) t))))

(defun %require-verified (engine)
  (when (and (config-verifier (%config engine)) (not (%verified engine)))
    (error 'tls-error :code 0 :operation "aion/tls"
                      :description "the server's certificate has not been accepted by the verifier")))

(defun engine-handshake-done-p (engine)
  (plusp (%handshake-over (%ssl engine))))

(defconstant +max-idle-reads+ 8
  "How many calls of mbedtls_ssl_read in a row may read nothing, with fed input still unread,
before ENGINE-READ stops asking. See the comment in ENGINE-READ.")

(defun engine-read (engine)
  "Decrypt what has been fed. Returns the plaintext as an octet vector, possibly empty when
a whole record has not arrived yet, or :EOF once the peer has sent close_notify."
  (%require-verified engine)
  (let ((result (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (cffi:with-foreign-object (buf :unsigned-char 16384)
      (loop with idle = 0
            do
        (let* ((before (%in-start engine))
               (n (%ssl-read (%ssl engine) buf 16384)))
          (cond ((plusp n)
                 (dotimes (i n) (vector-push-extend (cffi:mem-aref buf :unsigned-char i) result)))
                ;; WANT-READ does not always mean the fed ciphertext is used up. A TLS 1.3 server
                ;; may send session tickets after the handshake (OpenSSL sends two). mbedTLS
                ;; 4.1.1 handles a ticket over several calls of mbedtls_ssl_read, measured
                ;; against example.com: WANT-READ having read the ticket's record, then
                ;; RECEIVED-NEW-SESSION-TICKET, then WANT-READ again reading nothing, while the
                ;; response's records were still unread here. Returning at the first WANT-READ
                ;; made the caller wait on the network for data it already had, and a server
                ;; that closed after its response was reported as a truncated stream (#536).
                ;; So read again while fed input is still unread, or while mbedTLS says it holds
                ;; input it has not processed (mbedtls_ssl_check_pending). A call that reads
                ;; nothing and reports no ticket counts as idle, and after +MAX-IDLE-READS+ of
                ;; them in a row this returns, so mbedTLS refusing the input for good cannot
                ;; loop here.
                ((or (= n +err-want-read+) (= n +err-want-write+))
                 (if (= (%in-start engine) before) (incf idle) (setf idle 0))
                 (unless (and (< idle +max-idle-reads+)
                              (or (< (%in-start engine) (fill-pointer (%in engine)))
                                  (plusp (%ssl-check-pending (%ssl engine)))))
                   (return)))
                ;; A TLS 1.3 server may send session tickets after the handshake. We keep no
                ;; sessions, so a ticket is read and dropped. A ticket is progress: several can
                ;; share one record, so none of them reads input, and counting them as idle
                ;; stopped the loop after +MAX-IDLE-READS+ tickets with the response still
                ;; buffered (the hub's review of #913).
                ((= n +err-received-new-session-ticket+) (setf idle 0))
                ((or (zerop n) (= n +err-peer-close-notify+))
                 (setf (%peer-closed engine) t)
                 (return))
                (t (%check n "mbedtls_ssl_read"))))))
    (if (and (zerop (length result)) (%peer-closed engine))
        :eof
        (coerce result '(simple-array (unsigned-byte 8) (*))))))

(defun engine-write (engine octets &key (start 0) (end (length octets)))
  "Encrypt OCTETS from START to END. The ciphertext is in ENGINE-TAKE-OUTPUT afterwards.
All of it is consumed: SEND never refuses, so mbedtls_ssl_write only returns short when a
record is full, and the loop writes the rest."
  (%require-verified engine)
  (let ((n (- end start)))
    (when (plusp n)
      (cffi:with-foreign-object (buf :unsigned-char n)
        (loop for i from 0 below n do (setf (cffi:mem-aref buf :unsigned-char i) (aref octets (+ start i))))
        (let ((done 0))
          (loop while (< done n)
                do (let ((w (%ssl-write (%ssl engine) (cffi:inc-pointer buf done) (- n done))))
                     (cond ((plusp w) (incf done w))
                           ((or (= w +err-want-read+) (= w +err-want-write+))
                            (error "aion/tls: mbedtls_ssl_write asked to wait, which a memory buffer never needs"))
                           (t (%check w "mbedtls_ssl_write")))))))))
  (values))

(defun engine-close-notify (engine)
  "Tell the peer we are closing. The alert is in ENGINE-TAKE-OUTPUT afterwards."
  (let ((code (%ssl-close-notify (%ssl engine))))
    (unless (or (zerop code) (= code +err-want-read+) (= code +err-want-write+))
      (%check code "mbedtls_ssl_close_notify")))
  (values))

(defun engine-version (engine)
  "The negotiated protocol version, as +TLS-1.2+ or +TLS-1.3+."
  (%version-number (%ssl engine)))

(defun engine-alpn-protocol (engine)
  "The application protocol the handshake agreed on, such as \"http/1.1\", or NIL when the
client offered none (#125)."
  (let ((p (%ssl-get-alpn-protocol (%ssl engine))))
    (unless (cffi:null-pointer-p p) (cffi:foreign-string-to-lisp p))))

(defun engine-ciphersuite (engine)
  "mbedTLS's name for the negotiated cipher suite."
  (%ssl-get-ciphersuite (%ssl engine)))

(defun engine-peer-certificate-der (engine)
  "The DER octets of the certificate the peer presented, or NIL if it presented none."
  (let ((crt (%ssl-get-peer-cert (%ssl engine))))
    (unless (cffi:null-pointer-p crt) (%crt-pointer-der crt))))
