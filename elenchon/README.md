# Elenchon

*ἔλεγχος — "cross-examination, refutation."* **The Cause-Effect Graph engine +
reasoning system for Requirements-Based Testing**, in the lineage of Bender RBT.
Given a *structured* Cause-Effect Graph (causes, effects, and the E/I/O/R/M
constraints), Elenchon **reasons** over it — a relational solver, with miniKanren a
leading candidate — to generate the *minimum* set of functional test cases covering
the *maximum* share of the requirement logic, plus a requirement-defect report.

The name is the method: Socratic *elenchos* interrogates a claim until its
ambiguities and contradictions surface — and what survives is sound. Elenchon does
that to requirements.

> **Scope.** Elenchon does CEG *crunching and reasoning* — **not** natural-language
> translation. Turning human prose into a CEG (and driving Elenchon to build CEGs
> from human input) is an **agentic function that lives above Elenchon**, in praxeon
> (see its **ChatRBT** example). Elenchon takes structured input and can be driven by
> an agent, a form, or a test. Per the ecosystem dependency order
> (`aion → cons → mnemosyne → elenchon → hyperion → praxeon`), it depends only
> leftward and **never on praxeon/hyperion**.

One of six sibling core frameworks (in dependency order, lowest → highest); plus
[`hermes`](../hermes), a satellite leaf-lib off the DAG (external integrations:
neutral email + SMS, payments later; depends only on `aion`):

| Project | Role |
|---|---|
| [`aion`](../aion) | Coalton-first functional standard library |
| [`cons`](../cons) | CL dev tooling / project manager ("cargo for Lisp") |
| [`mnemosyne`](../mnemosyne) | data / persistence (Postgres-wire; PG or XTDB 2) |
| **`elenchon`** | this — the CEG engine + reasoning system for RBT |
| [`hyperion`](../hyperion) | full-stack, HTMX-first web framework |
| [`praxeon`](../praxeon) | praxeological framework for agentic AI |

## Thesis

Most defects are born in the **requirements**, not the code. The highest-leverage
testing artifact is therefore a *formalized* requirement — a Cause-Effect Graph —
from which a provably-minimal, provably-sufficient set of functional tests can be
derived. Elenchon is the **rigorous engine** for that: a typed CEG plus a reasoning
system that crunches it into minimal, sufficient tests. The hard *human* part —
turning vague prose into precise causes and effects — is handled by an **agentic
layer above** Elenchon (praxeon/ChatRBT), which feeds it a structured CEG. Engine
below, AI above: each does what it's best at.

## What Elenchon does (see [`docs/method.md`](docs/method.md))

Given a **structured** CEG (the agentic layer, or a form/test, supplies it):

1. **Build** the typed Cause-Effect Graph from structured causes/effects +
   `E`/`I`/`O`/`R`/`M` constraints *(Coalton ADT)*.
2. **Reason** — CEG → the minimal decision table whose columns show each cause
   *independently* drives its effect (≈ **MC/DC** coverage) *(the reasoning system;
   miniKanren a leading candidate)*.
3. **Render** — decision table → functional test cases, each traceable to the
   requirement.
4. **Report** — the requirement defects graphing surfaces for free (dangling
   causes/effects, contradictory constraints, non-propositional requirements).

*(Step 0 — NL → structured causes/effects — is the agentic consumer's job, above
Elenchon.)*

## Architecture (the common core)

- **Typed core in Coalton** — the CEG and the reasoning system are pure logic over
  an ADT. No IO in the core.
- **Pluggable reasoning behind a neutral protocol** — miniKanren / Bender table-walk
  / SAT-SMT are interchangeable; the house style.
- **Depends only leftward** — `aion` (collections) now, `mnemosyne` later (persist
  CEGs/projects). **Never praxeon/hyperion** — Elenchon is a framework the agentic
  layer *consumes*, not the reverse.

## Status

**Pre-alpha (0.0.0) — vision scaffold.** The system loads and exposes
`elenchon:version` plus the **typed CEG ADT** (`src/ceg.lisp`, 46 checks); the reasoning
system is not built. See `docs/adr/` (five settled decisions) and `docs/method.md` (the design
brief), `docs/roadmap.md`, and the open questions in `docs/elenchon-vision.md`.

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

    (ql:quickload :elenchon)   ; first load compiles Coalton — minutes, then cached

`bin/cons build | test | serve | run` is the intended one-command interface (in
progress; today `cons` implements `init` / `setup` / `version`).
