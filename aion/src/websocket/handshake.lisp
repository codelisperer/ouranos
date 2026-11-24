;;;; handshake.lisp --- the WebSocket opening handshake (RFC 6455 section 4.2), pure (#376).
;;;;
;;;; SHA-1 and base64 are written here rather than taken from ironclad and cl-base64. The
;;;; handshake needs one digest of a 60-character string per connection, SHA-1 is not used
;;;; for security in it (section 10.3 explains the value only proves the server read the
;;;; key), and depending on nothing keeps this system loadable in every gate run as
;;;; hyperion/http1 is. The suite checks both against ironclad and cl-base64, so the two
;;;; implementations are compared, not only tested against vectors this file's author chose.

(cl:in-package #:aion/websocket)

;;; --- SHA-1 (RFC 3174) ---------------------------------------------------------

(defun sha1 (octets)
  "The SHA-1 digest of OCTETS, as 20 octets."
  (let* ((n (length octets))
         (padded (* 64 (ceiling (+ n 9) 64)))
         (message (%octets padded))
         (bits (* 8 n))
         (w (make-array 80 :element-type '(unsigned-byte 32)))
         (h0 #x67452301) (h1 #xEFCDAB89) (h2 #x98BADCFE) (h3 #x10325476) (h4 #xC3D2E1F0))
    (replace message octets)
    (setf (aref message n) #x80)
    (dotimes (i 8)
      (setf (aref message (- padded 1 i)) (ldb (byte 8 (* 8 i)) bits)))
    (flet ((rotl (x k) (logand #xFFFFFFFF (logior (ash x k) (ash x (- k 32)))))
           (add (&rest xs) (logand #xFFFFFFFF (reduce #'+ xs))))
      (loop for block from 0 below padded by 64
            do (dotimes (i 16)
                 (setf (aref w i) (%be message (+ block (* 4 i)) 4)))
               (loop for i from 16 below 80
                     do (setf (aref w i)
                              (rotl (logxor (aref w (- i 3)) (aref w (- i 8))
                                            (aref w (- i 14)) (aref w (- i 16)))
                                    1)))
               (let ((a h0) (b h1) (c h2) (d h3) (e h4))
                 (dotimes (i 80)
                   (multiple-value-bind (f k)
                       (cond ((< i 20) (values (logior (logand b c)
                                                       (logand (logxor b #xFFFFFFFF) d))
                                               #x5A827999))
                             ((< i 40) (values (logxor b c d) #x6ED9EBA1))
                             ((< i 60) (values (logior (logand b c) (logand b d) (logand c d))
                                               #x8F1BBCDC))
                             (t (values (logxor b c d) #xCA62C1D6)))
                     (let ((temp (add (rotl a 5) f e k (aref w i))))
                       (setf e d
                             d c
                             c (rotl b 30)
                             b a
                             a temp))))
                 (setf h0 (add h0 a) h1 (add h1 b) h2 (add h2 c) h3 (add h3 d) h4 (add h4 e)))))
    (let ((out (%octets 20)))
      (loop for h in (list h0 h1 h2 h3 h4)
            for at from 0 by 4
            do (dotimes (i 4)
                 (setf (aref out (+ at i)) (ldb (byte 8 (* 8 (- 3 i))) h))))
      out)))

;;; --- base64 (RFC 4648 section 4, with padding) ---------------------------------

(defparameter +base64-alphabet+
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(defun base64-encode (octets)
  "OCTETS as base64 text, padded with = to a multiple of four characters."
  (let ((n (length octets)))
    (with-output-to-string (s)
      (loop for i from 0 below n by 3
            do (let* ((count (min 3 (- n i)))
                      (group (logior (ash (aref octets i) 16)
                                     (if (> count 1) (ash (aref octets (+ i 1)) 8) 0)
                                     (if (> count 2) (aref octets (+ i 2)) 0))))
                 (dotimes (j 4)
                   (write-char (if (<= j count)
                                   (char +base64-alphabet+ (ldb (byte 6 (* 6 (- 3 j))) group))
                                   #\=)
                               s)))))))

(defun base64-decode (text)
  "TEXT as octets, or NIL when it is not canonical padded base64: a length that is not a
multiple of four, a character outside the alphabet, padding anywhere but the end, or bits
after the last octet that are not zero."
  (let ((n (length text)))
    (when (and (plusp n) (zerop (mod n 4)))
      (let* ((pad (cond ((and (char= (char text (- n 1)) #\=) (char= (char text (- n 2)) #\=)) 2)
                        ((char= (char text (- n 1)) #\=) 1)
                        (t 0)))
             (out (%octets (- (* 3 (/ n 4)) pad)))
             (at 0))
        (loop for i from 0 below n by 4
              do (let ((group 0))
                   (dotimes (j 4)
                     (let* ((c (char text (+ i j)))
                            (v (position c +base64-alphabet+)))
                       (cond (v (setf group (logior (ash group 6) v)))
                             ((and (char= c #\=) (>= (+ i j) (- n pad)))
                              (setf group (ash group 6)))
                             (t (return-from base64-decode nil)))))
                   (dotimes (j 3)
                     (when (< at (length out))
                       (setf (aref out at) (ldb (byte 8 (* 8 (- 2 j))) group))
                       (incf at)))
                   ;; The bits a padded group carries past its last octet must be zero, or two
                   ;; different texts would decode to the same octets.
                   (when (and (= i (- n 4)) (plusp pad)
                              (not (zerop (ldb (byte (* 8 pad) 0) group))))
                     (return-from base64-decode nil))))
        out))))

;;; --- the handshake --------------------------------------------------------------

(defparameter +accept-guid+ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  "The GUID RFC 6455 section 1.3 appends to the client's key before hashing it.")

(defun accept-key (key)
  "The Sec-WebSocket-Accept value for the client's Sec-WebSocket-Key KEY: the base64 of the
SHA-1 of KEY followed by +ACCEPT-GUID+."
  (base64-encode (sha1 (sb-ext:string-to-octets (concatenate 'string key +accept-guid+)
                                                :external-format :latin-1))))

(defun %tokens (value)
  "VALUE, a comma-separated header value, as its trimmed, non-empty elements."
  (let ((out '()) (start 0))
    (loop for comma = (position #\, value :start start)
          do (let ((token (string-trim '(#\Space #\Tab) (subseq value start (or comma (length value))))))
               (when (plusp (length token)) (push token out)))
             (if comma (setf start (1+ comma)) (return)))
    (nreverse out)))

(defun header-has-token-p (value token)
  "Whether VALUE, a comma-separated header value, has TOKEN among its elements, compared
without regard to case. NIL for a NIL VALUE."
  (and value (member token (%tokens value) :test #'string-equal) t))

(defun offered-protocols (headers)
  "The subprotocols the client offered in Sec-WebSocket-Protocol, in its order of preference.
HEADERS is a hash table with lowercased names, as the Ring env's :HEADERS is."
  (let ((value (gethash "sec-websocket-protocol" headers)))
    (and value (%tokens value))))

(defun check-handshake (method protocol headers)
  "Check a client's opening handshake (RFC 6455 section 4.2.1).

METHOD is the request method as a keyword (:GET), PROTOCOL the HTTP version as a keyword
(:HTTP/1.1), HEADERS a hash table with lowercased names. Returns (values :ACCEPT key) with
the client's Sec-WebSocket-Key, or (values :REFUSE status reason headers), where HEADERS is a
plist of the headers the refusal must carry: a 426 names the version or the protocol the
server speaks, as section 4.4 and RFC 9110 section 15.5.22 require."
  (flet ((refuse (status reason &rest headers)
           (return-from check-handshake (values :refuse status reason headers))))
    (unless (eq method :get)
      (refuse 400 "a WebSocket handshake must be a GET request"))
    (unless (eq protocol :http/1.1)
      (refuse 400 "a WebSocket handshake must be HTTP/1.1"))
    (unless (gethash "host" headers)
      (refuse 400 "the handshake has no Host header"))
    (unless (header-has-token-p (gethash "upgrade" headers) "websocket")
      (refuse 426 "the request does not ask to upgrade to websocket"
              :upgrade "websocket" :sec-websocket-version "13"))
    (unless (header-has-token-p (gethash "connection" headers) "upgrade")
      (refuse 400 "the Connection header does not name upgrade"))
    (let ((version (gethash "sec-websocket-version" headers)))
      (unless (and version (string= (string-trim '(#\Space #\Tab) version) "13"))
        (refuse 426 "Sec-WebSocket-Version is not 13" :sec-websocket-version "13")))
    (let* ((key (gethash "sec-websocket-key" headers))
           (trimmed (and key (string-trim '(#\Space #\Tab) key)))
           (decoded (and trimmed (base64-decode trimmed))))
      (unless (and decoded (= 16 (length decoded)))
        (refuse 400 "Sec-WebSocket-Key is not 16 octets in base64"))
      (values :accept trimmed))))

;;; --- the client's half of the handshake (RFC 6455 section 4.1, #1028) -------------
;;;
;;; aion/cdp is a WebSocket client, so this system gained the client's side when it moved
;;; from hyperion. It stays pure and depends on nothing: the 16 random octets of the key are
;;; the caller's to supply (aion/cdp takes them from aion/random), and the socket is the
;;; caller's too.

(defun client-key (nonce)
  "The Sec-WebSocket-Key a client sends: NONCE, 16 random octets, in base64 (RFC 6455
section 4.1). The caller supplies the octets from a secure random source, because this
system depends on nothing. Signals an error unless NONCE is a vector of 16 octets."
  (unless (and (typep nonce '(vector (unsigned-byte 8))) (= 16 (length nonce)))
    (error "A Sec-WebSocket-Key nonce is 16 octets; got ~S." nonce))
  (base64-encode nonce))

(defun %check-header-text (what text)
  (when (find-if (lambda (c) (or (char= c #\Return) (char= c #\Newline)
                                 (> (char-code c) 255)))
                 text)
    (error "The ~A of a WebSocket request may not contain CR, LF or a character above 255: ~S"
           what text))
  text)

(defun client-request-head (host path key &key protocols origin)
  "The opening request a client sends, as a string: the request line, the headers, and the
empty line that ends the head, each line ended with CR LF.

HOST is the Host header's value, with the port when it is not the scheme's default. PATH is
the request target, starting with /. KEY comes from CLIENT-KEY. PROTOCOLS is a list of
subprotocol names to offer, in order of preference. ORIGIN is sent when given; a client that
is not a browser need not send one. A value containing CR, LF or a character above 255 is a
mistake by the caller and signals an error, because it would let the value add headers."
  (%check-header-text "host" host)
  (%check-header-text "path" path)
  (%check-header-text "key" key)
  (unless (and (plusp (length path)) (char= (char path 0) #\/))
    (error "A WebSocket request target starts with /: ~S" path))
  (when origin (%check-header-text "origin" origin))
  (dolist (p protocols) (%check-header-text "protocol" p))
  (with-output-to-string (s)
    (flet ((line (&rest parts)
             (dolist (p parts) (write-string p s))
             (write-char #\Return s) (write-char #\Newline s)))
      (line "GET " path " HTTP/1.1")
      (line "Host: " host)
      (line "Upgrade: websocket")
      (line "Connection: Upgrade")
      (line "Sec-WebSocket-Key: " key)
      (line "Sec-WebSocket-Version: 13")
      (when protocols
        (line "Sec-WebSocket-Protocol: "
              (format nil "~{~A~^, ~}" protocols)))
      (when origin (line "Origin: " origin))
      (line))))

(defconstant max-response-head-octets 16384
  "The longest response head PARSE-RESPONSE-HEAD reads before refusing it.")

(defun %head-end (octets start end)
  "The index just after the first CR LF CR LF in OCTETS between START and END, or NIL."
  (loop for i from start to (- end 4)
        when (and (= (aref octets i) 13) (= (aref octets (+ i 1)) 10)
                  (= (aref octets (+ i 2)) 13) (= (aref octets (+ i 3)) 10))
          return (+ i 4)))

(defun %token-char-p (c)
  (or (and (< (char-code c) 128) (alphanumericp c)) (find c "!#$%&'*+-.^_`|~")))

(defun parse-response-head (octets &key (start 0) (end (length octets)))
  "Parse the server's answer to the opening request, from OCTETS between START and END.

Returns one of:
  (values :INCOMPLETE)                 the head has not ended yet
  (values :HEAD status headers next)   STATUS is the integer status code, HEADERS a hash
                                       table with lowercased names (repeated headers are
                                       joined with \", \"), NEXT the index just after the
                                       head, where the first frame may already begin
  (values :ERROR reason)               the octets are not an HTTP/1.1 response head, or the
                                       head is longer than MAX-RESPONSE-HEAD-OCTETS

Octets are read as ISO-8859-1, as HTTP heads are."
  (let ((head-end (%head-end octets start end)))
    (unless head-end
      (return-from parse-response-head
        (if (> (- end start) max-response-head-octets)
            (values :error "the response head is longer than the limit")
            :incomplete)))
    (when (> (- head-end start) max-response-head-octets)
      (return-from parse-response-head
        (values :error "the response head is longer than the limit")))
    (let* ((text (map 'string #'code-char (subseq octets start (- head-end 4))))
           (lines (loop with at = 0
                        for crlf = (search (coerce '(#\Return #\Newline) 'string) text :start2 at)
                        collect (subseq text at (or crlf (length text)))
                        while crlf
                        do (setf at (+ crlf 2))))
           (status-line (first lines))
           (headers (make-hash-table :test 'equal)))
      (flet ((fail (reason) (return-from parse-response-head (values :error reason))))
        (unless (and (>= (length status-line) 12)
                     (string= "HTTP/1.1 " status-line :end2 9)
                     (every #'digit-char-p (subseq status-line 9 12))
                     (or (= (length status-line) 12) (char= (char status-line 12) #\Space)))
          (fail "the status line is not HTTP/1.1 with a three-digit status"))
        (dolist (line (rest lines))
          (let ((colon (position #\: line)))
            (unless (and colon (plusp colon) (every #'%token-char-p (subseq line 0 colon)))
              (fail "a header line has no valid name"))
            (when (find #\Newline line)
              (fail "a header line contains a bare LF"))
            (let ((name (string-downcase (subseq line 0 colon)))
                  (value (string-trim '(#\Space #\Tab) (subseq line (1+ colon)))))
              (setf (gethash name headers)
                    (let ((old (gethash name headers)))
                      (if old (concatenate 'string old ", " value) value))))))
        (values :head (parse-integer status-line :start 9 :end 12) headers head-end)))))

(defun check-server-handshake (status headers key &key protocols)
  "Check the server's answer to a client's opening request (RFC 6455 section 4.1, the
client's checks on the response).

STATUS and HEADERS are what PARSE-RESPONSE-HEAD returned; KEY is the Sec-WebSocket-Key the
client sent; PROTOCOLS is the list of subprotocols it offered. Returns (values :ACCEPT
protocol), where PROTOCOL is the subprotocol the server chose or NIL, or (values :REFUSE
reason). The client must then close the connection without sending a frame."
  (flet ((refuse (reason) (return-from check-server-handshake (values :refuse reason))))
    (unless (= status 101)
      (refuse (format nil "the server answered ~D, not 101 Switching Protocols" status)))
    (unless (header-has-token-p (gethash "upgrade" headers) "websocket")
      (refuse "the response's Upgrade header does not name websocket"))
    (unless (header-has-token-p (gethash "connection" headers) "upgrade")
      (refuse "the response's Connection header does not name upgrade"))
    (let ((accept (gethash "sec-websocket-accept" headers)))
      (unless (and accept (string= (string-trim '(#\Space #\Tab) accept) (accept-key key)))
        (refuse "Sec-WebSocket-Accept is not the value for the key that was sent")))
    (when (gethash "sec-websocket-extensions" headers)
      (refuse "the server named an extension, and the client offered none"))
    (let* ((value (gethash "sec-websocket-protocol" headers))
           (chosen (and value (%tokens value))))
      (cond ((null value) (values :accept nil))
            ((and (= 1 (length chosen))
                  (member (first chosen) protocols :test #'string=))
             (values :accept (first chosen)))
            (t (refuse "the server chose a subprotocol the client did not offer"))))))
