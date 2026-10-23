;;;; conditions.lisp --- hermes's failure protocol.
;;;;
;;;; House style: a root condition, specific subtypes carrying actionable detail, and -- for
;;;; a network edge -- a DELIVERY-FAILURE that surfaces the provider's own status + body, so a
;;;; 400 from SendGrid/Twilio explains itself instead of being opaque.

(cl:in-package #:hermes)

(define-condition hermes-error (error)
  ()
  (:documentation "Root of all hermes-signalled errors."))

(define-condition configuration-error (hermes-error)
  ((missing :initarg :missing :reader configuration-error-missing))
  (:report (lambda (c stream)
             (format stream "hermes is missing required configuration: ~A."
                     (configuration-error-missing c))))
  (:documentation "A provider is missing a required credential/setting (e.g. an API key or a
From address), usually because an environment variable is unset."))

(define-condition invalid-message (hermes-error)
  ((problem :initarg :problem :reader invalid-message-problem))
  (:report (lambda (c stream)
             (format stream "hermes cannot build this message: ~A." (invalid-message-problem c))))
  (:documentation "Signalled by MAKE-EMAIL and MAKE-ATTACHMENT when a value they were given is
not one a message can carry (#366), before anything is sent."))

(define-condition delivery-failure (hermes-error)
  ((provider :initarg :provider :initform nil :reader delivery-failure-provider)
   (status :initarg :status :initform nil :reader delivery-failure-status)
   (detail :initarg :detail :initform nil :reader delivery-failure-detail))
  (:report (lambda (c stream)
             (format stream "Delivery via ~A failed~@[ (HTTP ~A)~]~@[: ~A~]."
                     (delivery-failure-provider c)
                     (delivery-failure-status c)
                     (delivery-failure-detail c))))
  (:documentation "The provider rejected the message or the request could not be made. STATUS
is the HTTP status when there was a response; DETAIL is the provider's response body (where it
explains the failure) or a transport error."))

(define-condition delivery-rate-limited (delivery-failure)
  ((retry-after :initarg :retry-after :initform nil :reader delivery-rate-limited-retry-after))
  (:report (lambda (c stream)
             (format stream "Delivery via ~A was refused by the provider's rate limit~@[; retry after ~D seconds~]."
                     (delivery-failure-provider c)
                     (delivery-rate-limited-retry-after c))))
  (:documentation "The provider refused the message because too many were sent (HTTP 429).
RETRY-AFTER is the number of seconds the provider asked the caller to wait, or NIL when it gave
none. hermes neither waits nor retries: a caller that wants a retry schedules one, for example
with AION/SCHEDULE:SCHEDULE-ONCE (#778). The Telegram backend signals it; the other backends
still signal a plain DELIVERY-FAILURE for a 429."))

(define-condition telegram-chat-unreachable (delivery-failure)
  ()
  (:documentation "Telegram refused the message because the bot cannot reach the chat: the
chat does not exist, the bot was never added to it, or the bot was removed or blocked (#778)."))

(define-condition telegram-not-permitted (delivery-failure)
  ()
  (:documentation "Telegram refused the message because the bot is in the chat but may not post
there, for example a channel where the bot is not an administrator with the right to post
(#778)."))

(define-condition telegram-chat-migrated (delivery-failure)
  ((migrate-to-chat-id :initarg :migrate-to-chat-id :initform nil
                       :reader telegram-chat-migrated-migrate-to-chat-id))
  (:documentation "Telegram refused the message because the group became a supergroup, which has
a new chat id. MIGRATE-TO-CHAT-ID is that id; send to it instead, and store it in place of the
old one (#778)."))

(define-condition telegram-webhook-active (delivery-failure)
  ()
  (:documentation "Telegram refused getUpdates because the bot has a webhook set; the two cannot
be used together (#794). TELEGRAM-ADDED-CHATS signals it. The bot's updates, my_chat_member
included, then arrive at the webhook instead. hermes never deletes a webhook."))

;;; --- Facebook Pages (#822) ---------------------------------------------------
;;;
;;; The Graph API answers a refusal with {"error": {"message", "type", "code", "error_subcode",
;;; "fbtrace_id"}}. The classes below follow Meta's error-handling guide: the code, and for an
;;; expired or revoked token the subcode, decide which one is signalled.

(define-condition facebook-reconnect-required (delivery-failure)
  ()
  (:documentation "Facebook refused the call because the Page access token no longer works:
Graph error 190 (the token expired, was revoked, or the admin changed their password or removed
the app), 102, or a login subcode such as 492 (the admin no longer has a role on the Page). The
app shows \"reconnect\" and sends an admin through the connect flow again (#822)."))

(define-condition facebook-not-permitted (delivery-failure)
  ()
  (:documentation "Facebook refused the call because a permission is missing or was removed:
Graph error 10 or 200 to 299. The connected admin did not grant pages_manage_posts, or cannot
perform the CREATE_CONTENT task on the Page, or the target is not a Page this app may post to
(a numeric Group id arrives here) (#822)."))

(define-condition facebook-page-not-found (delivery-failure)
  ()
  (:documentation "Facebook refused the call because the Page does not exist, or this token
cannot see it: Graph error 100 with subcode 33, or 803 (#822)."))

(define-condition facebook-link-not-public (delivery-failure)
  ()
  (:documentation "Facebook refused the post because it could not use its link. Meta's Page Feed
reference says \"If the viewer or app cannot see the url of link, the post will fail\": a page
behind a sign-in, a private URL, or one Facebook cannot fetch. The app can say \"this post isn't
public yet\" (#822). Signalled for a Graph error 100 that mentions the link, on a post that has
one; the detail keeps Facebook's own text."))

(define-condition facebook-groups-unsupported (hermes-error)
  ((page :initarg :page :initform nil :reader facebook-groups-unsupported-page))
  (:report (lambda (c stream)
             (declare (ignore c))
             (write-string (concatenate 'string "hermes cannot post to a Facebook Group: "
                                        "Meta removed the Groups API for every app on 2024-04-22.")
                           stream)))
  (:documentation "Signalled by MAKE-FACEBOOK-POST for a target that names a Facebook Group. The
Graph API v19.0 changelog deprecated publish_to_groups, groups_access_member_info and the Groups
API, and removed them from every version on 2024-04-22, so no app can post to a Group (#822)."))

(define-condition facebook-connect-refused (hermes-error)
  ((reason :initarg :reason :reader facebook-connect-refused-reason)
   (detail :initarg :detail :initform nil :reader facebook-connect-refused-detail))
  (:report (lambda (c stream)
             (format stream "Connecting a Facebook Page failed: ~(~A~)~@[: ~A~]."
                     (facebook-connect-refused-reason c) (facebook-connect-refused-detail c))))
  (:documentation "FACEBOOK-CONNECT-PAGES refused to finish connecting (#822). REASON is
:STATE-MISMATCH (the state returned is not the one this admin's session holds: a forged or
replayed callback), :DENIED (the admin cancelled or refused the permissions, and Facebook
returned an error instead of a code), or :CODE-REJECTED (Facebook refused to exchange the code:
it was used already, expired, or the redirect URI differs). DETAIL is Facebook's text, with any
secret removed."))

(define-condition unsupported-message (hermes-error)
  ((provider :initarg :provider :reader unsupported-message-provider)
   (message :initarg :message :reader unsupported-message-message))
  (:report (lambda (c stream)
             (format stream "Provider ~A cannot deliver a ~A."
                     (unsupported-message-provider c)
                     (type-of (unsupported-message-message c)))))
  (:documentation "Signalled when a provider is asked to deliver a message on a channel it
does not implement (e.g. an SMS to an email-only provider)."))

;;; --- the boundary with aion/http-client (pre-publication issue 202) ----------------------------
;;;
;;; The HTTP client used to signal DELIVERY-FAILURE directly, which is exactly why it could
;;; not be reused: a general client has no business asserting that a *delivery* failed. It
;;; now signals AION/HTTP-CLIENT:HTTP-ERROR, and the meaning is restored here -- in the
;;; messaging framework, which is the only place "delivery" means anything.

(defmacro as-delivery (provider &body body)
  "Run BODY, translating an HTTP-ERROR into a DELIVERY-FAILURE attributed to PROVIDER.

Wraps a backend's whole outbound call rather than each stage, so a transport failure and a
rejected status arrive as the same kind of thing to a caller -- which is what DELIVER's
contract already promised."
  (let ((c (gensym)))
    `(handler-case (progn ,@body)
       (aion/http-client:http-error (,c)
         (error 'delivery-failure
                :provider ,provider
                :status (aion/http-client:http-error-status ,c)
                :detail (or (aion/http-client:http-error-detail ,c)
                            (aion/http-client:http-error-body ,c)))))))
