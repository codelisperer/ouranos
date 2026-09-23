# Aion

*Αἰών — "the eternal."* **A Coalton-first functional standard library for Common
Lisp.** The name is the thesis: values that never change. Aion is about
**immutable, persistent data** and the functional vocabulary for working with it.

One of six co-evolving core frameworks in the [Ouranos monorepo](../README.md), plus
[`hermes`](../hermes), a satellite leaf-lib — see
the [root README](../README.md) and [ECOSYSTEM.md](../ECOSYSTEM.md) for the thesis,
the dependency DAG, and how the pieces fit. In dependency order (lowest → highest):
[`aion`](../aion) (this — the functional core the others lean on) →
[`cons`](../cons) (project & dev tooling, "cargo for Lisp") →
[`mnemosyne`](../mnemosyne) (bitemporal data layer) →
[`elenchon`](../elenchon) (CEG engine + reasoning system for RBT) →
[`hyperion`](../hyperion) (HTMX-first web framework) →
[`praxeon`](../praxeon) (agentic AI).
Off the linear DAG: [`hermes`](../hermes) (external integrations — email/SMS, later
payments) depends only on `aion`; nothing in the core DAG depends on it.

## Thesis

The goal is to make **Coalton a first-class "modern Lisp"** — a peer to Clojure,
Scheme, OCaml, and Haskell — by giving it the functional-programming library the
ecosystem expects: persistent collections, a *consistent* sequence protocol
(Common Lisp's `sequence` is famously kludgy and inconsistent), and the
Clojure-goodness (transducers, optics, lazy sequences, threading) that make
immutable data a pleasure to work with.

**The pleasant surprise** (see [`docs/coalton-gap-analysis.md`](docs/coalton-gap-analysis.md)):
Coalton's stdlib is *already* remarkably complete — it ships persistent RRB-tree
vectors (`Seq`), HAMT maps (`hashmap`), ordered maps, immutable lists, a lazy
`Iterator`, and a full typeclass tower (`Functor`/`Applicative`/`Monad`,
`Foldable`, `Traversable`) *with monad transformers*. So Aion is **less
"reimplement Clojure" and more:**

1. **A pure-CL face.** Expose Coalton's persistent collections — and a consistent,
   generic `ISeq`-style protocol — to Common Lisp users who don't write Coalton,
   finally fixing CL's inconsistent sequence story.
2. **The genuine gaps.** The handful of things Coalton doesn't yet have: persistent
   **Sets**, **transducers**, **optics/lenses**, memoized **lazy-seq**, `Monoid`,
   itertools-grade combinators, and threading sugar (`-> ->> some-> cond->`).

Net: prove Coalton is already peer-level, give it a clean CL face, and add the
missing idioms — a stronger, more defensible pitch than starting from scratch.

## Architecture (the common core)

- **Typed core in Coalton; effectful/dynamic shell in CL.** Ontology and pure logic
  are Coalton (HM types); the pure-CL face and any effects are CL/CLOS.
- **Pluggable backends behind neutral protocols** — the house style across the five
  projects.

## Status

**Pre-alpha (0.0.0) — vision scaffold.** See `docs/roadmap.md`,
`docs/coalton-gap-analysis.md`, and the open questions in `docs/aion-vision.md`.

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

    (ql:quickload :aion)   ; first load compiles Coalton — minutes, then cached

`bin/cons build | test | serve | run` is the intended one-command interface (in
progress; today `cons` implements `init` / `setup` / `conform` / `env` / `db-repl` / `db-url` / `template check` / `version`).
