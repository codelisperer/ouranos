# Aion's CL half — where the optimization lives

*Aion is Coalton-first, not Coalton-only. This doc covers the other half: where clean
Common Lisp does the work, and what discipline keeps that from leaking into the typed
surface. Read [`coalton-gap-analysis.md`](coalton-gap-analysis.md) first — it covers what
Coalton already gives us; this covers what CL gives us that Coalton shouldn't try to.*

Verified against the local Coalton checkout at `03648698` (2026-07-29).

---

## 1. The thesis

The house rule is "typed Coalton core, effectful CL shell — no IO in Coalton." That rule
is usually read as being about *IO*. It is really about **where guarantees live versus
where work happens**, and IO is only its most obvious case.

Clojure makes the same move twice, and both are instructive:

- **Transients.** `conj!` mutates. It is unambiguously impure. But it is fenced inside
  `transient`/`persistent!`, so the *caller* sees a pure function. The mutation is real;
  the impurity is local.
- **`recur`.** The JVM has no tail-call elimination, so Clojure exposes an explicit,
  *compile-time-checked* tail jump. It is not sugar — it is a guarantee (constant stack)
  that the host cannot otherwise provide, made legible in the language.

Both say the same thing: **the guarantee belongs in the interface, the mechanism belongs
wherever it is fastest.** Aion's version:

| Layer | Language | Holds |
|---|---|---|
| Surface | Coalton | Types, laws, totality. What callers may rely on. |
| Mechanism | Common Lisp | Mutation, unboxed arrays, explicit loops, IO. SBCL-specific, `declaim`ed, measured. |
| Seam | Coalton's `lisp` operator | A typed assertion over an unchecked body. |

**Aion is the only framework where the middle layer is a feature rather than a
concession.** Everywhere else in the tree, dropping to CL is an admission. Here it is the
job: Aion exists so that the frameworks above it never have to make that trade themselves.

## 2. The seam, precisely

```lisp
(lisp (-> ⟨output-type⟩) (⟨coalton-var⟩ ...)
  ⟨lisp-form⟩ ...)
```

**Coalton trusts the declared output type and does not analyze the Lisp body.** The seam
is an *assertion*, not a check — the proof obligation moves from the compiler to the
author. That is exactly why it belongs concentrated in Aion, written once and reviewed
hard, rather than sprinkled across six frameworks.

### The rule that makes the seam safe

Coalton's interop document makes a short list of **promises**: `Symbol`, `Integer`,
`IFix`, `UFix`, `Char`, `String`, `F32`, `F64` are their Lisp counterparts; `Boolean` is
`cl:boolean` with `True`/`False` as `t`/`nil`; every `List` is a non-circular homogeneous
CL list.

For everything else — every `define-type` — it explicitly promises **nothing across
compilation modes**. Its own example: `(define-type Wrapper (Wrap Integer))` may compile
`Wrap` to something like `cl:identity`, making `Wrapper` representation-equivalent to
`Integer` in one mode and a CLOS instance in another.

> **Hard rule: a `lisp` block may traffic only in the promised representations. It must
> never inspect, construct, or destructure a `define-type` value's representation.**
> Cross the seam through Coalton accessors, or pass promised scalars.

This is not hypothetical for us. `elenchon/ceg` wraps its identifiers in newtypes
(`CauseId`, `EffectId`, …) precisely so wiring bugs cannot compile. Those wrappers are
CLOS instances in development mode and plausibly erased entirely in release mode. CL code
that reached past `cause-id-name` into the representation would work today and break on a
mode switch — and the mode switch is a global build flag, so it would break *everything
at once*, far from the cause.

## 3. The mode problem — read this before benchmarking anything

Coalton compiles in one of two global modes, set by `COALTON_ENV` before Coalton itself
is built:

| | Development (default) | Release (`COALTON_ENV=release`) |
|---|---|---|
| Types | mostly CLOS classes, redefinable | frozen `defstruct`s, flattened/unwrapped |
| Optimizations | several disabled for debuggability | applied |
| Redefinition | works | often requires restarting the image |

**Ouranos currently runs entirely in development mode.** The load banner says so on every
boot:

```
;; COALTON starting in development mode
;; COALTON starting with specializations enabled
;; COALTON starting with heuristic inlining disabled
```

Three consequences, none optional:

1. **Every performance number measured today is meaningless as a release claim.** Any
   benchmark — elenchon's reasoning benchmark included — must state its mode, and any
   claim aimed at outsiders must be measured in release mode.
2. **The mode is all-or-nothing across the image**, Coalton's own stdlib included. It is a
   property of the build, not of a system. So "just try release mode" is a full rebuild,
   which is why it needs to be a deliberate, scripted step rather than an experiment
   someone runs by hand.
3. **Both modes need testing.** Coalton's own docs warn that code can inadvertently depend
   on one mode's behavior. Given the hard rule in §2, a release-mode CI job is the thing
   that would actually catch a seam violation — the failure is invisible in development
   mode.

Aion should own the mode story for the tree, because Aion is where the representation
assumptions are concentrated.

## 4. Transients — the honest version

**The problem.** Building a persistent collection element-by-element allocates a fresh
path per insert: O(log n) allocation *per element*, O(n log n) to build a collection of
n. For a parser, a CSV reader, or a query-result decoder — all of which Aion is meant to
serve — that is the dominant cost, and it is pure waste, because the intermediate
collections are never observed.

**Clojure's answer** is transients: `(persistent! (reduce conj! (transient []) xs))`.
Ownership is enforced at *runtime* (a transient checks it is used by its owning thread and
invalidates on `persistent!`).

**What we can and cannot copy.** Coalton has no linear or affine types, and no rank-2
polymorphism, so there is no `runST`-style trick that makes escape a *type* error. The
scoped-builder shape is still right —

```lisp
(declare build-seq ((Builder :a -> Unit) -> (Seq :a)))
```

— the builder exists only for the dynamic extent of the callback, and the result is
persistent. But **be honest in the docs about what enforces it**: an opaque type in an
internal package, plus the discipline of not closing over the builder. Not the type
system. Claiming otherwise would be exactly the kind of overclaim the launch review is
already cleaning up elsewhere.

**And the deeper constraint:** a *true* transient needs mutable access to the RRB-tree and
HAMT internals, which Coalton's `Seq` and `hashmap` do not expose. Aion cannot build one
from outside without vendoring the structures — which would fork the substrate the gap
analysis explicitly says not to reimplement.

So the plan splits:

- **What Aion can do now:** *bulk construction*. One pass from a CL vector or hash table
  into a finished persistent structure, replacing n incremental inserts with a single
  build. It captures most of the win for the common case (you have all the elements
  already) without touching internals.
- **What belongs upstream:** real transients, as a contribution to Coalton. This is the
  better outcome — the whole ecosystem gets it, and Aion does not carry a fork.
- **What Aion uniquely owns either way:** *the measurement*. Aion is where the benchmark
  lives that says whether any of this matters, and by how much, in release mode.

## 5. Looping and the `recur` question

**Start by not competing with upstream.** Coalton ships
`library/experimental/loops.ct` — `dotimes`, `dolist`, `dolists`, `dorange`, `doiter`,
`repeat`, plus accumulating forms (`sumtimes`, `prodtimes`, `collecttimes`, `besttimes`,
`argbesttimes`). Most of the sugar exists. Its own docstring names the sharp edges:

> `(break)` and `(continue)` do not work inside these loop macros. `(return)` refers to
> the enclosing function, not the macro's hidden callback.

**What is actually missing is the guarantee, not the sugar.** Clojure's `recur` matters
because it is *checked*: not-in-tail-position is a compile error, so constant stack is
something you can rely on rather than hope for. Coalton documents no tail-call guarantee.
SBCL does eliminate tail calls under normal optimization settings — but development mode
disables optimizations, which is precisely the mode we run in.

**This is not theoretical.** `elenchon/ceg`'s `eval-conj` and `eval-disj` recurse and
*then* combine — non-tail by construction. They are correct, and they will exhaust the
stack on a deep enough expression. Written a week ago, in this tree, by following the
natural Coalton idiom.

The proposed division:

- **Prefer upstream.** Missing sugar, `break`/`continue`, and the `return` wart are
  Coalton issues. File them; don't fork them.
- **Aion adds the checked tail-loop** — a `recur`-shaped construct with a *compile-time
  tail-position check*, expanding to a CL `tagbody`/`loop` so the stack behavior is
  guaranteed by the expansion rather than inferred from the optimizer's mood. That is the
  one piece that is genuinely a guarantee rather than a convenience, and it is the piece
  the host language can deliver and Coalton currently cannot.
- **Aion documents the accumulator idiom** for the `eval-conj` shape, since most
  non-tail recursion in this tree is avoidable rather than essential.

## 6. When does code drop to CL?

A decision rule, so this stays a design and not a license:

1. **It performs IO** → CL. (Already the house rule.)
2. **It mutates** → CL, fenced behind a pure Coalton signature. The mutation must not be
   observable through that signature.
3. **It is measured hot, and the Coalton form allocates unnecessarily** → CL, **with the
   benchmark recorded next to it**. "It felt slow" is not a reason. A number is.
4. **It needs a stack or representation guarantee Coalton does not make** → CL.
5. **Otherwise** → Coalton. The default is the typed layer, and the burden of proof is on
   leaving it.

And two constraints that bind regardless:

- **A `lisp` block traffics only in promised representations** (§2). No exceptions; the
  failure mode is silent and global.
- **Every CL fast path needs a Coalton reference implementation and a test asserting they
  agree.** The pure version is the specification. Without it, the optimization is
  unfalsifiable — which is how fast, wrong code survives.

## 7. What this implies for Aion's shape

Adds to the module sketch in `src/packages.lisp`:

| Module | Language | Role |
|---|---|---|
| `aion/build` | CL + Coalton seam | Bulk construction of persistent collections; the transient story (§4) |
| `aion/loop` | CL macros | The checked tail-loop; the accumulator idioms (§5) |
| `aion/clock` | CL | Monotonic time + sortable ids — see [`sweep-2026-07.md`](sweep-2026-07.md) |
| `aion/random` | CL | CSPRNG. Currently a known-weak placeholder above Aion |
| `aion/retry` | CL | Retry/backoff policy as data |

The last three come out of the framework sweep rather than from Coalton's gaps — they are
things the tree already needs and is solving inconsistently. They are pure CL by nature
(clock, entropy, and sleep are all IO), which makes them a clean first demonstration of
this doc's thesis: **Aion is not "the Coalton library." It is the floor the whole tree
stands on, and part of that floor is unapologetically Common Lisp.**
