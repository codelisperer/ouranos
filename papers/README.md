# Ouranos papers

Ecosystem-wide write-ups — the whole-family thesis (the "CL all the way down" /
codelisperer argument, and how the six core frameworks — plus **hermes**, the satellite
leaf-lib — compose).

Each **framework** also keeps its own paper under `<framework>/paper/`, so a paper
travels with its framework on a future `git subtree split`:

- [`aion/paper`](../aion/paper) — the Coalton-first functional stdlib argument
- [`cons/paper`](../cons/paper) — cargo-for-Lisp project tooling
- [`elenchon/paper`](../elenchon/paper) — Cause-Effect Graphs / Requirements-Based Testing
- [`hyperion/paper`](../hyperion/paper) — an HTMX-first CL web framework
- [`praxeon/paper`](../praxeon/paper) — praxeological agentic AI

(`mnemosyne` and `hermes` have no paper yet.)

## Building (no make)

Every paper builds with a cross-platform script pair — `./build.sh` (macOS/Linux) or
`pwsh build.ps1` (Windows/any). Both wrap `latexmk`, require a TeX distribution, and
accept an optional `clean` argument. LaTeX tooling stays **out of `cons`'s scope** by
design (LaTeX-on-Windows was the original reason to drop `make`).
