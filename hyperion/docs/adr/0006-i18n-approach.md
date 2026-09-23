# ADR-0006 — i18n: dictionaries, negotiation, storage

**Status:** Accepted — 2026-07-16 (settled from an earlier provisional first cut;
detail and open items in [`../i18n-design.md`](../i18n-design.md))

## Context

A prior Clojure/Kit web app is bilingual (en/ru) and every landing-page string is an
i18n key. The port needs locale dictionaries, resolution, and a persisted language
switch — and the framework must make **translating to any language and adding a
language easy** (a consuming app will be a multilingual content platform).

## Decision

`hyperion/i18n`, app-neutral (the app supplies dictionaries and keys):

- **Storage: per-locale JSON files** (`resources/i18n/<code>.json`), loaded via
  `jzon` (already a dependency — no new dep). **Adding a language = drop a
  `<code>.json` file**; supported locales are derived from the files present, no
  code change. `.edn` is retained as the authoring source and generates the JSON.
  The dictionary abstraction hides the source, so a later **DB/CMS backend** swaps
  in without touching call sites.
- **Lookup: flat `:section/key`, explicit locale** — `(translate dict locale
  :home/join-the …)`; falls back to the default locale, then a visible
  `"[section/key]"` marker.
- **Resolution:** `resolve-locale` is the **middleware seam** — priority
  `?lang=` > user preference > cookie/session > `Accept-Language` > default.
  `user-pref` is reserved for the coming auth/user-preferences work (which brings
  session management + secure cookies — a separate ADR, not built here).
- **Interpolation:** `{named}` placeholders (`interpolate`).

## Consequences

- Zero new dependency; the landing-page port can proceed on the settled API.
- "Add a language" is a data operation (drop a file → later, a DB row / CMS entry).
- Deferred (see design doc): pluralization (Russian CLDR), a key-parity check,
  dev hot-reload of dictionaries, and DB-backed runtime editing.
- **AI-assisted translation stays out of the i18n core** — it belongs at the
  app/CMS layer (a consuming app + praxeon agents); Hyperion only provides the
  data-driven loading that accepts generated locales.

## Superseded first cut

The initial cut stored a prior Clojure/Kit app's `.edn` and read it via a brace→paren transform
(no EDN dep). Replaced by per-locale JSON for a cleaner path to data-driven i18n.
A real CL **EDN** library (none in the pinned Quicklisp dist) remains worth adding
for **XTDB 2** interop later; not needed for i18n.
