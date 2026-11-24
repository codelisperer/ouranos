;;;; frame.lisp --- WebSocket frames, close payloads, fragmented messages and UTF-8 (#376).
;;;;
;;;; Every function here is pure: octets in, a value out. The rules a frame from a client is
;;;; held to, and the close code each refusal carries (RFC 6455 sections 5 and 7.4.1):
;;;;
;;;;   a reserved bit (RSV1-3) set                      1002. No extension is negotiated, so
;;;;                                                    nothing gives the bits a meaning.
;;;;   an opcode other than 0, 1, 2, 8, 9, 10           1002.
;;;;   a control frame (close, ping, pong) that is      1002. Section 5.5: control frames are
;;;;   fragmented, or carries more than 125 octets           never fragmented and are short.
;;;;   a frame from a client that is not masked         1002. Section 5.1: the server MUST
;;;;                                                    close the connection.
;;;;   a frame to a client that is masked               1002. The same section, for the client
;;;;                                                    side, which the tests use.
;;;;   a 64-bit length with its top bit set             1002. Section 5.2.
;;;;   a length not in its shortest form                1002. Section 5.2 says the minimal
;;;;                                                    number of octets MUST be used.
;;;;   a payload longer than the configured maximum     1009. Checked from the header, before
;;;;                                                    the payload has arrived, so a peer
;;;;                                                    cannot make the server buffer a length
;;;;                                                    it then refuses.
;;;;   a continuation with no message to continue,      1002. Section 5.4.
;;;;   or a new message before the last one ended
;;;;   a message longer than the configured maximum     1009. Counted across its fragments.
;;;;   a text message, or a close reason, that is       1007. Section 8.1.
;;;;   not valid UTF-8
;;;;   a close payload of one octet, or a close code    1002. Section 7.4.
;;;;   that may not be sent in a close frame

(cl:in-package #:aion/websocket)

;;; --- opcodes and close codes ------------------------------------------------

(defconstant +continuation+ 0)
(defconstant +text+ 1)
(defconstant +binary+ 2)
(defconstant +close+ 8)
(defconstant +ping+ 9)
(defconstant +pong+ 10)

(defconstant +normal-closure+ 1000)
(defconstant +going-away+ 1001)
(defconstant +protocol-error+ 1002)
(defconstant +unsupported-data+ 1003)
(defconstant +no-status+ 1005
  "What a close frame with an empty payload is reported as. Never sent on the wire.")
(defconstant +abnormal-closure+ 1006
  "What a connection that ended without a close frame is reported as. Never sent on the wire.")
(defconstant +invalid-payload+ 1007)
(defconstant +policy-violation+ 1008)
(defconstant +message-too-big+ 1009)
(defconstant +internal-error+ 1011)

(defconstant max-control-payload 125
  "The longest payload a close, ping or pong frame may carry (RFC 6455 section 5.5).")

(defconstant max-close-reason-octets 123
  "The longest close reason, in octets: a control payload less the two octets of the code.")

(deftype octets () '(simple-array (unsigned-byte 8) (*)))

(defun %octets (n)
  (make-array n :element-type '(unsigned-byte 8)))

(defun control-opcode-p (opcode)
  "Whether OPCODE is a control frame's: close, ping or pong."
  (>= opcode 8))

(defun %known-opcode-p (opcode)
  (member opcode '(0 1 2 8 9 10)))

;;; --- UTF-8 ------------------------------------------------------------------

(defun utf8-valid-p (octets &key (start 0) (end (length octets)))
  "Whether OCTETS from START to END are well-formed UTF-8 (RFC 3629): no overlong form, no
surrogate code point, nothing above U+10FFFF, no sequence cut short at END."
  (flet ((in (i lo hi) (and (< i end) (<= lo (aref octets i) hi))))
    (let ((i start))
      (loop
        (when (>= i end) (return t))
        (let ((b (aref octets i)))
          (cond
            ((< b #x80) (incf i))
            ((<= #xC2 b #xDF)
             (unless (in (+ i 1) #x80 #xBF) (return nil))
             (incf i 2))
            ((= b #xE0)
             (unless (and (in (+ i 1) #xA0 #xBF) (in (+ i 2) #x80 #xBF)) (return nil))
             (incf i 3))
            ((or (<= #xE1 b #xEC) (<= #xEE b #xEF))
             (unless (and (in (+ i 1) #x80 #xBF) (in (+ i 2) #x80 #xBF)) (return nil))
             (incf i 3))
            ((= b #xED)
             ;; U+D800 to U+DFFF, the surrogates, would start ED A0 to ED BF.
             (unless (and (in (+ i 1) #x80 #x9F) (in (+ i 2) #x80 #xBF)) (return nil))
             (incf i 3))
            ((= b #xF0)
             (unless (and (in (+ i 1) #x90 #xBF) (in (+ i 2) #x80 #xBF) (in (+ i 3) #x80 #xBF))
               (return nil))
             (incf i 4))
            ((<= #xF1 b #xF3)
             (unless (and (in (+ i 1) #x80 #xBF) (in (+ i 2) #x80 #xBF) (in (+ i 3) #x80 #xBF))
               (return nil))
             (incf i 4))
            ((= b #xF4)
             (unless (and (in (+ i 1) #x80 #x8F) (in (+ i 2) #x80 #xBF) (in (+ i 3) #x80 #xBF))
               (return nil))
             (incf i 4))
            (t (return nil))))))))

(defun decode-utf8 (octets &key (start 0) (end (length octets)))
  "OCTETS from START to END as a string. The caller has checked them with UTF8-VALID-P."
  (sb-ext:octets-to-string octets :start start :end end :external-format :utf-8))

(defun encode-utf8 (string)
  "STRING as UTF-8 octets."
  (coerce (sb-ext:string-to-octets string :external-format :utf-8) 'octets))

;;; --- frames -----------------------------------------------------------------

(defstruct (frame (:constructor make-frame (fin opcode payload)) (:copier nil))
  "One frame as the peer sent it, with its payload already unmasked."
  (fin t :read-only t)
  (opcode 0 :read-only t)
  (payload (%octets 0) :read-only t))

(defun %be (octets start count)
  "COUNT octets of OCTETS from START, read as a big-endian unsigned integer."
  (let ((n 0))
    (dotimes (i count n)
      (setf n (logior (ash n 8) (aref octets (+ start i)))))))

(defun parse-frame (octets &key (start 0) (end (length octets)) (masked t)
                                (max-payload most-positive-fixnum))
  "Parse one frame from OCTETS between START and END.

Returns one of:
  (values :INCOMPLETE)            more octets are needed; nothing is wrong yet
  (values :FRAME frame next)      FRAME was parsed; NEXT is the index just after it
  (values :ERROR code reason)     the octets break a rule; CODE is the close code to send

MASKED is what the peer's frames must be: true when parsing a client's frames (the server's
case), NIL when parsing a server's. MAX-PAYLOAD is the largest payload accepted, checked
from the frame header before the payload has arrived."
  (let ((available (- end start)))
    (when (< available 2)
      (return-from parse-frame :incomplete))
    (let* ((b0 (aref octets start))
           (b1 (aref octets (1+ start)))
           (fin (logbitp 7 b0))
           (rsv (ldb (byte 3 4) b0))
           (opcode (ldb (byte 4 0) b0))
           (mask-bit (logbitp 7 b1))
           (len7 (ldb (byte 7 0) b1))
           (extended (case len7 (126 2) (127 8) (t 0))))
      (flet ((refuse (code reason) (return-from parse-frame (values :error code reason))))
        (unless (zerop rsv)
          (refuse +protocol-error+ "a reserved bit is set and no extension was negotiated"))
        (unless (%known-opcode-p opcode)
          (refuse +protocol-error+ (format nil "unknown opcode ~D" opcode)))
        (when (control-opcode-p opcode)
          (unless fin
            (refuse +protocol-error+ "a control frame is fragmented"))
          (when (> len7 max-control-payload)
            (refuse +protocol-error+ "a control frame's payload is longer than 125 octets")))
        (cond ((and masked (not mask-bit))
               (refuse +protocol-error+ "a frame from the client is not masked"))
              ((and (not masked) mask-bit)
               (refuse +protocol-error+ "a frame from the server is masked")))
        (when (< available (+ 2 extended))
          (return-from parse-frame :incomplete))
        (let ((length (if (zerop extended) len7 (%be octets (+ start 2) extended))))
          (case extended
            (2 (when (< length 126)
                 (refuse +protocol-error+ "a payload length is not in its shortest form")))
            (8 (when (logbitp 63 length)
                 (refuse +protocol-error+ "a 64-bit payload length has its top bit set"))
               (when (<= length #xFFFF)
                 (refuse +protocol-error+ "a payload length is not in its shortest form"))))
          (when (> length max-payload)
            (refuse +message-too-big+
                    (format nil "a frame's payload of ~D octets is over the limit of ~D"
                            length max-payload)))
          (let* ((key-at (+ start 2 extended))
                 (data-at (+ key-at (if mask-bit 4 0)))
                 (next (+ data-at length)))
            (when (< end next)
              (return-from parse-frame :incomplete))
            (let ((payload (%octets length)))
              (if mask-bit
                  (dotimes (i length)
                    (setf (aref payload i)
                          (logxor (aref octets (+ data-at i))
                                  (aref octets (+ key-at (mod i 4))))))
                  (replace payload octets :start2 data-at :end2 next))
              (values :frame (make-frame fin opcode payload) next))))))))

(defun encode-frame (opcode payload &key (fin t) mask-key)
  "One frame as octets: OPCODE, PAYLOAD (an octet vector), FIN, and MASK-KEY, four octets
when the frame is masked (a client's) or NIL (a server's).

Signals an error for a control frame that is fragmented or longer than 125 octets, because
the peer would have to refuse it."
  (let ((length (length payload)))
    (when (control-opcode-p opcode)
      (assert fin () "a control frame cannot be fragmented")
      (assert (<= length max-control-payload) ()
              "a control frame's payload cannot be longer than 125 octets, and this one is ~D"
              length))
    (let* ((extended (cond ((< length 126) 0) ((<= length #xFFFF) 2) (t 8)))
           (key-octets (if mask-key 4 0))
           (data-at (+ 2 extended key-octets))
           (out (%octets (+ data-at length))))
      (setf (aref out 0) (logior (if fin #x80 0) opcode)
            (aref out 1) (logior (if mask-key #x80 0)
                                 (case extended (0 length) (2 126) (8 127))))
      (dotimes (i extended)
        (setf (aref out (+ 2 i)) (ldb (byte 8 (* 8 (- extended 1 i))) length)))
      (if mask-key
          (progn
            (replace out mask-key :start1 (+ 2 extended))
            (dotimes (i length)
              (setf (aref out (+ data-at i))
                    (logxor (aref payload i) (aref mask-key (mod i 4))))))
          (replace out payload :start1 data-at))
      out)))

;;; --- close frames -----------------------------------------------------------

(defun valid-close-code-p (code)
  "Whether CODE may appear in a close frame (RFC 6455 section 7.4 and the IANA registry):
1000 to 1003, 1007 to 1014, or 3000 to 4999. 1004 is reserved, and 1005, 1006 and 1015 are
reported locally but never sent."
  (or (<= 1000 code 1003) (<= 1007 code 1014) (<= 3000 code 4999)))

(defun parse-close-payload (payload)
  "A close frame's PAYLOAD as (values :CLOSE code reason), or (values :ERROR code why).
An empty payload is code 1005 and the empty reason."
  (let ((n (length payload)))
    (cond
      ((zerop n) (values :close +no-status+ ""))
      ((= n 1) (values :error +protocol-error+ "a close frame's payload is one octet long"))
      (t
       (let ((code (%be payload 0 2)))
         (cond
           ((not (valid-close-code-p code))
            (values :error +protocol-error+
                    (format nil "close code ~D may not be sent in a close frame" code)))
           ((not (utf8-valid-p payload :start 2))
            (values :error +invalid-payload+ "a close reason is not valid UTF-8"))
           (t (values :close code (decode-utf8 payload :start 2)))))))))

(defun encode-close-payload (code &optional (reason ""))
  "The payload of a close frame for CODE and REASON. CODE NIL gives the empty payload.
Signals an error for a code that may not be sent, or a reason over 123 octets."
  (if (null code)
      (%octets 0)
      (let ((text (encode-utf8 reason)))
        (assert (valid-close-code-p code) () "close code ~D may not be sent" code)
        (assert (<= (length text) max-close-reason-octets) ()
                "a close reason can be at most 123 octets, and this one is ~D" (length text))
        (let ((out (%octets (+ 2 (length text)))))
          (setf (aref out 0) (ldb (byte 8 8) code)
                (aref out 1) (ldb (byte 8 0) code))
          (replace out text :start1 2)
          out))))

;;; --- messages from fragments ------------------------------------------------

(defstruct (assembler (:constructor make-assembler (&key (max-message-octets
                                                          most-positive-fixnum)))
                      (:copier nil))
  "What has been received of a fragmented message: its opcode, its parts so far, and their
total size. One per connection. ASSEMBLE is the only thing that changes it."
  (max-message-octets most-positive-fixnum :read-only t)
  (opcode nil)
  (parts '())
  (size 0))

(defun assembler-in-message-p (assembler)
  "Whether ASSEMBLER holds the first fragments of a message whose last has not arrived."
  (and (assembler-opcode assembler) t))

(defun %finish-message (opcode octets)
  (if (= opcode +text+)
      (if (utf8-valid-p octets)
          (values :text (decode-utf8 octets))
          (values :error +invalid-payload+ "a text message is not valid UTF-8"))
      (values :binary octets)))

(defun %join (parts size)
  (let ((out (%octets size)) (at 0))
    (dolist (part parts out)
      (replace out part :start1 at)
      (incf at (length part)))))

(defun assemble (assembler frame)
  "Take FRAME into ASSEMBLER and say what it completes:
  (values :NONE)                 a fragment of a message that has not ended yet
  (values :TEXT string)          a whole text message
  (values :BINARY octets)        a whole binary message
  (values :PING payload)         a ping, which may arrive between fragments
  (values :PONG payload)
  (values :CLOSE code reason)    a close frame, with 1005 for an empty payload
  (values :ERROR code reason)    a rule is broken; CODE is the close code to send"
  (let ((opcode (frame-opcode frame))
        (payload (frame-payload frame))
        (max (assembler-max-message-octets assembler)))
    (cond
      ((= opcode +ping+) (values :ping payload))
      ((= opcode +pong+) (values :pong payload))
      ((= opcode +close+) (parse-close-payload payload))
      ((= opcode +continuation+)
       (cond
         ((null (assembler-opcode assembler))
          (values :error +protocol-error+ "a continuation frame with no message to continue"))
         (t
          (let ((size (+ (assembler-size assembler) (length payload))))
            (if (> size max)
                (values :error +message-too-big+
                        (format nil "a message of at least ~D octets is over the limit of ~D"
                                size max))
                (progn
                  (push payload (assembler-parts assembler))
                  (setf (assembler-size assembler) size)
                  (if (frame-fin frame)
                      (let ((message-opcode (assembler-opcode assembler))
                            (octets (%join (reverse (assembler-parts assembler)) size)))
                        (setf (assembler-opcode assembler) nil
                              (assembler-parts assembler) '()
                              (assembler-size assembler) 0)
                        (%finish-message message-opcode octets))
                      (values :none))))))))
      ;; A text or binary frame: the first, or only, frame of a message.
      ((assembler-opcode assembler)
       (values :error +protocol-error+ "a new message began before the fragmented one ended"))
      ((> (length payload) max)
       (values :error +message-too-big+
               (format nil "a message of ~D octets is over the limit of ~D"
                       (length payload) max)))
      ((frame-fin frame) (%finish-message opcode payload))
      (t
       (setf (assembler-opcode assembler) opcode
             (assembler-parts assembler) (list payload)
             (assembler-size assembler) (length payload))
       (values :none)))))
