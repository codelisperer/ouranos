;;;; events.lisp --- the records a normalized event carries (CL structs).
;;;;
;;;; STATE, NOT DELTAS. Every event carries the resulting state -- "active until T" -- and
;;;; never an instruction relative to what the application holds. Deltas plus retries equals
;;;; drift, and webhooks are retried.
;;;;
;;;; ORDERING IS CARRIED, NOT INFERRED. Webhooks arrive at-least-once AND out of order, so
;;;; every event carries the provider's own OCCURRED-AT. Without it a retried "changed" can
;;;; overwrite a later "canceled" and silently restore access to somebody who left -- which
;;;; is a security failure wearing a data-quality costume. Arrival time cannot substitute:
;;;; it is the time WE received it, which is exactly the thing reordering destroys.
;;;;
;;;; DEDUPE IS THE APPLICATION'S. We expose a stable EVENT-ID and nothing more, because
;;;; deduplication needs durable storage and hermes is a satellite with no database and none
;;;; permitted. The application keeps the processed-events table; the protocol keeps the
;;;; promise that the id is stable. Same inversion as magic-link delivery and context
;;;; offload -- the obvious implementation is the illegal one.

(cl:in-package #:hermes/payments)

;;; --- the records ----------------------------------------------------------
;;;
;;; Amounts are a single MONEY (pre-publication issue 49), not a minor-units-plus-currency pair. The pair could
;;; be separated, passed half, or added to a different pair; a Money cannot. Read it with
;;; MONEY:MONEY-MINOR and MONEY:MONEY-CURRENCY, and combine amounts with MONEY:MONEY+,
;;; which returns None across currencies rather than a wrong number.

(defstruct (subscription (:constructor make-subscription (&key ref customer-ref status
                                                               current-period-end
                                                               cancel-at-period-end-p
                                                               trial-end
                                                               price-ref product-ref)))
  "The state of ONE subscription. A customer may hold several; see SUBSCRIPTIONS-FOR.

PRICE-REF AND PRODUCT-REF ARE WHAT MAKE THIS USABLE. Without them an application receiving a
renewal cannot tell WHAT was renewed except by reaching into the provider's raw payload --
which is the coupling this protocol exists to remove. They are two fields rather than one
because a provider Price is IMMUTABLE: repricing a product creates a new price and archives
the old, so the product ref survives a repricing and the price ref does not.

RESOLVE ENTITLEMENT FROM THE PRODUCT, NOT THE PRICE. The product is the tier; the price is
only what this member happens to pay for it. A tier is routinely sellable at several live
prices at once -- monthly and annual, several currencies, student and regional rates, plus
cohorts left on a price no longer offered -- and all of them confer exactly the same access.

If only a price reference is in hand, then A PRICE REFERENCE IS NEVER REPLACED, ONLY
SUPERSEDED: resolve over every price a product has ever had, not only its current one,
because members who bought at the old price go on being billed at it and their renewals keep
arriving carrying a reference the application may have stopped recognising.

THERE IS DELIBERATELY NO AMOUNT ON THIS RECORD. Amounts belong to payments, disputes and
refunds, which are billing facts; entitlement is not one. An API that let a caller infer
capability from what somebody paid would be inviting a discrimination bug that looks harmless
at a single call site and is systematic in aggregate -- a member on a student or regional
price has precisely the access of one paying the standard rate. Retiring one price of a tier
must likewise disturb neither the tier's other prices nor the members still on the retired
one, which follows from resolving on the product.

The failure is silent and it lands at the worst possible moment: the lookup returns nothing,
the state write puts an empty tier over a paying member's subscription, and the member loses
what they bought at the exact instant they pay for it again. No error, no log. It was found
in a real integration weeks-scale after the code looked correct, because it needs a repricing
AND a subsequent renewal before it can appear -- and only on the reprice path, since retiring
a product keeps the row."
  (ref "" :type string)
  (customer-ref "" :type string)
  ;; Immutable at the provider. See the note above: never replaced, only superseded.
  (price-ref nil)
  ;; Survives a repricing, which is why it cannot be the same column as PRICE-REF.
  (product-ref nil)
  ;; :active :trialing :past-due :canceled :unpaid -- the provider's status, normalized.
  (status :active :type keyword)
  (current-period-end 0 :type integer)
  ;; The distinction that decides whether access ends now or at CURRENT-PERIOD-END. It is a
  ;; property of the STATE rather than of the event, so a reconciliation run reads it too.
  (cancel-at-period-end-p nil :type boolean)
  (trial-end nil))

(defstruct (payment (:constructor make-payment (&key ref subscription-ref amount status)))
  "One payment attempt: succeeded or failed. A failure is dunning, not a revocation."
  (ref "" :type string)
  (subscription-ref nil)
  amount                                ; a MONEY
  (status :succeeded :type keyword))

(defstruct (dispute (:constructor make-dispute (&key ref payment-ref amount status)))
  "A chargeback in progress. Reported as a STATE; what happens to access is the
application's policy and deliberately not this library's -- a member may win, and
destroying their content over a bank's provisional decision is unrecoverable."
  (ref "" :type string)
  (payment-ref "" :type string)
  amount                                ; a MONEY
  (status :open :type keyword))

(defstruct (refund-record (:constructor make-refund-record (&key ref payment-ref amount
                                                                 partial-p)))
  "Money returned. NOT a cancellation -- they often coincide and mean different things
about intent, so an application that treats one as the other will revoke access it was
never asked to revoke."
  (ref "" :type string)
  (payment-ref "" :type string)
  amount                                ; a MONEY
  (partial-p nil :type boolean))

;;; --- the event ------------------------------------------------------------

(defstruct (event (:constructor make-event (&key kind id occurred-at provider
                                                 subscription payment dispute refund raw)))
  "A normalized webhook event: an envelope, and the record whose state it reports.

KIND is a HERMES/PAYMENTS/KIND:EVENT-KIND -- the typed vocabulary. Dispatch on
KIND-NAME rather than on the value itself; CL may not destructure a Coalton type.

RAW is the provider's own payload, kept for logging and for the extension hatch. It is
deliberately last and deliberately not part of any neutral contract: an application that
reads it is coupled to that provider, which is the coupling this protocol exists to remove."
  kind
  (id "" :type string)
  (occurred-at 0 :type integer)
  (provider "" :type string)
  subscription payment dispute refund raw)

(defun event-kind-name (event)
  "The event's kind as a string, for CASE dispatch in application code."
  (kind:kind-name (event-kind event)))

;;; --- applying events safely (pre-publication issue 47 input, from a real integration) ----------
;;;
;;; Two defences that every consumer of a webhook stream needs, that are provider-
;;; independent, and that a consuming app reported having had to write itself. Pure
;;; functions over values the protocol already carries, so they cost nothing to offer and
;;; save each application discovering them the expensive way.

(defun event-supersedes-p (event last-applied-at)
  "True when EVENT is newer than the last state an application applied.

DEDUPE AND ORDERING ARE DIFFERENT PROBLEMS, and only the second is subtle. Deduplicating on
EVENT-ID handles at-least-once delivery: the same event twice collapses to one. It does
nothing about a retried `changed` arriving AFTER a `canceled` -- which silently restores
access to somebody who left. No error, no log, just a member who kept what they cancelled.

Arrival order cannot decide it, because arrival order is precisely what is unreliable. The
provider's own OCCURRED-AT can, which is why every event carries it.

LAST-APPLIED-AT is whatever the application recorded when it last wrote this record; NIL
means it has none, and anything is newer than nothing."
  (or (null last-applied-at)
      (> (event-occurred-at event) last-applied-at)))

(defun subscription-grants-access-p (subscription &optional (at (get-universal-time)))
  "True when SUBSCRIPTION entitles its holder AT this moment.

A STORED STATUS GOES STALE SILENTLY. If a terminal event never arrives -- a missed webhook,
an outage -- the record says `active` forever and a status check keeps granting access to
somebody whose subscription ended months ago. The record cannot know it is wrong.

The period end can. It is a value the application already holds, needs no network to
consult, and cannot be missed. So entitlement is the PAIR -- an acceptable status AND a
period that has not elapsed -- and never the status alone.

A subscription cancelled at period end still grants access until that period ends, which is
the whole reason the two are distinguished."
  (and (member (subscription-status subscription) '(:active :trialing))
       (let ((ends (subscription-current-period-end subscription)))
         (or (null ends) (zerop ends) (> ends at)))))
