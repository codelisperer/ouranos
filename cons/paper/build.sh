#!/usr/bin/env sh
# Build the paper PDF. No make (LaTeX-on-Windows is the dealbreaker); pairs with build.ps1.
set -e
cd "$(dirname "$0")"
if [ "$1" = "clean" ]; then exec latexmk -C main.tex; fi
latexmk -pdf -interaction=nonstopmode main.tex
