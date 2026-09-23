#!/usr/bin/env python3
"""load.py --- measure what a desktop live feed actually asks of a web server.

    python3 hyperion/bench/load.py http://127.0.0.1:8099 --label hunchentoot

Deliberately stdlib-only: it has to run on a bare WSL/CI box with no pip install, and the
numbers must not depend on a load generator we had to provision first.

Three measurements, each chosen to answer a specific question in the Woo-vs-Hunchentoot
decision for DESKTOP bundles (issue #72):

  latency @ concurrency 1  -- the actual desktop case: one user, one request at a time.
                              p50/p99 matter here, not throughput; a feed that repaints at
                              10 Hz needs p99 well under 100 ms.
  throughput @ concurrency N -- headroom. Not a target: if both servers are 100x over what
                              one local user needs, the difference is not a reason to pick.
  idle connections         -- the real worry with a thread-per-connection server. An HTMX
                              dashboard that opens one SSE stream per widget turns into one
                              thread per widget. Measures RSS and thread count while N
                              connections sit open, which is what SSE streams look like.
"""

import argparse
import http.client
import json
import os
import socket
import statistics
import subprocess
import sys
import threading
import time
from urllib.parse import urlparse


def _conn(url):
    u = urlparse(url)
    return http.client.HTTPConnection(u.hostname, u.port, timeout=10)


def _get(conn, path):
    conn.request("GET", path)
    r = conn.getresponse()
    body = r.read()
    return r.status, len(body)


def latency(url, path, n, reuse=True):
    """Sequential request latency.

    reuse=True keeps ONE connection (what a browser and HTMX actually do); reuse=False
    reconnects each time. Both are reported because the gap between them is itself a
    finding: a ~40 ms floor that appears ONLY with reuse is the classic Nagle/delayed-ACK
    interaction, not the server being slow -- chunked encoding writes the terminating chunk
    separately, and without TCP_NODELAY the kernel sits on it.
    """
    conn = _conn(url) if reuse else None
    samples = []
    status = None
    size = 0
    stalled_after = None
    for i in range(n):
        t0 = time.perf_counter()
        try:
            if reuse:
                status, size = _get(conn, path)
            else:
                c = _conn(url)
                status, size = _get(c, path)
                c.close()
        except Exception as e:
            # A stall IS the measurement -- record where it died and keep going, rather
            # than taking the whole benchmark down with it.
            stalled_after = {"after_requests": i, "error": type(e).__name__}
            break
        samples.append((time.perf_counter() - t0) * 1000.0)
    if conn:
        try:
            conn.close()
        except Exception:
            pass
    if not samples:
        return {"n": n, "keepalive": reuse, "stalled": stalled_after, "samples": 0}
    samples.sort()
    return {
        "n": n, "samples": len(samples), "stalled": stalled_after,
        "status": status, "bytes": size, "keepalive": reuse,
        "p50_ms": round(statistics.median(samples), 3),
        "p90_ms": round(samples[int(len(samples) * 0.90)], 3),
        "p99_ms": round(samples[int(len(samples) * 0.99)], 3),
        "max_ms": round(samples[-1], 3),
    }


def throughput(url, path, workers, seconds):
    """Sustained rate with `workers` concurrent clients -- headroom, not a target."""
    stop = time.perf_counter() + seconds
    counts = [0] * workers
    errors = [0] * workers

    def run(i):
        try:
            conn = _conn(url)
            while time.perf_counter() < stop:
                try:
                    st, _ = _get(conn, path)
                    if st == 200:
                        counts[i] += 1
                    else:
                        errors[i] += 1
                except Exception:
                    errors[i] += 1
                    try:
                        conn.close()
                    except Exception:
                        pass
                    conn = _conn(url)
        except Exception:
            errors[i] += 1

    threads = [threading.Thread(target=run, args=(i,)) for i in range(workers)]
    t0 = time.perf_counter()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    elapsed = time.perf_counter() - t0
    total = sum(counts)
    return {"workers": workers, "seconds": round(elapsed, 2),
            "requests": total, "rps": round(total / elapsed, 1), "errors": sum(errors)}


def _proc_stats(pid):
    """RSS (MB) and thread count for a pid, from /proc -- Linux only, no deps."""
    try:
        with open(f"/proc/{pid}/status") as f:
            rss = threads = None
            for line in f:
                if line.startswith("VmRSS:"):
                    rss = int(line.split()[1]) / 1024.0
                elif line.startswith("Threads:"):
                    threads = int(line.split()[1])
            return {"rss_mb": round(rss, 1) if rss else None, "threads": threads}
    except OSError:
        return {"rss_mb": None, "threads": None}


def idle_connections(url, pid, n):
    """Hold N connections open at once -- what N SSE streams cost the server.

    A thread-per-connection server pays a thread (and its stack) per open connection; an
    event-loop server pays a file descriptor. This is the measurement that decides whether
    the per-widget-stream anti-pattern is merely wasteful or actually fatal.
    """
    u = urlparse(url)
    before = _proc_stats(pid)
    socks = []
    try:
        for _ in range(n):
            s = socket.create_connection((u.hostname, u.port), timeout=10)
            # A real request, deliberately left un-drained so the connection stays live.
            s.sendall(b"GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n")
            socks.append(s)
        time.sleep(2.0)                      # let the server settle
        during = _proc_stats(pid)
    finally:
        for s in socks:
            try:
                s.close()
            except Exception:
                pass
    return {"connections": n, "before": before, "during": during}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("--label", default="server")
    ap.add_argument("--pid", type=int, default=0, help="server pid, for the idle-connection test")
    ap.add_argument("--requests", type=int, default=2000)
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--seconds", type=int, default=5)
    ap.add_argument("--idle", type=int, default=50)
    args = ap.parse_args()

    # Warm up: the first requests through a fresh image pay for lazily-compiled paths, and
    # including them would measure the wrong thing. Fresh connections, so a keep-alive
    # pathology cannot make the warmup itself take minutes.
    latency(args.url, "/tile", 50, reuse=False)

    out = {"label": args.label, "url": args.url}
    # Keep-alive is what browsers/HTMX do, so it is the number that matters; the
    # fresh-connection figure isolates the server's actual work from any TCP pathology.
    n_ka = min(args.requests, 300)          # bounded: a 40 ms floor makes 2000 take 80 s
    out["tile_keepalive"] = latency(args.url, "/tile", n_ka, reuse=True)
    out["tile_fresh"] = latency(args.url, "/tile", args.requests, reuse=False)
    out["ping_fresh"] = latency(args.url, "/ping", args.requests, reuse=False)
    out["board_fresh"] = latency(args.url, "/board", max(200, args.requests // 4), reuse=False)
    out["tile_throughput"] = throughput(args.url, "/tile", args.workers, args.seconds)
    if args.pid:
        out["idle"] = idle_connections(args.url, args.pid, args.idle)
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
