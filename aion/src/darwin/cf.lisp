;;;; cf.lisp --- owned CoreFoundation objects and OSStatus as a condition (ADR-0004).
;;;;
;;;; OWNERSHIP. CoreFoundation's rule: a function with Create or Copy in its name returns an
;;;; object the caller owns and must CFRelease once; a Get function returns one the caller does
;;;; not own and must not release. Every MAKE-CF-* here is a Create, so its result is owned.
;;;; WITH-CF releases what it binds on every exit, unwinds included, so an error between a
;;;; Create and its release cannot leak the object. A value put into a dictionary is retained by
;;;; the dictionary, so the caller still releases its own reference.
;;;;
;;;; OSSTATUS. Security.framework returns an OSStatus, 0 for success. CHECK-OSSTATUS turns any
;;;; other value into an OSSTATUS-ERROR carrying the code, the operation and the OS's own
;;;; wording from SecCopyErrorMessageString, so no table of codes is kept here.

(in-package #:aion/darwin)

;;; --- conditions ---------------------------------------------------------------------------

(define-condition darwin-error (error)
  ((code :initarg :code :initform nil :reader darwin-error-code
         :documentation "The raw numeric code, as macOS reported it.")
   (message :initarg :message :initform nil :reader darwin-error-message
            :documentation "The OS's own wording, when it has one.")
   (operation :initarg :operation :initform nil :reader darwin-error-operation
              :documentation "The operation that failed, e.g. :SEC-ITEM-ADD."))
  (:report (lambda (c stream)
             (format stream "macOS ~@[~A ~]failed: ~A~@[ (~A)~]"
                     (darwin-error-operation c)
                     (or (darwin-error-message c) "unknown error")
                     (darwin-error-code c))))
  (:documentation "Base of every error aion/darwin signals from a macOS failure."))

(define-condition osstatus-error (darwin-error) ()
  (:documentation "A call that returned a failing OSStatus."))

(defun osstatus-message (status)
  "macOS's own wording for STATUS, from SecCopyErrorMessageString, or NIL if it has none."
  (let ((ref (ffi:sec-copy-error-message-string status (cffi:null-pointer))))
    (unless (cffi:null-pointer-p ref)
      (unwind-protect (cf-string-to-lisp ref)
        (ffi:cf-release ref)))))

(defun check-osstatus (status operation)
  "Return STATUS when it is errSecSuccess (0); otherwise signal OSSTATUS-ERROR naming OPERATION."
  (if (= status ffi:+err-sec-success+)
      status
      (error 'osstatus-error :code status :operation operation :message (osstatus-message status))))

;;; --- ownership ----------------------------------------------------------------------------

(defun cf-release (ref)
  "CFRelease REF unless it is NULL or NIL. CFRelease itself crashes on NULL."
  (when (and ref (not (cffi:null-pointer-p ref)))
    (ffi:cf-release ref))
  nil)

(defun cf-retain (ref)
  "CFRetain REF and return it: one more reference the caller now owns."
  (ffi:cf-retain ref))

(defmacro with-cf (bindings &body body)
  "Bind each (VAR FORM) in BINDINGS to an owned CF object and run BODY, releasing each one that
is not NULL on exit, normal or not. A later binding may use an earlier one."
  (if (null bindings)
      `(locally ,@body)
      (destructuring-bind ((var form) &rest more) bindings
        `(let ((,var ,form))
           (unwind-protect (with-cf ,more ,@body)
             (cf-release ,var))))))

(defun %created (ref what)
  "REF, a just-created CF object, or a DARWIN-ERROR when the Create returned NULL."
  (when (cffi:null-pointer-p ref)
    (error 'darwin-error :operation what :message "CoreFoundation returned NULL"))
  ref)

;;; --- strings --------------------------------------------------------------------------------

(defun make-cf-string (string)
  "An owned CFString with STRING's characters, made from its UTF-8 bytes."
  (let* ((octets (sb-ext:string-to-octets string :external-format :utf-8))
         (n (length octets)))
    (cffi:with-foreign-object (buf :uint8 (max 1 n))
      (dotimes (i n) (setf (cffi:mem-aref buf :uint8 i) (aref octets i)))
      (%created (ffi:cf-string-create-with-bytes (cffi:null-pointer) buf n ffi:+cf-string-encoding-utf8+ 0)
                :make-cf-string))))

(defun cf-string-to-lisp (ref)
  "The characters of REF, a CFString the caller keeps ownership of, as a Lisp string."
  (let ((size (1+ (ffi:cf-string-get-maximum-size-for-encoding (ffi:cf-string-get-length ref)
                                                               ffi:+cf-string-encoding-utf8+))))
    (cffi:with-foreign-object (buf :uint8 size)
      (when (zerop (ffi:cf-string-get-c-string ref buf size ffi:+cf-string-encoding-utf8+))
        (error 'darwin-error :operation :cf-string-to-lisp :message "the string would not convert to UTF-8"))
      (cffi:foreign-string-to-lisp buf :encoding :utf-8))))

;;; --- data ---------------------------------------------------------------------------------

(defun make-cf-data (octets)
  "An owned CFData holding a copy of OCTETS, a vector of (unsigned-byte 8). The foreign buffer
the bytes pass through is zeroed before it is freed; CoreFoundation's own copy is not
zeroed when it is released, which is its limit (ADR-0004)."
  (let ((n (length octets)))
    (cffi:with-foreign-object (buf :uint8 (max 1 n))
      (unwind-protect
           (progn
             (dotimes (i n) (setf (cffi:mem-aref buf :uint8 i) (aref octets i)))
             (%created (ffi:cf-data-create (cffi:null-pointer) buf n) :make-cf-data))
        (dotimes (i (max 1 n)) (setf (cffi:mem-aref buf :uint8 i) 0))))))

(defun cf-data-octets (ref)
  "A fresh (unsigned-byte 8) vector copying the bytes of REF, a CFData the caller keeps."
  (let* ((n (ffi:cf-data-get-length ref))
         (ptr (ffi:cf-data-get-byte-ptr ref))
         (out (make-array n :element-type '(unsigned-byte 8))))
    (dotimes (i n out) (setf (aref out i) (cffi:mem-aref ptr :uint8 i)))))

;;; --- dictionaries -------------------------------------------------------------------------

(defun make-cf-dictionary (pairs)
  "An owned CFDictionary of PAIRS, a list of (KEY . VALUE) CF objects. The dictionary retains
its keys and values (the standard CFType callbacks), so the caller still releases its own."
  (let ((n (length pairs)))
    (cffi:with-foreign-objects ((keys :pointer (max 1 n)) (vals :pointer (max 1 n)))
      (loop for (k . v) in pairs
            for i from 0
            do (setf (cffi:mem-aref keys :pointer i) k
                     (cffi:mem-aref vals :pointer i) v))
      (%created (ffi:cf-dictionary-create (cffi:null-pointer) keys vals n
                                          (cffi:foreign-symbol-pointer "kCFTypeDictionaryKeyCallBacks")
                                          (cffi:foreign-symbol-pointer "kCFTypeDictionaryValueCallBacks"))
                :make-cf-dictionary))))

;;; --- framework constants --------------------------------------------------------------------

(defun cf-constant (name)
  "The value of the exported CF constant NAME, such as \"kSecClass\" or \"kCFBooleanTrue\": a
CFTypeRef the framework owns, which the caller never releases. Signals DARWIN-ERROR when no
loaded framework exports NAME."
  (let ((address (cffi:foreign-symbol-pointer name)))
    (unless address
      (error 'darwin-error :operation :cf-constant :message (format nil "no loaded framework exports ~A" name)))
    (cffi:mem-ref address :pointer)))
