;;;; tests/payments.lisp --- the neutral payments protocol (pre-publication issue 48), and pre-publication issue 50's constraints.
;;;;
;;;; Two kinds of test here. The ORDINARY ones check the protocol does what it says. The
;;;; ones that matter check the properties an application would otherwise discover in
;;;; production, with money involved:
;;;;
;;;;   - a customer may hold SEVERAL subscriptions, so nothing returns "the" one
;;;;   - a tampered payload does not verify
;;;;   - a replayed event is recognisable as a replay (the id is stable)
;;;;   - out-of-order delivery is survivable, because ordering is CARRIED not inferred
;;;;   - cancel-at-period-end is distinguishable from cancel-now
;;;;   - a refund is not a cancellation
;;;;
;;;; None of this needs a vendor, a key or a network: the dev provider is a real
;;;; implementation of the neutral surface, and its signature path uses the same HMAC-SHA256
;;;; a real provider does rather than a stub that always says yes.

(cl:defpackage #:hermes/payments/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:pay #:hermes/payments)
                    (#:kind #:hermes/payments/kind)
                    (#:money #:hermes/payments/money)
                    (#:jzon #:com.inuoe.jzon))
  (:export #:run-tests))
(cl:in-package #:hermes/payments/tests)

(def-suite payments :description "The neutral payments protocol.")
(defun run-tests () (run! 'payments))
(in-suite payments)

(defun %provider () (pay:make-dev-payments))

(defun %event-json (&key (type "subscription.changed") (id "evt_1") (occurred-at 1000)
                         (sub-ref "sub_1") (customer-ref "cus_1") (status "active")
                         (period-end 5000) (cancel-at-period-end nil))
  (let ((sub (make-hash-table :test 'equal))
        (o (make-hash-table :test 'equal)))
    (setf (gethash "ref" sub) sub-ref
          (gethash "customer_ref" sub) customer-ref
          (gethash "status" sub) status
          (gethash "current_period_end" sub) period-end
          (gethash "cancel_at_period_end" sub) cancel-at-period-end)
    (setf (gethash "type" o) type
          (gethash "id" o) id
          (gethash "occurred_at" o) occurred-at
          (gethash "subscription" o) sub)
    (jzon:stringify o)))

;;; --- the assumption that was nearly wrong ----------------------------------

(test a-customer-may-hold-several-subscriptions
  ;; The correction that reshaped this protocol. A per-group tier means one customer holds
  ;; several concurrently; a surface returning "the" subscription forecloses that for every
  ;; consumer at once.
  (let ((p (%provider)))
    (pay:dev-add-subscription p (pay:make-subscription :ref "sub_a" :customer-ref "cus_1"))
    (pay:dev-add-subscription p (pay:make-subscription :ref "sub_b" :customer-ref "cus_1"))
    (let ((subs (pay:subscriptions-for p "cus_1")))
      (is (= 2 (length subs)))
      (is (equal '("sub_a" "sub_b") (mapcar #'pay:subscription-ref subs))))))

(test subscriptions-for-returns-a-list-even-when-empty-or-single
  ;; The shape must not vary with the count, or callers grow a special case that becomes
  ;; the assumption all over again.
  (let ((p (%provider)))
    (is (null (pay:subscriptions-for p "nobody")))
    (pay:dev-add-subscription p (pay:make-subscription :ref "sub_a" :customer-ref "cus_1"))
    (is (listp (pay:subscriptions-for p "cus_1")))
    (is (= 1 (length (pay:subscriptions-for p "cus_1"))))))

(test subscriptions-for-is-the-reconciliation-path
  ;; Not a convenience accessor: without an authoritative read, the only recovery from a
  ;; missed webhook is a human noticing.
  (let ((p (%provider)))
    (pay:dev-add-subscription p (pay:make-subscription :ref "sub_a" :customer-ref "cus_1"
                                                       :status :active
                                                       :current-period-end 9999))
    (let ((s (first (pay:subscriptions-for p "cus_1"))))
      (is (eq :active (pay:subscription-status s)))
      (is (= 9999 (pay:subscription-current-period-end s))
          "current state, sufficient to repair local drift without replaying history"))))

;;; --- cancellation semantics ------------------------------------------------

(test cancel-at-period-end-is-distinguishable-from-cancel-now
  ;; Revoking on a cancellation meant to take effect at period end is a support ticket
  ;; every time, so the difference is in the STATE and not only in the event.
  (let ((p (%provider)))
    (pay:dev-add-subscription p (pay:make-subscription :ref "sub_a" :customer-ref "cus_1"
                                                       :status :active))
    (let ((s (pay:cancel-subscription p "sub_a" :when :period-end)))
      (is (pay:subscription-cancel-at-period-end-p s))
      (is (eq :active (pay:subscription-status s))
          "still active until the period ends -- access must NOT be revoked here"))))

(test cancel-now-ends-it-immediately
  (let ((p (%provider)))
    (pay:dev-add-subscription p (pay:make-subscription :ref "sub_a" :customer-ref "cus_1"
                                                       :status :active))
    (let ((s (pay:cancel-subscription p "sub_a" :when :now)))
      (is (eq :canceled (pay:subscription-status s)))
      (is (not (pay:subscription-cancel-at-period-end-p s))))))

(test a-refund-is-not-a-cancellation
  ;; They often coincide and mean different things about intent. An application that
  ;; conflates them revokes access it was never asked to revoke.
  (let* ((p (%provider))
         (r (pay:refund p "pay_1" :amount (money:make-money 500 "usd"))))
    (is (pay:refund-record-p r))
    (is (pay:refund-record-partial-p r) "a part-refund is partial")
    (is (= 500 (money:money-minor (pay:refund-record-amount r))))
    (is (string= "usd" (money:money-currency (pay:refund-record-amount r))))))

(test a-refund-with-no-amount-is-a-full-refund
  ;; Providers distinguish full from partial and so must we -- the difference decides
  ;; whether an application shows "refunded" or "partially refunded".
  (let* ((p (%provider))
         (r (pay:refund p "pay_1")))
    (is (not (pay:refund-record-partial-p r)))))

;;; --- webhook verification (pre-publication issue 50) --------------------------------------------

(test a-correctly-signed-webhook-verifies-and-normalizes
  (let* ((p (%provider))
         (payload (%event-json))
         (ev (pay:verify-webhook p payload (pay:dev-sign payload))))
    (is (string= "subscription-changed" (pay:event-kind-name ev)))
    (is (string= "evt_1" (pay:event-id ev)))
    (is (= 1000 (pay:event-occurred-at ev)))
    (is (string= "sub_1" (pay:subscription-ref (pay:event-subscription ev))))))

(test a-tampered-payload-does-not-verify
  ;; pre-publication issue 50. The signature is over the bytes; changing the amount changes the bytes.
  (let* ((p (%provider))
         (payload (%event-json :status "active"))
         (sig (pay:dev-sign payload))
         (forged (%event-json :status "canceled")))
    (signals pay:webhook-signature-invalid (pay:verify-webhook p forged sig))))

(test a-missing-or-empty-signature-is-rejected
  (let* ((p (%provider)) (payload (%event-json)))
    (signals pay:webhook-signature-invalid (pay:verify-webhook p payload nil))
    (signals pay:webhook-signature-invalid (pay:verify-webhook p payload ""))))

(test a-signature-from-another-secret-is-rejected
  (let* ((p (%provider)) (payload (%event-json)))
    (signals pay:webhook-signature-invalid
      (pay:verify-webhook p payload (pay:dev-sign payload "someone-elses-secret")))))

(test a-replayed-event-is-recognisable-because-the-id-is-stable
  ;; pre-publication issue 50 asks us to EXPOSE ids so an application can dedupe; the protocol cannot dedupe for
  ;; it, because that needs durable storage hermes is not permitted to have. What we owe is
  ;; a stable id -- verified here by replaying the identical delivery.
  (let* ((p (%provider))
         (payload (%event-json :id "evt_dup"))
         (sig (pay:dev-sign payload))
         (a (pay:verify-webhook p payload sig))
         (b (pay:verify-webhook p payload sig)))
    (is (string= (pay:event-id a) (pay:event-id b))
        "a replay must be identifiable as the same event")
    (is (string= "evt_dup" (pay:event-id a)))))

(test out-of-order-delivery-is-survivable-because-ordering-is-carried
  ;; THE failure this prevents: a retried "changed" overwriting a later "canceled" and
  ;; silently restoring access to somebody who left. Arrival order cannot be trusted, so
  ;; the provider's own timestamp travels with the event.
  (let* ((p (%provider))
         (later (%event-json :id "evt_2" :type "subscription.canceled" :occurred-at 2000))
         (earlier (%event-json :id "evt_1" :type "subscription.changed" :occurred-at 1000))
         ;; delivered in the WRONG order, which is normal
         (first-seen (pay:verify-webhook p later (pay:dev-sign later)))
         (second-seen (pay:verify-webhook p earlier (pay:dev-sign earlier))))
    (is (> (pay:event-occurred-at first-seen) (pay:event-occurred-at second-seen))
        "the app can tell the one that arrived second happened FIRST")
    (is (string= "subscription-canceled" (pay:event-kind-name first-seen)))))

(test an-event-outside-the-vocabulary-is-reported-not-invented
  ;; A neutral protocol that grows a variant per provider is a union of vendors.
  (let* ((p (%provider))
         (payload (%event-json :type "invoice.some_stripe_specific_thing")))
    (signals pay:unmapped-event (pay:verify-webhook p payload (pay:dev-sign payload)))))

(test verification-happens-before-parsing
  ;; Nothing in an unverified payload is worth reading, including its type -- so an
  ;; unsigned payload carrying an unmappable type must fail on the SIGNATURE.
  (let ((p (%provider))
        (payload (%event-json :type "totally.unknown")))
    (handler-case (progn (pay:verify-webhook p payload "not-a-signature")
                         (fail "should have been rejected"))
      (pay:webhook-signature-invalid () (pass))
      (pay:unmapped-event () (fail "parsed before verifying")))))

;;; --- the vocabulary --------------------------------------------------------

(test the-vocabulary-is-seven-kinds-and-each-has-a-stable-name
  (let ((names (mapcar #'kind:kind-name
                       (list kind:Subscription-Changed kind:Subscription-Canceled
                             kind:Trial-Will-End kind:Payment-Succeeded
                             kind:Payment-Failed kind:Dispute-Opened kind:Refunded))))
    (is (= 7 (length names)))
    (is (= 7 (length (remove-duplicates names :test #'string=))) "names must be distinct")
    (is (member "dispute-opened" names :test #'string=))))

(test kinds-compare-by-identity-not-by-spelling
  (is (kind:kind= kind:Refunded kind:Refunded))
  (is (not (kind:kind= kind:Refunded kind:Payment-Succeeded))))

;;; --- the protocol's own guarantees ------------------------------------------

(test an-unimplemented-operation-says-so-rather-than-returning-nil
  ;; A gap in a backend and a bad afternoon at a vendor are different things, and an
  ;; application retries only the second.
  (let ((bare (make-instance 'pay:payment-provider)))
    (signals pay:unsupported-operation (pay:subscriptions-for bare "cus_1"))
    (signals pay:unsupported-operation (pay:create-customer bare :email "a@b.c"))))

(test idempotency-keys-are-unique
  ;; pre-publication issue 50: a retried create must not double-charge.
  (let ((keys (loop repeat 50 collect (pay:idempotency-key))))
    (is (= 50 (length (remove-duplicates keys :test #'string=))))))

(test the-dev-provider-is-selected-by-the-same-switch-as-email-and-sms
  ;; One transport switch for the whole satellite. A payments module whose local-dev path
  ;; reaches a real vendor is one that gets tested against real money.
  (let ((saved (uiop:getenv "HERMES_TRANSPORT")))
    (unwind-protect
         (progn (setf (uiop:getenv "HERMES_TRANSPORT") "dev")
                (is (typep (pay:payments) 'pay:dev-payments)))
      (if saved
          (setf (uiop:getenv "HERMES_TRANSPORT") saved)
          (sb-posix:unsetenv "HERMES_TRANSPORT")))))

(test checkout-returns-a-url-and-the-success-url-is-only-advisory
  (let* ((p (%provider))
         (url (pay:create-checkout p :customer-ref "cus_1" :mode :subscription
                                     :success-url "https://app.example/done")))
    (is (stringp url))
    (is (search "checkout" url))))

;;; --- Money (pre-publication issue 49) -----------------------------------------------------------
;;;
;;; What this type is FOR is narrower than "amounts cannot mix units", and the tests say
;;; which. A currency arrives at runtime from a provider payload, so it cannot be in the
;;; type and a mismatch cannot be a compile error at that boundary. What is reachable, and
;;; what these pin, is that an amount carries its currency and the arithmetic refuses to
;;; combine two that disagree -- returning None rather than a plausible wrong number.

(test money-carries-its-currency
  (let ((m (money:make-money 1050 "usd")))
    (is (= 1050 (money:money-minor m)) "minor units -- 1050 is $10.50, never 10.5")
    (is (string= "usd" (money:money-currency m)))))

(test adding-same-currency-amounts-works
  (let ((sum (money:money+ (money:make-money 100 "usd") (money:make-money 250 "usd"))))
    (is (money:money-ok? sum) "same currency must add")
    (is (= 350 (money:money-minor (money:money-or sum (money:make-money 0 "usd")))))))

(test adding-different-currencies-refuses-rather-than-guessing
  ;; THE property. There is no sane default for usd + eur -- the only honest conversion
  ;; needs a rate this library does not have -- so it returns None instead of a number
  ;; somebody will treat as real.
  (let ((sum (money:money+ (money:make-money 100 "usd") (money:make-money 100 "eur"))))
    (is (not (money:money-ok? sum)) "usd + eur must be None, not a coerced total")))

(test equality-includes-the-currency
  ;; 100 usd is not 100 eur, and is not equal to it in any sense this library endorses.
  (is (money:money= (money:make-money 100 "usd") (money:make-money 100 "usd")))
  (is (not (money:money= (money:make-money 100 "usd") (money:make-money 100 "eur"))))
  (is (not (money:money= (money:make-money 100 "usd") (money:make-money 101 "usd")))))

(test subtraction-may-go-negative
  ;; A refund larger than a payment is a real state and not this type's business to forbid.
  (let ((d (money:money- (money:make-money 100 "usd") (money:make-money 250 "usd"))))
    (is (money:money-ok? d))
    (is (= -150 (money:money-minor (money:money-or d (money:make-money 0 "usd")))))))

(test a-config-missing-a-credential-is-incomplete
  ;; So a missing key is found when the provider is built rather than on the first charge.
  (is (money:config-complete? (money:make-config "sk_test" "whsec" "https://api.example")))
  (is (not (money:config-complete? (money:make-config "" "whsec" "https://api.example"))))
  (is (not (money:config-complete? (money:make-config "sk_test" "" "https://api.example")))))

(test the-fallback-must-be-named-at-the-call-site
  ;; There is deliberately no "just give me the value" accessor: an amount that silently
  ;; became zero because two currencies disagreed is the wrong number this type exists to
  ;; prevent. A caller that wants a default has to say so.
  (let ((mismatch (money:money+ (money:make-money 100 "usd") (money:make-money 1 "gbp"))))
    (is (not (money:money-ok? mismatch)))
    (is (= 7 (money:money-minor (money:money-or mismatch (money:make-money 7 "usd"))))
        "the caller's fallback is what comes back, not a zero nobody chose")))

;;; --- applying events safely --------------------------------------------------
;;;
;;; From a consuming app running a real payment integration, offered before pre-publication issue 47 was built
;;; rather than after. Each is provider-independent and each is a failure that produces no
;;; error when it happens -- which is why they are worth having in the framework rather
;;; than rediscovered per application.

(test dedupe-and-ordering-are-different-problems
  ;; Deduplicating on event id handles at-least-once delivery. It does NOT handle a retried
  ;; `changed` arriving after a `canceled` -- which silently restores access to somebody who
  ;; left. Arrival order cannot decide it; the provider's timestamp can.
  (let* ((p (%provider))
         (canceled (%event-json :id "e2" :type "subscription.canceled" :occurred-at 2000))
         (changed (%event-json :id "e1" :type "subscription.changed" :occurred-at 1000))
         (applied-cancel (pay:verify-webhook p canceled (pay:dev-sign canceled)))
         (late-change (pay:verify-webhook p changed (pay:dev-sign changed))))
    ;; the cancel is applied first; its timestamp becomes the watermark
    (is (pay:event-supersedes-p applied-cancel nil) "anything supersedes nothing")
    (is (not (pay:event-supersedes-p late-change (pay:event-occurred-at applied-cancel)))
        "A LATE `changed` MUST NOT BE APPLIED OVER A NEWER `canceled` -- this is the
         silent re-grant of access to somebody who left")))

(test an-event-newer-than-what-was-applied-is-applied
  (let* ((p (%provider))
         (json (%event-json :occurred-at 5000))
         (ev (pay:verify-webhook p json (pay:dev-sign json))))
    (is (pay:event-supersedes-p ev 4999))
    (is (not (pay:event-supersedes-p ev 5000)) "equal is not newer -- a replay is not news")))

(test entitlement-is-the-status-AND-the-period-never-the-status-alone
  ;; A stored status goes stale silently: if a terminal event never arrives, the record says
  ;; `active` forever and keeps granting access. The period end is a value the app already
  ;; holds, needs no network, and cannot be missed.
  (let ((live (pay:make-subscription :ref "s" :customer-ref "c" :status :active
                                     :current-period-end 9999))
        (stale (pay:make-subscription :ref "s" :customer-ref "c" :status :active
                                      :current-period-end 100)))
    (is (pay:subscription-grants-access-p live 5000))
    (is (not (pay:subscription-grants-access-p stale 5000))
        "an `active` record whose period elapsed must NOT grant access")))

(test a-cancellation-at-period-end-still-grants-access-until-it-ends
  ;; The whole reason cancel-at-period-end is distinguished from cancel-now. Revoking here
  ;; is the support ticket.
  (let ((s (pay:make-subscription :ref "s" :customer-ref "c" :status :active
                                  :current-period-end 9999
                                  :cancel-at-period-end-p t)))
    (is (pay:subscription-grants-access-p s 5000))
    (is (not (pay:subscription-grants-access-p s 10000)) "and stops when the period does")))

(test a-trialing-subscription-grants-access-and-a-terminal-one-does-not
  (dolist (status '(:active :trialing))
    (is (pay:subscription-grants-access-p
         (pay:make-subscription :ref "s" :customer-ref "c" :status status
                                :current-period-end 9999)
         5000)
        "~A must grant" status))
  (dolist (status '(:canceled :unpaid :past-due))
    (is (not (pay:subscription-grants-access-p
              (pay:make-subscription :ref "s" :customer-ref "c" :status status
                                     :current-period-end 9999)
              5000))
        "~A must not grant on the status alone" status)))

;;; --- idempotency: two different failures ------------------------------------

(test a-derived-key-is-stable-for-the-same-intent
  ;; A random key makes a RETRY safe. It does nothing about a user double-clicking
  ;; Subscribe, because that is two genuinely different requests each with its own fresh
  ;; key -- and a consuming app reports the double-click is the failure that actually
  ;; happens.
  (is (string= (pay:derived-idempotency-key "cus_1" "price_pro")
               (pay:derived-idempotency-key "cus_1" "price_pro"))
      "the same intent must collapse to one key")
  (is (string/= (pay:derived-idempotency-key "cus_1" "price_pro")
                (pay:derived-idempotency-key "cus_2" "price_pro"))
      "different customers are different intents")
  (is (string/= (pay:derived-idempotency-key "cus_1" "price_pro")
                (pay:derived-idempotency-key "cus_1" "price_basic"))
      "different prices are different intents"))

(test a-random-key-is-fresh-every-time-which-is-the-point-and-the-limit
  (is (string/= (pay:idempotency-key) (pay:idempotency-key))
      "safe for retries, and deliberately useless against a double click"))

(test a-derived-key-must-move-when-the-users-situation-moves
  ;; The rule for choosing parts, from a live bug in a real integration: a bare entity id is
  ;; stable FOREVER, and providers honour a key for about a day. So customer+price hands a
  ;; member who subscribed, cancelled and changed their mind the same afternoon their old,
  ;; already-completed session -- and they appear unable to resubscribe.
  (let ((before (pay:derived-idempotency-key "cus_1" "price_pro" 1000))
        (same-moment (pay:derived-idempotency-key "cus_1" "price_pro" 1000))
        (after-something-happened (pay:derived-idempotency-key "cus_1" "price_pro" 2000)))
    (is (string= before same-moment)
        "two clicks a second apart are one intent and must collapse")
    (is (string/= before after-something-happened)
        "once their subscription changed, a new attempt is a NEW intent -- a key that
         cannot express that is the bug")))

;;; --- what was renewed, not merely that something was -----------------------

(test a-subscription-carries-what-it-is-a-subscription-TO
  ;; Without these an application receiving a renewal cannot tell what was renewed except by
  ;; reaching into the provider's raw payload -- the exact coupling this protocol removes.
  (let ((s (pay:make-subscription :ref "sub_1" :customer-ref "cus_1"
                                  :price-ref "price_old" :product-ref "prod_pro")))
    (is (string= "price_old" (pay:subscription-price-ref s)))
    (is (string= "prod_pro" (pay:subscription-product-ref s)))))

(test price-and-product-are-two-fields-because-a-price-is-immutable
  ;; Repricing creates a new price and archives the old, so the PRODUCT ref survives a
  ;; repricing and the PRICE ref does not. One column cannot carry both facts, and an
  ;; application that collapses them loses the ability to resolve an old price at all.
  (let ((before (pay:make-subscription :ref "s" :customer-ref "c"
                                       :price-ref "price_v1" :product-ref "prod_pro"))
        (after (pay:make-subscription :ref "s2" :customer-ref "c2"
                                      :price-ref "price_v2" :product-ref "prod_pro")))
    (is (string/= (pay:subscription-price-ref before) (pay:subscription-price-ref after))
        "a repricing changes the price ref")
    (is (string= (pay:subscription-product-ref before) (pay:subscription-product-ref after))
        "and does NOT change the product ref -- which is what makes the old one resolvable")))

(test a-webhook-carries-the-price-so-a-renewal-can-be-mapped-to-a-tier
  (let* ((p (%provider))
         (json (let ((o (com.inuoe.jzon:parse (%event-json)))) o)))
    (setf (gethash "price_ref" (gethash "subscription" json)) "price_old"
          (gethash "product_ref" (gethash "subscription" json)) "prod_pro")
    (let* ((payload (com.inuoe.jzon:stringify json))
           (ev (pay:verify-webhook p payload (pay:dev-sign payload))))
      (is (string= "price_old" (pay:subscription-price-ref (pay:event-subscription ev)))
          "the renewal names the price the member is actually billed at -- which may be one
           the catalogue no longer offers, and must still resolve"))))

;;; --- one tier, many live prices ---------------------------------------------
;;;
;;; A hard requirement from a consuming app, and not a promotional one: a large share of its
;;; intended membership is in countries where the standard price is a serious monthly sum,
;;; and a meaningful share are students. Both are permanent facts about who the members are.
;;; A protocol assuming one price per tier prices every consuming app for North America.

(test one-product-may-be-sold-at-several-live-prices-at-once
  ;; Monthly and annual, several currencies, student and regional rates, and cohorts left on
  ;; a price no longer offered -- all simultaneously live, all the same tier.
  (let ((subs (list (pay:make-subscription :ref "s1" :customer-ref "c1"
                                           :price-ref "price_standard_usd"
                                           :product-ref "prod_pro")
                    (pay:make-subscription :ref "s2" :customer-ref "c2"
                                           :price-ref "price_student"
                                           :product-ref "prod_pro")
                    (pay:make-subscription :ref "s3" :customer-ref "c3"
                                           :price-ref "price_annual_eur"
                                           :product-ref "prod_pro")
                    (pay:make-subscription :ref "s4" :customer-ref "c4"
                                           :price-ref "price_retired_2024"
                                           :product-ref "prod_pro"))))
    (is (= 4 (length (remove-duplicates (mapcar #'pay:subscription-price-ref subs)
                                        :test #'string=)))
        "four distinct prices")
    (is (= 1 (length (remove-duplicates (mapcar #'pay:subscription-product-ref subs)
                                        :test #'string=)))
        "ONE product -- which is the tier, and is what entitlement resolves on")))

(test entitlement-does-not-vary-with-what-was-paid
  ;; The discrimination bug this prevents looks harmless at one call site and is systematic
  ;; in aggregate. A member on a student price has exactly the access of one paying standard.
  (let ((student (pay:make-subscription :ref "s1" :customer-ref "c1" :status :active
                                        :current-period-end 9999
                                        :price-ref "price_student" :product-ref "prod_pro"))
        (standard (pay:make-subscription :ref "s2" :customer-ref "c2" :status :active
                                         :current-period-end 9999
                                         :price-ref "price_standard" :product-ref "prod_pro")))
    (is (eq (pay:subscription-grants-access-p student 5000)
            (pay:subscription-grants-access-p standard 5000))
        "the same tier grants the same access regardless of price")))

(test a-subscription-record-carries-no-amount-at-all
  ;; Deliberate. Amounts are billing facts and live on payments, disputes and refunds.
  ;; Entitlement is not a billing fact, and an API offering an amount here would invite a
  ;; caller to reason from it.
  (let ((slots (mapcar #'sb-mop:slot-definition-name
                       (sb-mop:class-slots (find-class 'pay:subscription)))))
    (is (notany (lambda (s) (search "AMOUNT" (symbol-name s))) slots)
        "no amount slot on a subscription; got ~S" slots)))

(test a-member-left-on-a-retired-price-keeps-the-tier
  ;; Retiring one price of a tier must disturb neither the tier's other prices nor the
  ;; members still on the retired one -- which follows from resolving on the product.
  (let ((legacy (pay:make-subscription :ref "s" :customer-ref "c" :status :active
                                       :current-period-end 9999
                                       :price-ref "price_retired_2024"
                                       :product-ref "prod_pro")))
    (is (string= "prod_pro" (pay:subscription-product-ref legacy))
        "the product still names the tier after its price is retired")
    (is (pay:subscription-grants-access-p legacy 5000))))

(test no-operation-changes-an-existing-subscribers-price
  ;; A boundary in the SHAPE of the API rather than in each application's judgement.
  ;; Repricing what a tier costs new buyers and changing what existing members are charged
  ;; are different acts: the second needs notice or consent in several jurisdictions, and an
  ;; edit form that quietly does it is a compliance incident rather than a convenience.
  ;;
  ;; Asserted over the exported surface, so adding such an operation has to be a deliberate
  ;; act that edits this test rather than something that slips in as a keyword argument.
  (let ((exported '()))
    (do-external-symbols (sym (find-package '#:hermes/payments))
      (push (symbol-name sym) exported))
    (dolist (forbidden '("CHANGE-PRICE" "MIGRATE" "SWAP-PRICE" "REPRICE"))
      (is (notany (lambda (name) (search forbidden name)) exported)
          "~A must not appear in the payments surface without its own decision" forbidden))))

;;; --- Stripe, the first real backend (pre-publication issue 47) ----------------------------------
;;;
;;; Every one of these runs offline. The backend takes its effect as a parameter -- the same
;;; seam aion/http-client exposes -- so a canned response stands in for the network and no
;;; key, container or account is involved. What is being tested is the TRANSLATION, which is
;;; the only thing this backend contains: the protocol was built before it, so there is no
;;; new concept here to test, only a mapping to check.

(defun %stripe (&key (responses '()) (perform nil))
  "A Stripe backend whose HTTP effect answers from RESPONSES -- an alist of
(url-substring . json-string) -- or from PERFORM directly."
  (pay:make-stripe-payments
   :api-key "sk_test_x" :webhook-secret "whsec_test"
   :perform (or perform
                (lambda (req)
                  (let* ((url (aion/http-client:request-url req))
                         (hit (find-if (lambda (e) (search (car e) url)) responses)))
                    (aion/http-client:make-response
                     :status (if hit 200 404)
                     :body (if hit (cdr hit) "{\"error\":{\"message\":\"no stub\"}}")))))))

(defparameter +stripe-sub-json+
  "{\"id\":\"sub_1\",\"customer\":\"cus_1\",\"status\":\"active\",
    \"current_period_end\":1800000000,\"cancel_at_period_end\":false,\"trial_end\":null,
    \"items\":{\"data\":[{\"price\":{\"id\":\"price_1\",\"product\":\"prod_pro\"}}]}}")

;;; --- the conversion that would silently deny everyone access ---------------

(test unix-timestamps-become-universal-time
  ;; THE most dangerous line in the backend. Stripe speaks Unix epoch; this protocol speaks
  ;; CL universal time, and they differ by about seventy years. Unconverted, every period end
  ;; sits in the past, every subscription reads as expired, and every member is denied --
  ;; with no error, because both are perfectly good integers.
  (is (= 2208988800 pay:+unix-epoch+))
  (is (= (+ 1800000000 2208988800) (pay:unix->universal 1800000000)))
  (is (null (pay:unix->universal nil)) "absent stays absent")
  (is (null (pay:unix->universal 0)) "0 is Stripe's absent, not 1970"))

(test a-converted-period-end-is-in-the-future-not-seventy-years-past
  ;; The failure stated as the application would experience it.
  (let* ((p (%stripe :responses (list (cons "/v1/subscriptions/sub_1" +stripe-sub-json+))))
         (s (pay:subscription-state p "sub_1")))
    (is (> (pay:subscription-current-period-end s) (get-universal-time))
        "a subscription ending in 2027 must not read as expired")
    (is (pay:subscription-grants-access-p s)
        "AND MUST THEREFORE GRANT ACCESS -- the unconverted version denies everyone")))

;;; --- translation ------------------------------------------------------------

(test a-stripe-subscription-becomes-the-neutral-record
  (let* ((p (%stripe :responses (list (cons "/v1/subscriptions/sub_1" +stripe-sub-json+))))
         (s (pay:subscription-state p "sub_1")))
    (is (string= "sub_1" (pay:subscription-ref s)))
    (is (string= "cus_1" (pay:subscription-customer-ref s)))
    (is (eq :active (pay:subscription-status s)))
    (is (string= "price_1" (pay:subscription-price-ref s)) "what they pay")
    (is (string= "prod_pro" (pay:subscription-product-ref s)) "AND the tier")))

(test stripe-incomplete-states-map-to-unpaid-rather-than-new-variants
  ;; Both mean the first payment never succeeded; neither grants access. Inventing variants
  ;; would widen a closed vocabulary for a distinction no application can act on.
  (dolist (raw '("incomplete" "incomplete_expired"))
    (let* ((json (format nil "{\"id\":\"s\",\"customer\":\"c\",\"status\":\"~A\",\"items\":{\"data\":[]}}" raw))
           (p (%stripe :responses (list (cons "/v1/subscriptions/s" json))))
           (s (pay:subscription-state p "s")))
      (is (eq :unpaid (pay:subscription-status s)) "~A must not grant access" raw)
      (is (not (pay:subscription-grants-access-p s))))))

(test subscriptions-for-returns-every-subscription-as-a-list
  (let* ((json (format nil "{\"data\":[~A,~A]}" +stripe-sub-json+
                       (substitute #\2 #\1 "{\"id\":\"sub_1\",\"customer\":\"cus_1\",\"status\":\"active\",\"items\":{\"data\":[]}}")))
         (p (%stripe :responses (list (cons "/v1/subscriptions?" json)))))
    (is (= 2 (length (pay:subscriptions-for p "cus_1"))))))

;;; --- gone versus unknown, on the real backend ------------------------------

(test a-404-means-gone-and-anything-else-means-unknown
  ;; The contract that stops an outage becoming a mass revocation. NIL only on positively
  ;; reported absence; a signal for everything else, so reconciliation leaves the record be.
  (let ((absent (%stripe :responses '()))                       ; stub answers 404
        (broken (%stripe :perform (lambda (req) (declare (ignore req))
                                    (aion/http-client:make-response
                                     :status 500 :body "{\"error\":\"upstream\"}")))))
    (is (null (pay:subscription-state absent "sub_missing"))
        "404 is the provider saying it is gone")
    (signals pay:payment-error (pay:subscription-state broken "sub_1")))
  (let ((down (%stripe :perform (lambda (req) (declare (ignore req))
                                  (error 'aion/http-client:http-error
                                         :detail "transport error: connection refused")))))
    (signals pay:payment-error (pay:subscription-state down "sub_1")
      "our outage must NOT read as their cancellation")))

;;; --- webhook signatures ----------------------------------------------------

(defun %stripe-sig (payload secret &key (at (- (get-universal-time) pay:+unix-epoch+)))
  (let ((mac (ironclad:make-mac :hmac (sb-ext:string-to-octets secret :external-format :utf-8)
                                :sha256)))
    (ironclad:update-mac mac (sb-ext:string-to-octets (format nil "~D.~A" at payload)
                                                      :external-format :utf-8))
    (format nil "t=~D,v1=~A" at
            (ironclad:byte-array-to-hex-string (ironclad:produce-mac mac)))))

(defparameter +stripe-event-json+
  "{\"id\":\"evt_1\",\"type\":\"customer.subscription.updated\",\"created\":1800000000,
    \"data\":{\"object\":{\"id\":\"sub_1\",\"customer\":\"cus_1\",\"status\":\"active\",
    \"current_period_end\":1800000000,\"items\":{\"data\":[{\"price\":{\"id\":\"price_1\",\"product\":\"prod_pro\"}}]}}}}")

(test a-correctly-signed-stripe-webhook-verifies
  (let* ((p (%stripe))
         (ev (pay:verify-webhook p +stripe-event-json+
                                 (%stripe-sig +stripe-event-json+ "whsec_test"))))
    (is (string= "subscription-changed" (pay:event-kind-name ev)))
    (is (string= "evt_1" (pay:event-id ev)))
    (is (string= "prod_pro" (pay:subscription-product-ref (pay:event-subscription ev))))))

(test a-tampered-stripe-payload-does-not-verify
  (let* ((p (%stripe))
         (sig (%stripe-sig +stripe-event-json+ "whsec_test"))
         (forged (substitute #\9 #\1 +stripe-event-json+)))
    (signals pay:webhook-signature-invalid (pay:verify-webhook p forged sig))))

(test a-signature-from-the-wrong-secret-does-not-verify
  (let ((p (%stripe)))
    (signals pay:webhook-signature-invalid
      (pay:verify-webhook p +stripe-event-json+
                          (%stripe-sig +stripe-event-json+ "whsec_someone_else")))))

(test a-stale-timestamp-is-refused-and-so-is-a-future-one
  ;; Too old is a replay. Too far ahead is a clock that cannot bound the first -- accepting
  ;; it would let a forged future timestamp buy an arbitrarily long replay window.
  (let ((p (%stripe))
        (now (- (get-universal-time) pay:+unix-epoch+)))
    (signals pay:webhook-signature-invalid
      (pay:verify-webhook p +stripe-event-json+
                          (%stripe-sig +stripe-event-json+ "whsec_test" :at (- now 4000))))
    (signals pay:webhook-signature-invalid
      (pay:verify-webhook p +stripe-event-json+
                          (%stripe-sig +stripe-event-json+ "whsec_test" :at (+ now 4000))))))

(test any-of-several-v1-signatures-may-match-because-that-is-how-rotation-works
  ;; During a secret roll Stripe signs with both. Accepting only the first would make every
  ;; rotation an outage.
  (let* ((p (%stripe))
         (good (%stripe-sig +stripe-event-json+ "whsec_test"))
         (ts (subseq good 0 (position #\, good)))
         (good-v1 (subseq good (1+ (position #\, good))))
         (rolled (format nil "~A,v1=deadbeef,~A" ts good-v1)))
    (finishes (pay:verify-webhook p +stripe-event-json+ rolled))))

(test a-stripe-event-outside-the-vocabulary-is-reported-not-invented
  (let* ((p (%stripe))
         (json "{\"id\":\"evt_x\",\"type\":\"invoice.upcoming\",\"created\":1800000000,\"data\":{\"object\":{}}}"))
    (signals pay:unmapped-event
      (pay:verify-webhook p json (%stripe-sig json "whsec_test")))))

(test the-event-timestamp-is-converted-so-ordering-works
  ;; This is the key that stops a late `updated` overwriting a newer `canceled`. A wrong
  ;; time base here silently restores access to people who left.
  (let* ((p (%stripe))
         (ev (pay:verify-webhook p +stripe-event-json+
                                 (%stripe-sig +stripe-event-json+ "whsec_test"))))
    (is (= (+ 1800000000 pay:+unix-epoch+) (pay:event-occurred-at ev)))))

;;; --- construction -----------------------------------------------------------

(test a-missing-credential-is-refused-at-construction-not-at-the-till
  (signals pay:configuration-error
    (pay:make-stripe-payments :api-key "" :webhook-secret "whsec"))
  (signals pay:configuration-error
    (pay:make-stripe-payments :api-key "sk" :webhook-secret "")))

(test discount-codes-are-unreachable-unless-checkout-allows-them
  ;; A silent, expensive failure reported from production conditions: the codes exist, the
  ;; provider accepts them, the dashboard lists them, and no buyer can ever enter one.
  ;; Nothing errors. Defaulting to NIL matches the provider and avoids surprising a checkout
  ;; page with an extra field -- so the protocol's job is to make the trap VISIBLE.
  (let (captured)
    (let ((p (%stripe :perform (lambda (req)
                                 (setf captured (aion/http-client:request-content req))
                                 (aion/http-client:make-response
                                  :status 200 :body "{\"url\":\"https://x.invalid/c\"}")))))
      (pay:create-checkout p :customer-ref "cus_1" :mode :subscription
                             :success-url "https://a" :cancel-url "https://b")
      (is (null (assoc "allow_promotion_codes" captured :test #'string=))
          "absent by default, as the provider defaults")
      (pay:create-checkout p :customer-ref "cus_1" :mode :subscription
                             :success-url "https://a" :cancel-url "https://b"
                             :allow-promotion-codes t)
      (is (equal "true" (cdr (assoc "allow_promotion_codes" captured :test #'string=)))
          "and sent when asked for -- without it every coupon is unreachable"))))

;;; --- pre-publication issue 209: a provider config must not print its credentials -----------------

(test payments-config-printing-does-not-disclose-its-credentials
  ;; Same defect shape as the DB password that reached a deploy log: a Coalton
  ;; DEFINE-TYPE prints field by field, so a String credential is rendered by anything
  ;; that prints the config -- a backtrace through a failed charge, most plausibly.
  (let* ((key "sk_live_do-not-log-me")
         (whsec "whsec_do-not-log-me")
         (printed (format nil "~S" (money:make-config key whsec "https://api.example"))))
    (is (null (search key printed))
        "a payments Config disclosed its API key: ~S" printed)
    (is (null (search whsec printed))
        "a payments Config disclosed its webhook secret: ~S" printed)
    ;; The API base is NOT a credential and must still print -- a redacted config that
    ;; hides which endpoint was being called is not worth having in the backtrace.
    (is (search "https://api.example" printed))))

(test payments-config-credentials-are-still-there-to-have-been-leaked
  ;; The control. CONFIG-COMPLETE? distinguishes present from blank, so it is the
  ;; assertion that fails if MAKE-CONFIG were dropping what it was given.
  (is (money:config-complete? (money:make-config "sk_live" "whsec" "https://api.example")))
  (is (string= "sk_live" (aion/secret:reveal
                          (money:config-api-key
                           (money:make-config "sk_live" "whsec" "https://api.example")))))
  (is (string= "whsec" (aion/secret:reveal
                        (money:config-webhook-secret
                         (money:make-config "sk_live" "whsec" "https://api.example"))))))
