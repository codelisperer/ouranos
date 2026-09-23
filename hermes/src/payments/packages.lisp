;;;; packages.lisp --- the neutral payments protocol (#48).

(cl:defpackage #:hermes/payments/kind
  (:use #:coalton #:coalton-prelude)
  (:documentation
   "The closed vocabulary of normalized webhook events, as a Coalton type (#48).

    Seven kinds, and no eighth: a provider event that does not map onto one of these is
    reported as unmapped rather than invented into the vocabulary. Typed rather than a bare
    keyword so a misspelt kind cannot be constructed at all -- with keywords,
    `:payment-suceeded` is silently a different event that no handler will ever match.

    Only the VARIANT is Coalton. The records each event carries are CL structs, because CL
    may never destructure a Coalton type and nothing downstream is Coalton: hermes' shell
    parses the provider payload and the application's handler dispatches on the result, so
    exhaustive `match` would have no consumer to serve while every field would need an
    exported accessor. Types are here where they prevent a bug and absent where they would
    only add ceremony.")
  (:export #:Event-Kind
           #:Subscription-Changed #:Subscription-Canceled #:Trial-Will-End
           #:Payment-Succeeded #:Payment-Failed #:Dispute-Opened #:Refunded
           #:kind-name #:kind=))

(cl:defpackage #:hermes/payments/money
  (:use #:coalton #:coalton-prelude)
  (:local-nicknames (#:sec #:aion/secret/types))
  (:documentation
   "A typed amount and a provider config (#49).

    What this prevents, precisely: a currency arrives at RUNTIME from a provider's JSON, so
    it cannot be in the type and a mismatch cannot be a compile error at that boundary.
    What IS reachable is that an amount CARRIES its currency and the arithmetic REFUSES to
    combine two that disagree -- returning None rather than a wrong number. The pair of
    loose slots this replaces could be separated, passed half, or added to a different
    pair; a Money cannot. Minor units always: there is deliberately no float constructor.")
  (:export #:Currency #:currency-code #:currency=
           #:Money #:make-money #:money-minor #:money-currency #:money-zero?
           #:money+ #:money- #:money= #:money<
           #:money-ok? #:money-or
           #:Config #:make-config #:config-api-key #:config-webhook-secret
           #:config-api-base #:config-complete?))

(cl:defpackage #:hermes/payments
  (:use #:cl)
  (:local-nicknames (#:kind #:hermes/payments/kind)
                    (#:money #:hermes/payments/money)
                    (#:http #:aion/http-client)
                    (#:jzon #:com.inuoe.jzon)
                    (#:log #:aion/log))
  ;; CONFIGURATION-ERROR is hermes' own, imported rather than redefined: a missing
  ;; credential means the same thing for a payment provider as for an email one, and two
  ;; conditions with one meaning is exactly the vocabulary split docs/vocabulary-and-layers
  ;; warns about. Re-exported so a caller need not know which package it came from.
  (:import-from #:hermes #:configuration-error #:configuration-error-missing)
  (:documentation
   "A neutral payments protocol: hosted checkout, subscriptions, and normalized webhooks
    (#48). Stripe is one implementation of this protocol and never the protocol itself.

    Mirrors hermes' messaging doctrine rather than inventing a second one -- a provider
    class, generic operations, an env-selected registry, and a dev backend. PAYMENT-PROVIDER
    is a SIBLING of PROVIDER, not a subclass: a payment provider does not deliver messages.

    Three properties worth knowing before use, each of which shaped the surface:

    SUBSCRIPTIONS ARE PLURAL. Nothing here returns *the* subscription. A customer may hold
    several concurrently, and a protocol that assumes otherwise forecloses that shape for
    every consumer at once.

    WEBHOOKS ARE AUTHORITATIVE; REDIRECTS ARE ADVISORY. A success URL is a browser being
    told what to display -- forgeable, replayable, and possibly never visited. State changes
    on the webhook.

    NO OPERATION ACCEPTS A CARD NUMBER, by shape rather than by policy. That is what holds
    PCI scope at SAQ-A, and it is why there is deliberately no form in which one could be
    passed.")
  (:export
   ;; the provider protocol
   #:payment-provider #:register-payment-impl #:payments #:provider-call
   #:idempotency-key #:derived-idempotency-key
   #:dev-payments #:make-dev-payments #:dev-add-subscription #:dev-sign
   #:stripe-payments #:make-stripe-payments #:*webhook-tolerance*
   #:unix->universal #:+unix-epoch+
   ;; operations
   #:create-customer #:create-checkout #:create-portal-session
   #:subscriptions-for #:subscription-state #:cancel-subscription #:refund
   #:verify-webhook
   ;; the normalized event and its envelope
   #:event-supersedes-p #:subscription-grants-access-p
   #:event #:event-p #:event-kind #:event-kind-name #:event-id #:event-occurred-at #:event-provider
   #:event-subscription #:event-payment #:event-dispute #:event-refund #:event-raw
   ;; the records an event carries
   #:make-subscription #:make-payment #:make-dispute #:make-refund-record #:make-event
   #:subscription #:subscription-p #:subscription-ref #:subscription-customer-ref
   #:subscription-status #:subscription-current-period-end
   #:subscription-price-ref #:subscription-product-ref
   #:subscription-cancel-at-period-end-p #:subscription-trial-end
   #:payment #:payment-p #:payment-ref #:payment-subscription-ref
   #:payment-amount #:payment-status
   #:dispute #:dispute-p #:dispute-ref #:dispute-payment-ref
   #:dispute-amount #:dispute-status
   #:refund-record #:refund-record-p #:refund-record-ref #:refund-record-payment-ref
   #:refund-record-amount #:refund-record-partial-p
   ;; failure
   #:payment-error #:payment-error-detail #:unsupported-operation
   #:configuration-error #:configuration-error-missing
   #:webhook-signature-invalid #:unmapped-event #:unmapped-event-type))
