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

(defgeneric deliver (provider message)
  (:documentation "Deliver MESSAGE (an EMAIL or SMS) via PROVIDER. Returns a DELIVERY-RESULT
on success; signals DELIVERY-FAILURE on a rejected/failed request, UNSUPPORTED-MESSAGE if the
provider does not implement the message's channel, or CONFIGURATION-ERROR when a required
credential is missing."))

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
;;; HERMES_TRANSPORT=dev|log forces the dev transport for every channel (local dev).
;;; A backend registers a no-arg constructor thunk under its name; adding a vendor is a new
;;; class + one REGISTER-IMPL, with the selection layer staying neutral.

(defvar *impls* (make-hash-table :test #'equal)
  "Map of \"channel/name\" -> a thunk returning a fresh provider.")

(defun %impl-key (channel name)
  (format nil "~(~A~)/~(~A~)" channel name))

(defun register-impl (channel name constructor)
  "Register CONSTRUCTOR (a thunk returning a fresh provider) for CHANNEL (:email, :sms or :telegram)
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

(defun send (message)
  "Deliver MESSAGE via the env-configured provider for its channel (EMAIL -> email provider,
SMS -> sms provider, TELEGRAM-MESSAGE -> Telegram provider). The everyday entry point: no
explicit provider needed. Logs the attempt at :debug and any DELIVERY-FAILURE at :error (quiet
at default levels; see aion/log). The lines carry the channel, the provider, the status and the
provider's message id, never the message's text or recipient."
  (let* ((channel (etypecase message (email :email) (sms :sms) (telegram-message :telegram)))
         (provider (ecase channel
                     (:email (email-provider-from-env))
                     (:sms (sms-provider-from-env))
                     (:telegram (telegram-provider-from-env)))))
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
