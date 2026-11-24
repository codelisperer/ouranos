;;;; jobs.lisp --- background jobs for a desktop's windows: the CL shell (#1218).
;;;;
;;;; A JOB is one call of a function on a thread of its own, started for a window. The request
;;;; that starts it returns at once. While the function runs, what it writes to
;;;; *STANDARD-OUTPUT* is added to the job's output, and the window is told that it changed
;;;; (HYPERION/DESKTOP-UI:WINDOW-CHANGED). CANCEL-JOB stops it, and so does its time limit.
;;;;
;;;; This file knows nothing about what a job is for. The Ouranos IDE example runs a REPL
;;;; input and an agent's turn as jobs.
;;;;
;;;; A job's status is a value of the Coalton type in job-status.lisp, and it changes only
;;;; through NEXT-STATUS there.
;;;;
;;;; HOW A JOB IS STOPPED. CANCEL-JOB and the time limit record the new status first, then call
;;;; the job's :ON-STOP function if it has one, then interrupt the job's thread so that it
;;;; leaves the function with a THROW. The function's UNWIND-PROTECT cleanup forms run. The
;;;; interrupt is taken only while the function is running, never in this file's own
;;;; bookkeeping before or after it.
;;;;
;;;; WHAT AN INTERRUPT CANNOT STOP. SBCL runs the interrupt when the thread next allows
;;;; interrupts. A function inside SB-SYS:WITHOUT-INTERRUPTS is not stopped until it leaves
;;;; that form. On an SBCL built with safepoints, which is the Windows build, a function inside
;;;; a foreign call is not stopped until the call returns. A thread the function started
;;;; itself is not stopped at all; give :ON-STOP a function that stops it. In those cases the
;;;; job's status is already Cancelled or TimedOut while its thread is still alive, and
;;;; INSPECT-JOB says so under :THREAD-ALIVE.
;;;;
;;;; RUNNING OUT OF STACK. A job whose function runs out of stack ends as Failed, because the
;;;; handler is for SERIOUS-CONDITION. That holds in an SBCL started in the ordinary way. One
;;;; started with --script or --lose-on-corruption ends the whole process when any thread runs
;;;; out of stack, before a handler can run.

(cl:defpackage #:hyperion/desktop-ui/jobs
  (:use #:cl)
  (:local-nicknames (#:status #:hyperion/desktop-ui/job-status)
                    (#:ui #:hyperion/desktop-ui))
  (:documentation
   "Background jobs for a desktop's windows. START-JOB runs a function on its own thread and
    captures its output, CANCEL-JOB stops it, WAIT-JOB waits for it, and INSPECT-JOB describes
    it as plain data.")
  (:export #:job #:start-job #:cancel-job #:wait-job #:find-job
           #:job-id #:job-name #:job-window #:job-status #:job-running-p #:job-output
           #:job-result #:job-condition #:job-error-text #:job-time-limit
           #:job-started #:job-ended #:job-seconds #:job-thread-alive-p
           #:inspect-job #:all-jobs #:window-jobs #:desktop-jobs
           #:*change-interval* #:*output-limit* #:*job-history*))

(cl:in-package #:hyperion/desktop-ui/jobs)

;;; The functions a request or a REPL calls, so a redefinition reaches compiled callers.
(declaim (notinline start-job cancel-job wait-job find-job inspect-job
                    all-jobs window-jobs desktop-jobs))

;;; --- settings ----------------------------------------------------------------------------

(defparameter *change-interval* 1/10
  "Seconds between two calls of WINDOW-CHANGED for one job's output. A job that prints in a
tight loop tells its window at most this often. The end of a job is always told at once.")

(defparameter *output-limit* 200000
  "The most characters of output a job keeps. What a job writes after that is dropped, and
INSPECT-JOB reports :OUTPUT-TRUNCATED.")

(defparameter *job-history* 100
  "How many ended jobs the image remembers for ALL-JOBS, WINDOW-JOBS and DESKTOP-JOBS. Running
jobs are always remembered. Code that holds a job object can read it for as long as it likes.")

;;; --- the record --------------------------------------------------------------------------

(defclass job ()
  ((id :initarg :id :reader job-id
       :documentation "A positive integer, unique in this image.")
   (name :initarg :name :reader job-name
         :documentation "A short string saying what the job is, for a list of jobs.")
   (window :initarg :window :reader job-window
           :documentation "The hyperion/desktop-ui window the job belongs to, or NIL.")
   (status :initform status:initial-status :accessor %status
           :documentation "A hyperion/desktop-ui/job-status:Job-Status. Read it with JOB-STATUS.")
   (output :initform (make-array 0 :element-type 'character :adjustable t :fill-pointer 0)
           :reader %output)
   (truncated :initform nil :accessor %truncated)
   (dirty :initform nil :accessor %dirty
          :documentation "True when output was written since the window was last told.")
   (result :initform nil :accessor %result)
   (condition :initform nil :accessor %condition)
   (error-text :initform nil :accessor %error-text)
   (time-limit :initarg :time-limit :initform nil :reader job-time-limit
               :documentation "NIL, or the seconds the job may run.")
   (on-stop :initarg :on-stop :initform nil :reader %on-stop)
   (stop-grace :initarg :stop-grace :initform 0 :reader %stop-grace)
   (started :initform (get-universal-time) :reader job-started
            :documentation "The universal time START-JOB was called.")
   (ended :initform nil :accessor %ended)
   (started-ticks :initform (get-internal-real-time) :reader %started-ticks)
   (ended-ticks :initform nil :accessor %ended-ticks)
   (interruptible :initform nil :accessor %interruptible
                  :documentation "True only while the job's function is running. Written and read by the job's own thread.")
   (thread :initform nil :accessor %thread)
   (monitor :initform nil :accessor %monitor)
   (lock :initform (sb-thread:make-mutex :name "desktop-ui job") :reader %lock
         :documentation "Held for every read or write of the status, output, result and times."))
  (:documentation "One call of a function on a thread of its own, started for a window."))

(defmethod print-object ((j job) stream)
  (print-unreadable-object (j stream :type t)
    (format stream "~D ~A" (job-id j) (job-status j))))

(defmacro %with-job ((job) &body body)
  `(sb-thread:with-recursive-lock ((%lock ,job)) ,@body))

(defun job-status (job)
  "JOB's status as a keyword: :RUNNING, :DONE, :FAILED, :CANCELLED or :TIMED-OUT."
  (intern (string-upcase (status:status-name (%with-job (job) (%status job)))) :keyword))

(defun job-running-p (job)
  "True until JOB's function returns or fails, or JOB is cancelled or reaches its time limit."
  (not (status:status-ended? (%with-job (job) (%status job)))))

(defun job-output (job)
  "A copy of what JOB's function has written to *STANDARD-OUTPUT* so far."
  (%with-job (job) (copy-seq (%output job))))

(defun job-result (job)
  "The first value JOB's function returned, or NIL when the status is not :DONE."
  (%with-job (job) (%result job)))

(defun job-condition (job)
  "The serious condition that ended JOB's function, or NIL when the status is not :FAILED."
  (%with-job (job) (%condition job)))

(defun job-error-text (job)
  "The report of the condition that ended JOB's function, or NIL when the status is not :FAILED."
  (%with-job (job) (%error-text job)))

(defun job-ended (job)
  "The universal time JOB's status stopped being :RUNNING, or NIL while it runs."
  (%with-job (job) (%ended job)))

(defun job-seconds (job)
  "How long JOB ran, or has run so far, in seconds as a real number."
  (%with-job (job)
    (/ (- (or (%ended-ticks job) (get-internal-real-time)) (%started-ticks job))
       internal-time-units-per-second)))

(defun job-thread-alive-p (job)
  "True while the thread running JOB's function exists. It can be true after a cancel or a
time limit, when the function is somewhere an interrupt does not reach."
  (let ((thread (%thread job)))
    (and thread (sb-thread:thread-alive-p thread) t)))

;;; --- the jobs the image remembers --------------------------------------------------------

(defvar *jobs* '() "Every running job and the most recent ended ones, newest first.")
(defvar *next-id* 0)
(defvar *jobs-lock* (sb-thread:make-mutex :name "desktop-ui jobs"))

(defun %register (job)
  "Add JOB to the list, and drop the oldest ended jobs over *JOB-HISTORY*."
  (sb-thread:with-mutex (*jobs-lock*)
    (let ((ended 0))
      (setf *jobs*
            (cons job (remove-if (lambda (old)
                                   (and (not (job-running-p old))
                                        (> (incf ended) *job-history*)))
                                 *jobs*))))))

(defun all-jobs ()
  "A fresh list of the jobs the image remembers, newest first."
  (sb-thread:with-mutex (*jobs-lock*) (copy-list *jobs*)))

(defun find-job (id)
  "The remembered job with the id ID, an integer, or NIL."
  (find id (all-jobs) :key #'job-id))

(defun window-jobs (window)
  "The remembered jobs that belong to WINDOW, newest first."
  (remove window (all-jobs) :key #'job-window :test-not #'eq))

(defun desktop-jobs (desktop)
  "The remembered jobs that belong to a window of DESKTOP, newest first."
  (remove-if-not (lambda (job)
                   (let ((window (job-window job)))
                     (and window (eq desktop (ui:window-desktop window)))))
                 (all-jobs)))

;;; --- telling the window ------------------------------------------------------------------

(defun %tell-window (job)
  "Call WINDOW-CHANGED for JOB's window. A failure there must not end the thread that called
this, which is the job's own thread or its monitor, so it is dropped."
  (let ((window (job-window job)))
    (when window
      (%with-job (job) (setf (%dirty job) nil))
      (handler-case (ui:window-changed window)
        (serious-condition () nil)))))

;;; --- the output stream -------------------------------------------------------------------

(defclass job-output-stream (sb-gray:fundamental-character-output-stream)
  ((job :initarg :job :reader %stream-job)
   (column :initform 0 :accessor %column))
  (:documentation "The stream *STANDARD-OUTPUT* is bound to in a job's thread. It appends to
the job's output. It does not call WINDOW-CHANGED itself: it marks the job, and the job's
monitor thread tells the window, at most once every *CHANGE-INTERVAL* seconds."))

(defun %append-output (job string start end)
  (%with-job (job)
    (let* ((output (%output job))
           (room (- *output-limit* (length output)))
           (count (- end start)))
      (when (> count room)
        (setf (%truncated job) t
              end (+ start (max 0 room))))
      (loop for i from start below end
            do (vector-push-extend (char string i) output))
      (setf (%dirty job) t))))

(defmethod sb-gray:stream-write-char ((stream job-output-stream) character)
  (%append-output (%stream-job stream) (string character) 0 1)
  (setf (%column stream) (if (char= character #\Newline) 0 (1+ (%column stream))))
  character)

(defmethod sb-gray:stream-write-string ((stream job-output-stream) string &optional (start 0) end)
  (let* ((end (or end (length string)))
         (newline (position #\Newline string :start start :end end :from-end t)))
    (%append-output (%stream-job stream) string start end)
    (setf (%column stream) (if newline
                               (- end newline 1)
                               (+ (%column stream) (- end start))))
    string))

(defmethod sb-gray:stream-line-column ((stream job-output-stream))
  (%column stream))

;;; --- running -----------------------------------------------------------------------------

(defun %apply-event (job event &key result condition error-text)
  "Apply EVENT to JOB's status. When that ends the job, store RESULT, CONDITION and
ERROR-TEXT and the end time, and return true. Return NIL when the job had ended already."
  (%with-job (job)
    (let ((before (%status job)))
      (unless (status:status-ended? before)
        (setf (%status job) (status:next-status event before)
              (%result job) result
              (%condition job) condition
              (%error-text job) error-text
              (%ended job) (get-universal-time)
              (%ended-ticks job) (get-internal-real-time))
        t))))

(defun %report (condition)
  "CONDITION's report as a string. A report function can fail too."
  (handler-case (princ-to-string condition)
    (serious-condition ()
      (format nil "A condition of type ~A, whose report could not be printed." (type-of condition)))))

(defun %run (job function)
  "The body of a job's thread: call FUNCTION, record how it ended, and tell the window.
Interrupts are off except around the call, so the THROW that CANCEL-JOB sends can only arrive
inside the CATCH."
  (sb-sys:without-interrupts
    (let ((event status:error-event)
          (result nil)
          (condition nil)
          (error-text "The job's function left without returning."))
      (unwind-protect
           (catch job
             (unwind-protect
                  (when (job-running-p job)   ; a cancel may have arrived before the thread ran
                    (setf (%interruptible job) t)
                    (handler-case
                        (sb-sys:with-local-interrupts
                          (setf result (funcall function))
                          (setf event status:return-event
                                error-text nil))
                      (serious-condition (c)
                        (setf condition c
                              error-text (%report c)))))
               (setf (%interruptible job) nil)))
        ;; When the job was cancelled or timed out, the status is final already and this
        ;; changes nothing.
        (%apply-event job event :result result :condition condition :error-text error-text)
        (%tell-window job)))))

(defun %interrupt (job)
  "Make JOB's thread leave its function, if it is still in it."
  (let ((thread (%thread job)))
    (when (and thread (sb-thread:thread-alive-p thread))
      ;; INTERRUPT-THREAD signals an error when the thread ended in the meantime.
      (ignore-errors
       (sb-thread:interrupt-thread
        thread (lambda () (when (%interruptible job) (throw job nil))))))))

(defun %stop (job event)
  "End JOB with EVENT, a cancel or a time limit. Returns true if JOB was running."
  (when (%apply-event job event)
    (let ((on-stop (%on-stop job))
          (thread (%thread job)))
      (when on-stop
        (handler-case (funcall on-stop)
          (serious-condition () nil))
        ;; Give the function the grace period to leave in its own way before the interrupt.
        (when (and thread (plusp (%stop-grace job)))
          (sb-thread:join-thread thread :default nil :timeout (%stop-grace job)))))
    (%interrupt job)
    (%tell-window job)
    t))

(defun %monitor (job)
  "The body of a job's monitor thread. Until the job's thread ends it wakes every
*CHANGE-INTERVAL* seconds, tells the window if output was written since the last time, and
stops the job when its time limit has passed."
  (let* ((thread (%thread job))
         (limit (job-time-limit job))
         (deadline (and limit (+ (%started-ticks job)
                                 (* limit internal-time-units-per-second)))))
    (loop
      (let ((remaining (and deadline (/ (- deadline (get-internal-real-time))
                                        internal-time-units-per-second))))
        (when (and remaining (<= remaining 0))
          (%stop job status:time-limit-event)
          (return))
        (sb-thread:join-thread thread :default nil
                                      :timeout (if remaining
                                                   (min remaining *change-interval*)
                                                   *change-interval*))
        (unless (sb-thread:thread-alive-p thread) (return))
        (when (%with-job (job) (%dirty job))
          (%tell-window job))))))

(defun start-job (function &key window (name "job") time-limit bindings on-stop (stop-grace 0))
  "Call FUNCTION, with no arguments, on a new thread, and return the JOB at once.

WINDOW is the hyperion/desktop-ui window the job belongs to, or NIL. WINDOW-CHANGED is called
for it when the job writes output, at most once every *CHANGE-INTERVAL* seconds, and when the
job ends.

In the thread, *STANDARD-OUTPUT* is a stream that appends to the job's output (JOB-OUTPUT).
The thread does not see the caller's other special bindings. BINDINGS is an alist of
(SYMBOL . VALUE) to bind there, for example ((*PACKAGE* . package)).

The job ends in one of four ways. FUNCTION returns: the status is :DONE and JOB-RESULT is its
first value. FUNCTION signals a SERIOUS-CONDITION that it does not handle, which includes
running out of stack: the status is :FAILED, and JOB-CONDITION and JOB-ERROR-TEXT hold the
condition and its report. CANCEL-JOB is called: :CANCELLED. TIME-LIMIT seconds pass
(NIL, the default: no limit): :TIMED-OUT.

ON-STOP is a function of no arguments, called on the stopping thread when the job is cancelled
or reaches its time limit, before the job's thread is interrupted. Use it to stop work that
FUNCTION handed to another thread, which the interrupt does not reach, or to ask FUNCTION to
stop in its own way. After ON-STOP returns, the stopping thread waits up to STOP-GRACE seconds
(0, the default: not at all) for the job's thread to end before it interrupts it. The status is
:CANCELLED or :TIMED-OUT either way, and what FUNCTION returns in that time is not kept."
  (let ((job (make-instance 'job :id (sb-thread:with-mutex (*jobs-lock*) (incf *next-id*))
                                 :name name :window window :time-limit time-limit
                                 :on-stop on-stop :stop-grace stop-grace))
        (symbols (mapcar #'car bindings))
        (bound (mapcar #'cdr bindings)))
    (%register job)
    ;; THREAD-LIFETIME: independent -- one job. It ends when FUNCTION returns or is stopped.
    ;; It takes BINDINGS and nothing else from the caller, which is a request that has
    ;; answered by the time the job writes anything.
    (setf (%thread job)
          (sb-thread:make-thread
           (lambda ()
             (aion/dynamic:unblock-interrupts)
             (progv symbols bound
               (let ((*standard-output* (make-instance 'job-output-stream :job job)))
                 (%run job function))))
           :name (format nil "desktop-ui job ~D" (job-id job))))
    ;; THREAD-LIFETIME: independent -- it ends when the job's thread ends, or when it has
    ;; stopped the job at its time limit.
    (setf (%monitor job)
          (sb-thread:make-thread
           (lambda ()
             (aion/dynamic:unblock-interrupts)
             (%monitor job))
           :name (format nil "desktop-ui job ~D monitor" (job-id job))))
    job))

(defun cancel-job (job)
  "Stop JOB: record the status :CANCELLED, call its :ON-STOP function, and interrupt its
thread. Returns true if JOB was running, and NIL if it had ended already. It returns without
waiting for the thread to end, except for the job's :STOP-GRACE; WAIT-JOB waits. Safe to call
from any thread."
  (%stop job status:cancel-event))

(defun wait-job (job &key timeout)
  "Wait until JOB's thread and its monitor thread have ended, for at most TIMEOUT seconds (NIL:
for as long as it takes). Returns true if both have ended."
  (let ((deadline (and timeout (+ (get-internal-real-time)
                                  (* timeout internal-time-units-per-second)))))
    (dolist (thread (list (%thread job) (%monitor job)) t)
      (when thread
        (sb-thread:join-thread
         thread :default nil
                :timeout (and deadline
                              (max 0 (/ (- deadline (get-internal-real-time))
                                        internal-time-units-per-second))))
        (when (sb-thread:thread-alive-p thread) (return nil))))))

;;; --- inspecting --------------------------------------------------------------------------

(defun %summary (value)
  "VALUE as something safe to show: a number, a symbol or a character as it is, a string cut
to 120 characters, and anything else by its type alone. An object's slots are never printed,
for the reason given at hyperion/desktop-ui's own %SUMMARY."
  (typecase value
    ((or number symbol character) value)
    (string (if (> (length value) 120)
                (concatenate 'string (subseq value 0 120) "...")
                value))
    (t (format nil "an object of type ~A" (type-of value)))))

(defun inspect-job (job)
  "JOB as a property list of plain values: its id and name, its window's id, its status, a
summary of its output and result (see %SUMMARY for what is left out), the error report, the
start and end times, the seconds it ran, its time limit, and whether its thread still exists."
  (%with-job (job)
    (list :id (job-id job)
          :name (job-name job)
          :window (and (job-window job) (ui:window-id (job-window job)))
          :status (job-status job)
          :output (%summary (copy-seq (%output job)))
          :output-length (length (%output job))
          :output-truncated (%truncated job)
          :result (%summary (%result job))
          :error (%summary (%error-text job))
          :started (job-started job)
          :ended (%ended job)
          :seconds (float (job-seconds job))
          :time-limit (job-time-limit job)
          :thread-alive (job-thread-alive-p job))))
