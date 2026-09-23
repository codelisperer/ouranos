#!/usr/bin/env sh
# build.sh --- build the native webview launcher for THIS OS.
# Output: ./hyperion-view (Unix) or ./hyperion-view.exe (Windows).
#
#   ./build.sh            build
#   ./build.sh --check    check prerequisites only (exit 1 if something is missing)
#
# Prereqs:
#   Linux  : a C++ compiler + libwebkit2gtk-4.1-dev (or 4.0) + pkg-config
#            (Debian/Ubuntu: sudo apt install g++ pkg-config libwebkit2gtk-4.1-dev)
#   macOS  : Xcode command-line tools (clang++; WebKit.framework is built in)
#   Windows: MSVC (preferred) or mingw-w64 g++, + the Edge WebView2 RUNTIME.
#            Handled by build.ps1, which this script delegates to -- it also
#            fetches the WebView2 SDK headers (pinned, Microsoft-licensed, so
#            never vendored) with no curl/unzip needed.
# Override the compiler with $CXX.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
src="$here/hyperion-view.cc"
out="$here/hyperion-view"

check_only=0
for arg in "$@"; do
  case "$arg" in
    --check) check_only=1;;
    -h|--help) sed -n '2,20p' "$0"; exit 0;;
    *) echo "build.sh: unknown option $arg (try --check)" >&2; exit 2;;
  esac
done

fail=0
pass() { printf '  PASS %s\n' "$1"; }
miss() { printf '  FAIL %s\n       fix: %s\n' "$1" "$2" >&2; fail=$((fail+1)); }
have() { command -v "$1" >/dev/null 2>&1; }

case "$(uname -s)" in
  Linux)
    cxx="${CXX:-c++}"
    pkg=webkit2gtk-4.1
    # NB: an `a && ! b && c` list whose value is false would trip `set -e` -- use `if`.
    if have pkg-config && ! pkg-config --exists "$pkg" 2>/dev/null; then pkg=webkit2gtk-4.0; fi

    have "$cxx" && pass "C++ compiler ($cxx)" \
      || miss "C++ compiler ($cxx) not found" "sudo apt install g++   |  dnf install gcc-c++  |  pacman -S gcc"
    have pkg-config && pass "pkg-config" \
      || miss "pkg-config not found" "sudo apt install pkg-config   |  dnf install pkgconf-pkg-config"
    if have pkg-config && pkg-config --exists "$pkg" 2>/dev/null; then
      pass "$pkg ($(pkg-config --modversion "$pkg"))"
    else
      miss "WebKitGTK dev headers (webkit2gtk-4.1 or -4.0) not found" \
           "sudo apt install libwebkit2gtk-4.1-dev  |  dnf install webkit2gtk4.1-devel  |  pacman -S webkit2gtk-4.1"
    fi
    [ "$fail" -eq 0 ] || { echo "build.sh: missing prerequisites (see above)." >&2; exit 1; }
    [ "$check_only" -eq 0 ] || { echo "build.sh: this machine can build the launcher."; exit 0; }

    # shellcheck disable=SC2046
    "$cxx" -std=c++17 -O2 "$src" -I"$here" $(pkg-config --cflags --libs "$pkg") -o "$out"
    ;;

  Darwin)
    cxx="${CXX:-c++}"
    have "$cxx" && pass "C++ compiler ($cxx)" \
      || miss "clang++ not found" "xcode-select --install"
    if xcode-select -p >/dev/null 2>&1; then
      pass "Xcode command-line tools ($(xcode-select -p))"
    else
      miss "Xcode command-line tools not installed" "xcode-select --install"
    fi
    pass "WebKit.framework (built into macOS -- nothing to install)"
    [ "$fail" -eq 0 ] || { echo "build.sh: missing prerequisites (see above)." >&2; exit 1; }
    [ "$check_only" -eq 0 ] || { echo "build.sh: this machine can build the launcher."; exit 0; }

    "$cxx" -std=c++17 -O2 "$src" -I"$here" -framework WebKit -o "$out"
    ;;

  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    # ONE Windows implementation, in build.ps1: it handles MSVC *and* mingw-w64,
    # fetches the WebView2 SDK headers without curl/unzip, and checks the WebView2
    # runtime. Delegate so `./build.sh` from an MSYS2/Git-Bash shell and
    # `.\build.ps1` from PowerShell behave identically.
    ps=""
    for c in pwsh powershell.exe powershell \
             "/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" \
             "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"; do
      command -v "$c" >/dev/null 2>&1 && { ps="$c"; break; }
    done
    [ -n "$ps" ] || { echo "build.sh: PowerShell not found -- run build.ps1 from a PowerShell prompt." >&2; exit 1; }
    # A UNIX-style path would be meaningless to native PowerShell; hand it a Windows one.
    script="$here/build.ps1"
    have cygpath && script=$(cygpath -w "$script")
    if [ "$check_only" -eq 1 ]; then
      exec "$ps" -NoProfile -ExecutionPolicy Bypass -File "$script" -Check
    else
      exec "$ps" -NoProfile -ExecutionPolicy Bypass -File "$script"
    fi
    ;;

  *) echo "build.sh: unsupported OS $(uname -s)" >&2; exit 1;;
esac
echo "built: $out"
