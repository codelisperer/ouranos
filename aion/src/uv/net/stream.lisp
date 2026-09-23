;;;; stream.lisp --- reading, writing, and the backpressure that makes them safe together.
;;;;
;;;; A uv_stream_t is the shared shape behind TCP sockets and pipes, so everything here
;;;; works on both and tcp.lisp adds only what is TCP-specific.
;;;;
;;;; BACKPRESSURE IS THE DESIGN, NOT A FEATURE OF IT.
;;;;
;;;; Node shipped streams three times -- 2010, 2012, 2013 -- because the first two made
;;;; backpressure advisory. A producer that cannot be STOPPED will outrun a slow consumer,
;;;; and the queue between them grows until the process dies; being able to ask "is the
;;;; consumer keeping up?" does not help if nothing enforces the answer. The lesson has
;;;; three consequences here, and they are why this file is shaped the way it is:
;;;;
;;;;   * STOP-READING is half of START-READING, not an extra. libuv gives us uv_read_stop
;;;;     precisely so a reader can shut the tap; a binding that exposes only read_start
;;;;     has reimplemented the 2010 mistake with different syntax.
;;;;   * The write queue is observable. uv_stream_get_write_queue_size is the signal --
;;;;     the same number Node surfaces as writable.writableLength -- and it is what the
;;;;     high-water mark is compared against.
;;;;   * PIPE-INTO wires the two together ITSELF. The composed case (read from A, write to
;;;;     B) is the one that matters, and if it requires the caller to pause and resume by
;;;;     hand then in practice nobody will, and the API will be advisory again. So the
;;;;     composition owns the policy.
;;;;
;;;; The high and low marks are deliberately DIFFERENT numbers. Resuming at the level you
;;;; paused at means pausing again on the very next write; the gap is what stops the pair
;;;; oscillating. See DRAINED? in types.lisp.
;;;;
;;;; THREADING. Every operation here touches loop state, so it obeys rule 1 from
;;;; aion/uv's loop.lisp: call it on the loop thread, or hand it over with UV:SUBMIT.
;;;; Handlers are invoked ON THE LOOP THREAD and should hand work off rather than block.
;;;; Errors escaping them are caught and kept in UV:*CALLBACK-ERRORS* rather than
;;;; swallowed, because a silent event loop is the hardest thing there is to debug.

(in-package #:aion/uv/net)

;;; ------------------------------------------------------------------ constants

(defconstant +default-high-water-mark+ (* 64 1024)
  "Queued bytes at which a producer must be paused. Ours, not libuv's -- libuv has no
opinion and will happily queue until memory runs out.")

(defconstant +default-low-water-mark+ (* 16 1024)
  "Queued bytes at which a paused producer may resume. Lower than the high mark on
purpose; see DRAINED? in types.lisp.")

(defconstant +read-buffer-size+ (* 64 1024)
  "Size of the per-connection read buffer handed to libuv's alloc callback. One buffer
per connection, reused: reads for a single stream are delivered in order on one thread,
so there is never a second read in flight to collide with it.")

;;; ----------------------------------------------------------------- conditions

(define-condition stream-closed (uv:uv-error) ()
  (:documentation
   "The connection was closed before the operation could be completed. Ours rather than
libuv's -- the same shape as AWAIT-TIMEOUT in aion/uv, so callers still catch a single
UV-ERROR family."))

(defun %closed-error (operation)
  (make-condition 'stream-closed
                  :code 0 :name "ECANCELED" :operation operation
                  :message "the connection was closed"))

;;; ---------------------------------------------------------------- connections

(defstruct (connection (:constructor %make-connection))
  "One connected stream: an accepted socket, a dialled socket, or a pipe."
  pointer loop (kind :tcp)
  (reading nil) (paused nil) (closed nil)
  on-data on-end on-error
  (read-buffer nil)
  (high-water-mark +default-high-water-mark+)
  (low-water-mark +default-low-water-mark+)
  (drain-hooks '()))

(defun reading-p (connection) (connection-reading connection))
(defun paused-p (connection) (connection-paused connection))

(defun %ensure-open (connection operation)
  (when (connection-closed connection)
    (error (%closed-error operation)))
  connection)

;;; ------------------------------------------------------------------- reading

(cffi:defcallback %alloc-callback :void
    ((handle :pointer) (suggested :size) (buf :pointer))
  (declare (ignore suggested))
  ;; libuv asks where to put the bytes. We answer with the connection's own buffer; if we
  ;; cannot find the connection we answer with nothing, and libuv reports UV_ENOBUFS to
  ;; the read callback rather than writing into a pointer we did not mean.
  (uv:with-callback-guard
    (let ((connection (uv:lookup handle)))
      (multiple-value-bind (base len)
          (if (and (connection-p connection) (connection-read-buffer connection))
              (values (connection-read-buffer connection) +read-buffer-size+)
              (values (cffi:null-pointer) 0))
        (setf (cffi:foreign-slot-value buf '(:struct uv-ffi:uv-buf-t) 'uv-ffi::base) base
              (cffi:foreign-slot-value buf '(:struct uv-ffi:uv-buf-t) 'uv-ffi::len) len)))))

(defun %octets-from (base count)
  (let ((octets (make-array count :element-type '(unsigned-byte 8))))
    (dotimes (i count octets)
      (setf (aref octets i) (cffi:mem-aref base :unsigned-char i)))))

(cffi:defcallback %read-callback :void
    ((stream :pointer) (nread uv-ffi:ssize) (buf :pointer))
  (uv:with-callback-guard
    (let ((connection (uv:lookup stream)))
      (when (connection-p connection)
        ;; The four meanings of one integer, separated by the typed core rather than by
        ;; an if-chain here. Dispatch is on libuv's error NAME, never its number.
        (let* ((name (if (minusp nread) (uv-ffi:uv-err-name nread) ""))
               (tag (types:read-outcome-tag nread name)))
          (cond
            ((string= tag "bytes")
             (let ((base (cffi:foreign-slot-value buf '(:struct uv-ffi:uv-buf-t)
                                                  'uv-ffi::base)))
               (when (connection-on-data connection)
                 (funcall (connection-on-data connection)
                          (%octets-from base nread)
                          connection))))
            ;; Not an error and not an end: libuv had nothing this time. A binding that
            ;; treats this as either will drop healthy connections.
            ((string= tag "nothing-yet") nil)
            ((string= tag "end-of-stream")
             (ignore-errors (ffi:uv-read-stop stream))
             (setf (connection-reading connection) nil)
             (when (connection-on-end connection)
               (funcall (connection-on-end connection) connection)))
            (t
             (let ((condition (make-condition (uv:uv-error-class name)
                                              :code nread :name name
                                              :message (uv-ffi:uv-strerror nread)
                                              :operation :read)))
               (if (connection-on-error connection)
                   (funcall (connection-on-error connection) condition connection)
                   (uv:note-callback-error condition))))))))))

(defun %ensure-read-buffer (connection)
  (or (connection-read-buffer connection)
      (setf (connection-read-buffer connection)
            (cffi:foreign-alloc :unsigned-char :count +read-buffer-size+))))

(defun start-reading (connection on-data &key on-end on-error)
  "Begin delivering data from CONNECTION.

ON-DATA is called with (OCTETS CONNECTION) for each chunk, ON-END with (CONNECTION) when
the peer finishes, ON-ERROR with (CONDITION CONNECTION) on failure. All three run ON THE
LOOP THREAD. Without ON-ERROR, errors are kept in UV:*CALLBACK-ERRORS*.

Chunk boundaries are not message boundaries -- TCP is a byte stream, and one write by
the peer may arrive as three chunks or three writes as one. Framing belongs to whatever
protocol is layered on top."
  (%ensure-open connection :start-reading)
  (setf (connection-on-data connection) on-data
        (connection-on-end connection) on-end
        (connection-on-error connection) on-error)
  (%ensure-read-buffer connection)
  (uv:check (ffi:uv-read-start (connection-pointer connection)
                               (cffi:callback %alloc-callback)
                               (cffi:callback %read-callback))
            :operation :start-reading)
  (setf (connection-reading connection) t
        (connection-paused connection) nil)
  connection)

(defun stop-reading (connection)
  "Stop delivering data. The handlers are kept, so RESUME-READING can restart delivery.

This is the half of the read API that makes backpressure enforceable rather than
advisory: it stops the PRODUCER, which is the only thing that actually helps."
  (when (and (connection-reading connection) (not (connection-closed connection)))
    (uv:check (ffi:uv-read-stop (connection-pointer connection)) :operation :stop-reading)
    (setf (connection-reading connection) nil))
  connection)

(defun pause-reading (connection)
  "Stop reading and remember that it was for backpressure, so RESUME-READING is expected."
  (stop-reading connection)
  (setf (connection-paused connection) t)
  connection)

(defun resume-reading (connection)
  "Restart delivery to the handlers START-READING was given."
  (when (and (connection-paused connection)
             (not (connection-closed connection))
             (not (connection-reading connection)))
    (uv:check (ffi:uv-read-start (connection-pointer connection)
                                 (cffi:callback %alloc-callback)
                                 (cffi:callback %read-callback))
              :operation :resume-reading)
    (setf (connection-reading connection) t
          (connection-paused connection) nil))
  connection)

;;; ------------------------------------------------------------------- writing

(defstruct (write-op (:constructor %make-write-op))
  "One uv_write_t or uv_shutdown_t in flight, and everything that must be released when
it completes. Held in the pointer registry keyed by the request, never in the request's
own `data` field -- SBCL's GC moves Lisp objects."
  connection future buffer operation on-complete on-error (size 0))

(defun %settle-write (op status)
  (let ((connection (write-op-connection op)))
    (if (minusp status)
        (let* ((name (uv-ffi:uv-err-name status))
               (condition (make-condition (uv:uv-error-class name)
                                          :code status :name name
                                          :message (uv-ffi:uv-strerror status)
                                          :operation (write-op-operation op))))
          ;; The FUTURE is the error channel for anything that returns one -- the same
          ;; convention as aion/uv's fs operations. Reporting it on *error-output* as
          ;; well would make ordinary graceful teardown noisy: shutting down the write
          ;; side and then closing the handle cancels the shutdown request, which is
          ;; correct behaviour and arrives here as ECANCELED. Pass ON-ERROR if you are
          ;; not awaiting the future.
          (uv:fail-future (write-op-future op) condition)
          (when (write-op-on-error op)
            (funcall (write-op-on-error op) condition)))
        (progn
          (uv:fulfill (write-op-future op) (write-op-size op))
          (when (write-op-on-complete op)
            (funcall (write-op-on-complete op) (write-op-size op)))))
    ;; Whatever the outcome, the queue just got shorter -- which is exactly when a paused
    ;; producer may be allowed to start again.
    (when (connection-p connection)
      (%run-drain-hooks connection))))

(cffi:defcallback %write-callback :void ((req :pointer) (status :int))
  (uv:with-callback-guard
    (let ((op (uv:lookup req)))
      (uv:deregister req)
      (unwind-protect (when op (%settle-write op status))
        (when (and op (write-op-buffer op))
          (cffi:foreign-free (write-op-buffer op)))
        (cffi:foreign-free req)))))

(defun %new-request (type op)
  (let ((req (cffi:foreign-alloc :char :count (uv-ffi:uv-req-size type))))
    (uv:register req op)
    req))

(defun write-bytes (connection octets &key on-complete on-error)
  "Queue OCTETS (or a string, encoded UTF-8) for writing. Returns a FUTURE for the byte
count; ON-COMPLETE / ON-ERROR run on the loop thread when it settles.

Returns as soon as the write is QUEUED, which is the point of the write queue -- and the
reason WRITE-QUEUE-SIZE and SATURATED-P exist. A producer that ignores them can queue
without bound."
  (%ensure-open connection :write-bytes)
  (let* ((octets (if (stringp octets)
                     (sb-ext:string-to-octets octets :external-format :utf-8)
                     (coerce octets '(vector (unsigned-byte 8)))))
         (size (length octets))
         (buffer (cffi:foreign-alloc :unsigned-char :count (max size 1)))
         (op (%make-write-op :connection connection :future (uv:make-future)
                             :buffer buffer :operation :write-bytes :size size
                             :on-complete on-complete :on-error on-error))
         (req (%new-request uv-ffi:+uv-write+ op)))
    (dotimes (i size)
      (setf (cffi:mem-aref buffer :unsigned-char i) (aref octets i)))
    ;; libuv copies the uv_buf_t ARRAY into the request, so the array may be stack-bound
    ;; here -- but the bytes it points at must outlive the call, which is why the buffer
    ;; is owned by the op and freed in the callback.
    (cffi:with-foreign-object (bufs '(:struct uv-ffi:uv-buf-t))
      (setf (cffi:foreign-slot-value bufs '(:struct uv-ffi:uv-buf-t) 'uv-ffi::base) buffer
            (cffi:foreign-slot-value bufs '(:struct uv-ffi:uv-buf-t) 'uv-ffi::len) size)
      (let ((code (ffi:uv-write req (connection-pointer connection) bufs 1
                                (cffi:callback %write-callback))))
        (when (minusp code)
          ;; Rejected outright: no callback will ever fire, so this is the only place the
          ;; request and buffer can be released. Same invariant as fs.lisp's %ISSUE.
          (uv:deregister req)
          (cffi:foreign-free buffer)
          (cffi:foreign-free req)
          (uv:signal-uv-error code :operation :write-bytes))))
    (write-op-future op)))

(defun shutdown-write (connection &key on-complete on-error)
  "Close our WRITE side, letting the peer see end-of-stream while we can still read.
Returns a FUTURE. This is the graceful half-close TCP allows and an abrupt close does
not; CLOSE-HANDLE afterwards releases the handle."
  (%ensure-open connection :shutdown-write)
  (let* ((op (%make-write-op :connection connection :future (uv:make-future)
                             :buffer nil :operation :shutdown-write :size 0
                             :on-complete on-complete :on-error on-error))
         (req (%new-request uv-ffi:+uv-shutdown+ op))
         (code (ffi:uv-shutdown req (connection-pointer connection)
                                (cffi:callback %write-callback))))
    (when (minusp code)
      (uv:deregister req)
      (cffi:foreign-free req)
      (uv:signal-uv-error code :operation :shutdown-write))
    (write-op-future op)))

;;; -------------------------------------------------------------- backpressure

(defun write-queue-size (connection)
  "Bytes queued for writing and not yet handed to the OS. The backpressure signal."
  (if (connection-closed connection)
      0
      (ffi:uv-stream-get-write-queue-size (connection-pointer connection))))

(defun saturated-p (connection &key high-water-mark)
  "True when CONNECTION has more queued than it should, and its producer must stop."
  (types:saturated? (write-queue-size connection)
                    (or high-water-mark (connection-high-water-mark connection))))

(defun %run-drain-hooks (connection)
  "Run whatever was waiting for the queue to drain, once it actually has."
  (when (and (connection-drain-hooks connection)
             (types:drained? (write-queue-size connection)
                             (connection-low-water-mark connection)))
    (let ((hooks (connection-drain-hooks connection)))
      (setf (connection-drain-hooks connection) '())
      (dolist (hook (reverse hooks))
        (handler-case (funcall hook)
          (error (e) (uv:note-callback-error e)))))))

(defun pipe-into (source destination &key on-end
                                          (high-water-mark +default-high-water-mark+)
                                          (low-water-mark +default-low-water-mark+))
  "Read everything from SOURCE and write it to DESTINATION, APPLYING BACKPRESSURE.

This is the composed case, and it carries the policy so the caller does not have to:
when DESTINATION's write queue reaches HIGH-WATER-MARK, SOURCE is paused; when it falls
back to LOW-WATER-MARK, SOURCE resumes. Nothing is buffered in Lisp in between.

That is the whole lesson of Node's three stream rewrites in one function. An API where
the caller must remember to pause is an API where the caller does not, and the failure
mode -- unbounded memory growth under a slow consumer -- appears only in production.

When SOURCE ends, DESTINATION's write side is shut down so the far end sees the end of
the stream too, and ON-END is called."
  (setf (connection-high-water-mark destination) high-water-mark
        (connection-low-water-mark destination) low-water-mark)
  (start-reading
   source
   (lambda (octets connection)
     (declare (ignore connection))
     (write-bytes destination octets)
     (when (saturated-p destination)
       (pause-reading source)
       ;; At most one hook can be queued per pause: while SOURCE is paused no further
       ;; data arrives, so this cannot run away.
       (push (lambda () (resume-reading source))
             (connection-drain-hooks destination))))
   :on-end (lambda (connection)
             (declare (ignore connection))
             (ignore-errors (shutdown-write destination))
             (when on-end (funcall on-end))))
  source)

;;; --------------------------------------------------------------------- close

(defmethod uv:close-handle ((connection connection))
  (let ((pointer (connection-pointer connection))
        (buffer (connection-read-buffer connection)))
    (unless (connection-closed connection)
      (setf (connection-closed connection) t
            (connection-reading connection) nil
            (connection-drain-hooks connection) '())
      (when pointer
        (ignore-errors (ffi:uv-read-stop pointer))
        (setf (uv:loop-owned (connection-loop connection))
              (remove pointer (uv:loop-owned (connection-loop connection))))
        ;; The read buffer is freed by the close callback, not here: libuv is still
        ;; using the handle until it fires, and an eager free is a use-after-free that
        ;; surfaces later as unrelated corruption.
        (uv:close-pointer pointer
                          :finalizer (lambda ()
                                       (when buffer (cffi:foreign-free buffer))))
        (setf (connection-pointer connection) nil
              (connection-read-buffer connection) nil)))))
