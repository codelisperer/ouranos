#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Check that a Windows desktop bundle loads only DLLs it carries or that Windows itself
  ships (#78).

.DESCRIPTION
  The Windows counterpart of verify-bundle.sh (Linux) and verify-bundle-macos.sh. Windows
  has no cheap clean room, so, like the macOS script, this one checks WHICH FILE the loader
  actually opened rather than only whether the process exited 0.

  Every DLL is put in one of three classes:

    CARRIED    -- inside the bundle directory. The build put it there (ADR-0013).
    WINDOWS    -- under the Windows directory, with a valid signature that marks it as an
                  operating-system binary (IsOSBinary). Every Windows installation has it.
    WEBVIEW2   -- under the WebView2 runtime's directory
                  (...\Microsoft\EdgeWebView\Application\<version>\) with a valid signature
                  from Microsoft Corporation. The bundle declares the runtime rather than
                  carrying it, and the installer installs it, so each such file is reported
                  by name and version rather than failed (#268).
    FINDING    -- anything else. It exists on this machine and may not exist on a user's.

  Being in System32 is not enough to be WINDOWS: other installers put DLLs there (OpenSSL
  on the machine this was written on, #249). Being signed by Microsoft is not enough
  either: vcruntime140.dll is Microsoft-signed, but it is the Visual C++ redistributable,
  which a fresh Windows does not necessarily have, and its signature has IsOSBinary false.

  Checks:

    1. Static imports. Every .exe and .dll in the bundle, including ones check 2 may not
       reach: each imported DLL name is resolved the way the loader
       would on a clean machine (the file's own directory, System32, the Windows directory)
       and classified. API-set names (api-ms-win-*, ext-ms-win-*) are resolved by Windows
       itself and count as WINDOWS.

    2. What the app loads when it runs. The app runs under a small debugger loop that
       records every DLL the loader maps into it, including ones opened at run time with
       LoadLibrary (which is how CFFI opens libraries, and how SBCL reopens the libraries
       an image had open when it was dumped). PATH is restricted to the bundle, System32
       and the Windows directory, and the working directory is a fresh empty one, so a DLL
       found only through a developer's PATH fails to load instead of passing. The app
       passes if it exits 0, or if it is still running after -Seconds (a server or a
       window); it fails if it exits with any other code.

       The debugger follows every process the app starts, and every process those start
       (#268). All of them are listed with their program and exit code, but only the ones
       whose program is in the bundle are judged: the app, and hyperion-view.exe when the
       app opens a window. The WebView2 runtime's msedgewebview2.exe processes and
       Windows' conhost.exe are followed and not judged, because what they load (GPU
       drivers, for one) depends on the runtime and the machine, not on the bundle. The
       report says whether the window opened: hyperion-view.exe had a visible window and
       the WebView2 runtime started. If it did not open, the report says so, and what was
       judged for hyperion-view.exe is what it loaded before it stopped.

       Software that loads itself into every process on a machine (some audio utilities
       do) shows up as a FINDING, because the verifier cannot tell it from a DLL our code
       asked for. Off CI, a failing report says so; the CI runner's report decides.

    3. The control. For each carried DLL the app loaded in check 2, a copy of the bundle
       without that DLL is run the same way, and that run must not pass: the app has to
       fail, or load the DLL from outside the bundle (a FINDING). If it passes, the app is
       not really using the carried copy.

  What this cannot tell you: whether a Windows machine without this one's other software
  can run the bundle. A DLL the app loads only on a code path this run did not reach is not
  seen, and a DLL that a user's machine lacks but this one has in a Windows-owned location
  is classified by its signature, not by trying a machine without it. A fresh VM or a
  runner that only downloads the artifact is the clean room (ADR-0013).

  Needs nothing beyond Windows: the debugger loop uses kernel32, and a process may debug a
  child it starts without administrator rights.

.PARAMETER Bundle
  The bundle directory, e.g. dist\coalton-repl-0.1.0-windows-x86-64.

.PARAMETER Seconds
  How long the app may run before it counts as started and is stopped. Default 20.

.PARAMETER AppArgs
  Arguments passed to the app.

.EXAMPLE
  .\scripts\verify-bundle-windows.ps1 dist\coalton-repl-0.1.0-windows-x86-64
.EXAMPLE
  .\scripts\verify-bundle-windows.ps1 dist\uv-probe-0.0.0-windows-x86-64 -Seconds 60
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)][string]$Bundle,
  [int]$Seconds = 20,
  [string]$AppArgs = ''
)

$ErrorActionPreference = 'Stop'

function Info($m) { Write-Host "==> $m" -ForegroundColor Blue }
function Note($m) { Write-Host "    $m" -ForegroundColor DarkGray }
function Good($m) { Write-Host "  ok      $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAILED  $m" -ForegroundColor Red }

# Every failure is recorded and the run continues; the verdict is computed from the list at
# the end, as in verify-clean-machine.ps1.
$script:Failures = @()
function Fail($m) { $script:Failures += $m; Bad $m }
function Warn($m) { Write-Host "  NOTE    $m" -ForegroundColor Yellow }
$script:LoadFindings = 0
$OnCI = ($env:GITHUB_ACTIONS -eq 'true') -or [bool]$env:CI

if ($env:OS -ne 'Windows_NT') { Write-Host 'ERROR: Windows only; see verify-bundle.sh and verify-bundle-macos.sh' -ForegroundColor Red; exit 2 }
if (-not (Test-Path -LiteralPath $Bundle -PathType Container)) { Write-Host "ERROR: no such bundle directory: $Bundle" -ForegroundColor Red; exit 2 }
$BundleDir = (Resolve-Path -LiteralPath $Bundle).Path.TrimEnd('\')
$WinDir = $env:WINDIR.TrimEnd('\')
$Sys32 = [Environment]::SystemDirectory.TrimEnd('\')

# The app is the one executable that is not a helper the bundle also carries.
$helpers = @('hyperion-view.exe', 'webview-launcher.exe', 'uninstall.exe')
$apps = @(Get-ChildItem -LiteralPath $BundleDir -Filter *.exe -File | Where-Object { $helpers -notcontains $_.Name.ToLower() })
if ($apps.Count -ne 1) {
  Write-Host "ERROR: expected one application .exe in $BundleDir, found $($apps.Count): $($apps.Name -join ', ')" -ForegroundColor Red
  exit 2
}
$AppExe = $apps[0].FullName

# --- the debugger loop -------------------------------------------------------------
# DEBUG_PROCESS: the app and every process it starts, and every process those start, are
# debugged, so hyperion-view.exe and the WebView2 runtime's msedgewebview2.exe processes are
# traced too (#268). Every exception except each process's initial loader breakpoint is
# passed back unhandled, so the processes' own handlers run exactly as they would without a
# debugger (SBCL and Chromium both raise exceptions in normal operation). When the app exits,
# or -Seconds runs out, every process still running is stopped, and the loop waits up to 20 s
# for their exit events. Once a second the loop records which traced processes own a visible
# top-level window, which is how the report says whether the window opened.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace OuranosVerify {
  public class TracedProcess {
    public int Pid;
    public string Image = "";
    public List<string> Dlls = new List<string>();
    public bool Exited;          // an exit event arrived
    public bool Stopped;         // it was still running when the verifier stopped the run
    public int ExitCode;
    public bool Window;          // it owned a visible top-level window at some point
  }

  public class LoadTrace {
    public List<TracedProcess> Procs = new List<TracedProcess>();
    public List<string> Dlls = new List<string>();     // the app's own, as before #268
    public bool Exited;                                // the app exited before it was stopped
    public int ExitCode;
    public int Pid;
    public string[] OutputTail = new string[0];

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO { public int cb; public string r, d, t; public int x, y, xs, ys, xc, yc, fill, flags; public short show, cbr2; public IntPtr r2, i, o, e; }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int pid, tid; }
    [StructLayout(LayoutKind.Sequential)]
    struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSecurityDescriptor; public bool bInheritHandle; }
    delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lparam);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, ref SECURITY_ATTRIBUTES sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WaitForDebugEvent(byte[] ev, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ContinueDebugEvent(int pid, int tid, uint status);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateProcess(IntPtr h, uint code);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern uint GetFinalPathNameByHandleW(IntPtr h, StringBuilder buf, uint len, uint flags);
    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lparam);
    [DllImport("user32.dll")]
    static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr hwnd, out int pid);

    const uint DEBUG_PROCESS = 0x1, CREATE_NEW_CONSOLE = 0x10, PROCESS_TERMINATE = 0x1;
    const uint DBG_CONTINUE = 0x00010002, DBG_EXCEPTION_NOT_HANDLED = 0x80010001;

    // DEBUG_EVENT on x64: code, pid, tid, then the union at offset 16. The file handle is the
    // first field of both CREATE_PROCESS_DEBUG_INFO and LOAD_DLL_DEBUG_INFO, and the debugger
    // owns it and must close it.
    static string PathOf(IntPtr h) {
      if (h == IntPtr.Zero) return null;
      var sb = new StringBuilder(1024);
      uint n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
      CloseHandle(h);
      if (n == 0 || n >= sb.Capacity) return null;
      string s = sb.ToString();
      if (s.StartsWith(@"\\?\UNC\")) return @"\\" + s.Substring(8);
      if (s.StartsWith(@"\\?\")) return s.Substring(4);
      return s;
    }

    static void MarkWindows(Dictionary<int, TracedProcess> procs, HashSet<int> live) {
      EnumWindows(delegate(IntPtr hwnd, IntPtr unused) {
        int pid;
        GetWindowThreadProcessId(hwnd, out pid);
        if (live.Contains(pid) && IsWindowVisible(hwnd)) procs[pid].Window = true;
        return true;
      }, IntPtr.Zero);
    }

    static void StopAll(HashSet<int> live) {
      foreach (int victim in new List<int>(live)) {
        IntPtr h = OpenProcess(PROCESS_TERMINATE, false, victim);
        if (h != IntPtr.Zero) { TerminateProcess(h, 0); CloseHandle(h); }
      }
    }

    // OUTPUT is a file that receives the app's stdout and stderr, so that a failure to start
    // can be reported with the app's own words (SBCL names the shared object it could not
    // open). The handle is created inheritable and handed over through STARTF_USESTDHANDLES;
    // this process closes its copy once the child has one.
    public static LoadTrace Run(string exe, string args, string cwd, int seconds, string output) {
      var t = new LoadTrace();
      var si = new STARTUPINFO();
      si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
      var sa = new SECURITY_ATTRIBUTES();
      sa.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
      sa.bInheritHandle = true;
      // GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL
      IntPtr log = CreateFileW(output, 0x40000000, 3, ref sa, 2, 0x80, IntPtr.Zero);
      if (log == new IntPtr(-1))
        throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "CreateFile " + output);
      si.flags = 0x100;                                    // STARTF_USESTDHANDLES
      si.o = log; si.e = log; si.i = IntPtr.Zero;
      var cmd = new StringBuilder("\"" + exe + "\"" + (string.IsNullOrEmpty(args) ? "" : " " + args));
      PROCESS_INFORMATION pi;
      bool ok = CreateProcessW(exe, cmd, IntPtr.Zero, IntPtr.Zero, true, DEBUG_PROCESS | CREATE_NEW_CONSOLE, IntPtr.Zero, cwd, ref si, out pi);
      int err = Marshal.GetLastWin32Error();
      CloseHandle(log);
      if (!ok) throw new System.ComponentModel.Win32Exception(err, "CreateProcess " + exe);
      t.Pid = pi.pid;
      var procs = new Dictionary<int, TracedProcess>();
      var live = new HashSet<int>();
      var sawLoaderBreak = new HashSet<int>();
      var ev = new byte[256];
      var deadline = DateTime.UtcNow.AddSeconds(seconds);
      var nextLook = DateTime.UtcNow;
      DateTime stopBy = DateTime.MaxValue;
      bool stopping = false;
      while (true) {
        if (!stopping && DateTime.UtcNow > deadline) {
          MarkWindows(procs, live);
          stopping = true; stopBy = DateTime.UtcNow.AddSeconds(20); StopAll(live);
        }
        if (stopping && (live.Count == 0 || DateTime.UtcNow > stopBy)) break;
        if (!stopping && DateTime.UtcNow >= nextLook) { MarkWindows(procs, live); nextLook = DateTime.UtcNow.AddSeconds(1); }
        if (!WaitForDebugEvent(ev, 200)) continue;
        uint code = BitConverter.ToUInt32(ev, 0);
        int pid = BitConverter.ToInt32(ev, 4), tid = BitConverter.ToInt32(ev, 8);
        uint status = DBG_CONTINUE;
        if (code == 1) {                                   // EXCEPTION_DEBUG_EVENT
          uint ecode = BitConverter.ToUInt32(ev, 16);
          if (ecode == 0x80000003 && !sawLoaderBreak.Contains(pid)) sawLoaderBreak.Add(pid);
          else status = DBG_EXCEPTION_NOT_HANDLED;
        } else if (code == 3) {                            // CREATE_PROCESS_DEBUG_EVENT
          var p = new TracedProcess();
          p.Pid = pid;
          p.Image = PathOf(new IntPtr(BitConverter.ToInt64(ev, 16))) ?? "";
          procs[pid] = p; t.Procs.Add(p); live.Add(pid);
        } else if (code == 6) {                            // LOAD_DLL_DEBUG_EVENT
          string path = PathOf(new IntPtr(BitConverter.ToInt64(ev, 16)));
          if (procs.ContainsKey(pid)) procs[pid].Dlls.Add(path ?? "");
        } else if (code == 5) {                            // EXIT_PROCESS_DEBUG_EVENT
          if (procs.ContainsKey(pid)) {
            var p = procs[pid];
            p.Exited = true; p.Stopped = stopping; p.ExitCode = BitConverter.ToInt32(ev, 16);
          }
          live.Remove(pid);
          // The app's end is the run's end: whatever it started is stopped with it.
          if (pid == pi.pid && !stopping) { stopping = true; stopBy = DateTime.UtcNow.AddSeconds(20); StopAll(live); }
        }
        ContinueDebugEvent(pid, tid, status);
      }
      CloseHandle(pi.hThread);
      CloseHandle(pi.hProcess);
      if (procs.ContainsKey(pi.pid)) {
        var root = procs[pi.pid];
        t.Dlls = root.Dlls; t.Exited = root.Exited && !root.Stopped; t.ExitCode = root.ExitCode;
      }
      return t;
    }
  }
}
'@

# --- classification ------------------------------------------------------------------
function Test-Under($path, $dir) { $path.StartsWith($dir + '\', [StringComparison]::OrdinalIgnoreCase) }

# The version of the WebView2 runtime a path is under, or $null. The runtime is installed per
# machine under Program Files (x86), or per user under LOCALAPPDATA, in both cases as
# ...\Microsoft\EdgeWebView\Application\<four-part version>\.
function Get-WebView2Version([string]$Path) {
  if ($Path -match '\\Microsoft\\EdgeWebView\\Application\\(\d+\.\d+\.\d+\.\d+)\\') { return $Matches[1] }
  return $null
}

function Get-DllClass([string]$Path, [string]$Carrier) {
  if (-not $Path) { return [pscustomobject]@{ Kind = 'FINDING'; Detail = 'the debugger was given no file handle for it, so its location is unknown' } }
  if (Test-Under $Path $Carrier) { return [pscustomobject]@{ Kind = 'CARRIED'; Detail = 'in the bundle' } }
  $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction SilentlyContinue
  if ((Test-Under $Path $WinDir) -and $sig -and $sig.Status -eq 'Valid' -and $sig.IsOSBinary) {
    return [pscustomobject]@{ Kind = 'WINDOWS'; Detail = 'operating-system binary' }
  }
  $vi = (Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue).VersionInfo
  $signer = if ($sig -and $sig.SignerCertificate) { $sig.SignerCertificate.Subject -replace '^CN=([^,]+).*', '$1' } else { 'none' }
  # The WebView2 runtime is a declared dependency, which the installer installs (#268). A file
  # counts as part of it only if it is in the runtime's directory AND has a valid signature
  # from Microsoft Corporation; either one alone is a finding.
  $wv = Get-WebView2Version $Path
  if ($wv -and $sig -and $sig.Status -eq 'Valid' -and $signer -eq 'Microsoft Corporation') {
    return [pscustomobject]@{ Kind = 'WEBVIEW2'; Detail = "WebView2 runtime $wv, file version $($vi.FileVersion)" }
  }
  $status = if ($sig) { $sig.Status } else { 'unreadable' }
  return [pscustomobject]@{
    Kind   = 'FINDING'
    Detail = "neither carried nor part of Windows -- signature $status, signer '$signer', CompanyName '$($vi.CompanyName)', ProductName '$($vi.ProductName)'"
  }
}

# --- PE import table (for check 1) ---------------------------------------------------
function Test-PeFile([string]$Path) {
  # A truncated or empty DLL in a bundle is a finding. It gets its own test because an empty
  # list returned from Get-PeImports reads as "imports nothing", which would pass it.
  $b = [IO.File]::ReadAllBytes($Path)
  if ($b.Length -lt 0x40) { return $false }
  $pe = [BitConverter]::ToInt32($b, 0x3C)
  return ($pe -ge 0 -and $pe + 24 -le $b.Length -and [BitConverter]::ToUInt32($b, $pe) -eq 0x00004550)
}

function Get-PeImports([string]$Path) {
  $b = [IO.File]::ReadAllBytes($Path)
  $pe = [BitConverter]::ToInt32($b, 0x3C)
  $nsec = [BitConverter]::ToUInt16($b, $pe + 6)
  $optSize = [BitConverter]::ToUInt16($b, $pe + 20)
  $opt = $pe + 24
  $dirs = if ([BitConverter]::ToUInt16($b, $opt) -eq 0x20b) { $opt + 112 } else { $opt + 96 }
  $secs = for ($s = 0; $s -lt $nsec; $s++) {
    $o = $opt + $optSize + 40 * $s
    [pscustomobject]@{ Va = [BitConverter]::ToUInt32($b, $o + 12); Vs = [BitConverter]::ToUInt32($b, $o + 8)
                       Raw = [BitConverter]::ToUInt32($b, $o + 20); RawSize = [BitConverter]::ToUInt32($b, $o + 16) }
  }
  function Off($rva) {
    foreach ($s in $secs) { if ($rva -ge $s.Va -and $rva -lt $s.Va + [Math]::Max($s.Vs, $s.RawSize)) { return $rva - $s.Va + $s.Raw } }
    return -1
  }
  function Str($off) { $e = $off; while ($e -lt $b.Length -and $b[$e] -ne 0) { $e++ }; [Text.Encoding]::ASCII.GetString($b, $off, $e - $off) }
  $names = @()
  # Data directory 1 is the import table (20-byte descriptors, Name at +12); 13 is the
  # delay-load table (32-byte descriptors, DllNameRVA at +4).
  foreach ($d in @(@{ Index = 1; Size = 20; NameAt = 12 }, @{ Index = 13; Size = 32; NameAt = 4 })) {
    $rva = [BitConverter]::ToUInt32($b, $dirs + 8 * $d.Index)
    if ($rva -eq 0) { continue }
    $o = Off $rva
    if ($o -lt 0) { continue }
    while ($o + $d.Size -le $b.Length) {
      $nameRva = [BitConverter]::ToUInt32($b, $o + $d.NameAt)
      if ($nameRva -eq 0) { break }
      $no = Off $nameRva
      if ($no -ge 0) { $names += (Str $no) }
      $o += $d.Size
    }
  }
  return $names | Sort-Object -Unique
}

function Resolve-Import([string]$Name, [string]$FromDir) {
  foreach ($d in @($FromDir, $Sys32, $WinDir)) {
    $p = Join-Path $d $Name
    if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
  }
  return $null
}

# --- running the app -----------------------------------------------------------------
function Invoke-Traced([string]$Dir, [string]$Exe) {
  $work = Join-Path $env:TEMP ("ouranos-verify-bundle-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  $oldPath = $env:PATH
  $env:PATH = "$Dir;$Sys32;$WinDir"
  $t = $null
  $out = Join-Path $work 'app-output.txt'
  try { $t = [OuranosVerify.LoadTrace]::Run($Exe, $AppArgs, $work, $Seconds, $out) }
  finally {
    $env:PATH = $oldPath
    if ($t -and (Test-Path -LiteralPath $out)) {
      # The first lines and the last few. SBCL states the error first and then prints a
      # backtrace, so the lines that say why are at the top, not the bottom.
      $lines = @(Get-Content -LiteralPath $out -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })
      $t.OutputTail = if ($lines.Count -le 12) { $lines } else { @($lines[0..7]) + @("... ($($lines.Count - 11) lines omitted)") + @($lines[-3..-1]) }
    }
    # The loop stops every traced process and waits 20 s for it to go. One that has still
    # not reported its exit is stopped again here, so no run leaves a process behind.
    if ($t) {
      $t.Procs | Where-Object { -not $_.Exited } |
        ForEach-Object { Stop-Process -Id $_.Pid -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
  }
  return $t
}

function Get-RunVerdict($t) {
  if (-not $t.Exited) { return [pscustomobject]@{ Ok = $true; Text = "still running after $Seconds s, so it started; stopped" } }
  if ($t.ExitCode -eq 0) { return [pscustomobject]@{ Ok = $true; Text = 'exited 0' } }
  # The app's own words, so the report says WHY it did not start (#78: on the runner,
  # "exited with code 1" alone left the reader to guess that OpenSSL was missing).
  $said = if ($t.OutputTail.Count) { ". Its output:`n" + (($t.OutputTail | ForEach-Object { "            | $_" }) -join "`n") } else { '. It wrote nothing to stdout or stderr.' }
  return [pscustomobject]@{ Ok = $false; Text = "exited with code $($t.ExitCode) within $Seconds s"; Said = $said }
}

Info "verify-bundle-windows (#78): $BundleDir"
Note "app     : $(Split-Path -Leaf $AppExe)"
$carriedFiles = @(Get-ChildItem -LiteralPath $BundleDir -Filter *.dll -File -Recurse)
Note ("carried : " + $(if ($carriedFiles) { ($carriedFiles | ForEach-Object { $_.FullName.Substring($BundleDir.Length + 1) }) -join ', ' } else { '(no DLLs)' }))
Note "PATH    : $BundleDir;$Sys32;$WinDir"
Note "judged  : the processes whose program is in the bundle; every other process is followed and listed"

# --- check 1 -------------------------------------------------------------------------
Write-Host ''
Info 'check 1: the static imports of every executable and DLL in the bundle'
foreach ($f in @(Get-ChildItem -LiteralPath $BundleDir -File -Recurse | Where-Object { $_.Extension -in '.exe', '.dll' })) {
  $rel = $f.FullName.Substring($BundleDir.Length + 1)
  if (-not (Test-PeFile $f.FullName)) { Fail "$rel is not a valid executable file ($($f.Length) bytes), so Windows cannot load it"; continue }
  foreach ($name in (Get-PeImports $f.FullName)) {
    if ($name -match '^(api|ext)-ms-win-') { continue }
    $p = Resolve-Import $name $f.DirectoryName
    if (-not $p) { Fail "$rel imports $name, which is not in the bundle, System32 or the Windows directory"; continue }
    $c = Get-DllClass $p $BundleDir
    if ($c.Kind -eq 'FINDING') { Fail "$rel imports $name -> $p -- $($c.Detail)" }
  }
  Good "$rel"
}

# --- check 2 -------------------------------------------------------------------------
Write-Host ''
Info "check 2: what $(Split-Path -Leaf $AppExe), and the processes it starts, load when they run"
$trace = Invoke-Traced $BundleDir $AppExe
$run = Get-RunVerdict $trace
if ($run.Ok) { Good "the app $($run.Text)" } else { Fail "the app $($run.Text), so it does not start with only the bundle and Windows$($run.Said)" }

# Every process the run started is listed, judged or not (#268). A process is judged when its
# program is in the bundle: the app, and hyperion-view.exe when the app opens a window. The
# others belong to Windows (conhost.exe) or to the WebView2 runtime (msedgewebview2.exe).
# What those load is decided by Windows, the runtime and this machine's drivers, and nothing
# in the bundle could change it.
function Get-ProcState($p) {
  if (-not $p.Exited) { return 'did not exit within 20 s of being stopped' }
  if ($p.Stopped) { return 'stopped by the verifier' }
  return ('exited with code {0} (0x{0:X8})' -f $p.ExitCode)
}
$judged = @($trace.Procs | Where-Object { $_.Image -and (Test-Under $_.Image $BundleDir) })
Note "processes traced: $($trace.Procs.Count), of which $($judged.Count) judged"
foreach ($p in $trace.Procs) {
  $role = if ($judged -contains $p) { 'judged' } else { 'followed, not judged: its program is not in the bundle' }
  Note ("  pid {0,-6} {1} -- {2}; {3}" -f $p.Pid, $(if ($p.Image) { $p.Image } else { '(image unknown)' }), (Get-ProcState $p), $role)
}

# Exit codes that mean Windows could not load the program or a DLL it needs.
$loaderStatus = @{ -1073741515 = 'STATUS_DLL_NOT_FOUND'; -1073741511 = 'STATUS_ENTRYPOINT_NOT_FOUND'; -1073741701 = 'STATUS_INVALID_IMAGE_FORMAT' }
$loadedCarried = @()
$webview2 = @{}
foreach ($p in $judged) {
  $leaf = Split-Path -Leaf $p.Image
  # The instrument has to show it saw something before its silence about the rest is
  # trusted. Every Windows process maps ntdll.dll and kernel32.dll; a trace without them
  # recorded nothing.
  $loaded = @($p.Dlls | Sort-Object -Unique)
  if (-not ($loaded | Where-Object { $_ -like '*\ntdll.dll' }) -or -not ($loaded | Where-Object { $_ -like '*\kernel32.dll' })) {
    Fail "the load trace of $leaf (pid $($p.Pid)) has no ntdll.dll or kernel32.dll ($($loaded.Count) entries), so it recorded nothing and this check saw nothing"
  }
  $n = @{ CARRIED = 0; WINDOWS = 0; WEBVIEW2 = 0; FINDING = 0 }
  foreach ($d in $loaded) {
    $c = Get-DllClass $d $BundleDir
    $n[$c.Kind]++
    switch ($c.Kind) {
      'CARRIED' { Good "$leaf loaded carried $d"; $loadedCarried += $d }
      'WINDOWS' { }
      'WEBVIEW2' { $webview2[$d] = $c.Detail }
      default { $script:LoadFindings++; Fail "$leaf loaded $d -- $($c.Detail)" }
    }
  }
  Good "${leaf}: $($n.WINDOWS) Windows DLLs, $($n.CARRIED) carried, $($n.WEBVIEW2) from the WebView2 runtime, $($n.FINDING) neither"
  if ($p.Pid -ne $trace.Pid -and $p.Exited -and -not $p.Stopped -and $loaderStatus.ContainsKey($p.ExitCode)) {
    Fail "$leaf exited with $($loaderStatus[$p.ExitCode]), so Windows could not load it or a DLL it needs"
  }
}
$loadedCarried = @($loadedCarried | Sort-Object -Unique)
# The WebView2 runtime is a dependency the bundle declares rather than carries, so each file
# of it that was loaded is recorded by name and version.
foreach ($d in ($webview2.Keys | Sort-Object)) { Good "WebView2 runtime: $(Split-Path -Leaf $d), $($webview2[$d]) -- $d" }
foreach ($f in $carriedFiles) {
  if (-not ($loadedCarried | Where-Object { $_ -ieq $f.FullName })) {
    Note "$($f.Name) is carried but was not loaded on this run (another code path, or other -AppArgs, may need it)"
  }
}

# Whether the window opened (#268). If it did not, the DLLs judged for hyperion-view.exe are
# the ones it loaded before it stopped, and the report says so rather than passing quietly.
$views = @($judged | Where-Object { (Split-Path -Leaf $_.Image) -ieq 'hyperion-view.exe' })
$runtimeProcs = @($trace.Procs | Where-Object { $_.Image -and (Get-WebView2Version $_.Image) })
if (-not $views) { Note 'no hyperion-view.exe process started on this run, so there was no window to check' }
foreach ($v in $views) {
  if ($v.Window -and $runtimeProcs.Count -gt 0) {
    Good "the window opened: hyperion-view.exe (pid $($v.Pid)) had a visible window, and the WebView2 runtime started $($runtimeProcs.Count) processes"
  } else {
    $why = @()
    if (-not $v.Window) { $why += 'hyperion-view.exe never had a visible window' }
    if ($runtimeProcs.Count -eq 0) { $why += 'the WebView2 runtime started no processes' }
    Warn "the window did not open: $($why -join ', and '). hyperion-view.exe (pid $($v.Pid)) $(Get-ProcState $v). What was judged for it above is what it loaded before that."
  }
}

# --- check 3 -------------------------------------------------------------------------
Write-Host ''
Info 'check 3: without a carried DLL, the app must not pass'
if (-not $loadedCarried) {
  Note '(nothing carried was loaded, so there is nothing to remove)'
}
foreach ($dll in $loadedCarried) {
  $name = $dll.Substring($BundleDir.Length + 1)
  # A copy, never the real bundle: an interrupted run must not leave the artifact broken.
  $copy = Join-Path $env:TEMP ("ouranos-verify-control-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  Copy-Item -Recurse -LiteralPath $BundleDir -Destination $copy
  try {
    Remove-Item -LiteralPath (Join-Path $copy $name) -Force
    $t = Invoke-Traced $copy (Join-Path $copy (Split-Path -Leaf $AppExe))
    $v = Get-RunVerdict $t
    $leaf = Split-Path -Leaf $name
    $outside = @($t.Procs | Where-Object { $_.Image -and (Test-Under $_.Image $copy) } | ForEach-Object { $_.Dlls } | Where-Object { $_ -and (Split-Path -Leaf $_) -ieq $leaf -and -not (Test-Under $_ $copy) })
    if ($outside) { Good "without $name the app loaded $($outside[0]) instead, which check 2 would report as a finding" }
    elseif (-not $v.Ok) { Good "without $name the app $($v.Text)" }
    else { Fail "without $name the app still $($v.Text) and loaded no other copy, so it is not using the carried one" }
  } finally { Remove-Item -Recurse -Force -LiteralPath $copy -ErrorAction SilentlyContinue }
}

# --- verdict -------------------------------------------------------------------------
Write-Host ''
if ($script:Failures.Count -eq 0) {
  Info 'verify-bundle-windows: PASS'
  Note 'This shows the bundle loads only what it carries and what Windows ships, on the code'
  Note 'paths this run reached. It does not show that a machine without this one''s other'
  Note 'software can run it; for that, run the artifact on a machine that never built it (ADR-0013).'
  exit 0
}
Write-Host "verify-bundle-windows: FAIL ($($script:Failures.Count)):" -ForegroundColor Red
$script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
if ($script:LoadFindings -gt 0 -and -not $OnCI) {
  # The verifier cannot tell a DLL that other software puts into every process (an audio
  # utility did this on the machine #268 was measured on) from one our code asked for.
  Write-Host ''
  Note "This did not run on CI. A DLL reported as neither carried nor part of Windows may come"
  Note "from software installed on this machine that loads itself into other programs. The CI"
  Note "runner has no such software, so its report is the one that decides."
}
exit 1
