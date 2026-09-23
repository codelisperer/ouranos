# Aion — Vision Questions

Open design questions to steer the library before code hardens. These are *my
clarifying questions for you*; answer inline (or in the roadmap) as they resolve.
Grounded in [`coalton-gap-analysis.md`](coalton-gap-analysis.md) — read that first.

## 1. Primary audience: CL-first or Coalton-first?
The gap analysis says the adoption story is the **pure-CL face**. But the name and
thesis are Coalton-first. Who is the *primary* user in v1 — a plain-CL dev who
wants coherent immutable collections (and never sees Coalton), or a Coalton dev who
wants the missing idioms? This decides whether `aion/cl` or the typed layer gets
the polish first. *(My lean: CL-face-first for adoption, typed layer underneath.)*

## 2. The `ISeq` protocol: CLOS generics, or a Clojure-style protocol macro?
The consistent sequence protocol is Thread 1. Implement it as plain CLOS generic
functions (`first`/`rest`/`conj` as `defgeneric`), as a `define-protocol` macro
mimicking Clojure protocols, or lean on CL's extensible `sequence` package? Trade
-off: CLOS is idiomatic and simple; a protocol macro is more Clojure-familiar but
more machinery. *(My lean: CLOS generics — least surprise, no new metaobject work.)*

## 3. How much should the CL face hide Coalton?
Should CL users see Coalton types at all (e.g. `Result`/`Optional` leaking
through), or does `aion/cl` translate fully to CL idioms (`values`/`nil`,
conditions)? Full translation = friendlier but lossy; leaky = more honest but asks
CL users to learn Coalton concepts.

## 4. Set semantics — value equality story?
Persistent sets (Thread 2) need an equality/hash notion. Ride Coalton's `Eq`/`Hash`
typeclasses (clean, typed) — but then the CL face needs a bridge for arbitrary CL
values. How do CL users get sets of their own structs/objects?

## 5. Transducers: worth the type-system fight?
Statically-typed transducers (Thread 3) are the novel research bit but also the
hardest to type well in HM. Is this a marquee feature worth real effort, or a
"nice to have" that can wait until the collections + optics land?

## 6. Optics scope for v1?
Full `Lens`/`Prism`/`Traversal`/`Iso` tower, or start with just `Lens` + `Traversal`
(the 80%)? And: hand-written optics only, or a macro that derives optics from
Coalton record definitions?

## 7. Naming & namespacing for CL users.
Packages like `aion/seq`, `aion/set`. Do CL users get a batteries-in convenience
package (`aion` re-exporting the common surface + threading macros) so they add one
dependency and `:use`/nickname it? What's the intended `:local-nickname` (e.g.
`a:` for aion, `seq:`/`set:`)?

## 8. Relationship to existing CL FP libs (FSet, cl-hamt, serapeum, trivia).
FSet already offers functional sets/maps/seqs in pure CL; serapeum has threading
macros; trivia has pattern matching. Is Aion's differentiator specifically *the
Coalton backing + typed layer*, and do we interop with / borrow from these, or
deliberately stand apart? Positioning matters for the pitch.

The fuller landscape to position against (and possibly mine for the gap items —
persistent Sets, lenses, etc. — rather than build from scratch):

- **Purely functional / persistent** (closest to Aion's model):
  - **FSet** — flagship functional seqs/sets/maps/bags with a *global ordering*.
    Mature; heavier (`misc-extensions`); its total-order equality model differs
    from Coalton's `Eq`/`Hash` (relevant to §4's value-equality question).
  - **Sycamore** (Neil Dantam) — weight-balanced trees, persistent maps/sets,
    priority queues. Leanest of the functional options; good benchmark baseline.
  - **cl-hamt** — HAMT persistent hash-maps/sets, the `{}`/`#{}` model. Overlaps
    directly with Coalton's HAMT `hashmap` — useful as a *comparison point*, not a
    dependency.
- **Pragmatic / mutable**: **serapeum** (threading, `dict`, queue, heap),
  **cl-data-structures** (large, aggregation/lazy ranges), **cl-containers**
  (classic, dated), **rutils**.
- **Adjacent idioms** (not collections, but the surrounding vocabulary):
  **trivia** (pattern matching), **Alexandria** (near-universal utility belt),
  **trivial-extensible-sequences** (portable CLOS `sequence` — the thing the
  `ISeq` protocol in §2 is trying to supersede cleanly).

These also make natural **benchmark peers** (see §9): FSet and Sycamore are the
obvious pure-CL baselines to measure Coalton-backed collections against.
*(My lean: differentiate on Coalton backing + typed layer + the coherent CL face;
borrow **algorithms/ideas** freely, but don't take runtime deps on FSet/cl-hamt —
their data models fight Coalton's `Eq`/`Hash`. FSet is the one worth interop
consideration for CL users who already have FSet values.)*

## 9. Benchmarks as a first-class deliverable?
Part of the thesis is "Coalton is peer-level." Do we want a benchmark suite
(vs Clojure persistent collections, vs FSet, vs Rust `im`) as evidence, shipped
early? It would make the "already peer-level" claim concrete.

## 10. AI-friendliness — what concretely?
The house goal is "vibe-coding friendly, even for people who hate parentheses."
For a *data-structure library*, what does that mean in practice — worked
before/after examples, a cheat-sheet mapping Clojure/Rust/TS idioms to Aion,
docstring-dense APIs, an LLM-oriented `docs/llms.txt`? Pick the concrete artifacts.
