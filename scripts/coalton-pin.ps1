#!/usr/bin/env pwsh
# scripts/coalton-pin.ps1 -- check that the Coalton checkout is at the commit coalton.pin names.
#
# The framework setup scripts (aion, elenchon, hyperion, mnemosyne and praxeon
# scripts/setup.ps1) run this instead of cloning Coalton themselves (#733, #751). It changes
# nothing. scripts/setup.ps1 is the only script that clones Coalton and checks out the pinned
# commit, so that is done in one place.
#
# Exits 0 when the checkout at $env:COALTON_DIR (default ~/common-lisp/coalton) is at the
# pinned commit. Otherwise prints what it found and says to run scripts/setup.ps1, and exits 1.
# Warns, without failing, when the checkout's origin differs from the pin's repo line, as
# scripts/setup.ps1 does.
#
# Usage:  pwsh scripts/coalton-pin.ps1

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$PinFile = Join-Path $Root 'coalton.pin'
$Fix = "Run scripts\setup.ps1 at the monorepo root ($Root), which checks out the pinned commit."

function Fail($m) { [Console]::Error.WriteLine("error: $m"); exit 1 }

# The commit REV names in the checkout at DIR, or $null. Under ErrorActionPreference 'Stop',
# Windows PowerShell turns git's "unknown revision" on stderr into a terminating error even
# with 2>$null, which would end the script before its message (#697).
function Resolve-GitCommit($dir, $rev) {
  $ErrorActionPreference = 'Continue'
  $out = (& git -C $dir rev-parse --verify --quiet "$rev^{commit}" 2>$null)
  if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
  return ([string]$out).Trim()
}

$Ref = $null
$Repo = $null
if (Test-Path $PinFile) {
  foreach ($line in Get-Content $PinFile) {
    if (-not $Ref -and $line -match '^\s*sha\s+(\S+)') { $Ref = $matches[1] }
    if (-not $Repo -and $line -match '^\s*repo\s+(\S+)') { $Repo = $matches[1] }
  }
}
if (-not $Ref) { Fail "no 'sha' line in $PinFile." }
if (-not $Repo) { $Repo = 'https://github.com/coalton-lang/coalton' }
$Dir = if ($env:COALTON_DIR) { $env:COALTON_DIR } else { Join-Path $HOME 'common-lisp\coalton' }

if (-not (Test-Path (Join-Path $Dir '.git'))) { Fail "Coalton is not checked out at $Dir. $Fix" }

$origin = & {
  $ErrorActionPreference = 'Continue'
  $o = (& git -C $Dir remote get-url origin 2>$null)
  if ($LASTEXITCODE -eq 0 -and $o) { ([string]$o).Trim() } else { '' }
}
if ($origin -and $origin -ne $Repo) {
  [Console]::Error.WriteLine("warning: $Dir tracks $origin but coalton.pin declares $Repo")
}

# coalton.pin carries a short sha, so compare resolved commit ids.
$current = Resolve-GitCommit $Dir 'HEAD'
$want = Resolve-GitCommit $Dir $Ref
if (-not $want -or $current -ne $want) {
  $shown = if ($current) { $current.Substring(0, 8) } else { 'no commit' }
  Fail "Coalton at $Dir is at $shown, but coalton.pin names $Ref. $Fix"
}
Write-Host "==> Coalton at $Dir is at the pinned $Ref." -ForegroundColor Blue
exit 0
