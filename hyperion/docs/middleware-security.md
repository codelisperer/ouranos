# Middleware & security posture (design)

*Design capture — mostly not built. The safe-output posture (Spinneret escaping,
`hyperion/markdown:render`) is already in force. Bundles with the session/auth
subsystem on the roadmap.*

## The question

Prevent XSS + provide basic security middleware. Pedestal (Clojure) models this
with **interceptors**; does Clack already have an opinion?

## Clack already has one: Lack (Ring-style middleware)

Clack is built on **Lack**, a **Ring-style middleware** stack — a middleware is a
function `(lambda (app) (lambda (env) … (funcall app env) …))` composed with
`lack.builder`. Lack ships middleware for **session, static, mount, accesslog,
backtrace** (and **CSRF** via a companion system). So the idiomatic Clack path is
Lack middleware, not a bespoke interceptor engine. *(Confirm exact system names —
e.g. `lack-middleware-csrf` — when we wire it.)*

## Ring/Lack middleware vs Pedestal interceptors

- **Middleware (Ring/Lack):** function composition wrapping request→response.
  Simple, familiar, sufficient for our needs.
- **Interceptors (Pedestal):** a **data-driven queue** of maps with `:enter` /
  `:leave` (+ `:error`) — bidirectional, **reorderable and inspectable as data**,
  can short-circuit or rewrite the queue at runtime. More powerful for complex,
  dynamic pipelines; a heavier concept.
- **Call:** start with **Lack middleware** (idiomatic, enough now). Keep a
  Pedestal-style **interceptor layer as a possible future** if we want
  data-driven/reorderable pipelines — an open architectural question, not now.

## Hyperion's XSS posture — output first

XSS is defended primarily at **output**, with transport headers as defense-in-depth:

- **Escape-by-default output (primary control).** Spinneret auto-escapes text;
  `hyperion/markdown:render` is **safe by default** (escapes raw HTML in the
  source); never `(:raw …)` untrusted content. This is where XSS is actually
  stopped. (ADR-0003/0004 already lean this way.)
- **Security-headers middleware** (to write): `Content-Security-Policy`,
  `X-Content-Type-Options: nosniff`, `X-Frame-Options` / CSP `frame-ancestors`,
  `Referrer-Policy`, and `Strict-Transport-Security` in prod. Defense-in-depth for
  XSS / clickjacking / MIME-sniffing. (We mostly avoid inline JS — Parenscript is
  compiled and served/inlined deliberately — which keeps CSP strict-friendly.)
- **CSRF** for state-changing posts (Lack's CSRF middleware + a `csrf-field`
  Spinneret helper), integrated with the typed-HTMX forms.
- **Session + secure cookies:** Lack's session middleware with signed cookies
  (`Secure`, `HttpOnly`, `SameSite`). Ties into the coming auth / user-preference
  work — the i18n `resolve-locale` seam already reserves `user-pref`.

## Proposed shape

A `hyperion` middleware module exposing a curated **`secure-app` wrapper** —
sensible security defaults (headers + CSRF + session) composed via `lack.builder`,
so an app opts into the whole stack with one call and can tune it. Generic and
app-neutral (a framework capability, not app logic).

## Open questions

- Interceptors vs middleware (above) — adopt an interceptor layer, or stay with
  Lack middleware?
- CSP policy shape (nonce-based for any inline? we mostly have none).
- Session store: signed cookie now; server-side (DB) later.
- How CSRF tokens compose with the Coalton-typed HTMX vocabulary + forms.

## Status

Captured; **not built** except the escape-by-default output posture (already in
force). Bundles with the **session management + secure cookies + user-pref**
subsystem already on the roadmap (Phase 4-adjacent). A future ADR records the
middleware/interceptor decision when we build it.
