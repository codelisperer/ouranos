# ADR-0001 — Consolidate the ecosystem into Hyperion (library + CLI)

**Status:** Superseded by [ADR-0007](0007-split-into-six-frameworks-monorepo.md) — 2026-07-21

> **Superseded.** This decision (fold `aion`/`cons` into Hyperion, ship a `hyperion`
> CLI) was reversed when the six frameworks were unified under the **Ouranos monorepo**:
> one repo removes the multi-repo coordination cost this ADR was trading against, while
> keeping each framework conceptually distinct with its own `.asd`. `cons` owns all
> project tooling; Hyperion is a library, not a CLI. The body below is retained
> unchanged as the historical record of why consolidation was tried. See ADR-0007.

## Context

The plan was a five-project ecosystem: `cons` (tooling / project manager),
`hyperion` (web), `aion` (FP core), `praxeon` (agentic AI), `elenchon` (testing).
Standing up and coordinating five repos this early created too many moving parts
for one maintainer, slowing the actual goal (get a prior Clojure/Kit app ported and running).

## Decision

**Hyperion is both a library and a CLI, and for now hosts the concerns once slated
for `aion` (FP core) and `cons` (tooling / project manager)** — in-project — until
a clear pattern and reason to decouple emerges.

- The CLI (`hyperion` — cargo-for-Lisp: `init`/`repl`/`build`/`test`/`add`/
  `serve`/`deploy`) lives in a separate `hyperion/cli` ASDF system so the library
  never pulls the CLI deps (clingon). Binary via `make cli`.
- FP and tooling code grows under `hyperion/fp`, `hyperion/tool` as needed — **not**
  as new repos.
- `praxeon` remains its own project (consumes Hyperion for its web surface);
  `elenchon` remains planned.

## Consequences

- Fewer repos to juggle; one place to look. A consuming app depends mainly on Hyperion.
- Hyperion's scope is deliberately broad and will feel "unfocused" for a while;
  that is the accepted trade for lower coordination overhead now.
- Re-evaluate a split when a concern clearly wants its own release cadence,
  dependency set, or external consumers. A future ADR records any extraction.

## Alternatives considered

- **Keep five separate repos.** Rejected now: coordination cost dominates while
  everything is pre-1.0 and has a single maintainer.
- **Fold everything including praxeon into one repo.** Rejected: praxeon has a
  distinct domain (agentic AI) and already exists independently.
