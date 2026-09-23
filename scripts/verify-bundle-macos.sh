#!/usr/bin/env sh
# verify-bundle-macos.sh --- prove a macOS bundle carries what it claims (#78).
#
#     scripts/verify-bundle-macos.sh dist/uv-probe-0.0.0-macos-arm64 [-- app args...]
#     scripts/verify-bundle-macos.sh "dist/UV Probe.app"
#
# The macOS counterpart to verify-bundle.sh, and deliberately NOT a port of it. That script
# gets its authority from a container: no toolchain, no repo, no copy of the library. macOS
# has no cheap equivalent, so this one gets its authority a different way -- by checking
# WHICH file the loader actually opened, rather than only whether the process exited 0.
#
# WHY THAT IS ENOUGH HERE, AND WHERE IT IS NOT:
#
#   * LINKED libraries (ADR-0014, @executable_path) have NO fallback chain. If the carried
#     copy is missing, dyld fails at process start. Deleting it is therefore decisive on
#     any machine, including the one that built the bundle. Run 2 below is a real control.
#
#   * DLOPEN'd libraries (ADR-0013, e.g. libuv) DO have a fallback chain -- the source tree
#     and then the system. On a developer's Mac, deleting the carried copy just falls
#     through and still passes, which proves nothing. So for these we do not test by
#     deletion; we assert the PATH THE LOADER USED is inside the bundle (via
#     DYLD_PRINT_LIBRARIES). That is falsifiable here, and it is the actual claim.
#
# What this still cannot tell you: whether some OTHER machine has a library this one has.
# A macOS clean room is a fresh VM or a CI job that downloads only the artifact -- see the
# note at the bottom.

set -eu

usage() {
  echo "usage: scripts/verify-bundle-macos.sh <bundle-dir|App.app> [-- app args...]" >&2
  exit 2
}

[ $# -ge 1 ] || usage
[ "$(uname -s)" = "Darwin" ] || { echo "verify-bundle-macos: macOS only" >&2; exit 2; }

TARGET="$1"; shift
[ "${1:-}" = "--" ] && shift
[ -d "$TARGET" ] || { echo "verify-bundle-macos: no such bundle: $TARGET" >&2; exit 2; }

# A .app keeps everything in Contents/MacOS (ADR-0014); a raw bundle IS that directory.
case "$TARGET" in
  *.app) DIR="$TARGET/Contents/MacOS" ;;
  *)     DIR="$TARGET" ;;
esac
DIR=$(cd "$DIR" && pwd)

BIN=""
for f in "$DIR"/*; do
  [ -f "$f" ] && [ -x "$f" ] || continue
  case "$(basename "$f")" in hyperion-view*|*.dylib) continue ;; esac
  BIN=$(basename "$f"); break
done
[ -n "$BIN" ] || { echo "verify-bundle-macos: no application binary in $DIR" >&2; exit 2; }

CARRIED=$(ls "$DIR" | grep '\.dylib$' || true)

echo "verify-bundle-macos: $BIN"
echo "verify-bundle-macos: dir      = $DIR"
echo "verify-bundle-macos: carried  = $(echo "$CARRIED" | tr '\n' ' ')"
echo

FAILED=0

# --- check 1: no build-machine paths survive in the load commands ----------------------
# The bug ADR-0014 exists for. A path under /opt/homebrew, /usr/local or the source tree is
# a machine-specific dependency that will not exist on a user's Mac.
echo "--- check 1: load commands name no build-machine paths ---"
LEAKED=$(otool -L "$DIR/$BIN" | tail -n +2 | awk '{print $1}' \
         | grep -vE '^/usr/lib/|^/System/|^@executable_path/|^@loader_path/|^@rpath/' || true)
if [ -n "$LEAKED" ]; then
  echo "  FAIL -- the image links absolute non-system paths:"
  echo "$LEAKED" | sed 's/^/         /'
  echo "         These exist on this machine and will not on a user's (ADR-0014)."
  FAILED=1
else
  echo "  ok -- every non-system load command is @executable_path-relative"
  otool -L "$DIR/$BIN" | tail -n +2 | awk '{print $1}' | grep -E '^@' | sed 's/^/         /' || true
fi

# --- check 2: run it, and confirm the libraries came from the bundle -------------------
echo
echo "--- check 2: the bundle runs, loading ITS OWN libraries ---"
LOG=$(mktemp)
if DYLD_PRINT_LIBRARIES=1 "$DIR/$BIN" "$@" >"$LOG" 2>&1; then
  echo "  ok -- exited 0"
else
  echo "  FAIL -- the bundle did not run:"
  head -10 "$LOG" | sed 's/^/         /'
  FAILED=1
fi

# THE INSTRUMENT CAN BE DISARMED FROM OUTSIDE THIS SCRIPT, SO IT HAS TO NOTICE (#98).
#
# This whole check rests on DYLD_PRINT_LIBRARIES reaching dyld. THE HARDENED RUNTIME STRIPS
# EVERY DYLD_* VARIABLE. So the day someone signs this app with `codesign --options runtime'
# -- which ADR-0010's M2 requires, and which is a change made in a completely different file
# -- dyld prints nothing, $LOG holds no loader lines, and every library below falls to the
# `note -- never loaded on this run (may need different app arguments)' branch.
#
# That branch does not set FAILED. So the script prints a tidy list of notes, exits 0, and
# has verified NOTHING ABOUT WHERE ANY LIBRARY CAME FROM. It does not fail -- it stops
# observing, which is worse, because a FAIL gets investigated and a pass gets believed.
#
# Absent and passing are identical at the exit code. The only difference here is that the
# transition is a config change somewhere else entirely, made by someone who has no reason
# to read this file. Hence: assert the instrument produced output BEFORE trusting its
# silence. If you are here because this fired, the fix is not to delete this check -- it is
# that a hardened bundle needs a different instrument (`dyld_info', or a signed-and-notarised
# run under `DYLD_PRINT_LIBRARIES' with `com.apple.security.cs.disable-library-validation'
# on a debug build), because the property still needs verifying and has become harder to see.
if ! grep -q "dyld" "$LOG"; then
  echo "  FAIL -- DYLD_PRINT_LIBRARIES produced no loader output at all."
  echo "         This check is now blind: it cannot see where any library was loaded from,"
  echo "         and every line below would read 'never loaded' rather than failing."
  echo "         Most likely cause: the bundle is signed with the HARDENED RUNTIME, which"
  echo "         strips DYLD_* (#98). See the note above this check for what to do."
  FAILED=1
fi

# Every carried .dylib must have been loaded FROM THE BUNDLE. This is the check that a bare
# exit code cannot make: without it a pass may mean the app silently used Homebrew's copy.
for lib in $CARRIED; do
  if grep -q "$DIR/$lib" "$LOG"; then
    echo "  ok -- $lib loaded from the bundle"
  elif grep -q "$lib" "$LOG"; then
    echo "  FAIL -- $lib was loaded from OUTSIDE the bundle:"
    grep "$lib" "$LOG" | grep dyld | head -2 | sed 's/^/         /'
    FAILED=1
  else
    echo "  note -- $lib was never loaded on this run (may need different app arguments)"
  fi
done

# --- check 3: the control, for linked libraries only -----------------------------------
# Decisive on any machine: @executable_path has no fallback. Skipped for dlopen'd libraries,
# where a dev machine's source tree or Homebrew would mask the result and a green would mean
# nothing -- check 2 is what covers those.
echo
echo "--- check 3: removing a LINKED library must break the app ---"
LINKED=$(otool -L "$DIR/$BIN" | tail -n +2 | awk '{print $1}' \
         | grep '^@executable_path/' | sed 's|^@executable_path/||' || true)
if [ -z "$LINKED" ]; then
  echo "  (none -- this image links nothing but system libraries; nothing to control for)"
else
  # The control runs against a COPY in a plain temp directory -- never the real bundle, and
  # never inside a .app. Two reasons, both learned the hard way:
  #
  #   * A crash inside a .app is escalated by macOS CrashReporter into a GUI dialog
  #     ("uv-probe cannot be opened because of a problem"). A verification script must not
  #     put a dialog on someone's screen to report a result it expected. Outside a bundle
  #     the same abort is just a stderr line.
  #   * Deleting from the real bundle and moving the file back leaves the shipped artifact
  #     broken if the script is interrupted between the two.
  #
  # @executable_path follows the copy, so the property under test is unchanged.
  for lib in $LINKED; do
    [ -f "$DIR/$lib" ] || { echo "  FAIL -- $lib is in a load command but NOT in the bundle"; FAILED=1; continue; }
    CTRL=$(mktemp -d)
    cp "$DIR/$BIN" "$CTRL/" 2>/dev/null || true
    for d in $CARRIED; do [ "$d" = "$lib" ] || cp "$DIR/$d" "$CTRL/" 2>/dev/null || true; done
    # A nested shell absorbs the "Abort trap: 6" job message, which is the shell's, not the app's.
    if sh -c '"$0" "$@" >/dev/null 2>&1' "$CTRL/$BIN" "$@" 2>/dev/null; then
      echo "  FAIL -- the app still ran without $lib, so it is not really using the carried copy"
      FAILED=1
    else
      echo "  ok -- removing $lib breaks the app, as it must"
    fi
    rm -rf "$CTRL"
  done
fi

rm -f "$LOG"
echo
if [ "$FAILED" -eq 0 ]; then
  echo "verify-bundle-macos: PASS"
  echo "verify-bundle-macos: NOTE -- this proves the bundle uses its own libraries. It does"
  echo "verify-bundle-macos: NOT prove it runs on a Mac lacking them; for that, run the"
  echo "verify-bundle-macos: artifact on a runner that never built it (ADR-0013 point 6)."
  exit 0
else
  echo "verify-bundle-macos: FAIL" >&2
  exit 1
fi
