;;;; protocol.lisp --- the provider protocol + env selection.
;;;;
;;;; A PROVIDER is a class; DELIVER is a generic that dispatches on BOTH provider and message,
;;;; so "this provider can send that kind of message" is CLOS multiple dispatch: (sendgrid .
;;;; email) and (twilio . sms) are methods; anything else falls to the default, which signals
;;;; UNSUPPORTED-MESSAGE. SEND is the everyday entry point: pick the env-configured provider
;;;; for the message's channel and deliver.

(cl:in-package #:hermes)

;;; --- Provider protocol ----------------------------------------------------

(defclass provider () ()
  (:documentation "Abstract base for anything that can DELIVER a message."))

(defclass email-provider (provider) ()
  (:documentation "A provider that can deliver EMAILs."))

(defclass sms-provider (provider) ()
  (:documentation "A provider that can deliver SMSes."))

(defclass telegram-provider (provider) ()
  (:documentation "A provider that can deliver TELEGRAM-MESSAGEs (#778)."))

(defclass facebook-provider (provider) ()
  (:documentation "A provider that can deliver FACEBOOK-POSTs to Facebook Pages (#822)."))

(defgeneric facebook-page-health (provider page)
  (:documentation "Whether PROVIDER can post to the Facebook Page PAGE (its id), for an admin
screen (#822). Returns two values: a status and the Page's name when Facebook gave it. STATUS is
:CONNECTED, :RECONNECT (the Page token no longer works, or lacks pages_manage_posts: send an
admin through the connect flow again), :NOT-PERMITTED (the token works but may not post to this
Page), :WRONG-PAGE (the token stored for PAGE belongs to another Page), :NOT-FOUND (no such
Page, or the token cannot see it), or :NOT-CONNECTED (no token is stored for PAGE). A PAGE that
is not a Page id signals INVALID-MESSAGE; a rate limit or a network failure is signalled, not
answered."))

(defgeneric deliver (provider message)
  (:documentation "Deliver MESSAGE (an EMAIL or SMS) via PROVIDER. Returns a DELIVERY-RESULT
on success; signals DELIVERY-FAILURE on a rejected/failed request, UNSUPPORTED-MESSAGE if the
provider does not implement the message's channel, or CONFIGURATION-ERROR when a required
credential is missing.

A method for EMAIL sends every header in EMAIL-HEADERS, or, for a provider that cannot send
extra headers, signals INVALID-MESSAGE when EMAIL-HEADERS is not empty. It never drops them
silently: an unsubscribe header that was set and not sent is not visible to anyone (#106)."))

(defmethod deliver ((p provider) message)
  "Default: the provider does not handle this kind of message."
  (error 'unsupported-message :provider (class-name (class-of p)) :message message))

(defgeneric edit-sent-message (provider result text &key parse-mode link-preview part)
  (:documentation "Replace the text of the message RESULT describes, a DELIVERY-RESULT from an
earlier DELIVER, with TEXT. PARSE-MODE and LINK-PREVIEW are as for MAKE-TELEGRAM-MESSAGE. PART
is :TEXT for a text message or :CAPTION for a photo's caption. Returns a DELIVERY-RESULT with
STATUS :EDITED. Needs RESULT's DESTINATION and ID; signals INVALID-MESSAGE when either is
missing, and DELIVERY-FAILURE when the provider refuses (#778)."))

(defgeneric delete-sent-message (provider result)
  (:documentation "Delete the message RESULT describes, a DELIVERY-RESULT from an earlier
DELIVER. Returns T. Needs RESULT's DESTINATION and ID; signals INVALID-MESSAGE when either is
missing, and DELIVERY-FAILURE when the provider refuses (#778)."))

(defgeneric telegram-can-post (provider chat)
  (:documentation "Whether the bot behind PROVIDER can post to CHAT (an integer chat id or an
\"@username\"), for an admin screen: :YES, :NOT-MEMBER (the bot is not in the chat, or cannot
see it), or :NOT-PERMITTED (it is in the chat but may not post there) (#778). A group that became
a supergroup is not answered: the Telegram backend signals TELEGRAM-CHAT-MIGRATED, whose
TELEGRAM-CHAT-MIGRATED-MIGRATE-TO-CHAT-ID is the chat id to store instead (#788)."))

(defgeneric telegram-added-chats (provider &key confirm)
  (:documentation "The chats the bot behind PROVIDER was added to or removed from recently, as a
list of TELEGRAM-ADDED-CHAT, one per chat with its latest change, oldest first (#794). This is how
an app finds the numeric id of a private group or channel that operators share as a t.me/+
invite link, which no Bot API method resolves: an operator adds the bot, then the app lists these
and the operator picks the chat by its title.

The Telegram backend reads the bot's pending updates with getUpdates. Telegram keeps an update for
24 hours, so a bot added longer ago than that is not listed. Without CONFIRM, the updates are read
and left pending, so another reader of the same bot still receives them; only the first 100
pending updates are read. With CONFIRM true, every pending update is read and confirmed, and
Telegram then drops them, for every reader of the bot. Signals TELEGRAM-WEBHOOK-ACTIVE when the
bot has a webhook set."))

(defmethod edit-sent-message ((p provider) result text &key parse-mode link-preview part)
  "Default: the provider cannot edit a sent message."
  (declare (ignore text parse-mode link-preview part))
  (error 'unsupported-message :provider (class-name (class-of p)) :message result))

(defmethod delete-sent-message ((p provider) result)
  "Default: the provider cannot delete a sent message."
  (error 'unsupported-message :provider (class-name (class-of p)) :message result))

;;; --- Provider selection from the environment ------------------------------
;;; HERMES_EMAIL_IMPL picks the email backend (default "sendgrid");
;;; HERMES_SMS_IMPL   picks the SMS backend  (default "twilio");
;;; HERMES_TELEGRAM_IMPL picks the Telegram backend (default "telegram");
;;; HERMES_FACEBOOK_IMPL picks the Facebook Page backend (default "facebook");
;;; HERMES_TRANSPORT=dev|log forces the dev transport for every channel (local dev).
;;; A backend registers a no-arg constructor thunk under its name; adding a vendor is a new
;;; class + one REGISTER-IMPL, with the selection layer staying neutral.

(defvar *impls* (make-hash-table :test #'equal)
  "Map of \"channel/name\" -> a thunk returning a fresh provider.")

(defun %impl-key (channel name)
  (format nil "~(~A~)/~(~A~)" channel name))

(defun register-impl (channel name constructor)
  "Register CONSTRUCTOR (a thunk returning a fresh provider) for CHANNEL (:email, :sms, :telegram
or :facebook)
under NAME (a string). Returns NAME."
  (setf (gethash (%impl-key channel name) *impls*) constructor)
  name)

(defun %selected-name (channel default-name env-var)
  "The provider name for CHANNEL: HERMES_TRANSPORT (dev|log) wins for local dev, else ENV-VAR,
else DEFAULT-NAME."
  (let ((global (uiop:getenv "HERMES_TRANSPORT")))
    (cond ((and global (member (string-downcase global) '("dev" "log") :test #'string=)) "dev")
          (t (or (uiop:getenv env-var) default-name)))))

(defun %make-impl (channel default-name env-var)
  (let* ((name (%selected-name channel default-name env-var))
         (ctor (gethash (%impl-key channel name) *impls*)))
    (unless ctor
      (error 'configuration-error
             :missing (format nil "no ~(~A~) provider registered under ~S (set ~A)"
                              channel name env-var)))
    (funcall ctor)))

(defun email-provider-from-env ()
  "The email provider named by HERMES_EMAIL_IMPL (default \"sendgrid\"; \"dev\" under HERMES_TRANSPORT)."
  (%make-impl :email "sendgrid" "HERMES_EMAIL_IMPL"))

(defun sms-provider-from-env ()
  "The SMS provider named by HERMES_SMS_IMPL (default \"twilio\"; \"dev\" under HERMES_TRANSPORT)."
  (%make-impl :sms "twilio" "HERMES_SMS_IMPL"))

(defun telegram-provider-from-env ()
  "The Telegram provider named by HERMES_TELEGRAM_IMPL (default \"telegram\"; \"dev\" under HERMES_TRANSPORT)."
  (%make-impl :telegram "telegram" "HERMES_TELEGRAM_IMPL"))

(defun facebook-provider-from-env ()
  "The Facebook Page provider named by HERMES_FACEBOOK_IMPL (default \"facebook\"; \"dev\" under
HERMES_TRANSPORT) (#822)."
  (%make-impl :facebook "facebook" "HERMES_FACEBOOK_IMPL"))

(defun send (message)
  "Deliver MESSAGE via the env-configured provider for its channel (EMAIL -> email provider,
SMS -> sms provider, TELEGRAM-MESSAGE -> Telegram provider, FACEBOOK-POST -> Facebook
provider). The everyday entry point: no
explicit provider needed. Logs the attempt at :debug and any DELIVERY-FAILURE at :error (quiet
at default levels; see aion/log). The lines carry the channel, the provider, the status and the
provider's message id, never the message's text or recipient."
  (let* ((channel (etypecase message
                    (email :email) (sms :sms) (telegram-message :telegram)
                    (facebook-post :facebook)))
         (provider (ecase channel
                     (:email (email-provider-from-env))
                     (:sms (sms-provider-from-env))
                     (:telegram (telegram-provider-from-env))
                     (:facebook (facebook-provider-from-env)))))
    (log:debug "hermes: sending" :channel channel :provider (class-name (class-of provider)))
    (handler-bind
        ((delivery-failure
           (lambda (c) (log:error "hermes: delivery failed" :channel channel
                                  :provider (delivery-failure-provider c)
                                  :status (delivery-failure-status c)))))
      (let ((result (deliver provider message)))
        (log:debug "hermes: sent" :channel channel :provider (delivery-result-provider result)
                   :id (delivery-result-id result) :status (delivery-result-status result))
        result))))

;;; --- Small config helper (used by backends) -------------------------------

(defun %require (value what)
  "VALUE if non-blank, else signal CONFIGURATION-ERROR naming WHAT."
  (if (and value (plusp (length value)))
      value
      (error 'configuration-error :missing what)))
