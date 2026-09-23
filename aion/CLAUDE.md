# CLAUDE.md — Aion

Tree-wide rules are in the root `CLAUDE.md`/`AGENTS.md`, loaded with this file. Only
aion-specific notes here.

## What this is

A Coalton-first functional standard library for CL — immutable/persistent data and the
functional vocabulary for it. The foundation every other framework leans on.

## The crucial context

Coalton's stdlib already has persistent `Seq` (RRB), HAMT `hashmap`, `ordmap`, a lazy
`Iterator`, the full typeclass tower and monad transformers. **Aion is not "reimplement
Clojure."** It is (1) a pure-CL face over those collections with an `ISeq`-style protocol,
and (2) the genuine gaps: persistent sets, transducers, optics, memoized lazy-seq, `Monoid`,
itertools, threading sugar. Measure against `docs/coalton-gap-analysis.md` before adding.

What aion's own Coalton is *for* (`docs/coalton-story.md`): untyped external vocabularies —
libuv integers, logger keywords, CSV characters — become typed values **once, at the
boundary**, never inside a hot loop. `aion/uv/types.lisp` is the worked reference.

## Gotchas

- `aion/uv` is opt-in and needs a C compiler: `scripts/build-libuv.lisp`. Its suites run
  under `OURANOS_WITH_UV`; `aion/pool` is deliberately *not* under uv so it's in the default
  gate.
- Core `aion` depends on nothing; consumers that want logging depend on `aion/log`.
- `aion/random` is the CSPRNG; `#95`'s guard rejects `cl:random` and seeded generators
  across `hyperion/src`, including in comments.

## Where to look

`docs/coalton-gap-analysis.md` · `docs/coalton-story.md` · `docs/aion-vision.md` ·
[`../docs/wiki/Framework-Aion.md`](../docs/wiki/Framework-Aion.md).
