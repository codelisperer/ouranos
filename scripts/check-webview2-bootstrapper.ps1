<#
.SYNOPSIS
  Check that a file is a WebView2 bootstrapper signed by Microsoft, before an installer embeds it (#736).

.DESCRIPTION
  build-installer.ps1 embeds MicrosoftEdgeWebview2Setup.exe, downloaded from Microsoft's
  Evergreen fwlink. The link has no version and Microsoft replaces the file behind it, so a
  sha256 pin would break the release build whenever Microsoft ships a new bootstrapper. What can
  be checked is who made it: the file's Authenticode signature must be Valid, and one of its
  signer's relative distinguished names must be exactly O=Microsoft Corporation (the hub's ruling
  on #736).

  Prints the file's version, sha256 and signer when it passes, so an installer can be traced to
  the bytes it embeds.

  Exit codes: 0 the file passes; 1 it fails the check (the reason is printed); 2 there is no such
  file; 3 -Fetch could not produce one.

.PARAMETER Path
  The file to check. With -Fetch, the place the bootstrapper is cached.

.PARAMETER Fetch
  Download the bootstrapper to Path first when no file is there. A cached copy is checked like a
  fresh one, and a file that fails is deleted so the next build downloads it again.

.PARAMETER Url
  Where -Fetch downloads from. The default is Microsoft's Evergreen fwlink.

.PARAMETER SelfTest
  Check the signer rule against known subjects, and exit 0 when every case holds.

.EXAMPLE
  .\scripts\check-webview2-bootstrapper.ps1 scripts\installers\.cache\MicrosoftEdgeWebview2Setup.exe -Fetch
#>
param(
  [Parameter(Position = 0)][string]$Path,
  [switch]$Fetch,
  [string]$Url = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703',
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

function Test-MicrosoftSigner([string]$Subject) {
  # A subject is a distinguished name: "CN=Microsoft Corporation, O=Microsoft Corporation,
  # L=Redmond, S=Washington, C=US". It is checked as a list of whole RDNs, not with a pattern
  # over the string: .NET quotes an RDN value that contains a comma, so a pattern accepted
  # CN="Evil, O=Microsoft Corporation, Inc", O=Evil (the hub's review of #759). A subject with a
  # quoted value is refused, which no Microsoft signing certificate has. The comparison is
  # case-sensitive.
  if ([string]::IsNullOrEmpty($Subject) -or $Subject.Contains('"')) { return $false }
  foreach ($part in $Subject.Split(',')) {
    if ($part.Trim() -ceq 'O=Microsoft Corporation') { return $true }
  }
  return $false
}

if ($SelfTest) {
  $cases = @(
    @('CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US', $true),
    @('O=Microsoft Corporation', $true),
    @('CN="Evil, O=Microsoft Corporation, Inc", O=Evil', $false),
    @('CN=Evil, O=Microsoft Corporation Evil, C=US', $false),
    @('CN=Evil, o=microsoft corporation, C=US', $false),
    @('CN=Google LLC, O=Google LLC, L=Mountain View, S=California, C=US', $false),
    @('', $false)
  )
  $failed = 0
  foreach ($c in $cases) {
    $got = Test-MicrosoftSigner $c[0]
    if ($got -ne $c[1]) { $failed++; Write-Host "  FAIL '$($c[0])': $got, expected $($c[1])" }
  }
  Write-Host "check-webview2-bootstrapper -SelfTest: $($cases.Count) cases, $failed failed"
  if ($failed -eq 0) { exit 0 } else { exit 1 }
}

if (-not $Path) { Write-Host "usage: check-webview2-bootstrapper.ps1 <path> [-Fetch] | -SelfTest"; exit 2 }

if ($Fetch) {
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    Write-Host "check-webview2-bootstrapper: checking the cached copy $Path"
  } else {
    Write-Host "check-webview2-bootstrapper: fetching the WebView2 Evergreen bootstrapper from $Url"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
    try {
      Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -MaximumRedirection 10
    } catch {
      Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
      Write-Host "check-webview2-bootstrapper: could not fetch it: $($_.Exception.Message)"
      exit 3
    }
    # A download can report success and leave no file (the hub's review of #759).
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
      Write-Host "check-webview2-bootstrapper: the download reported success but left no file at $Path"
      exit 3
    }
  }
}

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
  Write-Host "check-webview2-bootstrapper: no such file: $Path"
  exit 2
}

function Fail([string]$why) {
  Write-Host "check-webview2-bootstrapper: FAIL $Path -- $why"
  if ($Fetch) {
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    Write-Host "    deleted, so the next build fetches it again"
  }
  exit 1
}

$sig = Get-AuthenticodeSignature -LiteralPath $Path
if ($sig.Status -ne 'Valid') { Fail "the signature status is $($sig.Status): $($sig.StatusMessage)" }
$subject = $sig.SignerCertificate.Subject
if (-not (Test-MicrosoftSigner $subject)) { Fail "signed by '$subject', which has no RDN O=Microsoft Corporation" }

$version = (Get-Item -LiteralPath $Path).VersionInfo.FileVersion
$sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "check-webview2-bootstrapper: ok $Path"
Write-Host "    version $version"
Write-Host "    sha256  $sha256"
Write-Host "    signer  $subject"
exit 0
