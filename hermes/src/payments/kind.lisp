;;;; kind.lisp --- the closed vocabulary of normalized events (Coalton).
;;;;
;;;; Seven kinds. The list is closed on purpose: a provider event that does not map onto one
;;;; of them is reported as UNMAPPED rather than quietly widening the vocabulary, because a
;;;; neutral protocol that grows a variant per provider is not neutral, it is a union of
;;;; vendors.
;;;;
;;;; They are ranked here in the order a consuming application said they matter, which is by
;;;; what actually changes a member's access -- not by how the provider groups them.

(cl:in-package #:hermes/payments/kind)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  (define-type Event-Kind
    "What a normalized webhook event IS. The event's record carries the resulting state."
    ;; grants or changes entitlement -- created and updated are one kind, because an
    ;; application does the same thing with both: read the state and apply it.
    Subscription-Changed
    ;; ended -- and the state says whether it ended NOW or at period end. Revoking on the
    ;; event rather than at period end is a support ticket every single time.
    Subscription-Canceled
    ;; silent conversion is how a platform earns a chargeback. Trial length is the
    ;; PROVIDER'S, never an application constant.
    Trial-Will-End
    ;; extends the period, and is the anchor a reconciliation run counts from.
    Payment-Succeeded
    ;; dunning, and emphatically NOT revocation: a failed card is usually a card.
    Payment-Failed
    ;; money being clawed back and a decision required. A STATE, not a notification --
    ;; and what happens to access is the application's policy, not this library's.
    Dispute-Opened
    ;; NOT a cancellation, and partial refunds exist. They often coincide with a
    ;; cancellation and mean something different about intent.
    Refunded)

  (declare kind-name (Event-Kind -> String))
  (define (kind-name k)
    "A stable, lower-case name -- for logs, for tests, and for a CL `case`.

The CL shell dispatches on this rather than on the type, because CL may not destructure a
Coalton value. The type still earns its place: this is the only place the seven names are
written, so a misspelt kind cannot be constructed."
    (match k
      ((Subscription-Changed) "subscription-changed")
      ((Subscription-Canceled) "subscription-canceled")
      ((Trial-Will-End) "trial-will-end")
      ((Payment-Succeeded) "payment-succeeded")
      ((Payment-Failed) "payment-failed")
      ((Dispute-Opened) "dispute-opened")
      ((Refunded) "refunded")))

  (declare kind= (Event-Kind * Event-Kind -> Boolean))
  (define (kind= a b)
    "Compare two kinds. CL cannot pattern-match them, so it compares through this."
    (== (kind-name a) (kind-name b))))
