---
name: coalton-conventions
description: Conventions for the Coalton typed core of Praxeon — when to use Coalton vs plain CL, ADTs and pattern matching, declares, and keeping IO out of the core. Use when editing src/praxeology.lisp, adding types to the ontology, or deciding whether logic belongs in Coalton or the CL shell.
---

# Coalton conventions for Praxeon

## The boundary

- **Coalton (typed core):** the ontology and pure logic — what agents *are*
  (`End`, `Means`, `Action`, `Plan`, `Actor`) and total, side-effect-free
  functions over them.
- **Common Lisp (dynamic shell):** effects, IO, the condition system, the LLM
  provider, mutable context, the agent loop.

Never perform IO inside `coalton-toplevel`. If a function needs the network, a
clock, randomness, or mutation, it belongs in the CL shell.

## Style

- Prefer `define-type` ADTs plus `match` for destructuring over `define-struct`
  accessors — the pattern-matching surface is the most stable and the intent is
  clearer.
- Give every exported function a `declare` with its type signature.
- Keep constructors small; add helper accessors (e.g. `end-description`) rather
  than reaching into shapes at call sites.
- Introduce a type class (e.g. `Valued`) when you need dispatch over a capability
  (imputing value to ends/plans); put instances downstream, near their types.

## Working style

Development is REPL-driven. Load `src/praxeology.lisp`, and when the type checker
rejects a change, treat the error as design feedback — it is telling you the core
is inconsistent. Fix the types, don't cast around them.

## Interop

To use a Coalton value from CL, call the generated function symbols in the
`praxeon/praxeology` package. Keep effectful "means" implementations in the CL
`register-means` registry; the Coalton `Means` is only a description.
