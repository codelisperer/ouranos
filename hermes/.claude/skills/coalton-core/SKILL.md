---
name: coalton-core
description: Write a typed Coalton core plus its effectful CL shell for a codelisperer module, avoiding the compile-time gotchas.
---

# Writing a Coalton typed core + CL shell

Use this when adding pure, typed logic to a codelisperer framework (aion, mnemosyne,
hyperion, ...). The pattern: types and pure logic in Coalton; IO, effects, and dynamism in a
sibling CL package.

## Steps

1. Put the types + pure functions in a Coalton package (`(:use #:coalton #:coalton-prelude)`),
   with `(named-readtables:in-readtable coalton:coalton)` and a `(coalton-toplevel ...)`.
2. Declare function types **uncurried with `*`**: `(declare f (A * B -> C))`.
3. Prefer **ADTs over booleans**; `match` on a nullary constructor needs parens `((None) ...)`.
4. At the boundary, expose **CL-facing constructors** and **total accessors** so the CL shell
   builds and reads values with plain CL scalars (Coalton `define`d functions are callable
   from CL).
5. Keep **all IO in the CL shell** — connect / exec / render / print live outside Coalton.

## Gotchas (it will not compile otherwise)

- `(A B -> C)` reads as a type application (Kind mismatch). Use `(A * B -> C)`.
- Coalton is case-insensitive: constructor `Foo` clashes with function `foo`.
- Do not shadow: continue, Fail, Some, None, Ok, Err, Tuple, map, into.
- `cond` ends with `(True expr)`; booleans are `True` / `False`.

## Verify

`(ql:quickload :YOUR-SYSTEM)` compiles clean; add a fiveam test and run `(asdf:test-system ...)`.
