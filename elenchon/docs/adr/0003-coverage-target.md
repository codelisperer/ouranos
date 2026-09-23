# ADR-0003 — Coverage target: configurable, MC/DC-equivalent by default

**Status:** Provisional — 2026-07-29
**Resolves:** [`elenchon-vision.md`](../elenchon-vision.md) Q3

## Context

Elenchon's default target is "each cause independently drives its effect" — flip one
cause, hold the rest, show the effect changes. That is essentially **MC/DC** (Modified
Condition/Decision Coverage), the criterion DO-178C requires for safety-critical
avionics.

The open question was whether to make it selectable, so users trade test count against
rigor explicitly rather than having one opinion imposed.

The argument for a single fixed target is that a configurable criterion invites people
to dial down to something weak and still claim "Elenchon-covered." The argument against
is that the criterion is *already* the whole value proposition, and stating it precisely
is the pitch — which only works if the alternatives are nameable and the trade-off is
visible. A tool that silently imposes one criterion is not more rigorous than one that
names three and defaults to the strong one; it is just less legible.

There is also a practical driver. The independence-pair set (ADR-0002) is exactly what
varies between criteria; making the criterion a parameter of pair generation is
*cheaper* than hard-coding one, because the generator needs to know which pairs are
required either way.

## Decision

**The coverage target is an ADT parameter to the reasoning system, defaulting to
`Independence` (MC/DC-equivalent).**

```lisp
(define-type Coverage
  "What the generated decision table is required to demonstrate."
  Decision          ; each effect observed both true and false
  Independence      ; each cause shown to independently drive each effect it can (≈ MC/DC)
  MultipleCondition) ; every feasible cause combination
```

- **`Independence` is the default** everywhere a default is taken — the API, the CL
  face, the CLI, the demo.
- **Every emitted artifact states the criterion it was generated under**, alongside the
  column count. A decision table without its criterion is not evidence, and the
  coverage claim is the product (ADR-0005).
- **`MultipleCondition` is bounded and refuses rather than hangs.** It is exponential in
  the cause count; past a configured ceiling the reasoning system returns a structured
  `SolveError` naming the size, instead of running until the heap dies. Refusing legibly
  is the house posture toward failure.
- The criterion is a parameter of **pair generation**, not a post-filter over a
  fixed-size table.

## Consequences

- Test-count-versus-rigor becomes an explicit, documented choice, and a comparison table
  across the three criteria on the same requirement is an obvious and compelling demo
  artifact.
- The reasoning system gains one enum parameter and no structural complexity, since pair
  generation is parameterized either way.
- `Decision` coverage is cheap and makes a good smoke test for the whole pipeline before
  `Independence` is correct.
- Not adopted: per-effect or per-cause criteria (different rigor within one CEG). Real
  demand for that is unproven and it complicates the coverage claim, which must stay a
  single legible sentence.

## Alternatives considered

- **Fixed at MC/DC-equivalent, no knob.** Simplest and safest against misuse, but hides
  the trade-off that makes the pitch land, and saves nothing given ADR-0002's structure.
- **Fixed at MC/DC plus an escape hatch to raw enumeration.** Effectively the chosen
  design with worse naming; making all three first-class costs nothing more.
- **Coverage as a numeric percentage target.** Rejected outright. Percentages are what
  make weak suites look impressive and prove little — naming the criterion is the entire
  point of the method.
