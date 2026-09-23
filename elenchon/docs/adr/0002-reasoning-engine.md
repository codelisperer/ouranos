# ADR-0002 — Reasoning engine: native pair-generation + set cover first, behind a `Solver` protocol

**Status:** Provisional — 2026-07-29
**Resolves:** [`elenchon-vision.md`](../elenchon-vision.md) Q2

## Context

The marquee technical fork. Three candidates were on the table, behind one neutral
protocol: **(a)** relational/miniKanren, **(b)** the classic Bender/Myers table-walk in
Coalton, **(c)** SAT/SMT via FFI. The recorded lean was **(a) first** — the most
Lisp-native option, and the one that makes the "reasoning system" framing true rather
than aspirational.

Working the problem out changes the recommendation, because the problem is **two
problems, and the interesting one is not a search problem.**

Generating an MC/DC-equivalent decision table decomposes into:

1. **Independence-pair generation.** For each (cause `c`, effect `e`) pair, find two
   assignments identical on every cause but `c`, both *feasible* under the `E`/`I`/`O`/`R`
   constraints, whose values for `e` differ. This is constraint satisfaction — the part
   miniKanren and SAT are genuinely good at.
2. **Minimization.** Choose the fewest distinct assignments (decision-table columns)
   that realize *every* required independence pair. Pairs share columns heavily; this is
   a **set-cover** problem, NP-hard in general.

**Neither miniKanren nor a plain SAT solver solves (2).** They enumerate models for (1);
the cover is still yours to compute, and it is where the "minimum tests" claim is
actually won or lost. Adopting a relational engine buys a stream of satisfying
assignments and leaves the load-bearing half untouched — while adding a dependency the
monorepo's minimal-dependency stance treats as a real price.

Scale is also smaller than the instinct to reach for a solver suggests. RBT operates on
one requirement at a time; requirements run roughly 5–25 causes. Pair generation never
enumerates the full assignment space — for each cause it fixes the flip and searches for
a consistent completion, a small problem — and even exhaustive enumeration is tractable
at the low end of that range in a compiled core.

One further property decides it. Elenchon's output is meant to be **evidence**: a
minimal suite plus a claim about what it covers. A suite that differs run to run because
the solver's search order differed is a much weaker artifact than one that is
bit-identical every time. Native code with a fixed traversal order gives determinism by
construction; a general solver gives it only by accident or by pinning a version.

## Decision

**v1 is a native Coalton reasoning core: deterministic independence-pair generation,
then set cover — behind a `Solver` protocol that keeps (a) and (c) pluggable.**

- **Pair generation** — for each (cause, effect) required by the active coverage target
  (ADR-0003), search for a feasible independence pair. Feasibility is
  `elenchon/ceg:feasible?` (the `E`/`I`/`O`/`R` check, already implemented); effect
  values come from `eval-effects`, masking included. Deterministic traversal order.
- **Minimization** — greedy set cover over the generated columns, with an **exact**
  (branch-and-bound) pass for instances small enough to afford it. Greedy is standard
  practice for MC/DC suite reduction and is within a `ln n` factor; exact is affordable
  at the sizes that actually occur, and being able to say "this is *the* minimum, not a
  good one" is worth real effort for the pitch.
- **The seam** is a Coalton class parametric over the backend, so the two halves stay
  separable and a future backend can replace either:

  ```lisp
  (define-class (Solver :s)
    (independence-pairs (:s * Ceg * Coverage -> (Result SolveError (List Pair))))
    (minimize           (:s * (List Pair) -> (Result SolveError DecisionTable))))
  ```

  v1 ships one instance (`Native`). Per `docs/coalton-patterns.md` §5 a
  class-constrained function is not directly callable from CL, so `elenchon/reason`
  exports a monomorphic `solve-native` wrapper for the CL shell.
- **(a) miniKanren stays a live prototype for `independence-pairs` only** — the half it
  is actually suited to. It is worth building precisely to *measure* against native
  search rather than to assume.
- **(c) SAT/SMT remains the documented escape hatch** for scale, and would arrive as a
  `Solver` instance implementing `independence-pairs` (and, with cardinality
  constraints, potentially `minimize` too).

## Consequences

- No new dependency for v1, and a deterministic, reproducible suite — which the
  evidence story (ADR-0005) depends on.
- The `Solver` class must be defined *before* the native implementation is written, or
  it will be shaped around it. Write the class first even with one instance.
- The "reasoning system, not a table generator" framing is preserved and arguably
  strengthened: the reasoning that distinguishes Elenchon is the **minimality argument**
  over independence pairs, not the search technology underneath.
- **What would reverse this:** a benchmark where native pair generation blows up on a
  realistic requirement (say >30 causes with dense `R` chains). That benchmark is
  therefore the first thing the reasoning work should produce, before the solver is
  optimized. If it blows up, (c) is the answer, not (a).

## Alternatives considered

- **miniKanren first (the recorded lean).** Rejected as the *starting* engine for the
  reasons above: it addresses the half of the problem that is not the hard half, adds a
  dependency, and sacrifices determinism. Retained as a prototype backend for pair
  generation — the framing instinct behind the lean is right, it just attaches to the
  wrong half.
- **SAT/SMT first.** Best asymptotics, worst fit for a v1 whose instances are small and
  whose output must be reproducible and explainable. An FFI dependency also cuts against
  "CL all the way down" for no present benefit.
- **Classic Bender/Myers table-walk verbatim.** This is close to what is being adopted,
  and the literature's algorithm informs pair generation directly. It is not adopted
  *verbatim* because the published walk predates explicit MC/DC framing and does not
  separate generation from minimization — the separation is what makes the backend seam
  possible at all.
