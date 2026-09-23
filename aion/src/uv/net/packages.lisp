;;;; packages.lisp --- aion/uv/net package definitions.
;;;;
;;;; The same three-layer shape as aion/uv itself, one layer down:
;;;;
;;;;   aion/uv/net/ffi   -- the raw binding for streams, TCP, pipes and DNS. One Lisp
;;;;                        function per C function, no interpretation.
;;;;   aion/uv/net/types -- the typed core, in Coalton. Pure. Decodes the one genuinely
;;;;                        overloaded number in the stream API (nread) and the
;;;;                        backpressure decision, and nothing else.
;;;;   aion/uv/net       -- the idiomatic CL face: listeners, connections, reading with
;;;;                        backpressure, writing, addresses.
;;;;
;;;; WHY THIS IS A SUB-SYSTEM AND NOT A FRAMEWORK OF ITS OWN, or a part of hyperion:
;;;; everything that wants a socket sits to aion's RIGHT in the DAG -- cons wants
;;;; subprocess pipes, hermes depends on aion alone and will want an HTTP client,
;;;; mnemosyne's Postgres wire is a named target. Transport at position 5 is unreachable
;;;; from all three. So the binding lives here and the DECISIONS built on it (HTTP
;;;; parsing, request/response, subprocess orchestration) live in the frameworks that own
;;;; those domains. See the ECOSYSTEM decisions log, 2026-08-04, #117.
;;;;
;;;; It reuses aion/uv's loop, pointer registry, callback guard and error decoding rather
;;;; than restating them -- that reuse is exactly why the binding cannot be split across
;;;; frameworks. The shared pieces are exported from aion/uv under "the sub-system
;;;; substrate".

(cl:defpackage #:aion/uv/net/ffi
  (:use #:cl)
  (:local-nicknames (#:uv-ffi #:aion/uv/ffi))
  (:documentation
   "Raw CFFI bindings to libuv's stream, TCP, pipe and DNS surface.

Grovel-free on the same terms as aion/uv/ffi: sizes come from libuv's own
uv_handle_size/uv_req_size, and no platform struct is hand-written except
`struct addrinfo`, which is unavoidable and is guarded at runtime -- see the
commentary in ffi.lisp.")
  (:export
   ;; tcp
   #:uv-tcp-init #:uv-tcp-bind #:uv-tcp-connect #:uv-tcp-nodelay #:uv-tcp-keepalive
   #:uv-tcp-getsockname #:uv-tcp-getpeername
   ;; streams
   #:uv-listen #:uv-accept #:uv-read-start #:uv-read-stop #:uv-write #:uv-shutdown
   #:uv-stream-get-write-queue-size #:uv-is-readable #:uv-is-writable
   ;; pipes
   #:uv-pipe-init #:uv-pipe-bind #:uv-pipe-connect
   ;; addresses
   #:uv-ip4-addr #:uv-ip6-addr #:uv-ip-name
   #:+sockaddr-storage-size+ #:sockaddr-port
   ;; dns
   #:uv-getaddrinfo #:uv-freeaddrinfo
   #:addrinfo #:addrinfo-family #:addrinfo-addr #:addrinfo-next #:addrinfo-addrlen
   #:addrinfo-layout-error))

(cl:defpackage #:aion/uv/net/types
  (:use #:coalton #:coalton-prelude)
  (:local-nicknames (#:str #:coalton/string))
  (:documentation
   "The typed core of aion/uv/net, in Coalton. Pure: no IO, no pointers.

Two things are worth a type here, and only two. The first is libuv's `nread`, which is
the most overloaded number in the whole API -- one signed integer that means \"here are
N bytes\", \"nothing right now, not an error\", \"the peer is done\" or \"it failed\",
depending on sign and on an error NAME. Reading that with an if-chain at each call site
is how a binding ends up treating a clean end-of-stream as a failure. The second is the
backpressure decision, which is a pure function of two numbers and is the thing Node got
wrong three times by leaving it advisory.")
  (:export
   #:ReadOutcome #:Bytes #:NothingYet #:EndOfStream #:ReadFailed
   #:decode-read #:read-outcome->string #:read-outcome-tag
   #:FlowState #:Flowing #:Saturated
   #:flow-state #:flow-state->string #:saturated? #:drained?
   #:AddressFamily #:IPv4 #:IPv6
   #:address-family #:address-family->string #:address-family-name #:ipv6-literal?))

(cl:defpackage #:aion/uv/net
  (:use #:cl)
  (:local-nicknames (#:ffi #:aion/uv/net/ffi)
                    (#:uv-ffi #:aion/uv/ffi)
                    (#:uv #:aion/uv)
                    (#:types #:aion/uv/net/types))
  (:documentation
   "TCP, pipes and DNS for Common Lisp, over libuv.

Transport only -- no protocol. Nothing here knows what HTTP is; that belongs to
hyperion, which owns the request/response domain.

THE ONE RULE THAT IS NOT NEGOTIABLE HERE IS BACKPRESSURE. A reader that cannot stop
its producer is the mistake Node shipped in 2010 and rewrote its stream layer twice to
undo: a fast source outruns a slow sink, and the buffer between them grows without
bound until the process dies. So STOP-READING is not an optional extra to
START-READING, it is half of the same API; every connection exposes its write-queue
depth; and PIPE-INTO -- the composed read-from-A-write-to-B case -- applies
backpressure ITSELF, because an API that requires the caller to wire it up by hand is
one where nobody does.

Every handle here holds the loop open while it is active, which is what makes RUN not
return; see the ref/unref discussion in aion/uv's introspect.lisp and ask
(uv:describe-loop l) when something will not exit.")
  (:export
   ;; connections and listeners
   #:connection #:connection-p #:connection-kind #:connection-loop
   #:listener #:listener-p #:listener-loop #:listener-address #:close-listener
   #:listen-tcp #:connect-tcp #:listen-pipe #:connect-pipe #:make-pipe-connection
   #:connection-pointer
   ;; reading, with the pause/resume pair that makes backpressure real
   #:start-reading #:stop-reading #:pause-reading #:resume-reading #:reading-p #:paused-p
   ;; writing
   #:write-bytes #:shutdown-write #:write-queue-size #:saturated-p
   #:+default-high-water-mark+ #:+default-low-water-mark+
   ;; composition -- carries backpressure without the caller wiring it
   #:pipe-into
   ;; socket options and addresses
   #:set-nodelay #:set-keepalive #:local-address #:peer-address
   ;; dns
   #:resolve #:resolve-async #:address-info #:address-info-host #:address-info-port
   #:address-info-family
   ;; conditions
   #:not-an-ip-address #:stream-closed))
