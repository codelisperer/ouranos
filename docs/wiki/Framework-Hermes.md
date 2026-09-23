# hermes — external integrations (satellite leaf-lib)

**The vision: hermes handles all the messaging an app needs.**

One neutral `deliver` / `send` protocol across **every channel an app uses to reach a
person** — so an app writes `send` once, and the channel and the vendor stay a
*configuration detail*. Email today, SMS today, push notifications next, in-app and web push
after that, voice and chat later. Each new channel arrives as a **new backend on the same
protocol** — never as a new API the application has to learn.

Named for the messenger of the gods. The name is the specification.

---

## What it is, and why it exists

Applications talk to the outside world constantly, and the outside world is where
abstractions go to die. A signup flow needs a verification email. Two-factor needs an SMS. A
CRM needs to *receive* replies. A mobile shell needs push. Later there is billing. Each of
these arrives with a vendor SDK, a wire format, a webhook signature scheme, and an opinion
about how your code should be organized.

The ecosystem's doctrine is that **only true external services sit behind neutral
protocols** — and when they do, the protocol must be *thin*. hermes is where that doctrine
is applied to third-party services. Its template is Praxeon's provider-neutral LLM layer:
one neutral core, providers as swappable implementations, and vendor specifics confined to
the backend that owns them.

The payoff is stated most sharply for messaging, because messaging is where channel
proliferation hurts most. An app should express *intent* — "tell this person this" — and
never encode *how*. Swapping SendGrid for SES, or adding push alongside SMS, should be a
configuration change and a new backend class, not a refactor of every call site.

### What hermes deliberately does **not** own

Thin means thin. hermes returns values; it does not persist them, and it does not serve
routes.

| Concern | Owner |
|---|---|
| Provider protocol, vendor client, webhook verification/parsing | **hermes** |
| Persistence (message log, customers, subscriptions, processed-event ids) | **the app**, on [Framework Mnemosyne](Framework-Mnemosyne.md) |
| Web endpoints (webhook receiver route, redirects) | **the app**, or [Framework Hyperion](Framework-Hyperion.md) helpers |
| The conversation model and UI | **the app** |

hermes owns the transport in both directions. Everything above the transport is somebody
else's job — and keeping it that way is what lets hermes stay a leaf.

---

## Where it sits in the DAG

hermes is a **satellite leaf library**, not one of the six core frameworks. It sits **off**
the line:

```
aion → cons → mnemosyne → elenchon → hyperion → praxeon        (the core DAG)

hermes  ──depends only on──▶  aion  +  external libs
```

Two properties, both intentional:

- **It depends only leftward and externally** — `dexador` (HTTP), `com.inuoe.jzon` (JSON),
  `cl-base64`, `ironclad` (HMAC), and `aion/log`. **Never** on mnemosyne, hyperion, or
  praxeon.
- **Nothing in the core DAG depends on hermes.** It is a genuine leaf.

That second property is the important one. It means a third-party service concern can never
propagate inward: no core framework acquires an opinion about SendGrid because hermes exists.
Apps consume hermes directly, which is exactly what lets it talk to the outside world
without dragging vendor semantics into the core. It is a sibling in kind to the Fates
family of leaf libraries — orthogonal to the web/data/agentic stack rather than a rung on it.

---

## Status

| Module | State |
|---|---|
| **Delivery — email** (SendGrid backend) | **Shipped** |
| **Delivery — SMS** (Twilio backend) | **Shipped** |
| **Dev transport** (renders instead of sending, both channels) | **Shipped** |
| **Inbound SMS** (signature-verified Twilio webhook → neutral event) | **Shipped** |
| Provider registry + env-based selection | **Shipped** |
| **Push notifications** (native), in-app / web push | **Planned** — new backends, same protocol |
| Voice, chat | **Planned** — later channels, same protocol |
| Additional email/SMS vendors (SES, SNS, Postmark) | **Planned** — a class + one `register-impl` |
| **Payments** (Stripe first) | **Shipped** (#47) — a separate module, same doctrine: hosted Checkout only, per ADR-0002 |

`(ql:quickload :hermes)` loads clean; the suites are green (35 delivery + 123 payments +
276 blob = 434 checks); and the leaf-lib constraint holds — no dependency on hyperion, mnemosyne, or
praxeon.

### Why delivery shipped before payments

The original plan was **payments first** — Stripe, subscriptions, webhooks. The name hermes
was chosen for the Greek god of **commerce, trade, and messengers**, and payments was
supposed to be the commerce half.

The order changed because a consuming app needed **email and SMS now**: auth emails, SMS
verification codes, and two-way SMS for a CRM workflow. Real demand outranked the plan, so
**delivery landed first** and payments moved behind it. This is worth recording because it
also *clarified* the framework: what began as "the payments library, plus messaging later"
turned out to be a messaging framework with payments as a second module. The vision at the
top of this page is the result of that inversion, not a retrofit.

---

## Design narrative

### The `deliver` protocol — CLOS multiple dispatch as the design

A message is a **plain value**. A **provider** delivers it. `deliver` is a generic function
that dispatches on **both**:

```
(defgeneric deliver (provider message))
```

So the statement *"this provider can send that kind of message"* is expressed directly as
CLOS **multiple dispatch**. `(sendgrid . email)` is a method. `(twilio . sms)` is a method.
Anything else falls through to the default method on `(provider . t)`, which signals
`unsupported-message`.

This is a small design decision with outsized consequences:

- **Capability is checked by the method table, not by conditionals.** There is no
  `(if (supports-p provider :sms) …)` anywhere, and no capability flags to keep in sync.
  The set of methods *is* the capability matrix.
- **Adding a channel does not touch existing code.** A push channel is a new message type
  plus a `(push-provider . push-message)` method. Existing providers keep working and
  correctly refuse the new type by falling to the default.
- **Adding a vendor does not touch the protocol.** A new backend is a provider class, one
  `register-impl`, and a `deliver` method:
  `(hermes:register-impl :email "ses" (lambda () (make-ses)))`.
- **Vendor wire format is confined to its backend.** SendGrid's JSON body and Twilio's
  form-encoded POST never appear above the method that produces them.

`send` sits above `deliver` as the everyday entry point: it picks the **env-configured
provider for the message's channel** and delivers. That is the layer at which "the vendor is
a configuration detail" becomes literally true.

Selection is environment-driven, with a deliberate developer-experience choice at the top:

- `HERMES_TRANSPORT=dev` forces the **dev transport** for *both* channels — it **renders**
  the message (recipient, subject, body) instead of sending it. Rendering rather than
  silently swallowing matters: a verification link is only useful if a developer can see and
  click it. This is the local-dev default.
- Otherwise `HERMES_EMAIL_IMPL` (default `sendgrid`) and `HERMES_SMS_IMPL` (default
  `twilio`) select the backend.
- Each backend reads **its own** credentials (`SENDGRID_API_KEY`, `TWILIO_ACCOUNT_SID` /
  `TWILIO_AUTH_TOKEN` / `TWILIO_FROM`), documented in `.env.example` and loaded via
  `cons/env:load-dotenv`. Secrets stay in a gitignored `.env`; the selection layer stays
  neutral and knows nothing about any vendor's credential shape.

Failure follows house style — **conditions, not return codes**. Success returns a
`delivery-result` (`provider`, `id`, `status`, `raw`, so the vendor's response is available
without being in the protocol); failure signals `delivery-failure` (carrying the provider's
HTTP status and body), `unsupported-message`, or `configuration-error`.

### Receiving is half the job

Sending is only half of "the messenger." A CRM that can text a contact but cannot read the
reply is not integrated with anything. So the receive machinery lives in hermes too, rather
than being reinvented in every app.

The shape is: an app **subscribes** to a neutral `inbound-message` event, and **mounts the
webhook handler on its own route** — hyperion or otherwise, because hermes has no web
dependency at all. The app hands the handler three things from its request: the exact public
URL, the POST parameters as an alist, and the `X-Twilio-Signature` header.

The handler then **verifies the signature before doing anything else**: **HMAC-SHA1 over the
URL plus the sorted parameters** (Twilio's scheme), via `ironclad`. Forged or unsigned posts
are rejected with `signature-required`, and the app responds 403 and drops the request. This
is not optional hardening — a public webhook URL is an open endpoint on the internet, and
signature verification is the only thing standing between it and anyone who can guess the
URL. Verification lives in hermes precisely so that no app has to get it right twice.

What comes out is a **provider-neutral** `inbound-message` — `from`, `to`, `body`,
`provider`, `provider-id`, `timestamp` — so app handlers never see Twilio's parameter names.
An optional `twiml-message` helper produces an inline reply body for the same request when
that is the simplest thing.

The remaining requirements are **operational, not code**: a provisioned number pointed at
the webhook URL, and — for real US traffic — A2P 10DLC brand and campaign registration.
Documenting that in the framework saves the next integrator a surprising week.

### Payments — the next module, same doctrine

Payments is a **separate module**, deliberately not squeezed into the delivery protocol.
Same doctrine, different shape.

What hermes would own, kept thin: the payments **provider protocol**, the **Stripe client**
(HTTP + JSON), and **webhook verification/parsing** into normalized events. Persistence
(customers, subscriptions, payments, processed-event ids) belongs to the app on mnemosyne;
web endpoints (checkout redirect, webhook route, portal redirect) belong to the app or
hyperion. The sketched protocol:

```
create-customer(email, meta)                          → customer-ref
create-checkout(customer, price|items,
                mode {:payment | :subscription},
                success-url, cancel-url)              → checkout-url   ; hosted page
create-portal-session(customer, return-url)           → portal-url     ; self-service
subscription-status(sub-ref)                          → {status, current-period-end}
cancel-subscription(sub-ref) · refund(payment-ref, amt?)
verify-webhook(payload, signature, secret)            → normalized-event
```

with normalized events (`subscription-active`, `subscription-canceled`,
`payment-succeeded`, `payment-failed`) so handlers are provider-agnostic. The rule that
saves the most grief: **webhooks are the source of truth for state — never the redirect.**
A user closing the browser tab must not change what the system believes.

**The honest neutrality limit**, recorded rather than glossed over: hosted checkout and
**subscriptions** map cleanly onto Stripe, but crypto vendors are **invoice / one-time**
shaped — recurring crypto billing is a genuinely different beast. So the neutral core is
only "checkout + webhook + status." Subscriptions are Stripe-strong, crypto is
invoice-strong, and provider specifics ride as extensions. A neutral protocol that pretends
these are the same thing would be a lie with a leaky implementation.

The house-style split applies here as elsewhere: **Coalton** where types earn their keep — a
`Money`/`Currency` type that cannot mix units, the normalized `Webhook-Event` ADT, provider
`Config` — and **CL** for the HTTP calls, JSON, HMAC verification, and the provider generic,
with a `payment-error` condition wrapping the provider's.

Security is non-negotiable and mostly about scope reduction: **hosted Checkout + Elements**
so card data never touches our servers (minimal PCI scope, SAQ-A); **verify webhook HMAC
signatures** (Stripe uses HMAC-SHA256); **dedupe by event id** for idempotency;
**idempotency keys** on create calls; **restricted** API keys from a gitignored `.env`.

The provider order after Stripe reflects the project's ethos as much as market share:

| # | Provider | Kind | Notes |
|---|---|---|---|
| 1 | **Stripe** | cards + subscriptions | First. Hosted Checkout + Customer Portal + webhooks. |
| 2 | **BTCPay Server** | crypto (self-hosted) | Recommended next — open-source, non-custodial, no KYC or fees; fits the anti-SaaS / sovereignty ethos. Invoice-shaped. |
| — | Coinbase Commerce / NOWPayments | crypto (custodial) | Easier, but custodial and they take a cut. |
| 3 | **Paddle** / **Lemon Squeezy** | merchant-of-record | Handle global VAT / sales tax — a real burden for an international app. |
| — | PayPal / Square | cards / wallets | On demand. |

### Provenance

The delivery module was **ported from a consuming app's `courier` prototype** — app-level
email and SMS code that had already been proven in production use. Absorbing it into hermes
behind a neutral protocol is the ecosystem's usual maturation path: build it where it is
needed, extract it once the shape is known, and generalize only what experience justified.

---

## Usage

```lisp
(ql:quickload :hermes)

;; --- send: the channel and vendor are configuration, not code ---------------
(hermes:send (hermes:make-email :to "a@x.io" :from "no-reply@app.io"
                                :subject "Welcome"
                                :text "Verify: https://app/v/abc"
                                :html "<p>Verify …</p>"))          ; SendGrid, or dev
(hermes:send (hermes:make-sms :to "+15551234567"
                              :text "Your code is 123456"))        ; Twilio, or dev

;; explicit provider, when you really mean one:
(hermes:deliver (hermes:make-sendgrid) email)

;; --- receive: subscribe once, mount the verified webhook on your own route --
(hermes/inbound:subscribe
  (lambda (m) (format t "~A: ~A~%"
                      (hermes/inbound:inbound-message-from m)
                      (hermes/inbound:inbound-message-body m))))

;; in the route handler, from the Clack env: exact public URL, POST params
;; (alist), and the X-Twilio-Signature header value
(hermes/inbound:twilio-webhook url params signature)   ; verify → parse → emit
                                                       ; else SIGNATURE-REQUIRED → 403
(hermes/inbound:twiml-message "Got it, thanks!")       ; optional inline reply
```

Adding a vendor:

```lisp
(hermes:register-impl :email "ses" (lambda () (make-ses)))
;; + a (deliver (ses email)) method — and nothing else changes
```

Develop with `cons build` · `cons test` · `cons repl` (bare `cons` lists targets).

---

## Roadmap

The roadmap is **not** duplicated here. Work items live on the board; this page keeps the
reasoning behind them.

- **Board** — https://github.com/orgs/codelisperer/projects/1
- **Open hermes issues** —
  https://github.com/codelisperer/ouranos/issues?q=is%3Aissue+is%3Aopen+label%3A%22pkg%3Ahermes%22

Broadly, what those issues cover: **more channels** (push notifications first, then in-app /
web push, later voice and chat) as backends on the existing `deliver` protocol; **more
vendors** per channel (SES/SNS are the planned siblings); and the **payments module**,
Stripe first, under the same thin-neutral-protocol doctrine. Whatever arrives, the
constraint holds: **adding a channel must not add an API the app has to learn.**

---

## See also

- [Home](Home.md) — the ecosystem overview and the DAG rule
- [Framework Mnemosyne](Framework-Mnemosyne.md) — where an app persists what hermes returns
- [Framework Hyperion](Framework-Hyperion.md) — where an app mounts the webhook route
- [Framework Praxeon](Framework-Praxeon.md) — the provider-neutral LLM layer hermes takes as its template
- In the repository: `hermes/README.md`, `hermes/.env.example`
