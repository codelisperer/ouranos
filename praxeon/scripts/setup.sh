#!/usr/bin/env bash
#
# INTERIM -- superseded by `bin/cons` once build/test/serve/run land (see ECOSYSTEM.md
# and hyperion/docs/adr/0007). Kept only as the working path until cons reaches parity;
# do not extend. Discovery is handled by bootstrap.lisp's source-registry drop-in.
#
# scripts/setup.sh -- convenience provisioning for a fresh clone of Praxeon.
#
# Idempotent (safe to re-run). Does NOT install SBCL or Quicklisp -- it checks
# for them and tells you how to get them. What it does:
#   1. Clone Coalton (a local checkout; not pulled by Quicklisp).
#   2. Create .env from .env.example (never overwriting an existing one).
#   3. (optional, with --test) compile and run the network-free test suite.
#
# System discovery (finding praxeon.asd) is NOT done here anymore: run
# `sbcl --script bootstrap.lisp` at the monorepo root once -- it writes the ASDF
# source-registry drop-in covering all six frameworks.
#
# Usage:  scripts/setup.sh [--test]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colorize only when writing to a terminal (keeps logs/CI output clean).
if [ -t 1 ]; then
  BLUE=$'\033[1;34m'; YEL=$'\033[1;33m'; RED=$'\033[1;31m'; OFF=$'\033[0m'
else
  BLUE=; YEL=; RED=; OFF=
fi
info() { printf '%s==>%s %s\n' "$BLUE" "$OFF" "$*"; }
warn() { printf '%swarning:%s %s\n' "$YEL" "$OFF" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }

# --- prerequisites -----------------------------------------------------------
command -v sbcl >/dev/null 2>&1 \
  || die "SBCL not found. Install it (e.g. 'brew install sbcl', or your package manager), then re-run."

QL_HOME="${QUICKLISP_HOME:-$HOME/quicklisp}"
[ -f "$QL_HOME/setup.lisp" ] \
  || die "Quicklisp not found at $QL_HOME/setup.lisp. Install it (https://www.quicklisp.org/beta/) or set QUICKLISP_HOME."

info "SBCL $(sbcl --version | awk '{print $2}')  |  Quicklisp at $QL_HOME"

# libev: Woo (the web server) builds on it, and praxeon/elise depends on
# praxeon/web -- so WITHOUT libev even a plain (ql:quickload :praxeon/elise) fails.
# Best-effort detection across macOS (Homebrew) and Linux; warn (don't die) since
# the check can miss a valid install.
have_libev() {
  ls /opt/homebrew/lib/libev.* /opt/homebrew/opt/libev/lib/libev.* \
     /usr/local/lib/libev.* /usr/lib/*/libev.so* /usr/lib/libev.so* \
     >/dev/null 2>&1 && return 0
  command -v brew >/dev/null 2>&1 && brew list libev >/dev/null 2>&1 && return 0
  return 1
}
if have_libev; then
  info "libev present (Woo's event loop)."
elif command -v brew >/dev/null 2>&1; then
  info "libev not found -- installing with Homebrew (Woo needs it) ..."
  # Non-fatal: under 'set -e' a failed install would abort setup before the
  # warning below, contradicting the best-effort intent.
  brew install libev || warn "'brew install libev' failed -- install it manually; 'make dev' may fail to load Woo."
  have_libev || warn "libev still not detected after 'brew install libev' -- 'make dev' may fail to load Woo."
else
  warn "libev not found -- Woo needs it, and praxeon/elise loads Woo. Install it:"
  warn "    macOS:         brew install libev"
  warn "    Debian/Ubuntu: sudo apt-get install libev-dev"
  warn "  Without it, (ql:quickload :praxeon/elise) and 'make dev' fail to load Woo."
fi

# --- 1. Coalton (local checkout; Praxeon's typed core needs it) --------------
COALTON_DIR="$HOME/common-lisp/coalton"
if [ -d "$COALTON_DIR/.git" ]; then
  info "Coalton present at $COALTON_DIR (leave as-is; 'git -C $COALTON_DIR pull' to update)."
else
  info "Cloning Coalton into $COALTON_DIR ..."
  mkdir -p "$HOME/common-lisp"
  git clone --depth 1 https://github.com/coalton-lang/coalton "$COALTON_DIR"
fi

# --- 2. System discovery (handled by the repo-root bootstrap, not here) -------
info "Discovery: run \`sbcl --script bootstrap.lisp\` at the repo root (writes the ASDF drop-in)."

# --- 3. .env from the template (never overwrite) -----------------------------
if [ -f "$REPO_ROOT/.env" ]; then
  info ".env already exists (untouched)."
else
  cp "$REPO_ROOT/.env.example" "$REPO_ROOT/.env"
  warn "Created .env from .env.example -- add your PRAXEON_LLM_* key(s) before running Elise."
fi

# --- 4. optional: compile + run the network-free suite -----------------------
if [ "${1:-}" = "--test" ]; then
  info "Loading Praxeon and running tests (first run compiles Coalton; a few minutes)..."
  # Coalton's first, uncached compile can exhaust SBCL's 1 GB default heap
  # ("Heap exhausted, game over"). --dynamic-space-size (a runtime option, so it
  # must precede the toplevel --eval options) gives it room.
  sbcl --dynamic-space-size "${PRAXEON_DYNAMIC_SPACE_SIZE:-4096}" --non-interactive \
    --eval "(load \"$QL_HOME/setup.lisp\")" \
    --eval '(handler-case
               (progn
                 (ql:quickload :praxeon/tests)
                 (let ((r (fiveam:run (uiop:find-symbol* :praxeon :praxeon/tests))))
                   (fiveam:explain! r)
                   (unless (fiveam:results-status r) (uiop:quit 1))))
             (error (e) (format *error-output* "~&SETUP TEST FAILED: ~A~%" e) (uiop:quit 1)))'
  info "Tests passed."
fi

info "Setup complete."
cat <<NEXT

Next:
  1. If you haven't yet, run the discovery bootstrap once at the monorepo root:
       sbcl --dynamic-space-size 4096 --script bootstrap.lisp
  2. Edit $REPO_ROOT/.env and add a provider key (see .env.example).
  3. Start a REPL and talk to Elise:
       sbcl --dynamic-space-size 4096
       (ql:quickload :praxeon/elise)
       (praxeon/elise:start)
  See docs/user-guide.md for details.
NEXT
