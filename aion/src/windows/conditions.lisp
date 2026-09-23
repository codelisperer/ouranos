;;;; conditions.lisp --- Win32 codes and HRESULTs become CL conditions.
;;;;
;;;; The house rule is that recoverable failure travels through the condition system, not
;;;; return codes, so every failing call is converted here exactly once. Windows reports
;;;; failure two different ways and they must not be conflated:
;;;;
;;;;   GetLastError  a DWORD set as a SIDE EFFECT, valid only immediately after a call that
;;;;                 documented itself as setting it. Reading it after any other API call
;;;;                 -- including one that succeeded -- returns something unrelated. So it
;;;;                 is read at the call site, never later.
;;;;
;;;;   HRESULT       a value RETURNED. Failure is the sign bit, which is why FFI declares it
;;;;                 :int32; read as unsigned, every failure looks like a large success.
;;;;
;;;; Both decode through FormatMessage, which is the only way to get the OS's own wording
;;;; rather than a table we would have to maintain and would get subtly wrong.

(in-package #:aion/windows)

;;; --- the conditions ----------------------------------------------------------

(define-condition windows-error (error)
  ((code :initarg :code :initform nil :reader windows-error-code
         :documentation "The raw numeric code, as Windows reported it.")
   (message :initarg :message :initform nil :reader windows-error-message
            :documentation "The OS's own wording, from FormatMessage.")
   (operation :initarg :operation :initform nil :reader windows-error-operation
              :documentation "The aion/windows operation that failed, e.g. :CO-CREATE-INSTANCE."))
  (:report
   (lambda (c stream)
     (format stream "Windows ~@[~A ~]failed: ~A~@[ (~A)~]"
             (windows-error-operation c)
             (or (windows-error-message c) "unknown error")
             (windows-error-code c))))
  (:documentation "Base of every error aion/windows signals from a Windows failure."))

(define-condition win32-error (windows-error) ()
  (:documentation "A call that reported failure through GetLastError."))

(define-condition hresult-error (windows-error)
  ((hresult :initarg :hresult :initform nil :reader hresult-error-hresult
            :documentation "The signed HRESULT, kept separately from the printed code."))
  (:documentation "A call that returned a failing HRESULT."))

;;; The handful worth catching by name. Everything else stays a plain HRESULT-ERROR, which
;;; still carries the code -- same doctrine as aion/uv's conditions: name what a caller
;;; would plausibly branch on, and no more.
(define-condition not-implemented (hresult-error) ()
  (:documentation "E_NOTIMPL: the object does not implement this."))
(define-condition access-denied (hresult-error) ()
  (:documentation "E_ACCESSDENIED: refused."))
(define-condition invalid-argument (hresult-error) ()
  (:documentation "E_INVALIDARG: an argument was rejected."))
(define-condition out-of-memory (hresult-error) ()
  (:documentation "E_OUTOFMEMORY."))

;;; --- decoding ----------------------------------------------------------------

(defconstant +e-notimpl+      #x80004001)
(defconstant +e-outofmemory+  #x8007000E)
(defconstant +e-invalidarg+   #x80070057)
(defconstant +e-accessdenied+ #x80070005)

(defun last-error ()
  "GetLastError, as an unsigned DWORD. Read IMMEDIATELY after the failing call."
  (ffi:get-last-error))

(defun error-message-for (code)
  "The OS's own text for CODE, or NIL if Windows has nothing to say about it.

FORMAT_MESSAGE_ALLOCATE_BUFFER makes Windows allocate; we own the buffer and LocalFree it,
which is why this is written with UNWIND-PROTECT rather than as a one-liner. IGNORE_INSERTS
matters too: without it, a message containing %1 makes FormatMessage go looking for varargs
we did not pass, and it faults."
  (cffi:with-foreign-object (buffer :pointer)
    (setf (cffi:mem-ref buffer :pointer) (cffi:null-pointer))
    (let ((n (ffi:format-message-w
              (logior ffi:+format-message-allocate-buffer+
                      ffi:+format-message-from-system+
                      ffi:+format-message-ignore-inserts+)
              (cffi:null-pointer)
              code
              0                          ; language: let Windows choose
              buffer
              0
              (cffi:null-pointer))))
      (let ((text (cffi:mem-ref buffer :pointer)))
        (unwind-protect
             (when (and (plusp n) (not (cffi:null-pointer-p text)))
               (string-right-trim
                '(#\Space #\Newline #\Return)
                (cffi:foreign-string-to-lisp text :encoding :utf-16le)))
          (unless (cffi:null-pointer-p text)
            (ffi:local-free text)))))))

(defun hresult-succeeded-p (hr)
  "True when HR is a success code. FAILED(hr) is hr < 0 -- the sign bit IS the flag."
  (>= hr 0))

(defun %hresult-unsigned (hr)
  "HR as the unsigned value Windows documents and FormatMessage expects."
  (logand hr #xFFFFFFFF))

(defun %hresult-condition-class (unsigned)
  (cond ((= unsigned +e-notimpl+) 'not-implemented)
        ((= unsigned +e-accessdenied+) 'access-denied)
        ((= unsigned +e-invalidarg+) 'invalid-argument)
        ((= unsigned +e-outofmemory+) 'out-of-memory)
        (t 'hresult-error)))

(defun check-hresult (hr &key operation)
  "Return HR when it succeeded; signal the right HRESULT-ERROR subclass when it did not."
  (if (hresult-succeeded-p hr)
      hr
      (let ((unsigned (%hresult-unsigned hr)))
        (error (%hresult-condition-class unsigned)
               :hresult hr
               :code (format nil "0x~8,'0X" unsigned)
               :message (error-message-for unsigned)
               :operation operation))))

(defun check-win32 (result &key operation (predicate #'identity))
  "Return RESULT when the call succeeded; otherwise signal WIN32-ERROR from GetLastError.

PREDICATE says what success looks like, because Win32 has no single convention: most
functions return zero for failure, some return a sentinel handle, and a few return the count
they wrote. The caller states it rather than this function guessing -- guessing here would
turn a successful call returning 0 into an error, which is the one failure mode a wrapper
like this must not have."
  (if (funcall predicate result)
      result
      (let ((code (last-error)))
        (error 'win32-error
               :code code
               :message (error-message-for code)
               :operation operation))))
