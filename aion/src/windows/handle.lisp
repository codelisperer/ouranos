;;;; handle.lisp --- handle lifetime, made explicit rather than remembered.
;;;;
;;;; ADR-0003 Consequences: "we own Windows' memory and lifetime models ... defects are
;;;; memory-unsafe rather than merely wrong." A HANDLE is an opaque pointer-width token that
;;;; must be closed exactly once. Closing twice is undefined and, worse than a crash, is
;;;; usually silent -- the value may by then name a DIFFERENT object that some other part of
;;;; the image is still using.
;;;;
;;;; So a handle is wrapped in a struct that knows whether it has already been closed, and
;;;; CLOSE-HANDLE is idempotent. That converts the dangerous failure (double close, silently
;;;; closing a stranger's object) into a no-op.
;;;;
;;;; INVALID_HANDLE_VALUE IS NOT NULL, and this is a genuine Win32 trap: most APIs return
;;;; NULL on failure, but the file APIs return (HANDLE)-1. Testing only for NULL therefore
;;;; accepts -1 as a valid handle and passes it to CloseHandle. Both are treated as invalid
;;;; here.

(in-package #:aion/windows)

(defstruct (handle (:constructor %make-handle (pointer &key kind)))
  "A Windows HANDLE with its own closed flag."
  (pointer (cffi:null-pointer) :type t)
  (kind nil :read-only t)
  (closed nil))

(defun wrap-handle (pointer &key kind)
  "Adopt a raw HANDLE returned by a Win32 call, so it gets checked, idempotent closing.

Exported because the alternative is what every subsystem otherwise does: keep the bare
pointer and hand-roll a CloseHandle at teardown, which is how a double close and an
unchecked return value get written twice in two files. KIND is a label for reports."
  (%make-handle pointer :kind kind))

(defun %invalid-handle-value ()
  "(HANDLE)-1, the file APIs' failure return -- built rather than typed as a literal."
  (cffi:make-pointer (1- (expt 2 (* 8 (cffi:foreign-type-size :pointer))))))

(defun handle-valid-p (handle)
  "True when HANDLE is open and is neither NULL nor INVALID_HANDLE_VALUE."
  (and (handle-p handle)
       (not (handle-closed handle))
       (let ((p (handle-pointer handle)))
         (and (not (cffi:null-pointer-p p))
              (not (cffi:pointer-eq p (%invalid-handle-value)))))))

(defun close-handle (handle)
  "Close HANDLE if it is open. Idempotent; returns T when it actually closed one."
  (when (handle-valid-p handle)
    (let ((ok (ffi::%close-handle (handle-pointer handle))))
      (setf (handle-closed handle) t)
      ;; CloseHandle returns BOOL: zero is failure. Reported rather than swallowed -- a
      ;; failing close means the handle was already invalid, which is a bug upstream of
      ;; here and the kind that otherwise surfaces much later as a leak.
      (check-win32 ok :operation :close-handle :predicate (lambda (r) (not (zerop r))))
      t)))

(defmacro with-handle ((var form) &body body)
  "Bind VAR to the HANDLE produced by FORM, closing it however BODY exits."
  `(let ((,var ,form))
     (unwind-protect (progn ,@body)
       (close-handle ,var))))
