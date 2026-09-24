;;;; test-threads.lisp --- waiting for a thread a test started, with a deadline.
;;;;
;;;; A plain join waits forever, so a thread that never finished would hold the whole test
;;;; run until CI killed the job, and the log would not say which test was waiting (#178).
;;;; These wait at most a deadline and then signal an error that names the thread, so the
;;;; test that started it fails by name and the run continues.
;;;;
;;;; In aion because aion is the one framework every other may depend on: the test systems
;;;; of aion, hyperion and praxeon all wait for threads, and each used to do it without a
;;;; deadline (or, in hyperion's server-uv suite, with a private copy of this).

(cl:defpackage #:aion/test-threads
  (:use #:cl)
  (:export #:join #:join-all #:+default-timeout+))

(in-package #:aion/test-threads)

(defparameter +default-timeout+ 20
  "Seconds JOIN and JOIN-ALL wait by default. Longer than any single request or operation
a test is expected to make, so a thread that is merely slow finishes first.")

(defun %join-by (thread deadline timeout)
  ;; NONE is what JOIN-THREAD returns in place of a value when the thread did not finish.
  ;; Only then is its second value the reason. When the thread finished, JOIN-THREAD returns
  ;; the thread's own values, so a thread returning (VALUES 1 :TIMEOUT) is a normal return of
  ;; 1; reading the second value alone mistook it for a timeout.
  (let ((left (/ (- deadline (get-internal-real-time)) internal-time-units-per-second))
        (none '#:none))
    (multiple-value-bind (value outcome)
        (cond ((plusp left) (sb-thread:join-thread thread :timeout left :default none))
              ;; No time left: a TIMEOUT of 0, or a JOIN-ALL deadline that passed while an
              ;; earlier thread was being joined. JOIN-THREAD refuses a timeout of 0 with a
              ;; TYPE-ERROR that names no thread (#246), so decide here instead. A thread still
              ;; running has missed the deadline; a finished one is joined with no timeout,
              ;; which returns at once.
              ((sb-thread:thread-alive-p thread) (values none :timeout))
              (t (sb-thread:join-thread thread :default none)))
      (cond ((not (eq value none)) value)
            ((eq outcome :timeout)
             (error "the thread ~A did not finish within ~D seconds"
                    (sb-thread:thread-name thread) timeout))
            ;; An aborted thread has no value to return. A plain join signals an error here too.
            (t (error "the thread ~A ended without returning a value"
                      (sb-thread:thread-name thread)))))))

(defun join (thread &key (timeout +default-timeout+))
  "Wait for THREAD and return its value. Signal an error naming it if it has not finished
after TIMEOUT seconds, or if it ended without returning a value."
  (%join-by thread
            (+ (get-internal-real-time) (* timeout internal-time-units-per-second))
            timeout))

(defun join-all (threads &key (timeout +default-timeout+))
  "Wait for every thread in THREADS and return their values in order. TIMEOUT is one
deadline for the whole group, not one per thread, so fifty threads still give up after
TIMEOUT seconds. Signal an error naming the first thread that has not finished by then, or
that ended without returning a value."
  (let ((deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
    (mapcar (lambda (thread) (%join-by thread deadline timeout)) threads)))
