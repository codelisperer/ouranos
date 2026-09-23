#!/usr/bin/env sh
# verify-bundle.sh --- run a dumped bundle on a machine that has never seen this repo.
#
#     scripts/verify-bundle.sh dist/uv-probe-0.0.0-linux-x86-64 [-- app args...]
#
# WHY THIS EXISTS: a native-dependency bug is INVISIBLE on the machine that built the
# artifact, because that machine has every library the build needed. That is not a
# hypothetical -- it is exactly how the first Linux bundle shipped and died on a user's box
# with `Error opening shared object "libev.so.4"` (ADR-0011, #72, #78). So the acceptance
# test for ADR-0013 is not "it runs here"; it is "it runs THERE": a container with no
# toolchain, no source tree, no Quicklisp, and no copy of the library we claim to carry.
#
# The bundle is mounted READ-ONLY, so the run cannot repair itself, and nothing but the
# bundle is mounted, so nothing on this machine can be reached by accident.
#
# TWO RUNS, and the second is the one that makes the first mean anything:
#
#   1. the bundle as shipped               -- must PASS
#   2. the same bundle, carried .so deleted -- must FAIL
#
# Without (2), a green (1) is unfalsifiable: if the container happened to ship the library,
# the bundle would pass while carrying nothing, and the test would be measuring the
# container. (2) proves the library the app loaded was OURS.
#
# THE IMAGE FLOOR: glibc is forward- but not backward-compatible, so the clean room must be
# at least as new as the machine that built the bundle. Default is ubuntu:26.04; override
# with OURANOS_CLEANROOM_IMAGE for an older floor once we build on an older base (the same
# constraint .github/workflows/desktop-release.yml already documents for the runner).
#
# Linux only, deliberately: this is the Linux half of #78. macOS and Windows need their own
# clean room (a fresh VM, or a runner with nothing installed) -- the DESIGN they share is
# ADR-0013, not this script.

set -eu

IMAGE="${OURANOS_CLEANROOM_IMAGE:-ubuntu:26.04}"

usage() {
  echo "usage: scripts/verify-bundle.sh <bundle-dir|app.AppImage> [-- app args...]" >&2
  exit 2
}

[ $# -ge 1 ] || usage
BUNDLE="$1"
shift
[ "${1:-}" = "--" ] && shift

command -v docker >/dev/null 2>&1 || {
  echo "verify-bundle: docker is required -- it IS the clean machine here." >&2; exit 2; }

# --- an .AppImage: the file a user actually downloads --------------------------------
# Worth testing separately from the directory it was made from. The AppImage adds its own
# runtime, its own mount step and AppRun between the user and the image, and any of those
# can be the thing that breaks on a machine that is not this one.
if [ -f "$BUNDLE" ]; then
  case "$BUNDLE" in
    *.AppImage) ;;
    *) echo "verify-bundle: $BUNDLE is a file but not an .AppImage" >&2; exit 2 ;;
  esac
  APPIMAGE_ABS=$(cd "$(dirname "$BUNDLE")" && pwd)/$(basename "$BUNDLE")
  echo "verify-bundle: $(basename "$BUNDLE")"
  echo "verify-bundle: clean room = $IMAGE"
  echo
  echo "--- run 1: the AppImage as downloaded (must pass) ---"
  # APPIMAGE_EXTRACT_AND_RUN because a container has no FUSE; /tmp because extraction
  # writes beside the cwd and the AppImage is mounted read-only.
  if docker run --rm --network none -v "$APPIMAGE_ABS":/opt/app.AppImage:ro \
       -w /tmp -e APPIMAGE_EXTRACT_AND_RUN=1 "$IMAGE" /opt/app.AppImage "$@"; then
    echo "verify-bundle: PASS -- the AppImage runs on a machine that has never seen this repo."
    echo "verify-bundle: (the carried-library control run lives with the bundle directory,"
    echo "verify-bundle:  which is where a file can be deleted -- run it there too.)"
    exit 0
  else
    echo "verify-bundle: FAILED -- the AppImage does not run on a clean machine" >&2
    exit 1
  fi
fi

[ -d "$BUNDLE" ] || { echo "verify-bundle: no such bundle directory: $BUNDLE" >&2; exit 2; }

BUNDLE_ABS=$(cd "$BUNDLE" && pwd)

# The app binary: the one executable that is neither the launcher nor a shared library.
BIN=$(find "$BUNDLE_ABS" -maxdepth 1 -type f -perm -u+x \
        ! -name 'hyperion-view*' ! -name '*.so' ! -name '*.so.*' \
        -printf '%f\n' | head -1)
[ -n "$BIN" ] || { echo "verify-bundle: no application binary found in $BUNDLE" >&2; exit 2; }

CARRIED=$(find "$BUNDLE_ABS" -maxdepth 1 -type f \( -name '*.so' -o -name '*.so.*' \) \
            -printf '%f\n' | sort)

echo "verify-bundle: $BIN from $BUNDLE"
echo "verify-bundle: clean room = $IMAGE"
if [ -n "$CARRIED" ]; then
  echo "verify-bundle: carried    = $(echo "$CARRIED" | tr '\n' ' ')"
else
  echo "verify-bundle: carried    = (nothing -- this bundle claims no native dependencies)"
fi

run_in_clean_room() {
  # $1 = host directory to mount; the rest are app arguments.
  dir="$1"; shift
  docker run --rm --network none -v "$dir":/opt/app:ro "$IMAGE" "/opt/app/$BIN" "$@"
}

# --- what the clean room does NOT have ---------------------------------------------
echo
echo "--- the clean room, before we run anything ---"
docker run --rm "$IMAGE" sh -c '
  echo "glibc:  $(ldd --version | head -1)"
  echo "sbcl:   $(command -v sbcl || echo "(none -- good)")"
  echo "cc:     $(command -v cc || echo "(none -- good)")"
  printf "libuv:  "
  if ldconfig -p 2>/dev/null | grep -q libuv; then
    ldconfig -p | grep libuv
    echo "verify-bundle: WARNING -- this image HAS libuv; run 2 below is what saves the test"
  else
    echo "(none -- good)"
  fi'

# --- run 1: the bundle as shipped ---------------------------------------------------
echo
echo "--- run 1: the bundle as shipped (must pass) ---"
if run_in_clean_room "$BUNDLE_ABS" "$@"; then
  echo "verify-bundle: run 1 PASSED"
else
  echo "verify-bundle: run 1 FAILED -- the bundle does not run on a clean machine" >&2
  exit 1
fi

# --- run 2: the control -------------------------------------------------------------
if [ -z "$CARRIED" ]; then
  echo
  echo "verify-bundle: no carried libraries, so there is no control run to make."
  echo "verify-bundle: PASS (run 1 only -- this proves the image needs nothing, not that carrying works)"
  exit 0
fi

echo
echo "--- run 2: the same bundle with $(echo "$CARRIED" | tr '\n' ' ')removed (must fail) ---"
CONTROL=$(mktemp -d)
trap 'rm -rf "$CONTROL"' EXIT
cp -a "$BUNDLE_ABS/." "$CONTROL/"
for so in $CARRIED; do rm -f "$CONTROL/$so"; done

if run_in_clean_room "$CONTROL" "$@"; then
  echo "verify-bundle: run 2 PASSED, AND THAT IS THE FAILURE." >&2
  echo "verify-bundle: the app ran without the library we carried, so it resolved one from" >&2
  echo "verify-bundle: the clean room -- run 1 proved nothing about bundling." >&2
  exit 1
else
  echo "verify-bundle: run 2 failed as required -- run 1 used the carried library."
fi

echo
echo "verify-bundle: PASS -- $BIN runs on a machine that has never seen this repo,"
echo "verify-bundle:        using the libraries the bundle carried."
