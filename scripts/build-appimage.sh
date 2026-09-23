#!/usr/bin/env sh
# build-appimage.sh --- package a Linux bundle as a single-file .AppImage (#72).
#
#     scripts/build-appimage.sh dist/coalton-repl-0.1.0-linux-x86-64 \
#         [--icon hyperion/examples/coalton-repl/assets/lambda.png] [--out dist]
#
# Input is exactly what scripts/build-desktop-app.lisp produced -- the dumped image, the
# hyperion-view, the native libraries it carried (ADR-0013), VERSION and LICENSES.
# Output is one executable file the user downloads, chmod +x, and runs. That single-file
# shape is also the simplest self-update payload we have (ADR-0010): replace and re-exec.
#
# WHAT THIS DOES NOT DO: bundle WebKitGTK. The hyperion-view links the system GTK/WebKit
# stack, and pulling that into an AppImage is a different and much larger job (a full
# linuxdeploy-style dependency walk, plus the LGPL relink question ADR-0013 keeps out of the
# image). This packages what we build and carry; the GTK question is #78's remaining row and
# is not silently claimed here.
#
# AppRun is a two-liner because of ADR-0013: the app finds its own libraries beside itself,
# so there is no LD_LIBRARY_PATH to set and no shim behaviour to get wrong. Had we chosen
# the wrapper-script approach, this is the file that would have carried that cost.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/versions.env"

ICON=""
OUT="$ROOT/dist"
BUNDLE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --icon) ICON="$2"; shift 2 ;;
    --out)  OUT="$2";  shift 2 ;;
    -h|--help)
      echo "usage: scripts/build-appimage.sh <bundle-dir> [--icon <png>] [--out <dir>]"; exit 0 ;;
    *) BUNDLE="$1"; shift ;;
  esac
done

[ -n "$BUNDLE" ] || { echo "build-appimage: a bundle directory is required" >&2; exit 2; }
[ -d "$BUNDLE" ] || { echo "build-appimage: no such directory: $BUNDLE" >&2; exit 2; }
BUNDLE=$(cd "$BUNDLE" && pwd)

# --- what we are packaging -----------------------------------------------------------
# The VERSION file rather than the directory name: `coalton-repl-0.0.0-dev-linux-x86-64`
# cannot be split back into name and version by a rule that also survives a version like
# 0.0.0-dev. The bundle already states its own version; ask it.
VERSION=$(cat "$BUNDLE/VERSION" 2>/dev/null || echo "0.0.0")
BIN=$(find "$BUNDLE" -maxdepth 1 -type f -perm -u+x \
        ! -name 'hyperion-view*' ! -name '*.so' ! -name '*.so.*' -printf '%f\n' | head -1)
[ -n "$BIN" ] || { echo "build-appimage: no application binary in $BUNDLE" >&2; exit 2; }

echo "build-appimage: $BIN $VERSION  <- $BUNDLE"

# --- appimagetool, pinned and verified -------------------------------------------------
TOOLDIR="$ROOT/vendor/appimagetool"
TOOL="$TOOLDIR/appimagetool-$APPIMAGETOOL_VERSION-x86_64.AppImage"
if [ ! -f "$TOOL" ]; then
  mkdir -p "$TOOLDIR"
  URL="https://github.com/AppImage/appimagetool/releases/download/$APPIMAGETOOL_VERSION/appimagetool-x86_64.AppImage"
  echo "build-appimage: fetching appimagetool $APPIMAGETOOL_VERSION"
  curl -sSL -o "$TOOL.part" "$URL"
  GOT=$(sha256sum "$TOOL.part" | cut -d' ' -f1)
  if [ "$GOT" != "$APPIMAGETOOL_SHA256" ]; then
    rm -f "$TOOL.part"
    echo "build-appimage: checksum MISMATCH for appimagetool $APPIMAGETOOL_VERSION" >&2
    echo "  expected $APPIMAGETOOL_SHA256" >&2
    echo "  got      $GOT" >&2
    echo "  (scripts/versions.env is the pin; a mismatch means the artifact changed)" >&2
    exit 1
  fi
  mv "$TOOL.part" "$TOOL"
  chmod +x "$TOOL"
fi

# --- the AppDir -------------------------------------------------------------------------
APPDIR=$(mktemp -d)
trap 'rm -rf "$APPDIR"' EXIT
APPDIR="$APPDIR/$BIN.AppDir"
mkdir -p "$APPDIR/usr/bin"

cp -a "$BUNDLE/." "$APPDIR/usr/bin/"

# AppRun: resolve our own directory and exec the image. `readlink -f` because AppRun is
# invoked through the mount point, and the app must be exec'd (not forked) so that signals,
# the exit status and the process the updater watches are the app's own.
cat > "$APPDIR/AppRun" <<APPRUN
#!/bin/sh
HERE=\$(dirname "\$(readlink -f "\$0")")
exec "\$HERE/usr/bin/$BIN" "\$@"
APPRUN
chmod +x "$APPDIR/AppRun"

cat > "$APPDIR/$BIN.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=$BIN
Exec=$BIN
Icon=$BIN
Categories=Development;
Terminal=false
DESKTOP

if [ -n "$ICON" ] && [ -f "$ICON" ]; then
  cp "$ICON" "$APPDIR/$BIN.png"
else
  # A 1x1 transparent PNG. appimagetool requires an icon to exist; shipping a real one is
  # a per-app asset decision (#72 "icons per platform"), so the placeholder is LOUD rather
  # than quietly passing for artwork.
  printf '%s' \
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==' \
    | base64 -d > "$APPDIR/$BIN.png"
  echo "build-appimage: NOTE -- no --icon given, shipping a placeholder (see #72)"
fi
cp "$APPDIR/$BIN.png" "$APPDIR/.DirIcon"

# --- package ----------------------------------------------------------------------------
mkdir -p "$OUT"
TARGET="$OUT/$BIN-$VERSION-x86_64.AppImage"

# APPIMAGE_EXTRACT_AND_RUN: appimagetool is itself an AppImage, and mounting one needs FUSE
# -- which a container and a CI runner routinely lack. Extracting instead costs a second and
# removes a dependency on the host's kernel modules.
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 "$TOOL" "$APPDIR" "$TARGET" >/dev/null 2>&1 || {
  echo "build-appimage: appimagetool failed; re-running with output" >&2
  APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 "$TOOL" "$APPDIR" "$TARGET"
  exit 1
}

chmod +x "$TARGET"
echo "build-appimage: $TARGET ($(du -h "$TARGET" | cut -f1))"
