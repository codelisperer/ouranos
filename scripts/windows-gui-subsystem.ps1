#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Flip a dumped SBCL executable from the console subsystem to the Windows GUI subsystem,
  so a desktop app does not drag a console window around behind it.

.DESCRIPTION
  `save-lisp-and-die :executable t` writes a CUI (console) PE on Windows: launching it
  spawns a conhost.exe and a black console window sits behind the app's real window. Every
  native desktop app is a GUI-subsystem binary instead; the only difference in the PE is
  one field in the optional header, which `editbin /SUBSYSTEM:WINDOWS` rewrites in place.

  This must run AFTER the dump -- save-lisp-and-die terminates the process, so the build
  script itself cannot do it. Verified on SBCL 2.6.6 / MSVC 14.51: the image still runs and
  still launches the webview child; only the console is gone.

  Effects worth knowing: with no console, anything the app writes to stdout/stderr goes
  nowhere. Log to a file (or the app's own UI) rather than the terminal for shipping builds.

  editbin ships with MSVC (the same toolchain hyperion-view/build.ps1 already finds), so
  a machine that can build the launcher can do this too. Without MSVC this is a no-op with a
  warning -- a console window is cosmetic, not a build failure.

.PARAMETER Path
  The dumped .exe to convert.

.EXAMPLE
  .\scripts\windows-gui-subsystem.ps1 dist\coalton-repl-0.1.0-windows-x86-64\coalton-repl.exe
#>
[CmdletBinding()]
param([Parameter(Mandatory = $true, Position = 0)][string]$Path)

$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "==> $m" -ForegroundColor Blue }
function Warn($m) { Write-Host "WARNING: $m" -ForegroundColor Yellow }

if (-not (Test-Path $Path)) { Write-Host "ERROR: no such file: $Path" -ForegroundColor Red; exit 1 }

function Import-MsvcEnv {
  if (Get-Command editbin.exe -ErrorAction SilentlyContinue) { return $true }
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path $vswhere)) { return $false }
  $vs = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath 2>$null | Select-Object -First 1
  if (-not $vs) { return $false }
  $vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvarsall.bat'
  if (-not (Test-Path $vcvars)) { return $false }
  $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
  cmd /c "`"$vcvars`" $arch >nul 2>&1 && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($matches[1])" -Value $matches[2] }
  }
  return [bool](Get-Command editbin.exe -ErrorAction SilentlyContinue)
}

if (-not (Import-MsvcEnv)) {
  Warn "editbin not found (MSVC not installed) -- leaving $Path as a console app. The app still works; it just shows a console window."
  exit 0
}

Info "editbin /SUBSYSTEM:WINDOWS $Path"
& editbin.exe /nologo /SUBSYSTEM:WINDOWS $Path
if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: editbin exited $LASTEXITCODE" -ForegroundColor Red; exit 1 }
Info "done -- no console window on launch."
