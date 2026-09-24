;;;; test-threads-tests.lisp --- the thread-waiting helpers, tested against threads built to
;;;; misbehave.
;;;;
;;;; aion/test-threads is what every other suite relies on to fail a test by name instead of
;;;; hanging the run (#178). Until this suite, its timeout and abort paths had been measured
;;;; by hand once and asserted nowhere, so a change that broke them would have been invisible:
;;;; the helpers are only ever reached on the path where some OTHER test has already gone
;;;; wrong.

(cl:defpackage #:aion/test-threads/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:tt #:aion/test-threads))
  (:export #:run-tests))

(in-package #:aion/test-threads/tests)

(def-suite test-threads :description "JOIN and JOIN-ALL: values, deadlines, aborted threads.")
(in-suite test-threads)

(defun run-tests () (run! 'test-threads))

(defun %seconds-since (t0)
  (/ (- (get-internal-real-time) t0) internal-time-units-per-second))

(defun %sleeper (seconds name)
  (sb-thread:make-thread (lambda () (sleep seconds)) :name name))

(defun %stop-all (threads)
  "End any thread a test left running, so a sleeper cannot outlive the test that made it."
  (dolist (th threads)
    (when (sb-thread:thread-alive-p th)
      (ignore-errors (sb-thread:terminate-thread th))
      (ignore-errors (sb-thread:join-thread th :timeout 5 :default nil)))))

(test join-returns-the-thread-s-value
  (is (= 42 (tt:join (sb-thread:make-thread (lambda () 42))))))

(test join-gives-up-at-its-timeout-and-names-the-thread
  (let ((th (%sleeper 10 "a-slow-worker"))
        (t0 (get-internal-real-time)))
    (unwind-protect
         (let ((message (handler-case (progn (tt:join th :timeout 1) nil)
                          (error (e) (princ-to-string e)))))
           (is (stringp message) "JOIN of a thread still running after its timeout must signal")
           (is (and message (search "a-slow-worker" message))
               "and the error must name the thread, got: ~S" message)
           (is (< (%seconds-since t0) 3)
               "and it must give up at about its 1 s timeout, not wait for the thread"))
      (%stop-all (list th)))))

(test join-of-an-aborted-thread-is-an-error-not-a-value
  ;; A plain join signals here, and JOIN keeps that: an aborted thread returning NIL would
  ;; read as a thread that returned NIL on purpose.
  (let ((th (sb-thread:make-thread (lambda () (sb-thread:abort-thread)) :name "an-aborted-worker")))
    (let ((message (handler-case (progn (tt:join th) nil)
                     (error (e) (princ-to-string e)))))
      (is (and message (search "an-aborted-worker" message))
          "an aborted thread must be an error naming it, got: ~S" message))))

(test join-all-returns-every-value-in-order
  (is (equal '(1 2 3)
             (tt:join-all (list (sb-thread:make-thread (lambda () 1))
                                (sb-thread:make-thread (lambda () (sleep 0.1) 2))
                                (sb-thread:make-thread (lambda () 3)))))))

(test join-all-has-one-deadline-for-the-whole-group
  ;; The property a per-thread deadline would break. The threads finish 0.7 s apart, each
  ;; gap SHORTER than the 1 s timeout, so a deadline restarted for every thread would accept
  ;; them all and return after 3.5 s. One deadline for the group expires at 1 s, while the
  ;; second thread is still running. A group in which every thread outlives the timeout
  ;; would not tell the two apart: either way the first join gives up at 1 s.
  (let ((threads (loop for i from 1 to 5
                       collect (let ((seconds (* i 0.7)))
                                 (sb-thread:make-thread (lambda () (sleep seconds))
                                                        :name (format nil "group-worker-~D" i)))))
        (t0 (get-internal-real-time)))
    (unwind-protect
         (let ((message (handler-case (progn (tt:join-all threads :timeout 1) nil)
                          (error (e) (princ-to-string e)))))
           (is (stringp message)
               "the group was not finished at 1 s, so JOIN-ALL must signal; a per-thread deadline would not")
           (is (and message (search "group-worker-2" message))
               "and name the first thread not finished by the deadline, got: ~S" message)
           (is (< (%seconds-since t0) 2)
               "one 1 s deadline for the group; took ~,2F s" (%seconds-since t0)))
      (%stop-all threads))))
