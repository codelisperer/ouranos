# make-icon.ps1 --- generate the coalton-repl window icon (a lambda) from nothing.
#
#   pwsh -File hyperion/examples/coalton-repl/assets/make-icon.ps1
#
# The icon is GENERATED rather than committed as an opaque binary a future reader cannot
# edit: the source of truth is this script, and lambda.ico / lambda.png are its output.
# System.Drawing only -- no image toolchain, matching the repo's no-external-build-tools
# rule (this runs on Windows; the .png it emits is what the GTK path loads on Linux).
#
# ICO structure is written by hand because .NET's Icon class cannot SAVE a multi-size,
# 32-bit-with-alpha icon: Bitmap.GetHicon collapses to 32x32, and Icon.Save just copies
# whatever was loaded. So: render each size to a PNG, then assemble ICONDIR/ICONDIRENTRY
# around PNG payloads, which Windows has accepted inside .ico since Vista.
Add-Type -AssemblyName System.Drawing

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$sizes   = @(16, 32, 48, 64, 128, 256)
$bg      = [System.Drawing.ColorTranslator]::FromHtml('#0d1117')  # the app's own background
$fg      = [System.Drawing.ColorTranslator]::FromHtml('#7ee787')  # and its value green
$streams = @()

function New-LambdaPng([int]$size) {
  $bmp = New-Object System.Drawing.Bitmap($size, $size,
                                          [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
  $g.Clear([System.Drawing.Color]::Transparent)

  # A rounded square in the app's background colour, so the glyph reads at 16x16 instead of
  # dissolving into whatever is behind it.
  $pad    = [Math]::Max(1, [int]($size * 0.06))
  $radius = [Math]::Max(2, [int]($size * 0.22))
  $rect   = New-Object System.Drawing.Rectangle($pad, $pad, ($size - 2 * $pad), ($size - 2 * $pad))
  $path   = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d      = $radius * 2
  $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
  $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
  $path.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
  $path.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
  $path.CloseFigure()
  $g.FillPath((New-Object System.Drawing.SolidBrush($bg)), $path)

  # Cambria carries a proper lambda; the fallbacks matter on a machine that lacks it.
  $family = $null
  foreach ($name in @('Cambria Math', 'Cambria', 'Segoe UI Symbol', 'Arial')) {
    try { $family = New-Object System.Drawing.FontFamily($name); break } catch { }
  }
  $font   = New-Object System.Drawing.Font($family, ($size * 0.62),
                                           [System.Drawing.FontStyle]::Regular,
                                           [System.Drawing.GraphicsUnit]::Pixel)
  $format = New-Object System.Drawing.StringFormat
  $format.Alignment     = [System.Drawing.StringAlignment]::Center
  $format.LineAlignment = [System.Drawing.StringAlignment]::Center
  $g.DrawString([char]0x03BB, $font, (New-Object System.Drawing.SolidBrush($fg)),
                (New-Object System.Drawing.RectangleF(0, 0, $size, $size)), $format)
  $g.Dispose()

  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  return $ms
}

foreach ($size in $sizes) {
  $ms = New-LambdaPng $size
  $streams += , @{ size = $size; bytes = $ms.ToArray() }
  if ($size -eq 256) {
    [System.IO.File]::WriteAllBytes((Join-Path $here 'lambda.png'), $ms.ToArray())
  }
  $ms.Dispose()
}

# ICONDIR (6 bytes) + one ICONDIRENTRY (16 bytes) per image, then the PNG payloads.
$out = New-Object System.IO.MemoryStream
$w   = New-Object System.IO.BinaryWriter($out)
$w.Write([uint16]0)                    # reserved
$w.Write([uint16]1)                    # type: 1 = icon
$w.Write([uint16]$streams.Count)
$offset = 6 + (16 * $streams.Count)
foreach ($img in $streams) {
  # 256 is written as 0 -- the field is one byte, and 256 does not fit in it.
  $w.Write([byte]($(if ($img.size -ge 256) { 0 } else { $img.size })))
  $w.Write([byte]($(if ($img.size -ge 256) { 0 } else { $img.size })))
  $w.Write([byte]0)                    # palette entries
  $w.Write([byte]0)                    # reserved
  $w.Write([uint16]1)                  # colour planes
  $w.Write([uint16]32)                 # bits per pixel
  $w.Write([uint32]$img.bytes.Length)
  $w.Write([uint32]$offset)
  $offset += $img.bytes.Length
}
foreach ($img in $streams) { $w.Write($img.bytes) }
$w.Flush()
[System.IO.File]::WriteAllBytes((Join-Path $here 'lambda.ico'), $out.ToArray())
$out.Dispose()

Write-Host ("wrote lambda.ico ({0} sizes) and lambda.png in {1}" -f $streams.Count, $here)
