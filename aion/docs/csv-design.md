# CSV in Aion — a backend-neutral design

*Why Aion ships CSV, what the CL landscape offers, and the layered, backend-
neutral architecture that lets one protocol span a 40-line scalar parser and an
embedded SIMD engine. Cross-reference: [`coalton-gap-analysis.md`](coalton-gap-analysis.md)
(CSV is the first real customer of transducers, lazy-seq, and `Monoid`).*

## Why this belongs in Aion

Parsing and emitting CSV is a "generally needful thing" — every app touches it,
and `mnemosyne` needs it for ETL (split huge files, convert formats). Aion's job
is **not** to be a CSV app; it is to provide the *policies, primitives, and
protocols* that consuming libraries compose into domain solutions. The same
posture as the rest of Aion: small pure primitives, effects at the edges,
pluggable backends behind neutral protocols, and **two faces — CL-only and
Coalton — over one core.**

## The CL landscape (what exists)

No existing CL library targets tens-of-GB, parallel, format-converting CSV work.
They split into "correct-and-streaming" and "small-and-fast," none into
"industrial":

| Library | Strengths | Limits |
|---|---|---|
| [cl-csv](https://github.com/AccelerationNet/cl-csv) | De-facto standard; streaming `row-fn`; best error reporting; configurable | Char/`read-line` oriented, per-field consing → mid-pack throughput; single-threaded; no zero-copy/mmap/parallel |
| [fare-csv](https://github.com/fare/fare-csv) | Correctness-first; many dialect variants | Not performance-oriented; single-threaded |
| [cl-boost/csv](https://github.com/cl-boost/csv) | Fast, stream-based | Minimal feature surface |
| cl-simple-table / read-csv | Fastest in the informal [benchmark](https://sites.google.com/site/sabraonthehill/reading-csv-benchmarks) | Minimal; loads into memory; weak on edge cases |

The takeaway: **nobody in CL does byte-level DFA parsing, mmap, zero-copy records,
or parallel chunking.** For real big-data work CL users shell out to DuckDB/Arrow.
That gap is Aion's opportunity — not to beat DuckDB's C++, but to give CL/Coalton
*composable native primitives* it lacks.

## What the industrial parsers teach

From Rust's `csv` crate, DuckDB, Arrow, and the
[SIGMOD'19 speculative-parsing paper](https://badrish.net/papers/dp-sigmod19.pdf):

- **Dialect is data** — RFC 4180 + variants reduce to a value (delimiter, quote,
  escape, terminator, trim, comment, quoting policy).
- **A byte-level finite state machine is the throughput key** — parse
  `(unsigned-byte 8)`, defer UTF-8 decoding. DuckDB and the `csv` crate are both
  byte DFAs.
- **One reusable record buffer** — amortize allocation; never cons per field in
  the hot loop (Rust's `ByteRecord`).
- **A record-representation spectrum** — zero-copy byte-slice record (defer
  decode) vs decoded string record vs header-keyed map. Not one baked-in choice.
- **The quoted-newline problem is the whole story for parallelism** — you cannot
  split on `\n` ([DuckDB #7706](https://github.com/duckdb/duckdb/issues/7706)).
  Three strategies: **fast path** (dialect forbids quoted newlines → split
  anywhere), **speculative** (guess boundaries, parse under both quote hypotheses,
  reparse mispredictions), **index pass** (one scan builds a boundary index, then
  parallel typed parse).
- **Format conversion is just a different sink** — CSV→TSV/JSONL/EDN/Arrow =
  swapping the terminal reducing function over the same row stream.

## The architecture — one protocol, layered

SIMD and FFI do **not** change the design; they are *backends behind the same
protocol*. "Most powerful and flexible" **is** backend-neutrality: the L4 faces
stay identical while the parsing core swaps.

```
L0  Dialect          immutable policy value (delimiter/quote/escape/…)   [pure Aion]
L1  Parser core      pure byte/char DFA: State × input → events          [the primitive]
L2  Sources & sinks  neutral byte-source / byte-sink protocols           [effects at edges]
L3  Record reprs     raw-slice → string-record → header-map (cheap→rich) [pay for what you use]
L4  Faces            reducible/transducer · lazy-seq/ISeq · Iterator      [CL & Coalton]
L5  Operations       split · project · coerce · aggregate · convert       [composable, as xforms]
```

- **L0 Dialect** — one immutable value carries every format difference; nothing
  else branches on flavour. Presets `+rfc4180+`, `+excel+`, `+unix+`, `+tsv+`,
  `+pipe+`; derive with `dialect-with`.
- **L1 Parser core** — a pure step function, deterministic, no IO; reusable by any
  driver (sync, chunked, parallel). Fast, testable, backend-swappable.
- **L2 Sources & sinks** — `byte-source`/`byte-sink` protocols; backends: buffered
  stream (portable default), mmap (`sb-posix` / `static-vectors`), gzip/zstd,
  in-memory, socket. House style.
- **L3 Record representations** — ordered cheap→expensive; the consumer picks.
- **L4 The three faces over one core** *(the CL-or-Coalton answer)* —
  - **Reducible/transducer source**: rows as a reducible so `aion/xform` composes
    directly (`transduce (comp (filter …) (map …) (take …)) sink source`).
    Streaming, no materialization. *This is the "policies apps compose" answer.*
  - **Lazy-seq / ISeq** (`aion/cl`, `aion/lazy`): `first`/`rest`/`doseq` for CL
    users, no Coalton required.
  - **Coalton `Iterator`** for typed consumers.
- **L5 Operations, built as transducers/reducers** — `record-boundaries`
  (quote-aware safe offsets, fast path when no quoted newlines), `pmap-file`
  (split → parse chunks on threads → merge via **`Monoid`**), column
  select/coerce as transducing maps, conversion **sinks** (`->jsonl`, `->edn`,
  `->arrow`, `row-count`).

### Two native handoff boundaries

A native backend hands results to Lisp at one of two granularities — Aion needs
both as neutral protocols:

1. **Row-event / structural index** — native stage returns *offsets* into a buffer
   Lisp owns; fields are zero-copy slices. Fits `zsv`, `simdcsv`, `csv-core`.
   simdjson two-stage: SIMD finds delimiter/quote/newline bitmasks; **quote parity
   via `popcount`** resolves inside/outside-quote branch-free (and gives the safe
   split points for free).
2. **Columnar / Arrow batch** — native engine returns typed columns via the
   [Arrow C Data Interface](https://arrow.apache.org/docs/format/CDataInterface.html)
   (zero-copy ABI). Fits DuckDB/Arrow/Polars; best "convert to any format" story.

L4 transducers work over either — row-wise for (1), column-wise (an Arrow-batch
reducible) for (2).

### Zero-copy handoff mechanics

Never copy the 10 GB: `sb-posix:mmap` the file → foreign base pointer + length;
`static-vectors` for any Lisp buffer C must see (pinned `(unsigned-byte 8)`, no
marshalling); native stage returns offsets or Arrow arrays; Lisp materializes a
field only when the consumer pulls it. (Note: `cl-duckdb` copies on *ingest* but
DuckDB→Lisp via Arrow is cheap — use DuckDB as reader/converter, not a row sink.)

## Backends — one protocol, four implementations, opt-in muscle

| Backend | Buys | Cost | Handoff | System |
|---|---|---|---|---|
| **`portable`** *(done)* | Pure-CL scalar DFA; zero deps; the conformance oracle | Char-stream speed only | Row objects | `aion/csv` |
| **`sb-simd`** | Native SBCL two-stage SIMD; no FFI; also powers safe parallel split | SBCL-only | Structural index | `aion/csv-simd` |
| **`zsv`** | [zsv](https://github.com/liquidaty/zsv) — "world's fastest SIMD CSV," embeddable C, all edge cases | C artifact per platform | Row-event (pull) | `aion/csv-zsv` |
| **`duckdb`** | [cl-duckdb](https://github.com/ak-coram/cl-duckdb): parallel, sniffing, glob, gzip/zstd, type inference, Parquet/JSON/Arrow out — the mnemosyne ETL workhorse | Heavy dep | Arrow columnar | `aion/csv-duckdb` |

SIMD needs runtime CPU dispatch (AVX2/AVX-512/NEON) with the scalar path as floor.
**Foreign-thread callbacks are unsafe** under SBCL GC — use the pull/batch model
(Lisp calls C, C returns a buffer/Arrow batch); parallelism lives native-side or
in `lparallel` over Lisp-owned chunks, never via C→Lisp callbacks.

## Policies Aion codifies (but does not decide for the app)

- **Error policy via the condition system** — Aion's CL superpower. v1 signals
  `csv-parse-error` with source position; restarts (`skip-row`, `use-value`,
  `replace-field`, `null-field`) are the planned extension so the *app* picks
  strict / skip-and-collect / repair. Never hard-code an error mode.
- **Encoding** — byte-first, decode lazily; configurable external-format.
- **Quoting/escaping on write** (`:minimal` / `:all` / `:none`), **newline**
  (`:crlf` / `:lf` / `:cr`), **header**, **blank-line**, **trim** policies — all
  on the dialect.
- **Bounded memory by default** — streaming; materialization is an explicit sink.

**Non-goals:** not a query engine, not a dataframe, no default type inference —
those belong to mnemosyne/elenchon/apps composing these primitives.

## The conformance suite is the neutral spec

RFC 4180 + adversarial cases (cf. DuckDB's
[Pollock robustness benchmark](https://duckdb.org/2025/04/16/duckdb-csv-pollock-benchmark)).
*Every backend must pass it*, so a `Dialect` means the same whether the parser is
40 lines of scalar Lisp or embedded zsv. The suite is Aion's spec; backends plug
in. Seeded in [`tests/csv.lisp`](../tests/csv.lisp).

## Status

- **Done:** L0 `Dialect` (+ presets, `dialect-with`), L1/L2 `portable` scalar-DFA
  **reader** (`read-row`/`map-rows`/`do-rows`/`fold-rows`/`read-all`/`parse-string`/
  `read-file`) and **writer** (`write-row`/`write-rows`/`render-string`/`write-file`),
  the `reduced` early-termination protocol (the `aion/xform` seam), and the
  conditions. Dependency-free `aion/csv`; 24 conformance tests green.
- **Next:** (1) reducible/transducer face once `aion/xform` lands; (2) conversion
  sinks (`->jsonl`, `->edn`); (3) `record-boundaries` + `pmap-file` + `Monoid`
  merge for large files; (4) `zsv` FFI (row-event boundary, `static-vectors`/mmap);
  (5) `duckdb` (Arrow columnar boundary); (6) `sb-simd` native — the crown jewel,
  once the protocol is stable.

Build order rationale: `portable` first validates the protocol, the faces, and the
conformance oracle; `zsv` proves the row-event FFI boundary; `duckdb` proves the
Arrow columnar boundary; `sb-simd` comes last, on a settled protocol.
