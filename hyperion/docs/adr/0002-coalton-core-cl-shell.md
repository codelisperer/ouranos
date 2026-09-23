# ADR-0002 — Typed core in Coalton, effectful shell in CL

**Status:** Accepted — 2026-07-16 (records a founding constraint)

## Context

Hyperion (and the sibling projects) want compile-time-checked domain logic without
giving up Common Lisp's dynamism, condition system, and REPL-driven development.
Coalton provides Hindley–Milner types and typeclasses over CL; it is not CLOS
underneath and does static dispatch, interoperating with CL at the boundary.

## Decision

**Pure, typed logic goes in Coalton (no IO); effects, dynamism, and runtime-open
extensibility go in CL/CLOS.** The two meet at a thin boundary.

- The typed HTMX vocabulary (`Swap`, `Verb`, `Trigger`, `Target`, `Duration`, …)
  is Coalton — a checked value that can't spell a bad combo (a real `Duration`
  makes `"700ms"` unspellable-wrong). Pure `->string` renderers only.
- Rendering, IO, the server, the dev loop, request handling — CL/CLOS + Spinneret.

## Consequences

- The CL↔Coalton boundary is a real interface to design deliberately. Verified
  facts we rely on: Coalton `define`d functions are directly callable from CL
  (with CL scalars for `UFix`, strings for `String`); Coalton's own macros are
  matched by symbol, so the CL side calls renderers, it does not re-implement them.
- First Coalton compile is minutes (cached after); the Makefile sizes the heap.
- Some interop ergonomics (constructing typed values from CL app code) are still
  rough; the first cut keeps the CL bridge thin (keyword→renderer) and grows.

## Alternatives considered

- **All-CLOS, no Coalton.** Rejected: loses compile-time checking of the vocabulary.
- **All-Coalton.** Rejected: IO/dynamism/condition-system/hot-reload live better in CL.
