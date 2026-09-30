#!/usr/bin/env python3
"""compare.py --- :uv against Woo (and optionally Hunchentoot), as one table (#413).

    python3 hyperion/bench/compare.py                      # uv and woo
    python3 hyperion/bench/compare.py uv woo hunchentoot

The same subject as run.sh (server.lisp) and the same client measurements as load.py, which
this imports, plus a load generator for throughput, because Python threads cannot drive these
servers hard enough to measure them.

wrk is used when it is installed, otherwise ab; the one used is named in the output. Before any
backend, the generator is run against trivial.c, a single-threaded C server with one poll() loop
that does nothing but answer, and its rate is printed as a REFERENCE. It is not the generator's
ceiling: a server that uses several cores can go past it, and on Linux Woo did (#413). No
verdict is drawn from it.

:uv closes a kept-alive connection after *MAX-REQUESTS-PER-CONNECTION* requests (100 by
default); Woo and Hunchentoot run with their own defaults. So that :uv is not the only backend
reconnecting during a run, compare.py raises the cap (--uv-max-requests, default 10^9) and
prints the value used. Pass --uv-max-requests 100 to measure the shipped default.

Per backend:
  throughput      the generator, CONNECTIONS keep-alive connections for SECONDS, on /ping and
                  on /tile. Requests per second, the errors the generator counted, and the
                  share of requests sent on a kept-alive connection: from ab's own count, or
                  under wrk from the connections the host accepted during the run (Linux's
                  /proc/net/snmp PassiveOpens; other traffic on the host adds to it). Where it
                  cannot be measured it is reported as not measured.
  cpu             during each throughput run, the server's CPU time divided by the run's
                  length, as cores kept busy: the whole process, and for :uv the loop thread
                  alone. A loop near 1.00 is the loop thread saturated, and more loops could
                  raise the rate; a loop well below 1.00 means the limit is elsewhere (#373).
                  Read from the server's /cpu endpoint before and after the run.
  latency         load.py, one request at a time on one keep-alive connection: p50/p95/p99 of
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


def accepted_connections():
    """Connections this host has accepted since boot, or None where it cannot be read. Linux
    only: /proc/net/snmp's Tcp PassiveOpens. macOS's netstat -s reports zeros to a normal user."""
    try:
        with open("/proc/net/snmp") as f:
            rows = [line.split() for line in f if line.startswith("Tcp:")]
        return int(rows[1][rows[0].index("PassiveOpens")])
    except (OSError, IndexError, ValueError):
        return None


def drive(gen, url, connections, seconds):
    """Requests per second, errors, and the share of requests sent on a kept-alive connection,
    from GEN driving URL. A server that closed after each response would make the generator
    reconnect every time, and its rate would measure connection setup rather than serving, so
    the share is reported. The share is None where it cannot be measured."""
    if gen == "wrk":
        threads = str(max(1, min(connections, os.cpu_count() or 4)))
        before = accepted_connections()
        out = subprocess.run(["wrk", "-t", threads, "-c", str(connections), "-d", f"{seconds}s", url],
                             capture_output=True, text=True).stdout
        after = accepted_connections()
        rps = float(re.search(r"Requests/sec:\s+([\d.]+)", out).group(1))
        requests = int(re.search(r"(\d+) requests in", out).group(1))
        errors = sum(int(n) for n in re.findall(r"(?:connect|read|write|timeout) (\d+)", out))
        non2xx = re.search(r"Non-2xx or 3xx responses: (\d+)", out)
        share = None
        if before is not None and after is not None and requests:
            share = max(0.0, 1 - (after - before) / requests)
        return rps, errors + (int(non2xx.group(1)) if non2xx else 0), share
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


def reference(gen, connections, seconds):
    """The generator's rate against trivial.c, a single-threaded server that does nothing but
    answer. A point of comparison, not a ceiling."""
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

def cpu(url):
    """The server's CPU seconds so far, as (process, loop). loop is None on a backend without
    a single loop thread to measure."""
    text = urllib.request.urlopen(url + "/cpu", timeout=10).read().decode()
    fields = dict(part.split("=") for part in text.split())
    return float(fields["process"]), (None if fields["loop"] == "-" else float(fields["loop"]))


def busy(before, after, elapsed):
    """Cores kept busy between two cpu() readings ELAPSED seconds apart."""
    process = (after[0] - before[0]) / elapsed
    loop = None if before[1] is None else (after[1] - before[1]) / elapsed
    return process, loop


def measure(backend, gen, args):
    port = free_port()
    env = dict(os.environ, HYPERION_SERVER=backend, HYPERION_WORKERS=str(args.workers),
               HYPERION_MAX_REQUESTS_PER_CONNECTION=str(args.uv_max_requests),
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
            before, started = cpu(url), time.monotonic()
            rps, errors, kept = drive(gen, url + path, args.connections, args.seconds)
            process, loop = busy(before, cpu(url), time.monotonic() - started)
            row[path] = {"rps": rps, "errors": errors, "kept": kept,
                         "cpu_process": process, "cpu_loop": loop}
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

def cell(m):
    notes = []
    if m["errors"]:
        notes.append(f"{m['errors']} errors")
    if m["kept"] is None:
        notes.append("kept-alive share not measured")
    else:
        notes.append(f"{m['kept']:.0%} on kept-alive connections")
    return f"{m['rps']:,.0f} ({'; '.join(notes)})"


def cpu_cell(m):
    loop = "-" if m["cpu_loop"] is None else f"{m['cpu_loop']:.2f}"
    return f"{m['cpu_process']:.2f} / {loop}"


def table(rows, gen_line, ref, args):
    osname = {"Darwin": "macOS", "Linux": "Linux"}.get(platform.system(), platform.system())
    lines = [
        f"**{osname}** ({platform.machine()}, {os.cpu_count()} CPUs). Generator: `{gen_line}`, "
        f"{args.connections} keep-alive connections for {args.seconds} s. "
        f"Reference: the same generator against trivial.c (single-threaded, one poll() loop) "
        f"reached {ref:,.0f} requests/s; that is not the generator's ceiling. "
        f"`:uv` requests per connection: {args.uv_max_requests:,} (shipped default 100). "
        f"Workers: {args.workers} (Woo `:worker-num`, `:uv` `:workers`). "
        "CPU is cores kept busy during each throughput run, the whole process / the :uv loop "
        "thread alone; a loop near 1.00 is saturated.",
        "",
        "| backend | /ping req/s | /ping CPU process / loop | /tile req/s "
        "| /tile CPU process / loop | /tile p50 / p95 / p99 ms (1 connection) "
        f"| RSS MB before / with {args.idle} open | threads before / with {args.idle} open |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for r in rows:
        lat, idle = r["latency"], r["idle"]
        lines.append(
            f"| {r['backend']} | {cell(r['/ping'])} | {cpu_cell(r['/ping'])} "
            f"| {cell(r['/tile'])} | {cpu_cell(r['/tile'])} "
            f"| {lat.get('p50_ms')} / {lat.get('p95_ms')} / {lat.get('p99_ms')} "
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
    ap.add_argument("--uv-max-requests", type=int, default=10 ** 9,
                    help=":uv's requests per kept-alive connection (shipped default 100)")
    args = ap.parse_args()

    gen, gen_line = generator()
    ref = reference(gen, args.connections, args.seconds)
    print(f"compare: {gen_line}; {ref:,.0f} requests/s against trivial.c", file=sys.stderr)
    rows = []
    for b in args.backends:
        print(f"compare: measuring {b} ...", file=sys.stderr)
        rows.append(measure(b, gen, args))
    print(table(rows, gen_line, ref, args))


if __name__ == "__main__":
    main()
