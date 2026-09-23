;;;; packages.lisp --- aion/windows/com: OLE/COM automation.
;;;;
;;;; ADR-0003 s5 sequences COM first, and NOT because automation is the priority: it has the
;;;; widest reach per unit of work. WMI, the Shell, Task Scheduler, ADO, WSH and Office all
;;;; arrive through this one binding. It is the meta-API.
;;;;
;;;; This is the BINDING. Office automation is Hades (pre-publication issue 180), over this; an ADO backend is
;;;; mnemosyne's. Neither is here.

(cl:defpackage #:aion/windows/com/ffi
  (:use #:common-lisp)
  (:local-nicknames (#:wffi #:aion/windows/ffi))
  (:documentation "Raw COM FFI: CoInitializeEx, IDispatch, VARIANT, BSTR.")
  (:export
   ;; apartment
   #:co-initialize-ex #:co-uninitialize
   #:+coinit-apartmentthreaded+ #:+coinit-multithreaded+
   #:+coinit-disable-ole1dde+ #:+coinit-speed-over-memory+
   ;; objects
   #:co-create-instance #:clsid-from-prog-id #:+clsctx-inproc-server+
   #:+clsctx-local-server+ #:+clsctx-server+
   ;; interfaces -- VTABLE-SLOT is exported because extending this binding with a new
   ;; interface is impossible without it, and every caller would otherwise reinvent
   ;; (mem-aref (mem-ref p :pointer) :pointer n) with its own chance of being wrong
   #:vtable-slot
   #:iunknown-release #:iunknown-add-ref #:iunknown-query-interface
   #:idispatch-get-ids-of-names #:idispatch-invoke
   #:+iid-idispatch+ #:+iid-iunknown+
   ;; dispatch flags
   #:+dispatch-method+ #:+dispatch-property-get+ #:+dispatch-property-put+
   #:+dispid-property-put+
   ;; variants
   #:variant #:variant-value #:brecord #:variant-init #:variant-clear
   #:variant-change-type
   #:+vt-empty+ #:+vt-null+ #:+vt-i2+ #:+vt-i4+ #:+vt-r4+ #:+vt-r8+ #:+vt-cy+
   #:+vt-date+ #:+vt-bstr+ #:+vt-dispatch+ #:+vt-error+ #:+vt-bool+ #:+vt-variant+
   #:+vt-unknown+ #:+vt-i1+ #:+vt-ui1+ #:+vt-ui2+ #:+vt-ui4+ #:+vt-i8+ #:+vt-ui8+
   #:+vt-int+ #:+vt-uint+ #:+vt-decimal+ #:+vt-byref+
   #:decimal
   ;; strings
   #:sys-alloc-string #:sys-free-string #:sys-string-len
   ;; call plumbing
   #:dispparams #:excepinfo
   ;; type libraries -- the server's own description of itself
   #:typedesc #:paramdesc #:idldesc #:elemdesc #:vardesc #:typeattr #:tlibattr
   #:+tkind-enum+ #:+tkind-record+ #:+tkind-module+ #:+tkind-interface+
   #:+tkind-dispatch+ #:+tkind-coclass+ #:+tkind-alias+ #:+tkind-union+
   #:+var-perinstance+ #:+var-static+ #:+var-const+ #:+var-dispatch+
   #:+memberid-nil+ #:+typelib-index-self+
   #:+varflag-fhidden+ #:+varflag-frestricted+
   #:load-type-lib-ex #:+regkind-none+
   #:itypelib-get-type-info-count #:itypelib-get-type-info
   #:itypelib-get-type-info-type #:itypelib-get-lib-attr
   #:itypelib-get-documentation #:itypelib-release-tlib-attr
   #:itypeinfo-get-type-attr #:itypeinfo-get-var-desc
   #:itypeinfo-get-documentation #:itypeinfo-get-containing-type-lib
   #:itypeinfo-release-type-attr #:itypeinfo-release-var-desc
   #:idispatch-get-type-info))

(cl:defpackage #:aion/windows/com
  (:use #:common-lisp)
  (:local-nicknames (#:ffi #:aion/windows/com/ffi)
                    (#:reg #:aion/windows/registry)
                    (#:w #:aion/windows)
                    (#:wffi #:aion/windows/ffi))
  (:documentation "OLE/COM automation for Ouranos.")
  (:export
   ;; apartment
   #:start-apartment #:stop-apartment #:apartment-running-p #:in-apartment
   #:call-in-apartment #:apartment-error
   ;; objects. COM-OBJECT-POINTER and WRAP-INTERFACE are the two halves of the extension
   ;; surface: get the interface out to call something this binding does not wrap yet, and
   ;; put one back under management once you have it.
   #:com-object #:com-object-p #:com-object-pointer #:wrap-interface
   #:release #:with-com-object
   #:create-object #:object-from-prog-id #:class-available-p
   ;; calling
   #:invoke #:invoke-method #:get-property #:set-property
   #:by-ref #:by-ref-p #:by-ref-value
   ;; variants
   #:lisp-to-variant #:variant-to-lisp #:with-variant
   #:ole-date-to-universal-time #:universal-time-to-ole-date
   ;; type libraries -- the server's own description, read and emitted (pre-publication issue 181)
   #:typelib-constants #:typelib-information #:typelib-contents
   #:define-typelib-constants #:expand-typelib-constants
   #:check-typelib-version
   #:com-name-to-lisp-name #:constant-symbol-name
   ;; conditions
   #:com-error #:dispatch-error #:dispatch-error-source
   #:dispatch-error-description #:unknown-member
   #:typelib-error #:no-type-information
   #:typelib-name-collision #:typelib-name-collision-clashes
   #:typelib-version-mismatch))
