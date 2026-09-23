;;;; stripe.lisp --- Stripe as the first implementation of the neutral protocol (#47).
;;;;
;;;; The protocol was specified and built before this file existed (#48), on purpose:
;;;; building a neutral protocol with a vendor in the room is how the vendor's shape gets
;;;; into it. What that bought is visible here -- this file translates, and adds no concept.
;;;;
;;;; TIME BASE, AND IT IS THE MOST DANGEROUS LINE IN THE FILE. Stripe speaks UNIX epoch
;;;; seconds; this protocol speaks CL UNIVERSAL time, because that is what GET-UNIVERSAL-TIME
;;;; returns and what SUBSCRIPTION-GRANTS-ACCESS-P compares against. They differ by
;;;; +unix-epoch+ = 2208988800 seconds, roughly seventy years.
;;;;
;;;; Passed through unconverted, every period end would sit seventy years in the past, every
;;;; subscription would read as expired, and every member would be denied access -- with no
;;;; error anywhere, because both values are perfectly good integers. Conversion happens once,
;;;; here, at the seam where the vendor's units enter.
;;;;
;;;; HOSTED CHECKOUT ONLY. No operation in this file accepts a card number and there is no
;;;; shape in which one could be passed, which is what holds PCI scope at SAQ-A
;;;; (docs/adr/0002). Elements is deliberately not implemented.

(cl:in-package #:hermes/payments)

(defparameter +unix-epoch+ 2208988800
  "Seconds between the CL universal-time epoch (1900) and the Unix epoch (1970).")

(defun unix->universal (seconds)
  "A Unix timestamp as CL universal time. NIL and 0 pass through as NIL: Stripe uses null
for an absent time, and 0 would otherwise become 1970 rather than nothing."
  (when (and seconds (integerp seconds) (plusp seconds))
    (+ seconds +unix-epoch+)))

;;; --- the provider ---------------------------------------------------------

(defclass stripe-payments (payment-provider)
  ((api-key :initarg :api-key :reader stripe-api-key)
   (webhook-secret :initarg :webhook-secret :reader stripe-webhook-secret)
   (api-base :initarg :api-base :initform "https://api.stripe.com" :reader stripe-api-base)
   ;; The one impure pivot, injectable so the whole backend is testable without a network
   ;; or a key. Production leaves it NIL and the shared client performs the call.
   (perform :initarg :perform :initform nil :reader stripe-perform))
  (:documentation "Stripe, as one implementation of the neutral payments protocol."))

(defun make-stripe-payments (&key api-key webhook-secret
                                  (api-base "https://api.stripe.com") perform)
  "A Stripe backend. Credentials come from the environment when not supplied.

Signals CONFIGURATION-ERROR when a credential is missing, at CONSTRUCTION rather than on the
first charge -- a payments backend that appears to build and fails at the till is worse than
one that refuses to build."
  (let ((key (or api-key (uiop:getenv "STRIPE_SECRET_KEY")))
        (secret (or webhook-secret (uiop:getenv "STRIPE_WEBHOOK_SECRET"))))
    (unless (and key (plusp (length key)))
      (error 'configuration-error :missing "STRIPE_SECRET_KEY"))
    (unless (and secret (plusp (length secret)))
      (error 'configuration-error :missing "STRIPE_WEBHOOK_SECRET"))
    (make-instance 'stripe-payments :api-key key :webhook-secret secret
                                    :api-base api-base :perform perform)))

(register-payment-impl "stripe" #'make-stripe-payments)

;;; --- the wire -------------------------------------------------------------

(defun %stripe-call (p method path &key form idempotency-key)
  "One Stripe API call, returning the parsed JSON body.

Form-encoded going out, JSON coming back -- Stripe's own shape. A non-2xx raises through
ENSURE-2XX carrying Stripe's body, which is where it explains the refusal, and the caller
below turns that into a PAYMENT-ERROR."
  (let* ((url (format nil "~A~A" (stripe-api-base p) path))
         (headers (append (list (cons "Authorization"
                                      (format nil "Bearer ~A" (stripe-api-key p))))
                          (when idempotency-key
                            (list (cons "Idempotency-Key" idempotency-key)))))
         (req (http:make-request :method method :url url :headers headers :content form
                                 :connect-timeout 10 :read-timeout 30)))
    (handler-case
        (let ((resp (apply #'http:send-request req (list (http:ensure-2xx "stripe"))
                           (when (stripe-perform p)
                             (list :perform (stripe-perform p))))))
          (jzon:parse (http:response-body resp)))
      (http:http-error (e)
        (error 'payment-error
               :detail (format nil "stripe ~A ~A: ~@[HTTP ~A ~]~A"
                               method path (http:http-error-status e)
                               (or (http:http-error-body e)
                                   (http:http-error-detail e) "")))))))

(defun %get (o &rest keys)
  "Walk KEYS into a parsed JSON object, tolerating an absent step."
  (let ((node o))
    (dolist (k keys node)
      (unless (hash-table-p node) (return nil))
      (setf node (gethash k node)))))

;;; --- translation: a Stripe subscription -> the neutral record -------------

(defparameter +stripe-status+
  '(("active" . :active) ("trialing" . :trialing) ("past_due" . :past-due)
    ("canceled" . :canceled) ("unpaid" . :unpaid)
    ;; Stripe's two incomplete states mean the first payment never succeeded. Neither
    ;; grants access, and mapping them to :unpaid rather than inventing variants keeps the
    ;; neutral vocabulary closed -- an app cannot act differently on them anyway.
    ("incomplete" . :unpaid) ("incomplete_expired" . :unpaid))
  "Stripe subscription status -> the neutral keyword.")

(defun %stripe->subscription (o)
  "A Stripe subscription object as the neutral SUBSCRIPTION."
  (when (hash-table-p o)
    (let ((item (let ((data (%get o "items" "data")))
                  (when (and data (plusp (length data))) (aref data 0)))))
      (make-subscription
       :ref (or (gethash "id" o) "")
       :customer-ref (let ((c (gethash "customer" o)))
                       (if (stringp c) c (or (%get o "customer" "id") "")))
       :status (or (cdr (assoc (or (gethash "status" o) "") +stripe-status+ :test #'string=))
                   :unpaid)
       ;; UNIX -> UNIVERSAL. See the header: unconverted, everything reads as expired.
       :current-period-end (or (unix->universal (gethash "current_period_end" o)) 0)
       :cancel-at-period-end-p (and (gethash "cancel_at_period_end" o) t)
       :trial-end (unix->universal (gethash "trial_end" o))
       ;; The price is what they pay; the product is the TIER. Both, because a price is
       ;; immutable and a repricing changes only the first.
       :price-ref (and item (%get item "price" "id"))
       :product-ref (and item (let ((prod (%get item "price" "product")))
                                (if (stringp prod) prod (%get item "price" "product" "id"))))))))

;;; --- operations -----------------------------------------------------------

(defmethod create-customer ((p stripe-payments) &key email name metadata)
  (declare (ignore metadata))
  (let ((o (%stripe-call p :post "/v1/customers"
                         :form (append (when email (list (cons "email" email)))
                                       (when name (list (cons "name" name))))
                         :idempotency-key (idempotency-key "cus"))))
    (or (gethash "id" o)
        (error 'payment-error :detail "stripe returned a customer with no id"))))

(defmethod create-checkout ((p stripe-payments) &key customer-ref mode line-items
                                                     success-url cancel-url
                                                     idempotency-key metadata
                                                     allow-promotion-codes)
  (declare (ignore metadata))
  (let* ((form (append (list (cons "mode" (string-downcase (princ-to-string
                                                            (or mode :subscription))))
                             (cons "success_url" (or success-url ""))
                             (cons "cancel_url" (or cancel-url "")))
                       (when customer-ref (list (cons "customer" customer-ref)))
                       ;; Without this the coupons an operator creates are unreachable: they
                       ;; exist, the provider accepts them, and no buyer can enter one.
                       (when allow-promotion-codes
                         (list (cons "allow_promotion_codes" "true")))
                       ;; LINE-ITEMS is a list of (price-ref . quantity); Stripe wants them
                       ;; index-bracketed, which is form encoding rather than a nested body.
                       (loop for (price . qty) in line-items
                             for i from 0
                             append (list (cons (format nil "line_items[~D][price]" i) price)
                                          (cons (format nil "line_items[~D][quantity]" i)
                                                (princ-to-string (or qty 1)))))))
         (o (%stripe-call p :post "/v1/checkout/sessions" :form form
                          :idempotency-key (or idempotency-key (idempotency-key "cs")))))
    (or (gethash "url" o)
        (error 'payment-error :detail "stripe returned a checkout session with no url"))))

(defmethod create-portal-session ((p stripe-payments) &key customer-ref return-url)
  (let ((o (%stripe-call p :post "/v1/billing_portal/sessions"
                         :form (append (list (cons "customer" (or customer-ref "")))
                                       (when return-url
                                         (list (cons "return_url" return-url)))))))
    (or (gethash "url" o)
        (error 'payment-error :detail "stripe returned a portal session with no url"))))

(defmethod subscriptions-for ((p stripe-payments) customer-ref)
  "EVERY subscription this customer holds. A list, always -- see the protocol."
  (let* ((o (%stripe-call p :get (format nil "/v1/subscriptions?customer=~A&status=all"
                                         customer-ref)))
         (data (gethash "data" o)))
    (when data (coerce (map 'list #'%stripe->subscription data) 'list))))

(defmethod subscription-state ((p stripe-payments) subscription-ref)
  "NIL means GONE; a signal means UNKNOWN. Stripe's 404 is the only thing that means absent;
anything else -- a 500, a timeout, an expired key -- signals, so a reconciliation run leaves
the record alone rather than treating our outage as their cancellation."
  (handler-case
      (%stripe->subscription
       (%stripe-call p :get (format nil "/v1/subscriptions/~A" subscription-ref)))
    (payment-error (e)
      (if (search "HTTP 404" (or (payment-error-detail e) ""))
          nil
          (error e)))))

(defmethod cancel-subscription ((p stripe-payments) subscription-ref &key (when :period-end))
  (%stripe->subscription
   (ecase when
     (:now (%stripe-call p :delete (format nil "/v1/subscriptions/~A" subscription-ref)))
     (:period-end (%stripe-call p :post (format nil "/v1/subscriptions/~A" subscription-ref)
                                :form (list (cons "cancel_at_period_end" "true")))))))

(defmethod refund ((p stripe-payments) payment-ref &key amount idempotency-key)
  (let ((o (%stripe-call p :post "/v1/refunds"
                         :form (append (list (cons "payment_intent" payment-ref))
                                       (when amount
                                         (list (cons "amount"
                                                     (princ-to-string
                                                      (money:money-minor amount))))))
                         :idempotency-key (or idempotency-key (idempotency-key "re")))))
    (make-refund-record
     :ref (or (gethash "id" o) "")
     :payment-ref payment-ref
     :amount (or amount (money:make-money (or (gethash "amount" o) 0)
                                          (or (gethash "currency" o) "usd")))
     :partial-p (and amount t))))

;;; --- webhooks -------------------------------------------------------------
;;;
;;; Stripe signs `t=<unix>,v1=<hex>` where the signed payload is the timestamp, a period, and
;;; the RAW BODY. Raw matters: re-serialising parsed JSON changes bytes and the signature
;;; stops verifying, so a caller must hand over exactly what arrived.
;;;
;;; MULTIPLE v1 VALUES ARE LEGAL and are how secret rotation works -- during a roll, Stripe
;;; signs with both. Accepting only the first would make every rotation an outage.

(defparameter *webhook-tolerance* 300
  "Seconds a webhook timestamp may differ from now, in EITHER direction.

Both directions on purpose. Too old is a replay; too far in the future is a clock that cannot
be trusted to bound the first, and accepting it would let a forged future timestamp buy an
attacker an arbitrarily long replay window.")

(defun %parse-stripe-signature (header)
  "`t=123,v1=abc,v1=def` -> (values timestamp (list signatures))."
  (let ((timestamp nil) (sigs '()))
    (dolist (part (uiop:split-string (or header "") :separator '(#\,)))
      (let* ((trimmed (string-trim " " part))
             (eq-pos (position #\= trimmed)))
        (when eq-pos
          (let ((k (subseq trimmed 0 eq-pos))
                (v (subseq trimmed (1+ eq-pos))))
            (cond ((string= k "t") (setf timestamp (ignore-errors (parse-integer v))))
                  ((string= k "v1") (push v sigs)))))))
    (values timestamp (nreverse sigs))))

(defun %hmac-sha256-hex (secret message)
  (let ((mac (ironclad:make-mac :hmac
                                (sb-ext:string-to-octets secret :external-format :utf-8)
                                :sha256)))
    (ironclad:update-mac mac (sb-ext:string-to-octets message :external-format :utf-8))
    (ironclad:byte-array-to-hex-string (ironclad:produce-mac mac))))

(defparameter +stripe-events+
  '(("customer.subscription.created" . :changed)
    ("customer.subscription.updated" . :changed)
    ("customer.subscription.deleted" . :canceled)
    ("customer.subscription.trial_will_end" . :trial)
    ("invoice.paid" . :paid)
    ("invoice.payment_succeeded" . :paid)
    ("invoice.payment_failed" . :failed)
    ("charge.dispute.created" . :dispute)
    ("charge.refunded" . :refunded)
    ("refund.created" . :refunded))
  "Stripe event type -> an internal tag, mapped to a neutral kind below. Anything absent is
reported as UNMAPPED-EVENT rather than widening the neutral vocabulary.")

(defmethod verify-webhook ((p stripe-payments) payload signature &key secret)
  "Verify PAYLOAD's Stripe-Signature and parse it into a neutral EVENT.

PAYLOAD must be the RAW request body. Verification happens before parsing: nothing in an
unverified payload is worth reading, including its type."
  (let ((whsec (or secret (stripe-webhook-secret p))))
    (multiple-value-bind (timestamp sigs) (%parse-stripe-signature signature)
      (unless (and timestamp sigs)
        (error 'webhook-signature-invalid))
      ;; Freshness first: a signature that verifies over an ancient timestamp is a replay,
      ;; and the cheapest check should also be the earliest.
      (let ((skew (abs (- (- (get-universal-time) +unix-epoch+) timestamp))))
        (when (> skew *webhook-tolerance*)
          (error 'webhook-signature-invalid)))
      (let ((expected (%hmac-sha256-hex whsec (format nil "~D.~A" timestamp payload))))
        ;; Constant-time compare, and ANY of the offered v1 values may match -- that is how
        ;; secret rotation works, and rejecting all but the first turns a roll into an outage.
        (unless (some (lambda (s) (%constant-time-equal s expected)) sigs)
          (error 'webhook-signature-invalid))))
    (let* ((o (jzon:parse payload))
           (type (or (gethash "type" o) ""))
           (tag (cdr (assoc type +stripe-events+ :test #'string=)))
           (object (%get o "data" "object")))
      (unless tag (error 'unmapped-event :event-type type))
      (let ((envelope (list :id (or (gethash "id" o) "")
                            ;; UNIX -> UNIVERSAL again. This is the ordering key that stops a
                            ;; late `updated` overwriting a newer `canceled`, so a wrong base
                            ;; here would silently restore access to people who left.
                            :occurred-at (or (unix->universal (gethash "created" o)) 0)
                            :provider "stripe"
                            :raw o)))
        (ecase tag
          (:changed (apply #'make-event :kind kind:Subscription-Changed
                           :subscription (%stripe->subscription object) envelope))
          (:canceled (apply #'make-event :kind kind:Subscription-Canceled
                            :subscription (%stripe->subscription object) envelope))
          (:trial (apply #'make-event :kind kind:Trial-Will-End
                         :subscription (%stripe->subscription object) envelope))
          (:paid (apply #'make-event :kind kind:Payment-Succeeded
                        :payment (%stripe->payment object :succeeded) envelope))
          (:failed (apply #'make-event :kind kind:Payment-Failed
                          :payment (%stripe->payment object :failed) envelope))
          (:dispute (apply #'make-event :kind kind:Dispute-Opened
                           :dispute (%stripe->dispute object) envelope))
          (:refunded (apply #'make-event :kind kind:Refunded
                            :refund (%stripe->refund object) envelope)))))))

(defun %stripe->payment (o status)
  (when (hash-table-p o)
    (make-payment :ref (or (gethash "id" o) "")
                  :subscription-ref (let ((s (gethash "subscription" o)))
                                      (if (stringp s) s nil))
                  :amount (money:make-money (or (gethash "amount_paid" o)
                                                (gethash "amount_due" o)
                                                (gethash "amount" o) 0)
                                            (or (gethash "currency" o) "usd"))
                  :status status)))

(defun %stripe->dispute (o)
  (when (hash-table-p o)
    (make-dispute :ref (or (gethash "id" o) "")
                  :payment-ref (let ((c (gethash "charge" o))) (if (stringp c) c ""))
                  :amount (money:make-money (or (gethash "amount" o) 0)
                                            (or (gethash "currency" o) "usd"))
                  :status :open)))

(defun %stripe->refund (o)
  (when (hash-table-p o)
    (let ((refunded (or (gethash "amount_refunded" o) (gethash "amount" o) 0))
          (total (gethash "amount" o)))
      (make-refund-record
       :ref (or (gethash "id" o) "")
       :payment-ref (let ((c (or (gethash "charge" o) (gethash "payment_intent" o))))
                      (if (stringp c) c ""))
       :amount (money:make-money refunded (or (gethash "currency" o) "usd"))
       ;; A refund is not a cancellation, and a PARTIAL refund is not a full one -- an app
       ;; shows different words for each.
       :partial-p (and total (integerp total) (< refunded total))))))
