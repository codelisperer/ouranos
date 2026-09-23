;;;; dev.lisp --- the dev payments provider: everything in memory, no vendor, no money.
;;;;
;;;; NOT A CONVENIENCE. A module whose local-dev path reaches a real vendor is one that gets
;;;; tested against real money -- and payments is the one domain where "I was only testing"
;;;; is not a recoverable position. So the dev provider is selected by the same
;;;; HERMES_TRANSPORT=dev that already forces the dev transport for email and SMS: one
;;;; switch, whole-satellite, and nothing reaches a vendor.
;;;;
;;;; It is also how the protocol is tested. Everything below is real behaviour of the
;;;; neutral surface -- plural subscriptions, cancel-at-period-end versus now, signature
;;;; verification, the normalized vocabulary -- exercised without a network or a key.

(cl:in-package #:hermes/payments)

(defclass dev-payments (payment-provider)
  ((customers :initform (make-hash-table :test #'equal) :reader dev-customers)
   (subscriptions :initform (make-hash-table :test #'equal) :reader dev-subscriptions)
   (counter :initform 0 :accessor dev-counter)
   (secret :initarg :secret :initform "dev-secret" :reader dev-secret))
  (:documentation "An in-memory payment provider. Renders intent; charges nobody."))

(defun make-dev-payments (&key (secret "dev-secret"))
  (make-instance 'dev-payments :secret secret))

(register-payment-impl "dev" #'make-dev-payments)

(defun %dev-ref (provider prefix)
  (format nil "~A_dev_~D" prefix (incf (dev-counter provider))))

(defmethod create-customer ((p dev-payments) &key email name metadata)
  (declare (ignore metadata))
  (let ((ref (%dev-ref p "cus")))
    (setf (gethash ref (dev-customers p)) (list :email email :name name))
    (log:info "payments dev create-customer" :ref ref)
    ref))

(defmethod create-checkout ((p dev-payments) &key customer-ref mode line-items success-url
                                                  cancel-url idempotency-key metadata
                                                  allow-promotion-codes)
  (declare (ignore line-items cancel-url metadata allow-promotion-codes))
  (let ((key (or idempotency-key (idempotency-key))))
    (log:info "payments dev create-checkout" :customer customer-ref
                                             :mode (string-downcase (princ-to-string mode))
                                             :idempotency key)
    ;; A URL shaped like the real thing, pointing nowhere. The success URL is echoed so a
    ;; local flow can be walked end to end -- and it remains ADVISORY even here.
    (format nil "https://dev.invalid/checkout/~A?return=~A" (%dev-ref p "cs")
            (or success-url ""))))

(defmethod create-portal-session ((p dev-payments) &key customer-ref return-url)
  (declare (ignore return-url))
  (format nil "https://dev.invalid/portal/~A" (or customer-ref "unknown")))

(defun dev-add-subscription (provider sub)
  "Seed a subscription. The dev provider has no checkout completion to react to, so tests
and local flows put state in directly."
  (push sub (gethash (subscription-customer-ref sub) (dev-subscriptions provider)))
  sub)

(defmethod subscriptions-for ((p dev-payments) customer-ref)
  ;; A LIST, always -- including when it is empty, and including when it is one.
  (reverse (gethash customer-ref (dev-subscriptions p))))

(defmethod subscription-state ((p dev-payments) subscription-ref)
  (loop for subs being the hash-values of (dev-subscriptions p)
        do (let ((hit (find subscription-ref subs :key #'subscription-ref :test #'string=)))
             (when hit (return hit)))))

(defmethod cancel-subscription ((p dev-payments) subscription-ref &key (when :period-end))
  (let ((sub (subscription-state p subscription-ref)))
    (unless sub
      (error 'payment-error :detail (format nil "no such subscription: ~S" subscription-ref)))
    ;; The distinction that decides whether access ends now or later, recorded in the STATE
    ;; so a reconciliation read sees it too and not only the event.
    (ecase when
      (:now (setf (subscription-status sub) :canceled
                  (subscription-cancel-at-period-end-p sub) nil))
      (:period-end (setf (subscription-cancel-at-period-end-p sub) t)))
    sub))

(defmethod refund ((p dev-payments) payment-ref &key amount idempotency-key)
  ;; RECORDED, NOT ENFORCED -- the same as `create-checkout' above, and said here because
  ;; the two previously disagreed: that one logged the key and this one declared it IGNORE.
  ;; Neither dedupes. This class keeps `customers' and `subscriptions' tables but no table
  ;; keyed by idempotency key, so there is nothing here to dedupe a repeat against; the real
  ;; guarantee is the provider's, from the `Idempotency-Key' header the Stripe backend
  ;; sends. A reader comparing the two methods should not have to infer that difference
  ;; from one of them ignoring the argument.
  (let ((key (or idempotency-key (idempotency-key))))
    (log:info "payments dev refund" :payment payment-ref :idempotency key))
  (make-refund-record :ref (%dev-ref p "re") :payment-ref payment-ref
                      :amount (or amount (money:make-money 0 "usd"))
                      ;; A refund with no amount is a FULL refund; one with an amount is
                      ;; partial. Providers distinguish these and so must we.
                      :partial-p (and amount t)))

;;; --- webhooks --------------------------------------------------------------

(defun dev-sign (payload &optional (secret "dev-secret"))
  "The dev signature: HMAC-SHA256, the same primitive a real provider uses, so the
verification path under test is the real one and not a stub that always says yes."
  (let ((mac (ironclad:make-mac :hmac
                                (sb-ext:string-to-octets secret :external-format :utf-8)
                                :sha256)))
    (ironclad:update-mac mac (sb-ext:string-to-octets payload :external-format :utf-8))
    (ironclad:byte-array-to-hex-string (ironclad:produce-mac mac))))

(defun %constant-time-equal (a b)
  "Compare without leaking where two signatures diverge."
  (and (= (length a) (length b))
       (zerop (loop for x across a for y across b
                    sum (logxor (char-code x) (char-code y))))))

(defmethod verify-webhook ((p dev-payments) payload signature &key secret)
  ;; Signature FIRST. Nothing in an unverified payload is worth reading, including its type.
  (unless (and signature (%constant-time-equal signature (dev-sign payload (or secret (dev-secret p)))))
    (error 'webhook-signature-invalid))
  (let* ((o (jzon:parse payload))
         (type (or (gethash "type" o) ""))
         (id (or (gethash "id" o) ""))
         (at (let ((v (gethash "occurred_at" o))) (if (integerp v) v 0))))
    (flet ((sub ()
             (let ((s (gethash "subscription" o)))
               (when s
                 (make-subscription
                  :ref (or (gethash "ref" s) "") :customer-ref (or (gethash "customer_ref" s) "")
                  :status (intern (string-upcase (or (gethash "status" s) "active")) :keyword)
                  :current-period-end (let ((v (gethash "current_period_end" s)))
                                        (if (integerp v) v 0))
                  :cancel-at-period-end-p (and (gethash "cancel_at_period_end" s) t)
                  :trial-end (gethash "trial_end" s)
                  :price-ref (gethash "price_ref" s)
                  :product-ref (gethash "product_ref" s))))))
      (let ((kind (cond ((string= type "subscription.changed") kind:Subscription-Changed)
                        ((string= type "subscription.canceled") kind:Subscription-Canceled)
                        ((string= type "trial.will_end") kind:Trial-Will-End)
                        ((string= type "payment.succeeded") kind:Payment-Succeeded)
                        ((string= type "payment.failed") kind:Payment-Failed)
                        ((string= type "dispute.opened") kind:Dispute-Opened)
                        ((string= type "refund.created") kind:Refunded)
                        (t (error 'unmapped-event :event-type type)))))
        (make-event :kind kind :id id :occurred-at at :provider "dev"
                    :subscription (sub) :raw o)))))
