# CLAUDE.md — Elenchon

Tree-wide rules are in the root `CLAUDE.md`/`AGENTS.md`, loaded with this file. Only
elenchon-specific notes here.

## What this is

The Cause-Effect Graph engine and reasoning system for Requirements-Based Testing (Bender
lineage). Given a structured CEG (causes, effects, E/I/O/R/M constraints) it generates the
minimum test set covering the maximum share of the requirement logic, plus a
requirement-defect report. **The report leads; the suite proves the analysis was rigorous**
(ADR-0005) — build `elenchon/report` before `elenchon/cases`.

## Scope boundary — it decides the architecture

Turning prose into a CEG is an agentic function that lives **above** Elenchon, in praxeon
(ChatRBT). Elenchon depends only leftward and must never depend on praxeon or hyperion.

## Vocabulary

`docs/method.md` fixes the terms the code uses — causes, effects, the constraint letters,
functional variation, decision table. Use those, not "node/rule/case". Elenchon owns steps
(2)–(4) of the method; step (1) is the consumer's.

## Gotchas

- The reasoning engine is a `Solver` protocol (ADR-0002): native pair-generation + set
  cover in v1; miniKanren / FFI'd SAT are alternate instances, not rewrites.
- Read ADR-0001 before touching the CEG ADT (`src/ceg.lisp`), ADR-0002 before the solver.
- The condition system here literally models requirement ambiguity.

## Where to look

`docs/method.md` · `docs/adr/README.md` · `docs/elenchon-vision.md` ·
[`../docs/wiki/Framework-Elenchon.md`](../docs/wiki/Framework-Elenchon.md).
