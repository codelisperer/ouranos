;;;; loop.lisp --- the event loop, the thread that runs it, and the futures it fulfils.
;;;;
;;;; THREE RULES GOVERN EVERYTHING IN THIS FILE, and they are the difference between a
;;;; binding that works and one that corrupts the heap at 3am:
;;;;
;;;; 1. A LOOP IS OWNED BY ONE THREAD. libuv is not thread-safe; a uv_loop_t and its
;;;;    handles belong to whichever thread calls uv_run. The single exception libuv
;;;;    documents is uv_async_send, so that is the only door into a running loop from
;;;;    outside. SUBMIT enqueues a closure and knocks on that door.
;;;;
;;;; 2. CALLBACKS RUN ON A LISP THREAD, NEVER A FOREIGN ONE. libuv invokes callbacks
;;;;    from the thread running uv_run. Because we only ever run loops on threads SBCL
;;;;    created, callbacks re-enter Lisp on a thread that already has a Lisp stack --
;;;;    which is what makes this safe. (libuv's threadpool threads ARE foreign, but they
;;;;    run the WORK function, never our completion callback; completions are delivered
;;;;    on the loop thread. We never hand libuv a work function.)
;;;;
;;;; 3. NO LISP CONDITION MAY UNWIND INTO C. A callback is called by libuv; if a Lisp
;;;;    error escaped it, the stack unwind would tear through a foreign frame, which is
;;;;    undefined behaviour rather than an error message. Every callback body is wrapped
;;;;    in WITH-CALLBACK-GUARD, which catches everything and stashes it for the owner.

(in-package #:aion/uv)

;;; ------------------------------------------------------------------- registry
;;;
;;; C gives a callback only the handle pointer it fired for. To get back to the Lisp
;;; object, we key a table by that pointer's address. The alternative -- stashing a Lisp
;;; object pointer in the handle's `data` field -- is what you must NOT do: SBCL's GC
;;; moves objects, so a pointer parked in foreign memory goes stale silently.

(defvar *registry* (make-hash-table :test #'eql)
  "Foreign pointer address -> the Lisp object that owns it.")
(defvar *registry-lock* (sb-thread:make-mutex :name "aion/uv registry"))

(defun register (pointer object)
  (sb-thread:with-mutex (*registry-lock*)
    (setf (gethash (cffi:pointer-address pointer) *registry*) object)))

(defun deregister (pointer)
  (sb-thread:with-mutex (*registry-lock*)
    (remhash (cffi:pointer-address pointer) *registry*)))

(defun lookup (pointer)
  (sb-thread:with-mutex (*registry-lock*)
    (gethash (cffi:pointer-address pointer) *registry*)))

;;; ------------------------------------------------------------ callback safety

(defvar *callback-errors* '()
  "Conditions caught escaping callbacks. Kept rather than discarded: a swallowed error
in an event loop is a bug that presents as 'nothing happened'.")
(defvar *callback-error-lock* (sb-thread:make-mutex :name "aion/uv callback errors"))

(defun note-callback-error (condition)
  (sb-thread:with-mutex (*callback-error-lock*)
    (push condition *callback-errors*))
  ;; Also make it visible immediately -- during development the REPL is where this
  ;; wants to land, and a silent event loop is the hardest thing to debug.
  (ignore-errors
   (format *error-output* "~&;; aion/uv: error escaped a callback: ~A~%" condition)))

(defmacro with-callback-guard (&body body)
  "Run BODY, absorbing any condition. For use ONLY inside CFFI callbacks: letting a Lisp
condition unwind through the foreign frame that called us is undefined behaviour."
  `(handler-case (progn ,@body)
     (error (e) (note-callback-error e) nil)))

;;; -------------------------------------------------------------------- futures

(defstruct (future (:constructor %make-future))
  (semaphore (sb-thread:make-semaphore) :read-only t)
  (value nil)
  (error nil)
  (finished nil))

(defun make-future ()
  "A fresh, unfulfilled future. The constructor sub-systems use, since %MAKE-FUTURE is
the structure's own and this is the one that is part of the substrate."
  (%make-future))

(defun fulfill (future value)
  "Complete FUTURE successfully. Called on the loop thread."
  (setf (future-value future) value
        (future-finished future) t)
  (sb-thread:signal-semaphore (future-semaphore future))
  future)

(defun fail-future (future condition)
  "Complete FUTURE with a failure. Called on the loop thread."
  (setf (future-error future) condition
        (future-finished future) t)
  (sb-thread:signal-semaphore (future-semaphore future))
  future)

(defun future-finished-p (future) (future-finished future))

(defun await (future &key timeout)
  "Block until FUTURE completes, then return its value or signal its error.

This is how a synchronous answer is obtained from an asynchronous operation. Note the
asymmetry with the -SYNC family: those are synchronous inside libuv and cost nothing
extra, whereas AWAIT is a real handoff between threads. Prefer the synchronous call
when you simply want the answer; use AWAIT when the work was already in flight."
  (if (sb-thread:wait-on-semaphore (future-semaphore future) :timeout timeout)
      (if (future-error future)
          (error (future-error future))
          (future-value future))
      ;; Our own timeout, not libuv's -- so it does not borrow a libuv errno. Platform
      ;; errno values differ, and inventing one here would be a lie that a caller
      ;; comparing UV-ERROR-CODE could act on.
      (error 'await-timeout
             :code 0 :name "ETIMEDOUT" :operation :await
             :message (format nil "timed out after ~A s awaiting an asynchronous operation"
                              timeout))))

;;; ----------------------------------------------------------------- the loop

(defclass event-loop ()
  ((pointer :initarg :pointer :reader loop-pointer
            :documentation "The malloc'd uv_loop_t.")
   (async :initarg :async :reader loop-async
          :documentation "A uv_async_t reserved for cross-thread wakeups.")
   (queue :initform '() :accessor loop-queue
          :documentation "Closures submitted from other threads, newest first.")
   (lock :initform (sb-thread:make-mutex :name "aion/uv loop queue") :reader loop-lock)
   (thread :initform nil :accessor loop-thread
           :documentation "The SBCL thread running uv_run, if START-LOOP-THREAD was used.")
   (running :initform nil :accessor loop-running-p)
   (stop-requested :initform nil :accessor loop-stop-requested-p
                   :documentation "Asks the loop thread to exit. Distinct from CLOSED:
stopping the thread must not make CLOSE-LOOP think the loop is already torn down.")
   (closed :initform nil :accessor loop-closed-p)
   (owned :initform '() :accessor loop-owned
          :documentation "Handles created against this loop, so CLOSE-LOOP can close them."))
  (:documentation
   "A uv_loop_t plus the Lisp-side bookkeeping that makes it safe to use: the wakeup
handle, the submission queue, and the set of handles to close on teardown."))

(defun ensure-available ()
  "Load libuv if it is not loaded yet, and verify it matches this binding.
Called by every entry point, so a missing library fails at USE with instructions
rather than at LOAD with a broken system."
  (unless (ffi:libuv-loaded-p)
    (ffi::ensure-loaded)
    (ffi:verify-abi))
  t)

(defun version ()
  "The version string of the libuv actually loaded, e.g. \"1.52.1\"."
  (ensure-available)
  (ffi:uv-version-string))

(defun library-path ()
  "Namestring of the libuv actually loaded."
  (ensure-available)
  ffi:*libuv-path*)

(cffi:defcallback %async-callback :void ((handle :pointer))
  (with-callback-guard
    (let ((loop (lookup handle)))
      (when loop (drain-queue loop)))))

(defun drain-queue (loop)
  "Run every submitted closure. Called on the loop thread, from the async callback."
  (let ((pending (sb-thread:with-mutex ((loop-lock loop))
                   (prog1 (nreverse (loop-queue loop))
                     (setf (loop-queue loop) '())))))
    (dolist (thunk pending)
      ;; One failing submission must not abandon the rest of the batch.
      (handler-case (funcall thunk)
        (error (e) (note-callback-error e))))))

(defun make-loop ()
  "Create an event loop. The caller owns it and must CLOSE-LOOP it; WITH-LOOP is safer."
  (ensure-available)
  (let* ((pointer (cffi:foreign-alloc :char :count (ffi:uv-loop-size)))
         (async (cffi:foreign-alloc :char :count (ffi:uv-handle-size ffi:+uv-async+))))
    (handler-bind ((error (lambda (e) (declare (ignore e))
                            (cffi:foreign-free pointer)
                            (cffi:foreign-free async))))
      (check (ffi:uv-loop-init pointer) :operation :make-loop)
      (check (ffi:uv-async-init pointer async (cffi:callback %async-callback))
             :operation :make-loop))
    ;; The wakeup handle must not, by itself, keep the loop alive -- otherwise uv_run
    ;; would never return even with no real work outstanding.
    (ffi:uv-unref async)
    (let ((loop (make-instance 'event-loop :pointer pointer :async async)))
      (register async loop)
      loop)))

(defun submit (loop thunk)
  "Queue THUNK to run ON THE LOOP THREAD, and wake the loop.

The only safe way to touch a running loop from another thread. Returns immediately;
THUNK runs later. Signals LOOP-CLOSED if the loop is closed or closing, in which case
THUNK was not queued and will never run.

THE SEND IS INSIDE THE LOCK, AND THAT IS THE WHOLE POINT (pre-publication issue 296). It used to be outside,
guarded by nothing, while CLOSE-LOOP took no lock at any point -- so a submit racing a
teardown landed in one of two windows:

  after uv_close, before foreign-free   -> libuv's own assert fires:
                                           !(handle->flags & UV_HANDLE_CLOSING)
  after foreign-free                    -> uv_async_send on FREED memory

The assertion was the good case, and it is the one that was observed: a modal MSVC
dialog mid-suite on Windows, 55 tests in, with no verdict (pre-publication issue 291). The second case is
silent. M2 is what exposed it -- before the pool, the handler ran inline on the loop
thread and this path never submitted from anywhere else.

Testing LOOP-CLOSED-P and sending must not be separable, or the flag only narrows the
window instead of closing it. CLOSE-LOOP claims the flag under this same lock before it
touches the handle, so once it has, no send can be in flight that has not already
happened."
  (sb-thread:with-mutex ((loop-lock loop))
    (when (loop-closed-p loop)
      (error 'loop-closed :operation :submit))
    (push thunk (loop-queue loop))
    (check (ffi:uv-async-send (loop-async loop)) :operation :submit)))

(defun loop-thread-p (loop)
  "True if the current thread is the one running LOOP."
  (eq sb-thread:*current-thread* (loop-thread loop)))

(defun run (loop &key (mode :default))
  "Run LOOP on the CALLING thread until it has no more work.

MODE is :DEFAULT (until no active handles), :ONCE (block for one round of events) or
:NOWAIT (poll once and return). Returns non-zero if work remains."
  (ensure-available)
  (let ((mode-value (ecase mode
                      (:default ffi:+uv-run-default+)
                      (:once ffi:+uv-run-once+)
                      (:nowait ffi:+uv-run-nowait+))))
    (setf (loop-running-p loop) t)
    (unwind-protect
         (ffi:uv-run (loop-pointer loop) mode-value)
      (setf (loop-running-p loop) nil))))

(defun stop (loop)
  "Ask LOOP to stop. uv_stop is safe to call from the loop's own callbacks; from another
thread it is routed through SUBMIT so it lands on the owning thread."
  (if (or (null (loop-thread loop)) (loop-thread-p loop))
      (ffi:uv-stop (loop-pointer loop))
      (submit loop (lambda () (ffi:uv-stop (loop-pointer loop))))))

(defun loop-alive-p (loop)
  "True if LOOP still has active handles or pending requests."
  (plusp (ffi:uv-loop-alive (loop-pointer loop))))

(defun start-loop-thread (loop &key (name "aion/uv loop"))
  "Run LOOP on a dedicated SBCL thread and return that thread.

An SBCL thread, specifically: callbacks then re-enter Lisp on a thread that has a Lisp
stack, which is the property that makes foreign callbacks safe here."
  (when (loop-thread loop)
    (error "This loop already has a thread."))
  (setf (loop-stop-requested-p loop) nil)
  ;; Re-reference the wakeup handle for the lifetime of the thread. While it is
  ;; referenced the loop is always "alive", so uv_run :ONCE BLOCKS waiting for an event
  ;; instead of returning immediately -- without this the thread spins at 100% CPU
  ;; whenever it has nothing to do, since an unreferenced handle does not hold the loop.
  (ffi:uv-ref (loop-async loop))
  (setf (loop-thread loop)
        ;; THREAD-LIFETIME: independent -- the event loop outlives every caller that
        ;; submits to it, so it belongs to no one unit of work (#158).
        (sb-thread:make-thread
         (lambda ()
           ;; :DEFAULT would return as soon as no handles were active, which for a
           ;; service loop is a race against the first submission. :ONCE in a loop, with
           ;; the referenced wakeup handle above, blocks until there is genuinely
           ;; something to do -- a submission, a timer, a watched file.
           (loop until (loop-stop-requested-p loop)
                 do (run loop :mode :once)))
         :name name)))

(defun stop-loop-thread (loop &key (timeout 5))
  "Stop the loop thread started by START-LOOP-THREAD and wait for it to exit.
Leaves the loop itself usable; CLOSE-LOOP is what tears it down."
  (let ((thread (loop-thread loop)))
    (when thread
      (setf (loop-stop-requested-p loop) t)
      ;; Wake the blocked uv_run so it re-tests the flag and returns.
      (ignore-errors (ffi:uv-async-send (loop-async loop)))
      (ignore-errors (sb-thread:join-thread thread :timeout timeout))
      (setf (loop-thread loop) nil)
      ;; Drop the reference again so a subsequent plain RUN can still terminate.
      (ignore-errors (ffi:uv-unref (loop-async loop))))))

(cffi:defcallback %close-callback :void ((handle :pointer))
  (with-callback-guard
    (let ((finalizer (lookup handle)))
      (deregister handle)
      (when (functionp finalizer) (funcall finalizer))
      (cffi:foreign-free handle))))

(defgeneric close-handle (object)
  (:documentation
   "Close a libuv handle and release it. Specialised by TIMER, WATCHER and raw pointers,
so callers close everything the same way."))

(defmethod close-handle ((pointer sb-sys:system-area-pointer))
  (close-pointer pointer))

(defun close-pointer (pointer &key finalizer)
  "Close a uv handle and free its memory once libuv says it is done with it.

The memory MUST NOT be freed before the close callback fires -- libuv goes on using the
handle throughout teardown, so an eager free is a use-after-free that will usually look
like unrelated corruption much later."
  (unless (plusp (ffi:uv-is-closing pointer))
    (register pointer (or finalizer t))
    (ffi:uv-close pointer (cffi:callback %close-callback))))

(defun close-loop (loop)
  "Close LOOP, its handles and its memory. Idempotent.

CLAIMING THE FLAG IS AN ATOMIC TEST-AND-SET UNDER LOOP-LOCK (pre-publication issue 296), for two reasons.
It is what makes SUBMIT's refusal a guarantee rather than a narrowing -- see there. And
it makes the idempotence real: the old `unless' read the flag and set it in two steps,
so two threads closing at once could both pass the test and both reach FOREIGN-FREE.

THE LOCK IS RELEASED BEFORE STOP-LOOP-THREAD, and must be. That joins the loop thread,
whose async callback drains the queue under this same mutex -- holding it across the
join deadlocks. Releasing is enough: a submit that got in first completes its send while
the handle is still valid, and every later one is refused."
  (when (sb-thread:with-mutex ((loop-lock loop))
          (unless (loop-closed-p loop)
            (setf (loop-closed-p loop) t)))
    (stop-loop-thread loop)
    ;; Close everything we created against this loop, then pump the loop so libuv can
    ;; run the close callbacks -- uv_loop_close fails with EBUSY while handles remain.
    (dolist (handle (loop-owned loop))
      (ignore-errors (close-pointer handle)))
    (setf (loop-owned loop) '())
    (deregister (loop-async loop))
    (unless (plusp (ffi:uv-is-closing (loop-async loop)))
      (ffi:uv-close (loop-async loop) (cffi:null-pointer)))
    (loop repeat 32
          while (plusp (ffi:uv-run (loop-pointer loop) ffi:+uv-run-nowait+)))
    (ffi:uv-loop-close (loop-pointer loop))
    (cffi:foreign-free (loop-async loop))
    (cffi:foreign-free (loop-pointer loop)))
  nil)

(defmacro with-loop ((var) &body body)
  "Create an event loop, run BODY, and close it however BODY leaves."
  `(let ((,var (make-loop)))
     (unwind-protect (progn ,@body)
       (close-loop ,var))))
