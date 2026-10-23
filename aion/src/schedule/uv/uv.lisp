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

(defun %end-loop (loop thread)
  "Stop LOOP's thread, wait for it to end however long that takes, then close LOOP. Only for a
loop whose thread has nothing long left to do: closing frees the memory a callback still running
on the thread would use, so the loop is never closed before the thread has ended (#694)."
  (uv:stop-loop-thread loop :timeout 0)
  (sb-thread:join-thread thread :default nil)
  (uv:close-loop loop))

(defun start (scheduler)
  "Tick SCHEDULER once on the calling thread, then from a libuv timer on a loop and loop thread of
its own, until S:STOP. Returns SCHEDULER. When S:STOP begins during that first tick, no loop is
started. Signals an error, and leaves no driver installed, when the loop thread cannot create the
timer."
  (let ((settle (s:reserve-driver scheduler))
        (settled nil))
    (flet ((tick-once ()
             (handler-case (s:tick scheduler)
               (error (e) (log:exception e "aion/schedule/uv: a tick failed")))))
      (unwind-protect
           (progn
             ;; The first tick is the caller's, as in S:START, so that when START returns the jobs
             ;; due at that moment have been started; the timer then waits for the next wake.
             (tick-once)
             (unless (s:scheduler-stopping-p scheduler)
               (%start-loop scheduler #'tick-once
                            (lambda (driver-stop)
                              (setf settled t)
                              (funcall settle driver-stop)))))
        (unless settled (funcall settle nil))))
    scheduler))

(defun %start-loop (scheduler tick-once settle)
  "Start the loop, its thread and its timer, then call SETTLE with the function that ends them."
  (let* ((loop (uv:make-loop))
         (timer nil)
         (failure nil)
         (thread nil)
         (ready (sb-thread:make-semaphore :name "aion/schedule/uv ready")))
    (labels ((delay-ms ()
               (* 1000 (handler-case (s:next-wake scheduler)
                         (error () (max 1 (floor (s:scheduler-lease-seconds scheduler) 3))))))
             (fire (tm)
               (funcall tick-once)
               (uv:start-timer tm :after (delay-ms)))
             (wake ()
               (handler-case (uv:submit loop (lambda () (when timer (uv:start-timer timer :after 0))))
                 (error () nil))))
      (setf thread (uv:start-loop-thread loop :name "aion/schedule/uv loop"))
      (uv:submit loop (lambda ()
                        (unwind-protect
                             (handler-case
                                 (let ((tm (uv:make-timer loop #'fire)))
                                   (uv:start-timer tm :after (delay-ms))
                                   (setf timer tm))
                               (error (e) (setf failure e)))
                          (sb-thread:signal-semaphore ready))))
      ;; No timeout that closes the loop: DELAY-MS reads the store, which can be slow, and the
      ;; loop must not be closed while its thread may still be in it (#694). The wait ends when
      ;; the thread has created the timer or failed to, or when the thread itself has ended.
      (loop until (sb-thread:wait-on-semaphore ready :timeout 1)
            unless (sb-thread:thread-alive-p thread)
              do (setf failure (or failure "the loop thread ended before it created the timer"))
                 (return))
      (when failure
        (%end-loop loop thread)
        (error "aion/schedule/uv: the driver's timer could not be started: ~A" failure))
      (setf (s:scheduler-wake-function scheduler) #'wake)
      (funcall settle
               ;; Ends the driver; true once the loop thread has ended, within SECONDS.
               (lambda (seconds)
                 (setf (s:scheduler-wake-function scheduler) nil)
                 ;; Asks the loop to stop and returns at once; the join below is the only wait, so
                 ;; the whole call stays within SECONDS. A tick on the thread may be in a long
                 ;; database call, and the loop is closed only once the thread has ended, because
                 ;; closing frees the memory the thread's timer callback would use. Until then the
                 ;; loop is kept, and a later S:STOP waits for the thread again.
                 (uv:stop-loop-thread loop :timeout 0)
                 (sb-thread:join-thread thread :timeout seconds :default nil)
                 (unless (sb-thread:thread-alive-p thread)
                   (uv:close-loop loop)
                   t)))
      (log:info "aion/schedule: started" :holder (s:scheduler-holder scheduler) :driver :uv))))
