#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Provision a bare Windows machine (or a CI runner) for Ouranos. The Windows half of
  scripts/setup.sh.

.DESCRIPTION
  Installs, all at the versions pinned in scripts/versions.env:
    1. SBCL      -- the official MSI from SourceForge (x86-64 or arm64), per-user PATH.
    2. Quicklisp -- into ~/quicklisp, with the dist pinned to a dated snapshot.
    3. Coalton   -- a git checkout at the pinned commit in ~/common-lisp/coalton
                    (NOT a Quicklisp system; ASDF finds ~/common-lisp by default).
  It does NOT run bootstrap.lisp -- that is the next step, and the caller's choice:
    sbcl --dynamic-space-size 4096 --script bootstrap.lisp

  It also does NOT install a C compiler. -Check REPORTS whether MSVC is present, because
  aion/uv needs it to build libuv, but that is an OPT-IN extra: the compiler is a ~2 GB
  install, nothing else in the tree requires one, and a missing one is therefore not a
  provisioning failure. When it IS needed, it is MSVC and not MSYS2/MinGW -- each platform
  uses the toolchain its own vendor ships (ECOSYSTEM decisions log).

  Idempotent: anything already present at the right version is left alone.

.PARAMETER Check
  Report only; exit 1 if something is missing. Installs nothing.

.PARAMETER CI
  Also export PATH/SBCL_HOME into $GITHUB_PATH / $GITHUB_ENV for later workflow steps.

.EXAMPLE
  .\scripts\setup.ps1 -Check
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup.ps1
#>
[CmdletBinding()]
param([switch]$Check, [switch]$CI)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 compatible -- that is what a fresh Windows box has.
$Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Root = Split-Path -Parent $Here

function Info($m) { Write-Host "==> $m" -ForegroundColor Blue }
function Note($m) { Write-Host "    $m" -ForegroundColor DarkGray }
function Die($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# --- the pins ---------------------------------------------------------------
$Pins = @{}
Get-Content (Join-Path $Here 'versions.env') | ForEach-Object {
  # [A-Z0-9_]+, not [A-Z_]+: SQLITE_SHA256_X64 has a digit in the KEY, and the old
  # pattern silently skipped such a line rather than failing -- a pin that is quietly
  # absent is worse than one that is wrong.
  if ($_ -match '^\s*([A-Z0-9_]+)\s*=\s*(.+?)\s*$') { $Pins[$matches[1]] = $matches[2] }
}
foreach ($k in 'SBCL_VERSION', 'QUICKLISP_DIST') {
  if (-not $Pins.ContainsKey($k)) { Die "versions.env: $k missing" }
}
$SbclVersion = $Pins['SBCL_VERSION']
$QlDist = $Pins['QUICKLISP_DIST']
$SqliteVersion = $Pins['SQLITE_VERSION']
$SqliteYear = $Pins['SQLITE_YEAR']

# Coalton's commit comes from the repo-root coalton.pin -- the single source of truth for it
# across every machine (docs/coalton-upstream.md). Deliberately NOT duplicated in
# versions.env: two files naming a Coalton commit is the drift this pin exists to prevent.
$CoaltonRef = $null
$pinFile = Join-Path $Root 'coalton.pin'
if (Test-Path $pinFile) {
  foreach ($line in Get-Content $pinFile) {
    if ($line -match '^\s*sha\s+(\S+)') { $CoaltonRef = $matches[1]; break }
  }
}
if (-not $CoaltonRef) { Die "no 'sha' line in $pinFile" }
# An optional `repo` line lets the pin name a FORK; without it we track upstream. A sha is
# only meaningful relative to a repository, so a machine cloned from upstream and one cloned
# from a fork can disagree about what a given sha even refers to.
$CoaltonRepo = 'https://github.com/coalton-lang/coalton'
if (Test-Path $pinFile) {
  foreach ($line in Get-Content $pinFile) {
    if ($line -match '^\s*repo\s+(\S+)') { $CoaltonRepo = $matches[1]; break }
  }
}

$QlHome = if ($env:QUICKLISP_HOME) { $env:QUICKLISP_HOME } else { Join-Path $HOME 'quicklisp' }
$CoaltonDir = if ($env:COALTON_DIR) { $env:COALTON_DIR } else { Join-Path $HOME 'common-lisp\coalton' }
$Arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x86-64' }

function Get-SbclVersion {
  $cmd = Get-Command sbcl -ErrorAction SilentlyContinue
  if (-not $cmd) { return $null }
  $out = & sbcl --version 2>$null
  if ($out -match 'SBCL\s+(\S+)') { return $matches[1] }
  return $null
}

# --- downloading, with a retry that covers what actually goes wrong ----------
#
# ONE HELPER, because there were two download sites and two different bugs: the MSI
# fetch had a --retry that cannot see the failure it was for, and the Quicklisp fetch
# had no retry at all. Two call sites drifting apart is how one of them keeps being the
# one nobody fixed.
#
# curl.exe rather than Invoke-WebRequest, everywhere: SourceForge answers with an HTML
# interstitial that Invoke-WebRequest happily saves AS the .msi, and msiexec then fails
# with the opaque 1620. curl ships with Windows 10+ and follows mirror redirects.
function Get-Url {
  param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$OutFile)
  # --retry-all-errors is the flag that makes --retry cover a mid-transfer close
  # (curl exit 18). Available since curl 7.71; Windows 10+ ships 8.x.
  & curl.exe -fsSL --retry 4 --retry-delay 2 --retry-all-errors -o $OutFile $Url
  if ($LASTEXITCODE -ne 0) {
    # A partial file is worse than none: it fails later, somewhere else, as a corrupt
    # archive rather than as a download that did not finish.
    Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
    Die "downloading $Url failed (curl exit $LASTEXITCODE)"
  }
}

# --- 1. SBCL ----------------------------------------------------------------
function Install-Sbcl {
  # Upstream ships Windows binaries as an MSI (x86-64 and arm64 for 2.6.6).
  $msi = "sbcl-$SbclVersion-$Arch-windows-binary.msi"
  $url = "https://downloads.sourceforge.net/project/sbcl/sbcl/$SbclVersion/$msi"
  $tmp = Join-Path $env:TEMP $msi
  Info "downloading SBCL $SbclVersion ($Arch) ..."
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
  # curl.exe, not Invoke-WebRequest: SourceForge answers with an HTML interstitial that
  # Invoke-WebRequest happily saves AS the .msi, and msiexec then fails with the utterly
  # opaque 1620 ("package could not be opened"). Observed exactly that on a CI runner.
  # curl ships with Windows 10+ and follows the mirror redirects properly.
  # --retry-all-errors, NOT bare --retry. curl(1) limits --retry to a timeout, an FTP
  # 4xx, or HTTP 408/429/500/502/503/504/522/524. A mid-transfer close is NONE of those,
  # so the flag that was here could not absorb the one failure it was added for: the
  # Linux lane measured `curl: (18) transfer closed with 11526315 bytes remaining to
  # read' on a clean-machine run, after 3m23s, with nothing installed, and proved it both
  # directions against a server that truncates its first two responses (#198).
  Get-Url -Url $url -OutFile $tmp

  # Verify it really is an MSI before handing it to msiexec: an MSI is an OLE compound
  # file, magic D0 CF 11 E0. Failing here says what went wrong; failing in msiexec does not.
  $bytes = [IO.File]::ReadAllBytes($tmp)
  $isMsi = $bytes.Length -gt 1MB -and $bytes[0] -eq 0xD0 -and $bytes[1] -eq 0xCF -and $bytes[2] -eq 0x11 -and $bytes[3] -eq 0xE0
  if (-not $isMsi) {
    $head = [Text.Encoding]::ASCII.GetString($bytes[0..([Math]::Min(180, $bytes.Length - 1))])
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Die "what downloaded from $url is not an MSI ($($bytes.Length) bytes). First bytes:`n$head"
  }
  Info "installing (msiexec, per-machine -- may prompt for elevation) ..."
  $p = Start-Process msiexec.exe -ArgumentList '/i', "`"$tmp`"", '/quiet', '/norestart' -Wait -PassThru
  if ($p.ExitCode -ne 0) { Die "msiexec exited $($p.ExitCode) installing $msi" }
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

function Find-SbclHome {
  # SBCL_HOME must point at the directory holding sbcl.core, or `--script` runs and
  # `require` of a contrib fail. Look beside whatever sbcl is on PATH first -- that covers
  # hand-unpacked installs (e.g. C:\bin\sbcl\<version>\) as well as the MSI's location.
  if ($env:SBCL_HOME -and (Test-Path (Join-Path $env:SBCL_HOME 'sbcl.core'))) { return $env:SBCL_HOME }
  $cmd = Get-Command sbcl -ErrorAction SilentlyContinue
  if ($cmd) {
    $dir = Split-Path -Parent $cmd.Source
    foreach ($c in @($dir, (Join-Path $dir 'lib\sbcl'), (Join-Path (Split-Path -Parent $dir) 'lib\sbcl'))) {
      if ($c -and (Test-Path (Join-Path $c 'sbcl.core'))) { return $c }
    }
  }
  foreach ($p in @("$env:ProgramFiles\Steel Bank Common Lisp",
                   "${env:ProgramFiles(x86)}\Steel Bank Common Lisp",
                   "$env:ProgramFiles\sbcl")) {
    if (Test-Path (Join-Path $p 'sbcl.core')) { return $p }
    if (Test-Path $p) {
      $sub = Get-ChildItem $p -Directory -ErrorAction SilentlyContinue |
             Where-Object { Test-Path (Join-Path $_.FullName 'sbcl.core') } | Select-Object -First 1
      if ($sub) { return $sub.FullName }
    }
  }
  return $null
}

function Export-SbclEnv {
  # An MSI updates the MACHINE PATH, but a running process's PATH is a snapshot taken when
  # it started -- so the sbcl we just installed is invisible to THIS process until we merge
  # the machine/user PATH back in by hand. Without this, everything downstream believes SBCL
  # is missing immediately after installing it.
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:PATH = (@($machine, $user, $env:PATH) | Where-Object { $_ }) -join ';'

  $home_ = Find-SbclHome
  if ($home_) { $env:SBCL_HOME = $home_ }

  # NB: (Get-Command …).Source on a missing command is $null, and Split-Path -Parent $null
  # throws ParameterArgumentValidationErrorNullNotAllowed -- guard rather than chain.
  $cmd = Get-Command sbcl -ErrorAction SilentlyContinue
  $bin = if ($cmd) { Split-Path -Parent $cmd.Source } elseif ($home_) { $home_ } else { $null }

  if ($CI -and $env:GITHUB_ENV -and $home_) { "SBCL_HOME=$home_" | Out-File -Append -Encoding utf8 $env:GITHUB_ENV }
  if ($CI -and $env:GITHUB_PATH -and $bin) { $bin | Out-File -Append -Encoding utf8 $env:GITHUB_PATH }

  if (-not $cmd -and -not $home_) {
    Die ("SBCL was installed but cannot be located afterwards. Searched PATH, the NSIS-style" +
      " registry keys, and the usual Program Files locations. If the MSI installed" +
      " somewhere unusual, set SBCL_HOME and add its directory to PATH by hand.")
  }
}

# --- 2. Quicklisp -----------------------------------------------------------

function Invoke-SbclForm {
  <#
    Evaluate a Lisp FORM by writing it to a temp file and --load-ing it.

    Not --eval, which is a trap here: PowerShell mangles embedded double quotes when
    passing arguments to a native exe, so `--eval '(… :path "C:/Users/x/quicklisp/")'`
    reaches SBCL with the quotes stripped. Its reader then parses C:/Users/... as a
    package-qualified symbol and dies with 'Package "C" does not exist'. A file has no
    argument-quoting layer at all. (No BOM either -- WriteAllText with UTF8Encoding($false).)
  #>
  param([Parameter(Mandatory = $true)][string]$Form, [string]$PreLoad)
  $f = Join-Path $env:TEMP ("ouranos-" + [guid]::NewGuid().ToString('N') + ".lisp")
  [IO.File]::WriteAllText($f, $Form, (New-Object Text.UTF8Encoding($false)))
  try {
    if ($PreLoad) { & sbcl --non-interactive --no-userinit --load $PreLoad --load $f | Out-Null }
    else { & sbcl --non-interactive --no-userinit --load $f | Out-Null }
    return $LASTEXITCODE
  } finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
}

function Install-Quicklisp {
  Info "installing Quicklisp -> $QlHome"
  $tmp = Join-Path $env:TEMP 'quicklisp.lisp'
  # Was Invoke-WebRequest with NO retry of any kind -- a second hole, and a worse one:
  # the MSI download at least tried. One transient here fails the whole setup.
  Get-Url -Url 'https://beta.quicklisp.org/quicklisp.lisp' -OutFile $tmp
  # Forward slashes: backslash is the Lisp reader's escape character inside a string.
  $path = ($QlHome -replace '\\', '/') + '/'
  $rc = Invoke-SbclForm -PreLoad $tmp -Form "(quicklisp-quickstart:install :path `"$path`")"
  if ($rc -ne 0) { Die "Quicklisp install failed (sbcl exit $rc)" }
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

function Get-QlDist {
  $d = Join-Path $QlHome 'dists\quicklisp\distinfo.txt'
  if (-not (Test-Path $d)) { return $null }
  foreach ($line in Get-Content $d) { if ($line -match '^version:\s*(\S+)') { return $matches[1] } }
  return $null
}

function Set-QlDist {
  $current = Get-QlDist
  if ($current -eq $QlDist) { Note "Quicklisp dist $current (pinned)"; return }
  Info "pinning Quicklisp dist $current -> $QlDist"
  $setup = Join-Path $QlHome 'setup.lisp'
  $rc = Invoke-SbclForm -PreLoad $setup `
    -Form "(ql-dist:install-dist `"http://beta.quicklisp.org/dist/quicklisp/$QlDist/distinfo.txt`" :replace t :prompt nil)"
  if ($rc -ne 0) { Die "pinning the Quicklisp dist failed (sbcl exit $rc)" }
}

# --- 3. Coalton -------------------------------------------------------------
function Install-Coalton {
  if (Test-Path (Join-Path $CoaltonDir '.git')) {
    # coalton.pin carries a SHORT sha, so compare RESOLVED commit ids -- a string compare
    # against HEAD's full sha never matches and would re-checkout on every run.
    $current = (& git -C $CoaltonDir rev-parse HEAD 2>$null).Trim()
    $want = (& git -C $CoaltonDir rev-parse "$CoaltonRef^{commit}" 2>$null)
    if ($want -and $current -eq $want.Trim()) { Note "Coalton already at the pinned $CoaltonRef"; return }
    Info "fetching Coalton -> $CoaltonRef"
    & git -C $CoaltonDir fetch --quiet origin
  } else {
    Info "cloning Coalton from $CoaltonRepo -> $CoaltonDir"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $CoaltonDir) | Out-Null
    & git clone --quiet $CoaltonRepo $CoaltonDir
  }
  # A checkout tracking a different remote than the pin declares will fetch shas that do not
  # exist there -- or, worse, different commits sharing a short prefix.
  $origin = (& git -C $CoaltonDir remote get-url origin 2>$null)
  if ($origin -and $origin.Trim() -ne $CoaltonRepo) {
    Note "WARNING: $CoaltonDir tracks $($origin.Trim()) but coalton.pin declares $CoaltonRepo"
  }
  & git -C $CoaltonDir checkout --quiet $CoaltonRef
  if ($LASTEXITCODE -ne 0) { Die "commit $CoaltonRef not found in $CoaltonDir (wrong remote, or the fetch failed)" }
}

# --- 4. SQLite (#229) --------------------------------------------------------
#
# mnemosyne's DEFAULT backend, and until this existed `setup.ps1` never mentioned it. On a
# machine provisioned exactly as documented, `setup.ps1` exited 0, `bootstrap.lisp` exited
# 0, and mnemosyne could not load:
#
#   PATH = SBCL + System32 only   ->  Unable to load any of the alternatives:
#                                        ((:DEFAULT "libsqlite3") (:DEFAULT "sqlite3"))
#
# and the suite did not report failures -- it did not RUN. Exit 3, no checks at all.
#
# THE MACHINE THAT REPORTED IT GREEN WAS BEING CARRIED BY SOFTWARE NOBODY INSTALLED FOR
# THIS. The working `sqlite3.dll` came from Embarcadero RAD Studio, the AWS CLI, and a
# stray `C:\bin`. That is the "green on one machine" class in its purest form: the CHECK
# was honest -- it ran, it compiled, it reported 36 real checks against a real backend --
# and the dishonesty was one layer below anything the gate can see.
#
# WINDOWS SHIPS SQLITE ALREADY, AS `winsqlite3.dll`, AND IT WORKS. Measured: copy it in
# under the name cl-sqlite looks for and mnemosyne's entire suite passes -- 360 checks,
# `BACKEND-CHECKS sqlite 36`. It is not used here for two reasons and both matter. It is an
# OS component Microsoft documents as not for third-party use, and a COPY of it is frozen:
# Windows Update would patch System32 and leave our duplicate behind, which is a poor thing
# to do to the library holding a user's data. A pinned upstream build is stale in the same
# way, but visibly, in versions.env, where bumping it is a decision somebody makes.
function Get-SqliteUrl {
  # Upstream encodes the version in the filename as MMmmppXX -- 3.50.4 becomes 3500400.
  # Derived rather than pinned separately, because two places naming one version is the
  # drift every pin in this file exists to prevent.
  $parts = $SqliteVersion -split '\.'
  while ($parts.Count -lt 3) { $parts += '0' }
  $enc = '{0}{1:00}{2:00}00' -f [int]$parts[0], [int]$parts[1], [int]$parts[2]
  $a = if ($Arch -eq 'arm64') { 'arm64' } else { 'x64' }
  return "https://sqlite.org/$SqliteYear/sqlite-dll-win-$a-$enc.zip"
}

function Get-SqliteSha {
  if ($Arch -eq 'arm64') { return $Pins['SQLITE_SHA256_ARM64'] }
  return $Pins['SQLITE_SHA256_X64']
}

function Find-SqliteDll {
  # WHERE THE LOADER WOULD ACTUALLY FIND ONE, in the order it looks: the directory of the
  # executable (sbcl.exe, for everything this tree runs), then System32, then PATH. Windows
  # ships winsqlite3.dll in System32 under a name cl-sqlite never asks for, so that copy is
  # invisible here on purpose -- this reports what the LOADER sees, not what exists.
  $dirs = @()
  $cmd = Get-Command sbcl -ErrorAction SilentlyContinue
  if ($cmd) { $dirs += (Split-Path -Parent $cmd.Source) }
  $dirs += ($env:PATH -split ';' | Where-Object { $_ })
  foreach ($d in $dirs) {
    foreach ($n in @('sqlite3.dll', 'libsqlite3.dll')) {
      try { $p = Join-Path $d $n } catch { continue }
      if (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) { return $p }
    }
  }
  return $null
}

function Install-Sqlite {
  $cmd = Get-Command sbcl -ErrorAction SilentlyContinue
  if (-not $cmd) { Note 'no sbcl on PATH yet -- skipping sqlite'; return }
  $sbclDir = Split-Path -Parent $cmd.Source

  # BESIDE sbcl.exe, because the executable's own directory is the FIRST thing Windows
  # searches -- so the copy this script provisions wins over whatever else a developer's
  # machine happens to carry. That determinism is the point: "two machines stand up the
  # same toolchain" is not true if the answer depends on whether Delphi is installed.
  $target = Join-Path $sbclDir 'sqlite3.dll'
  if (Test-Path -LiteralPath $target) { Note "sqlite3.dll present beside sbcl.exe"; return }

  $url = Get-SqliteUrl
  $want = Get-SqliteSha
  if (-not $want) { Die "versions.env: no SQLITE_SHA256 for $Arch" }
  $zip = Join-Path $env:TEMP "sqlite-dll-$SqliteVersion-$Arch.zip"
  Info "downloading SQLite $SqliteVersion ($Arch) ..."
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
  & curl.exe -fsSL --retry 4 --retry-delay 2 -o $zip $url
  if ($LASTEXITCODE -ne 0) { Die "downloading $url failed (curl exit $LASTEXITCODE)" }

  $got = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
  if ($got -ne $want.ToLower()) {
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Die "sqlite checksum mismatch for $url`n  expected $want`n  got      $got"
  }

  $stage = Join-Path $env:TEMP "sqlite-dll-$SqliteVersion-$Arch"
  if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
  # Expand-Archive exists in Windows PowerShell 5.1, which is what a fresh box has.
  Expand-Archive -Path $zip -DestinationPath $stage -Force
  $dll = Join-Path $stage 'sqlite3.dll'
  if (-not (Test-Path $dll)) { Die "$url did not contain sqlite3.dll" }

  try {
    Copy-Item $dll $target -Force
    Note "sqlite3.dll -> $target"
  } catch {
    # A per-machine SBCL under Program Files is not writable without elevation. Fall back
    # rather than demanding admin -- but say so, because a PATH entry is LATER in the
    # search order than the machine PATH, so another sqlite3.dll can still win.
    $lib = Join-Path $env:LOCALAPPDATA 'Ouranos\lib'
    New-Item -ItemType Directory -Force -Path $lib | Out-Null
    Copy-Item $dll (Join-Path $lib 'sqlite3.dll') -Force
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -notcontains $lib) {
      [Environment]::SetEnvironmentVariable('Path', (@($lib, $userPath) | Where-Object { $_ }) -join ';', 'User')
      Note "added $lib to your user PATH"
    }
    $env:PATH = "$lib;$env:PATH"
    Write-Host "    WARN could not write beside sbcl.exe ($sbclDir) -- installed to $lib instead." -ForegroundColor Yellow
    Write-Host "         Another sqlite3.dll earlier on PATH would still win; run -Check to see which one does." -ForegroundColor DarkGray
  }
  Remove-Item $zip -Force -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
}

# --- 5. MSVC (reported, never installed) -------------------------------------
# Only aion/uv needs this, and only to run scripts/build-libuv.lisp. Kept in sync with
# find-msvc in that script: same vswhere path, same query.
function Find-Msvc {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path $vswhere)) { return $null }
  # -products * is load-bearing: without it vswhere ignores Build Tools installs and
  # answers only for Community/Professional/Enterprise -- so the leanest machine, the one
  # carrying exactly what we ask people to install, would report "no compiler".
  # -requires pins it to the C++ tools: a VS carrying only the .NET workload cannot build.
  $path = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath 2>$null
  if (-not $path) { return $null }
  $path = ($path | Select-Object -First 1).Trim()
  if (-not (Test-Path (Join-Path $path 'VC\Auxiliary\Build\vcvarsall.bat'))) { return $null }
  $name = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property displayName 2>$null
  return [pscustomobject]@{ Path = $path; Name = ($name | Select-Object -First 1) }
}

$MsvcInstallHint = 'winget install --id Microsoft.VisualStudio.2022.BuildTools --override "--quiet --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"'

# --- report / act -----------------------------------------------------------
Info "Ouranos setup on Windows ($Arch) -- pins: SBCL $SbclVersion, QL dist $QlDist, SQLite $SqliteVersion, Coalton $CoaltonRef"

if ($Check) {
  $missing = 0
  function Miss($what, $fix) { Write-Host "  MISSING $what" -ForegroundColor Red; Write-Host "       fix: $fix" -ForegroundColor DarkGray; $script:missing++ }
  function Pass($what) { Write-Host "  PASS    $what" -ForegroundColor Green }

  if (Get-Command git -ErrorAction SilentlyContinue) { Pass 'git' } else { Miss 'git' 'winget install --id Git.Git' }
  $v = Get-SbclVersion
  if (-not $v) { Miss 'SBCL' ".\scripts\setup.ps1   (installs $SbclVersion)" }
  elseif ($v -ne $SbclVersion) { Write-Host "  WARN    SBCL $v installed, pin is $SbclVersion" -ForegroundColor Yellow }
  else { Pass "SBCL $v" }
  if (Find-SbclHome) { Pass "SBCL_HOME resolvable ($(Find-SbclHome))" }
  elseif ($v) { Write-Host "  WARN    cannot locate sbcl.core -- set SBCL_HOME by hand" -ForegroundColor Yellow }
  if (Test-Path (Join-Path $QlHome 'setup.lisp')) { Pass "Quicklisp at $QlHome (dist $(Get-QlDist))" }
  else { Miss 'Quicklisp' '.\scripts\setup.ps1' }
  # Checking the directory EXISTS is not enough: a checkout at the wrong commit is the exact
  # drift coalton.pin exists to catch, and it stays invisible until something behaves oddly.
  if (Test-Path (Join-Path $CoaltonDir '.git')) {
    $head = (& git -C $CoaltonDir rev-parse HEAD 2>$null)
    $want = (& git -C $CoaltonDir rev-parse "$CoaltonRef^{commit}" 2>$null)
    if ($want -and $head -and $head.Trim() -eq $want.Trim()) { Pass "Coalton at $CoaltonDir (pinned $CoaltonRef)" }
    elseif (-not $want) { Miss "Coalton pin $CoaltonRef not present in $CoaltonDir" '.\scripts\setup.ps1   (fetches; or the remote is wrong)' }
    else { Miss "Coalton is at $($head.Trim().Substring(0,8)), pin says $CoaltonRef" '.\scripts\setup.ps1' }
  }
  else { Miss 'Coalton checkout' '.\scripts\setup.ps1' }
  Write-Host "      (deep check -- which Coalton actually LOADS: sbcl --script scripts/check-coalton.lisp)" -ForegroundColor DarkGray

  # NAMES THE FILE, not just "present". The whole of #229 is that this machine reported
  # the sqlite backend green on a DLL supplied by an unrelated Delphi installation, so a
  # bare PASS here would be the same lie one level up. Say which file the loader will find
  # first, and warn when it is not the one this script provisioned.
  $dll = Find-SqliteDll
  $cmd = Get-Command sbcl -ErrorAction SilentlyContinue
  $ours = if ($cmd) { Join-Path (Split-Path -Parent $cmd.Source) 'sqlite3.dll' } else { $null }
  if (-not $dll) {
    Miss 'sqlite3.dll (cl-sqlite needs it; mnemosyne cannot load without it)' '.\scripts\setup.ps1'
    Write-Host '            Windows ships winsqlite3.dll, which WORKS but is a name cl-sqlite never tries.' -ForegroundColor DarkGray
  }
  elseif ($ours -and $dll -eq $ours) { Pass "sqlite3.dll (provisioned) -- $dll" }
  else {
    Write-Host "  WARN    sqlite3.dll comes from $dll" -ForegroundColor Yellow
    Write-Host '            NOT provisioned by setup.ps1. mnemosyne loads because something else on this' -ForegroundColor DarkGray
    Write-Host '            machine supplies it, so a green sqlite backend here says nothing about a clean box.' -ForegroundColor DarkGray
    Write-Host '            fix: .\scripts\setup.ps1   (installs the pinned build where the loader looks first)' -ForegroundColor DarkGray
    # AND IT COUNTS AS MISSING. The WARN above is prose, and nothing downstream reads prose:
    # without this the summary still says "this machine is provisioned" and -Check still exits
    # 0, which is #229's own defect one level up -- a machine carried by an unrelated Delphi
    # install reporting green, now with a paragraph explaining that the green means nothing.
    # This branch is reachable ONLY when the provisioned copy is absent (Find-SqliteDll looks
    # beside sbcl.exe first), so WARN here means NOT PROVISIONED, which is what missing is.
    # The wording above is left exactly as it stands: verify-clean-machine.ps1 (#230) greps
    # for 'NOT provisioned by setup.ps1', so it is a contract, not just a message.
    $script:missing++
  }

  # OPT, not MISSING: this one does not fail provisioning. Everything except aion/uv builds
  # and runs without a C compiler, which is the whole point of keeping native code off the
  # load path -- a Windows user typing `quickload` must never hit a C build.
  $msvc = Find-Msvc
  if ($msvc) { Pass "MSVC C++ tools -- $($msvc.Name)   (aion/uv only)" }
  else {
    Write-Host '  OPT     MSVC C++ tools not found -- needed ONLY to build libuv for aion/uv' -ForegroundColor DarkGray
    Write-Host "       fix: $MsvcInstallHint" -ForegroundColor DarkGray
    Write-Host '            then: sbcl --script scripts/build-libuv.lisp' -ForegroundColor DarkGray
  }

  if ($missing -gt 0) { Write-Host 'missing prerequisites (see above).' -ForegroundColor Red; exit 1 }
  Info 'this machine is provisioned.'
  exit 0
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die 'git is required (winget install --id Git.Git)' }

$v = Get-SbclVersion
if (-not $v) { Install-Sbcl }
elseif ($v -ne $SbclVersion) { Note "SBCL $v present, pin is $SbclVersion -- leaving it alone (remove it first to install the pin)" }
else { Note "SBCL $v present" }
Export-SbclEnv
if (-not (Test-Path (Join-Path $QlHome 'setup.lisp'))) { Install-Quicklisp }
Set-QlDist
Install-Coalton
Install-Sqlite

Info "provisioned. Next: sbcl --dynamic-space-size 4096 --script bootstrap.lisp   (from $Root)"
