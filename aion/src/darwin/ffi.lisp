;;;; ffi.lisp --- CoreFoundation and Security.framework, raw (ADR-0004).
;;;;
;;;; Both frameworks ship with macOS, so they are opened by their absolute paths and nothing is
;;;; built or carried. A dumped image reopens them from the same paths on any Mac, since
;;;; /System/Library/Frameworks is where the OS keeps them.
;;;;
;;;; Types: CFIndex is a signed long, CFStringEncoding a uint32, Boolean a uint8, OSStatus an
;;;; int32. A CFTypeRef is a pointer; NULL is failure for every Create function bound here.
;;;; kCFAllocatorDefault is NULL, which is what every allocator argument below is given.

(in-package #:aion/darwin/ffi)

(cffi:define-foreign-library core-foundation
  (:darwin "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"))
(cffi:define-foreign-library security
  (:darwin "/System/Library/Frameworks/Security.framework/Security"))

(cffi:use-foreign-library core-foundation)
(cffi:use-foreign-library security)

(defconstant +cf-string-encoding-utf8+ #x08000100 "kCFStringEncodingUTF8.")
(defconstant +err-sec-success+ 0 "errSecSuccess.")
(defconstant +err-sec-item-not-found+ -25300 "errSecItemNotFound.")
(defconstant +err-sec-duplicate-item+ -25299 "errSecDuplicateItem.")

;;; --- CoreFoundation: ownership ------------------------------------------------------------

(cffi:defcfun ("CFRelease" cf-release) :void (cf :pointer))
(cffi:defcfun ("CFRetain" cf-retain) :pointer (cf :pointer))
(cffi:defcfun ("CFGetRetainCount" cf-get-retain-count) :long (cf :pointer))

;;; --- CoreFoundation: strings ----------------------------------------------------------------

(cffi:defcfun ("CFStringCreateWithBytes" cf-string-create-with-bytes) :pointer
  (alloc :pointer) (bytes :pointer) (num-bytes :long) (encoding :uint32) (is-external-representation :uint8))
(cffi:defcfun ("CFStringGetLength" cf-string-get-length) :long (string :pointer))
(cffi:defcfun ("CFStringGetMaximumSizeForEncoding" cf-string-get-maximum-size-for-encoding) :long
  (length :long) (encoding :uint32))
(cffi:defcfun ("CFStringGetCString" cf-string-get-c-string) :uint8
  (string :pointer) (buffer :pointer) (buffer-size :long) (encoding :uint32))

;;; --- CoreFoundation: data -------------------------------------------------------------------

(cffi:defcfun ("CFDataCreate" cf-data-create) :pointer (alloc :pointer) (bytes :pointer) (length :long))
(cffi:defcfun ("CFDataGetLength" cf-data-get-length) :long (data :pointer))
(cffi:defcfun ("CFDataGetBytePtr" cf-data-get-byte-ptr) :pointer (data :pointer))

;;; --- CoreFoundation: dictionaries -----------------------------------------------------------

(cffi:defcfun ("CFDictionaryCreate" cf-dictionary-create) :pointer
  (alloc :pointer) (keys :pointer) (values :pointer) (num-values :long)
  (key-callbacks :pointer) (value-callbacks :pointer))
(cffi:defcfun ("CFDictionaryGetCount" cf-dictionary-get-count) :long (dict :pointer))
(cffi:defcfun ("CFDictionaryGetValue" cf-dictionary-get-value) :pointer (dict :pointer) (key :pointer))

;;; --- Security.framework: keychain items -----------------------------------------------------
;;;
;;; Bound here because they are OS bindings (hades ADR-0001); called only by hades. RESULT is an
;;; out-parameter: a CFTypeRef the caller owns and releases, or NULL when not asked for.

(cffi:defcfun ("SecItemAdd" sec-item-add) :int32 (attributes :pointer) (result :pointer))
(cffi:defcfun ("SecItemUpdate" sec-item-update) :int32 (query :pointer) (attributes-to-update :pointer))
(cffi:defcfun ("SecItemCopyMatching" sec-item-copy-matching) :int32 (query :pointer) (result :pointer))
(cffi:defcfun ("SecItemDelete" sec-item-delete) :int32 (query :pointer))
(cffi:defcfun ("SecCopyErrorMessageString" sec-copy-error-message-string) :pointer
  (status :int32) (reserved :pointer))
