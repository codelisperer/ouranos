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

(deftype facebook-page-status ()
  "What FACEBOOK-PAGE-HEALTH says about a Page, for an admin screen (#822, #978). One of:

  :CONNECTED           the stored Page token works for this Page and has every scope in
                       +FACEBOOK-REQUIRED-SCOPES+.
  :MISSING-PERMISSION  the token works for this Page but lacks a scope hermes needs; the missing
                       scopes come back as FACEBOOK-PAGE-HEALTH's third value. An admin connects
                       again and grants them.
  :RECONNECT           the token no longer works: expired, revoked, the admin's password
                       changed, or the admin lost their role on the Page. An admin connects again.
  :NOT-PERMITTED       Facebook refused with a permission error: the admin cannot do the
                       CREATE_CONTENT task on this Page.
  :NOT-FOUND           no such Page, or the token cannot see it.
  :WRONG-PAGE          the token stored for this Page belongs to another Page.
  :NOT-CONNECTED       no token is stored for this Page."
  '(member :connected :missing-permission :reconnect :not-permitted :not-found :wrong-page
    :not-connected))

(defgeneric facebook-page-health (provider page)
  (:documentation "Whether PROVIDER can post to the Facebook Page PAGE (its id), for an admin
screen (#822). Returns up to three values: a FACEBOOK-PAGE-STATUS, the Page's name when Facebook
gave it, and for :MISSING-PERMISSION the list of missing scope names. Checking the scopes needs
the app's id and secret; without them a token that reads its own Page is :CONNECTED. A PAGE that
is not a Page id signals INVALID-MESSAGE; a rate limit or a network failure is signalled, not
answered."))

(defgeneric facebook-token-info (provider page)
  (:documentation "What Facebook says about the Page token PROVIDER holds for the Page PAGE (its
id), as a FACEBOOK-TOKEN-INFO, from the Graph API's debug_token (#978): whether it is valid, its
scopes, when it expires and when its access to data expires. An admin screen shows the last two
together, because a token that never expires still loses data access. Needs the app's id and
secret (debug_token is called with the app's token) and a stored token for PAGE, and signals
CONFIGURATION-ERROR without them. A PAGE that is not a Page id signals INVALID-MESSAGE."))

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

(defun %check-credential-url (value &key setting example credential carried-in appends-path)
  "Signal CONFIGURATION-ERROR unless VALUE is a URL this framework may send CREDENTIAL to
(#1077, #1092). Returns the parsed URI and, as a second value, the host that was approved as
local.

THE RULE IS AION/HTTP-CLIENT:CREDENTIAL-URL-REFUSAL, not written here (#1106). This function is
the part that is hermes': which condition to signal. The rule moved down beside LOCAL-HOST-P so
that hermes/blob could use it too -- blob does not depend on hermes core, and the alternative to
moving it was either a new dependency in that direction or a fifth copy of a rule that had
already grown three holes across two copies.

CARRIED-IN says where the credential travels, and is passed through: Telegram's bot token is in
the path of every request rather than in a header, and a refusal that described it wrongly would
be telling the reader something false about their own configuration.

WHAT CALLS THIS, AND WHAT DOES NOT. Twilio's API-BASE, SendGrid's ENDPOINT, Telegram's API-BASE,
Facebook's GRAPH-BASE and Stripe's API-BASE all do (#1106). hermes/blob's S3 endpoint does not
call THIS function, because it is in another system that must not depend on hermes core; it calls
the same rule in aion directly and signals BLOB-CONFIGURATION-ERROR. Facebook's DIALOG-BASE does
not: no credential is sent to it -- it is where a person's browser is sent -- so the rule about
carrying a credential in the clear has nothing to say about it."
  (multiple-value-bind (reason uri approved-local)
      (apply #'credential-url-refusal value
             :setting setting :example example :credential credential
             :appends-path appends-path
             ;; Passed only when given, so the default in CREDENTIAL-URL-REFUSAL is what decides
             ;; the common wording rather than a NIL from here.
             (when carried-in (list :carried-in carried-in)))
    (when reason
      (error 'configuration-error :missing reason))
    (values uri approved-local)))

(defun %call-with-url-check (provider url-slot verdict-slot check next)
  "Run NEXT -- a provider's CALL-NEXT-METHOD -- and then check the URL in URL-SLOT, recording
CHECK's verdict in VERDICT-SLOT; put both slots back if anything signals (#1106).

THE ORDERING IS THE WHOLE CONTENT OF THIS FUNCTION, and it exists once because three reviews in
a row found a defect in it while it was written twice, and #1106 would have made that five
times:

  - THE CHECK RUNS AFTER NEXT, and reads the slot rather than working out the value that would
    be in effect, so a subclass that gives the URL slot its own :INITFORM is checked too. On a
    fresh instance there is no initarg, the slot is not yet bound, and the superclass's default
    constant is not what the slot will hold.
  - THE VERDICT IS CLEARED BEFORE NEXT, so a failure part-way through cannot leave a verdict
    standing beside a URL it was not about.
  - NEXT IS INSIDE THE HANDLER, not only the check. A subclass :AFTER method on
    SHARED-INITIALIZE runs inside CALL-NEXT-METHOD, after the URL slot has been assigned, so a
    failure there left the new, unchecked URL in the slot.
  - BOTH SLOTS GO BACK TOGETHER on a failure, so a refusal leaves the provider as it was rather
    than pointing at an approved host having forgotten the approval.
  - THE HANDLER DECLINES. HANDLER-BIND rather than HANDLER-CASE, so the slots are restored and
    the condition still reaches the caller unchanged.

Why any of this matters: a provider whose URL check refuses is one a caller may handle and carry
on from, and the next send then carries a credential to whatever is in the slot (#1129)."
  (let ((previous (and (slot-boundp provider url-slot) (slot-value provider url-slot)))
        (previous-verdict (and (slot-boundp provider verdict-slot)
                               (slot-value provider verdict-slot))))
    (setf (slot-value provider verdict-slot) nil)
    (handler-bind ((error (lambda (c)
                            (declare (ignore c))
                            (if previous
                                (setf (slot-value provider url-slot) previous)
                                (slot-makunbound provider url-slot))
                            (setf (slot-value provider verdict-slot) previous-verdict))))
      (let ((instance (funcall next)))
        (setf (slot-value provider verdict-slot)
              (funcall check (slot-value provider url-slot)))
        instance))))

(defparameter *send-connect-timeout* 10
  "Seconds a backend waits for a connection to a provider before giving up (#1077).

TEN IS WHAT HAPPENED ALREADY, now stated here. #1077 was filed believing a send with no timeout
waited for ever; it does not. AION/HTTP-CLIENT passes a timeout to dexador only when one is set,
so an unset timeout has always meant dexador's own default, and that default is ten seconds
(`*default-connect-timeout*` in dexador's src/util.lisp). Measured against a socket that accepts
a connection and never answers: 10.0 seconds, with both timeouts NIL.

THIS DOES NOT COVER NAME RESOLUTION. It bounds the connect itself, and a name that takes a long
time to resolve, or hangs, is not bounded by it (#1077, the review of #1084).

So this changes no behaviour. What it changes is that the figure is hermes's, written down and
settable, instead of a number inside a dependency that an upgrade could move without anyone
here noticing. Setting this, or passing :CONNECT-TIMEOUT to a provider's constructor, now wins
over dexador's default. NIL still means \"say nothing to dexador\", which is dexador's ten, not
for ever.")

(defparameter *send-read-timeout* 10
  "Seconds a backend waits for a provider's answer once the connection was made (#1077). Ten,
for the reason in *SEND-CONNECT-TIMEOUT*: it is what dexador already did, so nothing changes for
an app that sets nothing.

THIS IS A LIMIT ON EACH SOCKET READ, NOT ON THE WHOLE RESPONSE. It is the socket's receive
timeout, so it is reset every time a byte arrives: a provider that sends one byte every nine
seconds holds DELIVER for as long as it cares to, and no setting here ends that. Bounding a whole
response needs a deadline around the call, which is an app's to impose (#1077, the review of
#1084).

A send that is cut off here has reached the provider, and raising this is a judgement about
responsiveness against failing a send that would have been answered. An app that wants to wait
longer sets it; the default is not raised for everybody, because a hung provider would then hold
DELIVER longer than it does today.

A SEND WHOSE READ TIMES OUT MAY ALREADY HAVE BEEN DELIVERED. The request reached the provider,
so the failure says only that no answer arrived. An app that retries one of these can deliver
the same message twice, and it should check the provider rather than assume either way.")

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
