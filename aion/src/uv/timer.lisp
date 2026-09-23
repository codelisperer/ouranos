;;;; timer.lisp --- timers.
;;;;
;;;; A timer is a handle, not a request: it belongs to a loop, fires on the loop thread,
;;;; and lives until it is explicitly closed. That lifetime is the whole difficulty --
;;;; the handle's memory must stay valid until libuv's close callback says otherwise,
;;;; which is why CLOSE-HANDLE (in loop.lisp) frees it rather than the caller.

(in-package #:aion/uv)

(defstruct (timer (:constructor %make-timer))
  pointer loop function (repeating nil))

(cffi:defcallback %timer-callback :void ((handle :pointer))
  (with-callback-guard
    (let ((timer (lookup handle)))
      (when (and timer (timer-function timer))
        (funcall (timer-function timer) timer)))))

(defun make-timer (loop function)
  "Create a timer on LOOP that calls FUNCTION (with the timer) when it fires.
The timer does not run until START-TIMER."
  (ensure-available)
  (let ((pointer (cffi:foreign-alloc :char :count (ffi:uv-handle-size ffi:+uv-timer+))))
    (handler-bind ((error (lambda (e) (declare (ignore e)) (cffi:foreign-free pointer))))
      (check (ffi:uv-timer-init (loop-pointer loop) pointer) :operation :make-timer))
    (let ((timer (%make-timer :pointer pointer :loop loop :function function)))
      (register pointer timer)
      (push pointer (loop-owned loop))
      timer)))

(defun start-timer (timer &key (after 0) (every nil))
  "Start TIMER. AFTER is the delay in milliseconds before the first call; EVERY, if
given, is the interval in milliseconds for repeats. Restarting a running timer
reschedules it."
  (setf (timer-repeating timer) (and every (plusp every)))
  (check (ffi:uv-timer-start (timer-pointer timer)
                             (cffi:callback %timer-callback)
                             (max 0 after)
                             (or every 0))
         :operation :start-timer)
  timer)

(defun stop-timer (timer)
  "Stop TIMER without destroying it. It can be started again."
  (check (ffi:uv-timer-stop (timer-pointer timer)) :operation :stop-timer)
  timer)

(defmethod close-handle ((timer timer))
  (let ((pointer (timer-pointer timer)))
    (setf (loop-owned (timer-loop timer))
          (remove pointer (loop-owned (timer-loop timer))))
    (close-handle pointer)
    (setf (timer-pointer timer) nil)))
