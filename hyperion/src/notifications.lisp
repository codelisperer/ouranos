;;;; notifications.lisp --- in-app notifications: a store protocol, notify, a bell and a list (#792).
;;;;
;;;; An app tells a user about something that happened while they were elsewhere: a request
;;;; awaiting their decision, a moderation outcome, a reply. NOTIFY records it for the user's
;;;; notification list, sends it by email through the app's own function, or both, as the user's
;;;; delivery choice for that kind of notification says. The bell shows the unread count and the
;;;; list shows the notifications, with mark-read and mark-all-read.
;;;;
;;;; Unlike hyperion/notice (#980), a notification is stored and follows the user from page to
;;;; page until it is read and pruned.
;;;;
;;;; EMAIL IS THE APP'S FUNCTION. hermes is a satellite, and nothing in hyperion depends on it,
;;;; so the email side is a function the app passes (see *NOTIFICATION-EMAIL*), which usually
;;;; calls hermes itself. The store is a protocol; this file has the memory store, and
;;;; hyperion/notifications-db the mnemosyne one.
;;;;
;;;; THE RECIPIENT NEVER COMES FROM THE REQUEST. Every store call that reads or changes a
;;;; notification takes the recipient, and a store matches on recipient and id together, so a
;;;; request cannot read or mark another user's notification whatever id it sends. The routes
;;;; take the recipient from the app's RECIPIENT-FN, which reads the app's own sign-in.

(cl:defpackage #:hyperion/notifications
  (:use #:cl)
  (:local-nicknames (#:bt #:bordeaux-threads)
                    (#:spin #:spinneret)
                    (#:i18n #:hyperion/i18n)
                    (#:http #:hyperion/http)
                    (#:router #:hyperion/router)
                    (#:csrf #:hyperion/csrf)
                    (#:clock #:aion/clock)
                    (#:log #:aion/log))
  (:documentation
   "In-app notifications (#792): NOTIFY routes a notification to the user's list, to email
    through the app's own function, or both, by the user's choice for its kind. A store
    protocol with a memory store (the mnemosyne store is hyperion/notifications-db), the
    NOTIFICATION-BELL and NOTIFICATION-PANEL components, NOTIFICATION-ROUTER, and
    PRUNE-NOTIFICATIONS-JOB for aion/schedule.")
  (:export
   ;; the record
   #:notification #:notification-p #:make-notification
   #:notification-id #:notification-recipient #:notification-kind #:notification-title
   #:notification-body #:notification-link #:notification-group-key #:notification-count
   #:notification-stamp #:notification-created-at #:notification-read-at
   ;; kinds and delivery
   #:define-notification-kind #:notification-kinds #:notification-kind-default
   #:notification-kind-label #:+deliveries+ #:delivery
   #:unknown-notification-kind #:invalid-notification #:invalid-notification-reason
   ;; notify
   #:notify #:*notification-email* #:notification-email-failed
   #:notification-email-failed-recipient #:notification-email-failed-kind
   #:notification-email-failed-cause
   ;; the store protocol
   #:notification-put #:notification-list #:unread-count #:mark-read #:mark-all-read
   #:prune-notifications #:delivery-ref #:delivery-set
   #:memory-notification-store #:make-memory-notification-store
   ;; the components and routes
   #:*prefix* #:notification-bell #:notification-panel #:delivery-form #:notification-router
   ;; retention
   #:prune-notifications-job))

(in-package #:hyperion/notifications)

;;; --- the record -------------------------------------------------------------------------

(defstruct (notification (:constructor %make-notification) (:copier nil))
  "One notification for RECIPIENT.

TITLE and BODY are each a string, or a translation key with arguments, (:KEY KEY :ARGS PLIST),
rendered in the viewer's locale when the list is shown. BODY may be NIL. Both are text, never
HTML. LINK is NIL or a path on the app's own site (see %CHECK-LINK). GROUP-KEY is NIL or a
string: a notification with the group key of an unread one collapses into it (NOTIFICATION-PUT).
COUNT is how many notifications this item stands for. STAMP orders the list: an AION/CLOCK
tick, newer when the item is created or collapsed into. CREATED-AT and READ-AT are universal
times; READ-AT is NIL while unread."
  (id "" :type string)
  (recipient "" :type string)
  (kind nil :type keyword)
  (title nil)
  (body nil)
  (link nil :type (or null string))
  (group-key nil :type (or null string))
  (count 1 :type (integer 1))
  (stamp 0 :type integer)
  (created-at 0 :type integer)
  (read-at nil :type (or null integer)))

(define-condition invalid-notification (error)
  ((reason :initarg :reason :reader invalid-notification-reason))
  (:report (lambda (c s) (format s "hyperion/notifications: ~A" (invalid-notification-reason c))))
  (:documentation "A notification NOTIFY or MAKE-NOTIFICATION refuses, with the reason."))

(defun %refuse (control &rest args)
  (error 'invalid-notification :reason (apply #'format nil control args)))

(defun %text-or-key-p (x)
  "Whether X is a string, or (:KEY KEY :ARGS PLIST) with KEY a keyword or string."
  (or (stringp x)
      (and (consp x) (eq (first x) :key)
           (let ((key (getf x :key)))
             (or (keywordp key) (stringp key)))
           (listp (getf x :args))
           (evenp (length (getf x :args))))))

(defun %check-link (link)
  "LINK, when it is NIL or a path on the app's own site: it begins with one slash and not two,
and holds no backslash or control character. Anything else, such as https://elsewhere,
//elsewhere or javascript:..., would let a notification send the user off the site, and is
refused."
  (when link
    (unless (and (stringp link)
                 (plusp (length link))
                 (char= (char link 0) #\/)
                 (not (and (> (length link) 1) (find (char link 1) "/\\")))
                 (notany (lambda (c) (or (char= c #\\) (< (char-code c) 32) (= (char-code c) 127)))
                         link))
      (%refuse "a notification's LINK must be a path on this site, beginning with one /, not ~S"
               link)))
  link)

(defun make-notification (recipient kind &key title body link group-key)
  "A new, unread notification for RECIPIENT of KIND, checked: RECIPIENT a non-empty string,
KIND a keyword, TITLE a string or (:KEY KEY :ARGS PLIST), BODY NIL or the same, LINK NIL or a
path on this site (%CHECK-LINK), GROUP-KEY NIL or a non-empty string."
  (unless (and (stringp recipient) (plusp (length recipient)))
    (%refuse "the RECIPIENT must be a non-empty string, not ~S" recipient))
  (unless (keywordp kind) (%refuse "the KIND must be a keyword, not ~S" kind))
  (unless (%text-or-key-p title)
    (%refuse "the TITLE must be a string or (:key KEY :args PLIST), not ~S" title))
  (unless (or (null body) (%text-or-key-p body))
    (%refuse "the BODY must be NIL, a string or (:key KEY :args PLIST), not ~S" body))
  (%check-link link)
  (unless (or (null group-key) (and (stringp group-key) (plusp (length group-key))))
    (%refuse "the GROUP-KEY must be NIL or a non-empty string, not ~S" group-key))
  ;; The id is a v6 UUID and the stamp is the clock tick it was made from.
  (multiple-value-bind (uuid vid) (clock:new-id)
    (%make-notification :id uuid :recipient recipient :kind kind
                        :title title :body body :link link :group-key group-key
                        :count 1 :stamp vid :created-at (get-universal-time))))

;;; --- kinds and delivery -----------------------------------------------------------------

(defparameter +deliveries+ '(:in-app :email :both :none)
  "Where a notification of a kind goes for a user: their list, email, both, or nowhere.")

(deftype delivery () '(member :in-app :email :both :none))

(defvar *kinds* (make-hash-table :test 'eq)
  "Each kind DEFINE-NOTIFICATION-KIND has declared, to (:default DELIVERY :label LABEL).")

(define-condition unknown-notification-kind (error)
  ((kind :initarg :kind :reader unknown-notification-kind-kind))
  (:report (lambda (c s)
             (format s "hyperion/notifications: ~S is not a notification kind; declare it with DEFINE-NOTIFICATION-KIND"
                     (unknown-notification-kind-kind c))))
  (:documentation "NOTIFY was given a kind no DEFINE-NOTIFICATION-KIND declared. A misspelt
kind is refused rather than sent with some default delivery."))

(defun define-notification-kind (kind &key (default :in-app) label)
  "Declare KIND, a keyword, with DEFAULT, the delivery a user gets until they choose one (one of
+DELIVERIES+), and LABEL, what the delivery form calls it: a string or (:KEY KEY :ARGS PLIST),
by default KIND's name. Declaring a kind again replaces its default and label. Returns KIND."
  (unless (keywordp kind) (%refuse "a notification KIND must be a keyword, not ~S" kind))
  (unless (typep default 'delivery)
    (%refuse "a kind's DEFAULT must be one of ~{~S~^, ~}, not ~S" +deliveries+ default))
  (unless (or (null label) (%text-or-key-p label))
    (%refuse "a kind's LABEL must be a string or (:key KEY :args PLIST), not ~S" label))
  (setf (gethash kind *kinds*)
        (list :default default :label (or label (string-downcase (symbol-name kind)))))
  kind)

(defun %kind (kind)
  (or (gethash kind *kinds*) (error 'unknown-notification-kind :kind kind)))

(defun notification-kinds ()
  "Every declared kind, sorted by name."
  (sort (loop for k being the hash-keys of *kinds* collect k) #'string< :key #'symbol-name))

(defun notification-kind-default (kind)
  "KIND's default delivery. Signals UNKNOWN-NOTIFICATION-KIND for an undeclared kind."
  (getf (%kind kind) :default))

(defun notification-kind-label (kind)
  "KIND's label, a string or (:KEY KEY :ARGS PLIST)."
  (getf (%kind kind) :label))

;;; --- the store protocol -----------------------------------------------------------------

(defgeneric notification-put (store notification)
  (:documentation "Store NOTIFICATION and return the item that holds it now.

With a GROUP-KEY, when RECIPIENT has an unread item with the same group key, that item takes
the new title, body, link, kind, stamp and created-at, its COUNT goes up by one, and it keeps
its id; NOTIFICATION itself is not stored. Otherwise NOTIFICATION is stored as a new item with
COUNT 1. A read item is never collapsed into, so after the user reads it the next notification
with that key starts a new item. A notification without a group key never collapses."))

(defgeneric notification-list (store recipient &key unread-only limit before)
  (:documentation "RECIPIENT's notifications, newest first (by STAMP), at most LIMIT of them,
only those with a stamp below BEFORE when it is given, and only unread ones with UNREAD-ONLY.
Returns (values ITEMS MORE), MORE true when older items are left."))

(defgeneric unread-count (store recipient)
  (:documentation "How many of RECIPIENT's items are unread. An item collapsed from several
notifications counts once."))

(defgeneric mark-read (store recipient id)
  (:documentation "Mark RECIPIENT's item ID read. True when it was unread; NIL when it was read
already or is not RECIPIENT's item, which includes another recipient's id."))

(defgeneric mark-all-read (store recipient)
  (:documentation "Mark every unread item of RECIPIENT read. Returns how many changed."))

(defgeneric prune-notifications (store &key read-before unread-before)
  (:documentation "Delete read items read before READ-BEFORE, and, when UNREAD-BEFORE is given,
unread items created before it. Both are universal times. Returns how many were deleted."))

(defgeneric delivery-ref (store recipient kind)
  (:documentation "The delivery RECIPIENT chose for KIND, or NIL when they have not chosen."))

(defgeneric delivery-set (store recipient kind delivery)
  (:documentation "Record DELIVERY, one of +DELIVERIES+, as RECIPIENT's choice for KIND, or
forget the choice when DELIVERY is NIL, so the kind's default applies again."))

(defun %check-delivery-choice (kind delivery)
  (%kind kind)
  (unless (or (null delivery) (typep delivery 'delivery))
    (%refuse "a DELIVERY must be one of ~{~S~^, ~} or NIL, not ~S" +deliveries+ delivery)))

;;; --- the memory store -------------------------------------------------------------------

(defclass memory-notification-store ()
  ((items :initform (make-hash-table :test 'equal) :reader %items
          :documentation "Recipient to their items, a list, unordered.")
   (choices :initform (make-hash-table :test 'equal) :reader %choices
            :documentation "(recipient . kind) to delivery.")
   (lock :initform (bt:make-lock "hyperion/notifications memory store") :reader %lock))
  (:documentation "A store in this process's memory: for tests, and for an app with one
process that does not need notifications to survive a restart."))

(defun make-memory-notification-store ()
  (make-instance 'memory-notification-store))

(defun %copy (n)
  "A copy of N, so a caller holding an item cannot change what the store holds."
  (copy-structure n))

(defmethod notification-put ((store memory-notification-store) (n notification))
  (bt:with-lock-held ((%lock store))
    (let* ((recipient (notification-recipient n))
           (key (notification-group-key n))
           (into (and key (find-if (lambda (i) (and (null (notification-read-at i))
                                                    (equal key (notification-group-key i))))
                                   (gethash recipient (%items store))))))
      (cond (into
             (setf (notification-kind into) (notification-kind n)
                   (notification-title into) (notification-title n)
                   (notification-body into) (notification-body n)
                   (notification-link into) (notification-link n)
                   (notification-stamp into) (notification-stamp n)
                   (notification-created-at into) (notification-created-at n))
             (incf (notification-count into))
             (%copy into))
            (t (push (%copy n) (gethash recipient (%items store)))
               (%copy n))))))

(defmethod notification-list ((store memory-notification-store) recipient
                              &key unread-only (limit 20) before)
  (bt:with-lock-held ((%lock store))
    (let* ((all (sort (remove-if-not (lambda (i)
                                       (and (or (not unread-only) (null (notification-read-at i)))
                                            (or (null before) (< (notification-stamp i) before))))
                                     (gethash recipient (%items store)))
                      #'> :key #'notification-stamp))
           (page (subseq all 0 (min limit (length all)))))
      (values (mapcar #'%copy page) (> (length all) (length page))))))

(defmethod unread-count ((store memory-notification-store) recipient)
  (bt:with-lock-held ((%lock store))
    (count-if-not #'notification-read-at (gethash recipient (%items store)))))

(defmethod mark-read ((store memory-notification-store) recipient id)
  (bt:with-lock-held ((%lock store))
    (let ((i (find id (gethash recipient (%items store)) :key #'notification-id :test #'equal)))
      (when (and i (null (notification-read-at i)))
        (setf (notification-read-at i) (get-universal-time))
        t))))

(defmethod mark-all-read ((store memory-notification-store) recipient)
  (bt:with-lock-held ((%lock store))
    (let ((now (get-universal-time)) (n 0))
      (dolist (i (gethash recipient (%items store)) n)
        (unless (notification-read-at i)
          (setf (notification-read-at i) now)
          (incf n))))))

(defmethod prune-notifications ((store memory-notification-store) &key read-before unread-before)
  (bt:with-lock-held ((%lock store))
    (let ((deleted 0))
      (maphash (lambda (recipient items)
                 (let ((keep (remove-if (lambda (i)
                                          (let ((read (notification-read-at i)))
                                            (or (and read read-before (< read read-before))
                                                (and (null read) unread-before
                                                     (< (notification-created-at i) unread-before)))))
                                        items)))
                   (incf deleted (- (length items) (length keep)))
                   (setf (gethash recipient (%items store)) keep)))
               (%items store))
      deleted)))

(defmethod delivery-ref ((store memory-notification-store) recipient kind)
  (bt:with-lock-held ((%lock store))
    (values (gethash (cons recipient kind) (%choices store)))))

(defmethod delivery-set ((store memory-notification-store) recipient kind delivery)
  (%check-delivery-choice kind delivery)
  (bt:with-lock-held ((%lock store))
    (if delivery
        (setf (gethash (cons recipient kind) (%choices store)) delivery)
        (remhash (cons recipient kind) (%choices store)))
    delivery))

;;; --- notify -----------------------------------------------------------------------------

(defvar *notification-email* nil
  "The function NOTIFY sends email with, when the delivery includes email and NOTIFY is given
no :EMAIL: a function of (RECIPIENT NOTIFICATION). hyperion cannot depend on hermes, a
satellite, so the app supplies it, usually with hermes:

    (setf hyperion/notifications:*notification-email*
          (lambda (recipient n)
            (hermes:deliver *mailer*
                            (hermes:make-email :to (my-app:email-of recipient)
                                               :from \"noreply@example.com\"
                                               :subject (my-app:notification-subject n)
                                               :text (my-app:notification-text n)))))

The function renders the notification's title and body itself, because only the app knows the
recipient's address and language.")

(define-condition notification-email-failed (error)
  ((recipient :initarg :recipient :reader notification-email-failed-recipient)
   (kind :initarg :kind :reader notification-email-failed-kind)
   (cause :initarg :cause :reader notification-email-failed-cause))
  (:report (lambda (c s)
             (format s "hyperion/notifications: the ~S notification for ~A was not emailed: ~A"
                     (notification-email-failed-kind c) (notification-email-failed-recipient c)
                     (notification-email-failed-cause c))))
  (:documentation "NOTIFY could not email a notification: there is no email function, or it
signalled. The in-app item, when the delivery includes one, is already stored. Signalled with a
CONTINUE restart, which makes NOTIFY return as if the email had been sent."))

(defun %email-failed (recipient kind cause)
  (log:warn "hyperion/notifications: email failed" :kind kind :recipient recipient)
  (restart-case (error 'notification-email-failed :recipient recipient :kind kind :cause cause)
    (continue ()
      :report "Return from NOTIFY without the email."
      nil)))

(defun notify (store recipient kind &key title body link group-key (email *notification-email*))
  "Tell RECIPIENT about something of KIND, as their delivery choice for KIND says, or the kind's
default when they have none (DEFINE-NOTIFICATION-KIND):
- :IN-APP or :BOTH stores it in STORE, collapsing it into an unread item with the same
  GROUP-KEY (NOTIFICATION-PUT);
- :EMAIL or :BOTH calls EMAIL, a function of (RECIPIENT NOTIFICATION), by default
  *NOTIFICATION-EMAIL*;
- :NONE does neither.
The in-app item is stored before the email is sent, so a failed email does not lose it: the
failure is logged, without the text, and signalled as NOTIFICATION-EMAIL-FAILED with a CONTINUE
restart. TITLE, BODY, LINK and GROUP-KEY are checked as MAKE-NOTIFICATION checks them, and an
undeclared KIND is refused (UNKNOWN-NOTIFICATION-KIND).

Returns the stored item, or NIL when nothing was stored."
  (%kind kind)
  (let* ((n (make-notification recipient kind :title title :body body :link link
                                              :group-key group-key))
         (delivery (or (delivery-ref store recipient kind) (notification-kind-default kind)))
         (stored (and (member delivery '(:in-app :both)) (notification-put store n))))
    (when (member delivery '(:email :both))
      (if (null email)
          (%email-failed recipient kind "no email function: pass :email or set *notification-email*")
          (handler-case (funcall email recipient n)
            (error (e) (%email-failed recipient kind e)))))
    stored))

;;; --- text -------------------------------------------------------------------------------

(defparameter +english+
  '(:notifications/title "Notifications"
    :notifications/unread.one "1 unread notification"
    :notifications/unread.other "{count} unread notifications"
    :notifications/none "You have no notifications."
    :notifications/mark-read "Mark as read"
    :notifications/mark-all-read "Mark all as read"
    :notifications/older "Older"
    :notifications/new "New"
    :notifications/times "{count} times"
    :notifications/delivery "How you get each kind of notification"
    :notifications/delivery-in-app "In the app"
    :notifications/delivery-email "By email"
    :notifications/delivery-both "In the app and by email"
    :notifications/delivery-none "Not at all"
    :notifications/save "Save"
    :notifications/saved "Saved.")
  "The English text for every key this file looks up; used when there is no source, or when the
source has the key in neither the requested nor its default locale.")

(defun %text (locale key source &rest args)
  (if (and source (i18n:translation-exists-p source locale key))
      (apply #'i18n:translate source locale key args)
      (i18n:interpolate (getf +english+ key) args)))

(defun %unread-sentence (locale source count)
  "\"N unread notifications\", in the plural form LOCALE uses for COUNT."
  (if (and source (or (i18n:translation-exists-p source locale "notifications/unread.other")
                      (i18n:translation-exists-p source locale :notifications/unread)))
      (i18n:translate-plural source locale :notifications/unread count)
      (i18n:interpolate (getf +english+ (if (= count 1)
                                           :notifications/unread.one
                                           :notifications/unread.other))
                        (list :count count))))

(defun %render-text (x locale source)
  "A notification's title, body or a kind's label as text: the string itself, or the key
translated with its arguments. A key the source lacks shows as its name, so a missing
translation is visible rather than blank."
  (cond ((stringp x) x)
        ((consp x)
         (let ((key (getf x :key)) (args (getf x :args)))
           (if (and source (i18n:translation-exists-p source locale key))
               (apply #'i18n:translate source locale key args)
               (string-downcase (if (symbolp key) (symbol-name key) key)))))
        (t "")))

;;; --- the components ---------------------------------------------------------------------
;;;
;;; The bell polls. Its poller sends the count it last showed, and the route answers 204 (htmx 2
;;; swaps nothing for a 204) while the count is the same. When the count changes, the answer
;;; replaces the visible count and the text of one status region out of band, and replaces the
;;; poller with one carrying the new count. The status region (role="status", aria-live="polite")
;;; stays in the page, so a screen reader announces the new count once, when it changes, and not
;;; on every poll.
;;;
;;; A later version may push the count over SSE. The bell and the router are the only places
;;; that know how the count arrives, so an app that calls NOTIFICATION-BELL and mounts
;;; NOTIFICATION-ROUTER will not change its calls for that.

(defvar *prefix* "/notifications"
  "Where the app mounts NOTIFICATION-ROUTER, and so where the components send their requests.
Bind or pass :PREFIX when it is mounted elsewhere.")

(defparameter +bell-id+ "hyperion-notification-bell")
(defparameter +count-id+ "hyperion-notification-count")
(defparameter +status-id+ "hyperion-notification-status")
(defparameter +poller-id+ "hyperion-notification-poller")
(defparameter +panel-id+ "hyperion-notification-panel")

(defun %check-poll-seconds (seconds)
  (unless (and (integerp seconds) (<= 1 seconds 86400))
    (%refuse "POLL-SECONDS must be a whole number of seconds from 1 to 86400, not ~S" seconds))
  seconds)

(defun %url (prefix path &optional query)
  (format nil "~A~A~@[?~A~]" (string-right-trim "/" prefix) path query))

(defun %poller (count prefix poll-seconds &key oob)
  (spin:with-html
    (:span :id +poller-id+ :hidden t
           :hx-swap-oob (and oob "true")
           :hx-get (%url prefix "/count" (format nil "seen=~D" count))
           :hx-trigger (format nil "every ~Ds" (%check-poll-seconds poll-seconds))
           :hx-swap "none")))

(defun notification-bell (count &key (prefix *prefix*) (poll-seconds 60) (locale "en")
                                     (source i18n:*translation-source*))
  "Write the bell into SPINNERET:*HTML*: a button showing COUNT, the recipient's unread count,
that loads NOTIFICATION-PANEL into the element with id hyperion-notification-panel, which the
app places where the list should open. Its accessible name is the whole sentence, \"3 unread
notifications\". A hidden status region (role=\"status\", aria-live=\"polite\") holds the same
sentence and changes only when the count does, so a screen reader announces each change once.

The count is polled every POLL-SECONDS, a whole number from 1 to 86400 (a number, not an htmx
interval string, so it cannot be misread: #422). PREFIX is where NOTIFICATION-ROUTER is mounted."
  (let ((sentence (%unread-sentence locale source count)))
    (spin:with-html
      (:div :id +bell-id+ :class "hyperion-notification-bell"
        (:button :type "button" :class "hyperion-notification-button"
                 :aria-label sentence
                 :hx-get (%url prefix "/list") :hx-target (format nil "#~A" +panel-id+)
                 :hx-swap "innerHTML"
          (:span :class "hyperion-notification-label" (%text locale :notifications/title source))
          " "
          (:span :id +count-id+ :class "hyperion-notification-count" :aria-hidden "true"
                 (princ-to-string count)))
        (:span :id +status-id+ :class "hyperion-visually-hidden" :role "status"
               :aria-live "polite" sentence)
        (%poller count prefix poll-seconds)))))

(defun %bell-update (count prefix poll-seconds locale source)
  "The out-of-band parts that bring a bell to COUNT: its count, its status sentence, its poller."
  (let ((sentence (%unread-sentence locale source count)))
    (spin:with-html
      (:span :id +count-id+ :hx-swap-oob "innerHTML" (princ-to-string count))
      (:span :id +status-id+ :hx-swap-oob "innerHTML" sentence)
      (%poller count prefix poll-seconds :oob t))))

(defun %iso-time (universal-time)
  (multiple-value-bind (s mi h d mo y) (decode-universal-time universal-time 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ" y mo d h mi s)))

(defun %shown-time (universal-time)
  (multiple-value-bind (s mi h d mo y) (decode-universal-time universal-time 0)
    (declare (ignore s))
    (format nil "~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D UTC" y mo d h mi)))

(defun notification-panel (items &key more (prefix *prefix*) (locale "en")
                                      (source i18n:*translation-source*))
  "Write the list of ITEMS, notifications newest first, into SPINNERET:*HTML*, as the contents of
the element with id hyperion-notification-panel. Each unread item has a \"Mark as read\" button;
the list has \"Mark all as read\", and \"Older\" when MORE is true. Buttons are real buttons and
links real links, so the list is keyboard operable. Each POST carries the CSRF token in the
X-CSRF-Token header (HYPERION/CSRF:TOKEN-HEADERS)."
  (let ((target (format nil "#~A" +panel-id+))
        (headers (csrf:token-headers)))
    (spin:with-html
      (:section :class "hyperion-notification-list"
                :aria-label (%text locale :notifications/title source)
        (if (null items)
            (:p :class "hyperion-notification-empty" (%text locale :notifications/none source))
            (progn
              (when (some (lambda (i) (null (notification-read-at i))) items)
                (:button :type "button" :class "hyperion-notification-mark-all"
                         :hx-post (%url prefix "/read-all") :hx-target target :hx-swap "innerHTML"
                         :hx-headers headers
                  (%text locale :notifications/mark-all-read source)))
              (:ul
                (dolist (i items)
                  (let ((title (%render-text (notification-title i) locale source))
                        (body (and (notification-body i)
                                   (%render-text (notification-body i) locale source)))
                        (unread (null (notification-read-at i))))
                    (:li :class (if unread
                                    "hyperion-notification hyperion-notification-unread"
                                    "hyperion-notification")
                      (:p :class "hyperion-notification-title"
                        (when unread
                          (:span :class "hyperion-notification-new"
                            (%text locale :notifications/new source)))
                        (if (notification-link i)
                            (:a :href (notification-link i) title)
                            (:span title))
                        (when (> (notification-count i) 1)
                          (:span :class "hyperion-notification-times"
                            (%text locale :notifications/times source
                                   :count (notification-count i)))))
                      (when body (:p :class "hyperion-notification-body" body))
                      (:p :class "hyperion-notification-time"
                        (:time :datetime (%iso-time (notification-created-at i))
                          (%shown-time (notification-created-at i))))
                      (when unread
                        (:button :type "button" :class "hyperion-notification-mark-read"
                                 :hx-post (%url prefix "/read") :hx-target target
                                 :hx-swap "innerHTML" :hx-headers headers
                                 :hx-vals (format nil "{\"id\": \"~A\"}" (notification-id i))
                          (%text locale :notifications/mark-read source)))))))
              (when more
                (:button :type "button" :class "hyperion-notification-older"
                         :hx-get (%url prefix "/list"
                                       (format nil "before=~D"
                                               (notification-stamp (car (last items)))))
                         :hx-target target :hx-swap "innerHTML"
                  (%text locale :notifications/older source)))))))))

(defun %delivery-label (delivery locale source)
  (%text locale (ecase delivery
                  (:in-app :notifications/delivery-in-app)
                  (:email :notifications/delivery-email)
                  (:both :notifications/delivery-both)
                  (:none :notifications/delivery-none))
         source))

(defun delivery-form (store recipient &key (prefix *prefix*) saved (locale "en")
                                          (source i18n:*translation-source*))
  "Write a form into SPINNERET:*HTML* with one choice per declared kind of how RECIPIENT gets it,
showing their stored choice or the kind's default. It posts to NOTIFICATION-ROUTER's /delivery
and is replaced by the answer; SAVED adds a line saying the choices were saved."
  (spin:with-html
    (:form :class "hyperion-notification-delivery" :hx-post (%url prefix "/delivery")
           :hx-swap "outerHTML" :hx-headers (csrf:token-headers)
      (:fieldset
        (:legend (%text locale :notifications/delivery source))
        (dolist (kind (notification-kinds))
          (let* ((name (string-downcase (symbol-name kind)))
                 (field (format nil "kind-~A" name))
                 (current (or (delivery-ref store recipient kind)
                              (notification-kind-default kind))))
            (:p
              (:label :for field (%render-text (notification-kind-label kind) locale source))
              " "
              (:select :id field :name field
                (dolist (d +deliveries+)
                  (:option :value (string-downcase (symbol-name d)) :selected (eq d current)
                    (%delivery-label d locale source))))))))
      (:button :type "submit" (%text locale :notifications/save source))
      (when saved
        (:p :role "status" (%text locale :notifications/saved source))))))

;;; --- the routes -------------------------------------------------------------------------

(defun %html (body &optional (status 200))
  (list status '(:content-type "text/html; charset=utf-8") (list body)))

(defun %parse-integer (text)
  (and (stringp text) (plusp (length text)) (<= (length text) 30)
       (every #'digit-char-p text)
       (parse-integer text)))

(defun notification-router (store &key recipient-fn (prefix *prefix*) (poll-seconds 60)
                                       (page-size 20) (locale-fn (constantly "en"))
                                       (source-fn (lambda () i18n:*translation-source*)))
  "A router for the components' requests. Mount it at PREFIX:

    (router:router (router:mount \"/notifications\"
                     (notification-router store :recipient-fn #'my-app:signed-in-user-id)))

RECIPIENT-FN is required: a function of the request env returning the signed-in recipient, or
NIL, which is answered 401. The recipient is never read from the request itself. LOCALE-FN maps
the env to a locale and SOURCE-FN returns the translation source. The routes:
- GET /count?seen=N: 204 while the unread count is N, otherwise the bell's out-of-band update;
- GET /list[?before=STAMP]: NOTIFICATION-PANEL, PAGE-SIZE items;
- POST /read with id: marks that item read, if it is the recipient's, and answers the panel and
  the bell's update;
- POST /read-all: marks all read, and answers the same;
- GET /delivery and POST /delivery: DELIVERY-FORM, and saving it.
The POST routes rely on the app's CSRF check (HYPERION/CSRF:WRAP-CSRF), as every route does."
  (unless (functionp recipient-fn)
    (%refuse "NOTIFICATION-ROUTER needs :RECIPIENT-FN, a function of the request env"))
  (%check-poll-seconds poll-seconds)
  (labels ((with-recipient (env fn)
             (let ((recipient (funcall recipient-fn env)))
               (if (and (stringp recipient) (plusp (length recipient)))
                   (funcall fn recipient (funcall locale-fn env) (funcall source-fn))
                   (list 401 '(:content-type "text/plain; charset=utf-8") (list "Not signed in")))))
           (panel-and-bell (recipient locale source &key before)
             (multiple-value-bind (items more)
                 (notification-list store recipient :limit page-size :before before)
               (%html (spin:with-html-string
                        (notification-panel items :more more :prefix prefix
                                                  :locale locale :source source)
                        (%bell-update (unread-count store recipient) prefix poll-seconds
                                      locale source))))))
    (router:router
     (router:route
      :get "/count"
      (lambda (env)
        (with-recipient env
          (lambda (recipient locale source)
            (let ((count (unread-count store recipient)))
              (if (eql count (%parse-integer (http:query-param env "seen")))
                  (list 204 '() '())
                  (%html (spin:with-html-string
                           (%bell-update count prefix poll-seconds locale source))))))))
      :name :notifications-count)
     (router:route
      :get "/list"
      (lambda (env)
        (with-recipient env
          (lambda (recipient locale source)
            (panel-and-bell recipient locale source
                            :before (%parse-integer (http:query-param env "before"))))))
      :name :notifications-list)
     (router:route
      :post "/read"
      (lambda (env)
        (with-recipient env
          (lambda (recipient locale source)
            (let ((id (http:form-param (http:body-string env) "id")))
              (when id (mark-read store recipient id))
              (panel-and-bell recipient locale source)))))
      :name :notifications-read)
     (router:route
      :post "/read-all"
      (lambda (env)
        (with-recipient env
          (lambda (recipient locale source)
            (mark-all-read store recipient)
            (panel-and-bell recipient locale source))))
      :name :notifications-read-all)
     (router:route
      :get "/delivery"
      (lambda (env)
        (with-recipient env
          (lambda (recipient locale source)
            (%html (spin:with-html-string
                     (delivery-form store recipient :prefix prefix :locale locale :source source))))))
      :name :notifications-delivery)
     (router:route
      :post "/delivery"
      (lambda (env)
        (with-recipient env
          (lambda (recipient locale source)
            (let ((body (http:body-string env)))
              ;; Only declared kinds and the four deliveries are read; any other field or value
              ;; is ignored, so nothing from the request becomes a kind or a delivery.
              (dolist (kind (notification-kinds))
                (let* ((value (http:form-param body (format nil "kind-~(~A~)" (symbol-name kind))))
                       (delivery (find value +deliveries+ :test #'string-equal :key #'symbol-name)))
                  (when delivery (delivery-set store recipient kind delivery)))))
            (%html (spin:with-html-string
                     (delivery-form store recipient :prefix prefix :saved t
                                                    :locale locale :source source))))))
      :name :notifications-delivery-save))))

;;; --- retention --------------------------------------------------------------------------

(defun prune-notifications-job (store &key (read-days 30) unread-days)
  "A job function for AION/SCHEDULE:DEFINE-JOB that deletes read notifications read more than
READ-DAYS ago, and, when UNREAD-DAYS is given, unread ones created more than UNREAD-DAYS ago.
It returns (:DELETED N) for the run log.

    (aion/schedule:define-job scheduler \"prune-notifications\"
                              (prune-notifications-job store :read-days 30)
                              :schedule '(:daily (3 0)))"
  (flet ((days-ago (days) (and days (- (get-universal-time) (* days 86400)))))
    (unless (and (integerp read-days) (plusp read-days))
      (%refuse "READ-DAYS must be a positive whole number, not ~S" read-days))
    (unless (or (null unread-days) (and (integerp unread-days) (plusp unread-days)))
      (%refuse "UNREAD-DAYS must be NIL or a positive whole number, not ~S" unread-days))
    (lambda (run &rest args)
      (declare (ignore run args))
      (list :deleted (prune-notifications store :read-before (days-ago read-days)
                                                :unread-before (days-ago unread-days))))))
