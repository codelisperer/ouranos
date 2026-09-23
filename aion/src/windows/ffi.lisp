;;;; ffi.lisp --- the raw layer. Windows spellings survive here on purpose.
;;;;
;;;; A reader with an MSDN page open should be able to search for the identifier in front of
;;;; them, so LPWSTR, dwFlags and HRESULT are not renamed to something more Lispy until they
;;;; cross into AION/WINDOWS. Same rule aion/uv/ffi follows.
;;;;
;;;; TYPES. Windows' typedef zoo reduces to very little once the aliases are unwound:
;;;;   DWORD    32-bit unsigned          HRESULT  32-bit SIGNED (the sign bit is the
;;;;   WORD     16-bit unsigned                   failure flag, so it must not be unsigned)
;;;;   BOOL     32-bit signed int        HANDLE   pointer-width opaque
;;;;   LPWSTR   pointer to UTF-16LE      WCHAR    16-bit code unit
;;;;
;;;; HRESULT being signed is not a detail. `FAILED(hr)' is `hr < 0', and reading it as
;;;; unsigned turns every failure into a large positive number that tests as success.

(in-package #:aion/windows/ffi)

;;; --- primitive types --------------------------------------------------------

(cffi:defctype dword :uint32)
(cffi:defctype word :uint16)
(cffi:defctype wide-char :uint16)
(cffi:defctype hresult :int32)          ; SIGNED -- see the header note
(cffi:defctype hmodule :pointer)
(cffi:defctype hwnd :pointer)

;;; --- structs, declared structurally so the layout check has teeth -----------
;;;
;;; See layout.lisp's "tautology trap" note: these are declared by their real members, and
;;; the documented sizes below were arrived at independently from Microsoft's documentation.
;;; CFFI computing the same number from the member list is the check.

(cffi:defcstruct filetime
  (low-date-time  dword)
  (high-date-time dword))

(register-layout
 :name "FILETIME"
 :type '(:struct filetime)
 ;; Two DWORDs, no padding, identical on both widths.
 :size '(:x86 8 :x64 8)
 :slots '((low-date-time  :offset (:x86 0 :x64 0))
          (high-date-time :offset (:x86 4 :x64 4)))
 :source "MSDN FILETIME (minwinbase.h)")

(cffi:defcstruct guid
  (data1 dword)
  (data2 word)
  (data3 word)
  (data4 :uint8 :count 8))

(register-layout
 :name "GUID"
 :type '(:struct guid)
 ;; 16 bytes on both widths: 4 + 2 + 2 + 8, alignment 4, no tail padding.
 :size '(:x86 16 :x64 16)
 :slots '((data1 :offset (:x86 0 :x64 0))
          (data2 :offset (:x86 4 :x64 4))
          (data3 :offset (:x86 6 :x64 6))
          (data4 :offset (:x86 8 :x64 8)))
 :source "MSDN GUID (guiddef.h); IID and CLSID are typedefs of it")

;;; --- errors -----------------------------------------------------------------

(defconstant +format-message-allocate-buffer+ #x00000100)
(defconstant +format-message-ignore-inserts+  #x00000200)
(defconstant +format-message-from-system+     #x00001000)

(cffi:defcfun ("GetLastError" get-last-error) dword)

;;; FormatMessageW with ALLOCATE_BUFFER treats lpBuffer as an LPWSTR* -- Windows allocates
;;; and we LocalFree. Declared :pointer for that reason; passing a plain buffer here is a
;;; classic way to corrupt the stack.
(cffi:defcfun ("FormatMessageW" format-message-w) dword
  (dw-flags dword)
  (lp-source :pointer)
  (dw-message-id dword)
  (dw-language-id dword)
  (lp-buffer :pointer)
  (n-size dword)
  (arguments :pointer))

(cffi:defcfun ("LocalFree" local-free) :pointer
  (h-mem :pointer))

(cffi:defcfun ("CoTaskMemFree" co-task-mem-free) :void
  (pv :pointer))

;;; --- handles ----------------------------------------------------------------

(cffi:defcfun ("CloseHandle" %close-handle) :int32
  (h-object :pointer))

;;; --- the layout gate --------------------------------------------------------
;;;
;;; Run at LOAD, and deliberately fatal. ADR-0003 s4: "built in from the first commit". A
;;; struct whose size we have wrong corrupts memory rather than returning a wrong answer, so
;;; refusing to finish loading is the only honest response -- the alternative is an image
;;; that works until someone passes two arguments.
(verify-layouts)
