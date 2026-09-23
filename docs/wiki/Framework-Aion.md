# Aion — the functional core

*Αἰών, "the eternal."* **A Coalton-first functional standard library for Common Lisp.**
The name is the thesis: values that never change. Aion is about immutable, persistent
data and the functional vocabulary for working with it.

---

## What it is / why it exists

The meta-thesis of the whole monorepo is to make **Coalton a first-class "modern
Lisp"** — a genuine peer to Clojure, Scheme, OCaml, and Haskell. Aion is where that
claim gets cashed out at the level of data: persistent collections, a *consistent*
sequence protocol, and the Clojure-goodness (transducers, optics, lazy sequences,
threading macros) that makes immutable data pleasant rather than penitential.

The obvious way to build such a library would be "reimplement Clojure on top of
Common Lisp." Aion deliberately does **not** do that, and the reason is the single
central fact in its design:

> **Coalton's standard library is already remarkably complete.** Roughly 50 `.ct`
> modules and ~920 definitions ship a persistent RRB-tree vector (`Seq`), a HAMT
> hash map (`hashmap`), ordered maps (`ordmap`/`ordtree`), an immutable cons list,
> a lazy pull `Iterator`, `Result`/`Optional` as first-class ADTs, and the full
> typeclass tower — `Functor`/`Applicative`/`Monad`, `Foldable`, `Traversable`,
> `Semigroup`, `Bifunctor`, `Eq`/`Ord`/`Hash`, the `Num` tower, `Show`,
> `Into`/`TryInto`, `Iterator`/`IntoIterator`/`FromIterator` — **plus monad
> transformers** (`StateT`, `ResultT`, `OptionalT`, `EnvironmentT`, `FreeT`).

Structural sharing, no mutation. That transformer stack puts Coalton *ahead* of
Clojure (which has no static types) and roughly level with a curated Haskell
`mtl`-lite; Rust has no monads at all, and TypeScript gets them only via libraries.
The hard part of "Clojure goodness" is therefore **already done**.

So Aion's actual scope is two things:

1. **A pure-CL face.** Expose Coalton's persistent collections — and one consistent,
   generic `ISeq`-style protocol — to Common Lisp users who never write a line of
   Coalton. Common Lisp's built-in `sequence` handling is famously inconsistent
   (lists vs vectors vs extensible sequences, `elt` vs `nth` vs `aref`, `map`
   demanding a result-type argument). Fixing that is what turns "Coalton has nice
   collections" into "**Common Lisp finally has a coherent sequence story**."
2. **The genuine gaps.** The short list of things Coalton does not yet have:
   persistent **Sets**, **transducers**, **optics/lenses**, memoized **lazy-seq**,
   `Monoid`, itertools-grade combinators, and threading sugar
   (`->`, `->>`, `some->`, `cond->`).

The pitch that falls out is stronger and more defensible than the from-scratch one:
*Coalton is already peer-level; here is the clean CL face plus the last-mile idioms.*

### The scorecard that defines the scope

| Capability | Coalton today | Clojure | Rust | TS (fp-ts/Effect) |
|---|---|---|---|---|
| Persistent vector / map | ✅ `Seq` / `hashmap` | ✅ | ➖ (`im`) | ➖ (immutable.js) |
| Immutable ordered map | ✅ `ordmap` | ✅ | ✅ `BTreeMap` | ➖ |
| **Persistent set** | ❌ **gap** | ✅ | ✅ | ➖ |
| Result / Option monad | ✅ | ➖ | ✅ | ✅ |
| Typeclasses / traits | ✅ | ❌ (protocols) | ✅ | ➖ |
| Monad transformers | ✅ | ❌ | ❌ | ✅ |
| Lazy sequences | ✅ `Iterator` | ✅ | ✅ | ➖ |
| **Memoized lazy-seq** | ❌ **gap** | ✅ | ❌ | ➖ |
| **Transducers** | ❌ **gap** | ✅ | ❌ | ❌ |
| **Optics / lenses** | ❌ **gap** | ➖ (specter) | ➖ | ✅ (monocle-ts) |
| **`Monoid`** | ❌ **gap** (has `Semigroup`) | n/a | n/a | ✅ |
| **Threading macros** | ❌ **gap** | ✅ | ➖ | ➖ |
| itertools breadth | ➖ partial | ✅ | ✅ | ➖ |
| **Consistent CL-facing seq protocol** | ❌ **gap** | n/a | n/a | n/a |

✅ solid · ➖ partial / library-only · ❌ absent

This table is not decoration — it *is* the roadmap. Every planned module below maps
to a ❌ in it. And it carries an explicit expiry note: Coalton evolves, so **re-audit
the `.ct` modules before committing to any gap** — a "gap" may have landed upstream.

---

## Where it sits in the DAG

```
aion → cons → mnemosyne → elenchon → hyperion → praxeon
 ▲
 the foundation; depends on nothing to its right
```

Aion is the **leftmost** framework in the dependency DAG. It depends on nothing else
in the monorepo — only Coalton and Alexandria in the core system — and everything
else may depend on it. It is the collections and FP vocabulary the other five
consume. `hermes` (the satellite leaf-lib for external integrations, off the linear
DAG) also depends only on `aion`.

Because Aion is the floor, its dependency budget is the strictest in the repo: the
core system is `coalton` + `alexandria` and nothing more, with optional faces
(`aion/csv`, `aion/log`) split into *separate ASDF systems* so that a consumer pays
only for what it uses. `aion/csv` in particular depends on **nothing at all** — not
even Coalton — on purpose.

---

## Current status

**Pre-alpha (0.0.0).** The core is still a vision scaffold; two auxiliary systems are
real.

| System | Depends on | State |
|---|---|---|
| `aion` (core) | coalton, alexandria | Loads; exposes `aion:version`. **No library yet** — `src/aion.lisp` is 14 lines with no definitions. The collections core the name promises is genuinely unwritten; everything below it is not. |
| `aion/csv` | *nothing* | **Real.** Dialects + presets, portable scalar-DFA reader and writer, the `reduced` early-termination protocol, conditions; 24 conformance tests green. |
| `aion/log` | log4cl, com.inuoe.jzon | **Real.** Neutral leveled + structured logging: pretty for dev, one-line JSON to stdout for staging/prod; ambient `*context*` fields. |
| `aion/csv/types` | coalton | **Real.** The typed core of the CSV reader — a total `ParseState` transition and a provably-distinct `Dialect`; the shipping parser is conformance-tested against it. Separate so `aion/csv` stays Coalton-free. |
| `aion/clock` | `aion/random` | **Real.** Monotonic Gregorian-100ns counter and v6 ids. Extracted from `mnemosyne/id`, because a monotonic clock is a floor primitive rather than a persistence concern. |
| `aion/random` | ironclad, bordeaux-threads | **Real.** The CSPRNG behind session ids (pre-publication issue 95). A security primitive, so it sits inside the verification gate. |
| `aion/signature` | ironclad | **Real.** Ed25519 verification — public key only, so a verifying host cannot mint. |
| `aion/secret` | *nothing* | **Real.** An opaque credential wrapper: plaintext in, `reveal` out, `#<SECRET REDACTED>` on every print path (pre-publication issue 209). Dependency-free and Coalton-free on purpose, so `cons` can hold a DB password without its core gaining Coalton. |
| `aion/secret/types` | `aion/secret`, coalton | **Real.** The same struct as an opaque Coalton field type (`repr :native`), so a `define-type` can carry a credential without a printable `String` field. |
| `aion/interceptor` | coalton | **Real.** A typed, protocol-agnostic interceptor pipeline (pre-publication issue 177). Not owned by a framework: the shape is request-response, not web, and the tree had reimplemented it twice before it moved here. |
| `aion/http-client` | dexador | **Real.** An interceptor-shaped client for one outbound call (pre-publication issue 202): enter stages, one round-trip, leave stages. The response carries the bytes that arrived; the string is derived (pre-publication issue 223). |
| `aion/platform` | *nothing* | **Real.** The host-platform registry (pre-publication issue 182). |
| `aion/uv`, `/net`, `/process` | cffi + a built libuv | **Real, opt-in.** The native boundary. Excluded from the default gate because they need a C toolchain — build with `scripts/build-libuv.lisp`, then `OURANOS_WITH_UV=1`. |
| `aion/windows`, `/com` | cffi | **Real, Windows-only** (ADR-0003). UTF-16 marshalling, `GetLastError`/HRESULT as conditions, handle lifetime, struct layouts asserted at load. |

What else exists: the founding docs (above all the gap analysis, which is the design
brief), the `cons.lisp` build spec that drives `cons build | test | repl` (the
`Makefile` is gone; the per-framework `setup.sh` is interim, superseded by the
repo-root `bootstrap.lisp` + `bin/cons`), and the `.vscode` Alive auto-load config.

**The recommended next move** is the CL face + `ISeq` protocol over Coalton's
`Seq`/`hashmap`. That is the adoption story; everything else is additive.

---

## Design narrative

### The two faces, and which one gets polished first

Aion has an unresolved tension baked into its identity. The *name and thesis* are
Coalton-first, but the *adoption story* is the pure-CL face. Who is the primary v1
user — a plain-CL developer who wants coherent immutable collections and never sees
Coalton, or a Coalton developer who wants the missing idioms? The answer decides
whether `aion/cl` or the typed layer gets the polish first. **The standing lean is
CL-face-first for adoption, with the typed layer underneath**, and the invariant that
keeps this honest is: *everything in the CL face is backed by the typed layer.* Two
faces, one library — they must not drift.

A sharper version of the same question: **how much should the CL face hide Coalton?**
Should CL users ever see Coalton types — `Result`/`Optional` leaking through — or
does `aion/cl` translate fully into CL idioms (`values`/`nil`, conditions)? Full
translation is friendlier but lossy; a leaky face is more honest but asks CL users to
learn Coalton concepts they did not sign up for. This is genuinely open.

### The `ISeq` protocol: three ways to build it

The consistent sequence/collection protocol (`first`/`rest`/`cons`/`conj`/`seq`/
`into`/`count`/`get`) is Thread 1, and there are three candidate mechanisms:

- **plain CLOS generic functions** — `defgeneric` for each operation;
- **a Clojure-style `define-protocol` macro** — more familiar to Clojure refugees,
  but more machinery to build and explain;
- **leaning on CL's extensible `sequence` package** — reuses the standard, but
  inherits exactly the inconsistency the protocol exists to supersede.

**The lean is CLOS generics**: least surprise for CL users, no new metaobject work,
and nothing to teach beyond `defmethod`. `trivial-extensible-sequences` is
acknowledged as the thing `ISeq` is trying to supersede *cleanly*, rather than
extend.

### Set semantics — the equality problem

Persistent sets are the clearest structural hole, and they are also where the
two-faces design gets uncomfortable. Sets need an equality/hash notion. Riding
Coalton's `Eq`/`Hash` typeclasses is clean and typed — but then the CL face needs a
**bridge for arbitrary CL values**. How does a CL user get a set of their own structs
or CLOS objects, when the underlying structure wants a typeclass instance? This is
open, and it is the reason FSet interop is not free (see below).

### Transducers — is the type-system fight worth it?

Statically-typed transducers are Aion's most novel research angle: Clojure's
transducers are dynamic reducing-function transformers, and typing them under
Hindley–Milner is a real design problem that essentially nobody outside Clojure has
solved. The honest open question is whether this is a **marquee feature worth real
effort**, or a nice-to-have that should wait until collections and optics land. It
did not stay purely theoretical, though — the CSV work (below) was deliberately built
with a `reduced` early-termination protocol as the seam that `aion/xform` will plug
into, so the transducer face has a concrete first customer waiting for it.

### Optics — how much of the tower for v1?

Optics are "the thing people actually miss once everything is immutable." Two open
scoping calls: the full `Lens`/`Prism`/`Traversal`/`Iso` tower versus starting with
just `Lens` + `Traversal` (the 80%); and hand-written optics only versus a macro that
**derives optics from Coalton record definitions**. Coalton's type system makes
*lawful* optics natural, which is the argument for doing them properly rather than
shipping ad-hoc updaters.

### Positioning against the existing CL FP libraries

Aion is not entering an empty room, and the vision doc surveys the neighbours
carefully because positioning is the pitch:

| Library | What it is | Why it matters to Aion |
|---|---|---|
| **FSet** | Flagship functional seqs/sets/maps/bags with a *global ordering* | Mature but heavy (`misc-extensions`); its total-order equality model **fights** Coalton's `Eq`/`Hash` |
| **Sycamore** | Weight-balanced trees, persistent maps/sets, priority queues | The leanest functional option; a good benchmark baseline |
| **cl-hamt** | HAMT persistent hash-maps/sets, the `{}`/`#{}` model | Overlaps Coalton's HAMT directly — a *comparison point*, not a dependency |
| **serapeum** | Threading macros, `dict`, queue, heap | Pragmatic/mutable; prior art for the threading sugar |
| **cl-data-structures**, **cl-containers**, **rutils** | Large / classic / utility | Pragmatic-mutable neighbours |
| **trivia**, **Alexandria**, **trivial-extensible-sequences** | Pattern matching, utility belt, portable CLOS `sequence` | Adjacent vocabulary; the last is what `ISeq` supersedes |

**The resolution:** differentiate on *the Coalton backing + the typed layer + the
coherent CL face*. Borrow **algorithms and ideas** freely, but **do not take runtime
dependencies** on FSet or cl-hamt — their data models fight Coalton's `Eq`/`Hash`,
which would import exactly the equality problem §4 is trying to solve cleanly. FSet
is the one worth *interop* consideration, for CL users who already hold FSet values.

FSet and Sycamore are also the obvious **benchmark peers**. Since part of the thesis
is the empirical claim "Coalton is already peer-level," there is a live question of
whether a benchmark suite (against Clojure's persistent collections, FSet, and Rust's
`im`) should be a **first-class, early deliverable** — evidence rather than
assertion.

### Naming and the "one dependency" question

Packages are `aion/seq`, `aion/set`, `aion/xform`, `aion/optics`, `aion/lazy`,
`aion/thread`, `aion/cl`. Open: whether CL users also get a **batteries-in
convenience package** (`aion` re-exporting the common surface plus the threading
macros) so that adding one dependency and one `:local-nickname` is all it takes —
and what the intended nicknames are (`a:` for aion? `seq:`/`set:`?).

### AI-friendliness, made concrete

The house goal is "vibe-coding friendly, even for people who hate parentheses." For a
*data-structure library* specifically, that has to be cashed out in artifacts rather
than good intentions: worked before/after examples, a cheat-sheet mapping
Clojure/Rust/TypeScript idioms onto Aion, docstring-dense APIs, an LLM-oriented
`docs/llms.txt`. Which of those actually get built is still an open pick.

### CSV — the one thread that shipped, and why it belongs here

`aion/csv` looks like an odd fit for a collections library until you see the
argument: parsing and emitting CSV is a "generally needful thing," it is
`mnemosyne`'s ETL substrate, and — decisively — **no existing CL library targets
tens-of-GB, parallel, format-converting CSV work.** The landscape splits into
"correct-and-streaming" (cl-csv, fare-csv) and "small-and-fast"
(cl-simple-table, read-csv); nobody in CL does byte-level DFA parsing, mmap,
zero-copy records, or parallel chunking, so CL users shell out to DuckDB/Arrow. The
opportunity is not to beat DuckDB's C++ — it is to give CL/Coalton the *composable
native primitives* it lacks.

Aion's job is explicitly **not to be a CSV app**; it is to supply the policies,
primitives, and protocols that consuming libraries compose. That posture produced a
layered, backend-neutral architecture:

```
L0  Dialect          immutable policy value (delimiter/quote/escape/…)
L1  Parser core      pure byte/char DFA: State × input → events
L2  Sources & sinks  neutral byte-source / byte-sink protocols
L3  Record reprs     raw-slice → string-record → header-map (cheap → rich)
L4  Faces            reducible/transducer · lazy-seq/ISeq · Coalton Iterator
L5  Operations       split · project · coerce · aggregate · convert
```

The lessons borrowed from Rust's `csv` crate, DuckDB, Arrow, and the SIGMOD'19
speculative-parsing paper are the reason for that shape: **dialect is data** (one
immutable value carries every format difference, so nothing else branches on
flavour); **a byte-level FSM is the throughput key** (parse `(unsigned-byte 8)`,
defer UTF-8 decoding); **one reusable record buffer** (never cons per field in the
hot loop); a **record-representation spectrum** rather than one baked-in choice; and
the observation that **the quoted-newline problem is the whole story for
parallelism** — you cannot split on `\n`, so the options are a fast path (dialect
forbids quoted newlines), speculation (parse under both quote hypotheses, reparse
mispredictions), or an index pass. Format conversion, pleasingly, is just a different
terminal reducing function over the same row stream.

SIMD and FFI **do not change the design** — they are backends behind the same
protocol, which is precisely what "most powerful and flexible" means here. Four
implementations are planned behind one protocol: `portable` (pure-CL scalar DFA, zero
deps, the conformance oracle — **done**), `sb-simd` (native two-stage SIMD, no FFI,
SBCL-only), `zsv` (embeddable C, row-event pull), and `duckdb` (Arrow columnar, the
ETL workhorse). Two native handoff boundaries are needed as neutral protocols: a
**row-event / structural index** (native returns offsets into a Lisp-owned buffer;
fields are zero-copy slices) and a **columnar / Arrow batch** (zero-copy C Data
Interface).

A hard constraint discovered along the way: **foreign-thread callbacks are unsafe
under SBCL's GC**, so the model must be pull/batch — Lisp calls C, C returns a
buffer or an Arrow batch — with parallelism living native-side or in `lparallel` over
Lisp-owned chunks, **never** via C→Lisp callbacks.

The build order is itself an argument: `portable` first validates the protocol, the
faces, and the conformance oracle; `zsv` proves the row-event FFI boundary; `duckdb`
proves the Arrow columnar boundary; `sb-simd` comes last, on a settled protocol. And
**the conformance suite is the neutral spec** — RFC 4180 plus adversarial cases (cf.
DuckDB's Pollock robustness benchmark). Every backend must pass it, so a `Dialect`
means the same thing whether the parser is 40 lines of scalar Lisp or embedded zsv.

Error policy is where Aion's CL heritage shows: parse failures signal a
`csv-parse-error` with source position, and the *planned* restarts (`skip-row`,
`use-value`, `replace-field`, `null-field`) let the **application** pick strict /
skip-and-collect / repair. Aion never hard-codes an error mode. Non-goals are stated
flatly: not a query engine, not a dataframe, no default type inference — those belong
to consumers composing these primitives.

### The constraints that govern everything

- **Typed core in Coalton, effects and dynamism in CL** — no IO in the Coalton core.
- **Build gap-fills *on* Coalton's existing structures**, not hand-rolled trees.
- **The two faces stay in sync** — everything in the CL face is backed by the typed
  layer.
- **Prove it by consumption** — the siblings are the first customers, and the natural
  ones are `praxeon`'s budgeted context and `hyperion`'s request/response plumbing,
  which want persistent collections and optics respectively.

---

## Usage

Aion is one of six core frameworks in the Ouranos monorepo; you build the whole tree,
not this directory alone. Prerequisites: **SBCL + Quicklisp** (Coalton loads from
Quicklisp on first use).

```sh
git clone https://github.com/codelisperer/ouranos.git
cd ouranos
sbcl --dynamic-space-size 4096 --script bootstrap.lisp   # → bin/cons
```

`bootstrap.lisp` points ASDF at the whole tree and writes a source-registry drop-in,
so every REPL finds the frameworks with no symlinking. From any SBCL REPL:

```lisp
(ql:quickload :aion)
(aion:version)            ;; => "0.0.0"
```

First load compiles Coalton (a minute or so; cached afterwards). `Heap exhausted`
means SBCL was started without the larger heap — pass `--dynamic-space-size 4096`.

The CSV face is dependency-free and loads on bare SBCL with no Coalton compile:

```lisp
(ql:quickload :aion/csv)
;; dialects are values: +rfc4180+ / +excel+ / +unix+ / +tsv+ / +pipe+, derive with dialect-with
;; readers:  read-row · map-rows · do-rows · fold-rows · read-all · parse-string · read-file
;; writers:  write-row · write-rows · render-string · write-file
```

Once Thread 1 lands, the intended shape of the collections face is a single
consistent protocol — no more `elt` vs `nth` vs `aref`:

```lisp
;; illustrative — not yet implemented
(-> (aion:vec 1 2 3)          ; persistent vector, structural sharing
    (aion:conj 4)             ; -> [1 2 3 4], original unchanged
    (aion:map #'1+)           ; -> [2 3 4 5]
    (aion:into '(:list)))     ; uniform `into` across collection types
```

---

## Roadmap

Planning is live on the board and in issues — this page carries the *why*, not the
task list.

- **Board:** https://github.com/orgs/codelisperer/projects/1
- **Open `aion` issues:** https://github.com/codelisperer/ouranos/issues?q=is%3Aissue+is%3Aopen+label%3A%22pkg%3Aaion%22

## See also

- `aion/docs/coalton-gap-analysis.md` — what Coalton already gives you vs the gaps
  (the founding design brief; read it before building anything).
- `aion/docs/csv-design.md` — the full CSV architecture, backend table, and the two
  zero-copy handoff boundaries.
- `aion/docs/aion-vision.md` — the open design questions in their original form.
