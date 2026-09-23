# ADR-0001 — CEG representation: an expression DAG, with the node diagram derived

**Status:** Provisional — 2026-07-29
**Resolves:** [`elenchon-vision.md`](../elenchon-vision.md) Q1

## Context

The Cause-Effect Graph can be modelled two ways. As an explicit **node graph** —
cause nodes, effect nodes, intermediate boolean nodes, typed edges — which matches the
diagrams in Myers and the Bender literature and carries traceability naturally. Or as a
**boolean expression tree per effect** (`E1 = (AND C1 (NOT C2))`), with the constraints
in a side table — simpler to type, simpler to solve.

The recorded lean was the expression tree with a node view derived from it. Working the
type out exposed a defect in the pure-tree form: **real CEGs share subexpressions.** A
condition like "overdue AND not exempt" typically drives several effects. A tree per
effect duplicates that subexpression, which costs three things that matter here:

1. **Traceability breaks.** The literature (and any reviewer) refers to "node N1." If
   the same condition exists as two unrelated subtrees, there is no N1 to point at, and
   the defect report cannot say "N1 is unreachable" — it must say it twice, about two
   structurally-identical-but-distinct trees.
2. **The solver re-derives shared work** once per effect.
3. **The derived diagram is wrong**, or at least not the diagram people expect: it
   renders duplicated logic as independent nodes.

Hash-consing the tree would recover sharing implicitly, but implicit sharing is not
addressable — and addressability is the point.

## Decision

**The CEG core is an expression DAG: one rooted boolean expression per effect, with
sharing made explicit by a `Ref` to a named intermediate node.**

```lisp
(define-type Expr
  (Lit CauseId)          ; a cause
  (Ref NodeId)           ; a named intermediate node, resolved via the CEG's node table
  (Neg Expr)             ; NOT
  (Conj (List Expr))     ; AND, n-ary
  (Disj (List Expr)))    ; OR,  n-ary
```

Named nodes live in a table on the `Ceg`; each `Effect` holds its own root `Expr`.
Constraints (`E`/`I`/`O`/`R`/`M`) stay in a side list, as planned — they constrain
*across* expressions and do not belong inside any one of them.

Supporting decisions taken with it:

- **`Conj`/`Disj` are n-ary**, not binary. The literature's AND/OR nodes are n-ary; a
  binary encoding forces an arbitrary associativity that then shows up in the derived
  diagram. Empty `Conj` is vacuously true, empty `Disj` vacuously false.
- **Constructors are `Conj`/`Disj`/`Neg`, never `And`/`Or`/`Not`.** Coalton's prelude
  owns those names and Coalton is case-insensitive.
- **Identifiers are distinct newtypes** (`CauseId`, `EffectId`, `NodeId`, `ReqId`), not
  bare `String`. Passing an `EffectId` where a `CauseId` belongs is exactly the wiring
  bug a typed core exists to reject; it costs one wrapper to make it uncompilable.
- **Evaluation is total and returns `(Optional Boolean)`.** `None` means "the graph does
  not determine this" — an unassigned cause, or a dangling `Ref`. Those are precisely
  the requirement defects the report exists to surface (ADR-0004), so they are
  *represented*, never defaulted to false. This is the ADT-over-booleans rule doing real
  work: the difference between "false" and "underdetermined" is the product.
- **The node diagram is a derived view**, computed from the DAG for rendering and
  traceability. It is not the stored form.

Implemented and compile-verified in [`../../src/ceg.lisp`](../../src/ceg.lisp).

## Consequences

- The solver and the renderers bind to one representation, and sharing is visible to
  both. A shared condition is evaluated once and named once.
- The defect report gains two findings for free that the tree form could not express:
  **dangling `Ref`** (a node referenced but not defined) and **unreachable node** (a
  node defined but referenced by nothing).
- Cycles are now *possible* to express (`N1` referencing `N2` referencing `N1`) where a
  tree made them unrepresentable. The builder must reject them — this is a new
  validation obligation, tracked as part of ADR-0004's builder. It is a fair trade:
  cycle detection is a dozen lines; losing shared-node identity is structural.
- CL callers cannot construct `List`-shaped Coalton values ergonomically, so
  `elenchon/build` will need CL-facing constructors per the house boundary rule
  (`docs/coalton-patterns.md` §5). Noted, not yet built.

## Alternatives considered

- **Explicit node/edge graph.** Matches the diagrams exactly, but the solver then walks
  edges instead of structure, and every traversal has to reconstruct "the expression
  driving E1" that the DAG simply holds. Rejected: the derived view gets the diagram
  back at a fraction of the cost.
- **Pure expression tree, hash-consed.** Recovers sharing without a `Ref` constructor,
  but the shared node has no *name*, so neither the report nor the diagram can refer to
  it. Rejected for the reason above.
- **CNF / a normalized form as the stored representation.** Good for a SAT backend,
  terrible for traceability and for showing a human the requirement they wrote.
  Normalization belongs *inside* a solver backend, not in the core type.
