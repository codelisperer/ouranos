#!/usr/bin/env pwsh
# Build the paper PDF. No make (LaTeX-on-Windows is the dealbreaker); pairs with build.sh.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
if ($args[0] -eq 'clean') { latexmk -C main.tex; exit }
latexmk -pdf -interaction=nonstopmode main.tex
