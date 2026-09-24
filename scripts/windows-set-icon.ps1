#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Write an .ico into a Windows executable's resources, so Explorer, the taskbar and
  shortcuts show it as the program's icon.

.DESCRIPTION
  Uses the Win32 resource-update API (BeginUpdateResource, UpdateResource,
  EndUpdateResource) from kernel32, so it needs no tool beyond Windows itself. Each image
  in the .ico becomes an RT_ICON resource, and one RT_GROUP_ICON (id 1) lists them.
  Explorer shows the first group icon in the file.

  RUN IT ON THE SBCL RUNTIME, NEVER ON A DUMPED IMAGE (#72). save-lisp-and-die appends the
  Lisp core after the end of the PE file, and EndUpdateResource rewrites the file without
  anything that follows the last section. Measured on SBCL 2.6.8: a 39,719,008-byte image
  came back as 2,404,352 bytes and died at start with "Can't find sbcl.core". The runtime
  that performs the dump is copied into the image byte for byte, so build-desktop-app.lisp
  --icon runs this on a copy of sbcl.exe and dumps with that copy. The dumped image then
  carries the icon, starts, and still starts after windows-gui-subsystem.ps1.

  The same rewrite drops sbcl.exe's COFF symbol table, which also lies after the last
  section (7,845 symbols, 177,020 bytes with its string table, in the SBCL 2.6.8 MSI). It
  is debugging information: SBCL finds runtime symbols through the export table, which is a
  section and is kept, as are the DWARF sections. EndUpdateResource leaves the header's
  PointerToSymbolTable and NumberOfSymbols unchanged, pointing at whatever section data now
  sits at the old offset, so this script sets both to zero, which is what a stripped
  executable has.

.PARAMETER Path
  The executable to modify in place.

.PARAMETER Icon
  The .ico file.

.EXAMPLE
  .\scripts\windows-set-icon.ps1 dist\.runtime\sbcl.exe hyperion\examples\coalton-repl\assets\lambda.ico
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)][string]$Path,
  [Parameter(Mandatory = $true, Position = 1)][string]$Icon
)

$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "==> $m" -ForegroundColor Blue }
function Die($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Die "no such file: $Path" }
if (-not (Test-Path -LiteralPath $Icon -PathType Leaf)) { Die "no such icon file: $Icon" }
$Path = (Resolve-Path -LiteralPath $Path).Path
$Icon = (Resolve-Path -LiteralPath $Icon).Path

Add-Type -Namespace Ouranos -Name Rsrc -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr BeginUpdateResource(string file, bool deleteExisting);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool UpdateResource(IntPtr h, IntPtr type, IntPtr name, ushort lang, byte[] data, uint size);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool EndUpdateResource(IntPtr h, bool discard);
'@

function Win32Error { [Runtime.InteropServices.Marshal]::GetLastWin32Error() }

# --- read the .ico -----------------------------------------------------------------
# ICONDIR: reserved (0), type (1 = icon), count; then one 16-byte ICONDIRENTRY per image,
# whose last two fields are the image's size and its offset in the file.
$ico = [IO.File]::ReadAllBytes($Icon)
if ($ico.Length -lt 6 -or [BitConverter]::ToUInt16($ico, 0) -ne 0 -or [BitConverter]::ToUInt16($ico, 2) -ne 1) {
  Die "$Icon is not an .ico file (its header does not say reserved 0, type 1)"
}
$count = [BitConverter]::ToUInt16($ico, 4)
if ($count -eq 0 -or $ico.Length -lt 6 + 16 * $count) { Die "$Icon lists $count images but is $($ico.Length) bytes" }

# --- write the resources -------------------------------------------------------------
$RT_ICON = [IntPtr]3
$RT_GROUP_ICON = [IntPtr]14
$LANG_NEUTRAL = 0

$h = [Ouranos.Rsrc]::BeginUpdateResource($Path, $false)
if ($h -eq [IntPtr]::Zero) { Die "BeginUpdateResource($Path) failed with Win32 error $(Win32Error)" }
$committed = $false
try {
  # RT_GROUP_ICON is the ICONDIR again, with each entry's 4-byte file offset replaced by the
  # 2-byte id of the RT_ICON resource that holds the image.
  $group = New-Object IO.MemoryStream
  $w = New-Object IO.BinaryWriter($group)
  $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$count)
  for ($i = 0; $i -lt $count; $i++) {
    $entry = 6 + 16 * $i
    $size = [BitConverter]::ToUInt32($ico, $entry + 8)
    $offset = [BitConverter]::ToUInt32($ico, $entry + 12)
    if ($offset + $size -gt $ico.Length) { Die "image $($i + 1) of $Icon runs past the end of the file" }
    $image = New-Object byte[] $size
    [Array]::Copy($ico, $offset, $image, 0, $size)
    if (-not [Ouranos.Rsrc]::UpdateResource($h, $RT_ICON, [IntPtr]($i + 1), $LANG_NEUTRAL, $image, $size)) {
      Die "UpdateResource(RT_ICON $($i + 1)) failed with Win32 error $(Win32Error)"
    }
    $w.Write($ico, $entry, 12)      # width, height, colour count, reserved, planes, bit count, size
    $w.Write([uint16]($i + 1))
  }
  $bytes = $group.ToArray()
  if (-not [Ouranos.Rsrc]::UpdateResource($h, $RT_GROUP_ICON, [IntPtr]1, $LANG_NEUTRAL, $bytes, $bytes.Length)) {
    Die "UpdateResource(RT_GROUP_ICON) failed with Win32 error $(Win32Error)"
  }
  if (-not [Ouranos.Rsrc]::EndUpdateResource($h, $false)) { Die "EndUpdateResource failed with Win32 error $(Win32Error)" }
  $committed = $true
} finally {
  # Discard on any failure, so a half-written resource table never reaches the file.
  if (-not $committed) { [void][Ouranos.Rsrc]::EndUpdateResource($h, $true) }
}

# --- clear the symbol-table fields the rewrite left behind ---------------------------
# COFF file header, right after the 'PE\0\0' signature at e_lfanew: Machine (2),
# NumberOfSections (2), TimeDateStamp (4), PointerToSymbolTable (4), NumberOfSymbols (4).
$fs = [IO.File]::Open($Path, 'Open', 'ReadWrite')
try {
  $br = New-Object IO.BinaryReader($fs)
  $fs.Position = 0x3C
  $pe = $br.ReadInt32()
  $fs.Position = $pe
  if ($br.ReadUInt32() -ne 0x00004550) { Die "$Path has no PE signature after the resource update" }
  $fs.Position = $pe + 6
  $sections = $br.ReadUInt16()
  $fs.Position = $pe + 12
  $symPtr = $br.ReadUInt32()
  $symCount = $br.ReadUInt32()
  $optSize = $br.ReadUInt16()
  # Where the last section's raw data ends. A symbol table still in the file starts at or
  # after this; a pointer before it lands in section data, so the table is gone.
  $sectionsEnd = 0
  for ($s = 0; $s -lt $sections; $s++) {
    $fs.Position = $pe + 24 + $optSize + 40 * $s + 16
    $rawSize = $br.ReadUInt32(); $rawPtr = $br.ReadUInt32()
    if ($rawPtr + $rawSize -gt $sectionsEnd) { $sectionsEnd = $rawPtr + $rawSize }
  }
  if ($symPtr -ne 0 -and $symPtr -lt $sectionsEnd) {
    $fs.Position = $pe + 12
    $bw = New-Object IO.BinaryWriter($fs)
    $bw.Write([uint32]0); $bw.Write([uint32]0); $bw.Flush()
    Info "cleared the COFF symbol-table fields ($symCount symbols at offset $symPtr, no longer in the file)"
  }
} finally { $fs.Dispose() }

Info "wrote $count icon images from $Icon into $Path"
