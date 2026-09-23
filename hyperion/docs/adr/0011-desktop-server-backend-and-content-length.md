# ADR-0011 — Desktop bundles use Hunchentoot; buffered responses carry Content-Length

**Status:** Accepted — 2026-07-29 (measured; the benchmark and its method are in
[`hyperion/bench/`](../../bench/)). **The Content-Length half stands permanently. The
backend half is a WAYPOINT, not a destination** — see Provenance.

> **Clarified 2026-08-05 by the maintainer.** This ADR reads as though Hunchentoot is where
> desktop bundles settle. It is not. **Hunchentoot is a near-term stop-gap until the
> libuv-backed server (pre-publication issue 117) exists,
> at which point it is to be removed as a dependency entirely** — as is Woo. Anything built
> on the assumption that a third-party HTTP server is permanent should be built so that
> assumption is cheap to withdraw.

## Context

Desktop bundles built by CI **do not run on a clean machine**. The Linux artifact dies with:

```
Error opening shared object "libev.so.4": cannot open shared object file
```

Woo — Hyperion's default server on Unix — binds **libev** through CFFI at *load* time, so
libev is a hard runtime dependency of every Linux and macOS bundle. No end user has
`libev-dev` installed, and the failure is invisible on any machine that has built the tree
(issue #72). The obvious fix is to build desktop bundles against **Hunchentoot**, which is
pure CL — and is already what Windows uses, so it is the path we have shipped and proven.

The objection was performance, and it deserved a real answer rather than reasoning: a
desktop app may drive a **live feed** (a stock ticker was the motivating case), repainting
via HTMX many times a second. Woo is an event loop; Hunchentoot is thread-per-connection.
So: measure.

## What the measurement found

WSL Ubuntu 26.04, SBCL 2.6.6, one 652 B HTMX fragment, sequential requests on **one
keep-alive connection** — what a browser and HTMX actually do:

| server | response | p50 |
|---|---|---|
| Woo | chunked | **0.15 ms** |
| Hunchentoot | chunked | **44.00 ms** |
| Hunchentoot | Content-Length | **0.17 ms** |

The 44 ms was **not** Hunchentoot being slow, and not a property of either server. It is a
flat floor at the **delayed-ACK timer**: without a length header the Clack handler falls
back to chunked encoding, whose terminating zero-length chunk is a **separate small write**,
and Nagle's algorithm holds that write waiting for an ACK the client will not send until it
has a complete response. Setting `Content-Length` makes the response one write; the stall
disappears.

So the benchmark set out to compare two servers and instead found **a bug in our own
request path** — one that had been costing ~44 ms on every HTMX swap over a persistent
connection, on every Hyperion app running Hunchentoot. On Windows, that is all of them.

## Decision

1. **Desktop bundles use Hunchentoot on every platform.** With Content-Length set the two
   servers are indistinguishable on the desktop path (0.17 vs 0.15 ms), so this costs
   nothing measurable and removes libev — a CFFI dependency that made every Linux/macOS
   bundle unrunnable on a clean machine. It also removes a platform asymmetry rather than
   adding one: Windows desktop already runs Hunchentoot.
2. **Hyperion sets Content-Length on buffered responses**, via `wrap-content-length` in
   `hyperion/server`, applied inside `start` so every app gets it without changing a line.
   Bodies that are *not* a fully-known sequence — a function (streamed), a pathname — are
   left strictly alone: they must stay chunked because their length is not knowable up
   front, and SSE depends on that.
3. **Woo remains the default for server deployments** on Unix, where many concurrent
   connections are the actual workload and an event loop earns its keep. This ADR narrows
   Hunchentoot to the *desktop* target, not to Hyperion generally.
4. **The escape hatch stays**: `HYPERION_SERVER` still selects a backend, and a desktop app
   that genuinely wants Woo can have it — accepting that it must then bundle libev.

## Consequences

- Desktop bundles lose a native dependency. The **general** problem does not go away —
  WebKitGTK, `tinyfiledialogs`, SQLite and OpenSSL are queued behind it (#78) — but the
  first and most immediate blocker is gone.
- **Every Hyperion app gets faster**, not only desktop ones. A 44 ms floor on the main
  request path is the difference between an HTMX UI that feels immediate and one that feels
  sluggish, and it would have read as "the framework is slow" with no visible cause.
- A remaining wrinkle, recorded rather than hidden: after the fix, `/tile`'s p50 is 0.24 ms
  but **p99 is still ~40 ms** — an occasional straggler continues to hit the delayed-ACK
  timer, so something intermittently splits the write. Worth chasing; it may argue for
  setting `TCP_NODELAY` on the listening socket as well, which would also protect *streamed*
  responses that by definition cannot carry a Content-Length (the SSE progress UI in pre-publication issue 76).
- Choosing Hunchentoot for desktop is an **`.asd`-level** decision, not a runtime one: the
  handler is baked into the dumped image at build time, so `hyperion.asd`'s
  platform-conditional dependency on `clack-handler-woo` has to become a deliberate choice
  per target kind.

## Method (so the numbers can be re-taken, and trusted)

The harness is [`hyperion/bench/`](../../bench/): `server.lisp` (one app, either backend,
endpoints that separate framing cost from rendering cost), `load.py` (stdlib-only, so the
numbers do not depend on a load generator we had to provision first), `run.sh` (drives one
backend end to end).

Four things that cost real time and would cost it again:

- **Measure the keep-alive path.** A fresh connection per request *hides this entire bug* —
  0.6 ms per request, no floor, no clue. Browsers reuse connections; a benchmark that does
  not is measuring a workload nobody runs.
- **A benchmark must report a stall, not crash on it.** The first harness died with a
  `TimeoutError` traceback, which reads as "the tool is broken" rather than "the server
  stalled after N requests" — losing the finding.
- **Under WSL, run the server and the load in ONE session.** The distro is reaped once no
  session holds it, silently killing a backgrounded server between calls.
- **`${1:?usage ... {a|b} ...}` in `sh` truncates at the first `}`** inside the message,
  yielding a corrupted value instead of an error — which poisoned `HYPERION_SERVER` and made
  the server die with an unrelated-looking backtrace.

**Coverage is partial and should be extended.** These numbers are Linux (WSL) only, which is
the one platform where both backends run, so it is the only apples-to-apples comparison
available. macOS can also run both and has not been measured. Windows can run **only**
Hunchentoot, so it yields absolute rather than comparative numbers — but it is where the
Content-Length bug bit hardest, and is worth taking.

## Alternatives considered

- **Bundle libev into the AppImage / `.app`** and keep Woo. Still needed for WebKitGTK
  regardless (#78), but it is strictly more machinery than not depending on libev at all,
  and it would have left the Content-Length bug undiscovered.
- **Write our own event-loop server** over a native shim we control, removing both the
  dependency and the bundling question. Seriously considered, and weakened considerably by
  this measurement: the evidence for it was a 44 ms floor that turned out to be our own
  missing header. If it is ever revisited, the primitive should be **libuv**, not libev —
  libev on Windows wraps only `select()` with no IOCP, which is precisely why Woo is
  Unix-only, so building on libev would inherit the Windows weakness we would be trying to
  escape. The surviving mandate is narrow: Woo-class throughput on Windows Server.
- **Ship desktop apps with a bundled `libev` via the package manager** (`brew install
  libev`, `apt install libev-dev`). Rejected: "install this before running our app" is not a
  desktop product.

## Provenance — and where this decision went next

Recorded because the *process* here is the interesting part, and because the conclusion did
not survive contact with what it enabled.

This ADR exists because a hunch was turned into a measurement. "Woo *feels* like it should
handle that better" produced a benchmark that was supposed to settle a server choice, and
instead found a **44 ms delayed-ACK floor in our own request path** — a bug in Hyperion, not
in either server, invisible to any harness that did not use a keep-alive connection. The
hunch was wrong about the cause and right to insist on measuring. That half of this ADR —
*buffered responses carry Content-Length* — is settled and permanent.

The backend half concluded "Hunchentoot on every platform for desktop," largely because it
drops **libev**, the CFFI dependency that made Linux and macOS bundles fail on a clean
machine. That was correct given the options *at the time*.

**The maintainer then rejected the framing rather than the answer.** If the objection to Woo
was really an unvendorable native dependency, the alternative was not "pick the other
third-party server" but "own the async substrate." That became `aion/uv` — libuv bound
directly, built from source by a Lisp script, with no groveller and no CMake — and then
pre-publication issue 117: a native libuv HTTP server with
the typed interceptor pipeline on top, no Hunchentoot and no Woo.

Worth being precise about what that does *not* rest on: **performance.** This ADR measured
Hunchentoot at p50 0.17 ms once Content-Length was set — indistinguishable from Woo, and
anyone can re-run it. The case for a native server is control and coherence, not speed, and
claiming otherwise would be falsified by our own benchmark.

Amend or supersede this ADR once the desktop path actually runs on the native server.

**What the clarification changes.** [ADR-0002](../../../aion/docs/adr/0002-libuv-integration-strategy.md)
gave pre-publication issue 117 an explicit exit condition — *if the HTTP security surface outgrows the maintainer,
fall back to Hunchentoot or Clack over our own socket layer.* That exit still exists, but it
is now the **unwanted** branch rather than a neutral one, and its cost should be priced
accordingly: taking it means keeping a dependency the maintainer intends to remove.

It also decides the shape of pre-publication issue 139.
The fix is **not** "make hyperion depend on Hunchentoot instead of Woo" — that swaps one
permanent third-party server for another. It is that **hyperion should stop declaring a
server backend at all** and let the application choose, the way every other opt-in aux
system in this tree works. Then the native server arrives as one more choice rather than as
surgery on the framework, and removing Hunchentoot later is an app-level edit.

**An open question falls out of it:** does **Clack** survive? Routing already yields a Clack
handler (`to-app`, ADR-0012), so today the abstraction is load-bearing. A native libuv server
could implement a Clack handler — keeping every existing app working — or bypass Clack
entirely. Those are different amounts of work and different amounts of freedom, and pre-publication issue 117
should answer it deliberately rather than by accident.