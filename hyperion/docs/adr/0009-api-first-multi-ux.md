# ADR-0009 — API-first, multi-UX: split the hypermedia and data APIs; type the data contract in Coalton

**Status:** Provisional — 2026-07-25

## Context

A Hyperion product is **not one UX**. A single core should expose many faces — web,
desktop, CLI, native mobile, and a pure programmatic API — the **GitHub / GitHub-Desktop
/ `gh`** pattern: each surface is a thin adapter, and a desktop or mobile client may
consume only *part* of the API rather than replicate the whole app. Hyperion should make
this easy "out of the gate," not special-cased per product.

The tension: classic HTMX returns **HTML fragments**, not JSON. Naive "API-first =
everything JSON, render client-side" would throw away HTMX's whole advantage; ignoring
API-first strands the non-web surfaces. There is a known hypermedia-community answer
(Carson Gross, *"Splitting Your Data and Application APIs"*): they are two different APIs.

## Decision

**1. Two distinct edge APIs over one domain core.**
- **Application / hypermedia API** — returns **HTML fragments** (Spinneret), shaped for
  the web UI, **un-versioned**, free to change with the UI. Consumed by the web UX and
  the desktop-as-webview UX.
- **Data API** — returns **JSON**, **stable and versioned**, the contract that native
  mobile, CLI, third parties, and pure-API consumers bind to.

Both are thin **effectful CL shells over the same domain core** (mnemosyne persistence,
aion/Coalton logic). A surface picks what it consumes; a specialized client uses a subset
(+ optionally its own views). This is what lets a desktop/mobile app be "a specialized
add-on that uses *some* of the web app's API," not a replica.

**2. The data-API contract is expressed as Coalton types (API-first, typed).** Request/
response DTOs are Coalton `define-type`s; JSON codecs are generated from them; an
OpenAPI / JSON-Schema document can be *emitted* for third parties. This extends
[ADR-0002](0002-coalton-core-cl-shell.md) (typed Coalton core, effectful CL shell) to the
API edge and mirrors [ADR-0001-era `hyperion/htmx`](../roadmap.md) (a typed vocabulary in
Coalton): the public contract is compile-time-checked, the (de)serialization generated,
the handlers effectful shells over typed values. The hypermedia API is deliberately **not**
typed this way — it emits HTML and is coupled to the UI on purpose.

**3. Surfaces are thin adapters; a product may declare several** — `api` · `web` ·
`desktop` · `cli` · `mobile` — each scaffolded by `cons` over the shared core. This
converges with [cons-vision §10](../../../cons/docs/cons-vision.md) ("a project may declare
several targets"): the UX surfaces *are* those targets, now enumerated.

**Provisional sub-positions (to firm up as the data API is built):**
- **Auth** — one identity/principal, two credential styles: cookie/session
  (`hyperion/session`) for web/hypermedia; bearer tokens / API keys for the data API.
- **Data-API posture** — **opt-in per product** (a local one-off, e.g. the visual Coalton
  REPL, needs no data API); first-class when present.
- **Versioning** — the data API is explicitly versioned (`/api/v1` or a header); the
  hypermedia API is explicitly **un**-versioned.

## Consequences

- Web/desktop keep HTMX's hypermedia benefits; mobile/CLI/third parties get a stable,
  typed JSON contract — **no surface compromises the others.**
- The desktop shell ([ADR-0008](0008-desktop-shell-cl-native-webview.md)) gains an escape
  hatch: `run-app` supports `:embedded` (default — local in-process server, the one-off
  app), `:remote <url>` (the GitHub-Desktop model — webview points at a remote backend),
  and `:hybrid`. **The localhost default is no longer hardcoded** (as the Tauri app playbook
  already warned: "make the host configurable").
- Implies a new **`hyperion/api`** capability (Coalton DTO → JSON codec + route helpers +
  OpenAPI emit), likely leaning on aion for the type/serialization machinery. Real work;
  sequence after the web/hypermedia core is solid.
- cons templates grow from `lib/cli/web/agent` toward UX-surface kinds; §10's
  "several targets per project" becomes the concrete multi-UX mechanism.
- Cost: maintaining two edges. Mitigated because both are thin over one core — the split
  is a *feature* (contract stability vs UI agility), not duplication.

## Alternatives considered

- **Single JSON API + client-side rendering (SPA everywhere).** Rejected: discards
  HTMX/hypermedia and reintroduces the JS-heavy stack the thesis exists to avoid.
- **Hypermedia only, no data API.** Rejected: strands native mobile, CLI, and programmatic
  consumers; leaves no stable public contract.
- **Untyped / hand-written JSON contract.** Rejected: violates the typed-core thesis; a
  stable *public* contract is exactly what most deserves compile-time typing + generated codecs.
- **Spec-first (OpenAPI → CL).** Reasonable, but inverts the typed-core direction; prefer
  Coalton-types-first with OpenAPI as a generated *output*. Revisit only if third-party
  spec-first interop demands the reverse.
