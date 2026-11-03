;;;; packages.lisp --- hermes package definitions.
;;;;
;;;; Package-per-module; :local-nicknames over long prefixes. Two modules:
;;;;   hermes          -- DELIVERY (send): neutral EMAIL/SMS/TELEGRAM-MESSAGE, the DELIVER
;;;;                      protocol, the SendGrid/Twilio/Telegram/dev backends, env selection, conditions. The
;;;;                      interceptor-shaped HTTP client is INTERNAL to this package.
;;;;   hermes/inbound  -- RECEIVE: a neutral inbound-message event apps subscribe to, and a
;;;;                      signature-verified Twilio webhook that emits it.

(cl:defpackage #:hermes
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon)
                    (#:b64  #:cl-base64)
                    (#:log  #:aion/log)
                    (#:secret #:aion/secret))
    (:import-from #:aion/http-client
                ;; The HTTP client moved to aion (pre-publication issue 202). Imported rather than nicknamed so
                ;; the backends' call sites are unchanged by the move -- the point of the
                ;; exercise was to stop reimplementing it, not to churn its consumers.
                ;; CALL-WITH-APPROVED-LOCAL-HOST is NOT exported from aion/http-client, and is
                ;; imported by name rather than reached with a double colon at the call site, so
                ;; that each package which touches it says so in its own definition. hermes/blob
                ;; imports it the same way; this comment used to claim the reach was in one place,
                ;; which was false the moment the S3 backend needed it too (the final review of
                ;; #1134). It is unexported on purpose: a keyword on MAKE-REQUEST let any
                ;; caller assert that a host had been approved as local and so send a plaintext
                ;; request to it with no proxy (#1091, the re-review of #1134).
                #:call-with-approved-local-host
                #:make-request #:request-url #:request-method #:request-headers
                #:request-content
                #:make-response #:response-status #:response-headers #:response-body
                #:make-interceptor #:add-header #:ensure-2xx #:send-request #:header-value
                #:http-error #:http-error-status #:http-error-body #:http-error-detail
                ;; #79: the phase says whether a message was sent before the failure, and
                ;; retry-after is the wait a 429's response asked for.
                #:http-error-phase #:http-error-retry-after
                ;; To decide whether a plaintext API base names something only this machine or
                ;; this network can reach (#1077).
                #:address-category #:parse-address #:resolve-host
                ;; The one rule for whether a host may be sent requests in the clear, and the
                ;; host-from-a-URL reading it takes. Both used to be written here (#1082).
                #:local-host-p #:url-host #:credential-url-refusal)
(:documentation
   "Neutral email + SMS delivery -- hermes, the messenger. A PROVIDER delivers a neutral
    EMAIL or SMS via the DELIVER generic (CLOS multiple dispatch on provider + message), so
    the vendor wire format is confined to each backend. SendGrid (email) + Twilio (SMS) are
    the first backends; a DEV transport renders instead of sending for local dev. The
    provider is chosen by env (HERMES_EMAIL_IMPL / HERMES_SMS_IMPL, or HERMES_TRANSPORT=dev).")
  (:export
   ;; neutral messages
   #:email #:make-email #:email-to #:email-from #:email-subject
   #:email-text #:email-html #:email-reply-to #:email-attachments #:email-headers
   #:reserved-email-headers
   #:attachment #:make-attachment #:attachment-p #:attachment-filename #:attachment-content-type
   #:attachment-content #:attachment-disposition #:attachment-content-id #:attachment-octets
   #:dev-last-email
   #:sms #:make-sms #:sms-to #:sms-from #:sms-text
   #:telegram-message #:make-telegram-message #:telegram-message-p #:telegram-message-chat
   #:telegram-message-text #:telegram-message-parse-mode #:telegram-message-link-preview
   #:telegram-message-photo #:escape-markdown-v2 #:escape-telegram-html #:dev-last-telegram
   #:facebook-post #:make-facebook-post #:facebook-post-p #:facebook-post-page
   #:facebook-post-link #:facebook-post-message #:facebook-post-image-url #:dev-last-facebook
   #:facebook-post-image-octets #:facebook-post-image-type
   #:+facebook-photo-max-octets+ #:+facebook-photo-types+
   ;; delivery result
   #:delivery-result #:make-delivery-result #:delivery-result-provider #:delivery-result-id
   #:delivery-result-status #:delivery-result-raw #:delivery-result-destination
   ;; the protocol
   #:provider #:email-provider #:sms-provider #:telegram-provider #:deliver
   #:edit-sent-message #:delete-sent-message #:telegram-can-post #:telegram-added-chats
   #:telegram-added-chat #:telegram-added-chat-p #:telegram-added-chat-id
   #:telegram-added-chat-type #:telegram-added-chat-title #:telegram-added-chat-status
   #:telegram-added-chat-date
   #:facebook-provider #:facebook-page-health #:post-to-page
   #:facebook-page-status #:+facebook-required-scopes+
   #:facebook-token-info #:facebook-token-info-p #:facebook-token-info-valid-p
   #:facebook-token-info-scopes #:facebook-token-info-expires-at
   #:facebook-token-info-data-access-expires-at #:facebook-token-info-page-id
   #:facebook-token-info-app-id
   #:facebook-page #:facebook-page-p #:facebook-page-id #:facebook-page-name
   #:facebook-page-token #:facebook-page-tasks #:facebook-page-can-post-p
   #:facebook-connect-state #:facebook-connect-url #:facebook-connect-pages
   ;; backends + constructors
   #:sendgrid #:make-sendgrid #:twilio #:make-twilio #:telegram #:make-telegram
   ;; How long a send waits, and the per-provider readers for it (#1077).
   #:*send-connect-timeout* #:*send-read-timeout*
   #:sendgrid-connect-timeout #:sendgrid-read-timeout
   ;; Readable since #1092, when the endpoint gained a check: an app that sets it should be able
   ;; to read back what was accepted.
   #:sendgrid-endpoint
   #:twilio-connect-timeout #:twilio-read-timeout #:twilio-api-base
   #:telegram-api-base #:facebook #:make-facebook #:facebook-app-id #:facebook-graph-base
   #:facebook-dialog-base #:dev-transport #:make-dev-transport
   ;; provider selection from the environment
   #:register-impl #:email-provider-from-env #:sms-provider-from-env
   #:telegram-provider-from-env #:facebook-provider-from-env #:send
   ;; conditions
   #:hermes-error #:configuration-error #:configuration-error-missing
   #:invalid-message #:invalid-message-problem
   #:as-delivery
   #:delivery-failure #:delivery-failure-provider #:delivery-failure-status
   #:delivery-failure-detail #:delivery-failure-phase #:unsupported-message
   #:delivery-rate-limited #:delivery-rate-limited-retry-after
   #:telegram-chat-unreachable #:telegram-not-permitted
   #:telegram-chat-migrated #:telegram-chat-migrated-migrate-to-chat-id
   #:telegram-webhook-active
   #:facebook-reconnect-required #:facebook-not-permitted #:facebook-page-not-found
   #:facebook-link-not-public #:facebook-groups-unsupported #:facebook-groups-unsupported-page
   #:facebook-connect-refused #:facebook-connect-refused-reason
   #:facebook-connect-refused-detail
   #:version))

(cl:defpackage #:hermes/inbound
  (:use #:cl)
  (:local-nicknames (#:b64 #:cl-base64)
                    (#:log #:aion/log))
  (:documentation
   "Inbound messages (receive), provider-neutral. INBOUND-MESSAGE is the neutral event
    (from/to/body/provider/provider-id/timestamp) an app SUBSCRIBEs to. TWILIO-WEBHOOK is the
    handler an app mounts on its own web route: it VERIFY-TWILIO-SIGNATURE (HMAC-SHA1 over the
    URL + sorted params, rejecting forged posts), parses the form POST to an INBOUND-MESSAGE,
    and EMITs it to subscribers. TWIML-MESSAGE builds an optional inline reply. Framework-
    neutral -- the app adapts its request (hyperion, etc.) to the handler's inputs.")
  (:export
   #:inbound-message #:make-inbound-message
   #:inbound-message-from #:inbound-message-to #:inbound-message-body
   #:inbound-message-provider #:inbound-message-provider-id #:inbound-message-timestamp
   #:subscribe #:unsubscribe #:emit #:*subscribers*
   #:verify-twilio-signature #:parse-twilio-inbound #:twilio-webhook #:twiml-message
   #:signature-required))
