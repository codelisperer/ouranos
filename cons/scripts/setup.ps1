#!/usr/bin/env pwsh
#
# INTERIM — superseded by `bin/cons` once build/test/serve/run land (see ECOSYSTEM.md
# and hyperion/docs/adr/0007). Kept only as the working path until cons reaches parity;
# do not extend. Discovery is handled by bootstrap.lisp's source-registry drop-in.
#
# scripts/setup.ps1 -- prereq check for cons (Windows). PowerShell port of
# scripts/setup.sh. Idempotent. Pure-CL and dependency-light on purpose (cons is a
# bootstrapping tool -- it shouldn't need a heavy ritual to itself install).
# Usage:  pwsh scripts/setup.ps1 [-Test]

[CmdletBinding()]
param([switch]$Test)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir '..')).Path

function Info($msg) { Write-Host '==> ' -ForegroundColor Blue -NoNewline; Write-Host $msg }
function Warn($msg) { Write-Host 'warning: ' -ForegroundColor Yellow -NoNewline; Write-Host $msg }
function Die($msg)  { Write-Host 'error: ' -ForegroundColor Red -NoNewline; Write-Host $msg; exit 1 }

if (-not (Get-Command sbcl -ErrorAction SilentlyContinue)) {
  Die "SBCL not found (e.g. 'choco install sbcl' or 'scoop install sbcl')."
}

$QlHome = if ($env:QUICKLISP_HOME) { $env:QUICKLISP_HOME } else { Join-Path $HOME 'quicklisp' }
$QlSetup = Join-Path $QlHome 'setup.lisp'
if (-not (Test-Path -LiteralPath $QlSetup)) {
  Die "Quicklisp not found at $QlSetup (https://www.quicklisp.org/beta/)."
}
$SbclVersion = (& sbcl --version) -split '\s+' | Select-Object -Index 1
Info "SBCL $SbclVersion  |  Quicklisp at $QlHome"

Info 'Discovery: run `sbcl --script bootstrap.lisp` at the repo root (writes the ASDF drop-in).'

# Optionally verify cons actually loads.
if ($Test) {
  Info 'Loading cons ...'
  $QlSetupLisp = $QlSetup -replace '\\', '/'
  & sbcl --non-interactive `
    --eval "(load `"$QlSetupLisp`")" `
    --eval '(handler-case (ql:quickload :cons) (error (e) (format *error-output* "~&FAILED: ~A~%" e) (uiop:quit 1)))'
  if ($LASTEXITCODE -ne 0) { Die 'cons failed to load.' }
  Info 'Loaded.'
}

Info 'Setup complete. Next: run bootstrap.lisp at the repo root, then rlwrap sbcl and (ql:quickload :cons).'
