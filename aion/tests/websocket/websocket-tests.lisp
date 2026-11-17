;;;; websocket-tests.lisp --- the pure WebSocket protocol: RFC 6455's examples and refusals
;;;; (#376), and the client's half of the handshake (#1028).
;;;;
;;;; Most checks here are refusals, because a frame arrives from a stranger. Each names the
;;;; close code the refusal must carry, since the code is what the peer is told.

(cl:defpackage #:aion/websocket/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:ws #:aion/websocket))
  (:export #:run-tests))

(in-package #:aion/websocket/tests)

(def-suite websocket :description "The WebSocket protocol as pure functions (#376).")
(in-suite websocket)

(defun run-tests ()
  "Run the suite; return T on success (for asdf:test-system)."
  (run! 'websocket))

(defun o (&rest bytes)
  "BYTES as an octet vector."
  (make-array (length bytes) :element-type '(unsigned-byte 8) :initial-contents bytes))

(defun ascii (string)
  (sb-ext:string-to-octets string :external-format :latin-1))

(defun parse (octets &rest keys)
  (multiple-value-list (apply #'ws:parse-frame octets keys)))

(defun refusal-code (octets &rest keys)
  "The close code PARSE-FRAME refuses OCTETS with, or NIL when it does not refuse them."
  (destructuring-bind (outcome &optional a b) (apply #'parse octets keys)
    (declare (ignore b))
    (and (eq outcome :error) a)))

;;; --- RFC 6455 section 5.7, the examples ---------------------------------------

(test rfc-example-unmasked-text-from-a-server
  (destructuring-bind (outcome frame next) (parse (o #x81 #x05 #x48 #x65 #x6c #x6c #x6f) :masked nil)
    (is (eq :frame outcome))
    (is (= 7 next))
    (is-true (ws:frame-fin frame))
    (is (= ws:+text+ (ws:frame-opcode frame)))
    (is (equalp (ascii "Hello") (ws:frame-payload frame)))))

(test rfc-example-masked-text-from-a-client
  (destructuring-bind (outcome frame next)
      (parse (o #x81 #x85 #x37 #xfa #x21 #x3d #x7f #x9f #x4d #x51 #x58))
    (is (eq :frame outcome))
    (is (= 11 next))
    (is (equalp (ascii "Hello") (ws:frame-payload frame)))))

(test rfc-example-masked-text-is-what-encode-frame-writes
  (is (equalp (o #x81 #x85 #x37 #xfa #x21 #x3d #x7f #x9f #x4d #x51 #x58)
              (ws:encode-frame ws:+text+ (ascii "Hello") :mask-key (o #x37 #xfa #x21 #x3d))))
  (is (equalp (o #x81 #x05 #x48 #x65 #x6c #x6c #x6f)
              (ws:encode-frame ws:+text+ (ascii "Hello")))))

(test rfc-example-fragmented-unmasked-text
  (let ((asm (ws:make-assembler))
        (bytes (o #x01 #x03 #x48 #x65 #x6c #x80 #x02 #x6c #x6f)))
    (destructuring-bind (outcome first next) (parse bytes :masked nil)
      (is (eq :frame outcome))
      (is-false (ws:frame-fin first))
      (is (eq :none (ws:assemble asm first)))
      (is-true (ws:assembler-in-message-p asm))
      (destructuring-bind (outcome2 second next2) (parse bytes :masked nil :start next)
        (is (eq :frame outcome2))
        (is (= (length bytes) next2))
        (is (equal '(:text "Hello") (multiple-value-list (ws:assemble asm second))))
        (is-false (ws:assembler-in-message-p asm))))))

(test rfc-example-ping-and-masked-pong
  (destructuring-bind (outcome frame next) (parse (o #x89 #x05 #x48 #x65 #x6c #x6c #x6f) :masked nil)
    (declare (ignore next))
    (is (eq :frame outcome))
    (is (equalp (list :ping (ascii "Hello"))
               (multiple-value-list (ws:assemble (ws:make-assembler) frame)))
        "a ping's payload comes back as it was"))
  (destructuring-bind (outcome frame next)
      (parse (o #x8a #x85 #x37 #xfa #x21 #x3d #x7f #x9f #x4d #x51 #x58))
    (declare (ignore next))
    (is (eq :frame outcome))
    (is (= ws:+pong+ (ws:frame-opcode frame)))
    (is (equalp (ascii "Hello") (ws:frame-payload frame)))))

(test rfc-example-256-octet-binary-uses-the-16-bit-length
  (let* ((payload (make-array 256 :element-type '(unsigned-byte 8) :initial-element 7))
         (frame (ws:encode-frame ws:+binary+ payload)))
    (is (equalp (o #x82 #x7E #x01 #x00) (subseq frame 0 4)))
    (is (= 260 (length frame)))
    (destructuring-bind (outcome parsed next) (parse frame :masked nil)
      (is (eq :frame outcome))
      (is (= 260 next))
      (is (equalp payload (ws:frame-payload parsed))))))

(test rfc-example-64-kib-binary-uses-the-64-bit-length
  (let* ((payload (make-array 65536 :element-type '(unsigned-byte 8) :initial-element 9))
         (frame (ws:encode-frame ws:+binary+ payload)))
    (is (equalp (o #x82 #x7F 0 0 0 0 0 1 0 0) (subseq frame 0 10)))
    (destructuring-bind (outcome parsed next) (parse frame :masked nil)
      (is (eq :frame outcome))
      (is (= (+ 10 65536) next))
      (is (= 65536 (length (ws:frame-payload parsed)))))))

(test a-frame-arriving-a-byte-at-a-time-is-incomplete-until-it-is-whole
  (let ((bytes (o #x81 #x85 #x37 #xfa #x21 #x3d #x7f #x9f #x4d #x51 #x58)))
    (loop for end from 0 below (length bytes)
          do (is (eq :incomplete (first (parse bytes :end end))) "~D of 11 octets" end))
    (is (eq :frame (first (parse bytes))))))

(test two-frames-in-one-read-are-parsed-one-after-the-other
  (let* ((a (ws:encode-frame ws:+text+ (ascii "one") :mask-key (o 1 2 3 4)))
         (b (ws:encode-frame ws:+binary+ (o 9 8 7) :mask-key (o 5 6 7 8)))
         (both (concatenate '(vector (unsigned-byte 8)) a b)))
    (destructuring-bind (outcome first next) (parse both)
      (is (eq :frame outcome))
      (is (equalp (ascii "one") (ws:frame-payload first)))
      (destructuring-bind (outcome2 second next2) (parse both :start next)
        (is (eq :frame outcome2))
        (is (= (length both) next2))
        (is (equalp (o 9 8 7) (ws:frame-payload second)))))))

;;; --- refusals: the frame header ---------------------------------------------------

(test an-unmasked-client-frame-is-refused-with-1002
  ;; The control for this check is in the server-uv suite: removing it there turns the
  ;; end-to-end refusal red.
  (is (= 1002 (refusal-code (o #x81 #x05 #x48 #x65 #x6c #x6c #x6f))))
  (is (= 1002 (refusal-code (o #x81 #x85 1 2 3 4 0 0 0 0 0) :masked nil))
      "and a masked frame to a client is refused the same way"))

(test a-reserved-bit-is-refused-with-1002
  (dolist (rsv '(#x40 #x20 #x10))
    (let ((frame (ws:encode-frame ws:+text+ (o) :mask-key (o 0 0 0 0))))
      (setf (aref frame 0) (logior (aref frame 0) rsv))
      (is (= 1002 (refusal-code frame)) "RSV bit ~X" rsv))))

(test an-ordinary-frame-is-not-refused
  (is (null (refusal-code (ws:encode-frame ws:+text+ (ascii "x") :mask-key (o 0 0 0 0))))))

(test unknown-opcodes-are-refused-with-1002
  (dolist (opcode '(3 4 5 6 7 11 12 13 14 15))
    (is (= 1002 (refusal-code (o (logior #x80 opcode) #x80 0 0 0 0))) "opcode ~D" opcode)))

(test a-fragmented-control-frame-is-refused-with-1002
  (dolist (opcode (list ws:+close+ ws:+ping+ ws:+pong+))
    (is (= 1002 (refusal-code (o opcode #x80 0 0 0 0))) "opcode ~D with FIN clear" opcode)))

(test a-control-frame-over-125-octets-is-refused-with-1002
  ;; 126 octets, with the 16-bit length, and refused from the header alone.
  (is (= 1002 (refusal-code (o (logior #x80 ws:+ping+) (logior #x80 126) 0 126))))
  (is (= 1002 (refusal-code (o (logior #x80 ws:+close+) (logior #x80 127) 0 0 0 0 0 0 1 0))))
  (is (eq :incomplete (first (parse (o (logior #x80 ws:+ping+) (logior #x80 125)))))
      "125 octets is allowed, and waits for its payload"))

(test encode-frame-refuses-a-control-frame-the-peer-would-refuse
  (signals error (ws:encode-frame ws:+ping+ (make-array 126 :element-type '(unsigned-byte 8))))
  (signals error (ws:encode-frame ws:+close+ (o) :fin nil)))

(test a-64-bit-length-with-its-top-bit-set-is-refused-with-1002
  (is (= 1002 (refusal-code (o #x82 (logior #x80 127) #x80 0 0 0 0 0 0 0)))))

(test a-length-not-in-its-shortest-form-is-refused-with-1002
  (is (= 1002 (refusal-code (o #x82 (logior #x80 126) 0 125))) "125 in 16 bits")
  (is (= 1002 (refusal-code (o #x82 (logior #x80 127) 0 0 0 0 0 0 #xFF #xFF))) "65535 in 64 bits")
  (is (eq :incomplete (first (parse (o #x82 (logior #x80 126) 0 126))))
      "126 in 16 bits is its shortest form"))

(test an-oversized-length-is-refused-with-1009-before-the-payload-arrives
  ;; The control for the limit is in the server-uv suite, end to end; here the point is
  ;; that the header alone is enough to refuse, so a peer cannot make the server buffer a
  ;; length it then refuses.
  (is (= 1009 (refusal-code (o #x82 (logior #x80 127) 0 0 0 1 0 0 0 0) :max-payload 1024))
      "a 4 GiB length, against a 1 KiB limit, from ten octets")
  (is (= 1009 (refusal-code (o #x82 (logior #x80 126) 4 1) :max-payload 1024))
      "1025 octets against 1024")
  (is (eq :incomplete (first (parse (o #x82 (logior #x80 126) 4 0) :max-payload 1024)))
      "exactly the limit is allowed"))

(test the-largest-64-bit-length-is-refused-without-allocating-it
  (is (= 1009 (refusal-code (o #x82 (logior #x80 127) #x7F #xFF #xFF #xFF #xFF #xFF #xFF #xFF)
                            :max-payload (* 64 1024 1024)))))

;;; --- refusals: messages -----------------------------------------------------------

(defun frame* (opcode payload &key (fin t))
  (ws::make-frame fin opcode payload))

(defun assemble* (asm frame)
  (multiple-value-list (ws:assemble asm frame)))

(test a-continuation-with-nothing-to-continue-is-refused-with-1002
  (is (equal (list :error 1002) (subseq (assemble* (ws:make-assembler)
                                                   (frame* ws:+continuation+ (ascii "x")))
                                        0 2))))

(test a-new-message-inside-a-fragmented-one-is-refused-with-1002
  (let ((asm (ws:make-assembler)))
    (is (eq :none (first (assemble* asm (frame* ws:+text+ (ascii "a") :fin nil)))))
    (is (equal (list :error 1002)
               (subseq (assemble* asm (frame* ws:+binary+ (ascii "b"))) 0 2)))))

(test a-ping-between-fragments-is-answered-and-the-message-still-completes
  (let ((asm (ws:make-assembler)))
    (is (eq :none (first (assemble* asm (frame* ws:+text+ (ascii "He") :fin nil)))))
    (is (eq :ping (first (assemble* asm (frame* ws:+ping+ (ascii "p"))))))
    (is (equal '(:text "Hello") (assemble* asm (frame* ws:+continuation+ (ascii "llo")))))))

(test a-message-over-the-limit-across-fragments-is-refused-with-1009
  (let ((asm (ws:make-assembler :max-message-octets 4)))
    (is (eq :none (first (assemble* asm (frame* ws:+binary+ (o 1 2 3) :fin nil)))))
    (is (equal (list :error 1009)
               (subseq (assemble* asm (frame* ws:+continuation+ (o 4 5) :fin nil)) 0 2))))
  (let ((asm (ws:make-assembler :max-message-octets 4)))
    (is (eq :none (first (assemble* asm (frame* ws:+binary+ (o 1 2) :fin nil)))))
    (is (equalp (list :binary (o 1 2 3 4))
                (assemble* asm (frame* ws:+continuation+ (o 3 4)))) "exactly the limit")))

(test invalid-utf-8-in-a-text-message-is-refused-with-1007
  (dolist (bad (list (o #xC0 #x80)            ; overlong NUL
                     (o #xED #xA0 #x80)       ; a surrogate
                     (o #xF4 #x90 #x80 #x80)  ; above U+10FFFF
                     (o #xE2 #x82)            ; cut short
                     (o #xFF)
                     (o #x80)))
    (is (equal (list :error 1007)
               (subseq (assemble* (ws:make-assembler) (frame* ws:+text+ bad)) 0 2))
        "~S" bad))
  (is (eq :binary (first (assemble* (ws:make-assembler) (frame* ws:+binary+ (o #xFF)))))
      "a binary message is not text, so any octets are allowed"))

(test utf-8-split-across-fragments-is-accepted
  ;; U+20AC, the euro sign, is E2 82 AC; a fragment boundary inside it is legal.
  (let ((asm (ws:make-assembler)))
    (is (eq :none (first (assemble* asm (frame* ws:+text+ (o #xE2 #x82) :fin nil)))))
    (is (equal (list :text (string (code-char #x20AC)))
               (assemble* asm (frame* ws:+continuation+ (o #xAC))))))
  (is-true (ws:utf8-valid-p (o #xF0 #x9F #x98 #x80)) "four octets, U+1F600")
  (is-true (ws:utf8-valid-p (o #xEF #xBF #xBF)) "U+FFFF"))

;;; --- close frames -----------------------------------------------------------

(test close-payloads
  (is (equal '(:close 1005 "") (multiple-value-list (ws:parse-close-payload (o)))))
  (is (equal '(:close 1000 "bye")
             (multiple-value-list (ws:parse-close-payload (ws:encode-close-payload 1000 "bye")))))
  (is (= 1002 (second (multiple-value-list (ws:parse-close-payload (o 3))))) "one octet")
  (dolist (code '(0 999 1004 1005 1006 1015 1016 2999 5000))
    (is (= 1002 (second (multiple-value-list
                         (ws:parse-close-payload (o (ldb (byte 8 8) code) (ldb (byte 8 0) code))))))
        "code ~D" code))
  (is (= 1007 (second (multiple-value-list (ws:parse-close-payload (o 3 232 #xFF)))))
      "a reason that is not UTF-8")
  (signals error (ws:encode-close-payload 1006))
  (signals error (ws:encode-close-payload 1000 (make-string 124 :initial-element #\a))))

;;; --- the handshake ------------------------------------------------------------

(test rfc-example-accept-key
  "RFC 6455 section 1.3."
  (is (string= "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" (ws:accept-key "dGhlIHNhbXBsZSBub25jZQ=="))))

(test sha1-matches-rfc-3174-and-ironclad
  (is (string= "a9993e364706816aba3e25717850c26c9cd0d89d"
               (ironclad:byte-array-to-hex-string (ws:sha1 (ascii "abc")))))
  (is (string= "84983e441c3bd26ebaae4aa1f95129e5e54670f1"
               (ironclad:byte-array-to-hex-string
                (ws:sha1 (ascii "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")))))
  ;; Every length from 0 to 200 crosses each padding boundary; ironclad is the comparison.
  (loop for n from 0 to 200
        for input = (let ((v (make-array n :element-type '(unsigned-byte 8))))
                      (dotimes (i n v) (setf (aref v i) (mod (* 31 i) 256))))
        do (is (equalp (ironclad:digest-sequence :sha1 input) (ws:sha1 input)) "length ~D" n)))

(test base64-matches-cl-base64-both-ways
  (loop for n from 0 to 40
        for input = (let ((v (make-array n :element-type '(unsigned-byte 8))))
                      (dotimes (i n v) (setf (aref v i) (mod (* 97 (1+ i)) 256))))
        for text = (cl-base64:usb8-array-to-base64-string input)
        do (is (string= text (ws:base64-encode input)) "encode, length ~D" n)
           (when (plusp n)
             (is (equalp input (ws:base64-decode text)) "decode, length ~D" n))))

(test base64-decode-refuses-text-that-is-not-canonical
  (dolist (bad '("" "abc" "ab=c" "a===" "ab$=" "AB==" "dGhlIHNhbXBsZSBub25jZR=="))
    (is (null (ws:base64-decode bad)) "~S" bad))
  (is (equalp (o 0) (ws:base64-decode "AA==")) "control: canonical"))

(defun headers (&rest plist)
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on plist by #'cddr do (setf (gethash k h) v))
    h))

(defun good-headers (&rest overrides)
  (let ((h (headers "host" "example.com" "upgrade" "websocket" "connection" "Upgrade"
                    "sec-websocket-key" "dGhlIHNhbXBsZSBub25jZQ==" "sec-websocket-version" "13")))
    (loop for (k v) on overrides by #'cddr
          do (if v (setf (gethash k h) v) (remhash k h)))
    h))

(defun check (&key (method :get) (protocol :http/1.1) (headers (good-headers)))
  (multiple-value-list (ws:check-handshake method protocol headers)))

(test a-good-handshake-is-accepted
  (is (equal '(:accept "dGhlIHNhbXBsZSBub25jZQ==") (check)))
  (is (eq :accept (first (check :headers (good-headers "upgrade" "WebSocket"
                                                       "connection" "keep-alive, Upgrade"))))
      "tokens are compared without case, and Connection may name others"))

(test bad-handshakes-are-refused-with-the-right-status
  (is (equal '(:refuse 400) (subseq (check :method :post) 0 2)))
  (is (equal '(:refuse 400) (subseq (check :protocol :http/1.0) 0 2)))
  (is (equal '(:refuse 400) (subseq (check :headers (good-headers "host" nil)) 0 2)))
  (is (equal '(:refuse 426) (subseq (check :headers (good-headers "upgrade" "h2c")) 0 2)))
  (is (equal '(:refuse 400) (subseq (check :headers (good-headers "connection" "keep-alive")) 0 2)))
  (is (equal '(:refuse 400) (subseq (check :headers (good-headers "sec-websocket-key" nil)) 0 2)))
  (is (equal '(:refuse 400) (subseq (check :headers (good-headers "sec-websocket-key" "c2hvcnQ=")) 0 2))
      "a key that is not 16 octets")
  (let ((r (check :headers (good-headers "sec-websocket-version" "8"))))
    (is (equal '(:refuse 426) (subseq r 0 2)))
    (is (equal "13" (getf (fourth r) :sec-websocket-version))
        "426 names the version the server speaks (section 4.4)")))

(test offered-protocols-are-read-in-the-client-s-order
  (is (equal '("chat" "superchat")
             (ws:offered-protocols (headers "sec-websocket-protocol" "chat, superchat"))))
  (is (null (ws:offered-protocols (headers)))))

;;; --- the client's half of the handshake (#1028) ---------------------------------
;;;
;;; RFC 6455 section 1.3's example: the nonce "the sample nonce", whose base64 is the key
;;; dGhlIHNhbXBsZSBub25jZQ==, and the accept value s3pPLMBiTxaQ9kYGzzhZRbK+xOo=.

(defparameter +rfc-nonce+ (ascii "the sample nonce"))
(defparameter +rfc-key+ "dGhlIHNhbXBsZSBub25jZQ==")

(defun crlf (&rest lines)
  "LINES joined, each ended with CR LF."
  (with-output-to-string (s)
    (dolist (l lines) (write-string l s) (write-char #\Return s) (write-char #\Newline s))))

(defun split-request (head)
  "HEAD, a request head as text, as (values method protocol headers), read here rather than
with anything in aion/websocket, so the server's check reads a request the client's code did
not also parse."
  (let* ((lines (loop with at = 0
                      for i = (search (crlf "") head :start2 at)
                      while (and i (> i at))
                      collect (subseq head at i)
                      do (setf at (+ i 2))))
         (request-line (first lines))
         (h (make-hash-table :test #'equal)))
    (dolist (l (rest lines))
      (let ((colon (position #\: l)))
        (setf (gethash (string-downcase (subseq l 0 colon)) h)
              (string-trim " " (subseq l (1+ colon))))))
    (values (if (string= "GET " request-line :end2 4) :get :other)
            (if (search " HTTP/1.1" request-line) :http/1.1 :other)
            h)))

(test client-key-is-the-nonce-in-base64
  (is (equal +rfc-key+ (ws:client-key +rfc-nonce+)))
  (is (= 24 (length (ws:client-key (make-array 16 :element-type '(unsigned-byte 8)
                                                  :initial-element 255)))))
  (signals error (ws:client-key (subseq +rfc-nonce+ 0 15)) "15 octets")
  (signals error (ws:client-key (coerce +rfc-nonce+ 'list)) "a list, not a vector of octets"))

(test client-request-head-is-the-rfc-request
  (is (equal (crlf "GET /chat HTTP/1.1"
                   "Host: server.example.com"
                   "Upgrade: websocket"
                   "Connection: Upgrade"
                   "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="
                   "Sec-WebSocket-Version: 13"
                   "Sec-WebSocket-Protocol: chat, superchat"
                   "Origin: http://example.com"
                   "")
             (ws:client-request-head "server.example.com" "/chat" +rfc-key+
                                     :protocols '("chat" "superchat")
                                     :origin "http://example.com"))))

(test the-server-s-check-accepts-the-client-s-request
  (multiple-value-bind (method protocol headers)
      (split-request (ws:client-request-head "127.0.0.1:9222" "/devtools/browser/abc"
                                             (ws:client-key +rfc-nonce+)))
    (is (equal (list :accept +rfc-key+)
               (multiple-value-list (ws:check-handshake method protocol headers))))
    (is (null (gethash "origin" headers)) "no Origin unless one is given")
    (is (null (gethash "sec-websocket-protocol" headers)) "no protocols unless offered")))

(test client-request-head-refuses-values-that-would-add-headers
  (signals error (ws:client-request-head (format nil "a~C~CX-Evil: 1" #\Return #\Newline)
                                         "/" +rfc-key+))
  (signals error (ws:client-request-head "a" (format nil "/~Cx" #\Newline) +rfc-key+))
  (signals error (ws:client-request-head "a" "/" +rfc-key+
                                         :origin (format nil "o~Cx" #\Return)))
  (signals error (ws:client-request-head "a" "/" +rfc-key+
                                         :protocols (list (format nil "p~Cx" #\Newline))))
  (signals error (ws:client-request-head "a" "chat" +rfc-key+) "a target must start with /")
  (signals error (ws:client-request-head "a" "" +rfc-key+) "an empty target"))

(defparameter +rfc-response+
  (crlf "HTTP/1.1 101 Switching Protocols"
        "Upgrade: websocket"
        "Connection: Upgrade"
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        ""))

(defun parse-head (text &rest keys)
  (multiple-value-list (apply #'ws:parse-response-head (ascii text) keys)))

(test parse-response-head-reads-the-rfc-response
  (destructuring-bind (outcome status headers next) (parse-head +rfc-response+)
    (is (eq :head outcome))
    (is (= 101 status))
    (is (equal "websocket" (gethash "upgrade" headers)))
    (is (equal "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" (gethash "sec-websocket-accept" headers)))
    (is (= (length +rfc-response+) next))))

(test parse-response-head-waits-for-the-end-of-the-head
  (loop for cut from 0 below (length +rfc-response+)
        do (is (equal '(:incomplete) (parse-head (subseq +rfc-response+ 0 cut)))
               "cut at ~D" cut)))

(test parse-response-head-leaves-a-frame-after-the-head-in-place
  (let* ((octets (concatenate '(vector (unsigned-byte 8))
                              (ascii +rfc-response+) (o #x81 #x02 #x68 #x69)))
         (r (multiple-value-list (ws:parse-response-head octets))))
    (is (= (length +rfc-response+) (fourth r)))
    (is (equal "hi" (ws:decode-utf8 (ws:frame-payload
                                      (second (multiple-value-list
                                               (ws:parse-frame octets :start (fourth r)
                                                                      :masked nil)))))))))

(test parse-response-head-joins-repeated-headers-and-lowercases-names
  (let ((headers (third (parse-head (crlf "HTTP/1.1 101 OK" "X-A: 1" "x-a:2" "CONNECTION: up"
                                          "")))))
    (is (equal "1, 2" (gethash "x-a" headers)))
    (is (equal "up" (gethash "connection" headers)))))

(test parse-response-head-refuses-what-is-not-an-http-1.1-head
  (is (eq :error (first (parse-head (crlf "HTTP/1.0 101 OK" "")))))
  (is (eq :error (first (parse-head (crlf "HTTP/1.1 1O1 OK" "")))))
  (is (eq :error (first (parse-head (crlf "HTTP/1.1 1011 OK" "")))))
  (is (eq :error (first (parse-head (crlf "HTTP/1.1 101 OK" "no colon here" "")))))
  (is (eq :error (first (parse-head (crlf "HTTP/1.1 101 OK" ": empty name" "")))))
  (is (eq :error (first (parse-head (crlf "HTTP/1.1 101 OK" "Bad Name: x" "")))))
  (is (eq :error (first (parse-head (crlf "HTTP/1.1 101 OK"
                                          (format nil "X-A: 1~CX-B: 2" #\Newline) ""))))
      "a bare LF inside a header line")
  (is (eq :error (first (parse-head (crlf "HTTP/1.1 101 OK"
                                          (format nil "N~C: x" (code-char 233)) ""))))
      "a header name outside ASCII"))

(test parse-response-head-refuses-a-head-over-the-limit
  (let ((long (make-string ws:max-response-head-octets :initial-element #\a)))
    (is (eq :error (first (parse-head (concatenate 'string "HTTP/1.1 101 OK" long))))
        "no end in sight, and already past the limit")
    (is (eq :error (first (parse-head (crlf "HTTP/1.1 101 OK" (concatenate 'string "X: " long)
                                            ""))))
        "an end, but after the limit")))

(defun server-check (text &rest keys)
  (destructuring-bind (outcome status headers next) (parse-head text)
    (declare (ignore next))
    (assert (eq outcome :head))
    (multiple-value-list (apply #'ws:check-server-handshake status headers +rfc-key+ keys))))

(defun rfc-response-with (&rest lines)
  (apply #'crlf "HTTP/1.1 101 Switching Protocols" (append lines '(""))))

(defparameter +good-response-lines+
  '("Upgrade: websocket" "Connection: Upgrade" "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))

(test the-rfc-response-is-accepted
  (is (equal '(:accept nil) (server-check +rfc-response+)))
  (is (equal '(:accept "chat")
             (apply #'server-check
                    (apply #'rfc-response-with
                           (append +good-response-lines+ '("Sec-WebSocket-Protocol: chat")))
                    '(:protocols ("superchat" "chat"))))))

(test bad-server-responses-are-refused
  (flet ((refused (text &optional protocols)
           (is (eq :refuse (first (server-check text :protocols protocols))) "~A" text)))
    (refused (crlf "HTTP/1.1 200 OK" ""))
    (refused (crlf "HTTP/1.1 403 Forbidden" ""))
    (refused (rfc-response-with "Connection: Upgrade"
                                "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
    (refused (rfc-response-with "Upgrade: websocket"
                                "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
    (refused (rfc-response-with "Upgrade: websocket" "Connection: Upgrade"))
    (refused (rfc-response-with "Upgrade: websocket" "Connection: Upgrade"
                                ;; an accept value for another key
                                "Sec-WebSocket-Accept: AAAAAAAAAAAAAAAAAAAAAAAAAAA="))
    (refused (apply #'rfc-response-with
                    (append +good-response-lines+
                            ;; an extension the client did not offer
                            '("Sec-WebSocket-Extensions: permessage-deflate"))))
    (refused (apply #'rfc-response-with
                    (append +good-response-lines+ '("Sec-WebSocket-Protocol: chat"))))
    (refused (apply #'rfc-response-with
                    (append +good-response-lines+ '("Sec-WebSocket-Protocol: chat")))
             '("superchat"))
    (refused (apply #'rfc-response-with
                    (append +good-response-lines+ '("Sec-WebSocket-Protocol: chat, superchat")))
             '("chat" "superchat"))))
