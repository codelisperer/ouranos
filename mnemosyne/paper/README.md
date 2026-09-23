# Mnemosyne paper

A LaTeX white paper describing **all** of Mnemosyne: the typed Coalton core + effectful CL
shell, backend neutrality over CL-DBI (SQLite / PostgreSQL-wire / XTDB 2), connections and
transactions, the migration runner, the HoneySQL-style data-driven query language (with
notes on the CL-vs-Clojure representation and the deliberate no-macros design), coverage vs
HoneySQL / the SQL standard / XTDB's subset, and bitemporality-as-a-capability.

Build the PDF: `./build.sh` (macOS/Linux) or `pwsh build.ps1` (Windows/any). Requires a TeX
distribution providing `latexmk`. `./build.sh clean` removes build artifacts.

PDFs and LaTeX build artifacts are git-ignored (see the repo `.gitignore`).
