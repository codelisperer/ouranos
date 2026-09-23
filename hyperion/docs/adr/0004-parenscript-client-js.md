# ADR-0004 — Parenscript for client JS (no Node); dogfood the poller

**Status:** Accepted — 2026-07-16

## Context

Hyperion forbids Node in the toolchain. Client JS is authored in Lisp and compiled
with Parenscript. The constitution calls for dogfooding: replace hand-written JS
(the hot-reload poller, interaction helpers) with Parenscript.

## Decision

**All client JS is Parenscript**, compiled through `hyperion/output:js-string` so
it honors the output style (ADR-0005). The generic interaction helpers
(`stick-to-bottom`, `autogrow-textarea`, `enter-submits`) are selector-parametrized
and domain-neutral; the hot-reload poller is generated per request.

**Placement rule.** A JS helper lives in `hyperion/js` **only if it is generic
and/or parameterizable** (selectors, URLs, options passed by the caller — nothing
app-specific baked in). Anything app-specific (a particular endpoint, a
domain-specific behavior) lives in that app's own web layer (e.g. `praxeon/web`).
Corollary: the app supplies selectors and its own URLs; the shared helpers never
hardcode them. (The dev-reload endpoint *defaults* are the one framework
convention, and they are overridable.)

## Consequences — the gotchas we hit (and how we verify)

- **Parenscript's own macros must be the real `parenscript:` symbols.** PS matches
  CL-package operators (`if`/`let`/`setf`/`and`/`funcall`) by *name*, but its own
  macros (`chain`, `@`, `new`, `create`) by *symbol identity*. Interning them in
  another package leaks them through as literal `chain(...)`/`catch(...)` — invalid
  JS. Fix: `(:import-from #:parenscript #:chain #:@ #:new #:create)` in the package
  that authors the PS.
- **`create` does not camelCase keys.** `(create :child-list t)` emits
  `{'child-list': true}`; APIs like `MutationObserver` need `childList`. Use string
  keys (`(create "childList" t)`).
- **JS must be validated, not just eyeballed.** An "entity-free" check is not
  enough (broken JS can be entity-free). We validate emitted JS with `node --check`
  as a **test oracle only** — Node is never a runtime or build dependency.
- JS that must honor dev/prod style is **generated at render time**, not baked into
  a `defparameter` at load (a baked string keeps its load-time style forever).

## Alternatives considered

- **Hand-written JS strings.** Rejected: not dogfooding; the poller/overlay is the
  canonical target.
- **A JS bundler/minifier (Terser, esbuild).** Rejected: reintroduces Node. If we
  ever want true minification we build it in CL (a future output-style member).
