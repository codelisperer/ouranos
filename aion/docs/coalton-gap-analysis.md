# Coalton FP Gap Analysis

*What Coalton's standard library already gives you, measured against the FP
toolkits of Clojure, Rust, TypeScript, and raw JavaScript — and the genuine gaps
that are Aion's reason to exist.*

This is Aion's founding design doc. **Read it before building anything.** The
temptation is to "bring Clojure to Lisp" from scratch; the reality is that Coalton
is already most of the way there, and the leverage is in (a) a pure-CL face and
(b) a short list of real holes.

> **Re-audited 2026-07-29** against the local Coalton checkout
> (`~/common-lisp/coalton`, upstream `coalton-lang/coalton`, at `03648698`). The
> founding snapshot asked for exactly this before committing to any gap — and **one
> gap had closed**: `Monoid` ships in Coalton and is corrected below. Sets,
> transducers, optics, and memoized lazy-seq were re-verified as genuine gaps.
> Re-audit again at the cadence in [`docs/coalton-upstream.md`](../../docs/coalton-upstream.md);
> a gap that closes upstream is work Aion should *delete*, not inherit.

---

## 1. What Coalton already ships

Coalton's stdlib is `.ct` source — roughly 50 modules, ~920 definitions. The
functional substrate is already strong.

### Persistent, immutable collections

| Coalton | Backing structure | Closest analog |
|---|---|---|
| `Seq` (`seq.ct`) | RRB-tree persistent vector | Clojure vector / `immutable.js` List |
| `hashmap` (`hashmap.ct`) | HAMT | Clojure `PersistentHashMap` / `immutable.js` Map |
| `ordmap` / `ordtree` (`ordmap.ct`, `ordtree.ct`) | immutable balanced tree | Clojure `sorted-map` / `BTreeMap` |
| `List` (`list.ct`) | immutable cons list | Clojure seq / OCaml `list` |
| `Vector` | mutable growable array | Rust `Vec` (the escape hatch) |

Structural sharing, no mutation. This is the hard part of "Clojure goodness," and
it is **already done**.

### The typeclass tower

`Functor`, `Applicative`, `Monad`, `Foldable`, `Traversable`, `Semigroup`,
`Bifunctor`, `Eq`, `Ord`, `Hash`, the full `Num` tower, `Show`, `Into`/`TryInto`,
`Iterator`/`IntoIterator`/`FromIterator`. **Plus monad transformers** —
`StateT`, `ResultT`, `OptionalT`, `EnvironmentT`, `FreeT`. That transformer stack
puts Coalton ahead of Clojure (no static types) and level with a curated Haskell
`mtl`-lite. Rust has no monads; TS gets them only via libraries (fp-ts/Effect).

### Lazy iteration

`Iterator` is a lazy pull sequence with `map`/`filter`/`fold`/`zip`/`take` etc. —
covers most of what Rust's `Iterator` and JS generators do.

### Error handling

`Result` and `Optional` as first-class ADTs with the full `map`/`and_then`/monad
interface — i.e. Rust's `Result`/`Option` combinators, statically typed, native.

---

## 2. Scorecard vs the other ecosystems

| Capability | Coalton today | Clojure | Rust | TS (fp-ts/Effect) | raw JS |
|---|---|---|---|---|---|
| Persistent vector/map | ✅ `Seq`/`hashmap` | ✅ | ➖ (`im` crate) | ➖ (immutable.js) | ❌ |
| Immutable ordered map | ✅ `ordmap` | ✅ | ✅ `BTreeMap` | ➖ | ❌ |
| **Persistent set** | ❌ **gap** | ✅ | ✅ | ➖ | ❌ (`Set` mutable) |
| Result/Option monad | ✅ | ➖ | ✅ | ✅ | ❌ |
| Typeclasses / traits | ✅ | ❌ (protocols) | ✅ | ➖ | ❌ |
| Monad transformers | ✅ | ❌ | ❌ | ✅ | ❌ |
| Lazy sequences | ✅ `Iterator` | ✅ | ✅ | ➖ | ➖ (generators) |
| **Memoized lazy-seq** (cached, shareable) | ❌ **gap** | ✅ | ❌ | ➖ | ❌ |
| **Transducers** | ❌ **gap** | ✅ | ❌ | ❌ | ❌ |
| **Optics / lenses** | ❌ **gap** | ➖ (specter) | ➖ (crates) | ✅ (monocle-ts) | ❌ |
| ~~`Monoid`~~ | ✅ **not a gap** — `classes.ct:226`, `(Semigroup :a => Monoid :a)` with `mempty` / `mempty?` / `mconcat` / `mconcatmap` | n/a | n/a | ✅ | ❌ |
| **Threading macros** (`-> ->>`) | ❌ **gap** | ✅ | ➖ (`.` chains) | ➖ (pipe) | ➖ |
| itertools breadth (`chunk`, `window`, `group-by`, `partition-by`, `dedupe`) | ➖ partial | ✅ | ✅ | ➖ | ❌ |
| **Consistent CL-facing seq protocol** | ❌ **gap** (Coalton-only) | n/a | n/a | n/a | n/a |

✅ solid · ➖ partial / library-only · ❌ absent

---

## 3. The genuine gaps — Aion's scope

Ordered by leverage:

1. **A pure-CL face (`aion/cl`) + a consistent `ISeq`-style protocol.** The single
   biggest win. CL's built-in `sequence` handling is inconsistent (lists vs
   vectors vs extensible-sequences, `elt` vs `nth` vs `aref`, `map` needing a
   result-type arg). Expose Coalton's persistent collections and one generic,
   uniform protocol (`first`/`rest`/`cons`/`conj`/`seq`/`into`) to CL users who
   never touch Coalton. This is what turns "Coalton has nice collections" into
   "Common Lisp finally has a coherent sequence story."

2. **Persistent Sets (`aion/set`).** A clear structural hole — hash-set and
   ordered-set, naturally built on the existing HAMT / ordtree substrate.

3. **Transducers (`aion/xform`).** Composable, collection-independent transforms
   (`map`/`filter`/`take`/`partition` as reducing-function transformers). Coalton's
   static types make this an interesting, principled design problem — and nobody
   outside Clojure really has them.

4. **Optics / lenses (`aion/optics`).** Lens/Prism/Traversal for ergonomic
   immutable update — the thing people actually miss once everything is immutable.
   TS has monocle-ts; Coalton's types make lawful optics natural.

5. **Memoized lazy-seq (`aion/lazy`).** A cached, shareable lazy sequence (Clojure
   `lazy-seq` semantics) distinct from Coalton's re-runnable `Iterator`.

6. ~~**`Monoid`**~~ — **struck (2026-07-29 re-audit): Coalton has it.** `classes.ct:226`
   defines `(Semigroup :a => Monoid :a)` with `mempty`, and `functions.ct` adds
   `mempty?`, `mconcat`, and `mconcatmap`. Instances ship across `list`, `string`,
   `optional`, `result`, `hashmap`, `ordmap`, `iterator`, `vector`, and `file`. Use it;
   do not reimplement it. *This is the cautionary example for the whole doc — a gap
   asserted at founding that was never true, or stopped being true, and would have cost
   real work.*

7. **itertools breadth** — `chunk`, `window`/`sliding`, `group-by`, `partition-by`,
   `dedupe`, `frequencies`, `interleave`, `zip-with`. Fill out `Iterator`.

8. **Threading sugar (`aion/thread`)** — `->`, `->>`, `some->`, `cond->`, `as->`,
   `doto`. Macros; work at the CL layer over both faces.

9. **The CL performance half** — transients, checked looping, and the `lisp`-seam
   discipline. This is a whole axis the founding snapshot did not cover; it has its own
   design doc, [`cl-shell-design.md`](cl-shell-design.md). Short version: the *guarantee*
   belongs in the Coalton type, the *optimization* belongs in clean CL underneath it.

10. **Low-level primitives the frameworks already need** — a monotonic clock + sortable
    ids, a CSPRNG, and retry/backoff. All three are being solved (or conspicuously
    not solved) above Aion today; see [`sweep-2026-07.md`](sweep-2026-07.md).

---

## 4. Strategy that falls out of this

- **Don't reimplement the substrate.** Build sets/lazy-seq/etc. *on* Coalton's
  HAMT/RRB/ordtree, don't hand-roll trees.
- **Two faces, one library.** Typed Coalton layer for Coalton users; `aion/cl`
  wraps it for the majority who write plain CL. The CL face is the adoption story.
- **The pitch is "Coalton is already peer-level; here's the clean CL face plus the
  last-mile idioms"** — more credible and less work than "reimplementing Clojure in
  Lisp."

*(Snapshot as of founding, 2026-07. Coalton evolves; re-audit the `.ct` modules
before committing to any gap above — a "gap" may have landed upstream.)*
