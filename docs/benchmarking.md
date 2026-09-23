# Benchmarking — and why every number here names its mode

Coalton compiles in one of two **global** modes, fixed by `COALTON_ENV` before Coalton
itself is built. Development (the default) keeps most types as redefinable CLOS objects and
disables optimizations that obscure debugging; release freezes them into flattened
`defstruct`s and optimizes. It is a property of the **build**, not of a system — Coalton's
stdlib included — so it cannot be switched inside a running image.

Until #98, **Ouranos ran entirely in development mode and had never been built in release
mode.** Every performance number the project had was therefore measured in the slower of the
two, and none of them said so.

## Running a benchmark

```sh
sbcl --dynamic-space-size 4096 --script scripts/with-mode.lisp dev     scripts/bench.lisp
sbcl --dynamic-space-size 4096 --script scripts/with-mode.lisp release scripts/bench.lisp
```

`with-mode.lisp` gives **each mode its own fasl cache**. That is not tidiness:
`:coalton-release` is a *feature*, and ASDF's default output translations do not encode
features in the fasl path — so a release-mode run against the ordinary cache happily loads
development fasls and reports a release number for a development build. Two caches make the
modes independent and repeatable; clearing one cache would make them alternate expensively
and still share a namespace.

Both modes are isolated, not just release. A development baseline drawn from whatever the
developer's last REPL left behind is not a controlled comparison.

`bench.lisp` reads the mode from the **running image** (`coalton-release-p`), not from
`COALTON_ENV` — the variable is what was asked for, the predicate is what was built — and
**refuses to run if they disagree**.

## What release mode is worth

Measured 2026-08-25, Linux/WSL, SBCL 2.6.7, 200 iterations, warm, GC'd between phases.

One run, all workloads measured together so the numbers are internally consistent.

| workload | development | release | ratio |
|---|---|---|---|
| `aion/csv/types:parse-rfc4180-rows` — 1,000-row CSV | 18.661 ms/op | **1.940 ms/op** | **9.6×** |
| — allocation | 8,497,978 B/op | 6,118,620 B/op | 1.39× |
| `hyperion/path:path-matches?` — one route match | 0.001000 ms/op | 0.000720 ms/op | 1.39× |
| `aion/log/types:render-event-line` — one structured log line | 0.007360 ms/op | 0.005560 ms/op | 1.32× |
| `aion/csv:parse-string` (pure CL, **control**) | 0.640 ms/op | 0.600 ms/op | 1.07× |

**The honest headline is the spread, not the best number.** Release mode is worth anywhere
between ~1.1× and ~10× depending on how much of a workload's time goes into ADT
construction and matching — the thing the mode actually changes. The CSV parser is a dense
state machine over `CharClass` / `ParseState` / `Action` / `Step`; the log renderer is
string building. Quoting the 9.9× alone would be an advertisement.

Two things about reading this table:

- **The control is what makes it a measurement, and it is also the thing that tells you
  which rows to distrust.** `aion/csv:parse-string` is pure CL and deliberately
  Coalton-free, so the mode cannot move it: every point by which it differs between two
  halves of a pair is measurement noise, not signal. Observed drift across runs of this
  suite has ranged from **0% to 7%** — it was identical in one pair and 1.07× apart in
  another.

  That puts the CSV row (9.6×, and 9.3–9.9× across three separate runs) far outside the
  noise and the other two rows barely outside it. **Treat the 1.3-ish ratios as
  indicative only.** They are the right order of magnitude — small — and they are not
  precise. An earlier run of this suite put the log renderer at 1.13× where this one says
  1.32×; the difference between those two figures is mostly the machine.
- **The CL and Coalton parsers are different implementations** of the same job — a stream
  DFA versus a char-list DFA. The pair is a reference point, **not** a "Coalton versus CL"
  comparison, and must not be quoted as one.

### What this means for the performance claims already published

`README.md`, `ECOSYSTEM.md` and [`working-with-ai.md`](working-with-ai.md) quote the
ADR-0011 delayed-ACK finding: **44.00 ms** per request against Woo's **0.15 ms**, and
**0.17 ms** for the same server once a `Content-Length` header was added. Like everything
else in this repo before #98, those were measured in development mode and do not say so.

**They survive.** The router is the only Coalton on that request path, and at ~1 µs it is
**0.7% of the 0.15 ms figure**; the mode moves it by 0.28 µs, or **0.19% of the claim**.
The 44 ms is a kernel-level stall from a chunked-encoding terminating write meeting Nagle's
algorithm, and cannot care how an ADT is represented.

So those numbers need a mode named, not a retraction. This was checked rather than argued:
the cheap way to test whether a published number can move is to measure the part of it that
*can* move and compare the magnitudes, instead of restaging the whole HTTP benchmark.

## Release mode passes the suite

The whole tree loads and passes in release mode — **2376 checks across 42 isolated images,
`VERDICT: PASS`**, the same count development mode reports, with Postgres coverage at 23
checks per backend.

```sh
scripts/test-postgres.sh up
eval "$(scripts/test-postgres.sh env)"
sbcl --dynamic-space-size 4096 --script scripts/with-mode.lisp release scripts/verify-tree.lisp
```

This is worth stating as the **negative result** it is. #98 expected to find latent
representation assumptions — code that inadvertently depends on development mode's
behaviour, which is invisible until the mode flips. **None surfaced.** The §7 rule (a `lisp`
block may only traffic in promised types) appears to have held across the tree.

That is evidence, not proof: one platform, one run. What keeps it true is the CI leg, not
this paragraph.

## The rule

**Any recorded performance number states its mode.** A number without one is not a
conservative claim, it is an unreadable one — the reader cannot tell whether they are
looking at a floor or a ceiling, and the two are an order of magnitude apart on ADT-heavy
code.

A claim aimed at outsiders is measured in **release** mode. A number used to compare two
implementations of ours may be measured in either, as long as both sides were measured in
the same one and it is named.
