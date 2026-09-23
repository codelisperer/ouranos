;;;; ffi.lisp --- the raw binding for streams, TCP, pipes and DNS.
;;;;
;;;; Same discipline as aion/uv/ffi, which this continues rather than restates: sizes
;;;; come from libuv (uv_handle_size(UV_TCP), uv_req_size(UV_WRITE)), enum values are
;;;; verified once by VERIFY-ABI for the whole binding, and nothing is interpreted here.
;;;;
;;;; TWO PLATFORM FACTS THIS LAYER RELIES ON, both checked rather than assumed:
;;;;
;;;; 1. `struct sockaddr_storage` is 128 bytes on Linux, macOS and Windows. It is defined
;;;;    to be large enough for any address family, and every implementation uses 128. We
;;;;    allocate that and never inspect its layout, with one exception:
;;;;
;;;; 2. THE PORT IS A BIG-ENDIAN UINT16 AT OFFSET 2, in every address family on every
;;;;    platform. This is worth stating because it looks like exactly the kind of
;;;;    assumption that breaks somewhere. It does not, and the reason is structural:
;;;;      Linux/Windows  sockaddr_in  { uint16 sin_family;             uint16 sin_port; }
;;;;      macOS/BSD      sockaddr_in  { uint8 sin_len; uint8 sin_family; uint16 sin_port; }
;;;;    The BSD variant splits the first two bytes rather than adding any, and sockaddr_in6
;;;;    has the identical prefix in both variants. So the port lands at offset 2 either
;;;;    way. Everything else about the address we get from libuv's own uv_ip_name, which
;;;;    handles v4 and v6 without us knowing which we hold.
;;;;
;;;; THE ONE HAND-WRITTEN PLATFORM STRUCT: `struct addrinfo`. It is unavoidable -- the
;;;; getaddrinfo callback hands us the head of a linked list and there is no libuv
;;;; accessor for walking it -- and it is the exception the no-grovel rule warned about,
;;;; because it is the PLATFORM's struct and its field ORDER genuinely differs: Linux puts
;;;; ai_addr before ai_canonname, BSD and Windows put them the other way round. Both
;;;; layouts are written out below, and %CHECK-ADDRINFO detects a wrong guess and signals
;;;; instead of dereferencing whatever it found. Getting this wrong on an unforeseen
;;;; platform therefore produces an error message, not a crash.

(in-package #:aion/uv/net/ffi)

;;; ---------------------------------------------------------------------- tcp

(cffi:defcfun ("uv_tcp_init" uv-tcp-init) :int (loop :pointer) (handle :pointer))
(cffi:defcfun ("uv_tcp_bind" uv-tcp-bind) :int
  (handle :pointer) (addr :pointer) (flags :uint))
(cffi:defcfun ("uv_tcp_connect" uv-tcp-connect) :int
  (req :pointer) (handle :pointer) (addr :pointer) (cb :pointer))
(cffi:defcfun ("uv_tcp_getsockname" uv-tcp-getsockname) :int
  (handle :pointer) (name :pointer) (namelen :pointer))
(cffi:defcfun ("uv_tcp_getpeername" uv-tcp-getpeername) :int
  (handle :pointer) (name :pointer) (namelen :pointer))

;;; TCP_NODELAY. Not a nicety: ADR-0011 measured a 44 ms delayed-ACK floor and fixed it
;;; with Content-Length, but left a p99 residual -- and a STREAMED response cannot carry
;;; a Content-Length by definition, so the fix does not reach it. Disabling Nagle is what
;;; does. Owning the socket is the only way to set it, which is a concrete reason to own
;;; the socket rather than an abstract one.
(cffi:defcfun ("uv_tcp_nodelay" uv-tcp-nodelay) :int (handle :pointer) (enable :int))
(cffi:defcfun ("uv_tcp_keepalive" uv-tcp-keepalive) :int
  (handle :pointer) (enable :int) (delay :uint))

;;; ------------------------------------------------------------------- streams

(cffi:defcfun ("uv_listen" uv-listen) :int
  (stream :pointer) (backlog :int) (cb :pointer))
(cffi:defcfun ("uv_accept" uv-accept) :int (server :pointer) (client :pointer))
(cffi:defcfun ("uv_read_start" uv-read-start) :int
  (stream :pointer) (alloc-cb :pointer) (read-cb :pointer))
(cffi:defcfun ("uv_read_stop" uv-read-stop) :int (stream :pointer))
(cffi:defcfun ("uv_write" uv-write) :int
  (req :pointer) (handle :pointer) (bufs :pointer) (nbufs :uint) (cb :pointer))
(cffi:defcfun ("uv_shutdown" uv-shutdown) :int
  (req :pointer) (handle :pointer) (cb :pointer))
(cffi:defcfun ("uv_is_readable" uv-is-readable) :int (handle :pointer))
(cffi:defcfun ("uv_is_writable" uv-is-writable) :int (handle :pointer))

;;; The backpressure signal. Node surfaces the same number as writable.writableLength and
;;; fires 'drain' when it reaches zero; we expose it directly and let PIPE-INTO act on it.
(cffi:defcfun ("uv_stream_get_write_queue_size" uv-stream-get-write-queue-size) :size
  (stream :pointer))

;;; --------------------------------------------------------------------- pipes
;;;
;;; A uv_pipe_t is a uv_stream_t, so everything above works on it unchanged. Bound here
;;; because it costs almost nothing given the stream layer, and because aion/uv/process
;;; (pre-publication issue 119) needs exactly this for a subprocess's stdio.

(cffi:defcfun ("uv_pipe_init" uv-pipe-init) :int
  (loop :pointer) (handle :pointer) (ipc :int))
(cffi:defcfun ("uv_pipe_bind" uv-pipe-bind) :int (handle :pointer) (name :string))
(cffi:defcfun ("uv_pipe_connect" uv-pipe-connect) :void
  (req :pointer) (handle :pointer) (name :string) (cb :pointer))

;;; ----------------------------------------------------------------- addresses

(defconstant +sockaddr-storage-size+ 128
  "sizeof(struct sockaddr_storage) on Linux, macOS and Windows. The struct exists to be
big enough for any family; we allocate it and never look inside, except for the port.")

(cffi:defcfun ("uv_ip4_addr" uv-ip4-addr) :int (ip :string) (port :int) (addr :pointer))
(cffi:defcfun ("uv_ip6_addr" uv-ip6-addr) :int (ip :string) (port :int) (addr :pointer))

;;; uv_ip_name (libuv >= 1.44) renders either family without us having to read sa_family
;;; -- which is the one part of sockaddr whose layout genuinely differs (BSD spends a byte
;;; on sa_len). libuv.pin is 1.52.1, so it is always present.
(cffi:defcfun ("uv_ip_name" uv-ip-name) :int (src :pointer) (dst :pointer) (size :size))

(defun sockaddr-port (addr)
  "The port from a sockaddr, in host order. Offset 2, big-endian, every family, every
platform -- see the file header for why that is structural rather than lucky."
  (+ (* 256 (cffi:mem-aref addr :unsigned-char 2))
     (cffi:mem-aref addr :unsigned-char 3)))

;;; ------------------------------------------------------------------------ dns

(cffi:defcfun ("uv_getaddrinfo" uv-getaddrinfo) :int
  (loop :pointer) (req :pointer) (cb :pointer)
  (node :pointer) (service :pointer) (hints :pointer))
(cffi:defcfun ("uv_freeaddrinfo" uv-freeaddrinfo) :void (ai :pointer))

;;; The platform's struct, not libuv's. Linux orders ai_addr before ai_canonname; BSD
;;; (macOS) and Windows reverse them, and Windows widens ai_addrlen to size_t.
(cffi:defcstruct addrinfo
  (flags :int)
  (family :int)
  (socktype :int)
  (protocol :int)
  #+windows (addrlen :size)
  #-windows (addrlen :uint32)
  #+(or darwin windows) (canonname :pointer)
  (addr :pointer)
  #-(or darwin windows) (canonname :pointer)
  (next :pointer))

(define-condition addrinfo-layout-error (error)
  ((detail :initarg :detail :reader addrinfo-layout-error-detail))
  (:report
   (lambda (c stream)
     (format stream "getaddrinfo returned a result this binding cannot read: ~A~%"
             (addrinfo-layout-error-detail c))
     (format stream "This means `struct addrinfo`'s field order on this platform is not one of the two aion/uv/net knows (Linux: ai_addr before ai_canonname; BSD/Windows: the reverse). Re-derive the layout in aion/src/uv/net/ffi.lisp from this platform's netdb.h before using DNS.~%")))
  (:documentation
   "Signalled when the hand-written addrinfo layout does not fit the platform.

Deliberately loud and deliberately BEFORE any dereference: on a wrong layout the ai_addr
slot reads whatever ai_canonname holds, which without AI_CANONNAME is a null pointer.
Detecting that is the difference between an error message and a segfault."))

(defun addrinfo-family (ai) (cffi:foreign-slot-value ai '(:struct addrinfo) 'family))
(defun addrinfo-addrlen (ai) (cffi:foreign-slot-value ai '(:struct addrinfo) 'addrlen))
(defun addrinfo-addr (ai) (cffi:foreign-slot-value ai '(:struct addrinfo) 'addr))
(defun addrinfo-next (ai) (cffi:foreign-slot-value ai '(:struct addrinfo) 'next))
