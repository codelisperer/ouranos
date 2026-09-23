# Aion — User Guide

> **Pre-alpha (0.0.0)** — the API will change. But there *is* a library now: **758 checks
> across six subsystems.** What is still unwritten is the piece the name promises — the
> persistent-collections core and the `ISeq` protocol.

## What Aion is

Two things, and the second arrived first.

**The stated goal** — a Coalton-first functional standard library: immutable, persistent
collections and the idioms for them, with a typed Coalton layer and a pure-CL face
(`aion/cl`) for developers who never touch Coalton. The name (Αἰών, "the eternal") is that
thesis: values that never change. **This part is not built yet.**

**What is actually here** — aion turned out to be where the ecosystem's *boundaries* live:
the place an untyped external vocabulary becomes a typed value, decoded once at the edge
(see [`docs/coalton-story.md`](coalton-story.md)). Four opt-in subsystems, none of which
core `aion` depends on:

| System | What it is | Checks |
|---|---|---|
| `aion/csv` | RFC-4180 reader/writer. **Dependency-free** (`:depends-on ()`) — loads on bare SBCL/CCL/ECL/ABCL with no Coalton | — |
| `aion/csv/types` | A typed specification of the parser: `ParseState`, `CharClass`, a transition the compiler proves total, and a reference parser held to exact agreement with the CL one | 431 |
| `aion/log` | Structured logging over log4cl. `Level` with `Ord` (gating is `>=`), `Layout`, a typed `Event` | 62 |
| `aion/uv`, `aion/uv/net`, `aion/uv/process` | **libuv** — event loop, sync and async filesystem, timers, file watching, TCP, pipes, DNS, subprocesses, signals. No groveller, no cmake | 188 |

`aion/uv` needs a C compiler once (your OS's own) — `sbcl --script scripts/build-libuv.lisp`.
Nothing else in the tree does, and no C toolchain is ever needed merely to *load* anything.

## Install / run

Aion is one of six core frameworks (plus `hermes`, a satellite leaf-lib) in the
[Ouranos monorepo](../../README.md); you build
the whole tree, not this directory alone. Prereqs: **SBCL + Quicklisp** (Coalton
loads from Quicklisp on first use).

```sh
git clone https://github.com/codelisperer/ouranos
cd ouranos
sbcl --dynamic-space-size 4096 --script bootstrap.lisp   # → bin/cons
```

`bootstrap.lisp` points ASDF at the whole tree and writes a source-registry
drop-in, so every REPL can find the frameworks with no symlinking. From any SBCL
REPL:

```lisp
(ql:quickload :aion)
(aion:version)            ;; => "0.0.0"
```

First load compiles Coalton (a minute-ish; cached afterward). If you hit
`Heap exhausted`, you started SBCL without the larger heap — pass
`--dynamic-space-size 4096`.

## What you'll be able to do (planned)

Once Thread 1 lands, the intended shape (subject to the vision Q&A) is a single,
consistent protocol over persistent collections — no more `elt` vs `nth` vs `aref`:

```lisp
;; illustrative — not yet implemented
(-> (aion:vec 1 2 3)          ; persistent vector, structural sharing
    (aion:conj 4)             ; -> [1 2 3 4], original unchanged
    (aion:map #'1+)           ; -> [2 3 4 5]
    (aion:into '(:list)))     ; uniform `into` across collection types
```

See `docs/roadmap.md` for the thread order and `docs/aion-vision.md` for the open
design questions (protocol shape, how much Coalton the CL face exposes, set
equality, etc.).

## See also
- `docs/coalton-gap-analysis.md` — what Coalton already gives you vs the gaps.
- `docs/roadmap.md` · `docs/aion-vision.md` · `docs/editor-setup.md` · `CLAUDE.md`.
