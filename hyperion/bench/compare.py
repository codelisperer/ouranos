#!/usr/bin/env python3
"""compare.py --- :uv against Woo (and optionally Hunchentoot), as one table (#413).

    python3 hyperion/bench/compare.py                      # uv and woo
    python3 hyperion/bench/compare.py uv woo hunchentoot

The same subject as run.sh (server.lisp) and the same client measurements as load.py, which
this imports, plus a load generator for throughput, because Python threads cannot drive these
servers hard enough to measure them.

wrk is used when it is installed, otherwise ab; the one used is named in the output. Before any
backend, the generator is run against trivial.c, a C server that does nothing but answer, with
one process per CPU, and its rate is printed as the generator's CEILING: the most this
generator measures on this machine. A backend rate of 80% of the ceiling or more is reported as
limited by the generator instead of as a number, because the generator, not the backend, may be
what set it. The ceiling is measured with the generator and trivial.c sharing the machine's
cores, which is also how the backends are measured. (trivial.c used to run one process, so its
rate was one core's limit and Woo went past it on Linux; #413.)

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

A backward step of the wall clock during a run makes the generator's error count wrong (#962).
wrk and ab both time requests with gettimeofday, and wrk subtracts two such readings as unsigned
numbers, so every request in flight when the clock steps back is counted as a timeout. WSL2 steps
its clock back by up to a few milliseconds every 20 to 30 seconds. compare.py watches for steps
during each run (ClockWatch) and, when there was one, prints the steps beside the error count
and marks the count as not valid. The rate stays valid: a step of a few milliseconds changes a 10 s run's
length by well under 0.1%.

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
import threading
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


class ClockWatch:
    """Watches for the wall clock stepping backwards while the generator runs (#962). Every
    millisecond it reads CLOCK_MONOTONIC, the wall clock, then CLOCK_MONOTONIC again, and keeps
    the wall clock's offset from the midpoint. A step back shows as the offset falling between
    two samples; slewing moves it by under a microsecond per millisecond, so a fall of more than
    STEP_NS is a step. A sample whose two monotonic reads are more than SAMPLE_NS apart is
    skipped, because the thread may have been preempted between the reads. Use as a context
    manager; afterwards STEPS holds each step's size in nanoseconds."""

    STEP_NS = 100_000
    SAMPLE_NS = 50_000

    def __init__(self):
        self.steps = []
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def _run(self):
        last = None
        while not self._stop.is_set():
            m1 = time.monotonic_ns()
            wall = time.time_ns()
            m2 = time.monotonic_ns()
            if m2 - m1 <= self.SAMPLE_NS:
                offset = wall - (m1 + m2) // 2
                if last is not None and last - offset > self.STEP_NS:
                    self.steps.append(last - offset)
                last = offset
            time.sleep(0.001)

    def __enter__(self):
        self._thread.start()
        return self

    def __exit__(self, *exc):
        self._stop.set()
        self._thread.join()


def drive(gen, url, connections, seconds):
    """Requests per second, errors, the share of requests sent on a kept-alive connection, and
    the wall clock's backward steps during the run in nanoseconds, from GEN driving URL. A server
    that closed after each response would make the generator reconnect every time, and its rate
    would measure connection setup rather than serving, so the share is reported. The share is
    None where it cannot be measured. The errors are not valid when the list of steps is not
    empty (#962)."""
    with ClockWatch() as clock:
        rps, errors, share = _drive(gen, url, connections, seconds)
    return rps, errors, share, clock.steps


def _drive(gen, url, connections, seconds):
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


GENERATOR_BOUND = 0.8   # a rate at this share of the ceiling or above is not given a number


def ceiling(gen, connections, seconds):
    """The generator's rate against trivial.c running one process per CPU and doing nothing but
    answer: the most this generator measures on this machine."""
    exe = os.path.join(tempfile.mkdtemp(prefix="bench-trivial-"), "trivial")
    subprocess.run(["cc", "-O2", "-o", exe, os.path.join(HERE, "trivial.c")], check=True)
    port = free_port()
    # Its own process group, so that the processes trivial.c forks are stopped with it.
    proc = subprocess.Popen([exe, str(port), str(os.cpu_count() or 1)],
                            stdout=subprocess.DEVNULL, start_new_session=True)
    try:
        wait_for(f"http://127.0.0.1:{port}/", proc, 10)
        return drive(gen, f"http://127.0.0.1:{port}/", connections, seconds)[0]
    finally:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass   # trivial.c already exited, for example on a failed bind; keep the real error
        proc.wait()


# --- one backend ----------------------------------------------------------------------

def _numbers(field, kind):
    return None if field in (None, "-") else [kind(x) for x in field.split(",")]


def cpu(url):
    """The server's CPU seconds so far, as (process, loops, conns): loops is each :uv loop
    thread's CPU seconds and conns how many connections each loop has taken on (#463), both
    first to last, or None on a backend without loop threads to measure."""
    text = urllib.request.urlopen(url + "/cpu", timeout=10).read().decode()
    fields = dict(part.split("=") for part in text.split())
    return (float(fields["process"]), _numbers(fields.get("loop"), float),
            _numbers(fields.get("conns"), int))


def busy(before, after, elapsed):
    """Between two cpu() readings ELAPSED seconds apart: cores kept busy by the process, cores
    kept busy by each loop, and the connections each loop took on."""
    process = (after[0] - before[0]) / elapsed
    loops = None if before[1] is None else [(b - a) / elapsed for a, b in zip(before[1], after[1])]
    conns = None if before[2] is None else [b - a for a, b in zip(before[2], after[2])]
    return process, loops, conns


def measure(backend, gen, args):
    port = free_port()
    env = dict(os.environ, HYPERION_SERVER=backend, HYPERION_WORKERS=str(args.workers),
               HYPERION_MAX_REQUESTS_PER_CONNECTION=str(args.uv_max_requests),
               CL_SOURCE_REGISTRY=f"{ROOT}//:")
    if backend == "uv" and args.loops:
        env["HYPERION_LOOPS"] = str(args.loops)
    if backend == "uv" and args.scheme:
        env["HYPERION_LOOP_SCHEME"] = args.scheme
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
            rps, errors, kept, steps = drive(gen, url + path, args.connections, args.seconds)
            process, loops, conns = busy(before, cpu(url), time.monotonic() - started)
            row[path] = {"rps": rps, "errors": errors, "kept": kept, "steps": steps,
                         "cpu_process": process, "cpu_loops": loops, "conns": conns}
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

def cell(m, top):
    if m["rps"] >= GENERATOR_BOUND * top:
        return (f"limited by the generator ({m['rps']:,.0f}, "
                f"{m['rps'] / top:.0%} of its ceiling {top:,.0f})")
    notes = []
    if m["steps"]:
        worst = max(m["steps"]) / 1000
        notes.append(f"{m['errors']} errors, a count that is not valid: the clock stepped back "
                     f"{len(m['steps'])} time(s) during the run, up to {worst:,.0f} µs")
    elif m["errors"]:
        notes.append(f"{m['errors']} errors")
    if m["kept"] is None:
        notes.append("kept-alive share not measured")
    else:
        notes.append(f"{m['kept']:.0%} on kept-alive connections")
    return f"{m['rps']:,.0f} ({'; '.join(notes)})"


def cpu_cell(m):
    """Process cores / each loop's cores, and with several loops the connections each took."""
    if m["cpu_loops"] is None:
        return f"{m['cpu_process']:.2f} / -"
    loops = ", ".join(f"{c:.2f}" for c in m["cpu_loops"])
    spread = ""
    if m["conns"] and len(m["conns"]) > 1:
        spread = " (connections " + ", ".join(str(n) for n in m["conns"]) + ")"
    return f"{m['cpu_process']:.2f} / {loops}{spread}"


def table(rows, gen_line, top, args):
    workers_text = (f"Workers: {args.workers} (Woo `:worker-num`, `:uv` `:workers`)."
                    if args.workers else
                    "Workers: none; handlers run inline (on `:uv`, on the loop thread).")
    osname = {"Darwin": "macOS", "Linux": "Linux"}.get(platform.system(), platform.system())
    lines = [
        f"**{osname}** ({platform.machine()}, {os.cpu_count()} CPUs). Generator: `{gen_line}`, "
        f"{args.connections} keep-alive connections for {args.seconds} s. "
        f"Generator ceiling: {top:,.0f} requests/s, against trivial.c with {os.cpu_count()} "
        f"processes; a rate of {GENERATOR_BOUND:.0%} of it or more is shown as limited by the "
        "generator. "
        f"`:uv` requests per connection: {args.uv_max_requests:,} (shipped default 100). "
        f"{workers_text} "
        f"`:uv` loops: {args.loops or 'the default'}, scheme: {args.scheme or 'the default'}. "
        "CPU is cores kept busy during each throughput run, the whole process / each :uv loop "
        "thread; a loop near 1.00 is saturated. With several loops, the connections each loop "
        "took during the run follow.",
        "",
        "| backend | /ping req/s | /ping CPU process / loop | /tile req/s "
        "| /tile CPU process / loop | /tile p50 / p95 / p99 ms (1 connection) "
        f"| RSS MB before / with {args.idle} open | threads before / with {args.idle} open |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for r in rows:
        lat, idle = r["latency"], r["idle"]
        lines.append(
            f"| {r['backend']} | {cell(r['/ping'], top)} | {cpu_cell(r['/ping'])} "
            f"| {cell(r['/tile'], top)} | {cpu_cell(r['/tile'])} "
            f"| {lat.get('p50_ms')} / {lat.get('p95_ms')} / {lat.get('p99_ms')} "
            f"| {idle['before']['rss_mb']} / {idle['during']['rss_mb']} "
            f"| {idle['before']['threads']} / {idle['during']['threads']} |")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("backends", nargs="*", default=["uv", "woo"])
    ap.add_argument("--connections", type=int, default=64)
    ap.add_argument("--seconds", type=int, default=10)
    ap.add_argument("--workers", type=int, default=8,
                    help="worker threads; 0 runs handlers inline, with no pool")
    ap.add_argument("--requests", type=int, default=2000)
    ap.add_argument("--loops", type=int, default=None,
                    help=":uv event loops (HYPERION_LOOPS); unset keeps server-uv's default")
    ap.add_argument("--scheme", default=None, choices=["reuseport", "shared", "handoff"],
                    help="how connections reach :uv's loops (HYPERION_LOOP_SCHEME)")
    ap.add_argument("--idle", type=int, default=500)
    ap.add_argument("--uv-max-requests", type=int, default=10 ** 9,
                    help=":uv's requests per kept-alive connection (shipped default 100)")
    args = ap.parse_args()

    gen, gen_line = generator()
    top = ceiling(gen, args.connections, args.seconds)
    print(f"compare: {gen_line}; ceiling {top:,.0f} requests/s against trivial.c", file=sys.stderr)
    rows = []
    for b in args.backends:
        print(f"compare: measuring {b} ...", file=sys.stderr)
        rows.append(measure(b, gen, args))
    print(table(rows, gen_line, top, args))


if __name__ == "__main__":
    main()
