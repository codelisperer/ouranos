;;;; packages.lisp --- aion/darwin: the macOS-specific API surface, bound by us (ADR-0004).
;;;;
;;;; The macOS counterpart of aion/windows. It binds what macOS functionality in hades needs
;;;; from the frameworks every Mac ships: CoreFoundation's strings, data and dictionaries, and
;;;; Security.framework's keychain item calls, with OSStatus decoded into a condition. The
;;;; functionality itself (a credential store, for example) belongs to hades (hades ADR-0001).
;;;;
;;;; TWO PACKAGES, the same split aion/windows uses:
;;;;
;;;;   AION/DARWIN/FFI  the raw layer -- defcfun and the frameworks. Apple's spellings survive
;;;;                    here (CFStringCreateWithBytes, SecItemAdd) so a reader can look them up.
;;;;   AION/DARWIN      the Lisp surface -- owned CF objects, WITH-CF, OSStatus as a condition.
;;;;
;;;; macOS-only. It cannot load elsewhere; scripts/platform-packages.lisp lists it as required
;;;; on macOS, so the gate loads and tests it there and reports it absent, correctly, on other
;;;; hosts.

(cl:defpackage #:aion/darwin/ffi
  (:use #:common-lisp)
  (:documentation "Raw macOS framework bindings: CoreFoundation and Security. Apple spellings kept.")
  (:export
   #:+cf-string-encoding-utf8+ #:+err-sec-success+ #:+err-sec-item-not-found+
   #:+err-sec-duplicate-item+
   #:cf-release #:cf-retain #:cf-get-retain-count
   #:cf-string-create-with-bytes #:cf-string-get-length #:cf-string-get-maximum-size-for-encoding
   #:cf-string-get-c-string
   #:cf-data-create #:cf-data-get-length #:cf-data-get-byte-ptr
   #:cf-dictionary-create #:cf-dictionary-get-count #:cf-dictionary-get-value
   #:sec-item-add #:sec-item-update #:sec-item-copy-matching #:sec-item-delete
   #:sec-copy-error-message-string))

(cl:defpackage #:aion/darwin
  (:use #:common-lisp)
  (:local-nicknames (#:ffi #:aion/darwin/ffi))
  (:documentation "The macOS API surface: owned CoreFoundation objects and OSStatus as a condition (ADR-0004).")
  (:export
   ;; conditions
   #:darwin-error #:darwin-error-code #:darwin-error-message #:darwin-error-operation
   #:osstatus-error #:check-osstatus #:osstatus-message
   ;; ownership
   #:with-cf #:cf-release #:cf-retain
   ;; conversions
   #:make-cf-string #:cf-string-to-lisp #:make-cf-data #:cf-data-octets #:make-cf-dictionary
   #:cf-constant))
