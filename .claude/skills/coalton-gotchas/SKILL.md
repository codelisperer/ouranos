---
name: coalton-gotchas
description: >
  Hard-won Coalton pitfalls + fixes for the codelisperer stack (hyperion, praxeon,
  mnemosyne, aion, elenchon). Read BEFORE writing or debugging Coalton
  (`coalton-toplevel`) code: function-type declare syntax, reserved/shadowed names,
  case-insensitivity collisions, CL<->Coalton interop, and verify-script patterns.
  Triggers: a Coalton compile error, `define-type`/`declare`/`define`, calling
  Coalton from CL, or "Invalid argument in", "expected a keyword", "Unable to
  change the type", "Arity mismatch", "does not designate any package".
---

# Coalton gotchas (this stack)

Coalton = Hindley–Milner static types embedded in CL. First compile is slow
(minutes; cached) — always give SBCL a big heap: `--dynamic-space-size 4096`.
Package + file preamble:

```lisp
(cl:defpackage #:my/mod (:use #:coalton #:coalton-prelude) (:export ...))
;;; file:
(cl:in-package #:my/mod)
(named-readtables:in-readtable coalton:coalton)
(coalton-toplevel ...)
```

## 1. Function-type `declare` uses `*` between args, ONE `->` before the return

Multi-argument function types are `(a * b * c -> result)` — **NOT** curried
`(a -> b -> c -> result)`. Getting this wrong yields **"Arity mismatch … expected
type '…' takes 1"** (Coalton read `a -> rest` as a 1-arg function).

```lisp
;; WRONG:  (declare f (String -> (:c -> (Flow :c)) -> (Interceptor :c)))
;; RIGHT:
(declare f (String * (:c -> (Flow :c)) -> (Interceptor :c)))
;; stdlib: (declare compose ((:b -> :c) * (:a -> :b) -> (:a -> :c)))
```
A single-arg function type is just `(arg -> result)` (one arrow, no `*`).

## 2. Coalton is CASE-INSENSITIVE — a constructor `Foo` and function `foo` collide

The CL reader upcases, so `Interceptor` (constructor) and `interceptor` (function)
are the **same symbol** → **"Unable to change the type of name X from CONSTRUCTOR to
VALUE."** Don't name a helper the lowercase of a constructor. Constructors ARE
functions — call the constructor directly (`(Interceptor n e l)`), no helper needed.

## 3. Reserved operators & shadowed stdlib names

- **`continue`** is a reserved Coalton loop operator → a constructor named
  `Continue` gives **"Invalid argument in continue … expected a keyword."** Rename
  (e.g. `Proceed`).
- **`Fail`, `Tuple`, `Ok`, `Err`, `Some`, `None`, `map`, `<>`, `into`, …** are
  exported by the Coalton stdlib (`coalton/classes`, prelude). Defining your own
  `Fail` → **"The symbol FAIL is defined in the package COALTON/CLASSES and not the
  current package."** Rename (e.g. `Failure`). To check first, grep the stdlib:
  `grep -rE "#:<name>\b" ~/common-lisp/coalton/library/*.ct`. (You may *use* stdlib
  names like `Tuple`; you just can't *redefine* them.)

## 4. Types, ADTs, records

- `define-type` supports a docstring after the (possibly parameterized) name:
  `(define-type (Flow :c) "doc" (Proceed :c) (Halt :c) (Failure String :c))`.
- Type variables are keywords: `:a`, `:c`.
- A record is a one-constructor type; access fields via `match` or your own
  accessors: `(define (name i) (match i ((Interceptor n _ _) n)))`.
- **`match` on nullary constructors needs parens**: `((None) ...)`, `((Halt c) ...)`.
- Numbers→String via `into` (there are `(Into UFix String)` etc. instances):
  `(<> (the String (into n)) "ms")`. `<>` is String concatenation (Semigroup).

## 5. Calling Coalton from CL (the boundary)

- A `define`d Coalton function is a normal CL function: call it directly or
  `funcall` it with **CL scalars** — `(my/mod:render-millis 700)` works; args are CL
  fixnums/strings, results are CL values (`String`→string, `Boolean`→`T`/`NIL`,
  `UFix`→integer, `Integer`→integer).
- To evaluate a Coalton *expression* (e.g. build a value with literal constructors)
  from CL: `(coalton (my/mod:swap->string my/mod:InnerHTML))`.
- Constructing a Coalton value from a **runtime** CL value inside `(coalton …)`
  needs a `lisp` escape with proper `(-> Type)` syntax — usually easier to expose a
  Coalton wrapper `(UFix -> String)` and call it from CL with the scalar.

## 6. Verify scripts: defer Coalton symbol resolution

`load`-ing a script that both `ql:quickload`s the system AND references
`my/mod::sym` in the **same top-level form** fails at READ time with **"Package …
does not exist"** (the whole form is read before quickload runs). Fixes:
- put `quickload` in its **own** top-level form, then reference symbols in *later*
  forms; and/or
- resolve symbols at runtime: `(funcall (read-from-string "my/mod::sym") arg)`.

## 7. Editor note

Alive's LSP shows "The name X does not designate any package" for
`hyperion/*`/`praxeon/*` until the system is loaded into its image — noise, not a
real error. The committed `.vscode/settings.json` loads the system on LSP start.
