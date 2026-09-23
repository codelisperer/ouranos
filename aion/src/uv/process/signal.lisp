;;;; signal.lisp --- uv_signal_t: SIGINT, SIGTERM and friends, delivered as events.
;;;;
;;;; The point of doing this through libuv rather than sb-sys:enable-interrupt is that the
;;;; handler runs as an ordinary loop callback, on the loop thread, with a full Lisp stack
;;;; -- not in a signal context where the set of things it is safe to do is small and the
;;;; consequences of exceeding it are not an error message. That is the same property that
;;;; makes every other callback in this binding safe, applied to the one case where CL's
;;;; own facility is most dangerous.
;;;;
;;;; A STARTED SIGNAL HANDLE HOLDS THE LOOP OPEN. For a supervisor -- the `service` target
;;;; kind (#37) -- that is exactly right: the process should stay up waiting for SIGTERM.
;;;; For a script it is the classic surprise, and the answer is UNWATCH-SIGNAL, or
;;;; (uv:describe-loop l), which will name this handle as the thing holding it.
;;;;
;;;; WINDOWS. libuv emulates a subset: SIGINT, SIGBREAK, SIGHUP and SIGWINCH are
;;;; deliverable to a signal handle; the rest are not. Unverified here -- see
;;;; aion/docs/uv-process-design.md.

(in-package #:aion/uv/process)

(defstruct (signal-watcher (:constructor %make-signal-watcher))
  "A started uv_signal_t and the function it calls."
  pointer loop function signal (closed nil))

(cffi:defcallback %signal-callback :void ((handle :pointer) (signum :int))
  (uv:with-callback-guard
    (let ((watcher (uv:lookup handle)))
      (when (signal-watcher-p watcher)
        (funcall (signal-watcher-function watcher)
                 ;; The name, not the number: the numbers that matter agree across
                 ;; Linux and macOS, but a caller should never have to know that.
                 (types:signal-name signum)
                 watcher)))))

(defun watch-signal (loop signal function &key oneshot)
  "Call FUNCTION with (SIGNAL-NAME WATCHER) whenever SIGNAL arrives, on the loop thread.

SIGNAL is a keyword (:INT, :TERM, :HUP, ...) or a number. With ONESHOT the handle stops
itself after the first delivery, which is the right shape for \"shut down on the first
SIGTERM\" and avoids the second one being handled by a half-torn-down system."
  (uv:ensure-available)
  (let* ((signum (%signal-number signal))
         (pointer (cffi:foreign-alloc :char
                                      :count (uv-ffi:uv-handle-size uv-ffi:+uv-signal+)))
         (code (ffi:uv-signal-init (uv:loop-pointer loop) pointer)))
    (when (minusp code)
      ;; Not yet initialised, so freeing is correct here and nowhere later.
      (cffi:foreign-free pointer)
      (uv:signal-uv-error code :operation :watch-signal))
    (let ((watcher (%make-signal-watcher :pointer pointer :loop loop
                                         :function function :signal signal)))
      (uv:register pointer watcher)
      (push pointer (uv:loop-owned loop))
      (handler-bind ((error (lambda (e) (declare (ignore e))
                              (ignore-errors (unwatch-signal watcher)))))
        (uv:check (if oneshot
                      (ffi:uv-signal-start-oneshot pointer
                                                   (cffi:callback %signal-callback)
                                                   signum)
                      (ffi:uv-signal-start pointer
                                           (cffi:callback %signal-callback)
                                           signum))
                  :operation :watch-signal))
      watcher)))

(defun unwatch-signal (watcher)
  "Stop delivering, and release the handle. Idempotent."
  (unless (signal-watcher-closed watcher)
    (setf (signal-watcher-closed watcher) t)
    (let ((pointer (signal-watcher-pointer watcher)))
      (when pointer
        (ignore-errors (ffi:uv-signal-stop pointer))
        (setf (uv:loop-owned (signal-watcher-loop watcher))
              (remove pointer (uv:loop-owned (signal-watcher-loop watcher))))
        (uv:close-pointer pointer)
        (setf (signal-watcher-pointer watcher) nil))))
  watcher)

(defmethod uv:close-handle ((watcher signal-watcher))
  (unwatch-signal watcher))
