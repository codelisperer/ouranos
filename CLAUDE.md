# CLAUDE.md — Ouranos (monorepo root)

Constitution for the **codelisperer** framework monorepo. Always loaded; kept lean.

@AGENTS.md

The tool-neutral conformance spec (DAG, house style, Coalton rules, the AI-task/GitHub-issues
policy, confidentiality) is [`AGENTS.md`](AGENTS.md), imported above. **Read
[`ECOSYSTEM.md`](ECOSYSTEM.md)** for the cross-machine shared brain (thesis, decisions log,
how-we-work). Each framework keeps its own `CLAUDE.md` (e.g. `hyperion/CLAUDE.md`) as its
sub-guide. This file adds the Ouranos runtime specifics below.

## What this is

**Ouranos** = one repo holding six co-evolving CL/Coalton core frameworks:
`aion · cons · mnemosyne · elenchon · hyperion · praxeon`, plus **hermes** — a
satellite leaf-lib (external integrations: email/SMS now, payments later). **CL all
the way down**, biased to the live SBCL image; a reaction to JVM/Node dependency
sprawl. Apps (consuming apps, etc.) are **separate repos** that consume these.

## The one hard rule

**Dependency order is a DAG, low → high:**
`aion → cons → mnemosyne → elenchon → hyperion → praxeon`.
A framework never depends on one to its **right** (ASDF errors on cycles). Aux
systems (e.g. `praxeon/web → hyperion`) may reach right; **core** systems may not.
Combined apps/examples live in the **highest** framework they need.
**Satellites sit outside this line** — they depend leftward into it and nothing in the
line depends on them. `hermes` (integrations) and `hades` attach at `aion`; `klio` (the
git-backed content engine) attaches at `hyperion`.

## Build / run — no external build tools

```sh
scripts/setup.sh          # (or setup.ps1) install SBCL + Quicklisp + Coalton at the pins — WORKS
sbcl --dynamic-space-size 4096 --script bootstrap.lisp   # → bin/cons  (identical on every OS) — WORKS
bin/cons build|test|serve|run …                          # from one root spec — INTENDED, in progress
```

Today: `scripts/setup.sh` provisions a bare machine (SBCL, Quicklisp, Coalton, libev), then
the seed (`bootstrap.lisp` → `bin/cons`) builds the tree; it also writes an ASDF `(:tree)`
source-registry drop-in so every REPL finds the tree with no symlinking. Verify the
provisioning step on an operating system that has none of it with
`scripts/verify-clean-machine.sh` (a container; CI cannot cover this, because runners arrive
with a toolchain). The `bin/cons build|test|serve|run` surface is still the target — cons
currently
implements `init` / `setup` / `conform` / `env` / `db-repl` / `db-url` / `template check` /
`version`, plus a per-framework task runner: each
framework ships a root `cons.lisp` build spec driven by `cons <target>` (run from inside the
framework's dir — bare `cons` lists targets, then `cons build` / `test` / `repl`, etc.). This
replaced the per-framework `Makefile`s, which have been removed.

No make / just / nmake anywhere — `sbcl --script` is uniform across Linux/macOS/
Windows, and `bin/cons` (a warm image) drives the tree. **SBCL-exclusive** by design.

## Parallel work

Use **git worktrees**: `git worktree add ../ouranos-<track> -b work/<track>`, open
each as its own window/agent on its own branch, merge to `main` when green. The main
checkout is the integration hub. One repo per worktree branch — no cross-branch edits.

## AI / system tasks → GitHub issues

AI/system task handoffs are **GitHub issues** (label `ai-task`), not files in the tree — see
[`AGENTS.md`](AGENTS.md) for the policy + the per-ticket agent-identity rule. The retired
`docs/tasks/` inbox is being removed. Inbox: `gh issue list --label ai-task --state open`.

## Memory (don't lose the thread across machines)

- **Committed** (`ECOSYSTEM.md`, project `CLAUDE.md`s, `docs/`) = the cross-machine
  brain. If it must survive a new machine or a fresh session, **it goes here**.
- `~/.claude` auto-memory = **machine-local, private** (personal motivation, hard-won
  gotchas). Never rely on it cross-machine; promote durable facts into committed docs.

## Conventions

- Typed **Coalton** core + effectful **CL/CLOS** shell; **no IO in Coalton**.
- Pluggable backends behind **neutral protocols**; recoverable failure via the
  **condition system**, not return codes.
- Small pure functions, effects at the edges, **ADTs over booleans**.
- **Plain prose everywhere** — commit messages, PR text, issues, docstrings, comments, docs.
  No aphorisms, no metaphors, no memorable one-liners; say what happened and what to do.
  Full rule and worked examples in [`AGENTS.md`](AGENTS.md), "Writing".
- Package-per-module; `:local-nicknames` over long prefixes. 2-space indent, no
  trailing whitespace. Docs-as-handoff: current status lives on the
  [Roadmap board](https://github.com/orgs/codelisperer/projects/1) / issues (filter
  `label:pkg:<framework>`) — no hand-maintained Status block; the design narrative lives in
  [`docs/wiki/`](docs/wiki/Home.md) (e.g. [`Framework-Aion.md`](docs/wiki/Framework-Aion.md));
  `CLAUDE.md` + the vision/design docs stay the always-loaded constitution.
- **LF line endings, enforced by root `.gitattributes`** (`* text=auto eol=lf`;
  Windows `.ps1/.bat/.cmd` keep CRLF). Never write a `FORMAT ~<newline>`
  continuation — on a CRLF checkout it becomes an illegal `~<Return>` directive
  that SBCL reports as a compile-time "macroexpansion" error. Fold the control
  string onto one line instead. (See ECOSYSTEM.md decisions log.)
