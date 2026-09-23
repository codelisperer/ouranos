# hermes

The codelisperer **external-integrations** framework — third-party services behind thin
**neutral protocols** (the ecosystem doctrine). A **satellite leaf library**: it depends only
leftward + external (dexador/jzon/base64/ironclad, `aion/log`), never on
hyperion/mnemosyne/praxeon, so apps consume it and nothing core depends on it.

**The vision: hermes handles all the messaging an app needs.** Named for the messenger — one
neutral protocol for every channel an app uses to reach a person, so an app writes `send`
once and the channel/vendor is a configuration detail. **Email + SMS ship today** (send *and*
receive); push notifications, in-app/web push, and richer channels (voice, chat) join the
same `deliver` protocol as they land — each a backend, never a new API for the app to learn.
Payments (Stripe) is a **separate module** under the same "third-party services behind thin
neutral protocols" doctrine — see the roadmap issues (`pkg:hermes`).

## Send (email + SMS)

A message is a plain value; a **provider** delivers it; `deliver` dispatches on both (CLOS
multiple dispatch), so the vendor wire format is confined to each backend. `send` picks the
env-configured provider for the channel:

```lisp
(hermes:send (hermes:make-email :to "a@x.io" :from "no-reply@app.io"
                                :subject "Welcome" :text "Verify: https://app/v/abc"
                                :html "<p>Verify …</p>"))     ; SendGrid (or dev)
(hermes:send (hermes:make-sms :to "+15551234567" :text "Your code is 123456"))  ; Twilio (or dev)
```

Returns a `delivery-result` (`provider`, `id`, `status`, `raw`); signals `delivery-failure`
(carries the provider's HTTP status + body), `unsupported-message`, or `configuration-error`.
For an explicit provider, `(hermes:deliver (hermes:make-sendgrid) email)`.

**Transport selection (env):**
- `HERMES_TRANSPORT=dev` → the **dev transport** for both channels: *renders* the message
  (recipient/subject/body — so links are visible) instead of sending. The local-dev default.
- else `HERMES_EMAIL_IMPL` (default `sendgrid`) / `HERMES_SMS_IMPL` (default `twilio`).
- Backends read their own creds: `SENDGRID_API_KEY`, `TWILIO_ACCOUNT_SID` / `TWILIO_AUTH_TOKEN`
  / `TWILIO_FROM`. See [`.env.example`](.env.example).

## Receive (inbound SMS) — `hermes/inbound`

Two-way SMS: an app **subscribes** to a neutral inbound event, and mounts the **Twilio
webhook** on its own web route (hyperion or otherwise — hermes has no web dep). The webhook
**verifies `X-Twilio-Signature`** (HMAC-SHA1; forged/unsigned posts are rejected):

```lisp
(hermes/inbound:subscribe
  (lambda (m) (format t "~A: ~A~%" (hermes/inbound:inbound-message-from m)
                      (hermes/inbound:inbound-message-body m))))

;; in your route handler, from the Clack env: the exact public URL, the POST params
;; (alist), and the X-Twilio-Signature header:
(hermes/inbound:twilio-webhook url params signature)   ; verifies → parses → emits; else SIGNATURE-REQUIRED
;; optional inline reply body (Content-Type application/xml):
(hermes/inbound:twiml-message "Got it, thanks!")
```

The app owns the conversation model + UI; hermes owns the transport both ways. **Ops:** a
provisioned Twilio number pointed at your webhook URL, and — for real US traffic — A2P 10DLC
brand/campaign registration.

## Take payments — `hermes/payments`

A neutral protocol for hosted checkout, subscriptions and normalized webhooks. **Stripe is
one implementation of it and never the protocol itself.** Its own system, so an app that
wants email does not compile a payments protocol it never calls:

```lisp
(ql:quickload :hermes/payments)
```

```lisp
(let ((p (pay:payments)))                                   ; env-selected backend
  (pay:create-checkout p :customer-ref cus :mode :subscription
                         :success-url "https://app.example/thanks"
                         :cancel-url  "https://app.example/pricing"))
```

### Three things to know before you use it

**Webhooks are authoritative. Redirects are advisory.** The success URL is a browser being
told what to display — it can be forged, replayed, or never visited. **Do not grant
entitlement there.** Grant it when the webhook arrives.

**Subscriptions are plural.** Nothing here returns *the* subscription; `subscriptions-for`
returns a list, including when it is empty and including when it is one. A customer may hold
several concurrently — a per-group tier is the obvious case — and a shape that varies with
the count grows a special case that becomes the assumption again.

**No operation accepts a card number**, by shape rather than by policy. Checkout is hosted,
so card data never reaches your servers, and there is deliberately no form in which it could
be passed. **That is what keeps PCI scope at SAQ-A** — so do not add a "convenience" that
widens it.

### Normalized events

Seven, and the vocabulary is closed — a provider event outside it is reported as
`unmapped-event` rather than quietly widening the neutral core:

| kind | what it means |
|---|---|
| `subscription-changed` | granted or changed entitlement |
| `subscription-canceled` | ended — the **state** says whether now or at period end |
| `trial-will-end` | convert deliberately; silent conversion earns chargebacks |
| `payment-succeeded` | period extended; the reconciliation anchor |
| `payment-failed` | **dunning, not revocation** — a failed card is usually a card |
| `dispute-opened` | money being clawed back; **you** decide about access |
| `refunded` | **not** a cancellation, and may be partial |

Amounts are a single **`Money`** — minor units plus their currency, never a loose
amount-and-currency pair. Arithmetic across currencies returns *nothing* rather than a
plausible wrong number:

```lisp
(money:money+ (money:make-money 100 "usd") (money:make-money 100 "eur"))
;; => None.  There is no sane default; the only honest conversion needs a rate we do not have.
(money:money-ok? sum)              ; did the currencies agree?
(money:money-or sum fallback)      ; the value, with a fallback you must name
```

Every event carries **state, not deltas** ("active until T", never "extend by a month"), a
stable `event-id`, and the provider's own `occurred-at`.

**That timestamp is load-bearing.** Webhooks arrive at-least-once *and out of order*.
Without it, a retried `changed` overwrites a later `canceled` and **silently restores access
to somebody who left**. Compare `occurred-at` against what you have already applied; never
infer order from arrival time.

**Deduplication is yours.** We expose a stable id; you keep the processed-events table.
hermes is a satellite with no database and none permitted, so the alternative is not a
better library, it is a library that cannot be a satellite.

### Reconciliation

Local state *will* drift — a missed delivery, an outage, a bug. `subscriptions-for` is the
authoritative read, meant to be run periodically to repair it. Without one, the only
recovery from a missed webhook is a human noticing.

### Can it take payment on behalf of someone else?

Asked because a second consuming app has a marketplace in view, and discovering the answer
after v1 ships is the retrofit this protocol was specified early to avoid.

**A payee that is not the operator fits additively; a payouts business does not.**

*Destination charges* — the buyer pays, and the money settles to a third party's account
minus a fee — are an attribute of a charge. A `destination` on checkout and a payee on the
payment record would extend the existing operations without reshaping them, and the neutral
core (**checkout + webhook + status**) is unchanged.

*Payouts and connected-account onboarding* are **not** that. Money moving outward to a third
party, on its own schedule, with its own identity verification and its own compliance
obligations, is a different operation family — not checkout with a different recipient. Adding
it here would widen a "neutral" core into a union of vendors, which is the thing
[#51](https://github.com/codelisperer/ouranos/issues/51) exists to prevent.

So the honest answer is: **the protocol can grow a payee; it should not grow a marketplace.**
If marketplace payouts become real, they want their own protocol beside this one — sharing
the provider and the HTTP client, not the vocabulary.

### The neutrality limit, stated honestly

Hosted checkout plus subscriptions maps cleanly onto Stripe. **It does not map cleanly onto
crypto vendors**, which are invoice- and one-time-shaped. So the neutral core is
**checkout + webhook + status**, and anything past that rides on `provider-call` — the
extension hatch, which is deliberately awkward and explicitly outside the compatibility
promise. An application that reaches for it is coupled to that provider and should know so
at the call site rather than when a second provider arrives.

### PCI scope, in one paragraph

Card data goes **browser → Stripe**, never through your servers: checkout is hosted, and no
operation in this protocol accepts a card number. You hold references (`cus_…`, `sub_…`) and,
if you want them, brand/last4/expiry — which Stripe states are **not** subject to PCI
compliance. That keeps you on the simplest attestation Stripe offers.

**It does not remove PCI entirely**: compliance is shared, and a merchant still attests
annually. And two obligations sit outside this library because it cannot discharge them for
you — allowlist Stripe's IP ranges in addition to verifying signatures, and serve payment
pages over TLS 1.2+. See [ADR-0002](docs/adr/0002-stripe-pci-posture.md), which also records
why **Elements is deliberately not implemented** and what adopting it would change.

### Local development

`HERMES_TRANSPORT=dev` selects the in-memory provider for payments exactly as it does for
email and SMS. **This is not a convenience.** A module whose local-dev path reaches a real
vendor is one that gets tested against real money.

## Extending

A new vendor is a new provider class + one `register-impl`: `(hermes:register-impl :email
"ses" (lambda () (make-ses)))`, then a `deliver` method. AWS SES/SNS are the planned siblings.

## Develop

    cons build · cons test · cons repl        # (bare `cons` lists targets)

`(ql:quickload :hermes)` resolves from the Ouranos tree (source-registry drop-in). Config/env
via `.env` → `cons/env:load-dotenv`.
