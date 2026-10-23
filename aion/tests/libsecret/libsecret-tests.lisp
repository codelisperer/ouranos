;;;; libsecret-tests.lisp --- aion/libsecret without the Secret Service (#357).
;;;;
;;;; Nothing here talks to D-Bus. GIO keeps the first session-bus connection a process makes, so a
;;;; test of a missing bus or a missing service has to run in a fresh process; those are in
;;;; hades/credentials's suite, which owns the reasons they produce.

(defpackage #:aion/libsecret/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:ls #:aion/libsecret) (#:ffi #:aion/libsecret/ffi))
  (:export #:run-tests))

(in-package #:aion/libsecret/tests)

(def-suite all :description "aion/libsecret.")
(in-suite all)

(defun run-tests () (fiveam:run! 'all))

(defmacro %call (name return-type &rest types-and-arguments)
  "Call the GLib function NAME, which this suite uses to look at what aion/libsecret built."
  `(cffi:foreign-funcall-pointer (ffi:symbol-pointer ,name) () ,@types-and-arguments ,return-type))

(test libsecret-loads-on-this-host
  (multiple-value-bind (loaded reason) (ls:load-libsecret)
    (is (eq t loaded) "libsecret-1.so.0 must be installed where this suite runs: ~A" reason)))

(test the-schema-has-libsecret-s-layout
  "SecretSchema on x86-64 and arm64: the name, the flags, 32 attributes of a pointer and an int
each, then a reserved int and seven reserved pointers. libsecret copies the whole struct, so a
wrong size reads past the end of what was allocated."
  (is (= 16 (cffi:foreign-type-size '(:struct ffi:secret-schema-attribute))))
  (is (= 16 (cffi:foreign-slot-offset '(:struct ffi:secret-schema) 'ffi::attributes)))
  (is (= 528 (cffi:foreign-slot-offset '(:struct ffi:secret-schema) 'ffi::reserved)))
  (is (= 592 (cffi:foreign-type-size '(:struct ffi:secret-schema)))))

(test a-schema-holds-its-name-and-string-attributes-and-ends-at-a-null-name
  (ls:with-schema (schema "org.example.Test" '("service" "account"))
    (flet ((attribute (i slot)
             (cffi:foreign-slot-value
              (cffi:inc-pointer (cffi:foreign-slot-pointer schema '(:struct ffi:secret-schema)
                                                           'ffi::attributes)
                                (* i 16))
              '(:struct ffi:secret-schema-attribute) slot)))
      (is (string= "org.example.Test"
                   (cffi:foreign-string-to-lisp
                    (cffi:foreign-slot-value schema '(:struct ffi:secret-schema) 'ffi::name))))
      (is (= ffi:+secret-schema-none+
             (cffi:foreign-slot-value schema '(:struct ffi:secret-schema) 'ffi::flags)))
      (is (string= "service" (cffi:foreign-string-to-lisp (attribute 0 'ffi::name))))
      (is (string= "account" (cffi:foreign-string-to-lisp (attribute 1 'ffi::name))))
      (is (= ffi:+secret-schema-attribute-string+ (attribute 1 'ffi::type)))
      (is (cffi:null-pointer-p (attribute 2 'ffi::name)) "the list must end after two"))))

(test an-attribute-table-maps-each-name-to-its-value
  (ls:load-libsecret)
  (let ((pairs (list (cons "service" (concatenate 'string "app/" (string (code-char #x6587))))
                     (cons "account" "user"))))
    (ls:with-attributes (table pairs)
      (is (= 2 (%call "g_hash_table_size" :uint :pointer table)))
      (dolist (pair pairs)
        (cffi:with-foreign-string (key (car pair) :encoding :utf-8)
          (let ((value (%call "g_hash_table_lookup" :pointer :pointer table :pointer key)))
            (is (not (cffi:null-pointer-p value)) "~A is missing" (car pair))
            (is (string= (cdr pair) (cffi:foreign-string-to-lisp value :encoding :utf-8)))))))))

(test a-secret-value-keeps-every-byte-including-nul
  "The _binary_ calls exist so a value is not cut at its first NUL byte, which the text calls do."
  (ls:load-libsecret)
  (dolist (bytes (list #(104 0 105 195 169) #() #(0)))
    (let* ((octets (coerce bytes '(vector (unsigned-byte 8))))
           (value (ls:make-secret-value octets)))
      (unwind-protect
           (is (equalp octets (ls:secret-value-octets value)) "~S came back different" bytes)
        (ffi:secret-value-unref value)))))

(test a-set-gerror-becomes-a-condition-and-is-freed
  (ls:load-libsecret)
  (let ((condition
          (handler-case
              (ls:with-gerror (err "storing")
                (setf (cffi:mem-ref err :pointer)
                      (%call "g_error_new_literal" :pointer
                             :uint32 (%call "g_quark_from_string" :uint32 :string "secret-error")
                             :int ffi:+secret-error-is-locked+
                             :string "Cannot create an item in a locked collection"))
                :returned)
            (ls:libsecret-error (e) e))))
    (is (typep condition 'ls:libsecret-error))
    (when (typep condition 'ls:libsecret-error)
      (is (equal "secret-error" (ls:libsecret-error-domain condition)))
      (is (= 2 (ls:libsecret-error-code condition)))
      (is (equal "storing" (ls:libsecret-error-operation condition)))
      (is (search "locked collection" (princ-to-string condition)))
      (is (ls:locked-error-p condition)))))

(test a-gerror-message-that-is-not-utf-8-is-read-with-replacement-characters
  "GLib's messages can quote names from the bus. One that is not UTF-8 must not stop the
condition from being made, and the GError must still be freed."
  (ls:load-libsecret)
  (let ((condition
          (handler-case
              (ls:with-gerror (err "reading")
                (cffi:with-foreign-object (bytes :uint8 6)
                  (loop for b in '(98 97 100 255 33 0) for i from 0
                        do (setf (cffi:mem-aref bytes :uint8 i) b))
                  (setf (cffi:mem-ref err :pointer)
                        (%call "g_error_new_literal" :pointer
                               :uint32 (%call "g_quark_from_string" :uint32 :string "secret-error")
                               :int 1 :pointer bytes)))
                :returned)
            (ls:libsecret-error (e) e))))
    (is (typep condition 'ls:libsecret-error) "got ~S" condition)
    (when (typep condition 'ls:libsecret-error)
      (is (string= (format nil "bad~C!" (code-char #xFFFD))
                   (ls:libsecret-error-message condition))))))

(test an-unset-gerror-returns-the-body-s-value
  (is (eq :returned (ls:with-gerror (err "nothing") :returned))))

(test the-lock-can-be-entered-again-by-its-holder
  (is (eq :inner (ls:with-libsecret-lock () (ls:with-libsecret-lock () :inner)))))
