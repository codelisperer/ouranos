#!/usr/bin/env sh
# build-dmg.sh --- package a macOS bundle as a .app inside a .dmg (#78), and the same .app
# as the updater's .app.tar.gz payload (#135).
#
#     scripts/build-dmg.sh dist/coalton-repl-0.1.0-macos-arm64 \
#         [--display-name "Coalton REPL"] \
#         [--icon hyperion/examples/coalton-repl/assets/lambda.png] [--out dist]
#
# Input is exactly what scripts/build-desktop-app.lisp produced -- the dumped image, the
# hyperion-view, the native libraries it carried (ADR-0013), the libraries the runtime
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
# WHAT THIS DOES NOT DO: sign or notarize. An unsigned .dmg raises Gatekeeper on another
# Mac -- the user gets "cannot be opened because the developer cannot be verified" and has
# to right-click > Open. Fixing that needs a paid Developer ID, `codesign --timestamp
# --options runtime` and `notarytool`; it is a distribution decision (ADR-0010), not a
# packaging one, and is deliberately not faked here. The ad-hoc signature applied to the
# image is what makes it RUN on Apple silicon, which is a different requirement.

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

# The app binary: the one executable that is neither the launcher nor a dylib. Same rule
# as verify-bundle.sh, spelled for BSD find (no -printf).
BIN=""
for f in "$BUNDLE_ABS"/*; do
  [ -f "$f" ] && [ -x "$f" ] || continue
  case "$(basename "$f")" in
    hyperion-view*|*.dylib) continue ;;
  esac
  BIN=$(basename "$f"); break
done
[ -n "$BIN" ] || { echo "build-dmg: no application binary found in $BUNDLE" >&2; exit 2; }

[ -n "$DISPLAY_NAME" ] || DISPLAY_NAME="$BIN"

APP="$OUT/$DISPLAY_NAME.app"
DMG="$OUT/$BIN-$VERSION-macos-$(uname -m).dmg"

echo "build-dmg: $BIN $VERSION -> $DISPLAY_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The whole bundle, verbatim -- see the header: Contents/MacOS IS the resolver's directory.
cp -R "$BUNDLE_ABS"/. "$APP/Contents/MacOS/"

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

# --- signing: deliberately NOT attempted, and this is the interesting part ---------------
#
# `codesign` REFUSES a dumped SBCL image -- "main executable failed strict validation" --
# for the same reason `install_name_tool` does: save-lisp-and-die appends the Lisp core
# past the end of the Mach-O, so the file is not a structurally valid Mach-O any more.
# That is why ADR-0014 patches the runtime BEFORE the dump rather than the image after it.
#
# Signing the .app bundle inherits the problem, because the bundle signature covers the
# main executable. So we do not attempt it, and remove any partial `_CodeSignature` a
# previous attempt left behind.
#
# What that does NOT buy us, measured rather than assumed: `spctl --assess` still reports
# "code has no resources but signature indicates they must be present". The cause is not the
# bundle signature but the one EMBEDDED in the image, inherited from the SBCL runtime and
# signed there as a standalone binary -- as a bundle's main executable it is now expected to
# be accompanied by a CodeResources file, and it cannot be re-signed to say otherwise.
# Verified: adding a real Resources payload (an .icns) does not change the verdict.
#
# That ad-hoc signature (`flags=0x2(adhoc)`) is also what lets the image execute on Apple
# silicon at all, so it cannot simply be stripped.
#
# CONSEQUENCE, recorded rather than papered over: Developer ID signing and notarization are
# BLOCKED for a dumped SBCL image by this same limitation, not merely unimplemented. Whoever
# takes that on (ADR-0010) needs a different artifact shape -- most likely runtime + core as
# separate files, where the runtime is an ordinary signable Mach-O -- which is a real
# trade against the single-binary property the updater relies on.
rm -rf "$APP/Contents/_CodeSignature"

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
# attribute it does not know about would still reach the installed app. COPYFILE_DISABLE and --no-mac-metadata stop
# the other macOS additions (AppleDouble `._' entries) for any tar that makes them.
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
cmp -s "$CHECK/$DISPLAY_NAME.app/Contents/MacOS/$BIN" "$BUNDLE_ABS/$BIN" || {
  echo "build-dmg: the $BIN inside $TGZ differs from the bundle's" >&2
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
hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "build-dmg: $DMG"
echo "build-dmg: $(du -h "$DMG" | cut -f1)"
echo
echo "build-dmg: NOT signed with a Developer ID and NOT notarized -- on another Mac"
echo "build-dmg: Gatekeeper will require right-click > Open. See ADR-0010."
