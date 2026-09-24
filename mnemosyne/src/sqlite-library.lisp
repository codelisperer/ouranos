;;;; sqlite-library.lisp --- which SQLite library this image is using, and its version (#129)
;;;;
;;;; cl-sqlite loads SQLite by a bare name ("libsqlite3", "sqlite3") while it is itself being
;;;; loaded, and the operating system's loader decides which file answers. Neither SBCL nor CFFI
;;;; keeps the file it chose: both hold only the name. On Windows that let an unrelated program's
;;;; sqlite3.dll carry the SQLite backend's green checks for months, and on the machine #201
;;;; measured, SBCL loaded Delphi's 3.45.3 while nothing inside the image could say so.
;;;;
;;;; HOW THE FILE IS FOUND. Not by searching for the name again: that would report a file that
;;;; answers to the name now, which is not necessarily the file that was loaded. Instead this
;;;; takes the address of `sqlite3_open', resolved the same way cl-sqlite's own calls resolve it,
;;;; and asks the platform which loaded file that address lies in -- `dladdr' on macOS and
;;;; Linux, `GetModuleHandleExW' and `GetModuleFileNameW' on Windows. The answer is therefore
;;;; about the code mnemosyne actually runs. The version comes from `sqlite3_libversion()',
;;;; called through the same lookup.
;;;;
;;;; WHY IT DOES NOT CHOOSE THE FILE ITSELF. #129 proposes resolving a path first and loading
;;;; that, as aion/uv does for libuv. That needs code that runs before cl-sqlite loads, and ASDF
;;;; loads cl-sqlite (through dbd-sqlite3) before any file of mnemosyne, so it would take a new
;;;; system ordered ahead of cl-sqlite. Reporting the file actually in use answers #129's
;;;; question without that, and on every platform.
;;;;
;;;; macOS: the system libsqlite3 lives in the dyld shared cache, so the path reported for it
;;;; (/usr/lib/libsqlite3.dylib) is the name dyld records and need not exist on disk.

(in-package #:mnemosyne/sqlite-library)

(defparameter +probe-symbol+ "sqlite3_open"
  "The SQLite function whose address identifies the library. cl-sqlite calls it to open every
connection, so the file that contains it is the file the SQLite backend runs.")

(defun %symbol-address (name)
  "The address NAME resolves to in this image, or NIL. The lookup is the one CFFI uses for a
DEFCFUN with no :LIBRARY, which is how cl-sqlite declares its functions."
  (let ((p (cffi:foreign-symbol-pointer name)))
    (and p (not (cffi:null-pointer-p p)) p)))

(defun %function-address (name)
  "The address of the C function NAME, or an error saying it is not defined in this image.

Every foreign call in this file goes through this and CFFI:FOREIGN-FUNCALL-POINTER rather than
CFFI:FOREIGN-FUNCALL. FOREIGN-FUNCALL links the symbol when the file is compiled, so a symbol
the platform does not provide would be a compile-time note and an error of a different kind at
run time. Resolving here makes every missing function the same thing: an ordinary error, which
LOADED-LIBRARY turns into its :ERROR reason."
  (or (%symbol-address name)
      (error "~A is not defined in this image" name)))

#-windows
(defun %file-containing (address)
  "The loaded file ADDRESS lies in, as a namestring, according to dladdr(3). Signals an error if
dladdr cannot place it."
  ;; Dl_info is four pointer-sized fields; the first, dli_fname, is the file name.
  (cffi:with-foreign-object (info :pointer 4)
    (when (zerop (cffi:foreign-funcall-pointer (%function-address "dladdr") ()
                                               :pointer address :pointer info :int))
      (error "dladdr could not place the address in any loaded file"))
    (let ((fname (cffi:mem-aref info :pointer 0)))
      (when (cffi:null-pointer-p fname)
        (error "dladdr returned no file name"))
      (cffi:foreign-string-to-lisp fname))))

#+windows
(defun %file-containing (address)
  "The loaded module ADDRESS lies in, as a namestring, according to GetModuleHandleExW and
GetModuleFileNameW. Signals an error if either call fails."
  ;; 4 = GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, 2 = GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT.
  (let ((capacity 32768))
    (cffi:with-foreign-objects ((module :pointer) (buffer :uint16 capacity))
      (when (zerop (cffi:foreign-funcall-pointer (%function-address "GetModuleHandleExW") ()
                                                 :uint32 6 :pointer address :pointer module :int))
        (error "GetModuleHandleExW could not place the address in any loaded module"))
      (let ((n (cffi:foreign-funcall-pointer (%function-address "GetModuleFileNameW") ()
                                             :pointer (cffi:mem-ref module :pointer)
                                             :pointer buffer :uint32 capacity :uint32)))
        (when (zerop n)
          (error "GetModuleFileNameW returned no file name"))
        (cffi:foreign-string-to-lisp buffer :count (* 2 n) :encoding :utf-16le)))))

(defun loaded-library ()
  "Which SQLite library this image is using, as a plist:

  :PATH     the file that contains the sqlite3_open this image calls, or NIL
  :VERSION  what that library's sqlite3_libversion() returns, or NIL
  :ERROR    NIL, or a string saying why PATH or VERSION could not be found

An error is returned rather than signalled because the callers are reports: a line saying the
path is unknown, and why, is the result they need to print. That includes the test runner's
banner, which verify-tree.lisp reads; nothing in here may fail the gate.

SERIOUS-CONDITION, not ERROR, so a storage or stack exhaustion inside the lookup is reported as
a reason too."
  (handler-case
      (let ((address (%symbol-address +probe-symbol+)))
        (if (null address)
            (list :path nil :version nil
                  :error (format nil "~A is not defined in this image; is SQLite loaded?"
                                 +probe-symbol+))
            (list :path (%file-containing address)
                  :version (cffi:foreign-funcall-pointer
                            (%function-address "sqlite3_libversion") () :string)
                  :error nil)))
    (serious-condition (e)
      (list :path nil :version nil
            :error (or (ignore-errors (princ-to-string e))
                       (format nil "~S" (type-of e)))))))

(defun describe-loaded-library (&optional (report (loaded-library)))
  "One line naming the SQLite library in REPORT (default: this image's): \"<version> <path>\",
or \"UNKNOWN (<reason>)\". The path is last so a path containing spaces stays one field."
  (destructuring-bind (&key path version error) report
    (if error
        (format nil "UNKNOWN (~A)" error)
        (format nil "~A ~A" version path))))
