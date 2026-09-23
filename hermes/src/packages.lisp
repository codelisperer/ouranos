;;;; packages.lisp --- hermes package definitions.
;;;;
;;;; Package-per-module; :local-nicknames over long prefixes. Two modules:
;;;;   hermes          -- DELIVERY (send): neutral EMAIL/SMS, the DELIVER protocol, the
;;;;                      SendGrid/Twilio/dev backends, env selection, conditions. The
;;;;                      interceptor-shaped HTTP client is INTERNAL to this package.
;;;;   hermes/inbound  -- RECEIVE: a neutral inbound-message event apps subscribe to, and a
;;;;                      signature-verified Twilio webhook that emits it.

(cl:defpackage #:hermes
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon)
                    (#:b64  #:cl-base64)
                    (#:log  #:aion/log))
    (:import-from #:aion/http-client
                ;; The HTTP client moved to aion (#202). Imported rather than nicknamed so
                ;; the backends' call sites are unchanged by the move -- the point of the
                ;; exercise was to stop reimplementing it, not to churn its consumers.
                #:make-request #:request-url #:request-method #:request-headers
                #:request-content
                #:make-response #:response-status #:response-headers #:response-body
                #:make-interceptor #:add-header #:ensure-2xx #:send-request #:header-value
                #:http-error #:http-error-status #:http-error-body #:http-error-detail)
(:documentation
   "Neutral email + SMS delivery -- hermes, the messenger. A PROVIDER delivers a neutral
    EMAIL or SMS via the DELIVER generic (CLOS multiple dispatch on provider + message), so
    the vendor wire format is confined to each backend. SendGrid (email) + Twilio (SMS) are
    the first backends; a DEV transport renders instead of sending for local dev. The
    provider is chosen by env (HERMES_EMAIL_IMPL / HERMES_SMS_IMPL, or HERMES_TRANSPORT=dev).")
  (:export
   ;; neutral messages
   #:email #:make-email #:email-to #:email-from #:email-subject
   #:email-text #:email-html #:email-reply-to
   #:sms #:make-sms #:sms-to #:sms-from #:sms-text
   ;; delivery result
   #:delivery-result #:make-delivery-result #:delivery-result-provider #:delivery-result-id
   #:delivery-result-status #:delivery-result-raw
   ;; the protocol
   #:provider #:email-provider #:sms-provider #:deliver
   ;; backends + constructors
   #:sendgrid #:make-sendgrid #:twilio #:make-twilio #:dev-transport #:make-dev-transport
   ;; provider selection from the environment
   #:register-impl #:email-provider-from-env #:sms-provider-from-env #:send
   ;; conditions
   #:hermes-error #:configuration-error #:configuration-error-missing
   #:as-delivery
   #:delivery-failure #:delivery-failure-provider #:delivery-failure-status
   #:delivery-failure-detail #:unsupported-message
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
