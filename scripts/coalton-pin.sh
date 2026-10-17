#!/usr/bin/env bash
#
# scripts/coalton-pin.sh -- check that the Coalton checkout is at the commit coalton.pin names.
#
# The framework setup scripts (aion, elenchon, hyperion, mnemosyne and praxeon
# scripts/setup.sh) run this instead of cloning Coalton themselves (#733, #751). It changes
# nothing. scripts/setup.sh is the only script that clones Coalton and checks out the pinned
# commit, so that is done in one place.
#
# Exits 0 when the checkout at $COALTON_DIR (default ~/common-lisp/coalton) is at the pinned
# commit. Otherwise prints what it found and says to run scripts/setup.sh, and exits 1. Warns,
# without failing, when the checkout's origin differs from the pin's repo line, as
# scripts/setup.sh does.
#
# Usage:  bash scripts/coalton-pin.sh

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pin="$root/coalton.pin"
fix="Run scripts/setup.sh at the monorepo root ($root), which checks out the pinned commit."

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

ref=$(awk '/^sha[[:space:]]/ {print $2; exit}' "$pin" 2>/dev/null || true)
[ -n "$ref" ] || fail "no 'sha' line in $pin."
repo=$(awk '/^repo[[:space:]]/ {print $2; exit}' "$pin" 2>/dev/null || true)
[ -n "$repo" ] || repo="https://github.com/coalton-lang/coalton"
dir="${COALTON_DIR:-$HOME/common-lisp/coalton}"

[ -d "$dir/.git" ] || fail "Coalton is not checked out at $dir. $fix"

origin=$(git -C "$dir" remote get-url origin 2>/dev/null || echo "")
if [ -n "$origin" ] && [ "$origin" != "$repo" ]; then
  printf 'warning: %s tracks %s but coalton.pin declares %s\n' "$dir" "$origin" "$repo" >&2
fi

# coalton.pin carries a short sha, so compare resolved commit ids.
current=$(git -C "$dir" rev-parse --verify --quiet "HEAD^{commit}" 2>/dev/null || echo "")
want=$(git -C "$dir" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null || echo "")
if [ -z "$want" ] || [ "$current" != "$want" ]; then
  shown="${current:0:8}"
  [ -n "$shown" ] || shown="no commit"
  fail "Coalton at $dir is at $shown, but coalton.pin names $ref. $fix"
fi
printf '==> Coalton at %s is at the pinned %s.\n' "$dir" "$ref"
