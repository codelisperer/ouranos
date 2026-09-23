# Architecture Decision Records (Hades)

Short, dated records of Hades's architecturally significant decisions — the *why* behind
choices that are expensive to reverse or that a future session/machine would otherwise
re-litigate. One decision per file, numbered, immutable once Accepted (supersede with a new
ADR rather than editing history).

**Format** (keep each ≤ a page): Status · Context · Decision · Consequences ·
Alternatives considered · *(optional)* **Provenance**.

**Provenance — how the decision was reached**, added when the *process* shaped the outcome: a
measurement that contradicted an assumption, a counterargument that was asked for and landed,
research that reframed the question, a lean abandoned. See
[`hyperion/docs/adr/README.md`](../../../hyperion/docs/adr/README.md) for the convention.

## What is deliberately *not* here

**The binding is aion's.** `aion/windows` and its subsystems are recorded in
[`aion/docs/adr/0003-windows-platform-binding.md`](../../../aion/docs/adr/0003-windows-platform-binding.md),
including the apartment policy, the struct-layout doctrine and the no-C-toolchain rule. Hades
does not restate them; two homes for one decision is the drift this tree keeps catching.

**The ecosystem-level rules** — that Hades is a satellite on hermes's terms, that native
bindings follow the DAG while abstractions over them follow the domain, and that `bootstrap.lisp`
compiles the host's platform package — live in the
[`ECOSYSTEM.md`](../../../ECOSYSTEM.md) decisions log.

An ADR here is for a decision **Hades owns and nothing else records.**

## Index

| # | Title | Status |
|---|---|---|
| [0001](0001-charter.md) | Hades: what earns a portable facade, and what does not | Provisional |
