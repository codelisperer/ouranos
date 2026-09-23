# Elenchon paper

A LaTeX write-up of Elenchon's value proposition (skeleton; fill in the sections).
The argument tracks `docs/method.md`: requirements are where defects are born, CEG/RBT
is the corrective, and an LLM front-end under rigor (condition-system-handled
ambiguity) closes the manual-formalization gap that has limited its adoption.

Build the PDF: `./build.sh` (macOS/Linux) or `pwsh build.ps1` (Windows/any). Requires
a TeX distribution providing `latexmk`. `./build.sh clean` removes build artifacts.

PDFs and LaTeX build artifacts are git-ignored (see the repo `.gitignore`).
