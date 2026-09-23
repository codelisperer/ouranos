#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Build the Hyperion hyperion-view on Windows -- or just check this machine's
  prerequisites for building it.

.DESCRIPTION
  The Windows half of hyperion-view/build.sh, native: PowerShell only, no MSYS2
  shell, no curl/unzip. It

    1. CHECKS the toolchain (MSVC or mingw-w64), the WebView2 SDK headers and the
       WebView2 runtime, printing an install command for anything missing;
    2. FETCHES the WebView2 SDK headers from NuGet, at the version and SHA-256 pinned
       in scripts/versions.env (Microsoft-licensed, so never vendored in the repo);
    3. COMPILES hyperion-view.cc -> hyperion-view.exe, statically linked so
       the only runtime requirement on the target machine is WebView2 itself.

  MSVC is preferred (it is what the shipped binary was verified with, and it needs
  no MSYS2); mingw-w64 works too. build.sh delegates here on Windows, so both entry
  points behave identically.

.PARAMETER Check
  Run the prerequisite check only; build nothing. Exit 0 if this machine can build,
  1 if something required is missing.

.PARAMETER Compiler
  auto (default -- MSVC, else mingw), msvc, or mingw.

.PARAMETER Sdk
  WebView2 SDK version to fetch. Default: WEBVIEW2_SDK_VERSION in scripts/versions.env.
  Overriding it requires -SdkSha256 as well, because the pinned checksum only matches the
  pinned version.

.PARAMETER SdkSha256
  SHA-256 of the .nupkg for -Sdk. Default: WEBVIEW2_SDK_SHA256 in scripts/versions.env. A
  download whose checksum differs is deleted and the build stops.

.PARAMETER Out
  Output path. Default: .\hyperion-view.exe beside this script (where
  hyperion/desktop:default-launcher looks in dev).

.PARAMETER Refresh
  Re-fetch the WebView2 SDK headers even if already present.

.EXAMPLE
  .\build.ps1 -Check          # can this machine build it? what's missing?
.EXAMPLE
  .\build.ps1                 # build with whatever toolchain is installed
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\build.ps1     # restricted-policy machine
#>
[CmdletBinding()]
param(
  [switch]$Check,
  [ValidateSet('auto', 'msvc', 'mingw')][string]$Compiler = 'auto',
  [string]$Sdk,
  [string]$SdkSha256,
  [string]$Out,
  [switch]$Refresh
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 compatible throughout (that is what a fresh Windows box has).
$Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Src = Join-Path $Here 'hyperion-view.cc'
if (-not $Out) { $Out = Join-Path $Here 'hyperion-view.exe' }
$SdkDir = Join-Path $Here '.webview2-sdk'
$SdkInc = Join-Path $SdkDir 'build\native\include'
# Records which pin the unpacked headers came from, so a changed pin fetches again rather
# than reusing headers from another version.
$SdkMarker = Join-Path $SdkDir '.pin'

# The SDK version and the SHA-256 of its .nupkg are pinned in scripts/versions.env, beside
# the other native downloads (#175). bootstrap.lisp runs this script on every Windows machine
# with a C++ toolchain, so the download is checked against the pin rather than trusted.
if ($Sdk -and -not $SdkSha256) {
  Write-Host "ERROR: -Sdk $Sdk needs -SdkSha256 too: the checksum in scripts/versions.env is for the pinned version only." -ForegroundColor Red
  exit 1
}
if (-not $Sdk) {
  $versionsEnv = Join-Path $Here '..\..\scripts\versions.env'
  if (-not (Test-Path $versionsEnv)) {
    Write-Host "ERROR: $versionsEnv not found; it pins the WebView2 SDK. Pass -Sdk and -SdkSha256 to build outside the repository." -ForegroundColor Red
    exit 1
  }
  $pins = @{}
  Get-Content $versionsEnv | ForEach-Object {
    if ($_ -match '^\s*([A-Z0-9_]+)\s*=\s*(.+?)\s*$') { $pins[$matches[1]] = $matches[2] }
  }
  foreach ($k in 'WEBVIEW2_SDK_VERSION', 'WEBVIEW2_SDK_SHA256') {
    if (-not $pins.ContainsKey($k)) {
      Write-Host "ERROR: scripts/versions.env: $k missing" -ForegroundColor Red
      exit 1
    }
  }
  $Sdk = $pins['WEBVIEW2_SDK_VERSION']
  $SdkSha256 = $pins['WEBVIEW2_SDK_SHA256']
}
$SdkSha256 = $SdkSha256.ToLower()

function Info($m) { Write-Host "==> $m" -ForegroundColor Blue }
function Note($m) { Write-Host "    $m" -ForegroundColor DarkGray }
function Die($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# The prerequisite report. Each check appends one row; PASS/WARN/FAIL + how to fix.
$script:Checks = @()
function Add-Check($name, $status, $detail, $fix) {
  $script:Checks += [pscustomobject]@{ Name = $name; Status = $status; Detail = $detail; Fix = $fix }
}

# ---------------------------------------------------------------------------
# Toolchain discovery
# ---------------------------------------------------------------------------

function Get-HostArch {
  switch ($env:PROCESSOR_ARCHITECTURE) {
    'ARM64' { 'arm64' }
    default { 'x64' }
  }
}

function Find-MsvcEnv {
  <#
    Locate MSVC and return the environment it needs as a hashtable (or $null).
    Any VS edition or the standalone Build Tools will do -- we ask vswhere for an
    install carrying the C++ tools, then harvest the env that vcvarsall.bat sets
    (cl.exe, the Windows SDK headers/libs, INCLUDE/LIB/PATH). Already inside a
    Developer Prompt? Then cl.exe is on PATH and we use it as-is.
  #>
  if (Get-Command cl.exe -ErrorAction SilentlyContinue) {
    return @{ Env = $null; Source = 'developer prompt (cl.exe already on PATH)' }
  }
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path $vswhere)) { return $null }
  $vs = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath 2>$null | Select-Object -First 1
  if (-not $vs) { return $null }
  $vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvarsall.bat'
  if (-not (Test-Path $vcvars)) { return $null }

  # vcvarsall only exists as a batch script: run it in cmd, then import the
  # resulting environment into this session.
  $arch = Get-HostArch
  $vars = @{}
  cmd /c "`"$vcvars`" $arch >nul 2>&1 && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { $vars[$matches[1]] = $matches[2] }
  }
  if (-not $vars.ContainsKey('VCToolsInstallDir')) { return $null }
  return @{ Env = $vars; Source = "$vs ($arch)" }
}

function Use-MsvcEnv($msvc) {
  if ($msvc.Env) { foreach ($k in $msvc.Env.Keys) { Set-Item -Path "env:$k" -Value $msvc.Env[$k] } }
}

function Find-Mingw {
  <#
    A NATIVE mingw-w64 g++ -- not MSYS2's /usr/bin/g++, which targets the MSYS
    POSIX-emulation runtime (msys-2.0.dll) and cannot produce a native Win32 GUI
    binary. `g++ -dumpmachine` tells them apart: x86_64-w64-mingw32 (good) vs
    x86_64-pc-msys (wrong one, and it is usually the one first on PATH).
  #>
  $candidates = @()
  if ($env:CXX) { $candidates += $env:CXX }
  $candidates += @(
    'C:\msys64\ucrt64\bin\g++.exe', 'C:\msys64\mingw64\bin\g++.exe',
    'C:\msys64\clang64\bin\g++.exe',
    'C:\ProgramData\chocolatey\bin\g++.exe',
    "$env:USERPROFILE\scoop\shims\g++.exe"
  )
  $onPath = (Get-Command g++.exe -ErrorAction SilentlyContinue | Select-Object -Expand Source -ErrorAction SilentlyContinue)
  if ($onPath) { $candidates += $onPath }
  $rejected = $null
  foreach ($c in $candidates) {
    if (-not $c) { continue }
    $exe = $null
    if (Test-Path $c) { $exe = (Resolve-Path $c).Path }
    else {
      $cmd = Get-Command $c -ErrorAction SilentlyContinue
      if ($cmd) { $exe = $cmd.Source }
    }
    if (-not $exe) { continue }
    $triple = (& $exe -dumpmachine 2>$null) | Select-Object -First 1
    if ($triple -match 'w64-mingw32') { return @{ Exe = $exe; Triple = $triple } }
    if ($triple) { $rejected = "$exe targets $triple" }
  }
  if ($rejected) { return @{ Exe = $null; Rejected = $rejected } }
  return $null
}

# ---------------------------------------------------------------------------
# WebView2: SDK headers (build time) + runtime (run time)
# ---------------------------------------------------------------------------

function Get-Tls12 { try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { } }

function Get-SdkUrls {
  # The v3 flat container is the canonical CDN path; the v2 route is the fallback.
  # (Neither answers HEAD -- probe with a GET, see Test-NugetReachable.)
  @("https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$Sdk/microsoft.web.webview2.$Sdk.nupkg",
    "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$Sdk")
}

function Test-NugetReachable {
  Get-Tls12
  try {
    Invoke-WebRequest -Uri 'https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/index.json' `
      -UseBasicParsing -TimeoutSec 15 | Out-Null
    return $true
  } catch { return $false }
}

function Get-WebView2Sdk {
  <#
    Fetch the WebView2 SDK headers from NuGet. A .nupkg IS a zip, so this is
    Invoke-WebRequest + Expand-Archive -- no curl/unzip needed. Not vendored in
    the repo: the SDK is Microsoft-licensed.
  #>
  if ((Test-SdkCurrent) -and -not $Refresh) { return $SdkInc }
  Info "fetching WebView2 SDK $Sdk (headers only) ..."
  # Start from an empty directory, so headers from another version or a failed download
  # cannot be mixed with these.
  if (Test-Path $SdkDir) { Remove-Item -Recurse -Force $SdkDir }
  New-Item -ItemType Directory -Force -Path $SdkDir | Out-Null
  $zip = Join-Path $SdkDir 'webview2.zip'      # .zip: Expand-Archive rejects .nupkg
  Get-Tls12
  $got = $null; $err = $null
  foreach ($url in Get-SdkUrls) {
    try {
      Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -MaximumRedirection 5
      $got = $url; break
    } catch { $err = $_.Exception.Message; Note "not available at $url" }
  }
  if (-not $got) {
    Die ("could not download the WebView2 SDK ($Sdk): $err`n" +
      "       Offline or behind a proxy? Fetch the nupkg elsewhere and unpack it here:`n" +
      "       Expand-Archive microsoft.web.webview2.$Sdk.nupkg.zip -DestinationPath '$SdkDir'")
  }
  # Checked before anything is unpacked. A mismatch means the file is not the one pinned in
  # scripts/versions.env, whatever the cause, so it is deleted and the build stops.
  $sha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
  if ($sha -ne $SdkSha256) {
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Die ("WebView2 SDK $Sdk checksum mismatch for $got`n" +
      "       expected $SdkSha256`n" +
      "       got      $sha`n" +
      "       scripts/versions.env is the pin; a mismatch means the downloaded file is not the pinned one.")
  }
  Note "sha256 $sha matches the pin"
  Expand-Archive -Path $zip -DestinationPath $SdkDir -Force
  Remove-Item $zip -Force -ErrorAction SilentlyContinue
  if (-not (Test-Path (Join-Path $SdkInc 'WebView2.h'))) { Die "WebView2.h missing after extracting $got" }
  Set-Content -Path $SdkMarker -Value "$Sdk $SdkSha256" -Encoding ASCII
  Note "headers: $SdkInc"
  return $SdkInc
}

function Test-SdkCurrent {
  # The unpacked headers are reused only when they came from the current pin. Headers
  # unpacked before the pin was checksummed have no marker, so they are fetched again once.
  if (-not (Test-Path (Join-Path $SdkInc 'WebView2.h'))) { return $false }
  if (-not (Test-Path $SdkMarker)) { return $false }
  return ((Get-Content $SdkMarker -TotalCount 1).Trim() -eq "$Sdk $SdkSha256")
}

function Get-WebView2Runtime {
  # The Evergreen runtime registers its version under the EdgeUpdate client GUID
  # (per-machine, 32/64-bit view, or per-user).
  $guid = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
  foreach ($root in @(
      "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$guid",
      "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$guid",
      "HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$guid")) {
    if (Test-Path $root) {
      $pv = (Get-ItemProperty -Path $root -ErrorAction SilentlyContinue).pv
      if ($pv) { return $pv }
    }
  }
  return $null
}

# ---------------------------------------------------------------------------
# The doctor: everything this machine needs, and how to get it
# ---------------------------------------------------------------------------

$FixMsvc = 'winget install --id Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"'
$FixMingw = 'winget install --id MSYS2.MSYS2   then in the UCRT64 shell: pacman -S mingw-w64-ucrt-x86_64-gcc'
$FixRuntime = 'winget install --id Microsoft.EdgeWebView2Runtime'

function Invoke-Doctor {
  Info "checking prerequisites (Windows $([Environment]::OSVersion.Version), $(Get-HostArch), PowerShell $($PSVersionTable.PSVersion))"

  if (-not (Test-Path $Src)) { Add-Check 'source' 'FAIL' "missing $Src" 'incomplete checkout -- re-clone the repo' }
  else { Add-Check 'source' 'PASS' 'hyperion-view.cc + webview.h (vendored)' '' }

  $script:Msvc = if ($Compiler -in 'auto', 'msvc') { Find-MsvcEnv } else { $null }
  $script:Mingw = if ($Compiler -in 'auto', 'mingw') { Find-Mingw } else { $null }

  if ($script:Msvc) { Add-Check 'MSVC (preferred)' 'PASS' $script:Msvc.Source '' }
  elseif ($Compiler -eq 'msvc') { Add-Check 'MSVC' 'FAIL' 'cl.exe / VC++ tools not found' $FixMsvc }
  elseif ($Compiler -eq 'mingw') { Add-Check 'MSVC (preferred)' '----' 'not checked (-Compiler mingw)' '' }
  else { Add-Check 'MSVC (preferred)' '----' 'not installed' $FixMsvc }

  if ($script:Mingw -and $script:Mingw.Exe) { Add-Check 'mingw-w64 g++' 'PASS' "$($script:Mingw.Exe) ($($script:Mingw.Triple))" '' }
  elseif ($script:Mingw -and $script:Mingw.Rejected) { Add-Check 'mingw-w64 g++' 'WARN' "not usable: $($script:Mingw.Rejected) -- MSYS/Cygwin g++ cannot build a native Win32 GUI binary" $FixMingw }
  elseif ($Compiler -eq 'mingw') { Add-Check 'mingw-w64 g++' 'FAIL' 'not found' $FixMingw }
  elseif ($Compiler -eq 'msvc') { Add-Check 'mingw-w64 g++' '----' 'not checked (-Compiler msvc)' '' }
  else { Add-Check 'mingw-w64 g++' '----' 'not installed' $FixMingw }

  if (-not $script:Msvc -and -not ($script:Mingw -and $script:Mingw.Exe)) {
    Add-Check 'C++ toolchain' 'FAIL' 'neither MSVC nor mingw-w64 available -- install ONE of the two above' $FixMsvc
  }

  if (Test-SdkCurrent) {
    Add-Check "WebView2 SDK headers" 'PASS' ".webview2-sdk (pinned $Sdk, sha256 checked)" ''
  } else {
    if (Test-NugetReachable) { Add-Check 'WebView2 SDK headers' 'PASS' "absent, or from another pin; will be fetched from NuGet on build (pinned $Sdk)" '' }
    else { Add-Check 'WebView2 SDK headers' 'FAIL' 'absent and nuget.org is unreachable' "fetch Microsoft.Web.WebView2 $Sdk elsewhere and Expand-Archive it into $SdkDir" }
  }

  $rt = Get-WebView2Runtime
  if ($rt) { Add-Check 'WebView2 runtime' 'PASS' "version $rt" '' }
  else { Add-Check 'WebView2 runtime' 'WARN' 'not detected -- the build will succeed but the window will not open' $FixRuntime }

  # Report.
  Write-Host ''
  foreach ($c in $script:Checks) {
    $color = switch ($c.Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'DarkGray' } }
    Write-Host ('  {0,-4} ' -f $c.Status) -ForegroundColor $color -NoNewline
    Write-Host ('{0,-22} {1}' -f $c.Name, $c.Detail)
    if ($c.Status -in 'FAIL', 'WARN' -and $c.Fix) { Write-Host "         fix: $($c.Fix)" -ForegroundColor DarkGray }
  }
  Write-Host ''
  return -not ($script:Checks | Where-Object Status -eq 'FAIL')
}

# ---------------------------------------------------------------------------
# Compile
# ---------------------------------------------------------------------------

function Build-Msvc($inc) {
  Use-MsvcEnv $script:Msvc
  $obj = Join-Path $Here '.obj-msvc'
  New-Item -ItemType Directory -Force -Path $obj | Out-Null
  Info "compiling with MSVC cl.exe -> $Out"
  # /MT  : static CRT, so no VC++ redistributable is needed on the target machine.
  # /link /SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup : a GUI app (no console window)
  #        that still has an ordinary main().
  # webview.h #pragma-links advapi32/ole32/shell32/shlwapi/user32/version itself;
  # oleaut32 is the one it does not.
  & cl.exe /nologo /std:c++17 /EHsc /O2 /MT `
    /I "$Here" /I "$inc" `
    "$Src" /Fo:"$obj\" /Fe:"$Out" `
    /link /SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup oleaut32.lib
  if ($LASTEXITCODE -ne 0) { Die "cl.exe failed (exit $LASTEXITCODE)" }
  Remove-Item $obj -Recurse -Force -ErrorAction SilentlyContinue
}

function Build-Mingw($inc) {
  $cxx = $script:Mingw.Exe
  # A full-path mingw g++ still needs its own bin\ on PATH to find its sub-tools
  # (cc1plus/as/ld) and runtime DLLs; without it the driver fails silently.
  $env:PATH = "$(Split-Path -Parent $cxx);$env:PATH"
  Info "compiling with $cxx -> $Out"
  & $cxx -std=c++17 -O2 "$Src" -I "$Here" -I "$inc" -o "$Out" `
    -ladvapi32 -lole32 -loleaut32 -lshell32 -lshlwapi -luser32 -lversion `
    -mwindows -static
  if ($LASTEXITCODE -ne 0) { Die "g++ failed (exit $LASTEXITCODE)" }
}

# ---------------------------------------------------------------------------

$ok = Invoke-Doctor
if ($Check) {
  if ($ok) { Info 'this machine can build the launcher.'; exit 0 }
  Write-Host 'missing prerequisites (see fixes above).' -ForegroundColor Red
  exit 1
}
if (-not $ok) { Die 'missing prerequisites (see above). Re-run with -Check after installing.' }

$inc = Get-WebView2Sdk
if ($script:Msvc) { Build-Msvc $inc }
elseif ($script:Mingw -and $script:Mingw.Exe) { Build-Mingw $inc }
else { Die 'no usable C++ toolchain (should not happen -- the check passed?)' }

$item = Get-Item $Out
Info ("built: {0}  ({1:N0} bytes)" -f $item.FullName, $item.Length)
Note "smoke test: .\$(Split-Path -Leaf $Out) https://example.com `"Smoke`" 800 600   (opens a window; close it to exit)"
Note 'hyperion/desktop:default-launcher finds it here automatically in dev.'
