;;;; protocol.lisp --- the neutral payments protocol + env selection.
;;;;
;;;; Deliberately the same shape as hermes' messaging protocol: a provider class, generic
;;;; operations, a registry, env selection, and a dev backend. Payments is the same doctrine
;;;; applied to a second domain and not a new one -- Stripe is one implementation of this
;;;; protocol and never the protocol itself (#51).
;;;;
;;;; PAYMENT-PROVIDER is a SIBLING of hermes' PROVIDER rather than a subclass. A payment
;;;; provider does not deliver messages, and inheriting from something whose contract is
;;;; DELIVER in order to reuse a registry would be reuse of the wrong thing.

(cl:in-package #:hermes/payments)

;;; --- failure --------------------------------------------------------------

(define-condition payment-error (error)
  ((detail :initarg :detail :initform nil :reader payment-error-detail))
  (:report (lambda (c s) (format s "hermes/payments: ~A"
                                 (or (payment-error-detail c) "request failed"))))
  (:documentation "Base for payment failures. Recoverable failure goes through the
condition system rather than through return codes, as everywhere else in this tree."))

(define-condition unsupported-operation (payment-error)
  ((provider :initarg :provider :reader unsupported-operation-provider)
   (operation :initarg :operation :reader unsupported-operation-operation))
  (:report (lambda (c s)
             (format s "hermes/payments: ~A does not implement ~A"
                     (unsupported-operation-provider c) (unsupported-operation-operation c))))
  (:documentation "The provider does not implement this operation. A distinct condition
from a failed request: one is a gap in a backend, the other is a bad afternoon at a vendor,
and an application retries only the second."))

(define-condition webhook-signature-invalid (payment-error)
  ()
  (:documentation "The webhook's signature did not verify. Carries no detail about WHY on
purpose -- a caller cannot act on the difference, and an attacker should not learn it."))

(define-condition unmapped-event (payment-error)
  ((event-type :initarg :event-type :reader unmapped-event-type))
  (:report (lambda (c s)
             (format s "hermes/payments: no neutral event for provider type ~S"
                     (unmapped-event-type c))))
  (:documentation "The provider sent something outside the neutral vocabulary. Reported
rather than invented into it: a protocol that grows a variant per provider is not neutral,
it is a union of vendors. Applications that need it reach for the extension hatch knowing
they are leaving the neutral core."))

;;; --- the provider ---------------------------------------------------------

(defclass payment-provider () ()
  (:documentation "Abstract base for anything that can take a payment."))

(defgeneric create-customer (provider &key email name metadata)
  (:documentation "Create a customer and return its opaque provider ref (a string).
Takes no card data, and there is deliberately no shape in which it could."))

(defgeneric create-checkout (provider &key customer-ref mode line-items success-url
                                           cancel-url idempotency-key metadata
                                           allow-promotion-codes)
  (:documentation
   "Create a HOSTED checkout session and return its URL (a string).

MODE is :PAYMENT or :SUBSCRIPTION. Hosted only -- card data never reaches our servers,
which is what holds PCI scope at SAQ-A.

SUCCESS-URL is where the browser is sent afterwards and is ADVISORY. It can be forged,
replayed, or never visited. Do not grant entitlement there; grant it on the webhook.

ALLOW-PROMOTION-CODES decides whether the hosted page offers a box for a discount code. It
defaults to NIL because that is what providers default to and surprising a checkout page with
an extra field is worse than an explicit opt-in -- but the failure it guards is silent and
expensive, so it is worth stating plainly:

  IF THIS IS NOT SET, EVERY DISCOUNT CODE YOU CREATE IS UNREACHABLE. The codes exist, the
  provider accepts them, the dashboard lists them, and no buyer can ever enter one. Nothing
  errors. A consuming app hit exactly this in production conditions, and it is not something
  the provider documentation surfaces at the point you need it."))

(defgeneric create-portal-session (provider &key customer-ref return-url)
  (:documentation "A hosted self-service portal URL, so an application does not reimplement
card updates, plan changes and cancellation -- each of which is a compliance surface."))

(defgeneric subscriptions-for (provider customer-ref)
  (:documentation
   "EVERY subscription this customer holds, as a list of SUBSCRIPTION -- possibly empty.

A list rather than one, always. A customer may hold several concurrently (a per-group tier
is the obvious case), and a protocol that models `the` subscription forecloses that shape
for every consumer at once.

An empty list means the customer positively holds none. A SIGNAL means we could not find
out -- see SUBSCRIPTION-STATE on why conflating the two is how an outage becomes a mass
revocation.

This is also the RECONCILIATION path, and is not merely a convenience accessor. Webhooks are
the source of truth for local state, so local state will drift -- a missed delivery, an
outage, a bug. Without an authoritative read there is no recovery from a missed webhook
except a human noticing."))

(defgeneric subscription-state (provider subscription-ref)
  (:documentation
   "The current state of ONE subscription by its own ref, or NIL if the provider says it
does not exist.

**NIL MEANS GONE. A SIGNAL MEANS UNKNOWN.** The distinction is the whole contract of this
operation and it is not decoration: a reconciliation run that treats an unreachable provider
as a cancellation revokes access for every member at once, during an outage, silently and
irreversibly. Our outage is not their cancellation.

So a backend returns NIL only when the provider positively reported absence, and signals
PAYMENT-ERROR for anything else -- a timeout, a 500, a network failure, an expired key. A
caller reconciling records must leave a record alone when this signals."))

(defgeneric cancel-subscription (provider subscription-ref &key when)
  (:documentation
   "Cancel a subscription. WHEN is :PERIOD-END (default) or :NOW, and the difference is
not cosmetic: revoking access on a cancellation that was meant to take effect at period end
is a support ticket every single time. Returns the resulting SUBSCRIPTION state, whose
CANCEL-AT-PERIOD-END-P says which happened."))

(defgeneric refund (provider payment-ref &key amount idempotency-key)
  (:documentation
   "Refund a payment, in full by default or partially with AMOUNT (a MONEY). Returns a
REFUND-RECORD.

A refund is NOT a cancellation. They often coincide and mean different things about intent;
an application that conflates them revokes access it was never asked to revoke."))

(defgeneric verify-webhook (provider payload signature &key secret)
  (:documentation
   "Verify PAYLOAD's SIGNATURE and parse it into a normalized EVENT.

Signals WEBHOOK-SIGNATURE-INVALID if it does not verify, and UNMAPPED-EVENT if the payload
is authentic but outside the neutral vocabulary. Verification happens BEFORE parsing:
nothing in an unverified payload is worth reading, including its type."))

(defgeneric provider-call (provider operation &rest args)
  (:documentation
   "THE EXTENSION HATCH, and deliberately awkward to reach for.

Provider-specific capabilities are real, and pretending otherwise produces a `neutral` core
that has quietly grown Stripe-shaped. Anything reached through here is outside the
protocol's compatibility promise: an application using it is coupled to that provider and
should know it at the call site rather than discover it when a second provider arrives."))

;;; --- default methods: a gap says so ---------------------------------------

(defmethod subscriptions-for ((p payment-provider) customer-ref)
  (declare (ignore customer-ref))
  (error 'unsupported-operation :provider (class-name (class-of p))
                                :operation 'subscriptions-for))

(defmethod subscription-state ((p payment-provider) subscription-ref)
  (declare (ignore subscription-ref))
  (error 'unsupported-operation :provider (class-name (class-of p))
                                :operation 'subscription-state))

(defmethod create-customer ((p payment-provider) &key email name metadata)
  (declare (ignore email name metadata))
  (error 'unsupported-operation :provider (class-name (class-of p)) :operation 'create-customer))

(defmethod create-checkout ((p payment-provider) &key customer-ref mode line-items
                                                      success-url cancel-url
                                                      idempotency-key metadata
                                                      allow-promotion-codes)
  (declare (ignore customer-ref mode line-items success-url cancel-url idempotency-key
                   metadata allow-promotion-codes))
  (error 'unsupported-operation :provider (class-name (class-of p)) :operation 'create-checkout))

(defmethod create-portal-session ((p payment-provider) &key customer-ref return-url)
  (declare (ignore customer-ref return-url))
  (error 'unsupported-operation :provider (class-name (class-of p))
                                :operation 'create-portal-session))

(defmethod cancel-subscription ((p payment-provider) subscription-ref &key when)
  (declare (ignore subscription-ref when))
  (error 'unsupported-operation :provider (class-name (class-of p))
                                :operation 'cancel-subscription))

(defmethod refund ((p payment-provider) payment-ref &key amount idempotency-key)
  (declare (ignore payment-ref amount idempotency-key))
  (error 'unsupported-operation :provider (class-name (class-of p)) :operation 'refund))

(defmethod verify-webhook ((p payment-provider) payload signature &key secret)
  (declare (ignore payload signature secret))
  (error 'unsupported-operation :provider (class-name (class-of p)) :operation 'verify-webhook))

(defmethod provider-call ((p payment-provider) operation &rest args)
  (declare (ignore args))
  (error 'unsupported-operation :provider (class-name (class-of p)) :operation operation))

;;; --- a boundary the protocol will not let you cross ------------------------
;;;
;;; MOVING AN EXISTING SUBSCRIBER TO A DIFFERENT PRICE IS NOT AN EDIT, AND NO OPERATION HERE
;;; WILL EVER MAKE IT ONE.
;;;
;;; Repricing what a tier costs *new* buyers and changing what *existing* members are charged
;;; are different acts with different consequences. The first is a catalogue decision. The
;;; second is a price change to people who have already agreed to a price, and in several
;;; jurisdictions it requires notice or consent.
;;;
;;; The failure it guards against is an operator making the second while believing they made
;;; the first -- an interface offering "change the price" that quietly migrates subscribers is
;;; not a convenience, it is a compliance incident produced by an edit form.
;;;
;;; It matters MORE with discounted pricing rather than less: moving somebody off a student or
;;; regional price is a price rise to a member who has said they cannot afford the standard
;;; one.
;;;
;;; So: this protocol carries no operation that changes an existing subscriber's price, and
;;; any future one must be separate, explicit, and impossible to reach as a side effect of
;;; something else. Same doctrine as no operation accepting a card number -- a boundary in the
;;; SHAPE of the API rather than in each application's judgement, because a shape cannot be
;;; forgotten under deadline.

;;; --- idempotency ----------------------------------------------------------

(defun idempotency-key (&optional (prefix "hermes"))
  "A fresh idempotency key, so a retried create cannot double-charge (#50).

Generated here rather than left to the caller because the failure mode of forgetting one is
a duplicate charge, and a default that is safe is worth more than a parameter that is correct
when remembered.

RANDOM KEYS ONLY SOLVE HALF THE PROBLEM, and it is worth knowing which half. A fresh key
makes a RETRY safe -- the same request sent twice by the transport collapses to one. It does
nothing about a USER double-clicking Subscribe, because that is two genuinely different
requests, each with its own fresh key, and the provider will honour both. If that is the
failure you care about -- and a consuming app reports it is the one that actually happens --
derive the key from the intent instead: see DERIVED-IDEMPOTENCY-KEY."
  (format nil "~A-~36R-~36R" prefix (get-universal-time) (random (expt 2 48))))

(defun derived-idempotency-key (&rest parts)
  "An idempotency key derived from PARTS -- the same intent yields the same key.

Pass what identifies the INTENT rather than the request. Two clicks on Subscribe then produce
one checkout session rather than two, which a random key cannot prevent because each click is
a genuinely separate request.

THE RULE FOR CHOOSING PARTS, and it is sharper than merely adding something
distinguishing: every
part should be something that CHANGES EXACTLY WHEN THE USER'S SITUATION CHANGES.

  - A cart id works, because carts are consumed.
  - A period works, because periods end.
  - The timestamp of the customer's last subscription event works, because it does not move
    between two clicks a second apart but moves the instant anything happens to them. An
    application tracking subscriptions already holds it for ordering, so it costs no new
    state.
  - A BARE ENTITY ID DOES NOT WORK, and is the tempting wrong answer.

Why it is worth this much text: a key of customer-plus-price is stable forever, and a
provider typically honours a key for around a day. So a member who subscribes, cancels, and
changes their mind the same afternoon is handed back the original -- already completed --
session, and appears unable to resubscribe. This was found in a real integration, where the
account page hid Subscribe while a subscription existed: the ONLY way to reach that path was
to have just cancelled, so the bug was reachable exactly and only in the case that looks
most like the application being broken.

The trade is the caller's to make and is the mirror of the random key's: a derived key makes
a deliberate repeat of the same purchase look like a duplicate. Choosing parts by the rule
above is what resolves it."
  (format nil "hermes-~(~{~A~^:~}~)" parts))

;;; --- registry + env selection (mirroring hermes' messaging) ---------------

(defvar *impls* (make-hash-table :test #'equal)
  "Map of provider name -> a thunk returning a fresh payment provider.")

(defun register-payment-impl (name constructor)
  "Register CONSTRUCTOR (a thunk) under NAME. Adding a vendor is a new class plus one call
to this, with the selection layer staying neutral."
  (setf (gethash (string-downcase name) *impls*) constructor)
  name)

(defun %selected-name ()
  "HERMES_TRANSPORT=dev|log wins, else HERMES_PAYMENTS_IMPL, else stripe.

A dev transport for payments is not a convenience. A module whose local-dev path reaches a
real vendor is one that gets tested against real money."
  (let ((global (uiop:getenv "HERMES_TRANSPORT")))
    (cond ((and global (member (string-downcase global) '("dev" "log") :test #'string=)) "dev")
          (t (string-downcase (or (uiop:getenv "HERMES_PAYMENTS_IMPL") "stripe"))))))

(defun payments ()
  "The env-configured payment provider. Signals PAYMENT-ERROR when the selected backend is
not registered -- which is what an unloaded provider system looks like."
  (let* ((name (%selected-name))
         (ctor (gethash name *impls*)))
    (unless ctor
      (error 'payment-error
             :detail (format nil "no payment provider registered under ~S (have: ~{~A~^, ~})"
                             name (sort (loop for k being the hash-keys of *impls* collect k)
                                        #'string<))))
    (funcall ctor)))
