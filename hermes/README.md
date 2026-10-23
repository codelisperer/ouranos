# hermes

The codelisperer **external-integrations** framework — third-party services behind thin
**neutral protocols** (the ecosystem doctrine). A **satellite leaf library**: it depends only
leftward + external (dexador/jzon/base64/ironclad, `aion/log`), never on
hyperion/mnemosyne/praxeon, so apps consume it and nothing core depends on it.

**The vision: hermes handles all the messaging an app needs.** Named for the messenger — one
neutral protocol for every channel an app uses to reach a person, so an app writes `send`
once and the channel/vendor is a configuration detail. **Email + SMS ship today** (send *and*
receive), and **Telegram** groups and channels (send, edit, delete); push notifications, in-app/web push, and richer channels (voice, chat) join the
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

Returns a `delivery-result` (`provider`, `id`, `status`, `raw`, and `destination`, which only
the Telegram backend fills); signals `delivery-failure`
(carries the provider's HTTP status + body), `unsupported-message`, or `configuration-error`.
For an explicit provider, `(hermes:deliver (hermes:make-sendgrid) email)`.

**Transport selection (env):**
- `HERMES_TRANSPORT=dev` → the **dev transport** for every channel: *renders* the message
  (recipient/subject/body — so links are visible) instead of sending. The local-dev default.
- else `HERMES_EMAIL_IMPL` (default `sendgrid`) / `HERMES_SMS_IMPL` (default `twilio`).
- Backends read their own creds: `SENDGRID_API_KEY`, `TWILIO_ACCOUNT_SID` / `TWILIO_AUTH_TOKEN`
  / `TWILIO_FROM`. See [`.env.example`](.env.example).

## Send to Telegram groups and channels

A `telegram-message` goes to a chat through the Telegram Bot API (#778). The chat is an
integer chat id or a public `@username`; the bot has to be a member of a group, or an
administrator allowed to post in a channel.

```lisp
(hermes:send (hermes:make-telegram-message
              :chat "@example_news"
              :text (format nil "*New post:* ~A" (hermes:escape-markdown-v2 title))
              :parse-mode :markdown-v2      ; or :html with hermes:escape-telegram-html, or NIL
              :link-preview :hide))          ; :show is the default
(hermes:send (hermes:make-telegram-message :chat -1001234567890 :text "Caption"
                                           :photo "https://example.com/cover.jpg"))
```

- **The token** is `TELEGRAM_BOT_TOKEN`, or `:token` to `make-telegram` (a string or an
  `aion/secret` secret). It is held as a secret, and because Telegram puts it in the URL path,
  it is replaced by `<redacted>` in the text of every failure the backend signals.
- **The result** is a `delivery-result` whose `id` is Telegram's message id and whose
  `destination` is the chat id Telegram answered with. `edit-sent-message` and
  `delete-sent-message` take that result, for example
  `(hermes:edit-sent-message provider result "new text")`, with `:part :caption` for a
  photo's caption.
- **Failures** are `delivery-failure`s, with four subtypes: `telegram-chat-unreachable` (the
  chat does not exist, or the bot is not in it or was removed), `telegram-not-permitted` (the
  bot may not post there), `telegram-chat-migrated` (the group became a supergroup;
  `telegram-chat-migrated-migrate-to-chat-id` is its new id), and `delivery-rate-limited`, for
  Telegram's flood limit.
- **Length is not checked.** Telegram allows 4096 characters of text and 1024 of caption,
  counted after it has parsed the markup out, so it refuses a longer message with a
  `delivery-failure`.
- **`(hermes:telegram-can-post provider chat)`** answers `:yes`, `:not-member` or
  `:not-permitted`, for a settings screen. For a group that became a supergroup it signals
  `telegram-chat-migrated` instead of answering, so the app can store the new chat id.
- `HERMES_TELEGRAM_IMPL` picks the backend (default `telegram`); `HERMES_TRANSPORT=dev` renders
  Telegram messages instead of sending them, like email and SMS.

**A flood limit is retried by the app, later, not by hermes.** `delivery-rate-limited` carries
`delivery-rate-limited-retry-after`, the number of seconds Telegram asked for, or NIL. hermes
does not wait or retry. An app that runs `aion/schedule` can store the retry as a one-off job;
the job's arguments are stored, so they are the message's fields rather than the message:

```lisp
(aion/schedule:define-job scheduler "announce"
  (lambda (context chat text)
    (declare (ignore context))
    (handler-case (hermes:send (hermes:make-telegram-message :chat chat :text text))
      (hermes:delivery-rate-limited (c)
        (aion/schedule:schedule-once
         scheduler "announce"
         :at (+ (aion/schedule:scheduler-clock-now scheduler)
                (or (hermes:delivery-rate-limited-retry-after c) 60))
         :args (list chat text))))))
```

**A chat shared as a `t.me/+` invite link has no id the app can look up.** No Bot API method
takes an invite link, so the chat id comes from the bot's own updates (#794):

1. An operator adds the bot to the group or channel through the link (in a channel, as an
   administrator who may post).
2. The app calls `(hermes:telegram-added-chats provider)`. It returns one `telegram-added-chat`
   per chat the bot was recently added to or removed from, with `telegram-added-chat-id`,
   `-type` (`:group`, `:supergroup`, `:channel`), `-title`, `-status` (the bot's membership, for
   example `:administrator` or `:left`) and `-date`.
3. The operator picks the chat by its title, and the app stores its id.

- Telegram keeps an update for 24 hours, so the bot has to have been added within that time.
- By default the updates are read and left pending, so another program reading the same bot's
  updates still gets them; only the first 100 pending updates are read. `:confirm t` reads all of
  them and confirms them, and Telegram then drops them for every reader. If a page arrives whose
  updates carry no `update_id`, or none newer than the ones already confirmed, the read stops
  there: the chats read so far are returned, and the updates on that page stay pending.
- If the app's own long poll on `getUpdates` is running at the same moment, Telegram ends one of
  the two requests with 409 "Conflict: terminated by other getUpdates request". Here that is a
  plain `delivery-failure`; call again once the app's poll has returned.
- Telegram stores the `allowed_updates` list the app last passed to `getUpdates` or `setWebhook`
  and applies it to every reader. If that list leaves out `my_chat_member`, these updates are
  never delivered, and `telegram-added-chats` returns an empty list with no error. hermes does
  not send `allowed_updates`, so it does not change that list.
- A bot with a webhook set cannot read its updates this way: Telegram refuses, and hermes signals
  `telegram-webhook-active`. The `my_chat_member` update is then delivered to the webhook, and
  its `chat.id` is the id. hermes does not delete the webhook.

## Post to a Facebook Page

A `facebook-post` goes to a Facebook Page the app's admins manage, through the Graph API, and
appears as the Page (#822). It is a `link` with an optional `message`, or a `message` alone, or a
photo with a caption.

```lisp
(hermes:post-to-page "1234567890" "https://example.com/posts/42"
                     :message "New post: the spring schedule")      ; returns the post id
(hermes:send (hermes:make-facebook-post :page "1234567890" :message "Look"
                                        :image-url "https://example.com/cover.jpg"
                                        :link "https://example.com/posts/42"))
```

- **The link card** comes from the target page's Open Graph tags (`og:title`, `og:image`, ...).
  Facebook fetches the link when the post is made, and "if the viewer or app cannot see the url
  of link, the post will fail" (Meta's Page Feed reference): a page behind a sign-in, or not yet
  public, is refused, and hermes signals `facebook-link-not-public`, which the app can explain as
  "this post isn't public yet".
- **Page tokens are looked up per Page.** `make-facebook` takes `:page-tokens`, a function of a
  Page id returning its token (a string or an `aion/secret` secret) or NIL, or an alist of
  `(page-id . token)`. The default reads `FACEBOOK_PAGE_TOKEN_<page-id>`, then
  `FACEBOOK_PAGE_TOKEN`. A Page with no token signals `configuration-error` naming it, and
  anything that is not a Page id signals `invalid-message`. A post sends the token in its POST
  body; a read sends it in an `Authorization: OAuth` header. Only two calls put a secret in a
  URL, because Meta documents them as query parameters: the connect flow's code exchanges
  (`client_secret`, `code`, `fb_exchange_token`) and the health check's `debug_token`
  (`input_token`). With `FACEBOOK_APP_SECRET` set, every call carries Meta's `appsecret_proof`.
  Tokens and the app secret are replaced by `<redacted>` in every failure's text, and reach the
  code that signals a failure only as `aion/secret` secrets, so a logged backtrace does not show
  them.
- **Timeouts.** A call waits 10 seconds to connect and 30 for the answer. A post whose answer
  timed out may still have been made: check the Page before posting it again.
- **Failures** are `delivery-failure` subclasses, chosen by the Graph error code:
  `facebook-reconnect-required` (190, 102, or a login subcode such as 492: send an admin through
  the connect flow again), `facebook-not-permitted` (10, 200 to 299), `facebook-page-not-found`
  (100 with subcode 33, 803), `facebook-link-not-public` (a code 100 whose message mentions the
  link, on a post that has one: Meta documents no code or subcode for this, so the message is
  the only signal), and `delivery-rate-limited` (4, 17, 32,
  613 and 80001, the code a Page token's limit uses). The wait is the
  `estimated_time_to_regain_access` in the `X-Business-Use-Case-Usage` header, in seconds, or NIL;
  as for Telegram, hermes does not wait or retry.
- **Groups are refused.** Meta removed the Groups API for every app on 2024-04-22, so a target
  that names a Group (a `/groups/` URL, or `"group:..."`) signals `facebook-groups-unsupported`
  when the post is made. A numeric Group id cannot be told from a Page id; Facebook refuses a post
  to one, which arrives as `facebook-not-permitted`.
- **`facebook-page-health`** answers for an admin screen: `:connected` (and the Page's name),
  `:reconnect`, `:not-permitted`, `:wrong-page` (the token stored for this Page belongs to
  another Page), `:not-found`, or `:not-connected` when no token is stored. It reads the token's
  own Page (`/me`) and compares it with the Page asked about. With the app's id and secret it
  also asks Facebook's `debug_token` whether the token is valid, belongs to this Page
  (`profile_id`), and still carries `pages_manage_posts`.
- `HERMES_FACEBOOK_IMPL` picks the backend (default `facebook`); `HERMES_TRANSPORT=dev` renders
  posts instead of making them, and `dev-last-facebook` reads the last one.

**Connecting a Page, once.** An admin signs in with Facebook and picks a Page; the app keeps that
Page's token. hermes does the Facebook side; the app's routes and session do the rest:

```lisp
;; GET /admin/facebook/connect
(let ((state (hermes:facebook-connect-state)))       ; 256 random bits
  (setf (session-value :facebook-state) state)        ; bound to this admin's session
  (redirect (hermes:facebook-connect-url provider :state state
              :redirect-uri "https://app.example.com/admin/facebook/callback")))

;; GET /admin/facebook/callback?code=...&state=...  (or ?error=...)
(let ((expected (session-value :facebook-state)))
  (setf (session-value :facebook-state) nil)          ; single use: delete before checking
  (dolist (page (hermes:facebook-connect-pages provider
                  :code code :state state :error error :expected-state expected
                  :redirect-uri "https://app.example.com/admin/facebook/callback"))
    ;; show (facebook-page-name page) and let the admin choose; store the chosen one's
    ;; (facebook-page-token page), an aion/secret secret, keyed by (facebook-page-id page)
    ...))
```

- `facebook-connect-pages` checks the returned state against the session's, in constant time,
  before anything is sent; a mismatch is `facebook-connect-refused` with reason
  `:state-mismatch`. An `error` from Facebook is `:denied`, and a code Facebook will not exchange
  (used already, expired, or a different `redirect_uri`) is `:code-rejected`.
- The code is exchanged for a user token, and that for a long-lived one, on the server with the
  app secret, as Meta requires ("Make this call from your server, not a client"). The URL the
  browser sees carries the app id and the state, never the secret.
- It returns the Pages the admin manages as `facebook-page` values, each with its Page token
  (an `aion/secret` secret) and the admin's tasks; `facebook-page-can-post-p` is true when they
  include `CREATE_CONTENT`. The user tokens are never returned or kept.
- Store the chosen token in the app's secret store, keyed by the Page id: an environment
  variable `FACEBOOK_PAGE_TOKEN_<page-id>` on a server, or `hades/credentials:store-credential`
  on a desktop, read back through `:page-tokens`.
- The `redirect_uri` must match one of the Meta app's Valid OAuth Redirect URIs exactly.

**Meta's rules, checked against developers.facebook.com on 2026-10-23.** Dates here and in the
code are UTC, written YYYY-MM-DD.

- *Who can connect without App Review.* Graph API "Access Levels": "Permissions with Standard
  Access can only be requested from app users who have a role on the requesting app", and "All
  Business, Consumer, and Gaming apps are automatically approved for Standard Access for all
  permissions and features." So an admin who has a role on the Meta app (administrator,
  developer or tester) can connect their own Page with no App Review. Connecting the Pages of
  people without a role needs Advanced Access: "Business Verification is required to get Advanced
  Access", and it "must be approved on an individual permission and feature basis through the App
  Review process." This transport is built for the first case; nothing in it is tied to one Page.
- *The one-time Meta app setup:* create a Business app; add Facebook Login with the callback in
  Valid OAuth Redirect URIs; give each admin who will connect a Page a role on the app; keep the
  app in Development mode unless people without a role must use it. Set `FACEBOOK_APP_ID` and
  `FACEBOOK_APP_SECRET` on the server.
- *Publishing* (Page Feed reference, v26.0): `POST /{page-id}/feed` with `message` and/or `link`,
  a Page token with `pages_manage_posts`, `pages_read_engagement` and `pages_show_list`, from
  someone who can perform the `CREATE_CONTENT` task on the Page; "The response will be the
  post_id."
- *Token lifetimes* ("Get Long-Lived Tokens"): a long-lived user token "generally lasts about 60
  days"; a Page token taken with it "do[es] not have an expiration date", but stops working when,
  for example, the admin changes their password, loses their role on the Page, or removes the
  app. `facebook-page-health` then answers `:reconnect`.
- *Groups* (Graph API v19.0 changelog): `publish_to_groups`, `groups_access_member_info` and the
  Groups API were deprecated, and "removed April 22, 2024" for every version.
- *Rate limits* ("Rate Limiting"): 4 is the app's limit, 17 the user's, 32 a Pages call made with
  a User token, 613 a custom limit, and 80001 a call made with a Page token. No error body carries
  a wait; the `X-Business-Use-Case-Usage` header's `estimated_time_to_regain_access` does, in
  minutes.

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
[#58](https://github.com/codelisperer/ouranos/issues/58) exists to prevent.

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
