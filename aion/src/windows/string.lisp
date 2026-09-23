;;;; string.lisp --- UTF-16 marshalling. Every modern entry point is the W variant.
;;;;
;;;; ADR-0003 s2 puts this in the foundation because every subsystem needs it and it is
;;;; expensive to get wrong. The A variants are not a simpler alternative: they encode
;;;; through the machine's ANSI code page, so the same call silently produces different
;;;; bytes on a Japanese Windows than on an English one, and any path outside the code page
;;;; becomes question marks. There is no "ASCII is fine" case -- a user's home directory is
;;;; enough to break it.
;;;;
;;;; WCHAR is a UTF-16 CODE UNIT, not a character. Anything outside the BMP is a surrogate
;;;; pair and occupies two of them, so a Lisp string of N characters is not N code units and
;;;; must never be assumed to be. CFFI's :utf-16le encoding does the conversion; what this
;;;; file adds is ownership -- who frees what, and when.

(in-package #:aion/windows)

(defun lisp-to-wide-string (string)
  "Allocate a null-terminated UTF-16LE copy of STRING. THE CALLER OWNS IT.

Returns a foreign pointer to be released with FREE-WIDE-STRING. Prefer WITH-WIDE-STRING;
this exists for the cases where the lifetime genuinely outlives a dynamic extent, which in
COM is common enough to need a name."
  (cffi:foreign-string-alloc string :encoding :utf-16le :null-terminated-p t))

(defun free-wide-string (pointer)
  "Release a string allocated by LISP-TO-WIDE-STRING."
  (unless (cffi:null-pointer-p pointer)
    (cffi:foreign-string-free pointer)))

(defun wide-string-to-lisp (pointer &key (max-chars nil))
  "Decode a null-terminated UTF-16LE string at POINTER. Does NOT free it.

Not freeing is the whole point of the name: who releases a string depends entirely on which
API produced it -- LocalFree for FormatMessage, SysFreeString for a BSTR, CoTaskMemFree for
most COM out-parameters, and nothing at all for a buffer we own. Folding a free in here
would be right for one of those and memory corruption for the other three."
  (unless (cffi:null-pointer-p pointer)
    (cffi:foreign-string-to-lisp pointer
                                 :encoding :utf-16le
                                 :max-chars (or max-chars array-total-size-limit))))

(defmacro with-wide-string ((var string) &body body)
  "Bind VAR to a temporary null-terminated UTF-16LE copy of STRING for BODY.

UNWIND-PROTECT rather than CFFI's WITH-FOREIGN-STRING alone, so a non-local exit out of BODY
-- which for this system means a signalled WINDOWS-ERROR, i.e. the common case -- still
releases the buffer."
  (let ((ptr (gensym "WIDE")))
    `(let ((,ptr (lisp-to-wide-string ,string)))
       (unwind-protect
            (let ((,var ,ptr)) ,@body)
         (free-wide-string ,ptr)))))
