#!/usr/bin/env pwsh
<#
.SYNOPSIS
  #111 -- prove an update does not touch ~/.<appname>, with a real installer.

.DESCRIPTION
  hyperion/docs/desktop-distribution-design.md section 1 says ~/.<appname> is "never
  touched by an update ... the update path must guarantee it survives". This runs the
  guarantee rather than restating it:

    1. build a real executable and package it as a real NSIS (or Inno) installer, twice --
       version 1.0.0 and version 1.1.0
    2. install 1.0.0 silently, the way a user would
    3. create and POPULATE the real ~/.<appname>, and hold an open handle on its database
    4. publish 1.1.0: a real Ed25519 key, a real signed manifest, a real signed payload
    5. run the real hyperion/update apply path, which finds the install through the
       registry key the installer wrote and hands the staged installer to NSIS or Inno
    6. assert the update ACTUALLY LANDED (the installed VERSION changed), and only then
       assert ~/.<appname> is byte-identical
    7. uninstall, and assert it survived that too

  THE POPULATION IS AS MUCH THE TEST AS THE ASSERTION. A test against an empty directory
  passes for an implementation that deletes everything in it, so the directory carries a
  config file, a binary database, files whose names look like build output, a dist/
  subdirectory holding a file named exactly like the update payload, and an uninstall.exe
  -- a name the BUNDLE owns, so an implementation tidying away "its own" files by name
  reaches into the wrong tree.

  -Control INVERTS THE TEST and is the reason a green run means anything. It rebuilds the
  1.1.0 installer with one line added -- NSIS `RMDir /r "$PROFILE\.<appname>"', or Inno's
  [InstallDelete] equivalent -- and then requires the harness to REPORT THE LOSS. A
  survival test that has never been shown to fail is indistinguishable from one that
  cannot.

  WHAT THIS DOES NOT COVER: macOS and Linux, which is #72's blocker and #111's openly
  unrun half; and the shutdown ordering, which is *before-apply* and was measured under
  pre-publication issue 76. The client half of #111 -- every refusal path, on every platform -- is in
  hyperion/tests/update-client-tests.lisp, with *launch-installer* stubbed. Neither half
  is evidence about the other; the seam is exactly the launch.

.PARAMETER Format
  nsis, inno, or both (default). Both packagings make the same promise and neither has
  been asked to keep it.

.PARAMETER Control
  Run the inverted test: an installer that DOES delete the data directory must be caught.

.PARAMETER DatabaseHandle
  held (default) or released: whether the harness holds app.db open across the update (#122).

  held models a running application, which is what an in-app updater faces. But Windows
  refuses to delete a file that is open this way, so with the handle held app.db survives
  whatever the installer does: its survival shows nothing about the installer, and the
  control cannot delete it (measured: -Control reports 8 of the 9 entries, never app.db).

  released opens no handle, so app.db is protected only by the installer's behaviour. With
  -Control the run must then report app.db as lost, and fails if it does not. Without
  -Control, app.db surviving is evidence about the installer, as the other eight entries are.

.PARAMETER KeepWork
  Leave the working directory behind for inspection.

.EXAMPLE
  .\scripts\verify-appdata-survives.ps1
.EXAMPLE
  .\scripts\verify-appdata-survives.ps1 -Format nsis -Control
.EXAMPLE
  .\scripts\verify-appdata-survives.ps1 -Format nsis -Control -DatabaseHandle released
#>
[CmdletBinding()]
param(
  [ValidateSet('nsis', 'inno', 'both')][string]$Format = 'both',
  [switch]$Control,
  [ValidateSet('held', 'released')][string]$DatabaseHandle = 'held',
  [switch]$KeepWork
)

$ErrorActionPreference = 'Stop'
$Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Root = Split-Path -Parent $Here

function Info($m) { Write-Host "==> $m" -ForegroundColor Blue }
function Note($m) { Write-Host "    $m" -ForegroundColor DarkGray }
function Good($m) { Write-Host "  OK $m" -ForegroundColor Green }
function Bad($m) { Write-Host "FAIL $m" -ForegroundColor Red }
function Die($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# The app name is deliberately unlovely and deliberately unique-ish. It becomes a real
# directory in the real home directory and a real HKCU key, and both are removed at the
# end -- so it must not be a name anything else could plausibly own.
$App = 'ouranos-appdata-probe'
$V1 = '1.0.0'
$V2 = '1.1.0'
$DataDir = Join-Path $HOME ".$App"
$BaseUrl = 'https://appdata-survival.invalid/dist'   # never resolves: see the driver's header

# NOT `$IsWindows'. That automatic variable arrived with PowerShell *Core* 6 and Windows
# PowerShell 5.1 -- the PowerShell a stock Windows box HAS -- does not define it, so
# `-not $null' is true and this guard refused on the one OS the harness supports. The
# message made it worse than a bare failure: it asserts "this harness is Windows-only,
# and says so rather than pretending otherwise" while standing on Windows, which sends
# the reader to #72 instead of to the guard. Same defect as verify-clean-machine.ps1
# carried (pre-publication issue 230); `$env:OS' is Windows_NT on every Windows since NT, absent elsewhere,
# and reads the same under 5.1 and 7.
if ($env:OS -ne 'Windows_NT') {
  Die "#111's other two thirds are blocked on #72. This harness is Windows-only, and says so rather than pretending otherwise."
}

# ---------------------------------------------------------------------------
# the app-data directory: populate, snapshot, compare
# ---------------------------------------------------------------------------

function New-AppData {
  param([string]$Dir)
  # REFUSE rather than overwrite. This is a real path in a real home directory; if
  # something is already there it is not ours to clear, and the harness has no business
  # guessing which.
  if (Test-Path -LiteralPath $Dir) {
    Die "$Dir already exists. Remove it by hand if it is left over from a previous run; this harness will not delete a directory it did not create."
  }
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $Dir 'dist') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $Dir 'exports') | Out-Null

  $utf8 = New-Object Text.UTF8Encoding($false)
  [IO.File]::WriteAllText((Join-Path $Dir 'config.toml'), "config_version = 3`nsettings = `"kept`"`n", $utf8)
  # A real SQLite file begins with exactly these 16 bytes, so an implementation that
  # classifies by CONTENT rather than by name also sees a database sitting here. The
  # database is the file whose loss is least recoverable, and the one a real app holds
  # open -- which this harness then does.
  $db = New-Object byte[] 512
  $magic = [Text.Encoding]::ASCII.GetBytes('SQLite format 3')
  [Array]::Copy($magic, $db, $magic.Length)
  [IO.File]::WriteAllBytes((Join-Path $Dir 'app.db'), $db)
  # Named like build output on purpose: an implementation that "cleans up" by pattern is
  # the one that passes every other version of this test.
  [IO.File]::WriteAllText((Join-Path $Dir 'cache.fasl'), "not a fasl`n", $utf8)
  [IO.File]::WriteAllText((Join-Path $Dir 'build.log'), "not a build log`n", $utf8)
  # A name the BUNDLE owns. An implementation removing "its own" files by name reaches
  # into the wrong tree entirely.
  [IO.File]::WriteAllText((Join-Path $Dir 'uninstall.exe'), "not the uninstaller`n", $utf8)
  # Named exactly like the update payload that is about to be installed.
  [IO.File]::WriteAllText((Join-Path $Dir "dist\$App-$V2-setup.exe"), "not the installer`n", $utf8)
  [IO.File]::WriteAllText((Join-Path $Dir 'exports\2026-09-01.csv'), "id,amount`n1,42`n", $utf8)
}

function Get-FileSha256 {
  param([string]$Path)
  # NOT Get-FileHash. This harness deliberately holds an open handle on app.db for the
  # whole update -- a real application holds its database open, and "close the app first"
  # is not what an in-app updater promises -- and Get-FileHash cannot read a file that is
  # open elsewhere. FileShare ReadWrite here says: somebody else may have this, and may
  # even be writing it. Which is exactly the situation being tested.
  $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  try {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash($fs)).Replace('-', '') }
    finally { $sha.Dispose() }
  } finally { $fs.Dispose() }
}

function Get-TreeSnapshot {
  param([string]$Root)
  # A directory that no longer exists has no entries, so every entry of the earlier snapshot
  # compares as VANISHED. Before this, Resolve-Path threw on it and the run ended in an error
  # instead of a report (#122) -- which was unreachable only while the harness held app.db
  # open, because a directory with an open file in it cannot be deleted.
  if (-not (Test-Path -LiteralPath $Root)) { return @() }
  $prefix = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\') + '\'
  Get-ChildItem -LiteralPath $Root -Recurse -Force | ForEach-Object {
    $rel = $_.FullName.Substring($prefix.Length)
    if ($_.PSIsContainer) {
      [pscustomobject]@{ Path = "$rel\"; Hash = '<dir>'; Written = '' }
    } else {
      [pscustomobject]@{
        Path    = $rel
        Hash    = Get-FileSha256 $_.FullName
        Written = $_.LastWriteTimeUtc.Ticks
      }
    }
  } | Sort-Object Path
}

function Compare-TreeSnapshot {
  param($Before, $After)
  # Names every difference. A digest of the whole tree could only say THAT something
  # changed, and the useful half of a red run is which file.
  $diffs = @()
  $afterMap = @{}
  foreach ($a in $After) { $afterMap[$a.Path] = $a }
  $beforeMap = @{}
  foreach ($b in $Before) { $beforeMap[$b.Path] = $b }
  foreach ($b in $Before) {
    $a = $afterMap[$b.Path]
    if ($null -eq $a) { $diffs += "VANISHED  $($b.Path)" }
    elseif ($a.Hash -ne $b.Hash) { $diffs += "MODIFIED  $($b.Path)" }
    # An identical rewrite is still a touch, and section 1 says never TOUCHED.
    elseif ($a.Written -ne $b.Written) { $diffs += "RESTAMPED $($b.Path)" }
  }
  foreach ($a in $After) {
    if (-not $beforeMap.ContainsKey($a.Path)) { $diffs += "APPEARED  $($a.Path)" }
  }
  , $diffs
}

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------

$sbcl = (Get-Command sbcl -ErrorAction SilentlyContinue).Source
if (-not $sbcl) { Die "sbcl is not on PATH. Run scripts/setup.ps1 first." }
& (Join-Path $Here 'build-installer.ps1') -Check | Out-Null
if ($LASTEXITCODE -ne 0) { Die "no installer toolchain -- see build-installer.ps1 -Check" }

$formats = if ($Format -eq 'both') { @('nsis', 'inno') } else { @($Format) }

# ONE TREE, STATED. bootstrap.lisp writes a source-registry drop-in naming a single
# checkout, so without this a driver running here could silently load another worktree's
# hyperion/update -- and the result would be a green run about somebody else's code.
# On Windows the entry separator is ';', not ':' -- a colon is read as part of "d:".
$env:CL_SOURCE_REGISTRY = "$Root//;"

$Work = Join-Path $env:TEMP "ouranos-appdata-$PID"
if (Test-Path $Work) { Remove-Item -Recurse -Force $Work }
New-Item -ItemType Directory -Force -Path $Work | Out-Null

Info "#111 -- an update must not touch ~/.<appname>"
Note "app           : $App"
Note "data          : $DataDir"
Note "work          : $Work"
Note "formats       : $($formats -join ', ')"
Note ("mode          : " + $(if ($Control) { 'CONTROL -- an installer that DELETES the data must be caught' } else { 'the real installers, which must not touch it' }))
Note ("app.db handle : " + $(if ($DatabaseHandle -eq 'held') { 'held open across the update (a running app; app.db survival shows nothing about the installer)' } else { 'released (app.db is protected only by what the installer does)' }))

# ---------------------------------------------------------------------------
# a real executable, built once and shared by both versions
# ---------------------------------------------------------------------------

$ProbeExe = Join-Path $Work 'probe.exe'
Info "building the probe application (a real SBCL executable)"
& $sbcl --dynamic-space-size 2048 --script (Join-Path $Here 'appdata-survival-probe.lisp') --out ($ProbeExe.Replace('\', '/'))
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $ProbeExe)) { Die "could not build the probe application" }
Note ("probe.exe: {0:N0} bytes" -f (Get-Item $ProbeExe).Length)

function New-Bundle {
  param([string]$Version)
  $dir = Join-Path $Work "$App-$Version-windows-x86-64"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  Copy-Item $ProbeExe (Join-Path $dir "$App.exe")
  $utf8 = New-Object Text.UTF8Encoding($false)
  # The installed VERSION file is how the harness knows the update actually landed. Without
  # it, an installer that silently did nothing would leave the data directory untouched and
  # the test would pass while proving the opposite of what it claims.
  [IO.File]::WriteAllText((Join-Path $dir 'VERSION'), "$Version`n", $utf8)
  [IO.File]::WriteAllText((Join-Path $dir 'README.txt'), "throwaway app for #111`n", $utf8)
  $dir
}

# ---------------------------------------------------------------------------
# installer building, including the control's sabotaged variant
# ---------------------------------------------------------------------------

function New-Installer {
  param([string]$BundleDir, [string]$Fmt, [string]$Out, [switch]$Sabotage)

  if (-not $Sabotage) {
    & (Join-Path $Here 'build-installer.ps1') $BundleDir -Format $Fmt -Out $Out -NoWebView2 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Out)) { Die "could not build the $Fmt installer" }
    return
  }

  # THE CONTROL. One line added to a COPY of the shipped installer script -- the shipped
  # one is never edited -- teaching it to delete the user's data directory during install.
  # Everything else about the run is identical, so a difference in the verdict can only
  # come from that line.
  $leaf = Split-Path -Leaf $BundleDir
  if ($leaf -notmatch '^(?<app>.+)-(?<ver>\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)-windows-x86-64$') {
    Die "cannot parse bundle name '$leaf'"
  }
  $a = $matches['app']; $v = $matches['ver']
  $exe = "$a.exe"

  if ($Fmt -eq 'nsis') {
    $src = Get-Content (Join-Path $Here 'installers\windows.nsi') -Raw
    # A literal .Replace, never -replace: .NET reads ${APPNAME} in a replacement string as
    # a named-group substitution, and naming the directory is the entire point of the line.
    $anchor = '  SetOutPath "$INSTDIR"'
    if (-not $src.Contains($anchor)) { Die "windows.nsi no longer contains the control's anchor line" }
    $sabotageText = '  RMDir /r "$PROFILE\.${APPNAME}"   ; #111 CONTROL -- deliberate data loss' + "`n" + $anchor
    $patched = $src.Replace($anchor, $sabotageText)
    $nsi = Join-Path $Work 'control-windows.nsi'
    Set-Content -LiteralPath $nsi -Value $patched -NoNewline
    $makensis = (Get-Command makensis.exe -ErrorAction SilentlyContinue).Source
    if (-not $makensis) {
      foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\NSIS', 'HKLM:\SOFTWARE\NSIS', 'HKCU:\SOFTWARE\NSIS')) {
        $d = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).'(default)'
        if ($d -and (Test-Path (Join-Path $d 'makensis.exe'))) { $makensis = Join-Path $d 'makensis.exe'; break }
      }
    }
    if (-not $makensis) { foreach ($p in @("$env:ProgramFiles\NSIS\makensis.exe", "C:\bin\NSIS\makensis.exe")) { if (Test-Path $p) { $makensis = $p; break } } }
    if (-not $makensis) { Die "makensis not found for the control build" }
    & $makensis /NOCD "/DAPPNAME=$a" "/DVERSION=$v" "/DVIVERSION=$v.0" `
      "/DSRCDIR=$BundleDir" "/DOUTFILE=$Out" "/DEXENAME=$exe" $nsi | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Out)) { Die "the control NSIS build failed" }
  } else {
    $src = Get-Content (Join-Path $Here 'installers\windows.iss') -Raw
    $sabotageText = @'

[InstallDelete]
; #111 CONTROL -- deliberate data loss
Type: filesandordirs; Name: "{%USERPROFILE}\.{#APPNAME}"
'@
    $patched = $src + $sabotageText
    $iss = Join-Path $Work 'control-windows.iss'
    Set-Content -LiteralPath $iss -Value $patched -NoNewline
    $iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
    if (-not $iscc) {
      foreach ($p in @("$env:ProgramFiles\Inno Setup 7\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
                       "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe")) { if (Test-Path $p) { $iscc = $p; break } }
    }
    if (-not $iscc) { Die "ISCC not found for the control build" }
    & $iscc "/DAPPNAME=$a" "/DVERSION=$v" "/DSRCDIR=$BundleDir" `
      "/DOUTDIR=$(Split-Path -Parent $Out)" "/DOUTBASE=$([IO.Path]::GetFileNameWithoutExtension($Out))" `
      "/DEXENAME=$exe" $iss | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Out)) { Die "the control Inno build failed" }
  }
}

function Invoke-Installer {
  param([string]$Installer, [string]$Fmt, [string]$InstallDir)
  # The same flags hyperion/update's launch-installer builds, because a first install that
  # went in some other way would not be the thing an update replaces.
  $cliArgs = if ($Fmt -eq 'nsis') { "/S /D=$InstallDir" }
             else { "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR=`"$InstallDir`"" }
  $p = Start-Process -FilePath $Installer -ArgumentList $cliArgs -PassThru -Wait
  if ($p.ExitCode -ne 0) { Die "$Fmt installer exited $($p.ExitCode)" }
}

function Get-InstalledVersion {
  param([string]$InstallDir)
  $f = Join-Path $InstallDir 'VERSION'
  if (Test-Path -LiteralPath $f) { (Get-Content -LiteralPath $f -Raw).Trim() } else { $null }
}

# ---------------------------------------------------------------------------
# one run, one packaging
# ---------------------------------------------------------------------------

function Invoke-Run {
  param([string]$Fmt)

  Write-Host ''
  Info "=== $Fmt ==="
  $script:runFailures = @()
  $runDir = Join-Path $Work $Fmt
  $pub = Join-Path $runDir 'pub'
  $installDir = Join-Path $runDir 'Install'
  New-Item -ItemType Directory -Force -Path $pub | Out-Null

  # --- build both versions -------------------------------------------------
  $b1 = New-Bundle $V1
  $b2 = New-Bundle $V2
  $i1 = Join-Path $runDir "$App-$V1-setup.exe"
  # 1.1.0 is published, so it must sit in the directory the manifest is generated from and
  # must carry the name update-manifest.lisp's artifact pattern looks for.
  $i2 = Join-Path $pub "$App-$V2-setup.exe"
  Info "building $Fmt installers for $V1 and $V2"
  New-Installer -BundleDir $b1 -Fmt $Fmt -Out $i1
  New-Installer -BundleDir $b2 -Fmt $Fmt -Out $i2 -Sabotage:$Control

  # --- install 1.0.0 -------------------------------------------------------
  Info "installing $V1 silently into $installDir"
  Invoke-Installer -Installer $i1 -Fmt $Fmt -InstallDir $installDir
  $v = Get-InstalledVersion $installDir
  if ($v -ne $V1) { Die "after installing $V1 the installed VERSION is '$v'" }
  $reg = (Get-ItemProperty -Path "HKCU:\Software\$App" -Name InstallDir -ErrorAction SilentlyContinue).InstallDir
  if (-not $reg) { Die "the $Fmt installer did not write HKCU\Software\$App\InstallDir" }
  Good "installed $V1; HKCU\Software\$App\InstallDir = $reg"
  if ($reg.TrimEnd('\') -ne $installDir.TrimEnd('\')) {
    # Not fatal to #111, but it IS the value the updater will act on, so say it loudly.
    $script:runFailures += "the installer recorded InstallDir '$reg', not the directory it was given ('$installDir')"
  }

  # --- populate the real ~/.<appname> --------------------------------------
  Info "populating $DataDir"
  New-AppData -Dir $DataDir
  $before = Get-TreeSnapshot $DataDir
  # NON-VACUITY. An empty directory survives everything. Assert the fixture exists before
  # asserting it survived, or a broken populate step turns this into a test of nothing.
  if ($before.Count -ne 9) { Die "the fixture holds $($before.Count) entries, not 9 -- populate is broken" }
  foreach ($want in @('config.toml', 'app.db', 'cache.fasl', 'build.log', 'uninstall.exe')) {
    if (-not ($before.Path -contains $want)) { Die "the fixture is missing $want" }
  }
  Good "9 entries, including a database, two build-output-shaped names and an uninstall.exe"

  # A REAL APP HOLDS ITS DATABASE OPEN. Held across the whole update, because "the user
  # must close the app first" is not what an in-app updater promises. With
  # -DatabaseHandle released no handle is opened, so the installer alone decides whether
  # app.db survives (#122).
  $db = $null
  if ($DatabaseHandle -eq 'held') {
    $db = [IO.File]::Open((Join-Path $DataDir 'app.db'), 'Open', 'ReadWrite', 'Read')
  }
  try {
    # --- publish 1.1.0 -----------------------------------------------------
    Info "publishing $V2 -- a real key, a real signed manifest, a real signed payload"
    $keys = & $sbcl --script (Join-Path $Here 'update-manifest.lisp') keygen
    $m = $keys | Select-String -Pattern '^public\s+\(ships inside the bundle\):\s*(.+)$'
    if (-not $m) { Die "could not read a public key out of update-manifest.lisp keygen" }
    $public = $m.Matches[0].Groups[1].Value.Trim()
    $private = if ($keys.Count -gt 2) { ($keys[2]).Trim() } else { '' }
    if (-not $public -or -not $private) { Die "could not read a key pair out of update-manifest.lisp keygen" }
    # An environment variable, not --key-file: argv is visible to every process on the
    # machine, and update-manifest.lisp's own sign subcommand would otherwise treat the
    # key file's PATH as another file to sign.
    $env:OURANOS_SIGNING_KEY = $private
    & $sbcl --script (Join-Path $Here 'update-manifest.lisp') generate `
      --dist ($pub.Replace('\', '/')) --product $App --version $V2 --base-url $BaseUrl | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "update-manifest.lisp generate failed" }

    # THE MANIFEST IS NOT PATCHED HERE ANY MORE. It used to be: update-manifest.lisp
    # hard-coded "nsis" for windows-x86-64 and could not declare an Inno release at all,
    # while build-installer.ps1 -Format inno writes its artifact under exactly the name the
    # generator's pattern matches -- so this harness had to rewrite the field and re-sign
    # in order to test the packaging the tree ships. The generator now DETECTS the
    # packaging from the artifact's own bytes (pre-publication issue 77), so the field is a statement about
    # what is being published rather than about what a table assumed.
    #
    # Asserted rather than trusted, because the alternative failure is silent: a manifest
    # declaring the wrong Windows format hands one installer the other's flags, which
    # installs nothing and exits 0. The behavioural half of this assertion is the "did the
    # update land" check further down -- it is what would go red if the field were wrong.
    $declared = ([regex]'"format"\s*:\s*"([^"]+)"').Match(
                  [IO.File]::ReadAllText((Join-Path $pub 'stable.json'))).Groups[1].Value
    if ($declared -ne $Fmt) {
      Die "the generated manifest declares format '$declared' for a $Fmt artifact"
    }
    Good "the generator read the artifact and declared format '$declared'"

    # NOT RENAMED ANY MORE. This used to move latest.json to stable.json, because the
    # generator wrote one name and the client asks for the other -- the third instance of
    # this subsystem's producing-and-consuming-a-contract-twice defect, and the harness
    # was quietly papering over it. The generator now writes <channel>.json (pre-publication issue 77).

    # --- the real apply ----------------------------------------------------
    $marker = Join-Path $runDir 'marker.txt'
    $env:OURANOS_PROBE_MARKER = $marker
    Info "applying -- hyperion/update, the real launch-installer, the real $Fmt installer"
    & $sbcl --dynamic-space-size 2048 --script (Join-Path $Here 'appdata-survival-driver.lisp') `
      --dist ($pub.Replace('\', '/')) --product $App --channel stable --installed-version $V1 `
      --app-name $App --public-key $public | Out-Host
    if ($LASTEXITCODE -ne 0) { Die "the apply path did not reach the installer (exit $LASTEXITCODE)" }

    # The installer is a detached process, so both of its outcomes are waited for
    # SEPARATELY. The bundle changes early -- File /r is near the top of the install
    # section -- while the relaunch is the very last thing a silent install does, so
    # testing for the marker the moment VERSION appears is a race the harness loses by
    # reporting a failure that did not happen.
    Info "waiting for the installer to replace the bundle"
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline -and (Get-InstalledVersion $installDir) -ne $V2) {
      Start-Sleep -Milliseconds 500
    }
    $v = Get-InstalledVersion $installDir
    Info "waiting for the application to come back"
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $marker)) {
      Start-Sleep -Milliseconds 500
    }
    # And a moment more, so a relaunch that is merely slow is not read as one that never
    # happened -- and so anything the relaunched app might do to the data directory has
    # happened BEFORE the snapshot rather than after it.
    Start-Sleep -Seconds 3

    # --- the assertions ----------------------------------------------------
    Write-Host ''
    # THE ANTI-VACUITY CHECK, FIRST. An installer that silently did nothing leaves the data
    # directory perfectly intact, and this test would report success for the strongest
    # possible failure of the update path.
    if ($v -ne $V2) {
      $script:runFailures += "the update did not land: installed VERSION is '$v', expected '$V2' -- every survival claim below would be vacuous"
      Bad "the update did not land (VERSION = '$v')"
    } else {
      Good "the update landed: installed VERSION is now $V2"
    }
    if (Test-Path -LiteralPath $marker) {
      Good ("the app was relaunched after the silent install: " + ((Get-Content $marker -Raw).Trim() -split "`n")[-1])
    } else {
      # Section 7: "the installer ran" and "the user got their application back" are
      # separate claims, and only the second is what an update promises.
      $script:runFailures += "no marker file: the silent $Fmt install did not relaunch the application"
      Bad "the application was not relaunched"
    }

    $after = Get-TreeSnapshot $DataDir
    $diffs = Compare-TreeSnapshot -Before $before -After $after
    # Name the worst case outright: the directory itself is gone, not only its contents.
    if (-not (Test-Path -LiteralPath $DataDir)) { $diffs = @("VANISHED  $DataDir itself (the whole directory)") + $diffs }
    if ($Control) {
      if ($diffs.Count -eq 0) {
        $script:runFailures += "CONTROL: an installer that deletes ~/.<appname> was reported as having touched nothing -- this harness cannot fail, so its green runs mean nothing"
        Bad "the control was NOT detected"
      } else {
        Good "the control was detected -- $($diffs.Count) difference(s):"
        $diffs | ForEach-Object { Note $_ }
      }
      # THE DATABASE IS THE FILE A USER WOULD LOSE (#122). With no handle on it, a control
      # that deletes the data directory must delete app.db too, and the run must say so.
      # With the handle held Windows protects it, and that is reported rather than passed.
      $dbLost = [bool]($diffs | Where-Object { $_ -match '^VANISHED\s+app\.db$' })
      if ($DatabaseHandle -eq 'released') {
        if ($dbLost) {
          Good "the control reached the database: app.db was deleted and reported"
        } else {
          $script:runFailures += "CONTROL (handle released): the installer deleted the data directory but app.db was not reported lost -- the harness cannot see the loss that matters most"
          Bad "the control did NOT reach app.db"
        }
      } elseif (-not $dbLost) {
        Note "app.db survived because this harness holds it open; run with -DatabaseHandle released to show the control reaching it"
      }
    } else {
      if ($diffs.Count -eq 0) {
        Good "$DataDir is byte-identical after a real $Fmt update ($($before.Count) entries)"
        if ($DatabaseHandle -eq 'held') {
          Note "app.db was held open, so its survival is Windows refusing the delete; -DatabaseHandle released shows it survives on the installer's behaviour"
        } else {
          Good "including app.db, which had no handle on it, so the installer left it alone"
        }
      } else {
        $script:runFailures += "the update touched ~/.<appname>: $($diffs -join '; ')"
        Bad "the update touched the data directory:"
        $diffs | ForEach-Object { Note $_ }
      }
    }
  } finally {
    if ($db) { $db.Close(); $db.Dispose() }

    # --- and the uninstall -------------------------------------------------
    # windows.nsi's Uninstall section and windows.iss's empty [UninstallDelete] both
    # promise the same thing, and an uninstall is where RMDir /r actually appears. Not
    # #111's stated scope, and cheap to ask while everything is standing.
    $uninst = if ($Fmt -eq 'nsis') { Join-Path $installDir 'uninstall.exe' } else { Join-Path $installDir 'unins000.exe' }
    if (Test-Path -LiteralPath $uninst) {
      Info "uninstalling"
      $ua = if ($Fmt -eq 'nsis') { '/S' } else { '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }
      Start-Process -FilePath $uninst -ArgumentList $ua -Wait | Out-Null
      Start-Sleep -Seconds 3
      if ($Control) {
        Note "control run: the uninstall check would be measuring the sabotage, and is skipped"
      } elseif (Test-Path -LiteralPath $DataDir) {
        $d2 = Compare-TreeSnapshot -Before $before -After (Get-TreeSnapshot $DataDir)
        if ($d2.Count -eq 0) {
          Good "$DataDir survived the uninstall too, byte-identical"
        } else {
          $script:runFailures += "the UNINSTALL touched ~/.<appname>: $($d2 -join '; ')"
          Bad "the uninstall touched the data directory"
          $d2 | ForEach-Object { Note $_ }
        }
      } else {
        $script:runFailures += "the uninstall deleted $DataDir entirely"
        Bad "the uninstall deleted the data directory"
      }
    } else {
      Note "no uninstaller at $uninst -- skipping the uninstall check"
    }

    # --- put the machine back ----------------------------------------------
    # Real keys, a real Start-menu entry and a real directory in the real home directory.
    # In the FINALLY because a run that throws must still take them with it -- otherwise
    # the next run refuses to start, correctly and unhelpfully.
    Remove-Item -Recurse -Force -LiteralPath $DataDir -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force -LiteralPath $installDir -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force -Path "HKCU:\Software\$App" -ErrorAction SilentlyContinue
    Remove-Item -Force -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$App" -ErrorAction SilentlyContinue
    Remove-Item -Force -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\${App}_is1" -ErrorAction SilentlyContinue
    Remove-Item -Force -LiteralPath (Join-Path ([Environment]::GetFolderPath('Programs')) "$App.lnk") -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force -LiteralPath (Join-Path ([Environment]::GetFolderPath('Programs')) $App) -ErrorAction SilentlyContinue
  }

  , $script:runFailures
}

# ---------------------------------------------------------------------------

$allFailures = @()
try {
  foreach ($f in $formats) { $allFailures += (Invoke-Run -Fmt $f) }
} finally {
  if ($KeepWork) { Note "work kept at $Work" }
  else { Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue }
  Remove-Item Env:\OURANOS_SIGNING_KEY -ErrorAction SilentlyContinue
  Remove-Item Env:\OURANOS_PROBE_MARKER -ErrorAction SilentlyContinue
}

Write-Host ''
if ($allFailures.Count -eq 0) {
  if ($Control) {
    Info "CONTROL PASSED: the harness caught an installer that deleted ~/.<appname>, in every packaging tested."
  } else {
    Info "PASSED: a real update, a real installer, a populated ~/.<appname>, byte-identical afterwards."
    Note "Windows only. macOS and Linux are blocked on #72 and are openly unrun."
  }
  exit 0
}
Bad "$($allFailures.Count) failure(s):"
$allFailures | ForEach-Object { Write-Host "     - $_" -ForegroundColor Red }
exit 1
