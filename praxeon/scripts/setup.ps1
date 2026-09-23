#!/usr/bin/env pwsh
# INTERIM -- superseded by `bin/cons` once build/test/serve/run land (see ECOSYSTEM.md
# and hyperion/docs/adr/0007). Kept only as the working path until cons reaches parity;
# do not extend. Discovery is handled by bootstrap.lisp's source-registry drop-in.
#
# scripts/setup.ps1 -- convenience provisioning for a fresh clone of Praxeon (Windows).
# Idempotent. Does NOT install SBCL/Quicklisp -- checks and tells you how.
#   1. Clone Coalton (local checkout; not pulled by Quicklisp).
#   2. Create .env from .env.example (never overwriting an existing one).
# System discovery (finding praxeon.asd) is NOT done here: run
# `sbcl --script bootstrap.lisp` at the monorepo root once (writes the ASDF drop-in).
# NB: on Windows the web backend is Hunchentoot (Woo/libev are Unix-only), so
# there is no libev step. Usage:  pwsh scripts/setup.ps1 [-Test]

param([switch]$Test)
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
function Info($m) { Write-Host "==> $m" -ForegroundColor Blue }
function Die($m)  { Write-Error $m; exit 1 }

if (-not (Get-Command sbcl -ErrorAction SilentlyContinue)) { Die "SBCL not found (choco/scoop install sbcl)." }
$QlHome  = if ($env:QUICKLISP_HOME) { $env:QUICKLISP_HOME } else { Join-Path $HOME 'quicklisp' }
$QlSetup = Join-Path $QlHome 'setup.lisp'
if (-not (Test-Path $QlSetup)) { Die "Quicklisp not found at $QlSetup (https://www.quicklisp.org/beta/)." }
Info "SBCL present  |  Quicklisp at $QlHome"

$CoaltonDir = Join-Path $HOME 'common-lisp\coalton'
if (Test-Path (Join-Path $CoaltonDir '.git')) { Info "Coalton present at $CoaltonDir." }
else { Info "Cloning Coalton into $CoaltonDir ..."; New-Item -ItemType Directory -Force -Path (Split-Path $CoaltonDir) | Out-Null
       git clone --depth 1 https://github.com/coalton-lang/coalton $CoaltonDir }

# System discovery is handled by the repo-root bootstrap, not here.
Info "Discovery: run 'sbcl --script bootstrap.lisp' at the repo root (writes the ASDF drop-in)."

# .env from the template (never overwrite).
$EnvExample = Join-Path $RepoRoot '.env.example'
$EnvFile    = Join-Path $RepoRoot '.env'
if (Test-Path $EnvFile) { Info ".env present (left as-is)." }
elseif (Test-Path $EnvExample) { Info "Creating .env from .env.example"; Copy-Item $EnvExample $EnvFile }

if ($Test) {
  Info "Loading Praxeon/Elise (first run compiles Coalton; a few minutes)..."
  $heap = if ($env:PRAXEON_DYNAMIC_SPACE_SIZE) { $env:PRAXEON_DYNAMIC_SPACE_SIZE } else { '4096' }
  $ql = ($QlSetup -replace '\\','/')
  sbcl --dynamic-space-size $heap --non-interactive `
    --eval "(load `"$ql`")" `
    --eval '(handler-case (ql:quickload :praxeon/elise) (error (e) (format *error-output* "~&FAILED: ~A~%" e) (uiop:quit 1)))'
  Info "Loaded."
}
Info "Setup complete. Next: run 'sbcl --script bootstrap.lisp' at the monorepo root (once), then '(ql:quickload :praxeon/elise)'."
