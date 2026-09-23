# Architecture Decision Records (ADRs)

Short, dated records of architecturally significant decisions — the *why* behind
choices that are expensive to reverse or that a future session/machine would
otherwise re-litigate. One decision per file, numbered, immutable once Accepted
(supersede with a new ADR rather than editing history).

**Format** (keep each ≤ a page): Status · Context · Decision · Consequences ·
Alternatives considered · *(optional)* **Provenance**.

**Provenance — how the decision was reached**, added when the *process* shaped the outcome
rather than incidental. Not attribution and not a changelog: a short note on what actually
moved the decision — a measurement that contradicted an assumption, a counterargument that
was asked for and landed, research that reframed the question, a lean that was abandoned.
This is the part a future reader cannot reconstruct from the outcome, and it is the part
that most often explains why a decision looks odd in hindsight.

It matters here specifically because this stack is engineered *with AI assistance* as a
deliberate practice ([`../../../docs/working-with-ai.md`](../../../docs/working-with-ai.md)).
The maintainer owns every decision; assisted research frequently shapes what the choices
even are. Recording that is more honest — and far more useful — than a per-commit
attribution trailer, which says nothing about how anything was decided.

**Status values:** Proposed · Accepted · Provisional (accepted but under active
review) · Superseded by ADR-NNNN · Deprecated.

These are Hyperion-level (web-framework) decisions. They live here for historical
reasons — early on Hyperion was slated to carry the shared machinery (ADR-0001, now
**superseded** by ADR-0007: the six frameworks are distinct dirs in the Ouranos
monorepo). Ecosystem-wide decisions now live in the root [`ECOSYSTEM.md`](../../../ECOSYSTEM.md)
decisions log; app-specific decisions live in that app's own `docs/`.

The tree has since gained a seventh directory, **`hermes`** — a satellite leaf-lib for
external integrations (email/SMS, later payments) that depends only on `aion`. It is
not part of the linear core DAG, so it does not change ADR-0007's decision (recorded
here as accepted, unedited).

## Index

| # | Title | Status |
|---|---|---|
| [0001](0001-consolidate-into-hyperion.md) | Consolidate the ecosystem into Hyperion (library + CLI) | Superseded by ADR-0007 |
| [0002](0002-coalton-core-cl-shell.md) | Typed core in Coalton, effectful shell in CL | Accepted |
| [0003](0003-all-spinneret-templating.md) | All-Spinneret templating (no Selmer/Djula) | Accepted |
| [0004](0004-parenscript-client-js.md) | Parenscript for client JS (no Node); dogfood the poller | Accepted |
| [0005](0005-output-style-knob.md) | One output-style knob: dev pretty / prod compact | Accepted |
| [0006](0006-i18n-approach.md) | i18n: dictionaries, negotiation, storage | Provisional |
| [0007](0007-split-into-six-frameworks-monorepo.md) | Split back into six frameworks under the Ouranos monorepo | Accepted |
| [0008](0008-desktop-shell-cl-native-webview.md) | Desktop shell: CL-native, out-of-process OS webview (no Tauri/Electron) | Provisional |
| [0009](0009-api-first-multi-ux.md) | API-first, multi-UX: split hypermedia/data APIs; type the data contract in Coalton | Provisional |
| [0010](0010-desktop-distribution-and-self-update.md) | Desktop distribution & self-update: signed manifest, stage-and-swap, native-runner CI | Provisional |
| [0011](0011-desktop-server-backend-and-content-length.md) | Desktop bundles use Hunchentoot; buffered responses carry Content-Length | Accepted |
| [0012](0012-routing-typed-paths-cl-dispatch.md) | Routing: typed path patterns in Coalton, dispatch in CL | Accepted |
| [0013](0013-bundling-native-libraries.md) | Bundled native libraries: carry what we build, resolve beside the image | Accepted |
| [0014](0014-macos-runtime-linked-libraries.md) | macOS: patch the runtime before the dump, not the image after it | Accepted |
| [0015](0015-ring-calling-convention-without-clack.md) | Keep the Ring calling convention; drop the Clack library | Accepted |
| [0016](0016-server-to-client-stream-back-pressure.md) | Server→client streams coalesce per key at a subscription's rate | Accepted |
| [0017](0017-native-uv-server-as-default-backend.md) | The native `:uv` server becomes the default backend | Proposed |
| [0018](0018-desktop-native-menus-and-tray.md) | Desktop native menus: declared by the app, rendered by the launcher | Proposed |
| [0019](0019-csrf-and-the-pre-authentication-fork.md) | CSRF: one mechanism, central on both sides, and a session before sign-in | Proposed |
