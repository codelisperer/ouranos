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

(defun %check-credential-url (value &key setting example credential appends-path)
  "Signal CONFIGURATION-ERROR unless VALUE is a URL this framework may send CREDENTIAL to
(#1077, #1092). SETTING names the slot in the message, EXAMPLE is a URL that would be accepted,
CREDENTIAL says what would travel -- \"the account SID and auth token\", \"the API key\" -- and
APPENDS-PATH says whether the backend appends a path to VALUE.

ONE CHECK FOR TWILIO'S API-BASE AND SENDGRID'S ENDPOINT. Those two, and no others yet: Telegram's
api-base, Facebook's graph-base, Stripe's api-base and HERMES/BLOB's S3 endpoint do NOT call this,
and blob keeps its own copy of the locality half. Bringing them here is #1106. An earlier version
of this docstring said it was one check for \"every backend that sends a credential to a
configured URL\", which was false when it was written (the review of #1104).

The reason for sharing even two: hermes had this written once, for Twilio's API base in #1077, and
hermes/blob had the locality half written again for an S3 endpoint; between them the two copies
acquired three different holes, each a case the other's fix had already closed (#1089, and the
reviews of #1084 and #1090). SendGrid had no check at all, which is #1092. Writing it a third
time by hand was the bet that produced the first two.

NO REFUSAL REPEATS VALUE, OR QURI'S ERROR TEXT. The value may carry a password -- that is one of
the things refused -- and these reports reach logs and terminals. An earlier version printed it
in every branch, and its parse-failure branch also appended quri's error, which quotes the URI
again, so a password appeared twice (the review of #1084).

What is refused, and why each is here rather than only the obvious one:

  - anything QURI cannot parse. QURI is used because it is the parser dexador parses the request
    URL with, so this asks the same question of the same parser;
  - a scheme that is not http or https. Refusing only plaintext is not enough: for
    \"evil.example://127.0.0.1\" quri reads the scheme \"evil.example\" and the host 127.0.0.1,
    which a check looking for \"http\" lets through;
  - any userinfo, whatever the scheme and host, including over https and including when the host
    is local. No API here uses it, and its only effects are to hide the real host from a reader
    and to defeat this check;
  - no host;
  - a query or a fragment, but only when APPENDS-PATH: the request's path would land inside them.
    A backend that sends VALUE as it stands has no such problem, and refusing a query there would
    turn away a legitimate local mock;
  - a bracketed IPv6 host, which cannot be connected to -- usocket:socket-connect answers
    NS-HOST-NOT-FOUND-ERROR for \"[::1]\" while \"::1\" resolves;
  - plaintext http to a host this machine or this network cannot reach by itself, which is
    AION/HTTP-CLIENT:LOCAL-HOST-P and not a rule written here. That function also refuses a
    leading-zero IPv4 spelling, where its parser and the system resolver can disagree.

The host is resolved at the moment this runs, once. A provider made while a name resolved
locally is not re-checked if that name later resolves elsewhere.

RETURNS TWO VALUES: the parsed URI, and whether the host was approved as LOCAL. The second is
what #1091 needed, and it costs no second lookup, because it is already known here: a plaintext
URL that this function returns at all is one whose host LOCAL-HOST-P approved -- that is the last
branch below, and the alternative is a refusal. A caller records it and passes it to
AION/HTTP-CLIENT as APPROVED-LOCAL, so the plaintext request it then sends is not handed to a
proxy. It is false for an https URL, whose host is never resolved here, which matches
PROXY-ARGUMENTS: the proxy decision is only made for plaintext."
  ;; CONTROL CHARACTERS ARE REFUSED FIRST, before the value is parsed. A newline in a URL is the
  ;; shape of a header injection -- "http://127.0.0.1/x\nHost: evil.example" -- and although the
  ;; credential would still have gone only to the local host, a value that cannot appear in a URL
  ;; has no reading worth arguing about. Refusing it removes the question rather than answering
  ;; it (the review of #1104).
  (when (and (stringp value)
             (some (lambda (c) (let ((n (char-code c))) (or (< n 32) (= n 127)))) value))
    (error 'configuration-error
           :missing (format nil "a ~A without control characters in it. The value contains at least one, and it is not repeated here because it may contain a password"
                            setting)))
  (let* ((uri (handler-case (quri:uri value)
                (error ()
                  (error 'configuration-error
                         :missing (format nil "a ~A that parses as a URL. The value given does not, and it is not repeated here because it may contain a password"
                                          setting)))))
         (scheme (quri:uri-scheme uri))
         (host (quri:uri-host uri))
         (approved-local nil))
    (flet ((refuse (why)
             (error 'configuration-error
                    :missing (format nil "a ~A such as ~A. ~A" setting example why))))
      (when (quri:uri-userinfo uri)
        (refuse (format nil "The value carries a user name or password before an \"@\", which this API does not use and which hides the host a request would reach. That host is ~S." host)))
      (unless (and scheme (or (string-equal scheme "https") (string-equal scheme "http")))
        (refuse (format nil "The scheme is ~S. Only http and https are sent, and another scheme means the host this check reads is not the host a request would reach." scheme)))
      (unless host
        (refuse "The value has no host."))
      (when (and appends-path (or (quri:uri-query uri) (quri:uri-fragment uri)))
        (refuse "The value carries a query or a fragment, and the rest of each request's path is appended to it, so the path would end up inside them."))
      (when (and (plusp (length host)) (char= #\[ (char host 0)))
        (refuse (format nil "The host ~S is a bracketed IPv6 address, which cannot be connected to: it is looked up as a name and no such name exists. Write the address without brackets, or use a name." host)))
      (when (and (string-equal scheme "http") (not (local-host-p host)))
        (refuse (format nil "The host ~S would receive ~A in the clear, because every request carries them in an Authorization header. Use https, or a host only this machine or this network can reach."
                        host credential)))
      ;; THE SECOND VALUE IS READ OFF THE BRANCH ABOVE rather than resolved again. Reaching here
      ;; with an http scheme means LOCAL-HOST-P said yes, since the only other way out of that
      ;; branch is a refusal (#1091).
      (setf approved-local (and scheme (string-equal scheme "http") t)))
    (values uri approved-local)))

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
