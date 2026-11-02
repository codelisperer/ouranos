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
          t)))

  (defun %zero-blob (cred)
    "Write zeros over CRED's CredentialBlob, the plaintext value Windows decrypted into this
process (#1035, the review of #1066). Called for every credential CredEnumerateW returned,
before CredFree, so a listing does not leave secrets in freed memory."
    (let ((size (cffi:foreign-slot-value cred '(:struct ffi:credential-w) 'ffi:credential-blob-size))
          (blob (cffi:foreign-slot-value cred '(:struct ffi:credential-w) 'ffi:credential-blob)))
      (when (and (integerp size) (plusp size) (not (cffi:null-pointer-p blob)))
        (dotimes (i size) (setf (cffi:mem-aref blob :uint8 i) 0)))))

  (defun %accounts (service operation)
    "The accounts stored under SERVICE, from CredEnumerateW with the filter SERVICE/* (#1035).

WINDOWS DECRYPTS THE VALUES, AND THIS ERASES THEM. There is no Windows call that lists
credentials without their values: CredEnumerateW returns a whole CREDENTIALW for every match,
and for a generic credential that includes CredentialBlob, the plaintext after DPAPI
decryption, in this process's heap. CredReadW does the same. So the issue's requirement that
this function not decrypt a value cannot be met here, and what it was for is met instead: every
blob is zeroed (%ZERO-BLOB) before CredFree, so a listing of ten items does not leave ten
plaintext values in freed memory. Writing zeros over a blob is not reading it. No test can see
this, because the decryption happens inside Windows (the review of #1066).

THE TARGET IS MATCHED EXACTLY, not by prefix. A target is SERVICE/ACCOUNT and either part may
hold a slash, so the filter SERVICE/* also matches items of other services: with
\"soloflow/anthropic-api-key\" stored under account \"user\", a prefix match reported
\"anthropic-api-key/user\" as an account of \"soloflow\". hades writes UserName = account, so each
target is compared with (%TARGET SERVICE USER-NAME), and the type must be CRED_TYPE_GENERIC,
which is what FETCH-CREDENTIAL reads with. macOS and Linux match service and account exactly,
so this is what makes the three agree.

CredEnumerateW does not prompt. ERROR_NOT_FOUND means the store holds no item matching the
filter, which is an empty list and not a failure."
    (cffi:with-foreign-objects ((count :uint32) (creds :pointer))
      (aion/windows:with-wide-string (filter (concatenate 'string service "/*"))
        (when (zerop (ffi:cred-enumerate-w filter 0 count creds))
          (let ((code (aion/windows:last-error)))
            (if (= code ffi:+error-not-found+)
                (return-from %accounts '())
                (error 'credential-error :service service :account nil :operation operation
                                         :code code)))))
      (let ((array (cffi:mem-ref creds :pointer))
            (n (cffi:mem-ref count :uint32)))
        (unwind-protect
             (loop for i below n
                   for cred = (cffi:mem-aref array :pointer i)
                   unless (cffi:null-pointer-p cred)
                     append (let ((target (aion/windows:wide-string-to-lisp
                                           (cffi:foreign-slot-value cred '(:struct ffi:credential-w)
                                                                    'ffi:target-name)))
                                  (user (let ((p (cffi:foreign-slot-value
                                                  cred '(:struct ffi:credential-w) 'ffi:user-name)))
                                          (unless (cffi:null-pointer-p p)
                                            (aion/windows:wide-string-to-lisp p))))
                                  (kind (cffi:foreign-slot-value cred '(:struct ffi:credential-w)
                                                                 'ffi::type)))
                              (when (and target user
                                         (eql kind ffi:+cred-type-generic+)
                                         (string= target (%target service user)))
                                (list user))))
          ;; Every blob is erased before the array is freed, whether the loop above finished or
          ;; unwound.
          (loop for i below n
                for cred = (cffi:mem-aref array :pointer i)
                unless (cffi:null-pointer-p cred) do (%zero-blob cred))
          (ffi:cred-free array)))))

  (defun %exists-p (service account)
    (and (member account (%accounts service :exists-p) :test #'string=) t))

  (defun %names (service)
    (remove-duplicates (%accounts service :names) :test #'string= :from-end t)))

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
            (t (%keychain-fail status service account :delete)))))

  (defun %accounts (service account operation)
    "The accounts of the generic-password items for SERVICE, and with ACCOUNT only that one
item's (#1035).

ATTRIBUTES ONLY, AND NO PROMPT. The query carries kSecReturnAttributes and kSecMatchLimitAll,
and never kSecReturnData, which is the only key that returns a value. kSecUseAuthenticationUI is
kSecUseAuthenticationUIFail, so a locked Keychain answers errSecInteractionNotAllowed instead of
showing an unlock dialog; that becomes CREDENTIAL-STORE-UNAVAILABLE saying so, as the issue
asks, rather than a prompt.

The query is built here rather than through %CALL-WITH-QUERY, because that one always names an
account and this must be able to ask for every account of a service."
    (darwin:with-cf ((s (darwin:make-cf-string service))
                     (a (when account (darwin:make-cf-string account))))
      (cffi:with-foreign-object (out :pointer)
        (setf (cffi:mem-ref out :pointer) (cffi:null-pointer))
        (let* ((entries (append
                         (list (cons (darwin:cf-constant "kSecClass")
                                     (darwin:cf-constant "kSecClassGenericPassword"))
                               (cons (darwin:cf-constant "kSecAttrService") s)
                               (cons (darwin:cf-constant "kSecReturnAttributes")
                                     (darwin:cf-constant "kCFBooleanTrue"))
                               (cons (darwin:cf-constant "kSecMatchLimit")
                                     (darwin:cf-constant "kSecMatchLimitAll"))
                               (cons (darwin:cf-constant "kSecUseAuthenticationUI")
                                     (darwin:cf-constant "kSecUseAuthenticationUIFail")))
                         (when account
                           (list (cons (darwin:cf-constant "kSecAttrAccount") a)))))
               (status (darwin:with-cf ((query (darwin:make-cf-dictionary entries)))
                         (ffi:sec-item-copy-matching query out))))
          (cond ((= status ffi:+err-sec-item-not-found+) (return-from %accounts '()))
                ((= status ffi:+err-sec-interaction-not-allowed+)
                 (error 'credential-store-unavailable
                        :service service :account account :operation operation
                        :reason "the Keychain is locked, and this reads it without asking you to unlock it; unlock the Keychain and try again"))
                ((/= status ffi:+err-sec-success+)
                 (%keychain-fail status service account operation))))
        ;; SecItemCopyMatching is a Copy: the CFArray it returned is ours to release.
        (darwin:with-cf ((items (cffi:mem-ref out :pointer)))
          (loop for i below (ffi:cf-array-get-count items)
                for item = (ffi:cf-array-get-value-at-index items i)
                for name = (unless (cffi:null-pointer-p item)
                             (let ((value (ffi:cf-dictionary-get-value
                                           item (darwin:cf-constant "kSecAttrAccount"))))
                               (unless (cffi:null-pointer-p value)
                                 (darwin:cf-string-to-lisp value))))
                when name collect name)))))

  (defun %exists-p (service account)
    (and (member account (%accounts service account :exists-p) :test #'string=) t))

  (defun %names (service)
    (remove-duplicates (%accounts service nil :names) :test #'string= :from-end t)))

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
           (progn (%fail-if-still-locked service account :delete) nil)))))

  (defun %accounts (service account operation)
    "The accounts stored under SERVICE, or, with ACCOUNT, the accounts of the items matching both
(#1035). Reads attributes only: no value is fetched and no collection is unlocked, so a locked
keyring still answers and nothing prompts.

The reachability check is %UNAVAILABLE-REASON's, as for every other operation. The
locked-and-headless refusal in %CALL-WITH-ITEM is deliberately NOT applied: that one is there
because a lookup or a clear asks to unlock, and this search does not."
    (libsecret:with-libsecret-lock ()
      (let ((reason (%unavailable-reason)))
        (when reason
          (error 'credential-store-unavailable
                 :service service :account account :operation operation :reason reason)))
      (handler-case
          (libsecret:with-schema (schema *schema-name* '("service" "account"))
            (libsecret:with-attributes (attributes (if account
                                                       (list (cons "service" service)
                                                             (cons "account" account))
                                                       (list (cons "service" service))))
              (libsecret:search-attribute-values schema attributes "account")))
        (libsecret:libsecret-error (e)
          (%secret-service-fail e service account operation)))))

  (defun %exists-p (service account)
    (and (member account (%accounts service account :exists-p) :test #'string=) t))

  (defun %names (service)
    (remove-duplicates (%accounts service nil :names) :test #'string= :from-end t)))

;;; --- elsewhere: no store ----------------------------------------------------------------

#-(or win32 darwin linux)
(progn
  (defun %exists-p (service account) (%unavailable service account :exists-p))
  (defun %names (service) (%unavailable service nil :names))

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

#+linux
(progn
  (defun %available ()
    ;; The same checks every operation makes first: libsecret, the session bus, and a program
    ;; providing the Secret Service. None of them unlocks a keyring, so this never prompts; a
    ;; locked keyring is reported when an operation is tried, as on macOS.
    (let ((reason (libsecret:with-libsecret-lock () (%unavailable-reason))))
      (if reason (values nil reason) (values t nil))))
  (defun %store-name () "Secret Service"))

#-(or win32 darwin linux)
(progn
  (defun %available ()
    (values nil "hades/credentials has no backend for this operating system; it has one for Windows, macOS and Linux"))
  (defun %store-name () nil))

(defun credential-store-available-p (&key service)
  "True when this system has a credential store an app can use, and NIL when it has none, so an
app can say so instead of showing a field that can only fail. A second value, when the first is
NIL, says why.

It never prompts, never writes, and never creates an item. On Windows it asks Credential Manager
for an item that does not exist, and is false when the logon session has no credential store; on
macOS it is true wherever the Keychain backend is built, without asking the Keychain, because a
query can prompt when the keychain is locked; on Linux it is true when libsecret is installed,
there is a D-Bus session bus, and a program provides the Secret Service on it, checked without
unlocking anything, and false with the first of those that is missing as the reason. A locked
keyring is reported when an operation is tried. SERVICE is accepted for a backend that answers
per service and is not used yet."
  (declare (ignore service))
  (%available))

(defun credential-store-name ()
  "The name to show a user for this system's credential store: \"Windows Credential Manager\",
\"macOS Keychain\" or \"Secret Service\", or NIL on a system hades/credentials has no backend
for. On Linux the name is given even when the Secret Service cannot be reached;
CREDENTIAL-STORE-AVAILABLE-P says whether it can."
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

(defun %check-listing-service (service operation)
  "Signal CREDENTIAL-ERROR when SERVICE cannot be used to list items (#1035, the review of
#1066). A `*' is refused because on Windows the service goes into CredEnumerateW's filter, where
it is a wildcard: a service of \"*\" or \"a*\" would make Windows enumerate, and therefore decrypt,
every credential of every application, or every one beginning with `a', before anything of ours
looked at it. It is refused on every platform so the three agree; on macOS and Linux a `*' is an
ordinary character in an attribute and would simply match nothing."
  (when (find #\* service)
    (error 'credential-error :service service :account nil :operation operation
                             :code "a service name used for listing may not contain `*'")))

(defun credential-exists-p (service account)
  "Whether a credential is stored for SERVICE and ACCOUNT, without returning its value, and on
macOS and Linux without decrypting one (#1035). ON WINDOWS THE VALUE IS DECRYPTED AND ERASED --
see below, and do not read this first line as saying otherwise.

An app that shows \"a key is saved\", or offers to remove one, asks this instead of fetching the
secret to decide a label. The Keychain is asked for attributes only, and the Secret Service is
searched and read for item attributes, which it stores unencrypted; neither decrypts a value.

ON WINDOWS THE VALUE IS DECRYPTED AND THEN ERASED, because Windows offers no other way. Every
call that lists or reads a credential, CredEnumerateW and CredReadW alike, returns the whole
CREDENTIALW including the plaintext CredentialBlob. hades writes zeros over every blob before
freeing what Windows returned, so nothing is left in freed memory, but the value does pass
through this process. See %ACCOUNTS (the review of #1066).

NOTHING HERE PROMPTS, as far as is tested. The macOS query sets kSecUseAuthenticationUIFail so
that a Keychain which could only answer by asking signals CREDENTIAL-STORE-UNAVAILABLE instead;
**that path is not covered by a test**, because no test here locks a keychain, and Apple
documents the flag for items under access control while a file-based login keychain's prompting
is governed by SecKeychainSetUserInteractionAllowed (the review of #1066). On Linux a locked
keyring answers without prompting, which IS exercised, so this can be true for an item
FETCH-CREDENTIAL would refuse to read until the keyring is unlocked.

WHAT THE ANSWER REVEALS is whether the credential exists, and never its value. Existence is
metadata the store already keeps unencrypted -- a target name in Credential Manager, an item
attribute in the Secret Service -- so answering from it discloses nothing the value protects
(the hub's ruling on #1035).

Signals CREDENTIAL-STORE-UNAVAILABLE where this system has no store or it cannot be reached,
and CREDENTIAL-ERROR for any other failure. A name that is empty signals, as elsewhere, and so
does a SERVICE holding `*' (%CHECK-LISTING-SERVICE)."
  (%check-names service account)
  (%check-listing-service service :exists-p)
  (%exists-p service account))

(defun credential-names (service)
  "The accounts stored under SERVICE, as a list of strings, without returning any value, and on
macOS and Linux without decrypting one (#1035). ON WINDOWS EVERY MATCHING VALUE IS DECRYPTED AND
ERASED -- see CREDENTIAL-EXISTS-P's docstring and %ACCOUNTS.
The order is the store's. An app keeping its own list of which keys it has saved, which can
drift from the store, asks this instead.

Reads what CREDENTIAL-EXISTS-P reads and prompts as little, and like it returns only which
accounts exist and never a value; see its docstring.

ONLY SERVICE'S OWN ITEMS ARE RETURNED, WHICH IS NOT THE SAME AS ONLY SERVICE'S OWN ITEMS BEING
READ. On Windows the filter handed to CredEnumerateW is SERVICE/*, and Windows decrypts every
credential of this user whose target begins with that prefix before hades compares any target,
including items another program stored under such a target. Those values are erased with the
rest (%ZERO-BLOB), and none is returned, but they do pass through this process. macOS and Linux
match the service attribute exactly in the store, so they read only SERVICE's items. Narrowing
the Windows read to one CredReadW for the exact target is #1079, and the collision between two
(service, account) pairs that join to the same Windows target is #1080 (the review of #1066).

Nothing here is logged. hades/credentials depends on no logging facade, and an account name is
the kind of thing a log must not carry, so the names are returned to the caller and written
nowhere."
  (%check-names service "unused")
  (%check-listing-service service :names)
  (%names service))
