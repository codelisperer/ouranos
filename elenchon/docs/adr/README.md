# Architecture Decision Records (Elenchon)

Short, dated records of Elenchon's architecturally significant decisions — the *why*
behind choices that are expensive to reverse or that a future session/machine would
otherwise re-litigate. One decision per file, numbered, immutable once Accepted
(supersede with a new ADR rather than editing history).

**Format** (keep each ≤ a page): Status · Context · Decision · Consequences ·
Alternatives considered. **Status values:** Proposed · Accepted · Provisional
(accepted but under active review) · Superseded by ADR-NNNN · Deprecated.

These are Elenchon-level decisions. Ecosystem-wide decisions live in the root
[`ECOSYSTEM.md`](../../../ECOSYSTEM.md) decisions log; the design *narrative* (why
Elenchon exists, the positioning, the prior art) lives in
[`docs/wiki/Framework-Elenchon.md`](../../../docs/wiki/Framework-Elenchon.md); the
method and its vocabulary are fixed by [`../method.md`](../method.md).

These five ADRs resolve the ten open questions in
[`../elenchon-vision.md`](../elenchon-vision.md), which is now a resolution index
rather than a live question list.

## Index

| # | Title | Status | Resolves |
|---|---|---|---|
| [0001](0001-ceg-representation.md) | CEG representation: an expression DAG, with the node diagram derived | Provisional | Vision Q1 |
| [0002](0002-reasoning-engine.md) | Reasoning engine: native pair-generation + set cover first, behind a `Solver` protocol | Provisional | Vision Q2 |
| [0003](0003-coverage-target.md) | Coverage target: configurable, MC/DC-equivalent by default | Provisional | Vision Q3 |
| [0004](0004-builder-contract-and-extraction-seam.md) | The builder contract is a validating one, and the extraction seam is data, not a protocol | Provisional | Vision Q4, Q5, Q6, Q8 |
| [0005](0005-positioning-defect-finder-first.md) | Positioning: a requirement-defect finder that also generates tests | Provisional | Vision Q7, Q9, Q10 |
