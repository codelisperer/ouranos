#!/usr/bin/env pwsh
<#
.SYNOPSIS
  pre-publication issue 230 -- would this tree load on a Windows machine that has only what we provision?

.DESCRIPTION
  The Windows counterpart to scripts/verify-clean-machine.sh, and NOT a port of it. That
  script starts a container with nothing in it. Windows has no cheap equivalent for this
  purpose -- a Windows container image is large, and half of what is being tested is what
  the OS itself supplies, which an image may not reproduce faithfully.

  So this tests the LOADER ENVIRONMENT instead, which is where the defect actually lives.
  It restricts PATH to SBCL plus System32, loads every system a Windows machine can load,
  and then asks the question that matters:

      FOR EVERY NATIVE LIBRARY THE TREE PULLED IN -- WHERE DID IT COME FROM?

  Presence was never the question. pre-publication issue 229's sqlite backend reported 36 honest checks against
  a real SQLite for months, supplied by an Embarcadero RAD Studio installation nobody
  installed for this. The check was truthful at every layer it could inspect; the falsehood
  was one layer below, in WHICH FILE the loader found. A harness that only asks "did it
  load" reproduces that failure exactly.

  A library is acceptable if it is either:

    PROVISIONED  -- beside sbcl.exe or under the tree's vendor/, i.e. something setup.ps1
                    or build-libuv.lisp put there deliberately, or
    WINDOWS      -- in System32 (or the Windows directory) AND carrying a valid signature
                    that marks it as an operating-system binary (IsOSBinary).

  The signature is load-bearing, not decoration. System32 is a dumping ground on a
  developer's machine: anyone can drop a DLL in it, and being there is not evidence that
  Windows ships it. A genuine component (WinHttp.dll, kernel32.dll, even winsqlite3.dll) is
  signed as part of the operating system; a third-party build sitting in the same directory
  is not.

  A Microsoft signature is not enough either (#253). Microsoft also signs redistributables
  that a fresh Windows does not necessarily have: vcruntime140.dll, the Visual C++ runtime,
  is signed by "Microsoft Windows Software Compatibility Publisher" and has IsOSBinary
  false. The rule used to accept any signer whose name matched 'Microsoft', which let it
  through. Every run now checks the rule against this machine's own files first.

  Anything else is a FINDING -- a library the tree needs and nobody provisions, which will
  be absent on a user's machine and present on yours.

.PARAMETER Control
  Hide the provisioned SQLite DLLs (libsqlite3.dll and sqlite3.dll) and require this
  harness to FAIL. A clean-machine test
  that has never been shown to fail is indistinguishable from one that cannot.

.PARAMETER KeepWork
  Leave the working directory behind.

.EXAMPLE
  .\scripts\verify-clean-machine.ps1
.EXAMPLE
  .\scripts\verify-clean-machine.ps1 -Control
#>
[CmdletBinding()]
param([switch]$Control, [switch]$KeepWork)

$ErrorActionPreference = 'Stop'
$Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Root = Split-Path -Parent $Here

function Info($m) { Write-Host "==> $m" -ForegroundColor Blue }
function Note($m) { Write-Host "    $m" -ForegroundColor DarkGray }
function Good($m) { Write-Host "  ok      $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAILED  $m" -ForegroundColor Red }

# EVERY FAILURE IS RECORDED AND THE RUN CONTINUES. The POSIX harness learned this the
# expensive way -- its first version checked a final exit code and reported PASS on a run
# where mnemosyne could not load. A verdict is the LAST thing computed here, from the list.
$script:Failures = @()
function Fail($m) { $script:Failures += $m; Bad $m }

# NOT `$IsWindows'. That automatic variable arrived with PowerShell *Core* 6; in Windows
# PowerShell 5.1 it is simply undefined, `-not $null' is true, and this guard fired on the
# one OS the script supports -- refusing with "Windows only" while standing on Windows.
# 5.1 is the PowerShell a stock Windows box HAS (`pwsh' is a separate install that
# setup.ps1 does not perform), so the harness for "a machine with only what we provision"
# could not run on one. That is the defect this file exists to catch, living in this file.
# `$env:OS' is Windows_NT on every Windows since NT, absent elsewhere, and reads the same
# under 5.1 and 7 -- which is the property the guard actually wants.
if ($env:OS -ne 'Windows_NT') { Write-Host 'ERROR: Windows only; the POSIX harness is verify-clean-machine.sh' -ForegroundColor Red; exit 2 }

$sbclCmd = Get-Command sbcl -ErrorAction SilentlyContinue
if (-not $sbclCmd) { Write-Host 'ERROR: sbcl is not on PATH -- run scripts/setup.ps1 first' -ForegroundColor Red; exit 2 }
$Sbcl = $sbclCmd.Source
$SbclDir = Split-Path -Parent $Sbcl
$Sys32 = Join-Path $env:WINDIR 'System32'

# PATH = SBCL + System32 + WINDIR, and nothing else. Not a clean machine -- a clean LOADER
# ENVIRONMENT, which is the part that decides whether a user can run what we ship.
$CleanPath = "$SbclDir;$Sys32;$env:WINDIR"

$Work = Join-Path $env:TEMP "ouranos-clean-$PID"
if (Test-Path $Work) { Remove-Item -Recurse -Force $Work }
New-Item -ItemType Directory -Force -Path $Work | Out-Null

Info 'pre-publication issue 230 -- would this tree load on a Windows machine with only what we provision?'
Note "tree        : $Root"
Note "sbcl        : $Sbcl"
Note "clean PATH  : $CleanPath"
Note ("mode        : " + $(if ($Control) { 'CONTROL -- the provisioned SQLite DLLs are hidden and this run MUST fail' } else { 'normal' }))

# ---------------------------------------------------------------------------
# where a name resolves, and what put it there
# ---------------------------------------------------------------------------

function Resolve-OnCleanPath {
  param([string]$Name)
  # The loader's own order: the executable's directory first, then System32, then the rest
  # of PATH. Everything this tree runs is sbcl.exe or an image dumped beside its libraries.
  foreach ($d in @($SbclDir, $Sys32, $env:WINDIR)) {
    $p = Join-Path $d $Name
    if (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) { return $p }
  }
  return $null
}

function Get-LibraryOrigin {
  param([string]$Path)
  if (-not $Path) { return [pscustomobject]@{ Kind = 'MISSING'; Detail = 'not on the clean PATH' } }
  $dir = (Split-Path -Parent $Path).TrimEnd('\')
  if ($dir -ieq $SbclDir.TrimEnd('\')) {
    return [pscustomobject]@{ Kind = 'PROVISIONED'; Detail = 'beside sbcl.exe' }
  }
  if ($Path -like "$Root\vendor\*") {
    return [pscustomobject]@{ Kind = 'PROVISIONED'; Detail = "the tree's vendor/" }
  }
  if ($dir -ieq $Sys32.TrimEnd('\') -or $dir -ieq $env:WINDIR.TrimEnd('\')) {
    # IN System32 IS NOT THE SAME AS SHIPPED BY WINDOWS. Anyone can drop a DLL there.
    $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction SilentlyContinue
    $signer = if ($sig -and $sig.SignerCertificate) { $sig.SignerCertificate.Subject -replace '^CN=([^,]+).*', '$1' } else { '' }
    if ($sig -and $sig.Status -eq 'Valid' -and $sig.IsOSBinary) {
      return [pscustomobject]@{ Kind = 'WINDOWS'; Detail = "operating-system binary, signed: $signer" }
    }
    $vi = (Get-Item -LiteralPath $Path).VersionInfo
    $status = if ($sig) { $sig.Status } else { 'no signature data' }
    return [pscustomobject]@{
      Kind   = 'UNPROVISIONED'
      Detail = "in System32 but NOT a Windows component -- signature $status, signer '$signer', CompanyName '$($vi.CompanyName)', ProductName '$($vi.ProductName)'"
    }
  }
  return [pscustomobject]@{ Kind = 'UNPROVISIONED'; Detail = "from $dir" }
}

# THE RULE ABOVE IS CHECKED AGAINST THIS MACHINE BEFORE IT IS USED (#253). A classifier that
# accepts too much looks exactly like a machine that needs nothing, so both directions are
# asserted: a file Windows certainly ships must be WINDOWS, and a Microsoft-signed
# redistributable, if this machine has one, must not be.
function Test-Classifier {
  $k = Get-LibraryOrigin (Join-Path $Sys32 'kernel32.dll')
  if ($k.Kind -eq 'WINDOWS') { Good "classifier: kernel32.dll is WINDOWS" }
  else { Fail "classifier: kernel32.dll came out $($k.Kind) ($($k.Detail)), so the rule rejects Windows itself" }
  $redist = @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll') | ForEach-Object { Join-Path $Sys32 $_ } |
              Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if (-not $redist) {
    Note 'classifier: no Visual C++ redistributable in System32 here, so the rejecting direction is not checked on this machine'
    return
  }
  $r = Get-LibraryOrigin $redist
  if ($r.Kind -ne 'WINDOWS') { Good "classifier: $(Split-Path -Leaf $redist) is $($r.Kind), not WINDOWS" }
  else { Fail "classifier: $(Split-Path -Leaf $redist) came out WINDOWS ($($r.Detail)), but it is the Visual C++ redistributable, not part of Windows" }
}

# ---------------------------------------------------------------------------
# the run
# ---------------------------------------------------------------------------

Info 'the classifier, against files whose answer is known'
Test-Classifier

# BOTH names are hidden. setup.ps1 installs the pinned DLL as libsqlite3.dll and as
# sqlite3.dll (#239), and cl-sqlite loads either, so hiding one leaves the other to load and
# the control would pass for the wrong reason.
$hidden = @()
if ($Control) {
  $dlls = @(@('libsqlite3.dll', 'sqlite3.dll') | ForEach-Object { Join-Path $SbclDir $_ } |
              Where-Object { Test-Path -LiteralPath $_ })
  if ($dlls.Count -eq 0) {
    Write-Host "ERROR: -Control needs a provisioned SQLite DLL beside sbcl.exe to hide; run scripts/setup.ps1" -ForegroundColor Red
    exit 2
  }
  foreach ($dll in $dlls) {
    $h = "$dll.hidden-by-clean-machine-control"
    Move-Item -LiteralPath $dll -Destination $h -Force
    $hidden += [pscustomobject]@{ From = $dll; To = $h }
    Note "hid $dll"
  }
}

try {
  # --- 1. the machine claims to be provisioned ------------------------------
  Info 'setup.ps1 -Check'
  $check = & (Join-Path $Here 'setup.ps1') -Check 2>&1
  $checkOk = ($LASTEXITCODE -eq 0)
  $check | ForEach-Object { Note $_ }
  if ($checkOk) { Good 'setup.ps1 -Check is satisfied' } else { Fail 'setup.ps1 -Check reports missing prerequisites' }
  # A WARN about an unprovisioned sqlite3.dll is a finding here even though -Check tolerates
  # it: that is the whole of pre-publication issue 229, and this harness exists to stop tolerating it.
  if ($check | Select-String -Pattern 'NOT provisioned by setup.ps1' -Quiet) {
    Fail 'the SQLite DLL on this machine comes from somewhere setup.ps1 did not put it'
  }
  # The same finding when setup.ps1 did provision a copy but a different file loads first (#239).
  if ($check | Select-String -Pattern 'provisioned by setup.ps1, but loaded from elsewhere' -SimpleMatch -Quiet) {
    Fail 'setup.ps1 provisioned SQLite, but the DLL that loads is a different file'
  }

  # --- 2. load the tree, with the loader restricted -------------------------
  Info 'loading every system, PATH = SBCL + System32'
  $report = Join-Path $Work 'libs.txt'
  $old = $env:PATH
  $env:PATH = $CleanPath
  $env:CL_SOURCE_REGISTRY = "$Root//;"
  try {
    # Windows PowerShell 5.1 turns a native command's STDERR into an ErrorRecord, and with
    # $ErrorActionPreference = 'Stop' that ABORTS the run. The `2>&1` below says plainly that
    # stderr is wanted as OUTPUT here: the probe reports load failures on it, and -Control is
    # the mode that produces them -- so the strict setting killed precisely the run that proves
    # this harness can fail, and left the quiet PASS path working. Relaxed for the native call
    # only, restored in the finally. (PowerShell 6+ stopped treating native stderr this way,
    # which is why it went unseen: this file had only ever been run under pwsh.)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $Sbcl --dynamic-space-size 4096 --script (Join-Path $Here 'clean-machine-probe.lisp') `
      --out ($report.Replace('\', '/')) 2>&1 | ForEach-Object { Write-Host "  $_" }
    $probeOk = ($LASTEXITCODE -eq 0)
  } finally { $ErrorActionPreference = $prevEap; $env:PATH = $old }

  if (-not (Test-Path $report)) {
    Fail 'the probe produced no report at all -- it did not get far enough to load anything'
  } else {
    $lines = Get-Content $report
    foreach ($l in ($lines | Where-Object { $_ -like 'FAILED-SYSTEM *' })) {
      Fail ($l -replace '^FAILED-SYSTEM ', 'a system does not load on a clean loader: ')
    }

    # --- 3. and where did every native library come from? -------------------
    Info 'the native libraries the tree pulled in, and who supplied each'
    $libs = $lines | Where-Object { $_ -like 'LIB *' } | ForEach-Object { $_.Substring(4) }
    if (-not $libs) { Fail 'the probe reported no native libraries at all, which cannot be right' }
    foreach ($name in $libs) {
      $path = Resolve-OnCleanPath $name
      $o = Get-LibraryOrigin $path
      switch ($o.Kind) {
        'PROVISIONED' { Good ("{0,-24} {1}  ({2})" -f $name, $path, $o.Detail) }
        'WINDOWS' { Good ("{0,-24} {1}  ({2})" -f $name, $path, $o.Detail) }
        default {
          Fail ("{0} is neither provisioned by this repo nor shipped by Windows -- {1}{2}" -f `
              $name, $o.Detail, $(if ($path) { " [$path]" } else { '' }))
        }
      }
    }
  }
} finally {
  foreach ($h in $hidden) { Move-Item -LiteralPath $h.To -Destination $h.From -Force }
  if ($KeepWork) { Note "work kept at $Work" } else { Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------

Write-Host ''
if ($Control) {
  if ($script:Failures.Count -eq 0) {
    Write-Host 'CONTROL FAILED: the harness passed with the provisioned SQLite DLLs hidden.' -ForegroundColor Red
    Write-Host '  It cannot fail, so its green runs mean nothing.' -ForegroundColor Red
    exit 1
  }
  Info "CONTROL PASSED: $($script:Failures.Count) failure(s) with the SQLite DLLs hidden:"
  $script:Failures | ForEach-Object { Note "- $_" }
  exit 0
}

if ($script:Failures.Count -eq 0) {
  Info 'PASSED: every native library this tree needs is one we provision or one Windows ships.'
  Note 'A clean LOADER environment, not a clean machine: this asserts what the tree needs'
  Note 'from the host, not that setup.ps1 can stand a bare box up. That is still unmeasured.'
  exit 0
}
Write-Host "FAILED: $($script:Failures.Count) finding(s)" -ForegroundColor Red
$script:Failures | ForEach-Object { Write-Host "     - $_" -ForegroundColor Red }
exit 1
