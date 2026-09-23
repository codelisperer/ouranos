# CLAUDE.md — Hyperion

Tree-wide rules are in the root `CLAUDE.md`/`AGENTS.md`, loaded with this file. Only
hyperion-specific notes here.

## What this is

A web framework for CL biased toward the live image: server-rendered HTMX, Parenscript for
JS (no Node), a CSS DSL, and a REPL-driven hot-reload loop. **Generic** components only —
never domain-specific. **A library, not a tool**: creating/building/running apps is `cons`'s
job. Its initial code was extracted from `praxeon/src/web.lisp`.

## The split

- **Coalton** owns the typed HTMX vocabulary (`Swap`, `Trigger`, `Target`, `Verb`,
  `Duration`, OOB, SSE) and the HTTP/1.1 encoder — values that can't express a bad combo.
- **CLOS + Spinneret** own rendering: a `render` generic apps specialise.
- **Parenscript** owns client JS. **`hyperion/assets`** (opt-in) vendors htmx, Alpine and
  Bulma 1.x into the image — never a CDN, so desktop works offline. Pinned in
  `assets/vendor/ASSETS.pin`; `scripts/check-assets.lisp` verifies.

## Design facts

- **Hyperion declares no HTTP server** (#139). The app depends on the Clack handler it
  wants; `hyperion/server:default-server` picks from what loaded. `server-uv` (native
  libuv, #117) is the destination; Woo and Hunchentoot go when it lands.
- Sessions are behind a `store` protocol; `rotate-session` exists — don't hand-roll it.
- Desktop is an out-of-process native webview. `libev` is no longer needed (ADR-0011).
- **A streaming body is a function in body position**, `(status headers (lambda (writer)
  …))`; a shim adapts it onto Clack's responder protocol. On Clack backends a stream that
  fails mid-flight is reported to the client as **complete** — only `server-uv` truncates
  honestly. SSE (`text/event-stream`) is refused under the inline dispatcher.
- `hyperion/channel` is bounded (`*default-capacity*`, `:capacity nil` for forever) and a
  reader that falls out of the window is signalled. `hyperion/feed` coalesces per key at the
  subscriber's rate (ADR-0016); no queue anywhere above it.
- `secure-app` (CSRF, CSP, security headers) is **planned**, not bundled — `docs/middleware-security.md`.

## Gotchas (hot reload)

- `dev:serve` takes a **thunk returning a fresh app**, not the app (#235); it does **not
  block** (#236); `:system` watches `<system>/src/` only — use `:paths` for a multi-surface
  repo (#237); a changed `defstruct` leaves stale dependents ("X is not of type X") and
  self-heals (#234); an error page carries no poller until #233.
- The entropy guard (#95) covers all of `hyperion/src`, comments included.

## Where to look

`docs/hyperion-vision.md` · `docs/adr/` · `docs/desktop-distribution-design.md` ·
[`../docs/wiki/Framework-Hyperion.md`](../docs/wiki/Framework-Hyperion.md).
