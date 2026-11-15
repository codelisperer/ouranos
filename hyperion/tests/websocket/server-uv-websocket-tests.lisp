;;;; server-uv-websocket-tests.lisp --- WebSockets on server-uv, over real sockets (#376).
;;;;
;;;; Every check goes through a TCP socket to a running server. The client is written here and
;;;; is deliberately small: it masks what it sends, reads the server's frames with its own
;;;; decoder rather than with hyperion/websocket's parser, and can send frames a correct
;;;; client never would (unmasked, oversized, with a bad opcode), because the refusals are
;;;; what a stranger's frames test.

(cl:defpackage #:hyperion/server-uv/websocket/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:srv #:hyperion/server-uv)
                    (#:wsrv #:hyperion/server-uv/websocket)
                    (#:ws #:hyperion/websocket)
                    (#:sock #:sb-bsd-sockets)
                    (#:ports #:hyperion/test-ports))
  (:export #:run-tests
           ;; the minimal client, which hyperion/clack-handler-uv/tests also uses (#376)
           #:ws-connect #:client-head #:client-close #:with-client #:send-frame #:send-raw
           #:frame-octets #:read-frame #:close-payload #:close-code-of #:eof-p
           #:status-of #:header-of #:utf8 #:octets #:wait-until))

(in-package #:hyperion/server-uv/websocket/tests)

(def-suite server-uv-websocket :description "WebSockets on hyperion/server-uv (#376).")
(in-suite server-uv-websocket)

(defun run-tests ()
  "Run the suite; return T on success (for asdf:test-system)."
  (run! 'server-uv-websocket))

(defparameter +io-timeout+ 10)

(defparameter +crlf+ (coerce (list (code-char 13) (code-char 10)) 'string))

(defun octets (&rest bytes)
  (make-array (length bytes) :element-type '(unsigned-byte 8) :initial-contents bytes))

(defun latin1 (string) (sb-ext:string-to-octets string :external-format :latin-1))

(defun utf8 (string) (sb-ext:string-to-octets string :external-format :utf-8))

(defun wait-until (predicate &key (seconds +io-timeout+))
  "Call PREDICATE every 5 ms until it returns true or SECONDS have passed; its last value."
  (loop with deadline = (+ (get-internal-real-time) (* seconds internal-time-units-per-second))
        for result = (funcall predicate)
        until (or result (> (get-internal-real-time) deadline))
        do (sleep 0.005)
        finally (return result)))

;;; --- the server -------------------------------------------------------------

(defstruct (log* (:constructor make-log*))
  (lock (sb-thread:make-mutex :name "test log"))
  (entries '()))

(defun note (log entry)
  (sb-thread:with-mutex ((log*-lock log)) (push entry (log*-entries log))))

(defun entries (log)
  (sb-thread:with-mutex ((log*-lock log)) (reverse (log*-entries log))))

(defun find-entry (log kind)
  (find kind (entries log) :key #'first))

(defun echo-app (log &rest keys)
  "An app answering a WebSocket handshake on any path but /http, which gets a plain 200.
Messages are echoed, except \"close\", which makes the server start the close handshake with
code 4000, and \"boom\", which signals in the callback. Every callback is noted in LOG."
  (lambda (env)
    (if (string= (getf env :path-info) "/http")
        (list 200 '(:content-type "text/plain") '("plain"))
        (apply #'wsrv:websocket-response env
               :on-open (lambda (w) (note log (list :open w)))
               :on-message (lambda (w m)
                             (note log (list :message m))
                             (cond ((equal m "close")
                                    (wsrv:close-websocket w :code 4000 :reason "asked"))
                                   ((equal m "boom") (error "a callback that fails"))
                                   ((stringp m) (wsrv:send-text w m))
                                   (t (wsrv:send-binary w m))))
               :on-pong (lambda (w p) (declare (ignore w)) (note log (list :pong p)))
               :on-close (lambda (w code reason)
                           (declare (ignore w))
                           (note log (list :close code reason)))
               keys))))

(defmacro with-server ((port app &rest start-args) &body body)
  (let ((s (gensym "SERVER")))
    `(let ((,s (srv:start ,app :port 0 ,@start-args)))
       (unwind-protect (let ((,port (srv:server-port ,s))) ,@body)
         (srv:stop ,s)))))

;;; --- the client -------------------------------------------------------------

(defstruct (client (:constructor %make-client)) socket stream head)

(defparameter +key+ "dGhlIHNhbXBsZSBub25jZQ=="
  "RFC 6455 section 1.3's sample key, whose accept value the RFC gives.")

(defun handshake-text (&key (path "/") (key +key+) (version "13") extra (method "GET"))
  (with-output-to-string (s)
    (dolist (line (append (list (format nil "~A ~A HTTP/1.1" method path)
                                "Host: 127.0.0.1"
                                "Upgrade: websocket"
                                "Connection: Upgrade"
                                (format nil "Sec-WebSocket-Key: ~A" key))
                          (and version (list (format nil "Sec-WebSocket-Version: ~A" version)))
                          extra
                          (list "")))
      (write-string line s)
      (write-string +crlf+ s))))

(defun %read-head (stream)
  "Octets up to and including the blank line, as a Latin-1 string; NIL at end of stream."
  (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (loop
      (let ((b (read-byte stream nil nil)))
        (unless b (return nil))
        (vector-push-extend b out)
        (let ((n (fill-pointer out)))
          (when (and (>= n 4) (= 13 (aref out (- n 4))) (= 10 (aref out (- n 3)))
                     (= 13 (aref out (- n 2))) (= 10 (aref out (- n 1))))
            (return (sb-ext:octets-to-string (coerce out '(vector (unsigned-byte 8)))
                                             :external-format :latin-1))))))))

(defun status-of (head)
  (parse-integer head :start (1+ (position #\Space head)) :junk-allowed t))

(defun header-of (head name)
  (loop for start = 0 then (+ end 2)
        for end = (search +crlf+ head :start2 start)
        while end
        do (let* ((line (subseq head start end)) (c (position #\: line)))
             (when (and c (string-equal name (subseq line 0 c)))
               (return (string-trim " " (subseq line (1+ c))))))))

(defun ws-connect (port &rest keys &key then &allow-other-keys)
  "Open a connection to PORT, send a handshake built from KEYS, and read the response head.
THEN, octets, is written in the same write as the handshake."
  (let ((s (make-instance 'sock:inet-socket :type :stream :protocol :tcp)))
    (handler-bind ((error (lambda (e) (declare (ignore e)) (ignore-errors (sock:socket-close s)))))
      (sock:socket-connect s #(127 0 0 1) port)
      (let ((stream (sock:socket-make-stream s :input t :output t
                                               :element-type '(unsigned-byte 8))))
        (remf keys :then)
        (write-sequence (concatenate '(vector (unsigned-byte 8))
                                     (latin1 (apply #'handshake-text keys))
                                     (or then #()))
                        stream)
        (force-output stream)
        (%make-client :socket s :stream stream
                      :head (ports:with-deadline (+io-timeout+ "the handshake")
                              (%read-head stream)))))))

(defun client-close (c) (ignore-errors (sock:socket-close (client-socket c))))

(defmacro with-client ((c port &rest keys) &body body)
  `(let ((,c (ws-connect ,port ,@keys)))
     (unwind-protect (progn ,@body) (client-close ,c))))

(defun frame-octets (opcode payload &key (fin t) (mask t) (rsv 0) (key (octets 55 18 201 4))
                                         length)
  "A frame as a client sends it. LENGTH overrides the declared payload length, for a frame
that lies about its size."
  (let* ((n (or length (length payload)))
         (out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (vector-push-extend (logior (if fin #x80 0) (ash rsv 4) opcode) out)
    (let ((m (if mask #x80 0)))
      (cond ((< n 126) (vector-push-extend (logior m n) out))
            ((< n 65536) (vector-push-extend (logior m 126) out)
             (vector-push-extend (ldb (byte 8 8) n) out)
             (vector-push-extend (ldb (byte 8 0) n) out))
            (t (vector-push-extend (logior m 127) out)
               (loop for i from 7 downto 0 do (vector-push-extend (ldb (byte 8 (* 8 i)) n) out)))))
    (when mask (loop for b across key do (vector-push-extend b out)))
    (loop for b across payload
          for i from 0
          do (vector-push-extend (if mask (logxor b (aref key (mod i 4))) b) out))
    (coerce out '(simple-array (unsigned-byte 8) (*)))))

(defun send-raw (c octets)
  (write-sequence octets (client-stream c))
  (force-output (client-stream c)))

(defun send-frame (c opcode payload &rest keys)
  (send-raw c (apply #'frame-octets opcode payload keys)))

(defun close-payload (code &optional (reason ""))
  (concatenate '(vector (unsigned-byte 8))
               (octets (ldb (byte 8 8) code) (ldb (byte 8 0) code))
               (utf8 reason)))

(defun read-frame (c)
  "One frame from the server as (OPCODE PAYLOAD FIN MASKED), or NIL at end of stream. Its own
decoder, so a fault in hyperion/websocket's parser cannot hide one in the encoder."
  (ports:with-deadline (+io-timeout+ "a frame from the server")
    (let* ((s (client-stream c))
           (b0 (read-byte s nil nil)))
      (when b0
        (let* ((b1 (read-byte s))
               (n (ldb (byte 7 0) b1)))
          (setf n (case n
                    (126 (logior (ash (read-byte s) 8) (read-byte s)))
                    (127 (loop repeat 8 for v = (read-byte s) then (logior (ash v 8) (read-byte s))
                               finally (return v)))
                    (t n)))
          (let ((payload (make-array n :element-type '(unsigned-byte 8))))
            (read-sequence payload s)
            (list (ldb (byte 4 0) b0) payload (logbitp 7 b0) (logbitp 7 b1))))))))

(defun read-message-frame (c)
  "The next frame that is not a ping, answering any ping on the way."
  (loop for f = (read-frame c)
        while (and f (= (first f) ws:+ping+))
        do (send-frame c ws:+pong+ (second f))
        finally (return f)))

(defun close-code-of (frame)
  (let ((p (second frame)))
    (and (>= (length p) 2) (logior (ash (aref p 0) 8) (aref p 1)))))

(defun eof-p (c)
  "Whether the server has closed the connection: the next read is the end of the stream."
  (ports:with-deadline (+io-timeout+ "the end of the stream")
    (null (handler-case (read-byte (client-stream c) nil nil)
            (error () nil)))))

(defun http-get (port path)
  "A plain HTTP GET on its own connection: the status, or NIL."
  (let ((s (make-instance 'sock:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (ports:with-deadline (+io-timeout+ path)
           (sock:socket-connect s #(127 0 0 1) port)
           (let ((stream (sock:socket-make-stream s :input t :output t
                                                    :element-type '(unsigned-byte 8))))
             (write-sequence (latin1 (format nil "GET ~A HTTP/1.1~AHost: x~AConnection: close~A~A"
                                             path +crlf+ +crlf+ +crlf+ +crlf+))
                             stream)
             (force-output stream)
             (let ((head (%read-head stream)))
               (and head (status-of head)))))
      (ignore-errors (sock:socket-close s)))))

;;; --- the handshake ------------------------------------------------------------

(test handshake-answers-101-with-the-rfc-accept-value
  (let ((log (make-log*)))
    (with-server (port (echo-app log) :workers 4)
      (with-client (c port)
        (let ((head (client-head c)))
          (is (= 101 (status-of head)))
          ;; RFC 6455 section 1.3 gives this value for the sample key.
          (is (equal "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" (header-of head "Sec-WebSocket-Accept")))
          (is (string-equal "websocket" (header-of head "Upgrade")))
          (is (string-equal "Upgrade" (header-of head "Connection")))
          (is (null (header-of head "Content-Length")))
          (is (null (header-of head "Sec-WebSocket-Protocol")))
          (is-true (wait-until (lambda () (find-entry log :open)))))))))

(test handshake-refusals
  (let ((log (make-log*)))
    (with-server (port (echo-app log) :workers 2)
      (with-client (c port :version "8")
        (is (= 426 (status-of (client-head c))))
        (is (equal "13" (header-of (client-head c) "Sec-WebSocket-Version"))))
      (with-client (c port :version nil)
        (is (= 426 (status-of (client-head c)))))
      (with-client (c port :key "short")
        (is (= 400 (status-of (client-head c)))))
      (with-client (c port :method "POST")
        (is (= 400 (status-of (client-head c)))))
      ;; A browser on another site: refused by the default origin check.
      (with-client (c port :extra '("Origin: http://evil.example"))
        (is (= 403 (status-of (client-head c)))))
      ;; The same origin as the Host header is accepted.
      (with-client (c port :extra '("Origin: http://127.0.0.1"))
        (is (= 101 (status-of (client-head c)))))
      (is (null (find-entry log :message))))))

(test origin-check-and-subprotocol-are-the-applications-to-set
  (let ((log (make-log*)))
    (with-server (port (echo-app log :check-origin (constantly t) :protocols '("chat" "v2"))
                       :workers 2)
      (with-client (c port :extra '("Origin: http://other.example"
                                    "Sec-WebSocket-Protocol: mqtt, v2, chat"))
        (is (= 101 (status-of (client-head c))))
        ;; The client's order of preference decides among the protocols both sides speak.
        (is (equal "v2" (header-of (client-head c) "Sec-WebSocket-Protocol"))))
      (with-client (c port :extra '("Sec-WebSocket-Protocol: mqtt"))
        (is (= 101 (status-of (client-head c))))
        (is (null (header-of (client-head c) "Sec-WebSocket-Protocol")))))))

(test same-origin-p-compares-host-and-port
  (flet ((env (host) (let ((h (make-hash-table :test #'equal)))
                       (setf (gethash "host" h) host)
                       (list :headers h))))
    (is-true (wsrv:same-origin-p nil (env "a.example")))
    (is-true (wsrv:same-origin-p "https://a.example" (env "a.example")))
    (is-true (wsrv:same-origin-p "https://A.example:443" (env "a.example")))
    (is-true (wsrv:same-origin-p "http://a.example:8080" (env "a.example:8080")))
    (is-false (wsrv:same-origin-p "http://a.example:8081" (env "a.example:8080")))
    (is-false (wsrv:same-origin-p "http://b.example" (env "a.example")))
    (is-false (wsrv:same-origin-p "null" (env "a.example")))))

;;; --- the conversation ----------------------------------------------------------

(test text-binary-ping-pong-and-a-clean-close
  (let ((log (make-log*)))
    (with-server (port (echo-app log) :workers 4)
      (with-client (c port)
        (is (= 101 (status-of (client-head c))))
        (send-frame c ws:+text+ (utf8 "héllo"))
        (let ((f (read-frame c)))
          (is (= ws:+text+ (first f)))
          (is (equal "héllo" (sb-ext:octets-to-string (second f) :external-format :utf-8)))
          (is-true (third f))
          (is-false (fourth f) "a server's frames are not masked"))
        (send-frame c ws:+binary+ (octets 0 1 2 255))
        (let ((f (read-frame c)))
          (is (= ws:+binary+ (first f)))
          (is (equalp (octets 0 1 2 255) (second f))))
        ;; A text message in three fragments, with a ping between two of them.
        (send-frame c ws:+text+ (utf8 "frag") :fin nil)
        (send-frame c ws:+continuation+ (utf8 "men") :fin nil)
        (send-frame c ws:+ping+ (utf8 "p1"))
        (send-frame c ws:+continuation+ (utf8 "ted"))
        (let ((pong (read-frame c)))
          (is (= ws:+pong+ (first pong)))
          (is (equalp (utf8 "p1") (second pong))))
        (let ((f (read-frame c)))
          (is (= ws:+text+ (first f)))
          (is (equal "fragmented" (sb-ext:octets-to-string (second f) :external-format :utf-8))))
        ;; The server pings; the client's pong reaches ON-PONG.
        (let ((w (second (find-entry log :open))))
          (wsrv:ping w (utf8 "srv"))
          (let ((f (read-frame c)))
            (is (= ws:+ping+ (first f)))
            (is (equalp (utf8 "srv") (second f)))
            (send-frame c ws:+pong+ (second f))))
        (is-true (wait-until (lambda () (find-entry log :pong))))
        (is (equalp (utf8 "srv") (second (find-entry log :pong))))
        ;; The client closes; the server answers with the same code and closes TCP.
        (send-frame c ws:+close+ (close-payload 1000 "bye"))
        (let ((f (read-frame c)))
          (is (= ws:+close+ (first f)))
          (is (= 1000 (close-code-of f))))
        (is-true (eof-p c))
        (is-true (wait-until (lambda () (find-entry log :close))))
        (is (equal '(:close 1000 "bye") (find-entry log :close)))
        (is (= 1 (count :close (entries log) :key #'first)))))))

(test frames-sent-with-the-handshake-are-read
  (let ((log (make-log*)))
    (with-server (port (echo-app log) :workers 2)
      (with-client (c port :then (frame-octets ws:+text+ (utf8 "early")))
        (is (= 101 (status-of (client-head c))))
        (let ((f (read-frame c)))
          (is (= ws:+text+ (first f)))
          (is (equalp (utf8 "early") (second f))))))))

(test the-server-starts-the-close-handshake
  (let ((log (make-log*)))
    (with-server (port (echo-app log) :workers 2)
      (with-client (c port)
        (send-frame c ws:+text+ (utf8 "close"))
        (let ((f (read-frame c)))
          (is (= ws:+close+ (first f)))
          (is (= 4000 (close-code-of f)))
          (is (equal "asked" (sb-ext:octets-to-string (subseq (second f) 2)
                                                      :external-format :utf-8))))
        (send-frame c ws:+close+ (close-payload 4000))
        (is-true (eof-p c))
        (is-true (wait-until (lambda () (find-entry log :close))))
        (is (equal '(:close 4000 "") (find-entry log :close)))))))

(test a-peer-that-does-not-answer-the-close-is-closed-after-the-timeout
  ;; SETF, not LET: the setting is read on a worker thread, which does not see a LET binding
  ;; made on this one.
  (let ((log (make-log*))
        (saved wsrv:*close-timeout-ms*))
    (setf wsrv:*close-timeout-ms* 200)
    (unwind-protect
         (with-server (port (echo-app log) :workers 2)
           (with-client (c port)
             (send-frame c ws:+text+ (utf8 "close"))
             (is (= ws:+close+ (first (read-frame c))))
             ;; No answer from the client: the server closes TCP on its own.
             (is-true (eof-p c))
             (is-true (wait-until (lambda () (find-entry log :close))))
             (is (= 1006 (second (find-entry log :close))))))
      (setf wsrv:*close-timeout-ms* saved))))

(test an-abrupt-disconnect-reports-1006
  (let ((log (make-log*)))
    (with-server (port (echo-app log) :workers 2)
      (let ((c (ws-connect port)))
        (is-true (wait-until (lambda () (find-entry log :open))))
        (client-close c))
      (is-true (wait-until (lambda () (find-entry log :close))))
      (is (equal '(:close 1006 "") (find-entry log :close))))))

(test a-callback-that-signals-closes-with-1011
  (let ((log (make-log*)))
    (with-server (port (echo-app log) :workers 2)
      (with-client (c port)
        (send-frame c ws:+text+ (utf8 "boom"))
        (let ((f (read-frame c)))
          (is (= ws:+close+ (first f)))
          (is (= 1011 (close-code-of f))))
        (is-true (eof-p c))))))

;;; --- refusals ----------------------------------------------------------------

(defun refusal (port &rest frames)
  "Send FRAMES (octet vectors) on a new WebSocket, and return the close code the server
answered with, or :NONE, and whether it then closed the connection."
  (with-client (c port)
    (dolist (f frames) (send-raw c f))
    (let ((f (read-frame c)))
      (list (if (and f (= ws:+close+ (first f))) (close-code-of f) :none)
            (eof-p c)))))

(test an-unmasked-frame-is-refused-with-1002
  (let ((log (make-log*)))
    (with-server (port (echo-app log) :workers 2)
      (is (equal '(1002 t) (refusal port (frame-octets ws:+text+ (utf8 "hi") :mask nil))))
      (is (null (find-entry log :message)) "the unmasked message is not delivered"))))

(test a-message-over-the-limit-is-refused-with-1009
  (let ((log (make-log*)))
    (with-server (port (echo-app log :max-message-octets 1000) :workers 2)
      ;; One frame over the limit, refused from its header: the payload is never sent.
      (is (equal '(1009 t) (refusal port (subseq (frame-octets ws:+binary+
                                                               (make-array 1001 :element-type '(unsigned-byte 8)))
                                                 0 8))))
      ;; Fragments that are each under the limit and together over it.
      (is (equal '(1009 t)
                 (refusal port
                          (frame-octets ws:+binary+ (make-array 600 :element-type '(unsigned-byte 8)
                                                                    :initial-element 1)
                                        :fin nil)
                          (frame-octets ws:+continuation+
                                        (make-array 600 :element-type '(unsigned-byte 8)
                                                        :initial-element 2)))))
      ;; At the limit is accepted.
      (with-client (c port)
        (send-frame c ws:+binary+ (make-array 1000 :element-type '(unsigned-byte 8)
                                                   :initial-element 7))
        (is (= 1000 (length (second (read-frame c))))))
      (is (= 1 (count :message (entries log) :key #'first))))))

(test the-default-message-limit-applies
  ;; SETF, not LET, for the reason given in the close-timeout test.
  (let ((log (make-log*))
        (saved wsrv:*max-message-octets*))
    (setf wsrv:*max-message-octets* 64)
    (unwind-protect
         (with-server (port (echo-app log) :workers 2)
           (is (equal '(1009 t) (refusal port (frame-octets ws:+text+
                                                            (make-array 65 :element-type '(unsigned-byte 8)
                                                                           :initial-element 97))))))
      (setf wsrv:*max-message-octets* saved))))

(test protocol-violations-are-refused
  (let ((log (make-log*)))
    (with-server (port (echo-app log) :workers 2)
      (is (equal '(1002 t) (refusal port (frame-octets 3 (utf8 "x"))))
          "a reserved opcode")
      (is (equal '(1002 t) (refusal port (frame-octets ws:+text+ (utf8 "x") :rsv 4)))
          "a reserved bit, with no extension negotiated")
      (is (equal '(1002 t) (refusal port (frame-octets ws:+ping+ (make-array 126 :element-type '(unsigned-byte 8)))))
          "a ping over 125 octets")
      (is (equal '(1002 t) (refusal port (frame-octets ws:+ping+ (utf8 "x") :fin nil)))
          "a fragmented ping")
      (is (equal '(1002 t) (refusal port (frame-octets ws:+continuation+ (utf8 "x"))))
          "a continuation with nothing to continue")
      (is (equal '(1007 t) (refusal port (frame-octets ws:+text+ (octets #xC0 #x80))))
          "an overlong UTF-8 encoding in a text message")
      (is (equal '(1007 t) (refusal port (frame-octets ws:+close+ (concatenate '(vector (unsigned-byte 8))
                                                                               (octets 3 232) (octets #xFF)))))
          "a close reason that is not UTF-8")
      (is (equal '(1002 t) (refusal port (frame-octets ws:+close+ (octets 3 237))))
          "close code 1005, which may not be sent")
      (is (equal '(1002 t) (refusal port (frame-octets ws:+binary+ #() :length (expt 2 63)))))
      (is (null (find-entry log :message))))))

;;; --- many sockets, threads, and backpressure -------------------------------------

(test many-open-websockets-do-not-stall-http
  ;; 200 open WebSockets on a server with 4 workers: an idle WebSocket holds no worker, so a
  ;; plain request is still answered at once, and every socket still works afterwards.
  (let ((log (make-log*))
        (clients '()))
    (with-server (port (echo-app log) :workers 4)
      (unwind-protect
           (progn
             (dotimes (i 200)
               (push (ws-connect port) clients))
             (is (every (lambda (c) (= 101 (status-of (client-head c)))) clients))
             (let ((start (get-internal-real-time)))
               (dotimes (i 20) (is (eql 200 (http-get port "/http"))))
               (is (< (/ (- (get-internal-real-time) start) internal-time-units-per-second) 5)))
             (loop for c in clients
                   for i from 0
                   do (send-frame c ws:+text+ (utf8 (format nil "m~D" i))))
             (is (loop for c in clients
                       for i from 0
                       always (equalp (utf8 (format nil "m~D" i)) (second (read-frame c))))))
        (mapc #'client-close clients))
      (is-true (wait-until (lambda () (= 200 (count :close (entries log) :key #'first)))))
      (is (eql 200 (http-get port "/http"))))))

(test a-busy-websocket-does-not-stall-http
  ;; One WebSocket's callbacks blocked on a worker: the other workers still answer HTTP.
  (let* ((log (make-log*))
         (gate (sb-thread:make-semaphore))
         (app (lambda (env)
                (if (string= (getf env :path-info) "/http")
                    (list 200 '(:content-type "text/plain") '("plain"))
                    (wsrv:websocket-response
                     env :on-message (lambda (w m)
                                       (declare (ignore w m))
                                       (note log '(:blocked))
                                       (sb-thread:wait-on-semaphore gate :timeout 20)))))))
    (with-server (port app :workers 4)
      (with-client (c port)
        (send-frame c ws:+text+ (utf8 "x"))
        (is-true (wait-until (lambda () (find-entry log :blocked))))
        (is (eql 200 (http-get port "/http")))
        (sb-thread:signal-semaphore gate)))))

(test sending-from-another-thread-and-a-large-message
  ;; The test thread is neither the loop nor a worker. Four MiB is more than the write
  ;; high-water mark, so the sender waits for the client to read rather than queueing it all.
  (let ((log (make-log*))
        (big (make-array (* 4 1024 1024) :element-type '(unsigned-byte 8))))
    (dotimes (i (length big)) (setf (aref big i) (mod (* i 7) 256)))
    (with-server (port (echo-app log) :workers 2)
      (with-client (c port)
        (is-true (wait-until (lambda () (find-entry log :open))))
        (let ((w (second (find-entry log :open))))
          (wsrv:send-text w "from the test thread")
          (is (equalp (utf8 "from the test thread") (second (read-frame c))))
          (let ((done nil))
            ;; The reader runs on the test thread; the sender on its own, because a sender
            ;; past the high-water mark waits for exactly this read.
            ;; INTERRUPTS: a test thread that sends one message and exits; nothing interrupts it.
            ;; THREAD-LIFETIME: joined below, with a timeout, before the test ends.
            (let ((sender (sb-thread:make-thread
                           (lambda () (wsrv:send-binary w big) (setf done t))
                           :name "websocket test sender")))
              (let ((f (read-frame c)))
                (is (= ws:+binary+ (first f)))
                (is (equalp big (second f))))
              (is-true (wait-until (lambda () done)))
              (sb-thread:join-thread sender :default nil :timeout +io-timeout+))))
        ;; After its close frame a WebSocket refuses to send.
        (let ((w (second (find-entry log :open))))
          (wsrv:close-websocket w)
          (signals wsrv:websocket-closed (wsrv:send-text w "late")))))))

(test under-the-inline-dispatcher-callbacks-run-on-the-loop
  ;; With no workers, events are delivered on the loop thread, as handlers are; the echo and
  ;; the close handshake still work, and a send there does not wait.
  (let ((log (make-log*)))
    (with-server (port (echo-app log) :loops 1)
      (with-client (c port)
        (is (= 101 (status-of (client-head c))))
        (send-frame c ws:+text+ (utf8 "inline"))
        (is (equalp (utf8 "inline") (second (read-frame c))))
        (send-frame c ws:+close+ (close-payload 1000))
        (is (= 1000 (close-code-of (read-frame c))))
        (is-true (eof-p c))
        (is-true (wait-until (lambda () (find-entry log :close))))))))
