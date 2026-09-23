# Elenchon — Vision Questions (resolution index)

The ten founding design questions, **all now resolved** by
[`docs/adr/0001`–`0005`](adr/README.md) (2026-07-29). This file is kept as the index
from question to decision — the questions are the natural entry point, and a reader who
knows what they want to ask should not have to guess which ADR answers it.

The decisions are **Provisional**: accepted and safe to build against, open to revision
by a superseding ADR if evidence contradicts them. Two departed from the lean recorded
here at founding — Q2 and Q8 — and each ADR records why.

Grounded in [`method.md`](method.md); read that first.

| # | Question | Resolution | Where |
|---|---|---|---|
| 1 | CEG representation: node graph or expression tree? | **Expression DAG** — one rooted expression per effect, sharing made explicit by a named `Ref` node; the classic node diagram is derived. Refines the recorded lean, which lost shared-node identity. | [ADR-0001](adr/0001-ceg-representation.md) |
| 2 | Reasoning engine: miniKanren, table-walk, or SAT/SMT? | **Native Coalton pair-generation + set cover first**, behind a `Solver` protocol. *Departs from the lean* — miniKanren addresses the search half, not the minimization half, and costs determinism. Retained as a prototype backend for pair generation. | [ADR-0002](adr/0002-reasoning-engine.md) |
| 3 | Coverage target: exactly MC/DC, or configurable? | **Configurable** — `Decision` / `Independence` / `MultipleCondition`, defaulting to `Independence` (≈ MC/DC). Every artifact states its criterion. | [ADR-0003](adr/0003-coverage-target.md) |
| 4 | The CEG-building API contract. | **A validating builder** accepting partial input and returning *every* finding, not the first. Elenchon validates structure, never propositions. | [ADR-0004](adr/0004-builder-contract-and-extraction-seam.md) |
| 5 | Requirement input format. | **`requirement = ID + text`** as the traceability anchor; every cause and effect carries an optional `ReqId`. Document formats are the consumer's problem, always. | [ADR-0004](adr/0004-builder-contract-and-extraction-seam.md) |
| 6 | Test-case output formats. | **The `DecisionTable` value is canonical**; renderers are separate and pure. v1: human table + machine-readable s-expression. Executable stubs deferred, and generic given/when/then before fiveam. | [ADR-0004](adr/0004-builder-contract-and-extraction-seam.md) |
| 7 | Is the defect report a co-equal product, or a byproduct? | **The product.** Elenchon is a requirement-defect finder that also generates tests. `elenchon/report` becomes a v1 module. | [ADR-0005](adr/0005-positioning-defect-finder-first.md) |
| 8 | Does Elenchon expose an extraction protocol? | **No — the seam is data.** The `Draft`/`Outcome` types *are* the contract. *Departs from the lean*: a generic function Elenchon never dispatches on is documentation, not a protocol. | [ADR-0004](adr/0004-builder-contract-and-extraction-seam.md) |
| 9 | Validation strategy / evidence. | **A mechanical coverage proof first** — brute-force ground truth as a CI property test — then the worked canonical example, then a benchmark corpus, then a Bender comparison. | [ADR-0005](adr/0005-positioning-defect-finder-first.md) |
| 10 | Scope guard: functional black-box only? | **Yes, and stated loudly.** Pairwise and classification trees are out of scope; under ADR-0002 they could later arrive as `Solver` instances, so the boundary costs nothing to hold. | [ADR-0005](adr/0005-positioning-defect-finder-first.md) |

## What is still genuinely open

The ADRs closed the founding questions; these came *out* of closing them, and are the
live design work:

- **The `Draft` type is unspecified.** ADR-0004 fixes the `Outcome` side of the seam but
  not the input side. It should be shaped by ChatRBT's actual needs — the praxeon lane
  should review it before it hardens.
- **Cycle detection over `Ref`** is a new obligation created by ADR-0001 and owed by the
  builder.
- **The `MultipleCondition` ceiling** (ADR-0003) needs a concrete number, which wants the
  ADR-0002 benchmark to exist first.
- **Where the exact/greedy cut-off sits** for minimization — likewise a benchmark
  question, and the benchmark is the first thing the reasoning work should produce.
- **Aion's role.** Elenchon currently uses plain Coalton `List`s. Whether the CEG's
  lookups want aion's persistent collections is a real question once graph sizes are
  known; premature until the benchmark exists.

---

*The questions in their original open form, with the leans recorded at founding, are in
this file's git history (superseded 2026-07-29).*
