;;;; uv.lisp --- aion/schedule/uv: drive a scheduler from a libuv timer (#689, ruling R1).
;;;;
;;;; The driver owns its loop and its loop thread. TICK reads the store, which for a database
;;;; store is a blocking query, so the scheduler does not share a loop whose other handles
;;;; would wait behind it.

(cl:defpackage #:aion/schedule/uv
  (:use #:cl)
  (:local-nicknames (#:s #:aion/schedule)
                    (#:uv #:aion/uv)
                    (#:log #:aion/log))
  (:documentation "START drives an aion/schedule scheduler from a libuv timer on a loop of its
    own: the timer ticks the scheduler and is restarted for its NEXT-WAKE. S:STOP stops it.")
  (:export #:start))

(in-package #:aion/schedule/uv)

(defun start (scheduler)
  "Tick SCHEDULER from a libuv timer on a loop and loop thread of its own, until S:STOP. Returns
SCHEDULER."
  (when (s:scheduler-driver-stop scheduler)
    (error "aion/schedule/uv: this scheduler already has a driver."))
  (let* ((loop (uv:make-loop))
         (timer nil)
         (ready (sb-thread:make-semaphore :name "aion/schedule/uv ready")))
    (labels ((fire (tm)
               (handler-case (s:tick scheduler)
                 (error (e) (log:exception e "aion/schedule/uv: a tick failed")))
               (let ((delay (handler-case (s:next-wake scheduler)
                              (error () (max 1 (floor (s:scheduler-lease-seconds scheduler) 3))))))
                 (uv:start-timer tm :after (* 1000 delay))))
             (wake ()
               (handler-case (uv:submit loop (lambda () (when timer (uv:start-timer timer :after 0))))
                 (error () nil))))
      (uv:start-loop-thread loop :name "aion/schedule/uv loop")
      (uv:submit loop (lambda ()
                        (unwind-protect
                             (progn (setf timer (uv:make-timer loop #'fire))
                                    (uv:start-timer timer :after 0))
                          (sb-thread:signal-semaphore ready))))
      (unless (sb-thread:wait-on-semaphore ready :timeout 10)
        (uv:close-loop loop)
        (error "aion/schedule/uv: the loop thread did not start the timer within 10 seconds."))
      (setf (s:scheduler-wake-function scheduler) #'wake
            (s:scheduler-driver-stop scheduler)
            (lambda ()
              (setf (s:scheduler-wake-function scheduler) nil)
              ;; CLOSE-LOOP stops the loop thread, then closes the timer with the loop's
              ;; other handles.
              (uv:close-loop loop)))
      (log:info "aion/schedule: started" :holder (s:scheduler-holder scheduler) :driver :uv)
      scheduler)))
