;;;; ffi.lisp --- libsecret and the GLib calls it needs, raw (#357).
;;;;
;;;; libsecret is a shared library a Linux distribution installs as libsecret-1.so.0, usually
;;;; already present on a desktop because GNOME and KDE applications use it. It is not built or
;;;; carried here. Loading it also loads its own dependencies, libglib-2.0, libgobject-2.0 and
;;;; libgio-2.0, so the GLib functions below come from those.
;;;;
;;;; THE LIBRARY IS LOADED ON FIRST USE. Every function below looks its C symbol up when it is
;;;; called, through CFFI:FOREIGN-SYMBOL-POINTER, rather than being linked by DEFCFUN when this
;;;; file loads. That way this system loads on a machine without libsecret, and a DEFCFUN of a
;;;; symbol no loaded library defines does not make SBCL warn about an undefined alien. It also
;;;; means no address is kept across a saved image, where the library may load somewhere else.
;;;;
;;;; Types: gboolean is a C int, gsize and gssize are the width of a pointer, GQuark is a uint32.
;;;; A GError is { GQuark domain; gint code; gchar *message; }.

(in-package #:aion/libsecret/ffi)

(cffi:define-foreign-library libsecret
  (:linux (:or "libsecret-1.so.0" "libsecret-1.so")))

(defun load-libsecret ()
  "Load libsecret if it is not loaded. Returns T, or NIL and a string saying why it could not be
loaded. A failure is not remembered, so a library installed later is found by the next call."
  (if (cffi:foreign-library-loaded-p 'libsecret)
      t
      (handler-case (progn (cffi:load-foreign-library 'libsecret) t)
        (cffi:load-foreign-library-error (e)
          (values nil (princ-to-string e))))))

(defun symbol-pointer (name)
  "The address of the C function NAME, from the libraries loaded so far. Signals an error when no
loaded library defines it, which before LOAD-LIBSECRET is every name here."
  (or (cffi:foreign-symbol-pointer name)
      (error "aion/libsecret: the C function ~A is not loaded; LOAD-LIBSECRET must succeed first"
             name)))

(defmacro define-call (lisp-name c-name return-type &rest arguments)
  "Define LISP-NAME to call the C function C-NAME through the pointer SYMBOL-POINTER finds.
Each of ARGUMENTS is (NAME CFFI-TYPE)."
  `(defun ,lisp-name ,(mapcar #'first arguments)
     ,(format nil "~A, looked up when called." c-name)
     (cffi:foreign-funcall-pointer (symbol-pointer ,c-name) ()
                                   ,@(loop for (name type) in arguments append (list type name))
                                   ,return-type)))

;;; --- constants -----------------------------------------------------------------------------

(defconstant +secret-schema-none+ 0 "SECRET_SCHEMA_NONE.")
(defconstant +secret-schema-attribute-string+ 0 "SECRET_SCHEMA_ATTRIBUTE_STRING.")
(defconstant +secret-schema-max-attributes+ 32
  "The length of SecretSchema's attributes array. The list ends at the first entry whose name is
NULL, so a schema has at most 31 attributes.")
(defconstant +secret-service-none+ 0 "SECRET_SERVICE_NONE.")
(defconstant +secret-service-open-session+ 2 "SECRET_SERVICE_OPEN_SESSION (1 << 1).")
(defconstant +secret-collection-none+ 0 "SECRET_COLLECTION_NONE.")
(defconstant +g-bus-type-session+ 2 "G_BUS_TYPE_SESSION.")
(defconstant +secret-error-is-locked+ 2
  "SECRET_ERROR_IS_LOCKED, in the domain \"secret-error\": the item or collection is locked.")
(defconstant +secret-error-no-such-object+ 3 "SECRET_ERROR_NO_SUCH_OBJECT.")
(defconstant +g-dbus-error-service-unknown+ 2
  "G_DBUS_ERROR_SERVICE_UNKNOWN, in the domain \"g-dbus-error-quark\": nothing owns the name and
no service file can start one.")
(defconstant +g-dbus-error-name-has-no-owner+ 3 "G_DBUS_ERROR_NAME_HAS_NO_OWNER.")

;;; --- SecretSchema --------------------------------------------------------------------------
;;;
;;; The layout from libsecret's secret-schema.h. The reserved fields are private, but they are
;;; part of the struct's size, and libsecret copies the whole struct.

(cffi:defcstruct secret-schema-attribute
  (name :pointer)
  (type :int))

(cffi:defcstruct secret-schema
  (name :pointer)
  (flags :int)
  (attributes (:struct secret-schema-attribute) :count 32)
  (reserved :int)
  (reserved1 :pointer) (reserved2 :pointer) (reserved3 :pointer) (reserved4 :pointer)
  (reserved5 :pointer) (reserved6 :pointer) (reserved7 :pointer))

;;; --- libsecret: the password calls ---------------------------------------------------------
;;;
;;; The non-variadic forms, which take the attributes as a GHashTable of string to string. The
;;; _binary_ forms take and return a SecretValue with an explicit length, so a value holding a
;;; NUL byte is stored whole instead of being cut at it. COLLECTION "default" is
;;; SECRET_COLLECTION_DEFAULT. ERROR is a GError** the caller owns.

(define-call secret-password-storev-binary-sync "secret_password_storev_binary_sync" :int
  (schema :pointer) (attributes :pointer) (collection :string) (label :string)
  (value :pointer) (cancellable :pointer) (error :pointer))

(define-call secret-password-lookupv-binary-sync "secret_password_lookupv_binary_sync" :pointer
  (schema :pointer) (attributes :pointer) (cancellable :pointer) (error :pointer))

(define-call secret-password-clearv-sync "secret_password_clearv_sync" :int
  (schema :pointer) (attributes :pointer) (cancellable :pointer) (error :pointer))

;;; --- libsecret: SecretValue ----------------------------------------------------------------
;;;
;;; secret_value_new copies SECRET into memory libsecret allocates for secrets, and
;;; secret_value_unref clears that memory before freeing it.

(define-call secret-value-new "secret_value_new" :pointer
  (secret :pointer) (length :long) (content-type :string))
(define-call secret-value-get "secret_value_get" :pointer (value :pointer) (length :pointer))
(define-call secret-value-unref "secret_value_unref" :void (value :pointer))

;;; --- libsecret and GIO: reaching the service -----------------------------------------------

(define-call secret-service-get-sync "secret_service_get_sync" :pointer
  (flags :int) (cancellable :pointer) (error :pointer))
;;; A SecretCollection made by secret_collection_for_alias_sync on a service that has not loaded
;;; its collections is a new D-Bus proxy, which reads the collection's properties when it is
;;; made. Its Locked property is therefore current at that moment, not a cached value.
(define-call secret-collection-for-alias-sync "secret_collection_for_alias_sync" :pointer
  (service :pointer) (alias :string) (flags :int) (cancellable :pointer) (error :pointer))
(define-call secret-collection-get-locked "secret_collection_get_locked" :int (collection :pointer))
(define-call secret-service-lock-dbus-paths-sync "secret_service_lock_dbus_paths_sync" :int
  (service :pointer) (paths :pointer) (cancellable :pointer) (locked :pointer) (error :pointer))

(define-call g-bus-get-sync "g_bus_get_sync" :pointer
  (bus-type :int) (cancellable :pointer) (error :pointer))
(define-call g-object-unref "g_object_unref" :void (object :pointer))

;;; --- GLib: hash tables and errors ----------------------------------------------------------

(define-call g-hash-table-new "g_hash_table_new" :pointer
  (hash-func :pointer) (equal-func :pointer))
(define-call g-hash-table-insert "g_hash_table_insert" :int
  (table :pointer) (key :pointer) (value :pointer))
(define-call g-hash-table-unref "g_hash_table_unref" :void (table :pointer))
(define-call g-error-free "g_error_free" :void (error :pointer))
(define-call g-quark-to-string "g_quark_to_string" :string (quark :uint32))
