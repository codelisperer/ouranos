# Praxeon — paper

A journal-style write-up of the Praxeon value proposition.

## Build

Build the PDF: `./build.sh` (macOS/Linux) or `pwsh build.ps1` (Windows/any). Requires
a TeX distribution providing `latexmk`. `./build.sh clean` removes build artifacts.

Requires a TeX distribution (TeX Live / MacTeX). The skeleton uses only stock
packages, so it builds out of the box; no venue class files are required.

## Authoring

You can draft prose in `main.tex` directly, or write sections in Markdown/org and
convert with pandoc, e.g.:

```sh
pandoc section.md -o section.tex
```

then `\input{section}` from `main.tex`.

## Targeting a venue

Swap the class line at the top of `main.tex`:

- **ACM** — `\documentclass[sigconf]{acmart}` (e.g., for a SIGPLAN-adjacent venue)
- **IEEE** — `\documentclass[conference]{IEEEtran}`
- **LNCS** — `\documentclass{llncs}` (common for symposium proceedings)

The European Lisp Symposium (ELS) is a natural home for the Common Lisp/Coalton
angle; check its current author kit for the exact class and length limits.

## Structure

The section outline mirrors the argument: Python's misdiagnosed dominance → a
praxeological model of agency → the Lisp/Coalton case → the Praxeon architecture
→ the Elise case study → Kairos (bitemporal context) → related work → an
evaluation plan. Each section carries comment stubs marking what to expand.
