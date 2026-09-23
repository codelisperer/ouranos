;;;; apartment.lisp --- a dedicated STA thread with a real message pump.
;;;;
;;;; ADR-0003 s6: apartment policy is DECLARED, never inherited. Every COM object belongs to
;;;; the apartment that created it, and the apartment is a property of the THREAD -- so
;;;; "which thread am I on" is not an implementation detail here, it is the object's
;;;; identity. cl-win32ole's central defect after the VARIANT one was exactly this: it
;;;; called CoInitialize once, at load time, on whichever thread happened to load the file,
;;;; and every other thread then got CO_E_NOTINITIALIZED.
;;;;
;;;; WHY STA AND NOT MTA. Automation servers are overwhelmingly single-threaded-apartment.
;;;; An MTA caller talking to an STA object does not fail -- it silently inserts a
;;;; marshalling proxy on every call, which is slower and, worse, changes reentrancy
;;;; behaviour. Declaring STA means we are in the same apartment as the objects we create
;;;; and calls are direct.
;;;;
;;;; WHY A PUMP IS NOT OPTIONAL. An STA delivers cross-apartment calls as WINDOW MESSAGES.
;;;; A thread that initialises STA and then blocks without pumping will deadlock the moment
;;;; an out-of-process server (Excel, Word) calls back into it -- and it will look like a
;;;; hang with no error anywhere. So the loop below waits with MsgWaitForMultipleObjects,
;;;; which wakes for EITHER our work event OR an incoming message, and dispatches messages
;;;; when that is what arrived. A plain semaphore wait would work until the first
;;;; out-of-process server, then hang forever.
;;;;
;;;; A COM STA THREAD NEVER ALSO RUNS A UV LOOP (ADR-0003 s6). A message pump and an event
;;;; loop cannot both own a thread; each wants to be the thing that blocks. That is why this
;;;; is a thread of its own rather than work folded onto an existing aion/uv loop.
;;;;
;;;; sb-thread, not bordeaux-threads: the tree is SBCL-exclusive and this file is
;;;; Windows-exclusive on top of that, so a portability layer over threads would be a
;;;; dependency bought with nothing.

(in-package #:aion/windows/com)

;;; --- the pump's FFI ----------------------------------------------------------
;;;
;;; Kept here rather than in com/ffi.lisp because it is not COM: it is the Win32 waiting and
;;; message machinery that an STA requires. Putting it beside the only thing that uses it
;;; keeps com/ffi.lisp about COM.

(cffi:defcfun ("CreateEventW" %create-event) :pointer
  (attributes :pointer) (manual-reset :int32) (initial-state :int32) (name :pointer))

(cffi:defcfun ("SetEvent" %set-event) :int32 (handle :pointer))

(cffi:defcfun ("MsgWaitForMultipleObjects" %msg-wait) wffi:dword
  (count wffi:dword) (handles :pointer) (wait-all :int32)
  (milliseconds wffi:dword) (wake-mask wffi:dword))

(cffi:defcstruct point (x :int32) (y :int32))

(cffi:defcstruct msg
  (hwnd :pointer)
  (message :uint32)
  (w-param :pointer)
  (l-param :pointer)
  (time wffi:dword)
  (pt (:struct point)))

(wffi:register-layout
 :name "MSG"
 :type '(:struct msg)
 ;; x64: hwnd 0, message 8, 4 bytes of padding, wParam 16, lParam 24, time 32, pt 36,
 ;; then 4 bytes of tail padding to the struct's 8-byte alignment.
 ;; x86: everything is 4-aligned and nothing pads.
 :size '(:x86 28 :x64 48)
 :slots '((hwnd :offset (:x86 0 :x64 0))
          (message :offset (:x86 4 :x64 8))
          (w-param :offset (:x86 8 :x64 16))
          (l-param :offset (:x86 12 :x64 24))
          (time :offset (:x86 16 :x64 32)))
 :source "MSDN MSG (winuser.h); POINT is two LONGs")

(cffi:defcfun ("PeekMessageW" %peek-message) :int32
  (msg :pointer) (hwnd :pointer) (filter-min :uint32) (filter-max :uint32) (remove :uint32))

(cffi:defcfun ("TranslateMessage" %translate-message) :int32 (msg :pointer))
(cffi:defcfun ("DispatchMessageW" %dispatch-message) :pointer (msg :pointer))

(defconstant +qs-allinput+ #x04FF)
(defconstant +wait-object-0+ 0)
(defconstant +infinite+ #xFFFFFFFF)
(defconstant +pm-remove+ 1)

(wffi:verify-layouts)

;;; --- conditions ---------------------------------------------------------------

(define-condition apartment-error (error)
  ((detail :initarg :detail :initform nil :reader apartment-error-detail))
  (:report (lambda (c stream)
             (format stream "aion/windows/com apartment: ~A" (apartment-error-detail c))))
  (:documentation "The COM apartment is not in a state that can serve this request."))

;;; --- the apartment -------------------------------------------------------------

(defstruct (apartment (:constructor %make-apartment))
  "The STA thread, its wakeup event, and the queue of work waiting for it.

EVENT is a wrapped AION/WINDOWS:HANDLE rather than a bare pointer, so closing it is checked
and idempotent like every other handle in this tree. Keeping the raw pointer here and
hand-rolling a CloseHandle at teardown is how an unchecked return value and a potential
double close get written a second time, in a second file."
  thread
  (event nil)
  (lock (sb-thread:make-mutex :name "com-apartment"))
  (queue '())
  (state :stopped)          ; :stopped | :starting | :running | :stopping
  (start-error nil))

(defvar *apartment* nil "The process-wide STA apartment, or NIL.")

(defstruct (work (:constructor %make-work (thunk)))
  "One unit of work for the apartment, and somewhere to put its outcome."
  (thunk nil :read-only t)
  (done (sb-thread:make-semaphore) :read-only t)
  (values nil)
  (condition nil))

(defun apartment-running-p (&optional (apartment *apartment*))
  (and apartment (eq (apartment-state apartment) :running)))

(defun %drain-queue (apartment)
  "Take everything queued, oldest first."
  (sb-thread:with-mutex ((apartment-lock apartment))
    (prog1 (nreverse (apartment-queue apartment))
      (setf (apartment-queue apartment) '()))))

(defun %run-work (work)
  "Run one work item on THIS thread, capturing its outcome for the caller.

The handler is not optional. A condition signalled inside a work item and left to unwind
would kill the apartment thread, and the next caller would block forever on a semaphore
nobody will ever signal. So the condition is captured and re-signalled in the caller's
thread, where it belongs -- the caller made the call."
  (handler-case
      (setf (work-values work) (multiple-value-list (funcall (work-thunk work))))
    (serious-condition (c)
      (setf (work-condition work) c)))
  (sb-thread:signal-semaphore (work-done work)))

(defun %pump-messages ()
  "Dispatch every message currently waiting, then return.

PM_REMOVE, and TranslateMessage before DispatchMessage, is the standard sequence. An STA
that skips this deadlocks against any out-of-process server that calls back into it."
  (cffi:with-foreign-object (m '(:struct msg))
    (loop while (not (zerop (%peek-message m (cffi:null-pointer) 0 0 +pm-remove+)))
          do (%translate-message m)
             (%dispatch-message m))))

(defun %apartment-loop (apartment)
  "The STA thread: initialise the apartment, then serve work and messages until stopped."
  (let ((hr (ffi:co-initialize-ex (cffi:null-pointer)
                                  (logior ffi:+coinit-apartmentthreaded+
                                          ffi:+coinit-disable-ole1dde+))))
    ;; S_FALSE means already initialised on this thread -- a success, and one that must not
    ;; be read as failure. CHECK-HRESULT already treats it as success (the sign bit is the
    ;; flag), which is exactly why HRESULT is declared signed.
    (handler-case (w:check-hresult hr :operation :co-initialize-ex)
      (error (c)
        (setf (apartment-start-error apartment) c
              (apartment-state apartment) :stopped)
        (return-from %apartment-loop nil))))
  (setf (apartment-state apartment) :running)
  (unwind-protect
       (loop
         (when (eq (apartment-state apartment) :stopping) (return))
         (dolist (work (%drain-queue apartment))
           (%run-work work))
         (when (eq (apartment-state apartment) :stopping) (return))
         ;; Wait for EITHER our event or an incoming message. This is the whole reason the
         ;; apartment is not a plain semaphore loop.
         (cffi:with-foreign-object (handles :pointer 1)
           (setf (cffi:mem-aref handles :pointer 0) (w:handle-pointer (apartment-event apartment)))
           (let ((r (%msg-wait 1 handles 0 +infinite+ +qs-allinput+)))
             (cond
               ((= r +wait-object-0+) nil)              ; work arrived
               ((= r (1+ +wait-object-0+)) (%pump-messages))
               (t nil)))))
    ;; Anything still queued when we stop must be released, or its caller waits forever.
    (dolist (work (%drain-queue apartment))
      (setf (work-condition work)
            (make-condition 'apartment-error :detail "the apartment stopped before this call ran"))
      (sb-thread:signal-semaphore (work-done work)))
    (ffi:co-uninitialize)
    (setf (apartment-state apartment) :stopped)))

(defun start-apartment ()
  "Start the process-wide STA apartment. Idempotent; returns the apartment."
  (when (apartment-running-p) (return-from start-apartment *apartment*))
  (let ((apartment (%make-apartment)))
    (setf (apartment-event apartment)
          (w:wrap-handle
           (w:check-win32 (%create-event (cffi:null-pointer) 0 0 (cffi:null-pointer))
                          :operation :create-event
                          :predicate (lambda (p) (not (cffi:null-pointer-p p))))
           :kind :apartment-wakeup-event))
    (setf (apartment-state apartment) :starting)
    (setf (apartment-thread apartment)
          ;; THREAD-LIFETIME: independent -- an apartment is a long-lived home for COM
          ;; objects and serves whoever calls in later (#430).
          (sb-thread:make-thread (lambda () (%apartment-loop apartment))
                                 :name "aion/windows/com STA"))
    ;; Wait for the thread to reach a decided state rather than returning an apartment that
    ;; may still be about to fail -- otherwise the first call reports the failure, far from
    ;; its cause.
    (loop repeat 2000
          until (member (apartment-state apartment) '(:running :stopped))
          do (sleep 0.001))
    (when (apartment-start-error apartment)
      (error 'apartment-error
             :detail (format nil "CoInitializeEx failed: ~A" (apartment-start-error apartment))))
    (unless (eq (apartment-state apartment) :running)
      (error 'apartment-error :detail "the apartment thread did not start"))
    (setf *apartment* apartment)))

(defun stop-apartment (&optional (apartment *apartment*))
  "Stop the apartment and wait for its thread to finish. Idempotent."
  (when (and apartment (not (eq (apartment-state apartment) :stopped)))
    (setf (apartment-state apartment) :stopping)
    (%set-event (w:handle-pointer (apartment-event apartment)))
    (ignore-errors (sb-thread:join-thread (apartment-thread apartment) :default nil))
    ;; CHECKED, via the foundation's handle. A failing CloseHandle here means the handle was
    ;; already invalid, which is a bug upstream of this line and exactly the kind that
    ;; otherwise surfaces much later as a leak.
    (w:close-handle (apartment-event apartment))
    (setf (apartment-event apartment) nil))
  (when (eq apartment *apartment*) (setf *apartment* nil))
  t)

(defun call-in-apartment (thunk)
  "Run THUNK on the STA thread and return its values here.

A condition signalled inside THUNK is re-signalled in THIS thread. That is the point: the
apartment is an implementation detail of where the call runs, not a place errors go to
disappear."
  (let ((apartment (or (and (apartment-running-p) *apartment*) (start-apartment))))
    ;; Already on the apartment thread: call directly. Queueing would deadlock -- the thread
    ;; would be waiting on a semaphore only it could signal.
    (if (eq sb-thread:*current-thread* (apartment-thread apartment))
        (funcall thunk)
        (let ((work (%make-work thunk)))
          (sb-thread:with-mutex ((apartment-lock apartment))
            (push work (apartment-queue apartment)))
          (%set-event (w:handle-pointer (apartment-event apartment)))
          (sb-thread:wait-on-semaphore (work-done work))
          (when (work-condition work) (error (work-condition work)))
          (values-list (work-values work))))))

(defmacro in-apartment (() &body body)
  "Run BODY on the STA thread, returning its values here."
  `(call-in-apartment (lambda () ,@body)))
