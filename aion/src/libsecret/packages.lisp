;;;; packages.lisp --- aion/libsecret: the Secret Service client library, bound by us (#357).
;;;;
;;;; The Linux counterpart of aion/darwin and aion/windows. It binds what hades/credentials needs
;;;; from libsecret, the client library for the freedesktop.org Secret Service API that GNOME
;;;; Keyring and KeePassXC provide over D-Bus: a schema, an attribute table, a secret value, the
;;;; store, lookup and clear calls, and GError as a condition. The credential store itself belongs
;;;; to hades (hades ADR-0001).
;;;;
;;;; TWO PACKAGES, the same split aion/darwin uses:
;;;;
;;;;   AION/LIBSECRET/FFI  the raw layer. libsecret's and GLib's spellings survive here
;;;;                       (secret_password_storev_binary_sync, g_hash_table_new) so a reader can
;;;;                       look them up.
;;;;   AION/LIBSECRET      the Lisp surface: loading the library, one lock around every call,
;;;;                       schemas and attribute tables that free themselves, GError as a
;;;;                       condition.
;;;;
;;;; libsecret is loaded on first use, not when this system loads, and is never built or carried
;;;; by this tree. A Linux machine without it loads this system, and LOAD-LIBSECRET then answers
;;;; NIL with the reason.

(cl:defpackage #:aion/libsecret/ffi
  (:use #:common-lisp)
  (:documentation "Raw libsecret and GLib bindings, called through pointers looked up after the library loads. C spellings kept in the docstrings.")
  (:export
   #:libsecret #:load-libsecret
   #:secret-schema #:secret-schema-attribute
   #:+secret-schema-none+ #:+secret-schema-attribute-string+ #:+secret-schema-max-attributes+
   #:+secret-service-open-session+ #:+g-bus-type-session+
   #:+secret-error-is-locked+ #:+secret-error-no-such-object+
   #:secret-password-storev-binary-sync #:secret-password-lookupv-binary-sync
   #:secret-password-clearv-sync
   #:secret-value-new #:secret-value-get #:secret-value-unref
   #:secret-service-get-sync
   #:g-bus-get-sync #:g-object-unref
   #:g-hash-table-new #:g-hash-table-insert #:g-hash-table-unref
   #:g-error-free #:g-quark-to-string
   #:symbol-pointer))

(cl:defpackage #:aion/libsecret
  (:use #:common-lisp)
  (:local-nicknames (#:ffi #:aion/libsecret/ffi))
  (:documentation "The Secret Service client surface: loading libsecret, one lock, schemas, attribute tables, secret values and GError as a condition (#357).")
  (:export
   ;; loading and the lock
   #:load-libsecret #:with-libsecret-lock
   ;; conditions
   #:libsecret-error #:libsecret-error-domain #:libsecret-error-code
   #:libsecret-error-message #:libsecret-error-operation #:with-gerror
   #:locked-error-p
   ;; the session bus and the service
   #:check-session-bus #:check-secret-service
   ;; schemas, attributes and values
   #:with-schema #:with-attributes #:make-secret-value #:secret-value-octets))
