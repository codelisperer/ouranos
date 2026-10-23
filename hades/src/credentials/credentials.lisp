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
;;;; buffer into a SecretValue, which libsecret clears when it is released.
;;;;
;;;; A LOCKED KEYRING on Linux: on a desktop an operation may ask the user to unlock it, as macOS
;;;; does. Without a display (no DISPLAY or WAYLAND_DISPLAY) a locked default collection is
;;;; refused before anything is asked. A lookup or delete that comes back empty while the
;;;; collection is still locked was refused or dismissed, and is reported as
;;;; CREDENTIAL-STORE-UNAVAILABLE, never as an absent item. The Lisp string REVEAL returns cannot be
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

  (defparameter *locked-headless-reason*
    "the keyring is locked, and there is no display to ask for it to be unlocked on (neither DISPLAY nor WAYLAND_DISPLAY is set); unlock it, for example by logging in to the desktop, and try again")

  (defparameter *locked-declined-reason*
    "the keyring is locked and was not unlocked: the request to unlock it was dismissed or could not be shown")

  (defun %unavailable-reason ()
    "NIL when the Secret Service can be reached, or a sentence saying why it cannot, checking in
the order a user would fix them: libsecret installed, a D-Bus session bus, a program providing
the Secret Service on it. These checks unlock nothing, so this does not prompt. The caller holds
the libsecret lock."
    (multiple-value-bind (loaded why) (libsecret:load-libsecret)
      (flet ((fails (check what)
               (handler-case (progn (funcall check) nil)
                 (libsecret:libsecret-error (e)
                   (format nil "~A (~A)" (funcall what e) (libsecret:libsecret-error-message e))))))
        (if (not loaded)
            (format nil "libsecret is not installed, so the Secret Service cannot be reached (~A)"
                    why)
            (or (fails #'libsecret:check-session-bus
                       (constantly "there is no D-Bus session bus to reach the Secret Service on"))
                (fails #'libsecret:check-secret-service
                       (lambda (e)
                         (if (libsecret:service-missing-error-p e)
                             "no program provides the Secret Service on the D-Bus session bus; GNOME Keyring and KeePassXC are two that do"
                             "the Secret Service on the D-Bus session bus could not be reached"))))))))

  (defun %headless-p ()
    "True when there is no display an unlock prompt could be shown on."
    (flet ((unset (name) (let ((v (uiop:getenv name))) (or (null v) (string= v "")))))
      (and (unset "DISPLAY") (unset "WAYLAND_DISPLAY"))))

  (defun %fail-if-still-locked (service account operation)
    "Called when an operation found or changed nothing. When the default collection is locked,
that result means the item could not be reached, not that it is absent, so signal
CREDENTIAL-STORE-UNAVAILABLE. libsecret's lookup and clear ask to unlock a locked item, and when
the request is dismissed they return nothing and no error."
    (when (libsecret:default-collection-locked-p)
      (error 'credential-store-unavailable
             :service service :account account :operation operation
             :reason *locked-declined-reason*)))

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
libsecret lock, after checking that the Secret Service can be reached. Returns what FN returns.

On a desktop, FN's call may show the user a request to unlock the keyring, as the Keychain does
on macOS, and waits for the answer holding the lock. Without a display there is nobody to ask,
so a locked keyring is refused here instead of starting a request that could wait indefinitely."
    (libsecret:with-libsecret-lock ()
      (let ((reason (%unavailable-reason)))
        (when reason
          (error 'credential-store-unavailable
                 :service service :account account :operation operation :reason reason)))
      (handler-case
          (progn
            (when (and (%headless-p) (libsecret:default-collection-locked-p))
              (error 'credential-store-unavailable
                     :service service :account account :operation operation
                     :reason *locked-headless-reason*))
            (libsecret:with-schema (schema *schema-name* '("service" "account"))
              (libsecret:with-attributes (attributes (list (cons "service" service)
                                                           (cons "account" account)))
                (funcall fn schema attributes))))
        (libsecret:libsecret-error (e)
          (%secret-service-fail e service account operation)))))

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
                         (%fail-if-still-locked service account :store)
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
           (%fail-if-still-locked service account :fetch)
           (error 'credential-not-found :service service :account account :operation :fetch))
         (unwind-protect
              (let ((octets (libsecret:secret-value-octets value)))
                (unwind-protect
                     (aion/secret:make-secret (%decode-value octets service account))
                  (fill octets 0)))
           (ffi:secret-value-unref value))))))

  (defun %decode-value (octets service account)
    "OCTETS as a UTF-8 string. Another program can store bytes that are not UTF-8 under this
schema; SBCL's decoding error would carry them into a report or a backtrace, so it is replaced
by a CREDENTIAL-ERROR that names the item and not its bytes."
    (or (handler-case (sb-ext:octets-to-string octets :external-format :utf-8)
          (sb-int:character-decoding-error () nil))
        (error 'credential-error :service service :account account :operation :fetch
                                 :code "the stored value is not UTF-8 text")))

  (defun %delete (service account)
    (%call-with-item
     service account :delete
     (lambda (schema attributes)
       (or (/= 0 (libsecret:with-gerror (err "deleting the credential")
                   (ffi:secret-password-clearv-sync schema attributes (cffi:null-pointer) err)))
           (progn (%fail-if-still-locked service account :delete) nil))))))

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

;;; --- is there a store? (#824) ----------------------------------------------------------

(defparameter *probe-service* "hades/credentials"
  "The service of the item CREDENTIAL-STORE-AVAILABLE-P asks Windows for. It is only ever read,
never written, so it does not exist unless an app stored one under the same name.")

(defparameter *probe-account* "availability-probe")

#+win32
(progn
  (defconstant +error-no-such-logon-session+ 1312
    "Credential Manager's answer when the process's logon session has no credential set, as for
some services and scheduled tasks.")

  (defun %available ()
    "Ask Credential Manager for an item that does not exist. Not found means the store answers;
a missing logon session means it cannot be used. Nothing is written and nothing prompts."
    (cffi:with-foreign-object (out :pointer)
      (aion/windows:with-wide-string (target (%target *probe-service* *probe-account*))
        (if (zerop (ffi:cred-read-w target ffi:+cred-type-generic+ 0 out))
            (let ((code (aion/windows:last-error)))
              (cond ((= code ffi:+error-not-found+) (values t nil))
                    ((= code +error-no-such-logon-session+)
                     (values nil "this logon session has no Windows credential store"))
                    (t (values nil (format nil "Windows Credential Manager answered error ~D"
                                           code)))))
            (progn (ffi:cred-free (cffi:mem-ref out :pointer))
                   (values t nil))))))

  (defun %store-name () "Windows Credential Manager"))

#+darwin
(progn
  (defun %available ()
    ;; Not probed: a Keychain query can put up a dialog when the login keychain is locked, and
    ;; this must never prompt. The backend is there; a locked keychain is reported when used.
    (values t nil))
  (defun %store-name () "macOS Keychain"))

#-(or win32 darwin)
(progn
  (defun %available ()
    (values nil "no credential store backend exists on this system yet; the Secret Service one is #357"))
  (defun %store-name () nil))

(defun credential-store-available-p (&key service)
  "True when this system has a credential store an app can use, and NIL when it has none, so an
app can say so instead of showing a field that can only fail. A second value, when the first is
NIL, says why.

It never prompts, never writes, and never creates an item. On Windows it asks Credential Manager
for an item that does not exist, and is false when the logon session has no credential store; on
macOS it is true wherever the Keychain backend is built, without asking the Keychain, because a
query can prompt when the keychain is locked; elsewhere it is false until #357 adds the Secret
Service backend, and is true from then on without a change here. SERVICE is accepted for a
backend that answers per service and is not used yet."
  (declare (ignore service))
  (%available))

(defun credential-store-name ()
  "The name to show a user for this system's credential store: \"Windows Credential Manager\" or
\"macOS Keychain\", or NIL where there is none yet (Linux, until #357)."
  (%store-name))

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
