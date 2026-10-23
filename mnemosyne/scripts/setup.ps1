#!/usr/bin/env pwsh
# INTERIM — superseded by `bin/cons` once build/test/serve/run land (see ECOSYSTEM.md
# and hyperion/docs/adr/0007). Kept only as the working path until cons reaches parity;
# do not extend. Discovery is handled by bootstrap.lisp's source-registry drop-in.
#
# scripts/setup.ps1 -- one-time Windows provisioning so a fresh clone of Mnemosyne loads.
# Idempotent. Does NOT install SBCL/Quicklisp -- checks and tells you how.
#   1. Check that Coalton is at the commit coalton.pin names (scripts\coalton-pin.ps1).
#      The monorepo's scripts\setup.ps1 is what clones it.
# A SQLite file (then Postgres / XTDB 2) is needed later for the connection work.
# Usage:  pwsh scripts/setup.ps1 [-Test]

param([switch]$Test)
$ErrorActionPreference = 'Stop'

function Info($m) { Write-Host "==> $m" -ForegroundColor Blue }
function Die($m)  { Write-Error $m; exit 1 }

if (-not (Get-Command sbcl -ErrorAction SilentlyContinue)) {
  Die "SBCL not found (e.g. 'choco install sbcl', or scoop)."
}
$QlHome  = if ($env:QUICKLISP_HOME) { $env:QUICKLISP_HOME } else { Join-Path $HOME 'quicklisp' }
$QlSetup = Join-Path $QlHome 'setup.lisp'
if (-not (Test-Path $QlSetup)) { Die "Quicklisp not found at $QlSetup (https://www.quicklisp.org/beta/)." }
Info "SBCL present  |  Quicklisp at $QlHome"

# Coalton: checked here, never cloned. scripts\coalton-pin.ps1 at the monorepo root stops with
# what to run when the checkout is missing or not at the commit coalton.pin names (#751).
& (Join-Path $PSScriptRoot '..\..\scripts\coalton-pin.ps1')
if ($LASTEXITCODE -ne 0) { exit 1 }

Info "Discovery: run ``sbcl --script bootstrap.lisp`` at the repo root (writes the ASDF drop-in)."

if ($Test) {
  Info "Loading Mnemosyne (first run compiles Coalton; a few minutes)..."
  $heap = if ($env:MNEMOSYNE_DYNAMIC_SPACE_SIZE) { $env:MNEMOSYNE_DYNAMIC_SPACE_SIZE } else { '4096' }
  $ql = ($QlSetup -replace '\\','/')
  sbcl --dynamic-space-size $heap --non-interactive `
    --eval "(load `"$ql`")" `
    --eval '(handler-case (ql:quickload :mnemosyne) (error (e) (format *error-output* "~&FAILED: ~A~%" e) (uiop:quit 1)))'
  Info "Loaded."
}
Info "Setup complete. Next: run ``sbcl --dynamic-space-size 4096 --script bootstrap.lisp`` at the repo root, then (ql:quickload :mnemosyne)."
