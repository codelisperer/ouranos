#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Build libuv.dll at libuv.pin's version and package it as the prebuilt DLL that
  scripts/setup.ps1 downloads when the MSVC Build Tools are absent (#1247).

.DESCRIPTION
  Runs scripts/build-libuv.lisp --force, checks that the DLL it wrote is a build of libuv.pin's
  version for the architecture asked for, and copies it to
    <OutDir>\libuv-<version>-windows-<arch>.dll
  with a checksum file beside it,
    <OutDir>\libuv-<version>-windows-<arch>.dll.sha256
  in sha256sum's format ("<hex>  <file name>", LF). .github/workflows/libuv-prebuilt.yml runs
  this on a Windows runner and attaches both files to the release libuv-v<version>. It also
  runs on any Windows machine with SBCL and the MSVC Build Tools.

  Needs SBCL on PATH (scripts/setup.ps1 -WithoutUv installs it) and MSVC.

.PARAMETER Arch
  x64 or arm64. Must be the architecture of this machine's MSVC target; the DLL's PE header is
  checked against it, and a mismatch fails.

.PARAMETER OutDir
  Where the packaged files go. Default: dist\libuv-prebuilt under the checkout.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Arch,
  [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Root = Split-Path -Parent $Here
if (-not $OutDir) { $OutDir = Join-Path (Join-Path $Root 'dist') 'libuv-prebuilt' }

function Die($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

function Get-PinVersion($file) {
  if (-not (Test-Path $file)) { return $null }
  foreach ($line in Get-Content $file) { if ($line -match '^\s*version\s+(\S+)') { return $matches[1] } }
  return $null
}

# The same reading as Get-PeMachine in setup.ps1: the Machine field of the COFF header.
function Get-PeMachine($path) {
  $fs = [IO.File]::OpenRead($path)
  try {
    $br = New-Object IO.BinaryReader($fs)
    if ($fs.Length -lt 0x40) { return $null }
    $fs.Position = 0x3C
    $pe = $br.ReadInt32()
    if ($pe -lt 0 -or $pe + 6 -gt $fs.Length) { return $null }
    $fs.Position = $pe
    if ($br.ReadUInt32() -ne 0x00004550) { return $null }
    return [int]$br.ReadUInt16()
  } finally { $fs.Dispose() }
}

function Get-Sha256Hex($path) {
  $stream = [IO.File]::OpenRead($path)
  try { $bytes = [Security.Cryptography.SHA256]::Create().ComputeHash($stream) }
  finally { $stream.Dispose() }
  return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

$version = Get-PinVersion (Join-Path $Root 'libuv.pin')
if (-not $version) { Die 'libuv.pin has no version line' }

Write-Host "==> building libuv $version for windows-$Arch (scripts/build-libuv.lisp --force)"
& sbcl --dynamic-space-size 4096 --script (Join-Path $Here 'build-libuv.lisp') --force
if ($LASTEXITCODE -ne 0) { Die "scripts/build-libuv.lisp failed (sbcl exit $LASTEXITCODE)" }

$vendor = [IO.Path]::Combine($Root, 'vendor', 'libuv')
$dll = [IO.Path]::Combine($vendor, 'lib', 'libuv.dll')
if (-not (Test-Path -LiteralPath $dll)) { Die "build-libuv.lisp exited 0 but $dll does not exist" }

# The stamp the build wrote must name libuv.pin's version: the file name below claims it.
$built = Get-PinVersion (Join-Path $vendor 'BUILT-FROM')
if ($built -ne $version) { Die "vendor\libuv\BUILT-FROM names '$built', and libuv.pin names $version" }

# The PE header decides the architecture, not the runner's name: an x64 compiler on an arm64
# host builds an x64 DLL without complaint (pre-publication issue 145).
$want = if ($Arch -eq 'arm64') { 0xAA64 } else { 0x8664 }
$got = Get-PeMachine $dll
if ($got -ne $want) {
  $gotText = if ($null -eq $got) { 'not a PE file' } else { '0x{0:X4}' -f $got }
  Die ("libuv.dll was built for machine $gotText, and windows-$Arch needs 0x{0:X4}" -f $want)
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$name = "libuv-$version-windows-$Arch.dll"
$out = Join-Path $OutDir $name
Copy-Item -LiteralPath $dll -Destination $out -Force
$sha = Get-Sha256Hex $out
[IO.File]::WriteAllText("$out.sha256", "$sha  $name`n", (New-Object Text.UTF8Encoding($false)))
Write-Host "==> $out"
Write-Host "    sha256 $sha"
