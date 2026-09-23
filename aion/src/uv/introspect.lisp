;;;; introspect.lisp --- what is actually alive in this loop, and what is holding it open.
;;;;
;;;; "Why will my process not exit?" is the most common complaint about Node, and it
;;;; nearly always has one answer: some handle is still REFERENCED, so the loop still has
;;;; work and uv_run will not return. Node users reach for async_hooks or a third-party
;;;; why-is-node-running to find out which one.
;;;;
;;;; We can answer it directly, and better, because we have a live image: uv_walk visits
;;;; every handle the loop owns, and the pointer registry already knows which Lisp object
;;;; each one belongs to. So DESCRIBE-LOOP does not merely say "a timer is open" -- it
;;;; says which of YOUR timers it is. Typing (uv:describe-loop l) at a REPL attached to a
;;;; running system is a thing Node structurally cannot offer.
;;;;
;;;; THE REF/UNREF DISTINCTION, since it is the whole point:
;;;;
;;;;   referenced   -- the handle keeps the loop alive. uv_run will not return while it
;;;;                   is active. This is the default for every handle libuv creates.
;;;;   unreferenced -- the handle still works, still fires its callbacks, but does not by
;;;;                   itself hold the loop open. Our wakeup handle is unreferenced for
;;;;                   exactly this reason (see MAKE-LOOP).
;;;;
;;;; Each handle type in aion/uv documents which it is; HOLDS-LOOP-P answers it for an
;;;; individual handle at runtime.

(in-package #:aion/uv)

(defstruct (handle-info (:constructor %make-handle-info))
  "One live libuv handle, as seen by UV_WALK."
  (address 0 :read-only t)
  (kind :unknown :read-only t)
  (active nil :read-only t)
  (closing nil :read-only t)
  (referenced nil :read-only t)
  (owner nil :read-only t))

(defun %handle-kind (pointer)
  "The handle's type as a keyword, asked of libuv rather than remembered by us."
  (let ((name (ffi:uv-handle-type-name (ffi:uv-handle-get-type pointer))))
    (if name (intern (string-upcase (substitute #\- #\_ name)) :keyword) :unknown)))

(defun %describe-handle (pointer)
  (let ((owner (lookup pointer)))
    (%make-handle-info
     :address (cffi:pointer-address pointer)
     :kind (%handle-kind pointer)
     :active (plusp (ffi:uv-is-active pointer))
     :closing (plusp (ffi:uv-is-closing pointer))
     :referenced (plusp (ffi:uv-has-ref pointer))
     ;; The registry maps the pointer back to the Lisp object that owns it. A raw T or a
     ;; closure means "closing, awaiting its close callback" -- see CLOSE-POINTER.
     :owner (typecase owner
              (null nil)
              ((or function boolean) :closing)
              (t owner)))))

(defvar %walk-accumulator '()
  "Where the walk callback deposits handles. A dynamic variable rather than uv_walk's
`arg` parameter, because the rule against parking a Lisp object in foreign memory has no
exception for a pointer that is only briefly held: the GC may move it in that window.")

(cffi:defcallback %walk-callback :void ((handle :pointer) (arg :pointer))
  (declare (ignore arg))
  (with-callback-guard
    (push (%describe-handle handle) %walk-accumulator)))

(defun loop-handles (loop)
  "Every live handle in LOOP, as a list of HANDLE-INFO.

uv_walk reads the loop's own handle queue, so it must run on the thread that owns the
loop -- rule 1. If LOOP has a loop thread this routes through SUBMIT and waits for the
answer, which makes it safe to call from a REPL while the loop is running. That is the
case it exists for."
  (ensure-available)
  (flet ((walk ()
           ;; Bound INSIDE the thunk on purpose: a dynamic binding is per-thread in SBCL,
           ;; so binding it on the calling thread would be invisible to the loop thread
           ;; that actually runs the callback.
           (let ((%walk-accumulator '()))
             (ffi:uv-walk (loop-pointer loop) (cffi:callback %walk-callback)
                          (cffi:null-pointer))
             (nreverse %walk-accumulator))))
    (if (and (loop-thread loop) (not (loop-thread-p loop)))
        (let ((result :not-run)
              (done (sb-thread:make-semaphore)))
          (submit loop (lambda ()
                         (unwind-protect (setf result (walk))
                           (sb-thread:signal-semaphore done))))
          (if (sb-thread:wait-on-semaphore done :timeout 5)
              result
              (error 'await-timeout
                     :code 0 :name "ETIMEDOUT" :operation :loop-handles
                     :message "the loop thread did not answer a handle walk within 5 s")))
        (walk))))

(defun holds-loop-p (handle-or-pointer)
  "True if this handle is referenced, i.e. it alone will keep RUN from returning."
  (let ((pointer (etypecase handle-or-pointer
                   (sb-sys:system-area-pointer handle-or-pointer)
                   (timer (timer-pointer handle-or-pointer))
                   (watcher (watcher-pointer handle-or-pointer)))))
    (and pointer (plusp (ffi:uv-has-ref pointer)))))

(defun describe-loop (loop &optional (stream *standard-output*))
  "Print what is alive in LOOP and, crucially, what is holding it open.

The bottom line is the one to read: while any handle is both active and referenced,
RUN will not return and the process will not exit on its own."
  (let* ((handles (loop-handles loop))
         (holding (remove-if-not (lambda (h)
                                   (and (handle-info-active h)
                                        (handle-info-referenced h)
                                        (not (handle-info-closing h))))
                                 handles)))
    (format stream "~&event loop ~X: ~D handle~:P, loop-alive: ~:[no~;yes~]~%"
            (cffi:pointer-address (loop-pointer loop))
            (length handles)
            (loop-alive-p loop))
    (dolist (h handles)
      (format stream "  ~12A ~A~@[ ~A~]~@[ ~A~]~@[  owner: ~A~]~%"
              (handle-info-kind h)
              (if (handle-info-active h) "active  " "inactive")
              (if (handle-info-referenced h) "referenced" "unreferenced")
              (when (handle-info-closing h) "closing")
              (let ((owner (handle-info-owner h)))
                (typecase owner
                  (null nil)
                  (keyword owner)
                  (t (type-of owner))))))
    (if holding
        (format stream "~&~D active referenced handle~:P: RUN will not return until closed or unreferenced.~%"
                (length holding))
        (format stream "~&Nothing holds this loop open.~%"))
    (values handles holding)))
