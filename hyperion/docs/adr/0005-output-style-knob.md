# ADR-0005 — One output-style knob: dev pretty / prod compact

**Status:** Accepted — 2026-07-16

## Context

Spinneret (HTML) and Parenscript (JS) both key their formatting off dynamic
variables (`*print-pretty*`, `spinneret:*html-style*`, `parenscript:*ps-print-pretty*`,
…). Without a single control they drift: e.g. Elise served pretty JS but
single-line HTML, because the page rendered via bare `spinneret:with-html-string`
(ambient `*print-pretty*` nil in server threads) while JS went through the knob.
The founder wants: **dev = pretty everything (readable view-source); prod (built
exe) = minify both.**

## Decision

`hyperion/output` owns a single knob, **`*output-style*`** — an enum
`(:pretty | :compact)`, not a boolean, so a future `:minified` slots in without
touching call sites. `with-output-style` binds *all* the Spinneret + Parenscript
formatting variables to match. Rules:

- **Render within `with-output-style`.** Apps wrap their request dispatch in it, so
  every response (HTML, JS, fragments) obeys the same style.
- **Style follows environment.** `*output-style*` defaults to `:pretty` (dev/REPL);
  an app sets it to `:compact` in prod. Praxeon's `start` sets it from its `:dev`
  flag (`:dev t` → pretty; otherwise compact).
- **Style-sensitive JS is generated at render time**, never baked at load
  (see ADR-0004).

## Consequences

- Deterministic output regardless of thread/ambient `*print-pretty*`.
- "compact" means whitespace-minimal, not a true minifier (no identifier renaming
  or dead-code elimination) — good enough; Parenscript can also obfuscate package
  symbols if needed later.
- A tiny amount of residual whitespace can remain from explicit separators in
  hand-composed multi-snippet JS; acceptable.

## Alternatives considered

- **Separate HTML and JS knobs.** Rejected: one place to configure is the point.
- **External minifier.** Rejected (Node) — see ADR-0004.
- **Per-call style arguments threaded everywhere.** Rejected: noisy; the dynamic
  var + boundary-wrap is cleaner.
