#!/usr/bin/env sh
# run.sh --- benchmark one server backend end to end, in a single shell session.
#
#     hyperion/bench/run.sh hunchentoot [port]
#     hyperion/bench/run.sh woo         [port]
#
# Start the bench server, wait until it actually listens, run the load client against it,
# stop it, print the JSON. Everything in ONE session on purpose: under WSL the distro is
# reaped once no session holds it, which quietly kills a backgrounded server between calls.
#
# Woo is Unix-only, so this only compares on Linux/macOS. Answers the desktop
# server-backend question in issue #72 with numbers instead of reasoning.
set -eu

# NB: no braces in the :? message -- the first `}` closes the expansion, so
# ${1:?usage ... {a|b} ...} silently yields "$1 ...trailing junk}" instead of erroring.
backend="${1:?usage: run.sh hunchentoot|woo [port]}"
port="${2:-8099}"
case "$backend" in
  hunchentoot|woo) ;;
  *) echo "run.sh: backend must be hunchentoot or woo (got '$backend')" >&2; exit 2;;
esac
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$(dirname "$here")")
log="/tmp/bench-$backend.log"

# The pinned SBCL installs under ~/.local, which is not on PATH in a fresh non-login shell.
[ -x "$HOME/.local/bin/sbcl" ] && { PATH="$HOME/.local/bin:$PATH"; export PATH; }
[ -d "$HOME/.local/lib/sbcl" ] && { SBCL_HOME="$HOME/.local/lib/sbcl"; export SBCL_HOME; }

cd "$root"
HYPERION_SERVER="$backend" sbcl --dynamic-space-size 4096 --script hyperion/bench/server.lisp "$port" > "$log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT

# Wait for the port rather than sleeping a guessed interval: the first run of a fresh image
# compiles Coalton and can take minutes, while a warm one is seconds.
i=0
while [ "$i" -lt 600 ]; do
  if command -v curl >/dev/null 2>&1 && curl -fsS "http://127.0.0.1:$port/ping" >/dev/null 2>&1; then break; fi
  kill -0 "$pid" 2>/dev/null || { echo "run.sh: server exited early; see $log" >&2; tail -20 "$log" >&2; exit 1; }
  i=$((i + 1)); sleep 1
done
[ "$i" -lt 600 ] || { echo "run.sh: server never listened on $port; see $log" >&2; exit 1; }

grep -i "listening\|bench:" "$log" | tail -2 >&2
python3 "$here/load.py" "http://127.0.0.1:$port" --label "$backend" --pid "$pid"

curl -fsS "http://127.0.0.1:$port/quit" >/dev/null 2>&1 || true
