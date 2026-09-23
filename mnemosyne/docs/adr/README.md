# Architecture Decision Records (ADRs) — Mnemosyne

Short, dated records of architecturally significant decisions in the **data layer** — the
*why* behind choices that are expensive to reverse or that a future session/machine would
otherwise re-litigate. One decision per file, numbered, immutable once Accepted (supersede
with a new ADR rather than editing history).

**Format** (keep each ≤ a page): Status · Context · Decision · Consequences ·
Alternatives considered · *(optional)* **Provenance**.

**Provenance — how the decision was reached**, added when the *process* shaped the outcome:
a measurement that contradicted an assumption, a counterargument that was asked for and
landed, a lean that was abandoned. See
[`../../../hyperion/docs/adr/README.md`](../../../hyperion/docs/adr/README.md) for the
convention in full — it applies unchanged here.

**Status values:** Proposed · Accepted · Provisional (accepted but under active review) ·
Superseded by ADR-NNNN · Deprecated.

Ecosystem-wide decisions live in the root [`ECOSYSTEM.md`](../../../ECOSYSTEM.md) decisions
log; web-framework decisions in [`hyperion/docs/adr/`](../../../hyperion/docs/adr/);
integration decisions in [`hermes/docs/adr/`](../../../hermes/docs/adr/).

## Index

| # | Title | Status |
|---|---|---|
| [0001](0001-unsupported-field-types.md) | What happens when a backend cannot support a declared field type | Accepted |
| [0002](0002-staleness-of-a-derived-value.md) | How a row says its derived value is stale | Accepted |
| [0003](0003-one-dialect-vocabulary.md) | One dialect vocabulary, and what a module does with a spelling it does not know | Accepted |
