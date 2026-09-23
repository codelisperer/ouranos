;;;; dns.lisp --- name resolution, over uv_getaddrinfo.
;;;;
;;;; WHY THERE IS NO TRULY SYNCHRONOUS FORM HERE, unlike the filesystem.
;;;;
;;;; uv_fs_* with a NULL callback runs inline and RETURNS the answer, which is why
;;;; aion/uv's read-file needs no loop. uv_getaddrinfo with a NULL callback also runs
;;;; inline -- but it leaves its answer in `req->addrinfo`, and libuv publishes no
;;;; accessor for that field. Reading it would mean hand-writing the layout of
;;;; uv_getaddrinfo_t, a struct with a whole request header in front of the field we
;;;; want, which is exactly the kind of guess the no-grovel rule exists to forbid.
;;;;
;;;; The ASYNC callback, by contrast, is handed `struct addrinfo* res` as a parameter --
;;;; no layout knowledge required. So the async path is the real one, and RESOLVE is a
;;;; convenience that runs a private loop to completion around it. That costs a loop
;;;; setup per call and is stated plainly rather than hidden: a caller resolving many
;;;; names should use RESOLVE-ASYNC on a loop it already has.
;;;;
;;;; MEMORY: libuv allocates the addrinfo list and uv_freeaddrinfo releases it. We never
;;;; free it ourselves -- the absolute rule from aion/uv/ffi, and on Windows the
;;;; difference between a leak and a crash, since a mingw-built libuv may not share a C
;;;; runtime with SBCL.

(in-package #:aion/uv/net)

(defstruct (address-info (:constructor %make-address-info))
  "One resolved address: the textual form, the port, and which family it turned out to be."
  (host "" :read-only t)
  (port 0 :read-only t)
  (family :ipv4 :read-only t))

(defstruct (resolve-op (:constructor %make-resolve-op))
  future host on-success on-error)

;;; ------------------------------------------------------------------- reading

(defun %check-addrinfo (ai addr)
  "Prove the hand-written addrinfo layout fits this platform BEFORE dereferencing.

On a wrong guess the ai_addr slot actually reads ai_canonname, which -- since we do not
ask for AI_CANONNAME -- is a null pointer. Testing for that turns a mis-assumed platform
into an error message instead of a segfault."
  (when (cffi:null-pointer-p addr)
    (error 'ffi:addrinfo-layout-error :detail "ai_addr read as a null pointer"))
  (let ((len (ffi:addrinfo-addrlen ai)))
    (unless (<= 8 len ffi:+sockaddr-storage-size+)
      (error 'ffi:addrinfo-layout-error
             :detail (format nil "ai_addrlen read as ~D, which is not a socket address"
                             len)))))

(defun %collect-addrinfo (head)
  "Walk libuv's addrinfo list into ADDRESS-INFO structures."
  (let ((results '()))
    (loop for ai = head then (ffi:addrinfo-next ai)
          until (cffi:null-pointer-p ai)
          do (let ((addr (ffi:addrinfo-addr ai)))
               (%check-addrinfo ai addr)
               (cffi:with-foreign-object (text :char 256)
                 (when (>= (ffi:uv-ip-name addr text 256) 0)
                   (let ((host (cffi:foreign-string-to-lisp text)))
                     (push (%make-address-info
                            :host host
                            :port (ffi:sockaddr-port addr)
                            ;; Classified by the same pure function that decides which
                            ;; uv_ip*_addr to call, so the two can never disagree.
                            :family (if (string= "ipv6" (types:address-family-name host))
                                        :ipv6
                                        :ipv4))
                           results))))))
    ;; getaddrinfo returns one entry per socket type unless hints narrow it; we ask for
    ;; SOCK_STREAM, and dedupe anyway so a platform that ignores the hint is harmless.
    (remove-duplicates (nreverse results)
                       :key (lambda (a) (cons (address-info-host a) (address-info-port a)))
                       :test #'equal :from-end t)))

(cffi:defcallback %getaddrinfo-callback :void
    ((req :pointer) (status :int) (res :pointer))
  (uv:with-callback-guard
    (let ((op (uv:lookup req)))
      (uv:deregister req)
      (unwind-protect
           (when op
             (if (minusp status)
                 (let* ((name (uv-ffi:uv-err-name status))
                        (condition (make-condition (uv:uv-error-class name)
                                                   :code status :name name
                                                   :message (uv-ffi:uv-strerror status)
                                                   :operation :resolve
                                                   :path (resolve-op-host op))))
                   ;; A name that does not resolve is an answer, not an escaped error.
                   (uv:fail-future (resolve-op-future op) condition)
                   (when (resolve-op-on-error op)
                     (funcall (resolve-op-on-error op) condition)))
                 (let ((results (%collect-addrinfo res)))
                   (uv:fulfill (resolve-op-future op) results)
                   (when (resolve-op-on-success op)
                     (funcall (resolve-op-on-success op) results)))))
        (unless (cffi:null-pointer-p res)
          (ffi:uv-freeaddrinfo res))
        (cffi:foreign-free req)))))

;;; -------------------------------------------------------------------- issuing

(defconstant +sock-stream+ 1
  "SOCK_STREAM. One of the few socket constants that is genuinely 1 on Linux, macOS and
Windows alike -- unlike AF_INET6, which is 10, 30 and 23 respectively and is why nothing
here compares address families numerically.")

(defmacro %with-hints ((var) &body body)
  "A zeroed addrinfo asking only for stream sockets, so one name does not come back three
times (one per socket type)."
  `(cffi:with-foreign-object (,var '(:struct ffi:addrinfo))
     (dotimes (i (cffi:foreign-type-size '(:struct ffi:addrinfo)))
       (setf (cffi:mem-aref ,var :unsigned-char i) 0))
     (setf (cffi:foreign-slot-value ,var '(:struct ffi:addrinfo) 'ffi::socktype)
           +sock-stream+)
     ,@body))

(defun resolve-async (loop host &key service on-success on-error)
  "Resolve HOST (optionally with SERVICE, a port number or service name) on LOOP.
Returns a FUTURE yielding a list of ADDRESS-INFO."
  (uv:ensure-available)
  (let* ((host (string host))
         (op (%make-resolve-op :future (uv:make-future) :host host
                               :on-success on-success :on-error on-error))
         (req (%new-request uv-ffi:+uv-getaddrinfo+ op)))
    (flet ((issue (node service-pointer)
             (%with-hints (hints)
               (let ((code (ffi:uv-getaddrinfo (uv:loop-pointer loop) req
                                               (cffi:callback %getaddrinfo-callback)
                                               node service-pointer hints)))
                 (when (minusp code)
                   ;; Rejected outright, so no callback will fire and this is the only
                   ;; place the request can be released.
                   (uv:deregister req)
                   (cffi:foreign-free req)
                   (uv:signal-uv-error code :operation :resolve :path host))))))
      ;; libuv copies both strings into the request, so they need not outlive this call.
      (cffi:with-foreign-string (node host)
        (if service
            (cffi:with-foreign-string (svc (princ-to-string service))
              (issue node svc))
            (issue node (cffi:null-pointer)))))
    (resolve-op-future op)))

(defun resolve (host &key service (timeout 30))
  "Resolve HOST and return a list of ADDRESS-INFO, blocking until it is answered.

Implemented on a private loop -- see the file header for why libuv's own synchronous
form is unreadable without groveling. Resolving many names is better done with
RESOLVE-ASYNC against a loop you already run."
  (uv:with-loop (l)
    (let ((future (resolve-async l host :service service)))
      (uv:run l :mode :default)
      (uv:await future :timeout timeout))))
