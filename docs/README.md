# Ouranos docs — ecosystem-wide

Cross-cutting documentation that belongs to the **whole** ecosystem rather than to any
single framework.

Read first (they are the shared brain, kept at the root so they load in every session):
the root [`ECOSYSTEM.md`](../ECOSYSTEM.md) — thesis, the dependency DAG, the decisions
log, how-we-work — and the root [`CLAUDE.md`](../CLAUDE.md).

**Per-framework** documentation lives under each framework's own `docs/` (e.g.
[`hyperion/docs/`](../hyperion/docs/), which also owns its ADRs). This folder is only for
material that spans several frameworks and has no single home.

## What lives here

- **[getting-started.md](getting-started.md)** — for **users** building an agent-powered
  website *on* Ouranos: consume the frameworks from your own repo, run the example apps,
  deploy.
- **[contributing.md](contributing.md)** — for **developers** working on the frameworks
  themselves: build from source, the DAG rule, worktrees, tests, house style.
- **[dependencies.md](dependencies.md)** — the external dependency surface across the six
  core frameworks + hermes (quantified, with pinned versions) — held to a conscious minimum.
- **[migrations.md](migrations.md)** — the app-owned migration convention: append-only ids as
  the resume key, bring-up in every entry point (never the app factory), framework tables
  joining an app's timeline via store-less DDL, and when generated DDL beats raw SQL.
- **[benchmarking.md](benchmarking.md)** — Coalton's two compilation modes, why every
  recorded number must name the one it was measured in, and what release mode is actually
  worth (between ~1.1x and ~10x, depending entirely on the workload).
- **[ci.md](ci.md)** — what the three-OS matrix proves and what it deliberately does not:
  the gate is `verify-tree.lisp`, why the fasl cache gets no fallback, why no leg excuses
  Postgres, and why native amd64 is the only meaningful Coalton-pin signal.
- **[logging.md](logging.md)** — how the frameworks log (`aion/log`): correlation ids bound
  once at the outermost seam, which level means what, structured fields over interpolated
  strings, and the hard rule that payloads (bind params, prompts) never reach a log.
- **[vocabulary-and-layers.md](vocabulary-and-layers.md)** — the failure the DAG rule does
- [`ffi-boundaries.md`](ffi-boundaries.md) — cross at frame rate, not at data rate: where an FFI boundary belongs, measured under a 1,644 msg/sec feed.
  *not* catch: a layer depending **sideways** into whichever implementation is installed
  underneath it. Domain vocabulary living in a transport, and domain behaviour hostage to
  one — same error, opposite directions, and invisible until the implementation is swapped.

Planned, seeded as each piece is written:

- **Ecosystem overview / architecture** beyond what `ECOSYSTEM.md` carries.
- **Cross-cutting design notes** touching several frameworks at once.

Consuming products (a consuming app; the planned codelisperer website) are **separate repos**
and keep their own docs.
