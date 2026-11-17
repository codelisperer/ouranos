;;;; server-uv-websocket.lisp --- WebSockets on hyperion/server-uv (#376).
;;;;
;;;; A handler answers a WebSocket handshake by returning WEBSOCKET-RESPONSE. It checks the
;;;; request with hyperion/websocket's CHECK-HANDSHAKE and either refuses it with the status
;;;; RFC 6455 asks for, or returns a 101 whose body takes the connection over (server-uv's
;;;; MAKE-UPGRADE). From then on the frames are parsed here, with hyperion/websocket's pure
;;;; parser, and the application hears about whole messages.
;;;;
;;;; WHERE THE CALLBACKS RUN. Every callback runs as one of the connection's events (see the
;;;; section on taking over a connection in server-uv.lisp): on a worker when the server has
;;;; them, one at a time per connection, in the order the frames arrived. SEND-TEXT,
;;;; SEND-BINARY, PING and CLOSE-WEBSOCKET may be called from any thread.
;;;;
;;;; THE CLOSE HANDSHAKE (RFC 6455 section 7). A close frame from the peer is answered with a
;;;; close frame carrying the same code, or an empty one when the peer sent none, and then the
;;;; server closes the TCP connection, as section 7.1.1 says the server should. A close the
;;;; application starts with CLOSE-WEBSOCKET sends the close frame and waits
;;;; *CLOSE-TIMEOUT-MS* for the peer's; the TCP connection is closed when it arrives or when
;;;; the time runs out. A frame that breaks a rule is answered with a close frame carrying the
;;;; code the parser named (1002, 1007 or 1009) and the connection is closed without waiting.
;;;; ON-CLOSE is called exactly once, whichever way the connection ended. A draining STOP of
;;;; the server starts the close handshake on every open WebSocket with code 1001 (going
;;;; away), and waits for those connections to close as it waits for requests in flight.
;;;;
;;;; Out of scope: extensions, permessage-deflate among them. A client that offers one is
;;;; answered without Sec-WebSocket-Extensions, which RFC 6455 section 9.1 allows, and a frame
;;;; with a reserved bit set is then refused with 1002.

(cl:defpackage #:hyperion/server-uv/websocket
  (:use #:cl)
  (:local-nicknames (#:srv #:hyperion/server-uv)
                    (#:ws #:hyperion/websocket)
                    (#:log #:aion/log))
  (:documentation
   "WebSockets (RFC 6455) on hyperion/server-uv.

    (lambda (env)
      (websocket-response env :on-message (lambda (ws message) (send-text ws message))))

WEBSOCKET-RESPONSE returns a response triple: a 101 that takes the connection over, or the
400, 403 or 426 the handshake earned. MESSAGE is a string for a text message and an octet
vector for a binary one.")
  (:export #:websocket-response
           #:websocket #:websocket-p #:websocket-env #:websocket-protocol #:websocket-open-p
           #:send-text #:send-binary #:ping #:close-websocket
           #:websocket-closed #:websocket-closed-reason
           #:same-origin-p
           #:*max-message-octets* #:*close-timeout-ms*))

(in-package #:hyperion/server-uv/websocket)

(defvar *max-message-octets* (* 1024 1024)
  "The largest message accepted, in octets, after its fragments are put together. A frame or
message over it is refused with close code 1009 before its payload is read. WEBSOCKET-RESPONSE
takes :MAX-MESSAGE-OCTETS to set it for one endpoint.")

(defvar *close-timeout-ms* 5000
  "How long to wait for the peer's close frame after sending ours, before closing the TCP
connection anyway.")

(define-condition websocket-closed (error)
  ((reason :initarg :reason :reader websocket-closed-reason))
  (:report (lambda (c s)
             (format s "hyperion/server-uv/websocket: the WebSocket is closed: ~A"
                     (websocket-closed-reason c))))
  (:documentation "Signalled by a send once the WebSocket has sent its close frame or its
connection has closed, and when the peer stops reading what is sent to it."))

(defstruct (websocket (:constructor %make-websocket) (:copier nil))
  "One WebSocket connection. The application gets it in every callback."
  (env nil :read-only t)
  (protocol nil :read-only t)
  (upgraded nil)
  (assembler nil)
  ;; Octets read and not yet parsed into frames: at most one frame's worth.
  (buffer (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
  (max-message-octets 0 :read-only t)
  (lock (sb-thread:make-mutex :name "websocket"))
  ;; NIL while open; :SENT once our close frame is queued.
  (close-sent nil)
  ;; The peer's close frame's code and reason, once it has arrived.
  (received nil)
  ;; Set once nothing more is to be read: a close frame arrived or the connection failed.
  (stopped nil)
  ;; The code %FAIL closed the connection with, when a rule was broken.
  (failed-code nil)
  (on-open nil :read-only t)
  (on-message nil :read-only t)
  (on-pong nil :read-only t)
  (on-close nil :read-only t))

(defun websocket-open-p (ws)
  "Whether WS may still send: it has not sent its close frame and its connection is open."
  (and (not (websocket-close-sent ws))
       (websocket-upgraded ws)
       (srv:upgraded-open-p (websocket-upgraded ws))))

;;; --- sending ----------------------------------------------------------------

(defun %write-frame (ws opcode payload)
  "Queue one frame. The caller holds WS's lock, so a frame is never queued after the close."
  (handler-case (srv:upgraded-write (websocket-upgraded ws) (ws:encode-frame opcode payload))
    (srv:upgraded-closed ()
      (error 'websocket-closed :reason "the connection is closed"))))

(defun %send (ws opcode payload)
  (sb-thread:with-mutex ((websocket-lock ws))
    (when (websocket-close-sent ws)
      (error 'websocket-closed :reason "the close frame has been sent"))
    (%write-frame ws opcode payload))
  ;; Outside the lock: a sender waiting for a slow peer must not stop another thread from
  ;; closing.
  (handler-case (srv:upgraded-wait-writable (websocket-upgraded ws))
    (srv:upgraded-closed (e)
      (error 'websocket-closed :reason (srv:upgraded-closed-reason e))))
  (values))

(defun send-text (ws string)
  "Send STRING as one text message. Callable from any thread. On a worker it waits while the
peer is far behind in reading, and signals WEBSOCKET-CLOSED if the peer stops reading."
  (%send ws ws:+text+ (ws:encode-utf8 string)))

(defun send-binary (ws octets)
  "Send OCTETS as one binary message. Callable from any thread, as SEND-TEXT is."
  (%send ws ws:+binary+ (coerce octets '(simple-array (unsigned-byte 8) (*)))))

(defun ping (ws &optional (payload (make-array 0 :element-type '(unsigned-byte 8))))
  "Send a ping carrying PAYLOAD, at most 125 octets. The peer's pong reaches ON-PONG."
  (assert (<= (length payload) ws:max-control-payload) ()
          "a ping's payload is ~D octets; the limit is ~D" (length payload) ws:max-control-payload)
  (%send ws ws:+ping+ (coerce payload '(simple-array (unsigned-byte 8) (*)))))

(defun %truncate-reason (reason)
  "REASON cut to the longest prefix whose UTF-8 fits in a close frame, at a character boundary."
  (loop for end downfrom (length reason) to 0
        for octets = (ws:encode-utf8 (subseq reason 0 end))
        when (<= (length octets) ws:max-close-reason-octets) return (subseq reason 0 end)))

(defun %send-close (ws code reason)
  "Queue our close frame, once. CODE NIL sends the empty payload. Returns whether this call
sent it."
  (sb-thread:with-mutex ((websocket-lock ws))
    (unless (websocket-close-sent ws)
      (setf (websocket-close-sent ws) :sent)
      (ignore-errors
       (%write-frame ws ws:+close+
                     (ws:encode-close-payload code (%truncate-reason (or reason "")))))
      t)))

(defun close-websocket (ws &key (code ws:+normal-closure+) (reason ""))
  "Start the close handshake: send a close frame with CODE and REASON, and close the TCP
connection when the peer answers or after *CLOSE-TIMEOUT-MS*. Callable from any thread;
does nothing once a close frame has been sent. REASON is cut to fit in 123 octets."
  (assert (ws:valid-close-code-p code) () "close code ~D may not be sent" code)
  (when (%send-close ws code reason)
    (let ((u (websocket-upgraded ws)))
      (srv:upgraded-after u *close-timeout-ms* (lambda () (srv:upgraded-close u)))))
  (values))

;;; --- receiving --------------------------------------------------------------

(defun %call (ws fn &rest args)
  "Call the application's FN. An error in it is logged and fails the connection with 1011, as
section 7.4.1 says a server that cannot fulfil a request does."
  (when fn
    (handler-case (apply fn ws args)
      (error (e)
        (log:error "server-uv/websocket: a callback signalled; closing with 1011"
                   :condition (log:condition-type e))
        (%fail ws ws:+internal-error+ "internal error")))))

(defun %fail (ws code reason)
  "Close the connection because a rule was broken: send CODE, then close without waiting for
the peer's answer (section 7.1.7)."
  (log:info "server-uv/websocket: closing the connection" :code code :reason reason)
  (setf (websocket-stopped ws) t)
  (unless (websocket-close-sent ws)
    (setf (websocket-failed-code ws) code))
  (%send-close ws code reason)
  (srv:upgraded-close (websocket-upgraded ws)))

(defun %on-frame (ws frame)
  "One frame from the peer. Returns NIL when nothing more is to be read."
  (multiple-value-bind (kind a b) (ws:assemble (websocket-assembler ws) frame)
    (ecase kind
      (:none t)
      ((:text :binary)
       ;; After our close frame the peer may still send messages that crossed it; they are
       ;; dropped, as the application has said it is done.
       (unless (websocket-close-sent ws)
         (%call ws (websocket-on-message ws) a))
       t)
      (:ping
       (sb-thread:with-mutex ((websocket-lock ws))
         (unless (websocket-close-sent ws)
           (ignore-errors (%write-frame ws ws:+pong+ a))))
       t)
      (:pong
       (%call ws (websocket-on-pong ws) a)
       t)
      (:close
       (setf (websocket-received ws) (cons a b)
             (websocket-stopped ws) t)
       ;; Echo the code, or send the empty payload when the peer sent none (1005 is never put
       ;; on the wire). Then the server closes TCP, which section 7.1.1 asks of a server.
       (%send-close ws (if (= a ws:+no-status+) nil a) "")
       (srv:upgraded-close (websocket-upgraded ws))
       nil)
      (:error
       (%fail ws a b)
       nil))))

(defun %on-data (ws chunk)
  "CHUNK arrived: parse every whole frame now in the buffer, and keep the rest."
  (let ((buffer (websocket-buffer ws)))
    (unless (websocket-stopped ws)
      (loop for octet across chunk do (vector-push-extend octet buffer))
      (let ((at 0) (end (fill-pointer buffer)))
        (loop
          (multiple-value-bind (kind a b)
              (ws:parse-frame buffer :start at :end end :masked t
                                     :max-payload (websocket-max-message-octets ws))
            (ecase kind
              (:incomplete (return))
              (:error (%fail ws a b) (setf at end) (return))
              (:frame
               (setf at b)
               (unless (and (%on-frame ws a) (not (websocket-stopped ws)))
                 (setf at end)
                 (return))))))
        (replace buffer buffer :start2 at :end2 end)
        (setf (fill-pointer buffer) (- end at))))))

(defun %on-close (ws)
  "The connection has closed. Tell the application, with the code the peer sent, else the
code we failed the connection with because a rule was broken, else 1006: the connection ended
without a close frame from the peer."
  (let ((received (websocket-received ws))
        (failed (websocket-failed-code ws)))
    (multiple-value-bind (code reason)
        (cond (received (values (car received) (cdr received)))
              (failed (values failed ""))
              (t (values ws:+abnormal-closure+ "")))
      (let ((fn (websocket-on-close ws)))
        (when fn
          (handler-case (funcall fn ws code reason)
            (error (e)
              (log:error "server-uv/websocket: ON-CLOSE signalled"
                         :condition (log:condition-type e)))))))))

(defun %on-drain (ws)
  "The server is stopping with a drain: start the close handshake with 1001 (going away), so
the peer hears why and a draining STOP is not left waiting for its timeout. Does nothing once a
close frame has been sent."
  (close-websocket ws :code ws:+going-away+ :reason "server going away"))

(defun %open (ws u)
  "The first event: the 101 has been written and the connection is ours."
  (setf (websocket-upgraded ws) u
        (srv:upgraded-on-data u) (lambda (u chunk) (declare (ignore u)) (%on-data ws chunk))
        (srv:upgraded-on-close u) (lambda (u) (declare (ignore u)) (%on-close ws))
        (srv:upgraded-on-drain u) (lambda (u) (declare (ignore u)) (%on-drain ws)))
  (%call ws (websocket-on-open ws)))

;;; --- the handshake ----------------------------------------------------------

(defun %authority (origin)
  "The host and port of ORIGIN, an Origin header's scheme://host[:port], lowercased and
without the scheme's default port; NIL when ORIGIN does not have that form."
  (let ((sep (search "://" origin)))
    (when sep
      (let* ((scheme (string-downcase (subseq origin 0 sep)))
             (authority (string-downcase (subseq origin (+ sep 3))))
             (default (cond ((string= scheme "http") ":80")
                            ((string= scheme "https") ":443"))))
        (if (and default
                 (> (length authority) (length default))
                 (string= default authority :start2 (- (length authority) (length default))))
            (subseq authority 0 (- (length authority) (length default)))
            authority)))))

(defun same-origin-p (origin env)
  "The default origin check: true when the request has no Origin header (a client that is
not a browser), or when the Origin's host and port are the request's Host. A browser always
sends Origin, so this refuses a page on another site that opens a socket to this one with
the user's cookies."
  (or (null origin)
      (let ((host (gethash "host" (getf env :headers))))
        (and host
             (let ((authority (%authority origin))
                   (host (string-downcase (string-trim " " host))))
               (and authority
                    (or (string= authority host)
                        ;; A Host header naming a default port the Origin left out.
                        (let ((stripped (%authority (concatenate 'string "http://" host)))
                              (stripped-s (%authority (concatenate 'string "https://" host))))
                          (or (string= authority stripped) (string= authority stripped-s))))))))))

(defun %refusal (status reason headers)
  (list status
        (append headers (list :content-type "text/plain; charset=utf-8"))
        (list reason)))

(defun websocket-response (env &key on-open on-message on-close on-pong
                                    protocols select-protocol
                                    (check-origin #'same-origin-p)
                                    (max-message-octets *max-message-octets*))
  "Answer ENV, a WebSocket opening handshake, with a response triple for server-uv.

The handshake is checked first (hyperion/websocket's CHECK-HANDSHAKE); a request that fails
gets 400, or 426 with the version or protocol the server speaks. CHECK-ORIGIN, a function of
the Origin header (or NIL) and ENV, then decides whether the page that opened the socket may;
when it says no the answer is 403. The default is SAME-ORIGIN-P; pass (constantly t) to accept
every origin.

PROTOCOLS lists the subprotocols this endpoint speaks. SELECT-PROTOCOL, a function of the list
the client offered, returns the one to use or NIL; by default it is the first offered that is
in PROTOCOLS. When none is chosen the connection opens without one, and the client decides
whether to go on (RFC 6455 section 4.2.2).

Callbacks, each given the WEBSOCKET first:
  ON-OPEN    ()                  the connection is open
  ON-MESSAGE (message)           a string for a text message, an octet vector for a binary one
  ON-PONG    (payload)           the peer answered a PING
  ON-CLOSE   (code reason)       once, when the connection has closed; CODE is 1006 when it
                                 ended without a close frame; after a draining STOP sent
                                 1001, the code the peer answered with, normally 1001
An error in a callback is logged and closes the connection with 1011.

MAX-MESSAGE-OCTETS bounds a message after its fragments are put together; over it, the
connection is closed with 1009."
  (let ((headers (getf env :headers)))
    (multiple-value-bind (verdict key-or-status reason refusal-headers)
        (ws:check-handshake (getf env :request-method) (getf env :server-protocol) headers)
      (if (eq verdict :refuse)
          (%refusal key-or-status reason refusal-headers)
          (let ((origin (gethash "origin" headers)))
            (if (not (funcall check-origin origin env))
                (progn
                  (log:info "server-uv/websocket: origin refused" :origin origin)
                  (%refusal 403 "the origin may not open a WebSocket here" '()))
                (let* ((offered (ws:offered-protocols headers))
                       (protocol (if select-protocol
                                     (funcall select-protocol offered)
                                     (find-if (lambda (p) (member p protocols :test #'string=))
                                              offered))))
                  (when (and protocol (not (member protocol offered :test #'string=)))
                    (error "hyperion/server-uv/websocket: the selected subprotocol ~S was not offered by the client"
                           protocol))
                  (let ((ws (%make-websocket :env env :protocol protocol
                                             :assembler (ws:make-assembler
                                                         :max-message-octets max-message-octets)
                                             :max-message-octets max-message-octets
                                             :on-open on-open :on-message on-message
                                             :on-pong on-pong :on-close on-close)))
                    (list 101
                          (append (list :upgrade "websocket"
                                        :sec-websocket-accept (ws:accept-key key-or-status))
                                  (and protocol (list :sec-websocket-protocol protocol)))
                          (srv:make-upgrade (lambda (u) (%open ws u))))))))))))
