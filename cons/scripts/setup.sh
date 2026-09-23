#!/usr/bin/env bash
#
# INTERIM — superseded by `bin/cons` once build/test/serve/run land (see ECOSYSTEM.md
# and hyperion/docs/adr/0007). Kept only as the working path until cons reaches parity;
# do not extend. Discovery is handled by bootstrap.lisp's source-registry drop-in.
#
# scripts/setup.sh -- prereq check for cons. Idempotent. Pure-CL and dependency-light
# on purpose (cons is a bootstrapping tool -- it shouldn't need a heavy ritual to
# itself install).
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

info "Discovery: run \`sbcl --script bootstrap.lisp\` at the repo root (writes the ASDF drop-in)."

if [ "${1:-}" = "--test" ]; then
  info "Loading cons ..."
  sbcl --non-interactive \
    --eval "(load \"$QL_HOME/setup.lisp\")" \
    --eval '(handler-case (ql:quickload :cons) (error (e) (format *error-output* "~&FAILED: ~A~%" e) (uiop:quit 1)))'
  info "Loaded."
fi
info "Setup complete. Next: run bootstrap.lisp at the repo root, then rlwrap sbcl and (ql:quickload :cons)."
