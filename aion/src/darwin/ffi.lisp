;;;; ffi.lisp --- CoreFoundation and Security.framework, raw (ADR-0004).
;;;;
;;;; Both frameworks ship with macOS, so they are opened by their absolute paths and nothing is
;;;; built or carried.
;;;;
;;;; OPENED ON FIRST USE WITH RTLD_LOCAL, NOT THROUGH CFFI'S LIBRARY LOADER (#905).
;;;; Security.framework links the system's /usr/lib/libsqlite3.dylib. A global open lets
;;;; Security's dependencies shadow a library a desktop bundle carries (#899): SBCL looks a
;;;; foreign function up in every globally loaded image, in load order. When this file opened
;;;; both frameworks with CFFI's USE-FOREIGN-LIBRARY, at load time and globally, a dumped image
;;;; reopened Security at startup before the bundle's SQLite, and cl-sqlite's sqlite3_* calls
;;;; reached the system's copy: the sqlite-probe bundle reported SQLite 3.54.0 from /usr/lib
;;;; instead of the pinned 3.54.1 beside it. Two things here prevent that, measured on Darwin
;;;; 27.2:
;;;;
;;;;   - The frameworks are opened on first use, and the handles are dropped when an image is
;;;;     saved, so a dumped image never reopens them at startup, before the libraries the
;;;;     runtime reopens. The sqlite-probe bundle run with --https, which opens Security, then
;;;;     reported the bundle's copy even with the frameworks opened RTLD_GLOBAL.
;;;;   - They are opened RTLD_LOCAL, so Security and what it links are not searched by a global
;;;;     lookup at all, whichever is opened first. In a plain SBCL that opened Security and then
;;;;     the bundle's libsqlite3, sqlite3_libversion answered 3.54.0 with Security opened
;;;;     RTLD_GLOBAL and 3.54.1 with it opened RTLD_LOCAL.
;;;;
;;;; Every function and constant is therefore looked up in the frameworks' own handles with
;;;; dlsym (DEFFRAMEWORK, FRAMEWORK-SYMBOL), not in the global namespace.
;;;;
;;;; Types: CFIndex is a signed long, CFStringEncoding a uint32, Boolean a uint8, OSStatus an
;;;; int32. A CFTypeRef is a pointer; NULL is failure for every Create function bound here.
;;;; kCFAllocatorDefault is NULL, which is what every allocator argument below is given.

(in-package #:aion/darwin/ffi)

(defparameter *%framework-paths*
  '("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
    "/System/Library/Frameworks/Security.framework/Security")
  "The frameworks this package binds, searched in this order for a name.")

(defconstant +rtld-lazy+ 1 "RTLD_LAZY, from dlfcn.h.")
(defconstant +rtld-local+ 4 "RTLD_LOCAL, from dlfcn.h on macOS.")

(defvar *%handles* nil
  "The dlopen handles of +FRAMEWORKS+, in the same order, or NIL before the first use in this
image. Cleared by a save hook, because a handle does not survive a dumped image.")

(defvar *%handles-lock* (sb-thread:make-mutex :name "aion/darwin framework handles"))

(cffi:defcfun ("dlopen" %dlopen) :pointer (path :string) (mode :int))
(cffi:defcfun ("dlsym" %dlsym) :pointer (handle :pointer) (name :string))
(cffi:defcfun ("dlerror" %dlerror) :string)

(defun %handles ()
  (or *%handles*
      (sb-thread:with-mutex (*%handles-lock*)
        (or *%handles*
            (setf *%handles*
                  (mapcar (lambda (path)
                            ;; RTLD_LOCAL: a global open lets Security's dependencies shadow a
                            ;; library a bundle carries (#899, #905; see the top of this file).
                            (let ((handle (%dlopen path (logior +rtld-lazy+ +rtld-local+))))
                              (when (cffi:null-pointer-p handle)
                                (error "aion/darwin: dlopen ~A failed: ~A" path (%dlerror)))
                              handle))
                          *%framework-paths*))))))

(pushnew (lambda () (setf *%handles* nil)) sb-ext:*save-hooks*)

(defun framework-symbol (name)
  "The address of NAME, a function or constant that CoreFoundation or Security exports, or NIL
when neither does. The frameworks are opened with RTLD_LOCAL on the first call (see above)."
  (loop for handle in (%handles)
        for address = (%dlsym handle name)
        unless (cffi:null-pointer-p address) return address))

(defun %framework-function (name)
  (or (framework-symbol name)
      (error "aion/darwin: neither CoreFoundation nor Security exports ~A" name)))

(defmacro defframework ((c-name lisp-name) return-type &body arguments)
  "Like CFFI:DEFCFUN, but the function is looked up in the frameworks' own handles at each call,
not in the global namespace."
  `(defun ,lisp-name ,(mapcar #'first arguments)
     (cffi:foreign-funcall-pointer (%framework-function ,c-name) ()
                                   ,@(loop for (name type) in arguments append (list type name))
                                   ,return-type)))

(defconstant +cf-string-encoding-utf8+ #x08000100 "kCFStringEncodingUTF8.")
(defconstant +err-sec-success+ 0 "errSecSuccess.")
(defconstant +err-sec-item-not-found+ -25300 "errSecItemNotFound.")
(defconstant +err-sec-duplicate-item+ -25299 "errSecDuplicateItem.")
(defconstant +err-sec-interaction-not-allowed+ -25308
  "errSecInteractionNotAllowed: the Keychain could only answer by asking the person something,
and the query said not to (kSecUseAuthenticationUIFail). A locked Keychain answers this to an
attributes-only read rather than showing an unlock dialog (#1035).")

;;; --- CoreFoundation: ownership ------------------------------------------------------------

(defframework ("CFRelease" cf-release) :void (cf :pointer))
(defframework ("CFRetain" cf-retain) :pointer (cf :pointer))
(defframework ("CFGetRetainCount" cf-get-retain-count) :long (cf :pointer))

;;; --- CoreFoundation: strings ----------------------------------------------------------------

(defframework ("CFStringCreateWithBytes" cf-string-create-with-bytes) :pointer
  (alloc :pointer) (bytes :pointer) (num-bytes :long) (encoding :uint32) (is-external-representation :uint8))
(defframework ("CFStringGetLength" cf-string-get-length) :long (string :pointer))
(defframework ("CFStringGetMaximumSizeForEncoding" cf-string-get-maximum-size-for-encoding) :long
  (length :long) (encoding :uint32))
(defframework ("CFStringGetCString" cf-string-get-c-string) :uint8
  (string :pointer) (buffer :pointer) (buffer-size :long) (encoding :uint32))

;;; --- CoreFoundation: data -------------------------------------------------------------------

(defframework ("CFDataCreate" cf-data-create) :pointer (alloc :pointer) (bytes :pointer) (length :long))
(defframework ("CFDataGetLength" cf-data-get-length) :long (data :pointer))
(defframework ("CFDataGetBytePtr" cf-data-get-byte-ptr) :pointer (data :pointer))

;;; --- CoreFoundation: dictionaries -----------------------------------------------------------

(defframework ("CFDictionaryCreate" cf-dictionary-create) :pointer
  (alloc :pointer) (keys :pointer) (values :pointer) (num-values :long)
  (key-callbacks :pointer) (value-callbacks :pointer))
(defframework ("CFDictionaryGetCount" cf-dictionary-get-count) :long (dict :pointer))
(defframework ("CFDictionaryGetValue" cf-dictionary-get-value) :pointer (dict :pointer) (key :pointer))

;;; --- Security.framework: keychain items -----------------------------------------------------
;;;
;;; Bound here because they are OS bindings (hades ADR-0001); called only by hades. RESULT is an
;;; out-parameter: a CFTypeRef the caller owns and releases, or NULL when not asked for.

(defframework ("SecItemAdd" sec-item-add) :int32 (attributes :pointer) (result :pointer))
(defframework ("SecItemUpdate" sec-item-update) :int32 (query :pointer) (attributes-to-update :pointer))
(defframework ("SecItemCopyMatching" sec-item-copy-matching) :int32 (query :pointer) (result :pointer))

;;; CFArray, for a query that returns every match rather than one (kSecMatchLimitAll, #1035).
(defframework ("CFArrayGetCount" cf-array-get-count) :long (array :pointer))
(defframework ("CFArrayGetValueAtIndex" cf-array-get-value-at-index) :pointer
  (array :pointer) (index :long))
(defframework ("SecItemDelete" sec-item-delete) :int32 (query :pointer))
(defframework ("SecCopyErrorMessageString" sec-copy-error-message-string) :pointer
  (status :int32) (reserved :pointer))

;;; --- Security.framework: trust evaluation (#905) ----------------------------------------------
;;;
;;; What aion/http-client asks before it trusts a TLS server on macOS: a SecTrust built from the
;;; server's certificates with the SSL policy for the host name, evaluated by the system against
;;; its own trust settings. Signatures from the macOS SDK headers SecCertificate.h, SecPolicy.h
;;; and SecTrust.h. SecTrustEvaluateWithError returns a C bool and, on failure, a CFError the
;;; caller owns; its code is an OSStatus from SecBase.h.

(defframework ("SecCertificateCreateWithData" sec-certificate-create-with-data) :pointer
  (alloc :pointer) (data :pointer))
(defframework ("SecPolicyCreateSSL" sec-policy-create-ssl) :pointer
  (server :uint8) (hostname :pointer))
(defframework ("SecTrustCreateWithCertificates" sec-trust-create-with-certificates) :int32
  (certificates :pointer) (policies :pointer) (trust :pointer))
(defframework ("SecTrustEvaluateWithError" sec-trust-evaluate-with-error) :bool
  (trust :pointer) (error :pointer))
(defframework ("CFErrorGetCode" cf-error-get-code) :long (error :pointer))
(defframework ("CFArrayCreate" cf-array-create) :pointer
  (alloc :pointer) (values :pointer) (num-values :long) (callbacks :pointer))
