;;;; schedule-uv.lisp --- aion/schedule/uv: the libuv driver ticks, wakes and stops (#689).

(cl:defpackage #:aion/schedule/uv/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:s #:aion/schedule)
                    (#:suv #:aion/schedule/uv))
  (:export #:run-tests))

(in-package #:aion/schedule/uv/tests)

(def-suite schedule-uv :description "aion/schedule/uv: the libuv driver.")
(in-suite schedule-uv)

(defun run-tests ()
  (let ((results (run 'schedule-uv)))
    (explain! results)
    (unless (results-status results) (error "aion/schedule/uv tests failed"))))

(defun wait-until (test &key (timeout 5))
  (let ((deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
    (loop (when (funcall test) (return t))
          (when (> (get-internal-real-time) deadline) (return nil))
          (sleep 0.005))))

(defun driver-thread ()
  (find "aion/schedule/uv loop" (sb-thread:list-all-threads)
        :key #'sb-thread:thread-name :test #'equal))

(test the-uv-driver-ticks-wakes-and-stops
  (let* ((store (s:make-memory-job-store))
         (clock (s:make-manual-clock 3990000000))
         (a (s:make-scheduler store :clock clock))
         (n (list 0)))
    (unwind-protect
         (progn
           (s:define-job a "j" (lambda (ctx) (declare (ignore ctx)) (incf (car n)) nil)
                         :schedule '(:every 60))
           (suv:start a)
           (let ((thread (driver-thread)))
             (is-true thread "START runs the loop on a thread of its own")
             (signals error (suv:start a) "a scheduler has one driver")
             (s:clock-advance clock 60)
             (sleep 0.2)
             (is (= 0 (car n)) "the timer is set for the next wake, not polling")
             (funcall (s:scheduler-wake-function a))
             (is-true (wait-until (lambda () (= 1 (car n)))) "a wake makes it tick")
             (is (eq :stopped (s:stop a :timeout 5)))
             (is-true (wait-until (lambda () (not (sb-thread:thread-alive-p thread))))
                      "STOP ends the loop thread")
             (is (null (s:scheduler-wake-function a)))))
      (s:stop a :timeout 5))))

(defclass gated-store (s:memory-job-store)
  ((hold :initform nil :accessor hold)
   (entered :initform (sb-thread:make-semaphore) :reader entered)
   (gate :initform (sb-thread:make-semaphore) :reader gate)))

(defmethod s:store-jobs :before ((store gated-store))
  (when (hold store)
    (setf (hold store) nil)
    (sb-thread:signal-semaphore (entered store))
    (sb-thread:wait-on-semaphore (gate store))))

(test stop-keeps-the-loop-while-a-tick-is-still-on-its-thread
  (let* ((store (make-instance 'gated-store))
         (a (s:make-scheduler store :clock (s:make-manual-clock 3990000000))))
    (suv:start a)
    (let ((thread (driver-thread)))
      (setf (hold store) t)
      (funcall (s:scheduler-wake-function a))
      (sb-thread:wait-on-semaphore (entered store))
      (let ((start (get-internal-real-time)))
        (is (eq :timed-out (s:stop a :timeout 1)) "the tick holds the loop thread")
        (is (< (/ (- (get-internal-real-time) start) internal-time-units-per-second) 1.6)
            "and STOP gives up within its timeout, not twice it"))
      (is-true (sb-thread:thread-alive-p thread))
      (sb-thread:signal-semaphore (gate store))
      (is (eq :stopped (s:stop a :timeout 5)) "a later STOP closes the loop")
      (is-true (wait-until (lambda () (not (sb-thread:thread-alive-p thread))))))))

(test a-timer-that-cannot-be-made-fails-start-and-installs-no-driver
  (let ((a (s:make-scheduler (s:make-memory-job-store)
                             :clock (s:make-manual-clock 3990000000))))
    (sb-int:encapsulate 'aion/uv:make-timer 'refuse
                        (lambda (f &rest args) (declare (ignore f args)) (error "no timer today")))
    (unwind-protect
         (signals error (suv:start a))
      (sb-int:unencapsulate 'aion/uv:make-timer 'refuse))
    (is (null (s:scheduler-driver-stop a)) "no driver is installed")
    (is (null (s:scheduler-wake-function a)))
    (is-true (wait-until (lambda () (null (driver-thread)))) "and the loop thread has ended")
    (is (eq :stopped (s:stop a :timeout 5)))))

(test start-refuses-a-scheduler-that-is-stopping
  (let ((a (s:make-scheduler (s:make-memory-job-store)
                             :clock (s:make-manual-clock 3990000000))))
    (is (eq :stopped (s:stop a :timeout 5)))
    (signals s:scheduler-stopped (suv:start a))
    (is (null (driver-thread)) "and starts no loop thread")))
