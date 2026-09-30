# Middleware & security posture (design)

*Partly built. The safe-output posture (Spinneret escaping, `hyperion/markdown:render`) is in
force, the security headers are sent by default (#119, section "Security headers" below), and
CSRF refusal is `hyperion/csrf:wrap-csrf` for an app with sessions and
`hyperion/csrf:wrap-same-origin` for one without (#293; `hyperion/desktop` installs it by
default). The rest is a design capture.*

## Which server has the same-origin guard (#304)

`wrap-same-origin` refuses a request whose Host is not the server's own, on every method, and an
unsafe request that did not come from the server's own page. It protects a server that holds a
user's data on their machine, with no session to check a token against, from two attacks: a web
page the user visits posting to it, and a DNS-rebinding page reading from it.

| Entry point | Default | Change it when |
|---|---|---|
| `hyperion/desktop:run-app`, `:embedded` or `:hybrid` | on (`:request-guard :same-origin`) | never, unless the app does its own checking (`:none`) |
| `hyperion/dev:serve` on loopback (127.0.0.1, ::1, localhost) | on | never for a real app; `:request-guard :none` only for a test that needs it off |
| `hyperion/dev:serve` on any other host | off, with a warning | pass `:request-guard (:same-origin "http://HOST:PORT" ...)` with the origins you browse to |
| `hyperion/server:start`, `serve-forever` | off (`:none`) | on (`:same-origin`) when it serves a desktop app's UI or a user's data headless on 127.0.0.1. `serve-forever`'s `:readiness-path` is always exempt (below) |
| `run-app :backend (:remote URL)` | none of its own | guard the server at URL instead |

On loopback the guard accepts both `127.0.0.1:PORT` and `localhost:PORT`. A rebinding page cannot
use either, because its Host is the attacker's domain.

`server:start` is off by default because of reverse proxies. A production app behind a proxy on
the same machine binds 127.0.0.1 but receives the public Host from the proxy, so a default guard
would refuse every real request. For a server reached by a name other than its bind address, pass
the origins: `:request-guard (:same-origin "https://app.example.com")`. `:same-origin` with a
server bound to every interface (`0.0.0.0`) signals an error, because the guard cannot know which
names are the app's own.

**The readiness path is exempt from the request guard.** In `serve-forever`, a request for
`:readiness-path` skips both the Host check and the Origin check, because a platform's health
checker sends no Origin and may use another Host, and refusing it would take a healthy instance
out of rotation. When the server is not draining, that request reaches the app's own handler
unguarded, so an app must serve nothing there but a status: a DNS-rebinding page can read
whatever that path returns.

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

## Security headers (built, #119)

`hyperion/server:start` wraps every app in `hyperion/security-headers:wrap-security-headers`
unless it is started with `:security-headers nil`. `serve-forever` takes the same option. Every
response then carries:

| header | default | why |
|---|---|---|
| `X-Content-Type-Options` | `nosniff` | a response is never sniffed into a type it was not sent as |
| `X-Frame-Options` | `DENY` | no page can be framed by another site (clickjacking); for older browsers |
| `Referrer-Policy` | `strict-origin-when-cross-origin` | a cross-origin request carries the origin, never the path |
| `Content-Security-Policy` | `frame-ancestors 'none'; base-uri 'self'; object-src 'none'` | the directives that do not depend on the page's markup |
| `Strict-Transport-Security` | not sent | opt-in; see below |

**The CSP has no `script-src` or `style-src` by default, on purpose.** Measured on the tree's
own pages served through `start`: active-search and active-search-db each inline one
compiled-Parenscript `<script>` and load Alpine, whose standard build evaluates expressions at
run time; coalton-repl inlines three `<script>` blocks; praxeon/web inlines its chat script;
and `hyperion/dev` injects an inline poller. `script-src 'self'` would break every one of
them. An application that emits no inline script should set a full policy.

**Overriding.** Each header has a special variable and a keyword of the same name without
earmuffs: `*content-type-options*`, `*frame-options*`, `*referrer-policy*`,
`*content-security-policy*`, `*hsts*`. A string replaces the default, and `nil` turns the header
off. Pass keywords through `start`:

```lisp
(srv:start app :security-headers
           '(:content-security-policy "default-src 'self'; frame-ancestors 'none'"
             :hsts "max-age=31536000; includeSubDomains"))
```

A header the application sets on its own response is never replaced, so one route can loosen
or tighten a header (a page that must be framed by a known origin, say) without the wrapper
knowing about it.

**HSTS** is off by default because it binds browsers to HTTPS for the whole host for
`max-age`, and hyperion does not terminate TLS itself (#125), so it cannot know the deployment
is HTTPS-only. `(hyperion/security-headers:hsts-value)` builds a value: one year and
`includeSubDomains` by default, and `preload` only with `:preload t`, because a preload-list
entry is close to irreversible.

**What does not get the headers.** A handler that signals an error, rather than returning a
500 itself, gets the backend's own error page, which the wrapper never sees: measured, that
500 carries none of these headers. An app that wants them on error pages returns its own error
response.

**Asserting them.** The failure mode for this category is a header that quietly stops being
sent. `hyperion/tests/security-headers-tests.lisp` asserts them on a real socket through
`start`; an application can do the same against its own routes.

## Proposed shape

A `hyperion` middleware module exposing a curated **`secure-app` wrapper** —
sensible security defaults (headers + CSRF + session) composed via `lack.builder`,
so an app opts into the whole stack with one call and can tune it. Generic and
app-neutral (a framework capability, not app logic).

## Open questions

- Interceptors vs middleware (above) — adopt an interceptor layer, or stay with
  Lack middleware?
- CSP policy shape. Answered for now by measurement (see "Security headers"): the tree's pages
  DO inline script, so the default leaves script-src to the app. A nonce-based `script-src`,
  with the page shell adding the nonce to hyperion's own inline scripts, is the way to a strict
  default and is not built.
- Session store: signed cookie now; server-side (DB) later.
- How CSRF tokens compose with the Coalton-typed HTMX vocabulary + forms.

## Status

**Built:** the escape-by-default output posture, the security headers (#119, above), and the
CSRF refusal (`hyperion/csrf`: the session-token check, and the Host / Sec-Fetch-Site /
Origin check for an app with no session, #293). **Not built:** a single `secure-app` wrapper composing headers,
CSRF and session in one call; a nonce-based strict CSP. Bundles with the **session
management + secure cookies + user-pref** subsystem already on the roadmap (Phase 4-adjacent). A future ADR records the
middleware/interceptor decision when we build it.
