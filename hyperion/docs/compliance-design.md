# Compliance by construction — consent & data-protection in Hyperion

Status: **draft / v1 scope shipped** (the `hyperion/consent` module). This doc
states the goal, the principles the framework encodes, what ships now, and the
backlog (much of it landing in `mnemosyne`, the data layer).

> Not legal advice. This describes engineering seams that make lawful behavior
> the path of least resistance. Each app still needs its own legal review.

## Goal

Make **privacy/data-protection compliance a framework capability**, so any app on
Hyperion is compliant-by-default rather than bolting consent and data-subject
rights on per app. Target regimes:

- **GDPR** (EU) and **UK GDPR** — lawful basis, data-subject rights, accountability.
- **ePrivacy / "cookie law"** — prior opt-in for non-essential cookies/tracking.
- **CCPA/CPRA** (California) and the growing set of US state laws — notice,
  opt-out of "sale/share", access & deletion.

The regimes differ (GDPR is opt-in for cookies; CCPA is more opt-out), so the
framework models the **union of duties** and lets an app configure the posture per
market.

## Principles the framework encodes

1. **Necessary vs optional is a hard boundary.** Strictly-necessary processing
   (session, security, locale) needs no consent and can never be "rejected".
   Everything else is optional and **off until affirmative opt-in** — no pre-ticked
   boxes, no opt-out defaults (GDPR/ePrivacy).
2. **Consent is versioned.** A material policy change bumps `*consent-version*`;
   older stored consent becomes "undecided" and the visitor is re-prompted.
3. **Accountability = an audit trail.** "We got consent" must be provable: who,
   what categories, when, which policy version. The cookie backend is the minimum;
   a durable consent **log** is the real requirement (→ mnemosyne).
4. **Neutral protocols, pluggable backends.** Consent storage is a protocol
   (`consent-store`) exactly like i18n's `locale-store` — cookie now, session/DB
   later — so apps upgrade storage without touching call sites.
5. **The app owns copy, routes, look, and posture; the framework owns the
   taxonomy, persistence seam, and wiring.** (Same split as the i18n switcher.)

## What ships now — `hyperion/consent`

- **Taxonomy.** `*consent-categories*` = `(:necessary :preferences :analytics
  :marketing)`; `*necessary-categories*` = `(:necessary)`. `optional-categories`,
  `consent-category-p`.
- **Consent value.** A list of granted category keywords (necessary always
  included); sentinel `:undecided` until an affirmative choice.
  `consent-allows-p`, `normalize-consent`, `*consent-version*`.
- **Store protocol.** `read-consent (store request) → categories | :undecided`,
  `persist-consent (store categories) → response headers`. Cookie backend:
  `cookie-consent-store` / `make-cookie-consent-store` (first-party, `SameSite=Lax`,
  `v<version>:cat,cat` payload, ~6-month lifetime).
- **Request seam.** `consent-decided-p`, `resolve-consent` (necessary-only while
  undecided, so optional tags stay off until opt-in).
- **Banner.** `consent-banner` — HTMX-first, app-supplied copy/URLs, two
  equally-weighted choices (accept optional / necessary-only) + policy link, no
  pre-selected default. Buttons `hx-post` the choice; the app persists and returns
  an empty body to remove it. App styles `.hy-consent-banner*` (markup + wiring
  ship; theme does not).

### App responsibilities (see a consuming app for the reference wiring)

- Provide the localized copy + the cookie-policy route.
- Provide the POST endpoint that maps `consent=all|necessary` → category list,
  calls `persist-consent`, and returns `""`.
- Render the banner only when `(not (consent-decided-p store request))`.
- Gate optional tags/scripts behind `consent-allows-p`.
- Style the banner.

## Backlog

**Consent (hyperion):**
- Per-category "manage preferences" panel (checkboxes) as a progressive step
  beyond accept/necessary-only.
- A default stylesheet/theme option (turnkey), still overridable.
- No-JS degradation (real `<form>` POST fallback for the banner).
- CCPA "Do Not Sell/Share" + Global Privacy Control (`Sec-GPC`) signal handling →
  auto-reject the relevant categories.
- A middleware/interceptor that attaches resolved consent to the request context
  (once `hyperion/interceptor` drives the HTTP path).

**Data-subject rights (mostly mnemosyne, the data layer):**
- **Consent log** — durable, append-only record of each decision (categories,
  timestamp, policy version, locale) for accountability. This is the main reason
  the cookie store is "interim".
- **Right of access / portability** — export a subject's data (machine-readable).
- **Right to erasure** — delete/anonymize on request; tombstones + cascade.
- **Rectification, restriction, objection** — data-layer affordances.
- **Retention** — per-entity retention policies + scheduled expiry.
- **Records of processing (Art. 30)** — a manifest of what's collected, why, lawful
  basis, and retention — ideally generated from schema/metadata, not hand-kept.

**App-facing:**
- Privacy/Terms/Cookie pages are app content (a consuming app ships DRAFT placeholders);
  the framework provides the mechanisms they describe.

## Why this lives in the framework, not the app

Consent wiring, data-export, and erasure are the same shape for every app and easy
to get subtly wrong (opt-out defaults, no audit trail, no re-consent on policy
change). Encoding them once — with the taxonomy and defaults that match the law —
means every codelisperer app inherits a defensible baseline. A consuming app is the
first consumer and drives the API.
