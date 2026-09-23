# Mnemosyne

**The bitemporal data layer for Common Lisp / Coalton — Ecto-like, backend-neutral.**

Mnemosyne is the persistence sibling of the codelisperer ecosystem: a schema/query
DSL + migrations + connection behind a **neutral backend protocol** (over **CL-DBI**),
with **bitemporality** (valid-time + transaction-time) as a first-class concern. Named
for the Titaness of **memory** — it remembers all of history.

Six sibling core frameworks (in dependency order, lowest → highest), plus
[`hermes`](../hermes) — a satellite leaf-lib off the DAG (external integrations:
neutral email + SMS, payments later; depends only on `aion`). See the
[root README](../README.md) and [ECOSYSTEM.md](../ECOSYSTEM.md) for the full overview:

| Project | Role |
|---|---|
| [`aion`](../aion) | Coalton-first functional standard library |
| [`cons`](../cons) | project & dev tooling ("cargo for Lisp") |
| **`mnemosyne`** | this — the bitemporal data layer |
| [`elenchon`](../elenchon) | CEG / RBT engine |
| [`hyperion`](../hyperion) | HTMX web framework (library only — tooling is cons's job) |
| [`praxeon`](../praxeon) | agentic-AI framework |

### The three-tier memory stack

```
Praxeon    leverages Kairos for recall + context-budget economics (praxeological)
   │
Kairos     a dedicated bitemporal knowledge-GRAPH store, built on ...
   │
Mnemosyne  general bitemporal DB abstractions (connection / schema / query / migrate)
```

Mnemosyne is the **DB**; **Kairos** is the graph on it; **Praxeon** is the agent on
Kairos. Thematically: **Aion** (time) · **Kairos** (the opportune moment) ·
**Mnemosyne** (memory).

## Approach (the common core)

- **Typed core in Coalton; effectful shell in CL.** Schema/query *types* are
  compile-time-checked Coalton; connection/IO is CL. No IO in Coalton.
- **Pluggable backends behind a neutral protocol** over **CL-DBI**. The decided
  progression is **SQLite → Postgres → XTDB 2** (embedded-first): SQLite for the
  zero-ops transactional MVP, Postgres next (mostly a connection-string change over
  one DBI adapter), XTDB 2 later as a separate adapter for bitemporal work. See
  [`docs/first-milestone.md`](docs/first-milestone.md) — the settled plan.
- **Bitemporal by design** — valid-time + tx-time, not bolted on.

## Status

**Pre-alpha (0.0.0) — scaffold.** See `docs/roadmap.md` for the plan and
`docs/mnemosyne-vision.md` for the open design questions. First consumers:
a consuming app (users/content/subscriptions) and Praxeon's Kairos.

## Getting started

This framework is one of six core frameworks (plus `hermes`) in the
[Ouranos monorepo](../README.md); you build the
whole tree, not this directory alone. Prereqs: **SBCL + Quicklisp** (Coalton loads from
Quicklisp on first use).

    git clone https://github.com/codelisperer/ouranos.git
    cd ouranos
    sbcl --dynamic-space-size 4096 --script bootstrap.lisp   # → bin/cons

`bootstrap.lisp` points ASDF at the whole tree and writes a source-registry drop-in, so
every REPL can find the frameworks with no symlinking. From any SBCL REPL:

    (ql:quickload :mnemosyne)   ; first load compiles Coalton — minutes, then cached

`bin/cons build | test | serve | run` is the intended one-command interface (in
progress; today `cons` implements `init` / `setup` / `version`).
