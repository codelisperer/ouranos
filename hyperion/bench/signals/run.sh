#!/usr/bin/env bash
#
# run.sh --- does SIGTERM reach a Hyperion app? One row per backend, per mode.
#
#   hyperion/bench/signals/run.sh [repeats]      (default 3)
#
# Fills the matrix in hyperion/docs/signals-and-shutdown.md. It exists as a script rather
# than as a paragraph because two of that matrix's cells are still unmeasured -- macOS and
# Windows -- and a measurement nobody can repeat is a claim, not evidence.
#
# TWO MODES, and the difference is the whole diagnosis:
#
#   toplevel       everything a real app does EXCEPT serve-forever. If a backend loses the
#                  signal here, the fault is in the transport and serve-forever is innocent.
#   serve-forever  the actual production entry point -- the row #37 depends on.
#
# The signal is sent by /bin/kill from THIS shell, i.e. from a genuinely external process.
# A signal sent from inside the SBCL under test proves less and was already known to work.
#
# Requires: a built vendor/libuv for the :uv rows (scripts/build-libuv.lisp), and quicklisp
# for the Clack handlers. Woo is Unix-only; on Windows expect it to be absent entirely.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
repeats="${1:-3}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# One run: start the probe, wait for READY (which carries the pid), SIGTERM it, report.
probe () {
  local script="$1" backend="$2" out="$tmp/$backend.out" pid="" driver rc
  rm -f "$out"
  CL_SOURCE_REGISTRY="$root//:" PROBE_BACKEND="$backend" \
    sbcl --dynamic-space-size 4096 --script "$here/$script" > "$out" 2>&1 &
  driver=$!
  for _ in $(seq 1 900); do
    grep -q "^READY " "$out" 2>/dev/null && { pid=$(awk '/^READY /{print $3}' "$out"); break; }
    grep -q "^PROBE-ERROR" "$out" 2>/dev/null && break
    sleep 0.1
  done
  if [ -z "$pid" ]; then
    wait $driver 2>/dev/null
    echo "SKIP  ($(grep -m1 '^PROBE-ERROR' "$out" | cut -c1-60))"
    return
  fi
  sleep 0.5
  /bin/kill -TERM "$pid"
  wait $driver; rc=$?
  if [ "$rc" -eq 0 ]; then echo "FIRED"; else echo "TIMEOUT"; fi
}

printf '%-14s %-22s %s\n' "BACKEND" "MODE" "RESULT (x$repeats)"
for backend in none woo hunchentoot uv; do
  for mode in toplevel serve-forever; do
    # "none" has no serve-forever row: serve-forever must start a server.
    [ "$backend" = none ] && [ "$mode" = serve-forever ] && continue
    script=$([ "$mode" = toplevel ] && echo probe-toplevel.lisp || echo probe-serve-forever.lisp)
    results=""
    for _ in $(seq 1 "$repeats"); do results="$results $(probe "$script" "$backend")"; done
    printf '%-14s %-22s %s\n' "$backend" "$mode" "$results"
  done
done
