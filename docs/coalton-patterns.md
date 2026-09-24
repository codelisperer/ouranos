# Coalton patterns & gotchas (Ouranos)

Hard-won, easy-to-re-hit rules for writing **Coalton** in this monorepo. Coalton is a typed,
ML-flavoured language *embedded in* Common Lisp; several of its surprises come from that
embedding (case-insensitive symbols, the CL reader, the CL↔Coalton boundary). This is the
**canonical** reference; the AI-conformance pack (`cons conform` → `AGENTS.md`) ships a
condensed digest of it. When you learn a new pattern, add it here first, then update the
digest.

Convention below: **✗** wrong, **✓** right.

---

## 1. Type signatures & `declare`

**Multi-argument function types are uncurried, separated by `*`.** This is the single most
common trip-up. A space-separated list reads as a *type application*; a curried `->` chain
reads as a *one-argument* function.

```lisp
;; ✗ (String UFix -> Backend)      → "Kind mismatch": String is applied to UFix
;; ✗ (String -> UFix -> Backend)   → a 1-arg function (curried); a 2-param define won't match
;; ✓ (String * UFix -> Backend)    → a 2-argument function
(declare make-postgres (String * UFix * String * String * String -> Backend))
(define (make-postgres host port database user password) ...)   ; params match the * arity
```

Symptoms if you get it wrong:
- **Kind mismatch** (`Expected kind '* → *' but got kind '*'`) → you wrote `(A B -> C)`; use `(A * B -> C)`.
- **Arity mismatch** (`definition has N positional parameters but expected type … takes 1`) →
  you wrote a curried `(A -> B -> C)`; use `(A * B -> C)`.

**Constrained signatures** put the class constraint first with `=>`, then the `*`-args:

```lisp
(declare touch ((DTO :a) => Stamp * String * :a -> :a))
(define (touch stamp who entity) ...)
```

A single-argument function uses a bare `->` (nothing to separate): `(declare f (Backend -> String))`.

**A *zero*-argument definition is a VALUE, not a `Unit ->` function.** `(Unit -> :a)` is a
one-parameter type and a `(define (f) ...)` will not match it:

```lisp
;; ✗ (declare f (Unit -> (Optional Boolean)))   with (define (f) ...)
;;   → "Function definition has 0 positional parameters but expected type takes 1"
(declare f (Optional Boolean))       ; ✓ a value
(define f (compute ...))
;; -- or keep it a function and take the Unit explicitly: (define (f _) ...)
```

Reach for the explicit-`Unit` form only when you actually need to defer evaluation;
otherwise a plain value is what you meant.

## 2. Classes & instances

**`define-class` method signatures follow the SAME `*` rule** — a multi-arg method needs `*`,
not curried `->` (learned the hard way on `with-meta`):

```lisp
(define-class (DTO :a)
  (get-meta  (:a -> (Optional Meta)))   ; 1 arg → bare ->
  (with-meta (:a * Meta -> :a)))        ; 2 args → * (NOT :a -> Meta -> :a)
```

Calling a method uses ordinary positional application: `(with-meta entity meta)`.

## 3. Pattern matching

**Matching a nullary constructor needs parentheses** — `None`, `True`, a custom `Up`:

```lisp
(match x
  ((Some v) ...)     ; constructor with a field
  ((None) ...))      ; ✓ nullary needs parens — (None ...) would be read as a binding
```

`cond` clauses end with a `(True expr)` catch-all; the boolean literals are `True` / `False`
(not `t`/`nil`):

```lisp
(cond ((== name "string") FT-String)
      (True FT-String))              ; the else branch
```

## 4. Naming & case

- **Coalton is case-insensitive.** A constructor `Foo` and a function `foo` are the *same
  symbol* and collide. Keep constructor names distinct from function names.
- **Reserved / prelude names — do not shadow:** `continue`, `Fail`, `Some`, `None`, `Ok`,
  `Err`, `Tuple`, `map`, `into`, `unwrap`, and friends. Redefining these fails obscurely.
- **`and` / `or` / `not` are the prelude's**, so boolean *constructors* need other names.
  `elenchon/ceg` uses `Conj` / `Disj` / `Neg` for exactly this reason — and note that
  case-insensitivity means `And` is no escape from `and`.
- **`join` is one of them too**, and it is not obvious: it is `Monad`'s, from
  `coalton/classes`, so a string-joining helper called `join` fails with *"Invalid identifier
  name … defined in the package COALTON/CLASSES and not the current package"* (#114). The
  list above is not exhaustive — when a plain-sounding name is rejected, that is what
  happened. There is no `concat-all` in `coalton-library/string`, only a binary `concat`,
  which is why the helper gets written in the first place.
- **A pattern variable that matches a constructor name is a WARNING**, and case-insensitivity
  makes it easy: `((Ok rendered) …)` where `Rendered` is a constructor. `ql:quickload` passes
  it and `asdf:load-system` — which is what `verify-tree.lisp` and a consuming app's build
  use — refuses the file. See §8b; this is the same symbol rule biting in `match`.

### 4a. `define-type` takes no docstring

```lisp
(define-type Job-State
  "What state a job is in."            ; <- NOT a docstring
  Queued Running Done)
```

The string is parsed as a **constructor**, and the error is `error: Invalid identifier name`
pointing at something else entirely (#114). `define-class` *does* take one, which is what
makes this easy to get wrong. Put the prose in a `;;` comment above the form.

## 5. The CL ↔ Coalton boundary

### 5y. The boundary checks an argument, not what is inside it (#110)

A Coalton function called from CL checks the outer type of each argument when it is entered.
It does not check the elements of a list, and it does not check an `Optional` argument at all.
Measured in development and release mode:

| call from CL | result |
|---|---|
| `:foo` where `String` is declared | `TYPE-ERROR` |
| `:foo` where `(List String)` is declared | `TYPE-ERROR` |
| `(list :foo)` where `(List String)` is declared | not checked on entry |
| anything where `(Optional String)` is declared, even `:foo` | not checked on entry: `(Some x)` is represented as `x` |

An unchecked wrong value reaches code compiled on the promise that it is right. Depending on
the value and the code, that is an unrelated error, a wrong answer, or a memory fault with
*"The integrity of this image is possibly compromised"*. Passing the header list
`("Retry-After" 30)` to `hyperion/http1:encode-head-flat` is a memory fault.

So a CL function that passes a list or an `Optional` into Coalton wraps that argument with
[`aion/boundary`](../aion/src/boundary/boundary.lisp), in the call form:

```lisp
(turn:run-chain (boundary:check-elements chain 'aion/interceptor:interceptor
                                         :function 'turn:run-chain :argument 'chain)
                effect turn)
(money:money-ok? (boundary:check-optional amount 'money:money
                                          :function 'money:money-ok? :argument 'amount))
```

Both return the value, and on a wrong one signal `boundary:boundary-type-error`, a
`type-error` whose datum is the offending element and which names the function, the argument
and the index. The element type is a CL type: `string` for `String`, and the type's own name
for a `define-type` or `define-struct` (see §7 for why that is allowed). A type parameter of an
element, such as the `Turn` in `(Interceptor Turn)`, does not exist at run time and is not
checked. `scripts/coalton-boundary.lisp` lists the Coalton functions that take a list or an
`Optional` and are called from CL.

### 5z. Coalton's `None` is TRUE in Common Lisp

```lisp
(or (mnemosyne/field:dialect-from name)          ; <- accepts every bad name
    (error 'unknown-dialect :name name))
```

`Optional` is a Coalton ADT, and `None` is an **object**. Every object is true in CL, so the
idiom above returns `None` *as if it were a value* and the error branch is unreachable. It
reads correctly, it compiles, and the failure it is guarding against passes straight through
(pre-publication issue 334).

The same applies to any Coalton ADT crossing into CL: **do not test one for truth.** Export a
monomorphic predicate returning `Boolean` — which *does* map to CL's `T`/`NIL` — and ask that:

```lisp
(unless (mnemosyne/field:dialect-known? n) (error 'unknown-dialect :name n))
(mnemosyne/field:dialect-required n)
```



- **A `define`d Coalton function is callable from CL** with plain CL scalars — that *is* the
  boundary. IO/effectful code stays in CL and calls into the typed core.
- **Expose a CL-facing constructor + total accessors** for each ADT the CL shell builds or
  reads, so the shell never pattern-matches:

  ```lisp
  (declare make-sqlite (String -> Backend))
  (define (make-sqlite path) (Sqlite path))         ; CL calls (make-sqlite "db.sqlite")
  (declare sqlite-path (Backend -> String))
  (define (sqlite-path b) (match b ((Sqlite p) p) ((Postgres _) "")))   ; total: every variant
  ```

  Make accessors **total** (handle every variant, returning a harmless default for the wrong
  one) — the CL shell branches on a tag first (e.g. `backend-name`), so the default is never
  actually consumed, and the accessor can't signal.
- **A typeclass-CONSTRAINED function can't be called from CL directly** — it takes a hidden
  dictionary argument, so `(touch stamp who entity)` from CL fails with *invalid number of
  arguments*. Expose a **monomorphic wrapper** (one concrete type → the dictionary is resolved
  at compile time), and call *that* from CL:

  ```lisp
  ;; ✗ (mnemosyne/entity:touch stamp who person)         ; from CL → invalid number of arguments
  (declare touch-person (Stamp * String * Person -> Person))   ; monomorphic: no constraint
  (define (touch-person s w p) (touch s w p))                  ; ✓ CL calls (touch-person s w p)
  ```

  Unconstrained multi-arg functions (e.g. `make-stamp`) call fine from CL; only the constrained
  (generic) ones need the wrapper. Use the generic freely *within* Coalton.
- No IO in Coalton — `format`/`print`/`connect`/random/clock all live in the CL shell.

## 6. File & package structure

A Coalton module is a CL package that `:use`s Coalton, with the readtable set and the code in
a `coalton-toplevel`:

```lisp
(cl:defpackage #:mnemosyne/backend (:use #:coalton #:coalton-prelude) (:export ...))
(cl:in-package #:mnemosyne/backend)
(named-readtables:in-readtable coalton:coalton)
(coalton-toplevel
  (define-type ...) (declare ...) (define ...))
```

Keep the Coalton core and its CL shell in **separate files/packages** (e.g.
`backend.lisp`/`entity.lisp` Coalton, `conn.lisp`/`id.lisp` CL) — the readtable and `:use`
differ, and the split mirrors typed-core / effectful-shell.

## 7. The `lisp` escape hatch, and the representation rule

Dropping into CL from inside Coalton uses the `lisp` operator:

```lisp
(lisp (-> Integer) (n)
  (cl:random n))
```

**Coalton trusts the declared output type and does not analyze the body.** It is an
assertion, not a check — the proof obligation is yours.

**The rule that keeps it safe:** a `lisp` block may traffic only in the representations
Coalton actually *promises* — `Symbol`, `Integer`, `IFix`, `UFix`, `Char`, `String`,
`F32`, `F64` (their Lisp counterparts), `Boolean` (`cl:t`/`cl:nil`), and `List` (a
non-circular homogeneous CL list). For any `define-type`, Coalton promises **nothing
across compilation modes**: `(define-type Wrapper (Wrap Integer))` may compile `Wrap` to
something like `cl:identity` in one mode and a CLOS instance in another.

So never inspect, construct, or destructure a `define-type` value's representation from
CL. Cross the seam through Coalton accessors, or pass promised scalars. The failure mode
is nasty: it works in development mode and breaks everywhere at once on a mode switch.

**The sanctioned exceptions: `aion/boundary` (#110).** One module reads Coalton's
representation, on purpose, because nothing else can check what §5y shows goes unchecked:

- `check-optional` recognises `None` with `coalton-impl/runtime/optional:cl-none-p`, a Coalton
  runtime internal, and relies on `(Some x)` being `x`. That dependency is kept in one function,
  `%coalton-none-p`, and `aion/boundary/tests` tests it with `Some` and `None` values Coalton
  itself constructs, so a Coalton that boxes `Some` fails that suite and one that removes
  `cl-none-p` fails the build.
- `check-elements` tests an element of a `define-type` or `define-struct` with `typep` against
  the type's name, which relies on Coalton making that type a CL class. The types checked this
  way are `aion/log/types:Field` and `aion/interceptor:Interceptor`. The suites that pass real
  values of them through a check (`aion/log/tests`, `praxeon/tests`) run on the release-mode
  CI leg too, so a mode in which either is not a class fails there. A single-field
  `define-type` is the case the rule above warns about; do not check one this way without
  measuring it in both modes.

No other code reads a representation.

### 7a. `print-object` on a `define-type` is a representation dependency (pre-publication issue 209)

The rule above is usually met while writing a `lisp` block. It also bites somewhere much
less obvious: **specializing a CLOS method — `print-object` above all — on a Coalton type.**
A method specializer names a class, and which class a `define-type` compiles to is exactly
what Coalton does not promise. Measured on this tree:

| | development | release |
|---|---|---|
| `MNEMOSYNE/BACKEND:PG-CONFIG` (one constructor) | `STANDARD-CLASS` | `STRUCTURE-CLASS` |
| `(Postgres …)` (a `Backend` variant) | `PG-CONFIG` | `BACKEND/POSTGRES` |

A single-constructor type keeps its name in both modes, so a specializer on it *happens* to
work; a multi-constructor type is not even named the same way, so the same code silently
specializes on nothing. Both are §7 violations, and both are invisible in development.

This came up for a real reason. Coalton generates a printer that renders a value **field by
field**, so a credential stored as a `String` field is written out in full by anything that
prints the enclosing value — most damagingly an unhandled condition's backtrace, which
reaches a deploy log precisely when a deployment is going wrong. That put a production
database password in plaintext into a log (pre-publication issue 209).

The obvious fix — a redacting `print-object` on `Pg-Config` — is the trap. **The fix that
holds is to change the field's TYPE, not the enclosing type's printer:**
`aion/secret:secret` is an ordinary CL struct whose printer we own legitimately, exposed to
Coalton as an opaque field type with `repr :native`:

```lisp
(coalton-toplevel
  (repr :native s:secret)
  (define-type Secret)
  (declare make-secret (String -> Secret))
  (define (make-secret plaintext) (lisp (-> Secret) (plaintext) (s:make-secret plaintext))))
```

Because the redacting printer belongs to *our* struct rather than to Coalton's rendering of
the type holding it, it travels with the value into any aggregate, in either mode. The
`lisp` blocks traffic only in a native type and `String`, so §7 is respected rather than
sidestepped. **The general form: when you need to control how a value prints inside a
Coalton type, own the printing of the FIELD.**

## 8. Compilation modes — development vs release

Coalton compiles in one of two global modes, fixed by `COALTON_ENV` **before Coalton
itself is built**. Development (the default, and what Ouranos runs today) keeps most types
as redefinable CLOS classes and disables optimizations that obscure debugging; release
(`COALTON_ENV=release`) freezes types into flattened `defstruct`s and optimizes.

The mode is a property of the whole image, Coalton's own stdlib included — you cannot mix.
Two consequences worth internalizing:

- **Benchmarks in development mode say nothing about release performance.** State the mode
  with any number you record. Measured on this tree: an ADT-dense workload runs **~9.6x**
  faster in release mode, while a route match and a log line move by roughly 1.3x — so a
  number without its mode could be off by an order of magnitude, in an unknown direction.
- **Test both modes.** Coalton's docs warn that code can inadvertently depend on one
  mode's behavior, and a §7 representation violation is invisible in development mode. The
  tree does pass in release mode today (3150 checks, measured under pre-publication issue 209) — which is a result, not a
  guarantee, and is what the release-mode CI leg exists to keep true.

Both are scripted: `scripts/with-mode.lisp` runs anything under a chosen mode, each mode in
its own fasl cache. See [`benchmarking.md`](benchmarking.md) for the numbers and the rule.

See [`../aion/docs/cl-shell-design.md`](../aion/docs/cl-shell-design.md) for how Aion uses
this seam deliberately, and [`coalton-upstream.md`](coalton-upstream.md) for keeping the
checkout current.

## 8a. An unused variable is a WARNING, and ASDF turns that into a build failure

Coalton reports an unused binding as a full `WARNING` (not a style-warning). ASDF's
`compile-file*` treats a `WARNING` as `failure-p`, so the system **fails to build**:

```
; caught COMMON-LISP:WARNING:
;   warn: Unused variable
;     --> .../types.lisp:337:40
;   help: prefix the variable with '_' to declare it unused
```

Fix it the way the compiler says — `_seen?` rather than `seen?` — for any binding a
`match` pattern introduces but the branch does not read.

**Two things make this bite far harder than it should.**

- **`ql:quickload` hides it — with no muffling at all.** This is stronger than it first
  appeared and it is the one that actually bites: plain `(ql:quickload :hyperion)` reports
  success on a system that `(asdf:load-system :hyperion)` refuses to build. Verified
  head-to-head on a real defect. Explicit `(handler-bind ((warning #'muffle-warning)) …)`
  hides it too, but you do not need to opt in — the everyday command is enough.
  **Verify with `asdf:load-system`, never `ql:quickload`.**
- **A warm fasl hides it too.** The warning is emitted when the file is *compiled*. Once a
  fasl exists the file is only loaded, so every subsequent run passes. The failure appears
  on a fresh clone, on CI, and after `~/.cache/common-lisp` is cleared — i.e. on someone
  else's machine.

So a green local run proves less than it appears to. Before committing Coalton, compile
**cold and unmuffled**:

```sh
find ~/.cache/common-lisp -path "*<your-project>*" -name "*.fasl" -delete
sbcl --dynamic-space-size 4096 --script scripts/verify-tree.lisp
```

`scripts/verify-tree.lisp` loads with **`asdf:load-system`** for exactly this reason. It
used `ql:quickload` until 2026-08-05, and consequently passed a branch that a consuming
app's plain ASDF build rejected — the warm fasl quickload left behind then hid the same
warning from the test phase. Switching the loader immediately surfaced **two further
defects nobody knew about**: a `defun` clobbering a `defstruct` predicate in
`aion/csv/reduced.lisp`, and a Spinneret attribute-table gap in the coalton-repl example.
Both had been in the tree for weeks, green every time.

## 8b. A constructor and a same-named function are the SAME symbol

§4's case-insensitivity rule has a shape worth calling out on its own, because the error
message points somewhere else entirely. Given a type whose constructor is `Step`, a
function named `step` **is that constructor**:

```lisp
(define-type Step (Step Action ParseState))
(declare step (ParseState * CharClass * Boolean * Boolean -> Step))   ; ✗ collides
;; every (Step action next) call now resolves to the 4-argument function:
;;   error: Function call has 2 positional arguments but inferred type
;;          'ParseState * CharClass * Boolean * Boolean -> Step' takes 4
```

The message describes the *call site* (`(Step AcFinishRow StStart)`) rather than the
duplicate name, so it reads like an arity bug in code that is correct. Name the function
something else — `transition`, not `step`. Accessors are fine (`step-action`, `step-next`
are distinct symbols); it is only the bare name that collides.

## 9. Misc

- **First load compiles Coalton** (minutes); give SBCL a big heap
  (`--dynamic-space-size 4096`). Cached after; the repo warm step (`bootstrap.lisp`) pays it
  once up front.
- Errors surface at **macroexpansion / compile time**, not load — read the `-->` file:line in
  the Coalton error; it points at the exact form.

---

*Seen a new one? Add it here, then mirror the one-liner into the conformance pack's Coalton
section (`cons/src/conform.lisp`).*
