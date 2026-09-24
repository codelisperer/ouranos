#!/usr/bin/env sh
# verify-appimage-update.sh --- apply a real AppImage update on Linux, end to end (#251)
#
#   scripts/verify-appimage-update.sh OLD.AppImage NEW.AppImage [--control]
#
# The Linux counterpart of verify-appdata-survives.ps1 (#111). OLD and NEW are two real,
# different AppImages, such as the coalton-repl AppImage from two desktop-release dry runs.
#
#   1. "Install" OLD: copy it to a fresh directory, mode 755.
#   2. Create and populate a real ~/.<appname>.
#   3. Publish NEW as version 1.1.0: a key made for this run, a signed manifest and a signed
#      payload, written by scripts/update-manifest.lisp exactly as the release job does.
#   4. Run the real apply path (appimage-update-driver.lisp) with APPIMAGE naming the
#      installed file, as the AppImage runtime would.
#   5. Assert: the installed file IS the new AppImage (checked first, so nothing below can
#      pass vacuously); it is mode 755; the old one is kept as <file>.previous; no temporary
#      file is left beside it; the NEW AppImage started (its own output appears); and
#      ~/.<appname> is byte-identical, contents and modification times.
#
# --control: the driver leaves the installed file mode 644 after the apply. This harness
# must then FAIL, and the run exits 0 only if it did.
#
# Exit 0 on success, 1 on a finding, 2 if it could not run.

set -eu

die() { echo "verify-appimage-update: $*" >&2; exit 2; }

[ $# -ge 2 ] || die "usage: $0 OLD.AppImage NEW.AppImage [--control]"
OLD=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
NEW=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
CONTROL=no
[ "${3:-}" = "--control" ] && CONTROL=yes
[ -f "$OLD" ] && [ -f "$NEW" ] || die "OLD and NEW must both exist"
[ "$(sha256sum < "$OLD")" != "$(sha256sum < "$NEW")" ] || die "OLD and NEW are the same file; an update between them proves nothing"

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
export CL_SOURCE_REGISTRY="$ROOT//:"
command -v sbcl >/dev/null || die "sbcl is not on PATH"

APP="ouranos-appimage-probe-$$"
DATA="$HOME/.$APP"
WORK=$(mktemp -d)
INSTALLED="$WORK/install/$APP.AppImage"
PUB="$WORK/pub"
LOG="$WORK/driver.log"
FAILURES=0
fail() { echo "  FAILED  $*"; FAILURES=$((FAILURES + 1)); }
ok() { echo "  ok      $*"; }

cleanup() {
  pkill -f "$INSTALLED" 2>/dev/null || true
  rm -rf "$DATA" "$WORK"
}
trap cleanup EXIT

[ ! -e "$DATA" ] || die "$DATA already exists"

echo "verify-appimage-update (#251): old $(sha256sum < "$OLD" | cut -c1-12), new $(sha256sum < "$NEW" | cut -c1-12), control=$CONTROL"

# 1. the installation
mkdir -p "$WORK/install" "$PUB"
cp "$OLD" "$INSTALLED"
chmod 755 "$INSTALLED"

# 2. the data directory, and a snapshot of it: path, sha256 and modification time
mkdir -p "$DATA/exports" "$DATA/dist"
printf 'config_version = 3\ntheme = "dark"\n' > "$DATA/config.toml"
{ printf 'SQLite format 3\000'; head -c 496 /dev/zero; } > "$DATA/app.db"
printf 'named like build output on purpose\n' > "$DATA/cache.fasl"
printf 'id,amount\n1,42\n' > "$DATA/exports/2026-09-01.csv"
cp "$NEW" "$DATA/dist/$APP-1.1.0-x86_64.AppImage"      # named exactly like the payload
snapshot() { (cd "$DATA" && find . -type f -exec sh -c 'printf "%s %s %s\n" "$1" "$(sha256sum < "$1" | cut -c1-64)" "$(stat -c %Y "$1")"' _ {} \; | sort); }
BEFORE=$(snapshot)
echo "  data: $DATA, $(echo "$BEFORE" | wc -l) files"

# 3. the release: a key for this run, a signed manifest and payload
cp "$NEW" "$PUB/$APP-1.1.0-x86_64.AppImage"
KEYS=$(sbcl --script "$HERE/update-manifest.lisp" keygen)
PUBLIC=$(echo "$KEYS" | sed -n 's/^public[[:space:]]*(ships inside the bundle):[[:space:]]*//p')
OURANOS_SIGNING_KEY=$(echo "$KEYS" | sed -n '3p' | tr -d '[:space:]')
export OURANOS_SIGNING_KEY
[ -n "$PUBLIC" ] && [ -n "$OURANOS_SIGNING_KEY" ] || die "could not read the key pair from update-manifest.lisp keygen"
sbcl --script "$HERE/update-manifest.lisp" generate --dist "$PUB" --product "$APP" --version 1.1.0 \
  --base-url https://appimage-update.invalid/dist > /dev/null
unset OURANOS_SIGNING_KEY
grep -q '"format": *"appimage"' "$PUB/stable.json" || die "the manifest does not declare format appimage"

# 4. the real apply
set +e
APPIMAGE="$INSTALLED" sbcl --script "$HERE/appimage-update-driver.lisp" \
  --dist "$PUB" --product "$APP" --installed-version 1.0.0 --app-name "$APP" --public-key "$PUBLIC" \
  $( [ "$CONTROL" = yes ] && echo --control ) > "$LOG" 2>&1
CODE=$?
set -e
sed 's/^/  | /' "$LOG" | head -12
[ "$CODE" -eq 0 ] || fail "the driver exited $CODE"

# 5. what happened
if [ "$(sha256sum < "$INSTALLED")" = "$(sha256sum < "$NEW")" ]; then
  ok "the installed file is the new AppImage"
else
  fail "the update did not land: the installed file is not the new AppImage"
fi
MODE=$(stat -c %a "$INSTALLED")
[ "$MODE" = 755 ] && ok "mode 755" || fail "the installed AppImage is mode $MODE, not 755"
if [ -f "$INSTALLED.previous" ] && [ "$(sha256sum < "$INSTALLED.previous")" = "$(sha256sum < "$OLD")" ]; then
  ok "the old AppImage is kept as $APP.AppImage.previous"
else
  fail "the old AppImage was not kept as .previous"
fi
LEFT=$(find "$WORK/install" -name '*.update-*' | wc -l)
[ "$LEFT" -eq 0 ] && ok "no temporary file left beside it" || fail "$LEFT temporary file(s) left beside the AppImage"
# The new AppImage inherits the driver's output; its own first line is Hunchentoot's.
i=0; while [ $i -lt 60 ] && ! grep -q 'server is going to start' "$LOG"; do sleep 0.5; i=$((i + 1)); done
if grep -q 'server is going to start' "$LOG"; then
  ok "the new AppImage started: $(grep -m1 'Listening on' "$LOG" || grep -m1 'server is going to start' "$LOG")"
else
  fail "the new AppImage did not start within 30 s"
fi
AFTER=$(snapshot)
if [ "$BEFORE" = "$AFTER" ]; then
  ok "$DATA is byte-identical, contents and modification times"
else
  fail "the update touched $DATA:"
  echo "$BEFORE" > "$WORK/before.txt"; echo "$AFTER" > "$WORK/after.txt"
  diff "$WORK/before.txt" "$WORK/after.txt" | sed 's/^/          /' || true
fi

echo
if [ "$CONTROL" = yes ]; then
  if [ "$FAILURES" -gt 0 ]; then
    echo "CONTROL PASSED: the harness reported $FAILURES failure(s) for an apply that left the AppImage non-executable."
    exit 0
  fi
  echo "CONTROL FAILED: an AppImage left mode 644 was reported as a good update."
  exit 1
fi
[ "$FAILURES" -eq 0 ] && { echo "verify-appimage-update: PASS"; exit 0; }
echo "verify-appimage-update: FAIL ($FAILURES)"
exit 1
