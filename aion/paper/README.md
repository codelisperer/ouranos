# Aion paper

A LaTeX write-up of Aion's value proposition (skeleton; fill in the sections).
The argument tracks `docs/coalton-gap-analysis.md`: Coalton already ships the
persistent-collection substrate, so Aion's contribution is a consistent CL-facing
protocol over it plus the genuine gap-fills.

Build the PDF: `./build.sh` (macOS/Linux) or `pwsh build.ps1` (Windows/any). Requires
a TeX distribution providing `latexmk`. `./build.sh clean` removes build artifacts.

PDFs and LaTeX build artifacts are git-ignored (see the repo `.gitignore`).
