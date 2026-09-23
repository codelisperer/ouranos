#!/usr/bin/env bash
# Exercise the publish job's SHELL against a fixture, both directions.
#
# The dry run skips `publish' and `verify-published' entirely (tag-gated), so without this
# they stay unexecuted -- and an unrun job and a working job are identical at the exit code.
# The steps under test are the ones that make a claim about bytes: the VERIFIED.sha256
# check, and the APP_PLATFORMS coverage comparison.
#
# Each case asserts the step PASSES when it should and FAILS when it should. A guard only
# checked in the direction where it passes is not a guard.

set -u
# RESOLVED BY RUNNING ONE, not by `command -v'. Windows puts an App Execution Alias stub
# named python3 on PATH: it resolves, prints "Python was not found" and exits nonzero.
# With `command -v' that stub was selected, every guard below failed for want of an
# interpreter, and four of them reported "fail, as expected" -- the check passed while
# testing nothing. The fixture has to be able to SUCCEED before its failures mean anything.
PY=""
for cand in python3 python py; do
  if "$cand" -c 'print("ok")' >/dev/null 2>&1; then PY=$cand; break; fi
done
[ -n "$PY" ] || { echo 'no working python interpreter'; exit 2; }
printf 'interpreter: %s (%s)
' "$PY" "$("$PY" --version 2>&1)"
ROOT=$(mktemp -d)
FAILURES=0

APP_NAME=coalton-repl
APP_CHANNEL=stable
APP_VERSION=0.1.0

say() { printf '\n=== %s\n' "$1"; }
ok()  { printf '  ok  %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# expect <want-exit: pass|fail> <label> <command...>
expect() {
  local want=$1 label=$2; shift 2
  if "$@" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [ "$got" = "$want" ]; then ok "$label ($got, as expected)"; else bad "$label (got $got, wanted $want)"; fi
}

# --- the fixture: a dist/ shaped like the one the publish job reassembles ------
make_dist() {
  local d=$1 platforms=$2
  rm -rf "$d"; mkdir -p "$d"
  ( cd "$d"
    printf 'fake nsis installer\n'   > "${APP_NAME}-${APP_VERSION}-setup.exe"
    printf 'fake appimage\n'         > "${APP_NAME}-${APP_VERSION}-x86_64.AppImage"
    printf 'sig-a\n'                 > "${APP_NAME}-${APP_VERSION}-setup.exe.sig"
    printf 'sig-b\n'                 > "${APP_NAME}-${APP_VERSION}-x86_64.AppImage.sig"
    "$PY" - "$platforms" <<'PYX' > "${APP_CHANNEL}.json"
import json, sys
keys = sys.argv[1].split()
print(json.dumps({"schema": 1, "product": "coalton-repl", "channel": "stable",
                  "version": "0.1.0",
                  "platforms": {k: {"format": "nsis", "payload": {}} for k in keys}},
                 indent=2))
PYX
    printf 'manifest-sig\n' > "${APP_CHANNEL}.json.sig"
    # VERIFIED.sha256 as the gate writes it: the manifest, its .sig, and each payload+sig.
    sha256sum "${APP_CHANNEL}.json" "${APP_CHANNEL}.json.sig" \
              "${APP_NAME}-${APP_VERSION}-setup.exe" "${APP_NAME}-${APP_VERSION}-setup.exe.sig" \
              "${APP_NAME}-${APP_VERSION}-x86_64.AppImage" \
              "${APP_NAME}-${APP_VERSION}-x86_64.AppImage.sig" > VERIFIED.sha256
  )
}

# --- STEP: the bytes about to be uploaded are the bytes that passed the gate ---
step_verified() (
  cd "$1" || exit 2
  test -f VERIFIED.sha256 || exit 1
  sha256sum -c VERIFIED.sha256
)

# --- STEP: the manifest carries exactly the platforms this release declares ----
step_platforms() (
  local d=$1; local APP_PLATFORMS=$2
  # cd + a RELATIVE path, because the interpreter here is native Windows Python and
  # cannot resolve a git-bash /tmp/... path. The runner passes dist/stable.json, which
  # is relative already -- so this is the fixture matching reality, not diverging from it.
  cd "$d" || exit 2
  got=$("$PY" -c "import json;print(' '.join(sorted(json.load(open('${APP_CHANNEL}.json'))['platforms'])))")
  want=$(printf '%s\n' ${APP_PLATFORMS} | sort | tr '\n' ' ' | sed 's/ *$//')
  [ "$got" = "$want" ]
)

say "VERIFIED.sha256 -- the control is a file that changed after the gate ran"
make_dist "$ROOT/d1" "linux-x86-64 windows-x86-64"
expect pass "intact dist passes" step_verified "$ROOT/d1"

make_dist "$ROOT/d2" "linux-x86-64 windows-x86-64"
printf 'AUTHENTICODE REWROTE ME\n' >> "$ROOT/d2/${APP_NAME}-${APP_VERSION}-setup.exe"
expect fail "an installer mutated after the gate is caught" step_verified "$ROOT/d2"

make_dist "$ROOT/d3" "linux-x86-64 windows-x86-64"
rm "$ROOT/d3/${APP_NAME}-${APP_VERSION}-x86_64.AppImage"
expect fail "an installer lost in reassembly is caught" step_verified "$ROOT/d3"

make_dist "$ROOT/d4" "linux-x86-64 windows-x86-64"
printf 'tampered\n' > "$ROOT/d4/${APP_CHANNEL}.json.sig"
expect fail "the manifest signature is pinned too" step_verified "$ROOT/d4"

make_dist "$ROOT/d5" "linux-x86-64 windows-x86-64"
rm "$ROOT/d5/VERIFIED.sha256"
expect fail "no VERIFIED.sha256 means the gate did not pass" step_verified "$ROOT/d5"

say "APP_PLATFORMS -- declared coverage, checked both directions"
make_dist "$ROOT/p1" "linux-x86-64 windows-x86-64"
expect pass "manifest matches the declaration" step_platforms "$ROOT/p1" "linux-x86-64 windows-x86-64"
expect pass "declaration order does not matter" step_platforms "$ROOT/p1" "windows-x86-64 linux-x86-64"

make_dist "$ROOT/p2" "linux-x86-64"
expect fail "a platform that silently stopped building is caught" step_platforms "$ROOT/p2" "linux-x86-64 windows-x86-64"

make_dist "$ROOT/p3" "linux-x86-64 windows-x86-64 macos-arm64"
expect fail "an UNDECLARED platform is caught too" step_platforms "$ROOT/p3" "linux-x86-64 windows-x86-64"

say "the upload argument lists"
make_dist "$ROOT/u1" "linux-x86-64 windows-x86-64"
payloads=$(cd "$ROOT/u1/.." && find u1 -maxdepth 1 -type f \( -name '*setup.exe' -o -name '*.AppImage' -o -name '*.app.tar.gz' \) | sort | tr '\n' ' ')
sigs=$(cd "$ROOT/u1/.." && find u1 -maxdepth 1 -type f -name '*.sig' ! -name "${APP_CHANNEL}.json.sig" | sort | tr '\n' ' ')
printf '  versioned release payloads: %s\n' "$payloads"
printf '  versioned release sigs    : %s\n' "$sigs"
case "$sigs" in
  *stable.json.sig*) bad "the channel manifest sig leaked into the versioned release" ;;
  *) ok "the channel manifest sig is excluded from the versioned release" ;;
esac
case "$payloads" in
  *setup.exe*AppImage*|*AppImage*setup.exe*) ok "both payloads are listed" ;;
  *) bad "a payload is missing from the upload list" ;;
esac

printf '\n%s\n' "-----------------------------------------"
if [ "$FAILURES" -eq 0 ]; then printf 'ALL PASS\n'; else printf '%d FAILURES\n' "$FAILURES"; fi
rm -rf "$ROOT"
exit $((FAILURES > 0))
