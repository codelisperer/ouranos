<#
.SYNOPSIS
  Check that a file is a WebView2 bootstrapper signed by Microsoft, before an installer embeds it (#736).

.DESCRIPTION
  build-installer.ps1 embeds MicrosoftEdgeWebview2Setup.exe, downloaded from Microsoft's
  Evergreen fwlink. The link has no version and Microsoft replaces the file behind it, so a
  sha256 pin would break the release build whenever Microsoft ships a new bootstrapper. What can
  be checked is who made it: the file's Authenticode signature must be Valid, and its signer's
  subject must name O=Microsoft Corporation (the hub's ruling on #736).

  Prints the file's version and sha256 on success, so an installer can be traced to the bytes it
  embeds. Exit 0 when the file passes, 1 when it does not (the reason is printed), 2 when there
  is no such file.

.PARAMETER Path
  The file to check.

.EXAMPLE
  .\scripts\check-webview2-bootstrapper.ps1 scripts\installers\.cache\MicrosoftEdgeWebview2Setup.exe
#>
param([Parameter(Mandatory = $true, Position = 0)][string]$Path)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
  Write-Host "check-webview2-bootstrapper: no such file: $Path"
  exit 2
}

$sig = Get-AuthenticodeSignature -LiteralPath $Path
if ($sig.Status -ne 'Valid') {
  Write-Host "check-webview2-bootstrapper: FAIL $Path -- the signature status is $($sig.Status): $($sig.StatusMessage)"
  exit 1
}

# The subject is a distinguished name such as "CN=Microsoft Corporation, O=Microsoft Corporation,
# L=Redmond, S=Washington, C=US". Match the O= component exactly, not a substring anywhere, so a
# certificate whose CN merely mentions Microsoft does not pass.
$subject = $sig.SignerCertificate.Subject
if ($subject -notmatch '(^|,\s*)O=Microsoft Corporation(\s*,|$)') {
  Write-Host "check-webview2-bootstrapper: FAIL $Path -- signed by '$subject', not O=Microsoft Corporation"
  exit 1
}

$version = (Get-Item -LiteralPath $Path).VersionInfo.FileVersion
$sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "check-webview2-bootstrapper: ok $Path"
Write-Host "    version $version"
Write-Host "    sha256  $sha256"
Write-Host "    signer  $subject"
exit 0
