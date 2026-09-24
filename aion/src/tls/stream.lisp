;;;; stream.lisp --- a TLS connection as a blocking binary stream, over any binary stream.
;;;;
;;;; For a client that already has a byte stream to its server and wants TLS on it: a Postgres
;;;; connection (#258) is the first. Made with MAKE-TLS-STREAM, which completes the handshake
;;;; before returning, so the caller never sees a stream that is not yet secure. Reading blocks
;;;; on the underlying stream until a whole record has arrived; writing encrypts and sends,
;;;; and FORCE-OUTPUT forces the underlying stream too.
;;;;
;;;; SBCL-only, like the tree, so it uses SBCL's own Gray streams rather than a portability
;;;; library.

(in-package #:aion/tls)

(defclass tls-stream (sb-gray:fundamental-binary-input-stream
                      sb-gray:fundamental-binary-output-stream)
  ((engine :initarg :engine :reader tls-stream-engine)
   (underlying :initarg :underlying :reader %underlying)
   (close-underlying :initarg :close-underlying :reader %close-underlying)
   (plain :initform (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)
          :accessor %plain)
   (plain-start :initform 0 :accessor %plain-start)
   (eof :initform nil :accessor %eof))
  (:documentation "A binary stream of (unsigned-byte 8) whose octets travel encrypted over
another binary stream. See MAKE-TLS-STREAM."))

(defmethod stream-element-type ((s tls-stream)) '(unsigned-byte 8))

(defun %flush (engine underlying)
  (let ((out (engine-take-output engine)))
    (when (plusp (length out))
      (write-sequence out underlying)
      (force-output underlying))))

(defun %pull (engine underlying)
  "Block until at least one octet of ciphertext arrives, feed it and every octet already
waiting behind it to ENGINE, and return T; return NIL if UNDERLYING is at end of file.
LISTEN is what tells us an octet is waiting, so the read after the first never blocks."
  (let ((first (read-byte underlying nil nil)))
    (when first
      (let ((got (make-array 1 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
        (vector-push-extend first got)
        (loop while (listen underlying)
              do (let ((b (read-byte underlying nil nil)))
                   (if b (vector-push-extend b got) (return))))
        (engine-feed engine got))
      t)))

(defun make-tls-stream (underlying config &key hostname (close-underlying t))
  "A TLS-STREAM over the binary stream UNDERLYING, as a client or server by CONFIG, with the
handshake already complete. HOSTNAME is required for a client (see MAKE-ENGINE). Signals
TLS-ERROR or TLS-VERIFY-ERROR if the handshake fails, after sending the peer the alert and
freeing the engine. CLOSE-UNDERLYING, true by default, makes CLOSE close UNDERLYING too."
  (let ((engine (make-engine config :hostname hostname)))
    (handler-bind ((error (lambda (e)
                            (declare (ignore e))
                            (ignore-errors (%flush engine underlying))
                            (free-engine engine))))
      (loop
        (let ((state (engine-handshake engine)))
          (%flush engine underlying)
          (when (eq state :done) (return))
          (unless (%pull engine underlying)
            (error 'tls-error :code +err-conn-eof+ :operation "mbedtls_ssl_handshake"
                              :description "the peer closed the connection during the handshake")))))
    (make-instance 'tls-stream :engine engine :underlying underlying
                               :close-underlying close-underlying)))

(defun %fill (s)
  "Make at least one plaintext octet available, or set EOF. Returns T if one is available."
  (loop
    (when (< (%plain-start s) (fill-pointer (%plain s))) (return t))
    (when (%eof s) (return nil))
    (setf (fill-pointer (%plain s)) 0 (%plain-start s) 0)
    (let ((got (engine-read (tls-stream-engine s))))
      (cond ((eq got :eof) (setf (%eof s) t))
            ((plusp (length got))
             (loop for b across got do (vector-push-extend b (%plain s))))
            ((not (%pull (tls-stream-engine s) (%underlying s)))
             ;; The transport ended without close_notify. Treated as end of file, as every
             ;; TLS client in practice does; a caller that must tell a truncation from a clean
             ;; close can check the engine.
             (setf (%eof s) t))))))

(defmethod sb-gray:stream-read-byte ((s tls-stream))
  (if (%fill s)
      (prog1 (aref (%plain s) (%plain-start s)) (incf (%plain-start s)))
      :eof))

(defmethod sb-gray:stream-read-sequence ((s tls-stream) seq &optional (start 0) end)
  (let ((end (or end (length seq))) (i start))
    ;; Block for the first octet only; after that, take what is already decrypted, so a read
    ;; asking for more than the peer has sent returns what there is rather than waiting.
    (loop while (and (< i end) (if (= i start) (%fill s) (< (%plain-start s) (fill-pointer (%plain s)))))
          do (setf (elt seq i) (aref (%plain s) (%plain-start s)))
             (incf (%plain-start s))
             (incf i))
    i))

(defmethod sb-gray:stream-listen ((s tls-stream))
  (< (%plain-start s) (fill-pointer (%plain s))))

(defmethod sb-gray:stream-write-byte ((s tls-stream) byte)
  (engine-write (tls-stream-engine s) (vector byte))
  byte)

(defmethod sb-gray:stream-write-sequence ((s tls-stream) seq &optional (start 0) end)
  (let ((octets (coerce (subseq seq start (or end (length seq))) '(simple-array (unsigned-byte 8) (*)))))
    (engine-write (tls-stream-engine s) octets))
  seq)

(defmethod sb-gray:stream-force-output ((s tls-stream))
  (%flush (tls-stream-engine s) (%underlying s))
  nil)

(defmethod sb-gray:stream-finish-output ((s tls-stream))
  (%flush (tls-stream-engine s) (%underlying s))
  (finish-output (%underlying s))
  nil)

(defmethod close ((s tls-stream) &key abort)
  (let ((engine (tls-stream-engine s)))
    (when (%ssl engine)
      (unless abort
        (ignore-errors (engine-close-notify engine))
        (ignore-errors (%flush engine (%underlying s))))
      (free-engine engine))
    (when (%close-underlying s) (close (%underlying s) :abort abort)))
  (call-next-method))
