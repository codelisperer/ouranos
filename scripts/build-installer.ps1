#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Build the Windows installer for a Hyperion desktop app bundle (NSIS).

.DESCRIPTION
  Takes a bundle produced by scripts/build-desktop-app.lisp and produces
  <app>-<version>-setup.exe -- which is BOTH the human download and the update payload
  (hyperion/docs/desktop-distribution-design.md §9, ADR-0010).

  One entry point for dev machines and CI alike; the workflow merely calls this, the same
  way it calls setup.ps1 and build-desktop-app.lisp.

  Needs makensis. It is not on PATH by default after an NSIS install, so the usual install
  locations are probed too:
      winget install NSIS.NSIS        (or: choco install nsis -y)

.PARAMETER Bundle
  The bundle directory, e.g. dist\coalton-repl-0.1.0-windows-x86-64.

.PARAMETER Out
  Output installer path. Defaults to <bundle-parent>\<app>-<version>-setup.exe.

.PARAMETER Check
  Report whether this machine can build an installer, and exit.

.EXAMPLE
  .\scripts\build-installer.ps1 -Check
.EXAMPLE
  .\scripts\build-installer.ps1 dist\coalton-repl-0.1.0-windows-x86-64
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Bundle,
  [string]$Out,
  # WHICH PACKAGING. Both produce a per-user install under %LOCALAPPDATA%\Programs and both
  # write HKCU\Software\<APPNAME>\InstallDir, which is the contract hyperion/update reads --
  # so an app may switch between them without shipping a new client. The manifest's
  # per-platform `format' field tells an installed client which one it is getting.
  #
  # inno exists for CODE SIGNING: a SignTool directive that signs the installer AND the
  # uninstaller during the build, rather than a post-build step somebody has to remember.
  [ValidateSet('nsis', 'inno')][string]$Format = 'nsis',
  # Name of a SignTool configured in Inno (ISCC /S<name>=<command>) or in the Inno IDE.
  # Ignored for -Format nsis, which has no signing support of its own.
  [string]$SignTool,
  [switch]$Check,
  [switch]$NoWebView2      # skip embedding the WebView2 bootstrapper (smaller, but a
                           # machine without the runtime gets no window)
)

$ErrorActionPreference = 'Stop'
$Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Nsi = Join-Path $Here 'installers\windows.nsi'
$Iss = Join-Path $Here 'installers\windows.iss'

function Info($m) { Write-Host "==> $m" -ForegroundColor Blue }
function Note($m) { Write-Host "    $m" -ForegroundColor DarkGray }
function Die($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

function Find-Iscc {
  $c = Get-Command ISCC.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  # Inno records itself as an uninstall entry carrying an InstallLocation, which is the only
  # reliable answer when it was installed somewhere unguessable, or is a major version this
  # script has never heard of. Checked before the hard-coded paths for exactly that reason --
  # Inno Setup 7 would not be found by a list written when 6 was current.
  foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                   'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    $hit = Get-ItemProperty $k -ErrorAction SilentlyContinue |
             Where-Object { $_.DisplayName -match 'Inno Setup' -and $_.InstallLocation } |
             Sort-Object DisplayName -Descending | Select-Object -First 1
    if ($hit) {
      $exe = Join-Path $hit.InstallLocation 'ISCC.exe'
      if (Test-Path $exe) { return $exe }
    }
  }
  foreach ($p in @("$env:ProgramFiles\Inno Setup 7\ISCC.exe",
                   "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
                   "$env:ProgramFiles\Inno Setup 6\ISCC.exe")) {
    if (Test-Path $p) { return $p }
  }
  return $null
}

function Find-MakeNsis {
  $c = Get-Command makensis.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  # NSIS records its install directory in the registry, which is the only reliable answer
  # when it was installed somewhere unguessable (C:\bin\NSIS, D:\tools\NSIS, ...). It is a
  # 32-bit installer, so on 64-bit Windows the key lands under WOW6432Node.
  foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\NSIS', 'HKLM:\SOFTWARE\NSIS',
                   'HKCU:\SOFTWARE\NSIS')) {
    $dir = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).'(default)'
    if (-not $dir) { $dir = (Get-ItemProperty -Path $k -Name 'InstallLocation' -ErrorAction SilentlyContinue).InstallLocation }
    if ($dir -and (Test-Path (Join-Path $dir 'makensis.exe'))) { return (Join-Path $dir 'makensis.exe') }
  }
  foreach ($p in @("$env:ProgramFiles\NSIS\makensis.exe",
                   "C:\bin\NSIS\makensis.exe",
                   "${env:ProgramFiles(x86)}\NSIS\makensis.exe",
                   "$env:LOCALAPPDATA\Programs\NSIS\makensis.exe",
                   "$env:ChocolateyInstall\bin\makensis.exe")) {
    if ($p -and (Test-Path $p)) { return $p }
  }
  return $null
}

$makensis = Find-MakeNsis
if ($Check) {
  $iscc = Find-Iscc
  # BOTH are reported, whichever -Format was asked for. "Can this machine build an
  # installer" has two answers now, and reporting only the requested one hides that the
  # other toolchain is absent until somebody switches and discovers it mid-release.
  if ($makensis) { Info "makensis (nsis): $makensis" } else { Write-Host "  MISSING makensis (nsis) -- winget install NSIS.NSIS" -ForegroundColor Yellow }
  if ($iscc)     { Info "ISCC (inno):     $iscc" }     else { Write-Host "  MISSING ISCC (inno)     -- winget install JRSoftware.InnoSetup" -ForegroundColor Yellow }
  if ($makensis -or $iscc) { exit 0 }
  Write-Host "  neither installer toolchain is present" -ForegroundColor Red
  Write-Host "       fix: winget install NSIS.NSIS   |   choco install nsis -y" -ForegroundColor DarkGray
  exit 1
}
if ($Format -eq 'nsis' -and -not $makensis) { Die "makensis not found. Install NSIS: winget install NSIS.NSIS (or choco install nsis -y), then re-run." }
$iscc = $null
if ($Format -eq 'inno') {
  $iscc = Find-Iscc
  if (-not $iscc) { Die "ISCC.exe not found. Install Inno Setup: winget install JRSoftware.InnoSetup, then re-run." }
}
if (-not $Bundle) { Die "usage: build-installer.ps1 <bundle-dir> [-Out <path>]" }
if (-not (Test-Path $Bundle)) { Die "no such bundle directory: $Bundle" }

$BundleDir = (Resolve-Path $Bundle).Path
$leaf = Split-Path -Leaf $BundleDir

# Bundle names are <app>-<version>-<os>-<arch>, and EVERY field can contain hyphens: the app
# (coalton-repl), the version (0.0.0-dev, 1.2.3-beta.1) and the arch (x86-64). Splitting on
# "-" is hopeless, so anchor on what is closed: os and arch are fixed alternations, and the
# version must start with X.Y.Z. That leaves exactly one way to parse the name.
if ($leaf -notmatch '^(?<app>.+)-(?<ver>\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)-(?<os>windows|linux|macos)-(?<arch>x86-64|arm64|x86)$') {
  Die "bundle name '$leaf' is not <app>-<version>-<os>-<arch> -- was it built by build-desktop-app.lisp?"
}
$app = $matches['app']; $version = $matches['ver']
if ($matches['os'] -ne 'windows') { Die "bundle '$leaf' is for $($matches['os']), not windows" }

$exe = "$app.exe"
if (-not (Test-Path (Join-Path $BundleDir $exe))) { Die "bundle has no $exe" }
if (-not (Test-Path (Join-Path $BundleDir 'hyperion-view.exe'))) {
  Write-Host "WARNING: bundle has no hyperion-view.exe -- the installed app will not open a window." -ForegroundColor Yellow
}

if (-not $Out) { $Out = Join-Path (Split-Path -Parent $BundleDir) "$app-$version-setup.exe" }

# VIProductVersion demands strictly X.X.X.X, so a pre-release version like 1.2.3-beta.1
# cannot be passed through -- derive a numeric 4-part form and keep the real string for
# every user-visible field.
$numeric = ($version -split '-')[0]
$parts = $numeric -split '\.'
while ($parts.Count -lt 4) { $parts += '0' }
$viversion = ($parts[0..3] -join '.')

# The Edge WebView2 runtime is the one dependency the app cannot carry itself. Embed the
# ~2 MB Evergreen *bootstrapper* (Tauri's "embedBootstrapper" mode): the installer then
# repairs a machine that lacks the runtime, with no third-party NSIS plugin and no
# install-time download of the bootstrapper itself. Fetched once at build time and cached.
$wv2Args = @()
if (-not $NoWebView2) {
  $cache = Join-Path $Here 'installers\.cache'
  $boot = Join-Path $cache 'MicrosoftEdgeWebview2Setup.exe'
  if (-not (Test-Path $boot)) {
    Info "fetching the WebView2 Evergreen bootstrapper (once; cached)"
    New-Item -ItemType Directory -Force -Path $cache | Out-Null
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
    try {
      Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' `
        -OutFile $boot -UseBasicParsing -MaximumRedirection 10
    } catch {
      Remove-Item $boot -Force -ErrorAction SilentlyContinue
      Write-Host "WARNING: could not fetch the WebView2 bootstrapper ($($_.Exception.Message))." -ForegroundColor Yellow
      Write-Host "         Building without it; use -NoWebView2 to make that explicit." -ForegroundColor DarkGray
    }
  }
  if (Test-Path $boot) { $wv2Args = @("/DWV2BOOTSTRAPPER=$boot") ; Note "WebView2 bootstrapper: embedded" }
} else {
  Note "WebView2 bootstrapper: skipped (-NoWebView2)"
}

Info "building installer for $app $version"
Note "bundle: $BundleDir"
Note "out:    $Out"
if ($Format -eq 'nsis') {
  & $makensis /NOCD `
    "/DAPPNAME=$app" "/DVERSION=$version" "/DVIVERSION=$viversion" `
    "/DSRCDIR=$BundleDir" "/DOUTFILE=$Out" "/DEXENAME=$exe" `
    @wv2Args `
    $Nsi
  if ($LASTEXITCODE -ne 0) { Die "makensis exited $LASTEXITCODE" }
} else {
  # Inno names its output by directory + basename rather than by full path, so $Out is split
  # rather than passed through. Splitting HERE keeps -Out meaning the same thing for both
  # formats, which is what lets a caller change packaging without changing anything else.
  $outDir  = Split-Path -Parent $Out
  $outBase = [IO.Path]::GetFileNameWithoutExtension($Out)
  $issArgs = @("/DAPPNAME=$app", "/DVERSION=$version",
               "/DSRCDIR=$BundleDir", "/DOUTDIR=$outDir", "/DOUTBASE=$outBase",
               "/DEXENAME=$exe")
  # Same flag spelling as the NSIS path on purpose: two packagings with two names for the
  # same input is how one of them silently stops embedding the runtime.
  $issArgs += $wv2Args
  if ($SignTool) {
    $issArgs += "/DSIGNTOOL=$SignTool"
    Note "signing with SignTool '$SignTool' (installer and uninstaller)"
  } else {
    Note "NOT Authenticode-signed -- pass -SignTool <name> to sign."
    Note "Ed25519 payload signing is UPDATE INTEGRITY only; it does nothing about"
    Note "SmartScreen on a first install, which is what signing here is for."
  }
  & $iscc @issArgs $Iss
  if ($LASTEXITCODE -ne 0) { Die "ISCC exited $LASTEXITCODE" }
}

$item = Get-Item $Out
Info ("built: {0}  ({1:N0} bytes)" -f $item.FullName, $item.Length)
if ($Format -eq 'nsis') {
  Note "install silently (the update path):  $($item.Name) /S"
  Note "install to a chosen directory:       $($item.Name) /S /D=C:\path\with\no\quotes"
} else {
  # Entirely different flags, which is why the MANIFEST declares the format rather than the
  # client inferring it from the OS: hand one installer the other's arguments and it
  # installs nothing while exiting 0.
  Note "install silently (the update path):  $($item.Name) /VERYSILENT /SUPPRESSMSGBOXES /NORESTART"
  # Backtick, not backslash: PowerShell escapes a quote with a backtick, and \" ends the
  # string early -- which printed a bare "/DIR=\" the first time this line ran.
  Note "install to a chosen directory:       $($item.Name) /VERYSILENT /DIR=`"C:\path\quoted`""
}
