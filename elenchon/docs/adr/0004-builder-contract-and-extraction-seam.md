# ADR-0004 — The builder contract is a validating one, and the extraction seam is data, not a protocol

**Status:** Provisional — 2026-07-29
**Resolves:** [`elenchon-vision.md`](../elenchon-vision.md) Q4, Q5, Q6, Q8

## Context

Four related questions about Elenchon's edges.

**The builder contract (Q4).** Must a caller hand the CEG-building API fully-formed
causes, effects, and constraints — or may it pass partial input and be told what is
missing? Should the API validate propositions and surface a rejection as a *defect*? The
recorded lean was a validating builder returning structured "what is still ambiguous."

**The extraction seam (Q8).** Does Elenchon expose a neutral extraction protocol — a
generic function the agentic layer implements, in the house pluggable-backend style — or
stay strictly at the CEG-building API and let the consumer own the whole NL step? The
recorded lean was a thin protocol seam Elenchon defines and praxeon implements.

**Input formats (Q5)** and **output formats (Q6)** hang off the same boundary.

The lean on Q4 is right and is adopted. The lean on Q8 is not, and the reason is worth
recording: **a generic function that Elenchon defines but never calls is not a protocol.**
A protocol earns its name when the defining side *dispatches* on it — that is what makes
backends interchangeable in `mnemosyne`'s backend protocol or `hermes`'s `deliver`.
Elenchon never invokes extraction; extraction happens strictly above it and hands down a
result. Defining a generic function for it would produce a vestigial hook that exists
only to be documented, and one nobody is obliged to implement.

The real contract is already there and is stronger: **the types.** What crosses the
boundary is a `Draft` going in and an `Outcome` coming back. That is the seam. It is
data, which means it is inspectable, serializable, diffable, and equally usable by an
agent, a web form, or a unit test — the exact property the scope boundary exists to
protect. Elenchon documents a data contract without depending rightward and without
inventing machinery.

## Decision

**1. The builder is validating, accepts partial input, and reports every finding.**

```lisp
(define-type Outcome
  "The result of attempting to build a CEG from a Draft."
  (Built Ceg (List Finding))   ; well-formed; advisory findings may still be present
  (Blocked (List Finding)))    ; not well-formed -- EVERY blocking reason, not the first
```

Reporting *every* reason is load-bearing: the caller above is typically an agent
iterating toward a well-formed graph, and one-finding-at-a-time turns a single round trip
into many. Failing with a complete list is the same posture the stack takes everywhere —
recoverable, structured, reported rather than guessed around.

**2. `Finding` is one vocabulary, shared by the builder and the report.** The defects
that graphing surfaces are the same objects whether they appear at build time or at
analysis time, so there is one type, not two:

| Finding | Severity | Meaning |
|---|---|---|
| `DuplicateId` | blocking | an identifier used twice |
| `DanglingRef` | blocking | a `Ref` to an undefined node |
| `CyclicNode` | blocking | a node-reference cycle (newly expressible under ADR-0001) |
| `UncausedEffect` | blocking | an effect with no expression driving it |
| `DanglingCause` | advisory | a cause with no path to any effect |
| `UnreachableNode` | advisory | a node defined but referenced by nothing |
| `UnsatisfiableEffect` | advisory | an effect that can never be true under the constraints |
| `TautologicalEffect` | advisory | an effect true regardless of any cause |
| `ContradictoryConstraints` | advisory | no feasible assignment satisfies `E`/`I`/`O`/`R` |
| `NonPropositional` | advisory | a cause or effect the caller could not reduce to yes/no |
| `UntracedItem` | advisory | a cause or effect with no `ReqId` |

Advisory findings **do not block** a build — an incomplete requirement should still yield
whatever tests are derivable, alongside a clear statement of what is wrong with it.
That is the ADR-0005 positioning made operational.

**3. Elenchon does not validate propositions; it validates *structure*, and records the
caller's judgment.** Deciding whether "the response must be fast" is a genuine yes/no
proposition requires understanding the sentence — that is the agentic layer's job, above
the boundary, by construction. The `Draft` therefore lets a caller *mark* an item
non-propositional, and Elenchon carries that through as a `NonPropositional` finding. The
boundary stays honest: Elenchon never reads prose, and never pretends to.

**4. The extraction seam is the `Draft`/`Outcome` data contract — no generic function.**
Elenchon publishes the types and their meaning; praxeon/ChatRBT produces `Draft` values
and consumes `Outcome`s. Nothing is dispatched, nothing is registered, and the dependency
direction is respected without ceremony.

**5. Input (Q5): the traceability anchor is `requirement = ID + text`.** Every cause and
effect carries an `(Optional ReqId)` back to the requirement it came from — already in
[`../../src/ceg.lisp`](../../src/ceg.lisp). Richer source formats (user stories, Gherkin,
a requirements document) are the *consumer's* parsing problem; they all reduce to a
`ReqId` plus text at this boundary. Elenchon targets no document format, ever.

**6. Output (Q6): the `DecisionTable` value is canonical; renderers are separate and
pure.** `elenchon/cases` holds them, and v1 ships two: a human-readable table and a
machine-readable s-expression (with JSON as a thin CL-shell wrapper over it). Every
rendered case carries its traceability metadata — the originating `ReqId`, the causes it
fixes, the effects it asserts, and the criterion it was generated under (ADR-0003).

**Executable test stubs are deferred, and when they come they are generic
given/when/then, not fiveam.** Elenchon tests *requirements*; the system under test is
usually not Common Lisp. A CL-specific emitter first would be optimizing for the rarest
case.

## Consequences

- The boundary is fully described by two Coalton types, which is exactly the artifact an
  agent above needs — and the thing to hand an LLM as the contract.
- One `Finding` type serves the builder, the report, and the agent conversation, so the
  defect vocabulary cannot drift between them.
- The builder must implement cycle detection over `Ref` (the obligation ADR-0001 created).
- Advisory-versus-blocking is a property of the finding, not of the caller, so a future
  strict mode is a filter over findings rather than a second code path.
- `Draft` is not yet specified in code — it is the next type to write after `Finding`,
  and it should be shaped by ChatRBT's actual needs, so the praxeon lane should review it
  before it hardens.

## Alternatives considered

- **Strict builder: fully-formed input or an error.** Simpler, and wrong for the primary
  caller. An agent's whole loop is iterating toward well-formedness; a builder that only
  says "no" makes Elenchon useless until the graph is already correct — precisely when it
  has least to offer.
- **A generic-function extraction protocol (the recorded lean).** Rejected above: nothing
  on Elenchon's side would dispatch on it. If a future feature genuinely requires Elenchon
  to *call* upward (it should not — that is the DAG), this decision gets revisited by a
  new ADR.
- **Two finding types, one for build errors and one for the report.** Rejected: the same
  defect would need two names, and the report is the product (ADR-0005) — it should not
  be assembled from two vocabularies.
- **Elenchon validating propositions itself** (heuristics, a word list, a grammar).
  Rejected: it is natural-language work, the boundary forbids it, and heuristics would be
  wrong in exactly the ambiguous cases that matter most.
