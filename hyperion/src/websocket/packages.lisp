;;;; packages.lisp --- hyperion/websocket: the WebSocket protocol (RFC 6455) as pure functions.
;;;;
;;;; Its own system, depending on nothing, for the reason hyperion/http1 is its own system
;;;; (ADR-0015, point 4): scripts/verify-tree.lisp leaves the libuv systems out unless
;;;; OURANOS_WITH_UV=1, and the code that decides what a frame from a stranger means has to be
;;;; inside every run of the gate. The connection, the socket and the threads are in
;;;; hyperion/server-uv/websocket; nothing here does IO.
;;;;
;;;; Plain Common Lisp rather than Coalton. Frames are octets with bit fields, and the parser
;;;; works on octet vectors in place; the Coalton parser for HTTP works on ISO-8859-1 strings
;;;; because HTTP heads are text. The decision is listed for the maintainer in the design note
;;;; for #376.

(cl:defpackage #:hyperion/websocket
  (:use #:cl)
  (:documentation
   "The WebSocket protocol of RFC 6455 as pure functions: frames parsed from and encoded to
octets, fragmented messages put back together, close payloads, strict UTF-8 checking, and the
opening handshake (the Sec-WebSocket-Accept value and the checks on the client's request).

PARSE-FRAME is incremental, as hyperion/http1's PARSE-HEAD is: it is given whatever octets
have arrived and answers :INCOMPLETE, :FRAME or :ERROR. An :ERROR carries the close code
(RFC 6455 section 7.4.1) the connection is to be closed with, because every refusal here
still has to be reported to the peer.

No IO, no threads, no conditions for bad input. A condition is signalled only for a mistake
by the caller, such as a close reason longer than a close frame can carry.")
  (:export
   ;; opcodes
   #:+continuation+ #:+text+ #:+binary+ #:+close+ #:+ping+ #:+pong+
   ;; close codes the server itself sends
   #:+normal-closure+ #:+going-away+ #:+protocol-error+ #:+unsupported-data+
   #:+no-status+ #:+abnormal-closure+ #:+invalid-payload+ #:+policy-violation+
   #:+message-too-big+ #:+internal-error+
   ;; frames
   #:frame #:frame-p #:frame-fin #:frame-opcode #:frame-payload #:control-opcode-p
   #:parse-frame #:encode-frame #:max-control-payload
   ;; close frames
   #:parse-close-payload #:encode-close-payload #:valid-close-code-p #:max-close-reason-octets
   ;; messages from fragments
   #:assembler #:make-assembler #:assemble #:assembler-in-message-p
   ;; text
   #:utf8-valid-p #:decode-utf8 #:encode-utf8
   ;; the opening handshake
   #:+accept-guid+ #:accept-key #:check-handshake #:offered-protocols #:header-has-token-p
   ;; the primitives the handshake is made of, exported for their tests
   #:sha1 #:base64-encode #:base64-decode))
