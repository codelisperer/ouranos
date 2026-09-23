# ADR-0003 — All-Spinneret templating (no Selmer/Djula)

**Status:** Accepted — 2026-07-16

## Context

Porting a prior Clojure/Kit app's landing page (`front.html`) — a large Bulma template whose copy
is all `{% i18n key %}` and which contains many inline SVGs. Two options: a
Selmer-analog (**Djula**) that keeps the `.html` almost verbatim plus an `{% i18n %}`
tag, or converting everything to **Spinneret** functions. (The founder's proven
pattern elsewhere is Selmer-pages + Hiccup-fragments.)

## Decision

**Render everything with Spinneret** — full pages and HTMX fragments alike. No
template-language dependency; copy comes from `(tr locale …)` calls.

- Matches Hyperion's constitution ("CLOS + Spinneret own rendering; runtime-open").
- One rendering model, one mental model, programmatic control.
- Inline SVGs from the source template are **extracted to asset files** and served
  statically rather than transcribed into Lisp (exact, keeps page code readable).

## Consequences

- Up-front conversion cost: ~560 lines of designer HTML → Spinneret functions
  (done section-by-section, with helpers for repeated structures).
- No runtime template files to hot-reload; pages are code, so the existing
  hot-reload loop covers them.
- i18n values that intentionally contain HTML (`<s>…</s>`, `<br/>`) render via
  `(:raw …)`; this assumes translation content is trusted (it is — we author it).
  See ADR-0006 and the i18n design doc for revisiting HTML-in-translations.

## Alternatives considered

- **Djula pages + Spinneret fragments** (the founder's proven split). Rejected for
  now to avoid a templating dependency and keep a single rendering model; revisit
  if hand-converting large designer templates proves too costly.
