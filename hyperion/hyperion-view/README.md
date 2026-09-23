# hyperion-view — Hyperion's native desktop shell

The native half of Hyperion's **desktop capability** (see
[`../docs/adr/0008-desktop-shell-cl-native-webview.md`](../docs/adr/0008-desktop-shell-cl-native-webview.md)
and [`../docs/desktop.md`](../docs/desktop.md)).

A ~15-line C++ program (`hyperion-view.cc`) over the MIT single-header
[`webview.h`](https://github.com/webview/webview) (v0.10.0, vendored) that opens a native OS
window hosting the platform webview at a URL — **WebKitGTK** on Linux, **WKWebView** on
macOS, **WebView2** on Windows. `hyperion/desktop:run-app` starts a Hyperion server on
localhost and launches this binary as a subprocess pointed at it — **out-of-process**, so the
webview owns its own GUI main thread and never collides with SBCL's.

This is a **per-machine, per-OS build artifact** (gitignored): build it once on each machine.
Given the prerequisite compiler for your OS, the build is a single command and needs no other
project setup.

---

## Prerequisites & build — per platform

Run from this directory (`hyperion/hyperion-view/`). Output: `./hyperion-view` (Unix) or
`.\hyperion-view.exe` (Windows). Override the compiler with `$CXX`.

**Check a machine before building** — every entry point takes `--check` / `-Check`, which
verifies the compiler, SDK and runtime this OS needs, prints an install command for anything
missing, and exits non-zero if the build cannot proceed:

```sh
./build.sh --check                # Linux / macOS / (Windows, via build.ps1)
.\build.ps1 -Check                # Windows, native PowerShell
```

### Linux — WebKitGTK  ✅ *(verified)*

Install a C++ compiler, `pkg-config`, and the WebKitGTK dev headers, then build:

```sh
# Debian / Ubuntu
sudo apt install g++ pkg-config libwebkit2gtk-4.1-dev      # or libwebkit2gtk-4.0-dev on older releases
# Fedora
sudo dnf install gcc-c++ pkgconf-pkg-config webkit2gtk4.1-devel
# Arch
sudo pacman -S gcc pkgconf webkit2gtk-4.1

./build.sh
```

`build.sh` auto-detects `webkit2gtk-4.1`, falling back to `-4.0`. Runtime needs the matching
`libwebkit2gtk` (pulled in by the dev package; present on any GTK desktop).

Note **`webkit2gtk-4.1` specifically**: the vendored `webview.h` v0.10.0 uses the WebKit2 C API,
so `libwebkitgtk-6.0-dev` (the GTK4 API, shipping alongside it on recent distros) is *not* a
substitute. One `-Wdeprecated-declarations` warning (`webkit_web_view_run_javascript`) is
expected; the binary is fine.

Verified 2026-07-25 on Ubuntu 26.04 (WSL2), from a bare box — `--check` correctly failed on all
three prerequisites, then after `sudo apt install g++ pkg-config libwebkit2gtk-4.1-dev` built a
53,736-byte ELF that opens a real window. Under **WSLg** the launcher prints `libEGL`/`MESA`
warnings (software GL, no GPU device) — noise; the window renders.

### macOS — WKWebView  ✅ *(verified)*

Only the Xcode command-line tools; **WebKit.framework is built into the OS** — nothing to fetch:

```sh
xcode-select --install     # if `xcode-select -p` prints nothing
./build.sh                 # clang++ -std=c++17 -O2 … -framework WebKit
```

Verified on Apple clang 21 / Apple silicon → a native `arm64` Mach-O. (Three harmless
`-Wdeprecated-literal-operator` warnings from the vendored `webview.h`; the binary is fine.)

### Windows — WebView2  ✅ *(verified — MSVC and mingw-w64)*

**`build.ps1` is the Windows build** — plain PowerShell (5.1, i.e. stock `powershell.exe`, or
`pwsh`): no MSYS2 shell, no `curl`/`unzip`. It checks prerequisites, fetches the WebView2 SDK
headers itself, and compiles with **whichever toolchain the machine has** — MSVC preferred,
mingw-w64 otherwise. `./build.sh` from an MSYS2/Git-Bash shell **delegates to it**, so both
entry points do the same thing.

From nothing to a built launcher on a fresh Windows box:

```powershell
# 1. ONE C++ toolchain -- MSVC (preferred: no MSYS2, smaller binary) ...
winget install --id Microsoft.VisualStudio.2022.BuildTools `
  --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
#    ... or mingw-w64
winget install --id MSYS2.MSYS2      # then, in the UCRT64 shell: pacman -S mingw-w64-ucrt-x86_64-gcc

# 2. the WebView2 RUNTIME -- preinstalled on Windows 11; needed on Windows 10
winget install --id Microsoft.EdgeWebView2Runtime

# 3. check, then build
cd hyperion\hyperion-view
.\build.ps1 -Check                   # PASS/FAIL per prerequisite, with the fix for each
.\build.ps1                          # -> hyperion-view.exe
```

If the machine's execution policy blocks scripts:
`powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1`.

Options: `-Compiler msvc|mingw|auto` · `-Check` · `-Sdk <version> -SdkSha256 <sha256>` · `-Out <path>` · `-Refresh`
(re-fetch the SDK headers).

What it does, and why:

| step | detail |
|------|--------|
| **MSVC discovery** | `vswhere` finds any VS edition **or the standalone Build Tools** carrying the C++ workload, then the environment `vcvarsall.bat` sets is imported into the session — so **no Developer Command Prompt is required**. Already in one (`cl.exe` on `PATH`)? That is used as-is. |
| **mingw discovery** | UCRT64/MINGW64/CLANG64, choco, scoop, `$CXX`, `PATH`. Each candidate is vetted with `g++ -dumpmachine`: **`x86_64-w64-mingw32` is accepted, `x86_64-pc-msys` is rejected** — MSYS2's `/usr/bin/g++` targets the POSIX-emulation runtime (`msys-2.0.dll`) and cannot build a native Win32 GUI binary, and it is usually the one first on `PATH`. |
| **WebView2 SDK headers** | A `.nupkg` is a zip, so `Invoke-WebRequest` + `Expand-Archive` (NuGet v3 flat container, v2 as fallback) into gitignored `.webview2-sdk/`. The version and the SHA-256 of the `.nupkg` are pinned in `scripts/versions.env` (`WEBVIEW2_SDK_VERSION`, `WEBVIEW2_SDK_SHA256`); a download that does not match the checksum is deleted and the build stops. `.webview2-sdk/.pin` records the pin the headers came from, and headers from any other pin are fetched again. Microsoft-licensed, hence fetched, never committed. |
| **WebView2 runtime** | Probed in the registry (`EdgeUpdate\Clients\{F3017226-…}`, per-machine and per-user). Missing is a **warning**, not an error: the build still succeeds, but no window will open at run time. |
| **compile (MSVC)** | `cl /std:c++17 /EHsc /O2 /MT … /link /SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup oleaut32.lib`. `/MT` = static CRT, so **no VC++ redistributable** on target machines; `/SUBSYSTEM:WINDOWS` + `mainCRTStartup` = a GUI app (no console window) with an ordinary `main()`. `webview.h` `#pragma`-links advapi32/ole32/shell32/shlwapi/user32/version itself; `oleaut32` is the one it does not. → ~170 KB. |
| **compile (mingw)** | `-std=c++17 -O2 -mwindows -static` + the same libs. The compiler's own `bin\` is prepended to `PATH` first: a full-path mingw `g++` needs it to find `cc1plus`/`as`/`ld`, and **fails silently (exit 1, no message)** without it. → ~1 MB. |

Either way the result is standalone (static CRT + `webview.h`'s built-in WebView2 loader, so no
`WebView2Loader.dll` to ship); the only run-time requirement is the WebView2 runtime.

Verified 2026-07-25 on Windows 11 (26200), x64: MSVC 14.51 (VS 18) → 173,568 bytes, and
mingw-w64 UCRT64 g++ → 1,014,324 bytes; both open a WebView2 window against the runtime
(150.0.4078.83).

---

## Verify

```sh
./build.sh                                        # built: …/hyperion-view[.exe]
./hyperion-view https://example.com "Smoke" 800 600   # opens a window; close it to exit
```
```powershell
.\build.ps1                                              # Windows
.\hyperion-view.exe https://example.com "Smoke" 800 600
```

## Putting it together — run a Hyperion app as a desktop window

The launcher is only the native half. The full flow on a fresh machine:

```sh
# 1. the CL side, once at the repo root (SBCL + Quicklisp assumed installed)
sbcl --dynamic-space-size 4096 --script bootstrap.lisp

# 2. this native launcher, once per machine (this dir)
cd hyperion/hyperion-view && ./build.sh      # Windows: .\build.ps1  (./build.sh delegates to it)

# 3. run any hyperion app as a desktop window — e.g. the Coalton REPL example
sbcl --dynamic-space-size 4096 \
  --eval '(ql:quickload :hyperion/examples/coalton-repl)' \
  --eval '(hyperion/examples/coalton-repl:desktop)'
```

`hyperion/desktop:run-app` resolves the binary via **`default-launcher`**: `*launcher*` if set,
else `hyperion-view[.exe]` **beside the running image** (how a shipped app bundles it), else
this **built copy in the source tree** (dev — step 2), else the bare name on **`PATH`**. During
UI dev prefer the `:browser` shell or an example's `dev` target (same server, your browser, hot
reload); switch to `:webview` to see it as a real window.

## Packaging into deployable installers — roadmap

Building the launcher is step one; turning a Hyperion desktop app into a **distributable,
installable bundle** per platform is the next milestone (to be driven by **`cons desktop`** —
see [cons-vision §10](../../cons/docs/cons-vision.md)). The shape per platform:

- **macOS** — an `.app` bundle (Info.plist + the SBCL-dumped binary + the `hyperion-view`
  beside it, which `default-launcher` already expects), then a signed/notarized `.dmg` or `.pkg`.
- **Windows** — the dumped `.exe` + `hyperion-view.exe`, wrapped by an installer (WiX/MSI or
  NSIS), assuming/ensuring the WebView2 runtime; code-signing for SmartScreen.
- **Linux** — an AppImage (self-contained) or a `.deb`/`.rpm` declaring the `libwebkit2gtk`
  dependency; optionally a Flatpak.

Cross-cutting: **auto-update** glue and the `~/.<appname>` config dir (per ADR-0008/0009). This
is a design item, not yet built — tracked for `cons desktop`.

## Provenance

- `webview.h` — webview/webview **v0.10.0**, MIT (license header intact in the file).
- **WebView2 SDK headers** — fetched at build time on Windows, **not committed** (Microsoft license).
