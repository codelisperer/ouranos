;;;; tcp.lisp --- TCP sockets, and the pipes that share their machinery.
;;;;
;;;; A uv_tcp_t IS a uv_stream_t, so everything in stream.lisp -- reading, writing,
;;;; backpressure, shutdown -- already applies. What is left here is what TCP has and a
;;;; generic stream does not: binding, listening, accepting, dialling, socket options and
;;;; addresses.
;;;;
;;;; TWO LIFECYCLE RULES, both easy to get wrong and both silent when you do:
;;;;
;;;;   * AN UNINITIALISED HANDLE IS FREED; AN INITIALISED ONE IS CLOSED. Once
;;;;     uv_tcp_init has succeeded the handle belongs to the loop, and releasing its
;;;;     memory with foreign-free is a use-after-free -- it must go through uv_close and
;;;;     have its memory released by the close callback. The two failure paths in %ACCEPT
;;;;     are on opposite sides of that line, which is why they are written out separately
;;;;     rather than shared.
;;;;   * TCP_NODELAY IS SET BY DEFAULT HERE, inverting the C default deliberately. Nagle's
;;;;     algorithm exists to coalesce tiny writes on links where that mattered; on a
;;;;     request/response protocol it interacts with delayed ACK to add tens of
;;;;     milliseconds for nothing. ADR-0011 measured exactly that -- a 44 ms floor -- and
;;;;     fixed the part Content-Length could fix, leaving a p99 residual that a STREAMED
;;;;     response cannot fix at all, because a streamed response has no Content-Length by
;;;;     definition. Owning the socket is what lets us set this, and setting it is a large
;;;;     part of why owning the socket is worth anything.
;;;;
;;;; HOSTNAMES ARE NOT ACCEPTED HERE, deliberately. libuv wants a sockaddr, and turning a
;;;; name into one is DNS -- a network operation with its own latency and failure modes.
;;;; A binding that hides it inside `connect` makes an invisible network call on a
;;;; function that looks local. Use RESOLVE, then connect to what it returns.

(in-package #:aion/uv/net)

;;; ----------------------------------------------------------------- conditions

(define-condition not-an-ip-address (uv:uv-error) ()
  (:documentation
   "The host given was not an IP address literal. Resolve it with RESOLVE first."))

;;; ------------------------------------------------------------------ addresses

(defun %fill-sockaddr (addr host port)
  "Fill ADDR (a sockaddr_storage) from an IP LITERAL and PORT.

Which converter to call is decided by the typed core -- a colon can only appear in an
IPv6 literal -- rather than by guessing here."
  (let ((code (if (types:ipv6-literal? host)
                  (ffi:uv-ip6-addr host port addr)
                  (ffi:uv-ip4-addr host port addr))))
    (when (minusp code)
      (error 'not-an-ip-address
             :code code :name (uv-ffi:uv-err-name code) :path host
             :operation :address
             :message (format nil "~S is not an IP address literal; RESOLVE it first" host)))
    addr))

(defmacro %with-sockaddr ((var host port) &body body)
  `(cffi:with-foreign-object (,var :unsigned-char ffi:+sockaddr-storage-size+)
     (%fill-sockaddr ,var ,host ,port)
     ,@body))

(defun %address-of (connection getter operation)
  ;; A pipe has no socket address, and asking libuv for one on a uv_pipe_t is a category
  ;; error rather than a runtime failure -- so it is refused here with a clear reason.
  (unless (eq (connection-kind connection) :tcp)
    (error 'uv:uv-error
           :code 0 :name "EINVAL" :operation operation
           :message "only a TCP connection has a socket address"))
  (cffi:with-foreign-object (addr :unsigned-char ffi:+sockaddr-storage-size+)
    (cffi:with-foreign-object (len :int)
      (setf (cffi:mem-ref len :int) ffi:+sockaddr-storage-size+)
      (uv:check (funcall getter (connection-pointer connection) addr len)
                :operation operation)
      (cffi:with-foreign-object (text :char 256)
        ;; uv_ip_name renders either family, so we never have to read sa_family --
        ;; the one field of sockaddr whose layout genuinely differs across platforms.
        (uv:check (ffi:uv-ip-name addr text 256) :operation operation)
        (values (cffi:foreign-string-to-lisp text)
                (ffi:sockaddr-port addr))))))

(defun local-address (connection)
  "Our end of CONNECTION, as (values HOST PORT)."
  (%address-of connection #'ffi:uv-tcp-getsockname :local-address))

(defun peer-address (connection)
  "The far end of CONNECTION, as (values HOST PORT)."
  (%address-of connection #'ffi:uv-tcp-getpeername :peer-address))

;;; ------------------------------------------------------------- socket options

(defun set-nodelay (connection &optional (enable t))
  "Enable or disable TCP_NODELAY. On by default for every connection made here; see the
file header for the measurement that justifies inverting the C default."
  (uv:check (ffi:uv-tcp-nodelay (connection-pointer connection) (if enable 1 0))
            :operation :set-nodelay)
  connection)

(defun set-keepalive (connection &key (enable t) (delay 60))
  "Enable TCP keepalive, with DELAY seconds of idle before the first probe."
  (uv:check (ffi:uv-tcp-keepalive (connection-pointer connection)
                                  (if enable 1 0) (if enable delay 0))
            :operation :set-keepalive)
  connection)

;;; ------------------------------------------------------------------- handles

(defun %handle-type (kind)
  (ecase kind
    (:tcp uv-ffi:+uv-tcp+)
    (:pipe uv-ffi:+uv-named-pipe+)))

(defun %init-handle (loop kind operation)
  "Allocate and initialise a stream handle. Returns the pointer.

Note the asymmetry in the failure path: uv_*_init has NOT yet made the handle the loop's,
so a plain foreign-free is correct here and would be a use-after-free anywhere later."
  (let* ((pointer (cffi:foreign-alloc :char :count (uv-ffi:uv-handle-size
                                                    (%handle-type kind))))
         (code (ecase kind
                 (:tcp (ffi:uv-tcp-init (uv:loop-pointer loop) pointer))
                 (:pipe (ffi:uv-pipe-init (uv:loop-pointer loop) pointer 0)))))
    (when (minusp code)
      (cffi:foreign-free pointer)
      (uv:signal-uv-error code :operation operation))
    pointer))

(defun %adopt-connection (pointer loop kind)
  (let ((connection (%make-connection :pointer pointer :loop loop :kind kind)))
    (uv:register pointer connection)
    (push pointer (uv:loop-owned loop))
    connection))

;;; ------------------------------------------------------------------ listening

(defstruct (listener (:constructor %make-listener))
  "A bound, listening handle. Holds the loop open while it is listening -- which is
usually what you want for a server and is the answer when a process will not exit."
  pointer loop (kind :tcp) on-connection (nodelay t) (closed nil))

(defun %accept (listener)
  "Accept one pending connection. Called from the connection callback, on the loop thread."
  (let* ((loop (listener-loop listener))
         (kind (listener-kind listener))
         (pointer (%init-handle loop kind :accept))
         (code (ffi:uv-accept (listener-pointer listener) pointer)))
    (when (minusp code)
      ;; Initialised, therefore CLOSED rather than freed -- the other side of the rule in
      ;; %INIT-HANDLE. Freeing it here would be a use-after-free libuv performs later.
      (uv:close-pointer pointer)
      (uv:signal-uv-error code :operation :accept))
    (let ((connection (%adopt-connection pointer loop kind)))
      (when (and (eq kind :tcp) (listener-nodelay listener))
        (set-nodelay connection t))
      connection)))

(cffi:defcallback %connection-callback :void ((server :pointer) (status :int))
  (uv:with-callback-guard
    (let ((listener (uv:lookup server)))
      (when (listener-p listener)
        (if (minusp status)
            (uv:note-callback-error
             (make-condition (uv:uv-error-class (uv-ffi:uv-err-name status))
                             :code status :name (uv-ffi:uv-err-name status)
                             :message (uv-ffi:uv-strerror status)
                             :operation :listen))
            ;; An error accepting ONE connection must not take down the listener.
            (handler-case
                (let ((connection (%accept listener)))
                  (when (listener-on-connection listener)
                    (funcall (listener-on-connection listener) connection)))
              (error (e) (uv:note-callback-error e))))))))

(defun %listen (loop kind bind-thunk &key (backlog 128) on-connection (nodelay t)
                                          operation path)
  (uv:ensure-available)
  (let* ((pointer (%init-handle loop kind operation))
         (listener (%make-listener :pointer pointer :loop loop :kind kind
                                   :on-connection on-connection :nodelay nodelay)))
    (uv:register pointer listener)
    (push pointer (uv:loop-owned loop))
    (handler-bind ((error (lambda (e) (declare (ignore e))
                            (ignore-errors (close-listener listener)))))
      (uv:check (funcall bind-thunk pointer) :operation operation :path path)
      (uv:check (ffi:uv-listen pointer backlog (cffi:callback %connection-callback))
                :operation operation :path path))
    listener))

(defun listen-tcp (loop host port &key (backlog 128) on-connection (nodelay t))
  "Listen on HOST (an IP literal) and PORT, calling ON-CONNECTION with each accepted
CONNECTION, on the loop thread.

PORT 0 asks the OS to choose one; LOCAL-ADDRESS on the listener's connections, or
LISTENER-PORT, reports what it chose. NODELAY is applied to every accepted connection."
  (%listen loop :tcp
           (lambda (pointer)
             (%with-sockaddr (addr host port)
               (ffi:uv-tcp-bind pointer addr 0)))
           :backlog backlog :on-connection on-connection :nodelay nodelay
           :operation :listen-tcp :path host))

(defun listener-address (listener)
  "The address this listener actually bound to, as (values HOST PORT). The port is the
interesting half when 0 was requested."
  (cffi:with-foreign-object (addr :unsigned-char ffi:+sockaddr-storage-size+)
    (cffi:with-foreign-object (len :int)
      (setf (cffi:mem-ref len :int) ffi:+sockaddr-storage-size+)
      (uv:check (ffi:uv-tcp-getsockname (listener-pointer listener) addr len)
                :operation :listener-address)
      (cffi:with-foreign-object (text :char 256)
        (uv:check (ffi:uv-ip-name addr text 256) :operation :listener-address)
        (values (cffi:foreign-string-to-lisp text) (ffi:sockaddr-port addr))))))

(defun close-listener (listener)
  "Stop listening and release the handle. Accepted connections are unaffected."
  (let ((pointer (listener-pointer listener)))
    (unless (listener-closed listener)
      (setf (listener-closed listener) t)
      (when pointer
        (setf (uv:loop-owned (listener-loop listener))
              (remove pointer (uv:loop-owned (listener-loop listener))))
        (uv:close-pointer pointer)
        (setf (listener-pointer listener) nil))))
  listener)

(defmethod uv:close-handle ((listener listener))
  (close-listener listener))

;;; ------------------------------------------------------------------ connecting

(defstruct (connect-op (:constructor %make-connect-op))
  connection future on-connect on-error nodelay)

(cffi:defcallback %connect-callback :void ((req :pointer) (status :int))
  (uv:with-callback-guard
    (let ((op (uv:lookup req)))
      (uv:deregister req)
      (unwind-protect
           (when op
             (let ((connection (connect-op-connection op)))
               (if (minusp status)
                   (let* ((name (uv-ffi:uv-err-name status))
                          (condition (make-condition (uv:uv-error-class name)
                                                     :code status :name name
                                                     :message (uv-ffi:uv-strerror status)
                                                     :operation :connect)))
                     ;; The handle exists but is useless; nobody else has a reference to
                     ;; close it, so closing it here is the only thing that can.
                     (ignore-errors (uv:close-handle connection))
                     ;; Carried by the future, not shouted: a refused connection is an
                     ;; ordinary outcome of dialling, not an escaped error.
                     (uv:fail-future (connect-op-future op) condition)
                     (when (connect-op-on-error op)
                       (funcall (connect-op-on-error op) condition)))
                   (progn
                     (when (and (connect-op-nodelay op)
                                (eq (connection-kind connection) :tcp))
                       (ignore-errors (set-nodelay connection t)))
                     (uv:fulfill (connect-op-future op) connection)
                     (when (connect-op-on-connect op)
                       (funcall (connect-op-on-connect op) connection))))))
        (cffi:foreign-free req)))))

(defun connect-tcp (loop host port &key on-connect on-error (nodelay t))
  "Dial HOST (an IP literal) and PORT on LOOP. Returns a FUTURE that yields the
CONNECTION once it is established.

HOST must be a literal; see the file header for why this does not resolve names. If the
connection fails, the handle is closed for you and the future carries the error."
  (uv:ensure-available)
  (let* ((pointer (%init-handle loop :tcp :connect-tcp))
         (connection (%adopt-connection pointer loop :tcp))
         (op (%make-connect-op :connection connection :future (uv:make-future)
                               :on-connect on-connect :on-error on-error
                               :nodelay nodelay))
         (req (%new-request uv-ffi:+uv-connect+ op)))
    (%with-sockaddr (addr host port)
      (let ((code (ffi:uv-tcp-connect req pointer addr
                                      (cffi:callback %connect-callback))))
        (when (minusp code)
          (uv:deregister req)
          (cffi:foreign-free req)
          (ignore-errors (uv:close-handle connection))
          (uv:signal-uv-error code :operation :connect-tcp :path host))))
    (connect-op-future op)))

;;; ---------------------------------------------------------------------- pipes
;;;
;;; A uv_pipe_t is a uv_stream_t too, so it needs only its own bind and connect. Bound
;;; here because it costs a dozen lines given everything above, and because aion/uv/process
;;; (pre-publication issue 119) will want exactly this for a subprocess's stdio.

(defun listen-pipe (loop path &key (backlog 128) on-connection)
  "Listen on a named pipe / unix domain socket at PATH."
  (%listen loop :pipe
           (lambda (pointer) (ffi:uv-pipe-bind pointer (namestring path)))
           :backlog backlog :on-connection on-connection :nodelay nil
           :operation :listen-pipe :path (namestring path)))

(defun make-pipe-connection (loop &key ipc)
  "An initialised but UNCONNECTED uv_pipe_t, wrapped as a CONNECTION.

For callers that will have the other end attached by something other than a connect --
notably aion/uv/process, which hands the raw handle to uv_spawn as a child's stdio and
lets libuv join the two. Once spawned it is an ordinary stream: START-READING,
WRITE-BYTES and the backpressure in stream.lisp all apply unchanged, which is the entire
reason subprocess stdio costs almost nothing on top of this sub-system.

IPC is libuv's flag for a pipe that can carry handles between processes; leave it off
unless you mean it."
  (uv:ensure-available)
  (let* ((pointer (cffi:foreign-alloc :char
                                      :count (uv-ffi:uv-handle-size
                                              uv-ffi:+uv-named-pipe+)))
         (code (ffi:uv-pipe-init (uv:loop-pointer loop) pointer (if ipc 1 0))))
    (when (minusp code)
      (cffi:foreign-free pointer)
      (uv:signal-uv-error code :operation :make-pipe-connection))
    (%adopt-connection pointer loop :pipe)))

(defun connect-pipe (loop path &key on-connect on-error)
  "Connect to the named pipe / unix domain socket at PATH. Returns a FUTURE yielding the
CONNECTION. uv_pipe_connect cannot fail synchronously -- it returns void -- so every
failure arrives through the future."
  (uv:ensure-available)
  (let* ((pointer (%init-handle loop :pipe :connect-pipe))
         (connection (%adopt-connection pointer loop :pipe))
         (op (%make-connect-op :connection connection :future (uv:make-future)
                               :on-connect on-connect :on-error on-error :nodelay nil))
         (req (%new-request uv-ffi:+uv-connect+ op)))
    (ffi:uv-pipe-connect req pointer (namestring path)
                         (cffi:callback %connect-callback))
    (connect-op-future op)))
