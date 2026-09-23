# Architecture Decision Records (ADRs) — Praxeon

Short, dated records of architecturally significant decisions in the **agentic layer** — the
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
log; data-layer decisions in [`mnemosyne/docs/adr/`](../../../mnemosyne/docs/adr/);
web-framework decisions in [`hyperion/docs/adr/`](../../../hyperion/docs/adr/).

## Index

| # | Title | Status |
|---|---|---|
| [0001](0001-two-budgets-context-and-history.md) | Two budgets: what `assemble` is for, and what conversation history gets instead | Accepted |
| [0002](0002-data-access-through-means.md) | An agent reaches data through parameterised means, not generated SQL | Accepted |
