;;;; credentials.lisp --- a credential store over the operating system's own (#357).
;;;;
;;;; An app keeps a user's API key, database password or token here rather than in a file. The
;;;; operating system stores it, protected per user:
;;;;
;;;;   - Windows: Credential Manager, a generic credential per item, encrypted per user by DPAPI
;;;;     and kept on this machine across logons (CRED_PERSIST_LOCAL_MACHINE).
;;;;   - macOS: the login Keychain, a generic-password item per credential, with the item's
;;;;     service and account set to SERVICE and ACCOUNT. Not the data-protection keychain,
;;;;     which needs a keychain-access-groups entitlement that an app signed ad hoc lacks.
;;;;   - Linux: the Secret Service, the freedesktop.org API that GNOME Keyring and KeePassXC
;;;;     provide over D-Bus, through libsecret. An item per credential in the default
;;;;     collection (the user's login keyring), with the attributes service and account under
;;;;     the schema org.codelisperer.hades.Credential, labelled "SERVICE (ACCOUNT)".
;;;;
;;;; Where no backend exists, every call signals CREDENTIAL-STORE-UNAVAILABLE. Nothing is ever
;;;; written to a file instead: a store that quietly saved the key somewhere weaker would be the
;;;; silent no-op hades's charter forbids.
;;;;
;;;; An item is named by SERVICE and ACCOUNT, both chosen by the app. SERVICE should name the
;;;; app and the purpose ("soloflow/anthropic-api-key"), so one app does not read another's
;;;; items by accident; the operating system already keeps users apart.
;;;;
;;;; THE VALUE NEVER APPEARS IN TEXT. It goes in as an AION/SECRET and comes out as one, which
;;;; prints as #<SECRET REDACTED>. No condition carries it, and no report names it. On Windows it
;;;; passes through a foreign buffer as UTF-8 bytes, and that buffer is zeroed before it is freed.
;;;; On macOS it passes through the same kind of buffer into a CFData; the buffer is zeroed, and
;;;; the CFData's own copy is not (aion ADR-0004). On Linux it passes through the same kind of
;;;; buffer into a SecretValue, which libsecret clears when it is released. The Lisp string REVEAL returns cannot be
;;;; zeroed; that is aion/secret's limit, not this file's.

(in-package #:hades/credentials)

;;; --- conditions --------------------------------------------------------------------

(define-condition credential-error (error)
  ((service :initarg :service :reader credential-error-service)
   (account :initarg :account :reader credential-error-account)
   (operation :initarg :operation :reader credential-error-operation)
   (code :initarg :code :initform nil :reader credential-error-code))
  (:report (lambda (c s)
             (format s "~A of the credential ~S / ~S failed~@[ (error ~A)~]"
                     (credential-error-operation c) (credential-error-service c)
                     (credential-error-account c) (credential-error-code c))))
  (:documentation "A credential operation failed. It names the item, never its value."))

(define-condition credential-not-found (credential-error)
  ()
  (:report (lambda (c s)
             (format s "no credential is stored for ~S / ~S"
                     (credential-error-service c) (credential-error-account c))))
  (:documentation "FETCH-CREDENTIAL found no item for the service and account."))

(define-condition credential-store-unavailable (credential-error)
  ((reason :initarg :reason :reader credential-store-unavailable-reason))
  (:report (lambda (c s)
             (format s "no credential store is available for ~S / ~S: ~A"
                     (credential-error-service c) (credential-error-account c)
                     (credential-store-unavailable-reason c))))
  (:documentation "This system has no credential store to use, so nothing was stored or read.
The value was not written anywhere else."))

(define-condition credential-too-large (credential-error)
  ((size :initarg :size :reader credential-too-large-size)
   (limit :initarg :limit :reader credential-too-large-limit))
  (:report (lambda (c s)
             (format s "the credential for ~S / ~S is ~D bytes, and the store takes at most ~D"
                     (credential-error-service c) (credential-error-account c)
                     (credential-too-large-size c) (credential-too-large-limit c))))
  (:documentation "STORE-CREDENTIAL refused a value longer than the store accepts. The report
gives its length, not its content."))

(defun %check-names (service account)
  (unless (and (stringp service) (plusp (length service)) (stringp account) (plusp (length account)))
    (error "hades/credentials: SERVICE and ACCOUNT must be non-empty strings, got ~S and ~S"
           service account)))

;;; --- Windows: Credential Manager -----------------------------------------------------

#+win32
(progn
  (defun %target (service account)
    "The Credential Manager target name for an item: SERVICE/ACCOUNT."
    (concatenate 'string service "/" account))

  (defun %fail (class service account operation &rest more)
    (apply #'error class :service service :account account :operation operation
           :code (aion/windows:last-error) more))

  (defun %store (service account secret)
    (let* ((octets (sb-ext:string-to-octets (aion/secret:reveal secret) :external-format :utf-8))
           (n (length octets)))
      (unwind-protect
           (progn
             (when (> n ffi:+cred-max-credential-blob-size+)
               (error 'credential-too-large :service service :account account :operation :store
                                            :size n :limit ffi:+cred-max-credential-blob-size+))
             (let ((blob (cffi:foreign-alloc :uint8 :count (max 1 n))))
               (unwind-protect
                    (progn
                      (dotimes (i n) (setf (cffi:mem-aref blob :uint8 i) (aref octets i)))
                      (aion/windows:with-wide-string (target (%target service account))
                        (aion/windows:with-wide-string (user account)
                          (cffi:with-foreign-object (cred '(:struct ffi:credential-w))
                            (dotimes (i (cffi:foreign-type-size '(:struct ffi:credential-w)))
                              (setf (cffi:mem-aref cred :uint8 i) 0))
                            (cffi:with-foreign-slots ((ffi:flags ffi::type ffi:target-name
                                                       ffi:credential-blob-size ffi:credential-blob
                                                       ffi:persist ffi:user-name)
                                                      cred (:struct ffi:credential-w))
                              (setf ffi:flags 0
                                    ffi::type ffi:+cred-type-generic+
                                    ffi:target-name target
                                    ffi:credential-blob-size n
                                    ffi:credential-blob blob
                                    ffi:persist ffi:+cred-persist-local-machine+
                                    ffi:user-name user))
                            (when (zerop (ffi:cred-write-w cred 0))
                              (%fail 'credential-error service account :store))))))
                 (dotimes (i (max 1 n)) (setf (cffi:mem-aref blob :uint8 i) 0))
                 (cffi:foreign-free blob))))
        (fill octets 0)))
    t)

  (defun %fetch (service account)
    (cffi:with-foreign-object (out :pointer)
      (aion/windows:with-wide-string (target (%target service account))
        (when (zerop (ffi:cred-read-w target ffi:+cred-type-generic+ 0 out))
          (let ((code (aion/windows:last-error)))
            (error (if (= code ffi:+error-not-found+) 'credential-not-found 'credential-error)
                   :service service :account account :operation :fetch :code code))))
      (let ((cred (cffi:mem-ref out :pointer)))
        (unwind-protect
             (let* ((n (cffi:foreign-slot-value cred '(:struct ffi:credential-w) 'ffi:credential-blob-size))
                    (blob (cffi:foreign-slot-value cred '(:struct ffi:credential-w) 'ffi:credential-blob))
                    (octets (make-array n :element-type '(unsigned-byte 8))))
               (unwind-protect
                    (progn
                      (dotimes (i n) (setf (aref octets i) (cffi:mem-aref blob :uint8 i)))
                      (dotimes (i n) (setf (cffi:mem-aref blob :uint8 i) 0))
                      (aion/secret:make-secret
                       (sb-ext:octets-to-string octets :external-format :utf-8)))
                 (fill octets 0)))
          (ffi:cred-free cred)))))

  (defun %delete (service account)
    (aion/windows:with-wide-string (target (%target service account))
      (if (zerop (ffi:cred-delete-w target ffi:+cred-type-generic+ 0))
          (let ((code (aion/windows:last-error)))
            (if (= code ffi:+error-not-found+)
                nil
                (error 'credential-error :service service :account account :operation :delete
                                         :code code)))
          t))))

;;; --- macOS: the login Keychain ---------------------------------------------------------

#+darwin
(progn
  (defconstant +keychain-max-bytes+ 2560
    "The longest value stored, in UTF-8 bytes. The Keychain itself takes more; this is
Credential Manager's limit, so a value an app can store on one system it can store on the
other.")

  (defun %keychain-fail (status service account operation)
    (error (if (= status ffi:+err-sec-item-not-found+) 'credential-not-found 'credential-error)
           :service service :account account :operation operation :code status))

  (defun %call-with-query (service account extra fn)
    "Call FN with an owned query dictionary naming the generic-password item SERVICE / ACCOUNT,
plus EXTRA, a list of (CONSTANT-NAME . VALUE) pairs whose values the caller owns. Returns what
FN returns."
    (darwin:with-cf ((s (darwin:make-cf-string service))
                     (a (darwin:make-cf-string account))
                     (query (darwin:make-cf-dictionary
                             (list* (cons (darwin:cf-constant "kSecClass")
                                          (darwin:cf-constant "kSecClassGenericPassword"))
                                    (cons (darwin:cf-constant "kSecAttrService") s)
                                    (cons (darwin:cf-constant "kSecAttrAccount") a)
                                    (mapcar (lambda (pair)
                                              (cons (darwin:cf-constant (car pair)) (cdr pair)))
                                            extra)))))
      (funcall fn query)))

  (defun %store (service account secret)
    (let ((octets (sb-ext:string-to-octets (aion/secret:reveal secret) :external-format :utf-8)))
      (unwind-protect
           (progn
             (when (> (length octets) +keychain-max-bytes+)
               (error 'credential-too-large :service service :account account :operation :store
                                            :size (length octets) :limit +keychain-max-bytes+))
             (darwin:with-cf ((data (darwin:make-cf-data octets)))
               ;; Add, and when an item already exists, replace its value instead.
               (let ((status (%call-with-query service account (list (cons "kSecValueData" data))
                                               (lambda (query)
                                                 (ffi:sec-item-add query (cffi:null-pointer))))))
                 (when (= status ffi:+err-sec-duplicate-item+)
                   (setf status
                         (%call-with-query service account '()
                                           (lambda (query)
                                             (darwin:with-cf ((change (darwin:make-cf-dictionary
                                                                       (list (cons (darwin:cf-constant "kSecValueData")
                                                                                   data)))))
                                               (ffi:sec-item-update query change))))))
                 (unless (= status ffi:+err-sec-success+)
                   (%keychain-fail status service account :store)))))
        (fill octets 0)))
    t)

  (defun %fetch (service account)
    (cffi:with-foreign-object (out :pointer)
      (setf (cffi:mem-ref out :pointer) (cffi:null-pointer))
      (let ((status (%call-with-query service account
                                      (list (cons "kSecReturnData" (darwin:cf-constant "kCFBooleanTrue"))
                                            (cons "kSecMatchLimit" (darwin:cf-constant "kSecMatchLimitOne")))
                                      (lambda (query) (ffi:sec-item-copy-matching query out)))))
        (unless (= status ffi:+err-sec-success+)
          (%keychain-fail status service account :fetch)))
      ;; SecItemCopyMatching is a Copy: the CFData it returned is ours to release.
      (darwin:with-cf ((data (cffi:mem-ref out :pointer)))
        (let ((octets (darwin:cf-data-octets data)))
          (unwind-protect
               (aion/secret:make-secret (sb-ext:octets-to-string octets :external-format :utf-8))
            (fill octets 0))))))

  (defun %delete (service account)
    (let ((status (%call-with-query service account '()
                                    (lambda (query) (ffi:sec-item-delete query)))))
      (cond ((= status ffi:+err-sec-success+) t)
            ((= status ffi:+err-sec-item-not-found+) nil)
            (t (%keychain-fail status service account :delete))))))

;;; --- Linux: the Secret Service ----------------------------------------------------------

#+linux
(progn
  (defparameter *schema-name* "org.codelisperer.hades.Credential"
    "The libsecret schema every item is stored under. A lookup matches only items with this
schema, so it never returns an item another program stored with the same attributes.")

  (defconstant +secret-service-max-bytes+ 2560
    "The longest value stored, in UTF-8 bytes. The Secret Service itself takes more; this is
Credential Manager's limit, so a value an app can store on one system it can store on the
others.")

  (defun %unavailable-reason ()
    "NIL when the Secret Service can be used, or a sentence saying why it cannot, checking in
the order a user would fix them: libsecret installed, a D-Bus session bus, a program providing
the Secret Service on it. Nothing here unlocks a keyring, so it never prompts. The caller holds
the libsecret lock."
    (multiple-value-bind (loaded why) (libsecret:load-libsecret)
      (flet ((fails (check what)
               (handler-case (progn (funcall check) nil)
                 (libsecret:libsecret-error (e)
                   (format nil "~A (~A)" what (libsecret:libsecret-error-message e))))))
        (if (not loaded)
            (format nil "libsecret is not installed, so the Secret Service cannot be reached (~A)"
                    why)
            (or (fails #'libsecret:check-session-bus
                       "there is no D-Bus session bus to reach the Secret Service on")
                (fails #'libsecret:check-secret-service
                       "no program provides the Secret Service on the D-Bus session bus; GNOME Keyring and KeePassXC are two that do"))))))

  (defun %secret-service-fail (condition service account operation)
    "Signal the hades condition for the libsecret CONDITION: a locked keyring is a store that
cannot be used now; anything else is a failed operation, with GLib's message as its code."
    (if (libsecret:locked-error-p condition)
        (error 'credential-store-unavailable
               :service service :account account :operation operation
               :reason "the keyring is locked; unlock it, for example by logging in to the desktop, and try again")
        (error 'credential-error
               :service service :account account :operation operation
               :code (format nil "~A ~D: ~A" (libsecret:libsecret-error-domain condition)
                             (libsecret:libsecret-error-code condition)
                             (libsecret:libsecret-error-message condition)))))

  (defun %call-with-item (service account operation fn)
    "Call FN with the schema and the attribute table naming the item SERVICE / ACCOUNT, under the
libsecret lock, after checking that the Secret Service can be reached. Returns what FN returns."
    (libsecret:with-libsecret-lock ()
      (let ((reason (%unavailable-reason)))
        (when reason
          (error 'credential-store-unavailable
                 :service service :account account :operation operation :reason reason)))
      (libsecret:with-schema (schema *schema-name* '("service" "account"))
        (libsecret:with-attributes (attributes (list (cons "service" service)
                                                     (cons "account" account)))
          (handler-case (funcall fn schema attributes)
            (libsecret:libsecret-error (e)
              (%secret-service-fail e service account operation)))))))

  (defun %store (service account secret)
    (let ((octets (sb-ext:string-to-octets (aion/secret:reveal secret) :external-format :utf-8)))
      (unwind-protect
           (progn
             (when (> (length octets) +secret-service-max-bytes+)
               (error 'credential-too-large :service service :account account :operation :store
                                            :size (length octets)
                                            :limit +secret-service-max-bytes+))
             (%call-with-item
              service account :store
              (lambda (schema attributes)
                (let ((value (libsecret:make-secret-value octets)))
                  (unwind-protect
                       ;; Stores a new item, or replaces the value of the one already stored with
                       ;; the same schema and attributes in the collection.
                       (when (zerop (libsecret:with-gerror (err "storing the credential")
                                      (ffi:secret-password-storev-binary-sync
                                       schema attributes "default"
                                       (format nil "~A (~A)" service account)
                                       value (cffi:null-pointer) err)))
                         (error 'credential-error :service service :account account
                                                  :operation :store))
                    (ffi:secret-value-unref value))))))
        (fill octets 0)))
    t)

  (defun %fetch (service account)
    (%call-with-item
     service account :fetch
     (lambda (schema attributes)
       (let ((value (libsecret:with-gerror (err "looking up the credential")
                      (ffi:secret-password-lookupv-binary-sync schema attributes
                                                               (cffi:null-pointer) err))))
         (when (cffi:null-pointer-p value)
           (error 'credential-not-found :service service :account account :operation :fetch))
         (unwind-protect
              (let ((octets (libsecret:secret-value-octets value)))
                (unwind-protect
                     (aion/secret:make-secret
                      (sb-ext:octets-to-string octets :external-format :utf-8))
                  (fill octets 0)))
           (ffi:secret-value-unref value))))))

  (defun %delete (service account)
    (%call-with-item
     service account :delete
     (lambda (schema attributes)
       (/= 0 (libsecret:with-gerror (err "deleting the credential")
               (ffi:secret-password-clearv-sync schema attributes (cffi:null-pointer) err)))))))

;;; --- elsewhere: no store ----------------------------------------------------------------

#-(or win32 darwin linux)
(progn
  (defun %unavailable (service account operation)
    (error 'credential-store-unavailable
           :service service :account account :operation operation
           :reason "hades/credentials has no backend for this operating system; it has one for Windows, macOS and Linux"))
  (defun %store (service account secret)
    (declare (ignore secret))
    (%unavailable service account :store))
  (defun %fetch (service account) (%unavailable service account :fetch))
  (defun %delete (service account) (%unavailable service account :delete)))

;;; --- the facade ------------------------------------------------------------------------

(defun store-credential (service account secret)
  "Store SECRET, an AION/SECRET, as the credential for SERVICE and ACCOUNT, replacing any stored
before. Returns T. Signals CREDENTIAL-TOO-LARGE for a value the store cannot hold,
CREDENTIAL-STORE-UNAVAILABLE where this system has no store, and CREDENTIAL-ERROR otherwise."
  (%check-names service account)
  (unless (aion/secret:secretp secret)
    (error 'type-error :datum :not-shown :expected-type 'aion/secret:secret))
  (%store service account secret))

(defun fetch-credential (service account)
  "The credential stored for SERVICE and ACCOUNT, as an AION/SECRET. Signals
CREDENTIAL-NOT-FOUND when there is none, rather than returning NIL."
  (%check-names service account)
  (%fetch service account))

(defun delete-credential (service account)
  "Delete the credential for SERVICE and ACCOUNT. Returns T when one was deleted and NIL when
there was none."
  (%check-names service account)
  (%delete service account))
