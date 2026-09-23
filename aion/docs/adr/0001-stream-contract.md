# ADR-0001 — The stream contract: backpressure, NODELAY, and loop introspection

**Status:** Proposed — 2026-08-04. Written **before** the implementation
(pre-publication issue 118), which is the point: two of
these are cheap now and expensive to retrofit.

**Sits under [ADR-0002](0002-libuv-integration-strategy.md)** (the libuv integration
strategy — why we bind at all, what we will never bind, and when we would stop). This ADR
decides only the *stream* surface; the founding binding decisions are in
[`../uv-design.md`](../uv-design.md) §"The five decisions" and the placement rule is in the
[`ECOSYSTEM.md`](../../../ECOSYSTEM.md) log.

## Context

`aion/uv` binds libuv's loop, filesystem, timers and file watching. **Streams — TCP, pipes
— are the largest remaining surface**, and the one an HTTP server needs
(pre-publication issue 117).

Node.js is the reference implementation of getting this wrong first. It shipped streams
three times — streams1 (2010), streams2 (2012), streams3 (2013) — and the reason each time
was the same: **backpressure was advisory.** A fast producer could outrun a slow consumer,
and nothing in the API stopped it. The result was lost data and unbounded memory, in
production, for years.

We know this in advance. There is no excuse for rediscovering it, and the cost of designing
it in now versus retrofitting it later is the entire content of Node's three rewrites.

Two smaller items belong with it, for the same reason — both are cheap at design time and
awkward afterwards.

## Decision

**1. Backpressure is half the read API, not an addition to it.**
`read-start` ships with `read-stop` in the same commit, and a consumer can pause and resume
a stream. The write side exposes the queue depth (`uv_stream_get_write_queue_size`) and
signals drain. **Composition must carry backpressure without the caller wiring it** — the
common case is read from A, write to B, and if that path requires manual coordination
nobody will do it correctly. That composed case is an acceptance criterion, not a
follow-up.

**2. `TCP_NODELAY` is set on our sockets, and the API says so.**
Not a tuning knob discovered later. [hyperion ADR-0011](../../../hyperion/docs/adr/0011-desktop-server-backend-and-content-length.md)
measured a **44 ms delayed-ACK floor** on every keep-alive request, fixed the buffered case
with `Content-Length`, and recorded an unexplained **p99 ~40 ms residual**. Crucially,
**streamed responses cannot carry a `Content-Length` by definition**, so the SSE progress UI
(pre-publication issue 76) is still exposed to that floor
and the existing fix cannot help it. Owning the socket is what makes this fixable at all.

**3. `uv_walk` is bound, with a `describe-loop` reader.**
*"Why won't my process exit?"* is Node's single most common debugging complaint, and its
answer is nearly always a live handle holding the loop open. Node users reach for
`async_hooks` or third-party tools. We can walk the live handles **from a REPL attached to a
running image** — one binding plus a printer. This turns their worst-known pain into
something we demo. It is also why **every handle type must document whether it holds the
loop alive** (`uv-ref`/`uv-unref` are already exported).

**4. Errors escaping stream callbacks are kept, not swallowed** — into `*callback-errors*`,
exactly as the existing callbacks do. Streams add many more callbacks; the rule does not
change, and the existing behaviour is already ahead of Node's history here (error-first
callbacks → unhandled `'error'` events crashing the process → silently-swallowed promise
rejections).

Rules 1–5 of [`../uv-design.md`](../uv-design.md) continue to bind unchanged. Streams add
handle *kinds*, not new lifecycle or threading rules.

## Consequences

- The read API is larger on day one, and the first implementation is slower to write.
  That is the trade, taken deliberately.
- `uv_walk` invokes a callback per handle, so the existing callback discipline applies to
  introspection too — a printer that signals would take the loop with it.
- A `describe-loop` reader is user-facing surface we then have to keep working. Worth it.
- **This ADR does not decide the HTTP layer.** Parsing, keep-alive and the request/response
  model are hyperion's, per the ECOSYSTEM rule that bindings follow the DAG while
  abstractions follow the domain.

## Alternatives considered

- **Advisory backpressure, tightened later.** Precisely Node's mistake, with the outcome
  already known. Rejected.
- **`TCP_NODELAY` as an option, defaulting off.** Defensible in general; wrong here, because
  we have a *measured* defect it addresses and a class of response (streamed) that no other
  fix reaches.
- **Skip `uv_walk`; add diagnostics when someone asks.** The moment someone asks is the
  moment they are already stuck and unable to see why — which is exactly the situation Node
  users are in when they go looking for `why-is-node-running`.

## Provenance

The founder asked for a review of Node's libuv practice specifically because *"Node's
wrapping of libuv is what put it on the map"* and ours should be industrial-strength too.
That review is what produced this ADR: the three items above are Node's scar tissue rather
than our own preferences, and the reason to write them down **before** pre-publication issue 118 is that all
three are cheap now and were, historically, very expensive later.

It also caught something worth recording about process rather than code: these constraints
had been captured only in a **GitHub issue comment**, which does not travel with a clone.
The founder asked whether the uv decisions were in an ADR — they were not, and "backpressure"
appeared nowhere in the tree at all. Hence this file, and hence `aion/docs/adr/`, which did
not exist until now.
