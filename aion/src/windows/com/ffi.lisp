;;;; ffi.lisp --- raw COM. VARIANT is the reason this whole binding exists.
;;;;
;;;; ============================================================================
;;;; VARIANT, and why it is declared with its full member list
;;;; ============================================================================
;;;;
;;;; cl-win32ole sized VARIANT at 16 bytes. That is right on x86 and WRONG on x64, where it
;;;; is 24. The argument array was under-allocated and strode 16 bytes per element, so
;;;; argument 0 landed correctly and every call with two or more arguments read garbage as
;;;; pointers. Silent, architecture-specific memory corruption on the core data path.
;;;;
;;;; The 8 bytes are not padding and not arbitrary. VARIANT is:
;;;;
;;;;     VARTYPE vt;  WORD wReserved1, wReserved2, wReserved3;   <- 8 bytes of header
;;;;     union { ... many 4- and 8-byte members ...,  BRECORD brecVal; };
;;;;
;;;; and BRECORD is `struct { PVOID pvRecord; IRecordInfo *pRecInfo; }' -- TWO pointers. So
;;;; the union is 8 bytes wide on x86 and 16 on x64, and the struct is 16 and 24. The whole
;;;; difference is one member of one union that automation code never touches.
;;;;
;;;; THAT is why BRECORD is declared here even though nothing in this system uses a record:
;;;; omitting it would make CFFI compute 16 on x64 -- reproducing the exact defect -- and
;;;; the layout assertion in layout.lisp would then catch it, because the documented 24 was
;;;; arrived at independently of the member list. Declaring the union without BRECORD and
;;;; documenting the size as 24 would be the tautology trap avoided (see layout.lisp): the
;;;; numbers have to come from different places or the check proves nothing.

(in-package #:aion/windows/com/ffi)

;;; --- BSTR and string plumbing ------------------------------------------------
;;;
;;; A BSTR is a length-prefixed UTF-16 string: the pointer names the CHARACTERS, and the
;;; byte count sits at pointer-4. So it is not a plain wide string and must never be freed
;;; with anything but SysFreeString, which knows to step back over the prefix.

(cffi:defcfun ("SysAllocString" sys-alloc-string) :pointer
  (psz :pointer))

(cffi:defcfun ("SysFreeString" sys-free-string) :void
  (bstr :pointer))

(cffi:defcfun ("SysStringLen" sys-string-len) wffi:dword
  (bstr :pointer))

;;; --- VARIANT -----------------------------------------------------------------

(defconstant +vt-empty+ 0)    (defconstant +vt-null+ 1)
(defconstant +vt-i2+ 2)       (defconstant +vt-i4+ 3)
(defconstant +vt-r4+ 4)       (defconstant +vt-r8+ 5)
(defconstant +vt-cy+ 6)       (defconstant +vt-date+ 7)
(defconstant +vt-bstr+ 8)     (defconstant +vt-dispatch+ 9)
(defconstant +vt-error+ 10)   (defconstant +vt-bool+ 11)
(defconstant +vt-variant+ 12) (defconstant +vt-unknown+ 13)
(defconstant +vt-i1+ 16)      (defconstant +vt-ui1+ 17)
(defconstant +vt-ui2+ 18)     (defconstant +vt-ui4+ 19)
(defconstant +vt-i8+ 20)      (defconstant +vt-ui8+ 21)
(defconstant +vt-int+ 22)     (defconstant +vt-uint+ 23)
(defconstant +vt-decimal+ 14)
(defconstant +vt-byref+ #x4000)

;;; DECIMAL, and it does NOT live in the union with everything else.
;;;
;;; `tagVARIANT' is a union of the familiar { vt, wReserved1..3, value } struct AND a bare
;;; DECIMAL -- so a VT_DECIMAL variant IS a DECIMAL, starting at offset 0, and its wReserved
;;; field OVERLAPS the vt. Read it at offset 8 like every other payload and you get the
;;; middle of the number. This is exactly the class of trap ADR-0003 s4 exists for: the
;;; layout is documented, nothing at runtime will tell you, and being wrong reads plausible
;;; values rather than failing.
;;;
;;;   wReserved  0  (2)   <- occupied by vt
;;;   scale      2  (1)   the power of ten to divide by, 0..28
;;;   sign       3  (1)   0x80 when negative
;;;   Hi32       4  (4)   the high 32 bits of a 96-bit integer
;;;   Lo64       8  (8)   the low 64
(cffi:defcstruct decimal
  (w-reserved wffi:word)
  (scale :uint8)
  (sign :uint8)
  (hi32 :uint32)
  (lo64 :uint64))

(wffi:register-layout
 :name "DECIMAL"
 :type '(:struct decimal)
 :size '(:x86 16 :x64 16)
 :slots '((scale :offset (:x86 2 :x64 2))
          (sign :offset (:x86 3 :x64 3))
          (hi32 :offset (:x86 4 :x64 4))
          (lo64 :offset (:x86 8 :x64 8)))
 :source "MSDN DECIMAL (wtypes.h); shares offset 0 with VARIANT, hence 16 = sizeof(VARIANT) on x86")

;;; The union member that decides the whole struct's size. Two pointers.
(cffi:defcstruct brecord
  (pv-record :pointer)
  (p-rec-info :pointer))

(cffi:defcunion variant-value
  (ll-val :int64)
  (l-val :int32)
  (b-val :uint8)
  (i-val :int16)
  (flt-val :float)
  (dbl-val :double)
  (bool-val :int16)
  (scode :int32)
  (bstr-val :pointer)
  (p-disp-val :pointer)
  (p-unk-val :pointer)
  (parray :pointer)
  (byref :pointer)
  ;; Present precisely because it is the widest member. See the header note.
  (brec-val (:struct brecord)))

(cffi:defcstruct variant
  (vt wffi:word)
  (w-reserved1 wffi:word)
  (w-reserved2 wffi:word)
  (w-reserved3 wffi:word)
  (value (:union variant-value)))

(wffi:register-layout
 :name "VARIANT"
 :type '(:struct variant)
 ;; 8 bytes of header, then a union whose widest member is BRECORD (two pointers).
 ;; THE NUMBER THAT COST cl-win32ole EVERY MULTI-ARGUMENT CALL.
 :size '(:x86 16 :x64 24)
 :slots '((vt :offset (:x86 0 :x64 0))
          (value :offset (:x86 8 :x64 8)))
 :source "MSDN VARIANT / tagVARIANT (oaidl.h); union widened by BRECORD")

(cffi:defcfun ("VariantInit" variant-init) :void
  (pvarg :pointer))

(cffi:defcfun ("VariantClear" variant-clear) wffi:hresult
  (pvarg :pointer))

(cffi:defcfun ("VariantChangeType" variant-change-type) wffi:hresult
  (pvargdest :pointer)
  (pvarsrc :pointer)
  (w-flags wffi:word)
  (vt wffi:word))

;;; --- DISPPARAMS and EXCEPINFO -------------------------------------------------

(cffi:defcstruct dispparams
  (rgvarg :pointer)
  (rgdispid-named-args :pointer)
  (c-args :uint32)
  (c-named-args :uint32))

(wffi:register-layout
 :name "DISPPARAMS"
 :type '(:struct dispparams)
 ;; two pointers then two UINTs: 4+4+4+4 on x86, 8+8+4+4 on x64.
 :size '(:x86 16 :x64 24)
 :slots '((rgvarg :offset (:x86 0 :x64 0))
          (c-args :offset (:x86 8 :x64 16)))
 :source "MSDN DISPPARAMS (oaidl.h)")

(cffi:defcstruct excepinfo
  (w-code wffi:word)
  (w-reserved wffi:word)
  (bstr-source :pointer)
  (bstr-description :pointer)
  (bstr-help-file :pointer)
  (dw-help-context wffi:dword)
  (pv-reserved :pointer)
  (pfn-deferred-fill-in :pointer)
  (scode :int32))

(wffi:register-layout
 :name "EXCEPINFO"
 :type '(:struct excepinfo)
 ;; x86: packed at 4-byte alignment. x64: the two WORDs are followed by 4 bytes of padding
 ;; before the first pointer, and dwHelpContext by 4 more before pvReserved.
 :size '(:x86 32 :x64 64)
 :slots '((bstr-source :offset (:x86 4 :x64 8))
          (dw-help-context :offset (:x86 16 :x64 32))
          (scode :offset (:x86 28 :x64 56)))
 :source "MSDN EXCEPINFO (oaidl.h)")

;;; --- apartments ---------------------------------------------------------------

(defconstant +coinit-apartmentthreaded+ #x2)
(defconstant +coinit-multithreaded+ #x0)
(defconstant +coinit-disable-ole1dde+ #x4)
(defconstant +coinit-speed-over-memory+ #x8)

(cffi:defcfun ("CoInitializeEx" co-initialize-ex) wffi:hresult
  (pv-reserved :pointer)
  (dw-co-init wffi:dword))

(cffi:defcfun ("CoUninitialize" co-uninitialize) :void)

;;; --- creating objects ----------------------------------------------------------

(defconstant +clsctx-inproc-server+ #x1)
(defconstant +clsctx-local-server+ #x4)
;; What an automation caller wants: in-process if the server offers it, out-of-process
;; otherwise. Office is local-server; Scripting.FileSystemObject is in-process.
(defconstant +clsctx-server+ #x15)

(cffi:defcfun ("CLSIDFromProgID" clsid-from-prog-id) wffi:hresult
  (lpsz-prog-id :pointer)
  (lpclsid :pointer))

(cffi:defcfun ("CoCreateInstance" co-create-instance) wffi:hresult
  (rclsid :pointer)
  (p-unk-outer :pointer)
  (dw-cls-context wffi:dword)
  (riid :pointer)
  (ppv :pointer))

;;; --- calling through a vtable ---------------------------------------------------
;;;
;;; A COM interface pointer points at a pointer to a table of function pointers. There is no
;;; header to read, so the slot INDEX is the contract, and the indices below are fixed by
;;; the interface definitions and can never change -- that is what binary compatibility
;;; means for COM.
;;;
;;;   IUnknown:  0 QueryInterface  1 AddRef  2 Release
;;;   IDispatch: 3 GetTypeInfoCount  4 GetTypeInfo  5 GetIDsOfNames  6 Invoke

(declaim (inline vtable-slot))
(defun vtable-slot (interface index)
  "The function pointer at INDEX in INTERFACE's vtable."
  (cffi:mem-aref (cffi:mem-ref interface :pointer) :pointer index))

(defun iunknown-query-interface (this riid ppv)
  (cffi:foreign-funcall-pointer (vtable-slot this 0) ()
                                :pointer this :pointer riid :pointer ppv
                                wffi:hresult))

(defun iunknown-add-ref (this)
  (cffi:foreign-funcall-pointer (vtable-slot this 1) () :pointer this :uint32))

(defun iunknown-release (this)
  (cffi:foreign-funcall-pointer (vtable-slot this 2) () :pointer this :uint32))

(defun idispatch-get-ids-of-names (this riid rgsz-names c-names lcid rgdispid)
  (cffi:foreign-funcall-pointer (vtable-slot this 5) ()
                                :pointer this :pointer riid :pointer rgsz-names
                                :uint32 c-names :uint32 lcid :pointer rgdispid
                                wffi:hresult))

(defun idispatch-invoke (this dispid riid lcid w-flags p-dispparams
                         p-var-result p-excepinfo pu-arg-err)
  (cffi:foreign-funcall-pointer (vtable-slot this 6) ()
                                :pointer this :int32 dispid :pointer riid
                                :uint32 lcid :uint16 w-flags :pointer p-dispparams
                                :pointer p-var-result :pointer p-excepinfo
                                :pointer pu-arg-err
                                wffi:hresult))

(defconstant +dispatch-method+ #x1)
(defconstant +dispatch-property-get+ #x2)
(defconstant +dispatch-property-put+ #x4)
(defconstant +dispid-property-put+ -3)

;;; --- well-known IIDs -------------------------------------------------------------

(defparameter +iid-iunknown+ "{00000000-0000-0000-C000-000000000046}")
(defparameter +iid-idispatch+ "{00020400-0000-0000-C000-000000000046}")

;;; Re-run with COM's structs now registered. ffi.lisp in the foundation already verified
;;; what it knew about; this proves the additions before anything can marshal through them.
(wffi:verify-layouts)
