;;;; typelib-ffi.lisp --- ITypeLib and ITypeInfo: the server describing itself.
;;;;
;;;; A COM automation server ships its own API description. ITypeLib enumerates the types it
;;;; defines; ITypeInfo describes one of them -- its methods, its parameters, its constants,
;;;; their DISPIDs and their help text. All of it readable at runtime, from the server that
;;;; is actually installed.
;;;;
;;;; THAT IS WHY THE WRAPPER DOES NOT HAVE TO BE WRITTEN. It has to be read out and emitted.
;;;;
;;;; ------------------------------------------------------------------------------
;;;; SIX STRUCTS, AND WHY THEY ARE ALL DECLARED WHEN TWO FIELDS WOULD DO
;;;; ------------------------------------------------------------------------------
;;;;
;;;; Reading enum constants needs exactly two fields: VARDESC.lpvarValue and VARDESC.varkind.
;;;; It would be shorter to declare VARDESC as an opaque block with those two at hand-computed
;;;; offsets. That is the tautology trap in layout.lisp wearing a different hat -- the offsets
;;;; would then be asserted against the same arithmetic that produced them.
;;;;
;;;; So TYPEDESC, PARAMDESC, IDLDESC and ELEMDESC are declared in full, purely so that
;;;; VARDESC's members are laid out by CFFI rather than by me. ELEMDESC is 32 bytes on x64 and
;;;; 16 on x86, and it sits BETWEEN the two fields this file actually reads: get it wrong and
;;;; `varkind' points at padding, every variable looks like something other than a constant,
;;;; and the generator emits an empty package with no error anywhere.
;;;;
;;;; A SILENTLY EMPTY RESULT IS THE WORST FAILURE AVAILABLE HERE, because nothing reports that
;;;; something did not happen -- the same shape as the platform-key defect in pre-publication issue 206, where a
;;;; client that never matched the manifest reported itself up to date forever.
;;;;
;;;; The four helper structs are therefore not decoration. They are how the two offsets that
;;;; matter come to be computed by something other than the person asserting them.

(in-package #:aion/windows/com/ffi)

;;; --- TYPEKIND and VARKIND ------------------------------------------------------

(defconstant +tkind-enum+ 0)
(defconstant +tkind-record+ 1)
(defconstant +tkind-module+ 2)
(defconstant +tkind-interface+ 3)
(defconstant +tkind-dispatch+ 4)
(defconstant +tkind-coclass+ 5)
(defconstant +tkind-alias+ 6)
(defconstant +tkind-union+ 7)

(defconstant +var-perinstance+ 0)
(defconstant +var-static+ 1)
(defconstant +var-const+ 2)
(defconstant +var-dispatch+ 3)

(defconstant +varflag-fhidden+ #x40
  "VARFLAG_FHIDDEN. The server marking a member as not part of its public surface -- what an
object browser hides by default and what an underscore-prefixed name usually accompanies.")

(defconstant +varflag-frestricted+ #x80
  "VARFLAG_FRESTRICTED. Not callable from a macro language. Reported alongside FHIDDEN.")

(defconstant +memberid-nil+ -1
  "MEMBERID_NIL. Passed to GetDocumentation to ask about the TYPE rather than a member of it.")

(defconstant +typelib-index-self+ -1
  "The index ITypeLib::GetDocumentation reads as `the library itself'.")

;;; --- the description structs ----------------------------------------------------

(cffi:defcstruct typedesc
  ;; A union of two self-referential pointers and an HREFTYPE. Only its WIDTH matters here.
  (u :pointer)
  (vt wffi:word))

(wffi:register-layout
 :name "TYPEDESC"
 :type '(:struct typedesc)
 :size '(:x86 8 :x64 16)
 :slots '((vt :offset (:x86 4 :x64 8)))
 :source "MSDN TYPEDESC / tagTYPEDESC (oaidl.h)")

(cffi:defcstruct paramdesc
  (p-param-desc-ex :pointer)
  (w-param-flags :uint16))

(wffi:register-layout
 :name "PARAMDESC"
 :type '(:struct paramdesc)
 :size '(:x86 8 :x64 16)
 :slots '((w-param-flags :offset (:x86 4 :x64 8)))
 :source "MSDN PARAMDESC / tagPARAMDESC (oaidl.h)")

(cffi:defcstruct idldesc
  ;; ULONG_PTR, so it is pointer-width -- which is why ELEMDESC changes size between
  ;; architectures, and with it the offset of the one field that decides what a variable is.
  (dw-reserved :pointer)
  (w-idl-flags :uint16))

(wffi:register-layout
 :name "IDLDESC"
 :type '(:struct idldesc)
 :size '(:x86 8 :x64 16)
 :slots '((w-idl-flags :offset (:x86 4 :x64 8)))
 :source "MSDN IDLDESC / tagIDLDESC (oaidl.h)")

(cffi:defcunion elemdesc-detail
  (idldesc (:struct idldesc))
  (paramdesc (:struct paramdesc)))

(cffi:defcstruct elemdesc
  (tdesc (:struct typedesc))
  (detail (:union elemdesc-detail)))

(wffi:register-layout
 :name "ELEMDESC"
 :type '(:struct elemdesc)
 ;; The struct that decides where VARDESC.varkind lands. See this file's header.
 :size '(:x86 16 :x64 32)
 :slots '((detail :offset (:x86 8 :x64 16)))
 :source "MSDN ELEMDESC / tagELEMDESC (oaidl.h)")

(cffi:defcstruct vardesc
  (memid :int32)
  (lpstr-schema :pointer)
  ;; union { ULONG oInst; VARIANT *lpvarValue; } -- pointer-width, and for a VAR_CONST it is
  ;; the pointer. Declared as the WIDER member for the same reason BRECORD is in VARIANT.
  (value :pointer)
  (elemdesc-var (:struct elemdesc))
  (w-var-flags :uint16)
  (varkind :int))

(wffi:register-layout
 :name "VARDESC"
 :type '(:struct vardesc)
 ;; x86: 4 memid, 4 schema, 4 union, 16 elemdesc, 2 flags + 2 pad, 4 varkind = 36.
 ;; x64: 4 memid + 4 pad, 8 schema, 8 union, 32 elemdesc, 2 flags + 2 pad, 4 varkind = 64.
 :size '(:x86 36 :x64 64)
 ;; BOTH FIELDS THIS FILE ACTUALLY READS, pinned. If ELEMDESC is mis-sized these move and the
 ;; generator silently emits nothing.
 :slots '((value :offset (:x86 8 :x64 16))
          (varkind :offset (:x86 32 :x64 60)))
 :source "MSDN VARDESC / tagVARDESC (oaidl.h)")

(cffi:defcstruct typeattr
  (guid (:struct wffi:guid))
  (lcid wffi:dword)
  (dw-reserved wffi:dword)
  (memid-constructor :int32)
  (memid-destructor :int32)
  (lpstr-schema :pointer)
  (cb-size-instance :uint32)
  (typekind :int)
  (c-funcs :uint16)
  (c-vars :uint16)
  (c-impl-types :uint16)
  (cb-size-vft :uint16)
  (cb-alignment :uint16)
  (w-type-flags :uint16)
  (w-major-ver-num :uint16)
  (w-minor-ver-num :uint16)
  (tdesc-alias (:struct typedesc))
  (idldesc-type (:struct idldesc)))

(wffi:register-layout
 :name "TYPEATTR"
 :type '(:struct typeattr)
 :size '(:x86 76 :x64 96)
 :slots '((lpstr-schema :offset (:x86 32 :x64 32))
          (cb-size-instance :offset (:x86 36 :x64 40))
          (typekind :offset (:x86 40 :x64 44))
          (c-vars :offset (:x86 46 :x64 50)))
 :source "MSDN TYPEATTR / tagTYPEATTR (oaidl.h)")

(cffi:defcstruct tlibattr
  (guid (:struct wffi:guid))
  (lcid wffi:dword)
  (syskind :int)
  (w-major-ver-num :uint16)
  (w-minor-ver-num :uint16)
  (w-lib-flags :uint16))

(wffi:register-layout
 :name "TLIBATTR"
 :type '(:struct tlibattr)
 ;; No pointers, so it is 32 on both -- the one struct here that does not move.
 :size '(:x86 32 :x64 32)
 :slots '((w-major-ver-num :offset (:x86 24 :x64 24))
          (w-minor-ver-num :offset (:x86 26 :x64 26)))
 :source "MSDN TLIBATTR / tagTLIBATTR (oaidl.h)")

;;; --- loading a type library from a file -------------------------------------------

(cffi:defcfun ("LoadTypeLibEx" load-type-lib-ex) wffi:hresult
  (sz-file :pointer)
  (reg-kind :int)
  (pptlib :pointer))

(defconstant +regkind-none+ 2
  "REGKIND_NONE.

LoadTypeLib -- and LoadTypeLibEx under REGKIND_DEFAULT -- will REGISTER a type library it
loads from a path, writing to HKEY_CLASSES_ROOT and needing elevation to do it. Reading a
description must not modify the machine, so every load here passes REGKIND_NONE. This is a
one-word difference between `inspect a file' and `install a file'.")

;;; --- ITypeLib and ITypeInfo through the vtable --------------------------------------
;;;
;;; The slot indices, which are the contract. Counted past IUnknown's three:
;;;
;;;   ITypeLib:   3 GetTypeInfoCount   4 GetTypeInfo      5 GetTypeInfoType
;;;               6 GetTypeInfoOfGuid  7 GetLibAttr       8 GetTypeComp
;;;               9 GetDocumentation  10 IsName          11 FindName
;;;              12 ReleaseTLibAttr
;;;
;;;   ITypeInfo:  3 GetTypeAttr        4 GetTypeComp      5 GetFuncDesc
;;;               6 GetVarDesc         7 GetNames         8 GetRefTypeOfImplType
;;;               9 GetImplTypeFlags  10 GetIDsOfNames   11 Invoke
;;;              12 GetDocumentation  13 GetDllEntry     14 GetRefTypeInfo
;;;              15 AddressOfMember   16 CreateInstance  17 GetMops
;;;              18 GetContainingTypeLib                 19 ReleaseTypeAttr
;;;              20 ReleaseFuncDesc   21 ReleaseVarDesc
;;;
;;; WRITTEN OUT IN FULL RATHER THAN ONLY THE NINE USED, because an off-by-one here does not
;;; fail cleanly: it calls a DIFFERENT, REAL FUNCTION with this call's arguments. An early
;;; draft of this work had GetContainingTypeLib at 22 and ReleaseTypeAttr at 18 -- both
;;; plausible, both wrong -- and the result was not an error at the call but
;;; `Memory fault at 0000000000000004' several calls later, in unrelated code. Listing every
;;; slot is how the arithmetic gets checked against something other than itself.

(defun itypelib-get-type-info-count (this)
  "The number of types in the library.

RETURNS A COUNT, NOT AN HRESULT. ITypeLib::GetTypeInfoCount is `UINT GetTypeInfoCount()',
unlike IDispatch::GetTypeInfoCount which takes an out-parameter and returns HRESULT. Two
methods, one name, different signatures -- and reading this one as an HRESULT makes an empty
library look like S_OK and any non-empty one look like a failure."
  (cffi:foreign-funcall-pointer (vtable-slot this 3) () :pointer this :uint32))

(defun itypelib-get-type-info (this index pp-tinfo)
  (cffi:foreign-funcall-pointer (vtable-slot this 4) ()
                                :pointer this :uint32 index :pointer pp-tinfo
                                wffi:hresult))

(defun itypelib-get-type-info-type (this index p-tkind)
  (cffi:foreign-funcall-pointer (vtable-slot this 5) ()
                                :pointer this :uint32 index :pointer p-tkind
                                wffi:hresult))

(defun itypelib-get-lib-attr (this pp-tlibattr)
  (cffi:foreign-funcall-pointer (vtable-slot this 7) ()
                                :pointer this :pointer pp-tlibattr
                                wffi:hresult))

(defun itypelib-get-documentation (this index p-name p-doc p-help-ctx p-help-file)
  (cffi:foreign-funcall-pointer (vtable-slot this 9) ()
                                :pointer this :int index
                                :pointer p-name :pointer p-doc
                                :pointer p-help-ctx :pointer p-help-file
                                wffi:hresult))

(defun itypelib-release-tlib-attr (this p-tlibattr)
  (cffi:foreign-funcall-pointer (vtable-slot this 12) ()
                                :pointer this :pointer p-tlibattr :void))

(defun itypeinfo-get-type-attr (this pp-typeattr)
  (cffi:foreign-funcall-pointer (vtable-slot this 3) ()
                                :pointer this :pointer pp-typeattr
                                wffi:hresult))

(defun itypeinfo-get-var-desc (this index pp-vardesc)
  (cffi:foreign-funcall-pointer (vtable-slot this 6) ()
                                :pointer this :uint32 index :pointer pp-vardesc
                                wffi:hresult))

(defun itypeinfo-get-documentation (this memid p-name p-doc p-help-ctx p-help-file)
  (cffi:foreign-funcall-pointer (vtable-slot this 12) ()
                                :pointer this :int32 memid
                                :pointer p-name :pointer p-doc
                                :pointer p-help-ctx :pointer p-help-file
                                wffi:hresult))

(defun itypeinfo-get-containing-type-lib (this pp-tlib p-index)
  (cffi:foreign-funcall-pointer (vtable-slot this 18) ()
                                :pointer this :pointer pp-tlib :pointer p-index
                                wffi:hresult))

(defun itypeinfo-release-type-attr (this p-typeattr)
  (cffi:foreign-funcall-pointer (vtable-slot this 19) ()
                                :pointer this :pointer p-typeattr :void))

(defun itypeinfo-release-var-desc (this p-vardesc)
  (cffi:foreign-funcall-pointer (vtable-slot this 21) ()
                                :pointer this :pointer p-vardesc :void))

(defun idispatch-get-type-info (this i-tinfo lcid pp-tinfo)
  "IDispatch::GetTypeInfo -- slot 4, and the route from a LIVE OBJECT to its own description.

This is what lets the generator read the Office that is INSTALLED rather than the Office it
was written against."
  (cffi:foreign-funcall-pointer (vtable-slot this 4) ()
                                :pointer this :uint32 i-tinfo :uint32 lcid
                                :pointer pp-tinfo
                                wffi:hresult))

;;; The typelib structs, checked before anything reads a byte through them.
(wffi:verify-layouts)
