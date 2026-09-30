#!/usr/bin/env python3
"""compare.py --- :uv against Woo (and optionally Hunchentoot), as one table (#413).

    python3 hyperion/bench/compare.py                      # uv and woo
    python3 hyperion/bench/compare.py uv woo hunchentoot

The same subject as run.sh (server.lisp) and the same client measurements as load.py, which
this imports, plus a load generator for throughput, because Python threads cannot drive these
servers hard enough to measure them.

THE GENERATOR IS MEASURED FIRST. wrk is used when it is installed, otherwise ab; the one used
is named in the output. Before any backend, the generator is run against trivial.c, a C server
that does nothing but answer, and the rate it reaches is its ceiling on this machine: the most
this setup can measure. A backend whose rate comes within CEILING_SHARE of it is reported as
limited by the generator, not given a number, so the table shows servers, not the generator.

Per backend:
  throughput      the generator, CONNECTIONS keep-alive connections for SECONDS, on /ping and
                  on /tile. Requests per second, and the errors the generator counted.
  latency         load.py, one request at a time on one keep-alive connection: p50/p90/p99 of
                  /tile. Not limited by the generator, and finer than ab's whole milliseconds.
  open conns      load.py's idle test: resident memory and threads while IDLE connections
                  are open at once.

Requires: sbcl and Quicklisp as for run.sh; a built vendor/libuv for :uv; cc; and wrk or ab.
Woo is Unix-only.
"""

import argparse
import os
import platform
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import load  # noqa: E402  (the measurements run.sh already uses)

CEILING_SHARE = 0.8


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def wait_for(url, proc, seconds):
    """Poll URL until it answers, or fail when PROC exits or SECONDS pass."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"the server exited before listening (code {proc.returncode})")
        try:
            urllib.request.urlopen(url, timeout=2).read()
            return
        except OSError:
            time.sleep(0.5)
    raise RuntimeError(f"{url} did not answer within {seconds} s")


# --- the generator --------------------------------------------------------------------

def generator():
    """The load generator to use and a line naming it, version included."""
    if shutil.which("wrk"):
        out = subprocess.run(["wrk", "-v"], capture_output=True, text=True)
        return "wrk", (out.stdout or out.stderr).splitlines()[0].strip()
    if shutil.which("ab"):
        out = subprocess.run(["ab", "-V"], capture_output=True, text=True)
        return "ab", out.stdout.splitlines()[0].strip()
    sys.exit("compare.py: neither wrk nor ab is installed; install wrk (apt install wrk)")


def drive(gen, url, connections, seconds):
    """Requests per second, errors, and the share of requests sent on a kept-alive connection,
    from GEN driving URL. A server that closed after each response would make the generator
    reconnect every time, and its rate would measure connection setup rather than serving, so
    the share is reported. wrk always keeps connections alive: its share is 1."""
    if gen == "wrk":
        threads = str(max(1, min(connections, os.cpu_count() or 4)))
        out = subprocess.run(["wrk", "-t", threads, "-c", str(connections), "-d", f"{seconds}s", url],
                             capture_output=True, text=True).stdout
        rps = float(re.search(r"Requests/sec:\s+([\d.]+)", out).group(1))
        errors = sum(int(n) for n in re.findall(r"(?:connect|read|write|timeout) (\d+)", out))
        non2xx = re.search(r"Non-2xx or 3xx responses: (\d+)", out)
        return rps, errors + (int(non2xx.group(1)) if non2xx else 0), 1.0
    # ab: -t bounds the run by time; -n only has to be larger than what fits in it.
    out = subprocess.run(["ab", "-k", "-q", "-c", str(connections), "-t", str(seconds),
                          "-n", "50000000", url], capture_output=True, text=True).stdout
    rps = float(re.search(r"Requests per second:\s+([\d.]+)", out).group(1))
    failed = int(re.search(r"Failed requests:\s+(\d+)", out).group(1))
    non2xx = re.search(r"Non-2xx responses:\s+(\d+)", out)
    complete = int(re.search(r"Complete requests:\s+(\d+)", out).group(1))
    kept = re.search(r"Keep-Alive requests:\s+(\d+)", out)
    share = (int(kept.group(1)) / complete) if (kept and complete) else 0.0
    return rps, failed + (int(non2xx.group(1)) if non2xx else 0), share


def ceiling(gen, connections, seconds):
    """The generator's rate against trivial.c, which does nothing but answer."""
    exe = os.path.join(tempfile.mkdtemp(prefix="bench-trivial-"), "trivial")
    subprocess.run(["cc", "-O2", "-o", exe, os.path.join(HERE, "trivial.c")], check=True)
    port = free_port()
    proc = subprocess.Popen([exe, str(port)], stdout=subprocess.DEVNULL)
    try:
        wait_for(f"http://127.0.0.1:{port}/", proc, 10)
        return drive(gen, f"http://127.0.0.1:{port}/", connections, seconds)[0]
    finally:
        proc.terminate()
        proc.wait()


# --- one backend ----------------------------------------------------------------------

def measure(backend, gen, cap, args):
    port = free_port()
    env = dict(os.environ, HYPERION_SERVER=backend, HYPERION_WORKERS=str(args.workers),
               CL_SOURCE_REGISTRY=f"{ROOT}//:")
    log = open(os.path.join(tempfile.gettempdir(), f"bench-{backend}.log"), "w")
    proc = subprocess.Popen(["sbcl", "--dynamic-space-size", "4096", "--script",
                             os.path.join(HERE, "server.lisp"), str(port)],
                            cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
    url = f"http://127.0.0.1:{port}"
    try:
        wait_for(url + "/ping", proc, 600)
        load.latency(url, "/tile", 50, reuse=False)          # warm up, as load.py does
        row = {"backend": backend}
        for path in ("/ping", "/tile"):
            rps, errors, kept = drive(gen, url + path, args.connections, args.seconds)
            row[path] = {"rps": rps, "errors": errors, "kept": kept,
                         "bound": rps >= CEILING_SHARE * cap}
        row["latency"] = load.latency(url, "/tile", args.requests, reuse=True)
        row["idle"] = load.idle_connections(url, proc.pid, args.idle)
        return row
    finally:
        try:
            urllib.request.urlopen(url + "/quit", timeout=2).read()
            proc.wait(timeout=30)
        except Exception:
            proc.send_signal(signal.SIGKILL)   # only the server this script started
            proc.wait()
        log.close()


# --- the table -----------------------------------------------------------------------

def cell(m, cap):
    if m["bound"]:
        return f"limited by the generator (≥{int(CEILING_SHARE * 100)}% of {cap:,.0f})"
    notes = []
    if m["errors"]:
        notes.append(f"{m['errors']} errors")
    if m["kept"] < 0.99:
        notes.append(f"only {m['kept']:.0%} on kept-alive connections")
    return f"{m['rps']:,.0f}" + (f" ({'; '.join(notes)})" if notes else "")


def table(rows, gen_line, cap, args):
    osname = {"Darwin": "macOS", "Linux": "Linux"}.get(platform.system(), platform.system())
    lines = [
        f"**{osname}** ({platform.machine()}, {os.cpu_count()} CPUs). Generator: `{gen_line}`, "
        f"{args.connections} keep-alive connections for {args.seconds} s. "
        f"**Generator ceiling** against trivial.c: {cap:,.0f} requests/s. "
        f"Workers: {args.workers} (Woo `:worker-num`, `:uv` `:workers`).",
        "",
        "| backend | /ping req/s | /tile req/s | /tile p50 / p90 / p99 ms (1 connection) "
        f"| RSS MB before / with {args.idle} open | threads before / with {args.idle} open |",
        "|---|---|---|---|---|---|",
    ]
    for r in rows:
        lat, idle = r["latency"], r["idle"]
        lines.append(
            f"| {r['backend']} | {cell(r['/ping'], cap)} | {cell(r['/tile'], cap)} "
            f"| {lat.get('p50_ms')} / {lat.get('p90_ms')} / {lat.get('p99_ms')} "
            f"| {idle['before']['rss_mb']} / {idle['during']['rss_mb']} "
            f"| {idle['before']['threads']} / {idle['during']['threads']} |")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("backends", nargs="*", default=["uv", "woo"])
    ap.add_argument("--connections", type=int, default=64)
    ap.add_argument("--seconds", type=int, default=10)
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--requests", type=int, default=2000)
    ap.add_argument("--idle", type=int, default=500)
    args = ap.parse_args()

    gen, gen_line = generator()
    cap = ceiling(gen, args.connections, args.seconds)
    print(f"compare: {gen_line}; ceiling {cap:,.0f} requests/s against trivial.c", file=sys.stderr)
    rows = []
    for b in args.backends:
        print(f"compare: measuring {b} ...", file=sys.stderr)
        rows.append(measure(b, gen, cap, args))
    print(table(rows, gen_line, cap, args))


if __name__ == "__main__":
    main()
