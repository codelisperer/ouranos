# Architecture Decision Records (Aion)

Short, dated records of Aion's architecturally significant decisions — the *why* behind
choices that are expensive to reverse or that a future session/machine would otherwise
re-litigate. One decision per file, numbered, immutable once Accepted (supersede with a new
ADR rather than editing history).

**Format** (keep each ≤ a page): Status · Context · Decision · Consequences ·
Alternatives considered · *(optional)* **Provenance**.

**Provenance — how the decision was reached**, added when the *process* shaped the outcome:
a measurement that contradicted an assumption, a counterargument that was asked for and
landed, research that reframed the question, a lean abandoned. See
[`hyperion/docs/adr/README.md`](../../../hyperion/docs/adr/README.md) for the convention and
[`docs/working-with-ai.md`](../../../docs/working-with-ai.md) for why it exists.

## What is deliberately *not* here

**The libuv binding's founding decisions are in
[`../uv-design.md`](../uv-design.md) §"The five decisions"** — built from source and pinned;
no cmake or make; no grovelling; sync and async both real; callbacks re-enter Lisp only on
Lisp threads. They are well recorded there and are **not restated as ADRs**, because two
homes for one decision is the drift this tree keeps catching elsewhere.

Likewise the **ecosystem-level** rules that constrain Aion live in the
[`ECOSYSTEM.md`](../../../ECOSYSTEM.md) decisions log, not here: no C toolchain on the load
path, the platform's own first-party toolchain on the build path, and *native bindings
follow the DAG while abstractions over them follow the domain*.

An ADR here is for a decision **Aion owns and nothing else records.**

## Index

| # | Title | Status |
|---|---|---|
| [0001](0001-stream-contract.md) | The stream contract: backpressure, NODELAY, and loop introspection | Proposed |
| [0002](0002-libuv-integration-strategy.md) | libuv integration strategy: one async substrate, bound but not abstracted | Provisional |
| [0003](0003-windows-platform-binding.md) | The Windows platform binding: one Windows surface in aion, COM first | Provisional |

**Start with [0002](0002-libuv-integration-strategy.md)** for the whole libuv picture — it
is the umbrella, and it cross-references everything else (the five founding decisions in
[`../uv-design.md`](../uv-design.md), the placement rule in
[`ECOSYSTEM.md`](../../../ECOSYSTEM.md), the stream contract in 0001, and the open work).
Numbering here is chronological, not hierarchical.
