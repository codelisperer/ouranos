# cons

*cons the magnificent* — **the missing project & dev tool for Common Lisp.**

`cons` is to Common Lisp what **cargo** is to Rust, **(p)npm** to Node, and the
**go** tool to Go: one friendly, opinionated front-end for creating projects,
managing dependencies, and running the build/test/repl loop — so you stop
hand-rolling a `setup.sh` + `Makefile` + symlink dance for every new project.

The name is doing real work: `cons` is the primordial Lisp constructor, and the
tool *constructs* projects.

**`cons`** is the project & dev tooling of the [Ouranos monorepo](../README.md) — one of
six co-evolving core frameworks in DAG order `aion → cons → mnemosyne → elenchon → hyperion →
praxeon`, plus [`hermes`](../hermes), a satellite leaf-lib (external integrations —
email/SMS, later payments). See the [root README](../README.md) and
[ECOSYSTEM.md](../ECOSYSTEM.md) for the
sibling overview and governance; `cons` sits second, right after [`aion`](../aion).

## The problem

CL's tooling is *fragmented*:
- **ASDF** — system definition + build (the `make`)
- **Quicklisp** — dependency *distribution* (curated, global-ish, no lockfiles)
- **ocicl** — modern dep manager with per-project lockfiles / reproducibility
- **qlot** — per-project Quicklisp pinning
- **Roswell** — impl install/version mgmt + script runner

There's no single, modern `cargo`-class front-end tying these together — so every
project reinvents its own onboarding scripts. **That boilerplate is `cons`'s reason
to exist.**

## Approach

`cons` is a thin, opinionated front-end that **delegates to the best engines and
adds DX** — it does not reinvent dependency resolution on day one.

**Real today:**
- **`cons init <name> --template {lib,cli,web,agent}`** — scaffold a project (the
  `.asd`, packages, `src/`, tests, `.gitignore`, `.vscode` Alive config, a `cons.lisp`
  build spec, README). `web` scaffolds a minimal, runnable Hyperion app.
- **`cons <target> KEY=VALUE`** — the **build-spec task runner**. A project declares its
  tasks in a root **`cons.lisp`** (a declarative, Lispy manifest); `cons build | test |
  repl | run | serve | dev …` then works identically on Linux / macOS / Windows, with no
  GNU-make dependency. Targets run in cons's warm image; `--fresh` uses a subprocess sbcl.
  **This replaces the per-project Makefile.**
- **`cons conform`** — install the AI-conformance pack (`AGENTS.md` + editor rules/skills).
- **`cons setup`** — env-bootstrap step (a stub for now).  ·  **`cons version`**.

**Planned (not built yet):**
1. **A dependency-source protocol** (neutral, pluggable) — the house style. A
   **Quicklisp** backend and an **ocicl** backend to start (work nicely with
   both); a **native `cons`** backend later, with a real resolver + lockfiles, to
   eventually make both obsolete. Adding native is *registering an implementation*,
   not a rewrite.
2. **`cons add`** and lockfiles (on top of the dependency-source protocol).

Distributed as a self-contained binary (`bin/cons`, via `save-lisp-and-die`).

## Status

**Pre-alpha (0.0.0).** Scaffolding (`cons init`), the AI-conformance pack (`cons
conform`), and the `cons.lisp` build-spec task runner are real and drive every
framework in this repo (the Makefiles are gone); dependency management is next.

**`cons/coalton-repl`** (opt-in, 38 checks) is also real and easy to miss: a headless
Coalton **eval + type-introspection engine** — read a source string in a per-session
package, decide expression vs. definition, and return the value *and* its inferred type.
It is deliberately a separate system, because it pulls Coalton and `cons` core stays
Coalton-free. It is the engine behind the desktop Coalton REPL in
[`hyperion/examples/coalton-repl`](../hyperion/examples/coalton-repl) — the visual front end
is hyperion's half, the engine is this one (ADR-0009). See
`docs/roadmap.md` and the open questions in `docs/cons-vision.md` (notably: does
`cons` itself use Coalton, or stay lean for easy bootstrapping?).

## Getting started

This framework is one of six core frameworks (plus `hermes`) in the
[Ouranos monorepo](../README.md); you build the
whole tree, not this directory alone. Prereqs: **SBCL + Quicklisp** (Coalton loads from
Quicklisp on first use).

    git clone https://github.com/codelisperer/ouranos.git
    cd ouranos
    sbcl --dynamic-space-size 4096 --script bootstrap.lisp   # → bin/cons

`bootstrap.lisp` points ASDF at the whole tree and writes a source-registry drop-in, so
every REPL can find the frameworks with no symlinking. From any SBCL REPL:

    (ql:quickload :cons)   ; cons is lean — pure CL, no Coalton; loads fast

Then, from inside any project that has a `cons.lisp` (every framework in this repo does):

    cd praxeon
    cons                       # list the project's targets
    cons build                 # compile
    cons dev HOST=0.0.0.0      # (praxeon) hot-reload + Elise web app, LAN-reachable

`bin/cons` implements `init` / `conform` / `setup` / `env` / `db-repl` / `db-url` /
`template check` / `version`, plus the
`cons.lisp` build-spec task runner (`build | test | repl | run | serve | dev …`).
