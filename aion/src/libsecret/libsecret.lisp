;;;; libsecret.lisp --- the Lisp surface over libsecret (#357).
;;;;
;;;; Everything here allocates and frees inside one dynamic extent: a schema, an attribute table
;;;; and the foreign strings in it exist for the length of a WITH- form and no longer. Nothing
;;;; foreign is kept between calls, so nothing goes stale in a saved image.

(in-package #:aion/libsecret)

;;; --- loading and the lock ------------------------------------------------------------------

(defun load-libsecret ()
  "Load libsecret. Returns T, or NIL and the reason it could not be loaded."
  (ffi:load-libsecret))

(defvar *lock* (sb-thread:make-mutex :name "aion/libsecret")
  "Held around every call into libsecret. Its synchronous calls each run a private GLib main
loop, and one caller at a time keeps two of them from waiting on the same D-Bus reply.")

(defmacro with-libsecret-lock (() &body body)
  "Run BODY holding the one lock every libsecret call is made under. It may be entered again by
the thread holding it."
  `(sb-thread:with-recursive-lock (*lock*) ,@body))

;;; --- GError as a condition -----------------------------------------------------------------

(define-condition libsecret-error (error)
  ((domain :initarg :domain :reader libsecret-error-domain)
   (code :initarg :code :reader libsecret-error-code)
   (message :initarg :message :reader libsecret-error-message)
   (operation :initarg :operation :reader libsecret-error-operation))
  (:report (lambda (c s)
             (format s "~A failed: ~A (~A ~D)" (libsecret-error-operation c)
                     (libsecret-error-message c) (libsecret-error-domain c)
                     (libsecret-error-code c))))
  (:documentation "A libsecret or GIO call set its GError. DOMAIN is the error domain's name, such
as \"secret-error\" or \"g-dbus-error-quark\"; CODE is the code within it; MESSAGE is GLib's
text, which describes the failure and never carries a stored value."))

(defun locked-error-p (condition)
  "True when CONDITION says the item or the collection was locked."
  (and (equal "secret-error" (libsecret-error-domain condition))
       (= ffi:+secret-error-is-locked+ (libsecret-error-code condition))))

(defun service-missing-error-p (condition)
  "True when CONDITION says nothing on the bus provides the name asked for: D-Bus's
ServiceUnknown or NameHasNoOwner."
  (and (equal "g-dbus-error-quark" (libsecret-error-domain condition))
       (member (libsecret-error-code condition)
               (list ffi:+g-dbus-error-service-unknown+ ffi:+g-dbus-error-name-has-no-owner+))
       t))

(defun %c-string-lossy (pointer)
  "The NUL-terminated C string at POINTER as a Lisp string, with each byte sequence that is not
UTF-8 replaced by U+FFFD rather than signalled."
  (if (cffi:null-pointer-p pointer)
      ""
      (let* ((n (loop for i from 0
                      until (zerop (cffi:mem-aref pointer :uint8 i))
                      finally (return i)))
             (octets (make-array n :element-type '(unsigned-byte 8))))
        (dotimes (i n) (setf (aref octets i) (cffi:mem-aref pointer :uint8 i)))
        (sb-ext:octets-to-string octets
                                 :external-format '(:utf-8 :replacement #\Replacement_Character)))))

(defun %signal-gerror (gerror operation)
  "Read the GError at GERROR, free it, and signal LIBSECRET-ERROR. The GError is freed even when
reading it fails."
  (let (domain code message)
    (unwind-protect
         (setf domain (ffi:g-quark-to-string (cffi:mem-ref gerror :uint32 0))
               code (cffi:mem-ref gerror :int 4)
               message (%c-string-lossy (cffi:mem-ref gerror :pointer 8)))
      (ffi:g-error-free gerror))
    (error 'libsecret-error :domain domain :code code :message message :operation operation)))

(defmacro with-gerror ((var operation) &body body)
  "Bind VAR to a GError** for BODY's call. When BODY returns with the GError set, free it and
signal LIBSECRET-ERROR naming OPERATION; otherwise return what BODY returned."
  (let ((result (gensym "RESULT")))
    `(cffi:with-foreign-object (,var :pointer)
       (setf (cffi:mem-ref ,var :pointer) (cffi:null-pointer))
       (let ((,result (progn ,@body)))
         (unless (cffi:null-pointer-p (cffi:mem-ref ,var :pointer))
           (%signal-gerror (cffi:mem-ref ,var :pointer) ,operation))
         ,result))))

;;; --- the session bus and the service -------------------------------------------------------
;;;
;;; GIO and libsecret each keep one shared connection and one shared service object per process
;;; once the first call succeeds, so after that these calls cost a reference count, not a round
;;; trip. A failure is not kept, so a bus or a service that starts later is found.

(defun check-session-bus ()
  "Connect to the D-Bus session bus. Returns T, or signals LIBSECRET-ERROR when there is none, as
when DBUS_SESSION_BUS_ADDRESS names nothing or is unset outside a desktop session."
  (let ((bus (with-gerror (err "connecting to the D-Bus session bus")
               (ffi:g-bus-get-sync ffi:+g-bus-type-session+ (cffi:null-pointer) err))))
    (unless (cffi:null-pointer-p bus) (ffi:g-object-unref bus))
    t))

(defun check-secret-service ()
  "Reach the Secret Service and open a session with it. Returns T, or signals LIBSECRET-ERROR
when no program on the session bus provides org.freedesktop.secrets and none can be started.
This call unlocks nothing, so it does not prompt."
  (let ((service (with-gerror (err "opening a session with the Secret Service")
                   (ffi:secret-service-get-sync ffi:+secret-service-open-session+
                                                (cffi:null-pointer) err))))
    (unless (cffi:null-pointer-p service) (ffi:g-object-unref service))
    t))

(defun default-collection-locked-p ()
  "T when the Secret Service's default collection exists and is locked, NIL when it is unlocked
or there is none. Reads the collection's Locked property from a new proxy, so the answer is
current; it unlocks nothing, so it does not prompt. Signals LIBSECRET-ERROR when the service
cannot be reached."
  (let ((service (with-gerror (err "reaching the Secret Service")
                   (ffi:secret-service-get-sync ffi:+secret-service-none+
                                                (cffi:null-pointer) err))))
    (unwind-protect
         (let ((collection (with-gerror (err "finding the default collection")
                             (ffi:secret-collection-for-alias-sync
                              service "default" ffi:+secret-collection-none+
                              (cffi:null-pointer) err))))
           (unless (cffi:null-pointer-p collection)
             (unwind-protect (/= 0 (ffi:secret-collection-get-locked collection))
               (ffi:g-object-unref collection))))
      (unless (cffi:null-pointer-p service) (ffi:g-object-unref service)))))

;;; --- schemas and attribute tables ----------------------------------------------------------

(defun %free-all (pointers)
  (dolist (p pointers) (cffi:foreign-free p)))

(defmacro with-schema ((var name attribute-names) &body body)
  "Bind VAR to a SecretSchema called NAME whose attributes are the strings ATTRIBUTE-NAMES, each
of type string, for BODY. Lookups through it match only items stored through a schema of the
same NAME. The schema and its strings are freed when BODY exits."
  `(call-with-schema ,name ,attribute-names (lambda (,var) ,@body)))

(defun call-with-schema (name attribute-names fn)
  (assert (< (length attribute-names) ffi:+secret-schema-max-attributes+))
  (let* ((size (cffi:foreign-type-size '(:struct ffi:secret-schema)))
         (schema (cffi:foreign-alloc :uint8 :count size :initial-element 0))
         (strings '()))
    (unwind-protect
         (let ((attributes (cffi:foreign-slot-pointer schema '(:struct ffi:secret-schema)
                                                      'ffi::attributes))
               (entry-size (cffi:foreign-type-size '(:struct ffi:secret-schema-attribute))))
           (push (cffi:foreign-string-alloc name :encoding :utf-8) strings)
           (setf (cffi:foreign-slot-value schema '(:struct ffi:secret-schema) 'ffi::name)
                 (first strings)
                 (cffi:foreign-slot-value schema '(:struct ffi:secret-schema) 'ffi::flags)
                 ffi:+secret-schema-none+)
           (loop for attribute in attribute-names
                 for i from 0
                 for entry = (cffi:inc-pointer attributes (* i entry-size))
                 do (push (cffi:foreign-string-alloc attribute :encoding :utf-8) strings)
                    (setf (cffi:foreign-slot-value entry '(:struct ffi:secret-schema-attribute)
                                                   'ffi::name)
                          (first strings)
                          (cffi:foreign-slot-value entry '(:struct ffi:secret-schema-attribute)
                                                   'ffi::type)
                          ffi:+secret-schema-attribute-string+))
           (funcall fn schema))
      (%free-all strings)
      (cffi:foreign-free schema))))

(defmacro with-attributes ((var alist) &body body)
  "Bind VAR to a GHashTable from string to string holding ALIST, a list of (NAME . VALUE) string
pairs, for BODY. The table and its strings are freed when BODY exits."
  `(call-with-attributes ,alist (lambda (,var) ,@body)))

(defun call-with-attributes (alist fn)
  (let ((table (ffi:g-hash-table-new (ffi:symbol-pointer "g_str_hash")
                                     (ffi:symbol-pointer "g_str_equal")))
        (strings '()))
    (unwind-protect
         (progn
           (loop for (name . value) in alist
                 for key = (cffi:foreign-string-alloc name :encoding :utf-8)
                 for val = (progn (push key strings)
                                  (cffi:foreign-string-alloc value :encoding :utf-8))
                 do (push val strings)
                    (ffi:g-hash-table-insert table key val))
           (funcall fn table))
      ;; The table was made without free functions, so it owns none of the strings.
      (ffi:g-hash-table-unref table)
      (%free-all strings))))

;;; --- secret values -------------------------------------------------------------------------

(defun make-secret-value (octets)
  "A new SecretValue holding OCTETS, a vector of (unsigned-byte 8), with content type text/plain.
The caller owns it and releases it with SECRET-VALUE-UNREF. OCTETS pass through a foreign buffer
that is zeroed before it is freed; libsecret keeps its own copy, which it clears when released."
  (let* ((n (length octets))
         (buffer (cffi:foreign-alloc :uint8 :count (max n 1))))
    (unwind-protect
         (progn
           (dotimes (i n) (setf (cffi:mem-aref buffer :uint8 i) (aref octets i)))
           (ffi:secret-value-new buffer n "text/plain"))
      (dotimes (i (max n 1)) (setf (cffi:mem-aref buffer :uint8 i) 0))
      (cffi:foreign-free buffer))))

(defun secret-value-octets (value)
  "The bytes of the SecretValue VALUE, as a fresh (unsigned-byte 8) vector the caller should zero
when done. VALUE itself is not released."
  (cffi:with-foreign-object (length :unsigned-long)
    (let* ((bytes (ffi:secret-value-get value length))
           (n (cffi:mem-ref length :unsigned-long))
           (octets (make-array n :element-type '(unsigned-byte 8))))
      (dotimes (i n octets)
        (setf (aref octets i) (cffi:mem-aref bytes :uint8 i))))))
