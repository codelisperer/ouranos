#!/usr/bin/env sh
# build-dmg.sh --- package a macOS bundle as a .app inside a .dmg (#78), and the same .app
# as the updater's .app.tar.gz payload (#135).
#
#     scripts/build-dmg.sh dist/coalton-repl-0.1.0-macos-arm64 \
#         [--display-name "Coalton REPL"] \
#         [--icon hyperion/examples/coalton-repl/assets/lambda.png] [--out dist]
#
# Input is exactly what scripts/build-desktop-app.lisp produced -- the launcher, the SBCL
# runtime and the app's core (sbcl.core; #98, #332), the hyperion-view, the native libraries it carried (ADR-0013), the libraries the runtime
# links (ADR-0014), VERSION and LICENSES. Output is the thing a Mac user expects: a disk
# image they open, containing an app they drag to Applications.
#
# WHY THE BUNDLE DIRECTORY MAPS ONTO Contents/MacOS/ UNCHANGED. Both resolution mechanisms
# this tree relies on are directory-relative to the executable:
#
#   * dlopen'd libraries (libuv) -- found by hyperion/desktop:image-directory /
#     aion/uv's search, i.e. beside the running image (ADR-0013);
#   * linked libraries (libzstd) -- found via @executable_path, rewritten into the image
#     at build time (ADR-0014);
#   * the hyperion-view -- found beside the image (default-launcher).
#
# All three mean "the directory the executable is in", and in a .app that directory is
# Contents/MacOS/. So packaging is a copy, not a re-layout, and there is nothing here that
# can disagree with the resolver. A `lib/` subdirectory would have broken all three.
#
# SIGNING: AD HOC, NOT DEVELOPER ID. The .app is signed with `codesign --force --deep -s -`
# and the build fails unless `codesign --verify --deep --strict` passes, on the .app and on
# the update payload unpacked. On another Mac a downloaded copy then gets the ordinary
# "Not Opened ... Apple could not verify" prompt; after Done, System Settings > Privacy &
# Security offers Open Anyway, which needs no terminal (measured on macOS 26.6.2, #332).
# Before the app was split into launcher, runtime and core, it could not be signed at all,
# and the same download was reported as damaged, with no Open Anyway. A Developer ID
# signature and notarization (`codesign --timestamp --options runtime`, `notarytool`) remain
# a distribution decision (ADR-0010) and are not done here.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)

OUT="$ROOT/dist"
ICON=""
DISPLAY_NAME=""
BUNDLE=""

usage() {
  echo "usage: scripts/build-dmg.sh <bundle-dir> [--display-name NAME] [--icon PNG] [--out DIR]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --display-name) DISPLAY_NAME="$2"; shift 2 ;;
    --icon)         ICON="$2";         shift 2 ;;
    --out)          OUT="$2";          shift 2 ;;
    -h|--help)      usage ;;
    -*)             echo "build-dmg: unknown option $1" >&2; usage ;;
    *)              BUNDLE="$1";       shift ;;
  esac
done

[ -n "$BUNDLE" ] || usage
[ -d "$BUNDLE" ] || { echo "build-dmg: no such bundle directory: $BUNDLE" >&2; exit 2; }
[ "$(uname -s)" = "Darwin" ] || { echo "build-dmg: macOS only (hdiutil)" >&2; exit 2; }

BUNDLE_ABS=$(cd "$BUNDLE" && pwd)
VERSION=$(cat "$BUNDLE_ABS/VERSION" 2>/dev/null || echo "0.0.0")

# The app binary: the one executable that is not the window process (hyperion-view), the
# SBCL runtime (sbcl) or a dylib. Same rule as verify-bundle-macos.sh.
BIN=""
for f in "$BUNDLE_ABS"/*; do
  [ -f "$f" ] && [ -x "$f" ] || continue
  case "$(basename "$f")" in
    hyperion-view*|sbcl|*.dylib) continue ;;
  esac
  BIN=$(basename "$f"); break
done
[ -n "$BIN" ] || { echo "build-dmg: no application binary found in $BUNDLE" >&2; exit 2; }

# A bundle from before the split has the dumped image as $BIN and no core beside it. codesign
# cannot sign that, so it is refused here with the reason, rather than failing below.
for f in sbcl sbcl.core; do
  [ -f "$BUNDLE_ABS/$f" ] || {
    echo "build-dmg: $BUNDLE has no $f. It was built before macOS apps were split into a" >&2
    echo "build-dmg: launcher, the runtime and sbcl.core (#98); rebuild it with this tree's" >&2
    echo "build-dmg: scripts/build-desktop-app.lisp." >&2
    exit 2
  }
done

[ -n "$DISPLAY_NAME" ] || DISPLAY_NAME="$BIN"

APP="$OUT/$DISPLAY_NAME.app"
DMG="$OUT/$BIN-$VERSION-macos-$(uname -m).dmg"

echo "build-dmg: $BIN $VERSION -> $DISPLAY_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The whole bundle, verbatim -- see the header: Contents/MacOS IS the resolver's directory.
cp -R "$BUNDLE_ABS"/. "$APP/Contents/MacOS/"

# ONLY CODE STAYS IN Contents/MacOS; everything else moves to Contents/Resources, with a
# relative symlink left under its old name (#98). codesign treats every file in
# Contents/MacOS as code, and signs one that is not a Mach-O -- sbcl.core, VERSION, the
# licence texts -- by writing extended attributes on it. The update payload is made with
# `tar --no-xattrs` (below), so those signatures were lost: measured, the unpacked payload
# failed `codesign --verify --deep --strict` with "code object is not signed at all" on
# LICENSES/libzstd.1-COPYING while the .app itself verified. Resources are sealed in
# CodeResources instead, which travels. A symlink in Contents/MacOS is followed and sealed
# (ADR-0014), so everything that looks beside the executable still finds these files.
for f in "$APP/Contents/MacOS"/* "$APP/Contents/MacOS"/.[!.]*; do
  [ -e "$f" ] || continue
  if [ -f "$f" ] && file -b "$f" | grep -q 'Mach-O'; then continue; fi
  name=$(basename "$f")
  mv "$f" "$APP/Contents/Resources/$name"
  ln -s "../Resources/$name" "$APP/Contents/MacOS/$name"
done

# --- the icon -----------------------------------------------------------------------
# .icns is generated from the PNG with sips + iconutil, both first-party. No icon is not
# an error: the app gets the generic one.
ICON_NAME=""
if [ -n "$ICON" ] && [ -f "$ICON" ]; then
  ICONSET=$(mktemp -d)/icon.iconset
  mkdir -p "$ICONSET"
  for sz in 16 32 128 256 512; do
    sips -z $sz $sz "$ICON" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null 2>&1 || true
    dbl=$((sz * 2))
    sips -z $dbl $dbl "$ICON" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1 || true
  done
  if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/$BIN.icns" 2>/dev/null; then
    ICON_NAME="$BIN"
    echo "build-dmg: icon    -> Resources/$BIN.icns"
  else
    echo "build-dmg: WARNING -- iconutil failed; shipping without an icon" >&2
  fi
fi

# --- Info.plist ------------------------------------------------------------------------
# LSMinimumSystemVersion is a claim we should not invent: 11.0 is the floor for Apple
# silicon, which is the only arch we build here.
# NSHighResolutionCapable matters for a webview app -- without it the window renders
# upscaled and blurry on a Retina display.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>       <string>$DISPLAY_NAME</string>
  <key>CFBundleExecutable</key>        <string>$BIN</string>
  <key>CFBundleIdentifier</key>        <string>dev.codelisperer.$BIN</string>
  <key>CFBundleVersion</key>           <string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>LSMinimumSystemVersion</key>    <string>11.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
$( [ -n "$ICON_NAME" ] && printf '  <key>CFBundleIconFile</key>          <string>%s</string>\n' "$ICON_NAME" )
</dict>
</plist>
PLIST

# --- signing (#98, #332) ----------------------------------------------------------------
# Ad hoc, over the whole .app: --deep signs every Mach-O inside it (the launcher, the runtime,
# hyperion-view, each dylib) and seals the rest, sbcl.core included, as resources. Then the
# strict check that Gatekeeper's assessment rests on. Before the split, the main executable
# was a dumped image, which codesign cannot sign, and this check could not pass.
codesign --force --deep -s - "$APP"
codesign --verify --deep --strict "$APP" || {
  echo "build-dmg: $APP does not verify after signing (codesign --verify --deep --strict)" >&2
  exit 1
}
echo "build-dmg: signed ad hoc, verifies: $APP"

# --- the update payload (#135) ---------------------------------------------------------
# scripts/update-manifest.lisp lists macOS as format `app-targz', file
# <name>-<version>-macos-arm64.app.tar.gz. The client unpacks it beside the installed .app
# and swaps the whole bundle (hyperion/docs/desktop-distribution-design.md, "macOS --
# app-targz"), so the archive holds exactly one entry at its root: the .app built above.
# The .dmg below packs the same .app, so the human download and the update payload are two
# packagings of one bundle, not two builds.
#
# --no-xattrs keeps the build machine's extended attributes out of the payload. Without it,
# macOS tar (bsdtar 3.5.3) stores every file's attributes as pax headers and restores them
# on unpack: measured, a plain archive of this .app unpacked with com.apple.provenance on
# every file plus any attribute set on the build machine, where --no-xattrs unpacked with
# none. The design has the client strip the quarantine attribute after unpacking; an
# attribute it does not know about would still reach the installed app. COPYFILE_DISABLE
# and --no-mac-metadata stop the other macOS additions (AppleDouble `._' entries) for any
# tar that makes them.
TGZ="$OUT/$BIN-$VERSION-macos-$(uname -m).app.tar.gz"
rm -f "$TGZ"
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -C "$OUT" -czf "$TGZ" "$DISPLAY_NAME.app"

# The archive has to unpack to a .app the client can use. Checked here, where it is made,
# rather than first on a user's machine.
roots=$(tar -tzf "$TGZ" | cut -d/ -f1 | sort -u)
[ "$roots" = "$DISPLAY_NAME.app" ] || {
  echo "build-dmg: $TGZ has root entries other than $DISPLAY_NAME.app:" >&2
  echo "$roots" >&2
  exit 1
}
if tar -tzf "$TGZ" | grep -q '/\._'; then
  echo "build-dmg: $TGZ contains AppleDouble (._) files" >&2
  exit 1
fi
if gzip -dc "$TGZ" | grep -a -q 'SCHILY\.xattr\.'; then
  echo "build-dmg: $TGZ carries extended attributes from this machine" >&2
  exit 1
fi
CHECK=$(mktemp -d)
tar -xzf "$TGZ" -C "$CHECK"
[ -x "$CHECK/$DISPLAY_NAME.app/Contents/MacOS/$BIN" ] || {
  echo "build-dmg: $TGZ does not unpack to an executable Contents/MacOS/$BIN" >&2
  exit 1
}
# Compared with the signed .app, not the input bundle: signing rewrote $BIN's signature.
cmp -s "$CHECK/$DISPLAY_NAME.app/Contents/MacOS/$BIN" "$APP/Contents/MacOS/$BIN" || {
  echo "build-dmg: the $BIN inside $TGZ differs from the signed .app's" >&2
  exit 1
}
codesign --verify --deep --strict "$CHECK/$DISPLAY_NAME.app" || {
  echo "build-dmg: the .app unpacked from $TGZ does not verify (codesign --verify --deep --strict)" >&2
  exit 1
}
rm -rf "$CHECK"
echo "build-dmg: $TGZ"

# --- the disk image ----------------------------------------------------------------------
# A staging directory with the .app and a symlink to /Applications is the conventional
# drag-to-install layout, and costs nothing.
STAGE=$(mktemp -d)/dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$OUT"
rm -f "$DMG"
# -size is explicit. The first run of this script on the GitHub macos-14 runner failed with
# "create failed - No space left on device" (desktop-release run 35933536980). Without
# -size, hdiutil sizes the image itself from -srcfolder, and too small an estimate is one
# cause of that error; a full disk is the other. The size given is a quarter over the
# staged size, plus 20 MB for the filesystem's own structures. If creation still fails, the
# free space is printed, so that a full disk shows up as one.
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) * 5 / 4 + 20 ))
hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$STAGE" -size "${SIZE_MB}m" \
  -ov -format UDZO "$DMG" >/dev/null || {
  echo "build-dmg: hdiutil create failed for a ${SIZE_MB} MB image; free space:" >&2
  df -h "$OUT" "$STAGE" >&2
  exit 1
}

echo "build-dmg: $DMG"
echo "build-dmg: $(du -h "$DMG" | cut -f1)"
echo
echo "build-dmg: signed ad hoc, NOT with a Developer ID, and NOT notarized. On another Mac:"
echo "build-dmg: open it, click Done, then System Settings > Privacy & Security > Open Anyway."
