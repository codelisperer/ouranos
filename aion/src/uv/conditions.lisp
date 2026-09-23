;;;; conditions.lisp --- libuv return codes become CL conditions.
;;;;
;;;; libuv reports failure the C way: a negative integer return. The house rule is that
;;;; recoverable failure travels through the condition system, so every negative code
;;;; crossing out of the raw layer is converted here exactly once.
;;;;
;;;; The specific subclasses are selected by libuv's own ERROR NAME ("ENOENT"), not by
;;;; the numeric code. The numbers are platform errnos and differ between Linux, macOS
;;;; and Windows; the names do not. This is the same reason the Coalton decoder in
;;;; types.lisp dispatches on the name.

(in-package #:aion/uv)

(define-condition uv-error (error)
  ((code :initarg :code :reader uv-error-code
         :documentation "The negative integer libuv returned.")
   (name :initarg :name :initform nil :reader uv-error-name
         :documentation "libuv's symbolic name, e.g. \"ENOENT\".")
   (message :initarg :message :initform nil :reader uv-error-message
            :documentation "libuv's human-readable description.")
   (operation :initarg :operation :initform nil :reader uv-error-operation
              :documentation "The aion/uv operation that failed, e.g. :READ-FILE.")
   (path :initarg :path :initform nil :reader uv-error-path
         :documentation "The path involved, when the operation had one."))
  (:report
   (lambda (c stream)
     (format stream "libuv ~@[~A ~]failed~@[ on ~S~]: ~A~@[ (~A)~]"
             (uv-error-operation c)
             (uv-error-path c)
             (or (uv-error-message c) "unknown error")
             (uv-error-name c))))
  (:documentation "Base of every error aion/uv signals from a libuv return code."))

;;; The handful worth catching by name. Everything else stays a plain UV-ERROR, which
;;; still carries the name -- a caller can always test UV-ERROR-NAME.
(define-condition file-not-found (uv-error) ()
  (:documentation "ENOENT: no such file or directory."))
(define-condition permission-denied (uv-error) ()
  (:documentation "EACCES/EPERM: the operation was not permitted."))
(define-condition file-exists (uv-error) ()
  (:documentation "EEXIST: the path already exists."))
(define-condition not-a-directory (uv-error) ()
  (:documentation "ENOTDIR: a path component is not a directory."))
(define-condition is-a-directory (uv-error) ()
  (:documentation "EISDIR: the path is a directory and the operation needs a file."))
(define-condition directory-not-empty (uv-error) ()
  (:documentation "ENOTEMPTY: the directory still has entries."))

(define-condition await-timeout (uv-error) ()
  (:documentation
   "AWAIT gave up waiting. Ours, not libuv's -- the operation may still be in flight."))

(define-condition loop-closed (uv-error)
  ((code :initform 0))
  (:report
   (lambda (c stream)
     (declare (ignore c))
     (format stream "SUBMIT refused: the loop is closed or closing -- the thunk was not queued and will never run.")))
  (:documentation
   "SUBMIT was called on a loop CLOSE-LOOP has already begun tearing down.

Ours, not libuv's, and a REFUSAL rather than a failure -- so it does NOT inherit
UV-ERROR's report, which would claim libuv failed when libuv was never called.

Signalled rather than returned as NIL because a submission that silently vanishes
during shutdown is the defect class this condition exists because of (pre-publication issue 296): only
the CALLER knows whether dropping that work is correct, so the caller has to say
so. A teardown path that legitimately drops it handles this and says why."))

(defparameter *error-classes*
  '(("ENOENT" . file-not-found)
    ("EACCES" . permission-denied)
    ("EPERM" . permission-denied)
    ("EEXIST" . file-exists)
    ("ENOTDIR" . not-a-directory)
    ("EISDIR" . is-a-directory)
    ("ENOTEMPTY" . directory-not-empty))
  "libuv error name -> condition class. Names, not numbers: the numbers are platform
errnos, the names are libuv's and are the same everywhere.")

(defun uv-error-class (name)
  (or (cdr (assoc name *error-classes* :test #'string=)) 'uv-error))

(defun signal-uv-error (code &key operation path)
  "Signal the condition corresponding to libuv return CODE. CODE must be negative."
  (let* ((name (ffi:uv-err-name code))
         (message (ffi:uv-strerror code)))
    (error (uv-error-class name)
           :code code :name name :message message
           :operation operation :path path)))

(declaim (inline check))
(defun check (code &key operation path)
  "Return CODE if it is a success (>= 0), otherwise signal. The single choke point
through which every libuv return code passes on its way out of the raw layer."
  (if (minusp code)
      (signal-uv-error code :operation operation :path path)
      code))
