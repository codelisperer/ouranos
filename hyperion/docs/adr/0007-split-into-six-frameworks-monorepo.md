# ADR-0007 — Split back into six frameworks under the Ouranos monorepo

**Status:** Accepted — 2026-07-21 (supersedes [ADR-0001](0001-consolidate-into-hyperion.md))

## Context

[ADR-0001](0001-consolidate-into-hyperion.md) folded `aion` (FP core) and `cons`
(tooling) into Hyperion and gave Hyperion its own cargo-like CLI, to avoid the
coordination cost of standing up five separate repos under a single maintainer. That
trade bought fewer moving parts at the price of a deliberately "unfocused" Hyperion.

The coordination cost, not the conceptual overlap, was the real problem — and a
**monorepo** removes it directly: one repo, one history, atomic cross-cutting commits,
one `bootstrap.lisp` seed, while each framework keeps its own conceptual boundary and
`.asd`. With that in hand, the reasons to keep the concerns *merged inside Hyperion*
fall away, and the downsides of the merge (broad scope, a per-framework CLI competing
with the dedicated tooling framework) become pure cost.

## Decision

The six frameworks live as **distinct top-level directories in the Ouranos monorepo**,
each its own ASDF system, in the strict dependency DAG
`aion → cons → mnemosyne → elenchon → hyperion → praxeon` (a framework never depends on
one to its right; aux systems may reach right if acyclic).

- **`aion`** and **`cons`** are their own frameworks again — *not* `hyperion/fp` /
  `hyperion/tool`.
- **`cons` owns all project tooling** (`init` / `build` / `test` / `serve` / `run` /
  deps). **Hyperion is a library, not a CLI** — the `hyperion/cli` system is retired as
  cons reaches parity. Hyperion may supply web-app *templates*; `cons` supplies the
  machinery.
- Build/discovery is uniform and make-free: `sbcl --script bootstrap.lisp` → `bin/cons`,
  plus an ASDF `(:tree)` source-registry drop-in that replaces per-project
  `local-projects` symlinks (see ECOSYSTEM.md).
- Apps/examples that combine frameworks live in the highest framework they need
  (e.g. Elise, ChatRBT under `praxeon/`). Consuming products (a separate consuming repo) stay separate
  repos.

## Consequences

- Each framework regains a focused scope and can be reasoned about (and eventually
  split out via `git subtree split`) independently, without the multi-repo overhead that
  motivated ADR-0001.
- Hyperion sheds its tooling/FP scope and its CLI; docs that described the "absorb" stance
  or a `hyperion` command are corrected to the monorepo + cons model.
- There is a transition window: `cons build|test|serve|run` are not yet implemented, so
  the per-framework `Makefile`s remain the interim build path (clearly labeled) until cons
  reaches parity, at which point they are removed.

## Alternatives considered

- **Keep the ADR-0001 consolidation.** Rejected: the monorepo already eliminates the
  coordination cost that justified it, leaving only its downsides (unfocused Hyperion, a
  CLI competing with cons).
- **Six separate repos again.** Rejected: reintroduces exactly the multi-repo coordination
  overhead ADR-0001 fled; the monorepo keeps the frameworks distinct without it.
- **Fold everything, including praxeon, into one framework.** Rejected: erases the
  conceptual boundaries the DAG depends on.
