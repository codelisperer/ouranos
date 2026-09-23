#!/usr/bin/env bash
#
# INTERIM -- superseded by `bin/cons` once build/test/serve/run land (see ECOSYSTEM.md
# and hyperion/docs/adr/0007). Kept only as the working path until cons reaches parity;
# do not extend. Discovery is handled by bootstrap.lisp's source-registry drop-in.
#
# scripts/setup.sh -- one-time provisioning so a fresh clone of Hyperion loads and runs.
# Idempotent. Does NOT install SBCL/Quicklisp -- checks and tells you how.
#   1. Clone Coalton (local checkout; not pulled by Quicklisp).
#   2. Ensure libev is present (Woo's event loop).
# Discovery of the frameworks is NOT this script's job -- run
# `sbcl --script bootstrap.lisp` at the repo root once (writes the ASDF drop-in).
#
# Usage:  scripts/setup.sh [--test]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -t 1 ]; then BLUE=$'\033[1;34m'; YEL=$'\033[1;33m'; RED=$'\033[1;31m'; OFF=$'\033[0m'
else BLUE=; YEL=; RED=; OFF=; fi
info() { printf '%s==>%s %s\n' "$BLUE" "$OFF" "$*"; }
warn() { printf '%swarning:%s %s\n' "$YEL" "$OFF" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }

command -v sbcl >/dev/null 2>&1 || die "SBCL not found (e.g. 'brew install sbcl')."
QL_HOME="${QUICKLISP_HOME:-$HOME/quicklisp}"
[ -f "$QL_HOME/setup.lisp" ] || die "Quicklisp not found at $QL_HOME/setup.lisp (https://www.quicklisp.org/beta/)."
info "SBCL $(sbcl --version | awk '{print $2}')  |  Quicklisp at $QL_HOME"

# libev (Woo). Best-effort detect; auto-install with Homebrew if missing.
have_libev() {
  ls /opt/homebrew/lib/libev.* /opt/homebrew/opt/libev/lib/libev.* \
     /usr/local/lib/libev.* /usr/lib/*/libev.so* /usr/lib/libev.so* >/dev/null 2>&1 && return 0
  command -v brew >/dev/null 2>&1 && brew list libev >/dev/null 2>&1 && return 0
  return 1
}
if have_libev; then info "libev present (Woo)."
elif command -v brew >/dev/null 2>&1; then
  info "libev not found -- installing with Homebrew ..."; brew install libev || warn "'brew install libev' failed."
else warn "libev not found -- Woo needs it. macOS: brew install libev | Debian: sudo apt-get install libev-dev"; fi

# Coalton local checkout (Hyperion's typed core).
COALTON_DIR="$HOME/common-lisp/coalton"
if [ -d "$COALTON_DIR/.git" ]; then info "Coalton present at $COALTON_DIR."
else info "Cloning Coalton into $COALTON_DIR ..."; mkdir -p "$HOME/common-lisp"
  git clone --depth 1 https://github.com/coalton-lang/coalton "$COALTON_DIR"; fi

# Discovery: framework discovery is via bootstrap.lisp's ASDF source-registry drop-in
# -- run `sbcl --script bootstrap.lisp` at the repo root once. No local-projects symlink.
info "Discovery: run 'sbcl --script bootstrap.lisp' at the repo root (writes the ASDF drop-in)."

if [ "${1:-}" = "--test" ]; then
  info "Loading Hyperion (first run compiles Coalton; a few minutes)..."
  sbcl --dynamic-space-size "${HYPERION_DYNAMIC_SPACE_SIZE:-4096}" --non-interactive \
    --eval "(load \"$QL_HOME/setup.lisp\")" \
    --eval '(handler-case (ql:quickload :hyperion) (error (e) (format *error-output* "~&FAILED: ~A~%" e) (uiop:quit 1)))'
  info "Loaded."
fi
info "Setup complete. Next: run 'sbcl --dynamic-space-size 4096 --script bootstrap.lisp' at the repo root, then (ql:quickload :hyperion)."
