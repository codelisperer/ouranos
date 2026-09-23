# CLAUDE.md — cons

Tree-wide rules are in the root `CLAUDE.md`/`AGENTS.md`, loaded with this file. Only
cons-specific notes here.

## What this is

The project and dev tool for CL — cargo/npm for Lisp. Scaffolds projects, runs the
build/test/repl loop, manages the environment. A thin front-end that delegates to ASDF and
the existing dependency engines; its own resolver comes later as an implementation, not a
rewrite. Distributed as a binary (`bin/cons`, `save-lisp-and-die`).

## Design facts

- **Dependency-source protocol** (neutral, pluggable): Quicklisp and ocicl backends now, a
  native `cons` backend later.
- `cons init` scaffolds; `cons conform` installs the AI-conformance pack (`AGENTS.md`,
  `.cursor/rules`, `.claude/skills`, a `CLAUDE.md` that imports `AGENTS.md`).
- **Two axes, not one** (`docs/templates-design.md`): *target kind* (`lib cli web desktop
  service shared-lib` — closed, versioned with cons, where platform pain lives) versus
  *template* (`saas landing admin` — open, data-driven). A template declares its kind.
  Today's four templates are `ecase` branches in `init.lisp`; that's the thing to fix.
- Bare `cons` lists what's real. The board has the rest.

## Gotchas

- Templates must not ship a literal dev port (#238): ports derive from the project name
  (FNV-1a, not `sxhash`, which isn't stable across SBCL versions), and `start` refuses a
  port already answering — by connecting, not binding.
- `cons` warns when a consuming app's framework checkout is behind its remote (#240); the
  comparison's *age* is reported, because `@{u}` only moves on fetch.
- `setup.ps1`'s pin parser matches `[A-Z_]+` — a pin name with a digit is silently dropped.

## Open questions

`docs/cons-vision.md`: Coalton or lean; native dep-source model and lockfile format; CLI
framework; Roswell interop.
