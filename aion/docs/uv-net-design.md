# aion/uv/net — stream transport over libuv

Companion to [uv-design.md](uv-design.md), which covers the loop, filesystem, timers and
watching. This is the **transport** sub-system: TCP, pipes and asynchronous DNS.

**Transport only.** Nothing here knows what HTTP is. That is not an omission — it is the
line the ECOSYSTEM decisions log draws (2026-08-04, pre-publication issue 117): *native bindings follow the
DAG, abstractions over them follow the domain*. A binding's specification is the C
library's own documentation; an abstraction makes a choice the C library does not make
for you. HTTP parsing and the request/response model are choices, and they belong to
hyperion.

## Why this lives in aion

Everything that wants a socket sits to aion's **right** in the DAG:

| consumer | position | wants |
|---|---|---|
| `cons` | 2 | subprocess pipes (pre-publication issue 119) |
| `mnemosyne` | 3 | the Postgres wire protocol |
| `hermes` | leaf, depends on aion *only* | its own HTTP client |
| `hyperion` | 5 | the native HTTP server (pre-publication issue 117) |

Put TCP in hyperion and the first three become DAG violations. There is no version of
this where transport lives at position 5.

Granularity comes from **sub-systems, not from splitting the binding across frameworks**:
`aion/uv` (loop, fs, timers, watch), `aion/uv/net` (streams, DNS), `aion/uv/process`
(spawn, signals, next). A consumer takes only what it needs, and the shared loop, pointer
registry, callback guard and error decoding are never duplicated. That reuse is exactly
why the binding cannot be split across frameworks — and it is why `aion/uv` now exports a
documented **sub-system substrate** (`check`, `register`/`lookup`, `with-callback-guard`,
`close-pointer`, the future constructors). A shared substrate has to be nameable to be
shared.

Accepted cost, stated plainly: **aion must now be correct on all three platforms**, and it
is leftmost in the DAG. Mitigated by these staying opt-in — core aion is still `coalton` +
`alexandria`, and `aion/uv/net` loads fine with no libuv present.

## Backpressure is the design, not a feature of it

Node shipped streams three times — 2010, 2012, 2013 — because the first two made
backpressure **advisory**. A fast producer outran a slow consumer, the queue between them
grew without bound, and the process died. Being *able* to ask "is the consumer keeping
up?" does not help when nothing enforces the answer.

Three consequences, all present from the first commit rather than added later:

1. **`stop-reading` is half of `start-reading`, not an extra.** libuv gives us
   `uv_read_stop` precisely so a reader can shut the tap. A binding exposing only
   `read_start` has reimplemented the 2010 mistake with different syntax. `pause-reading`
   / `resume-reading` are the documented pair.
2. **The write queue is observable.** `uv_stream_get_write_queue_size` is the signal —
   the same number Node surfaces as `writable.writableLength` — and `write-queue-size` /
   `saturated-p` expose it directly.
3. **`pipe-into` owns the policy.** The composed case (read from A, write to B) is the one
   that matters, and an API where the caller must remember to pause is an API where the
   caller does not. So the composition pauses the source at the high-water mark and
   resumes it at the low one, with nothing buffered in Lisp in between.

The two marks are **deliberately different numbers** (64 KB and 16 KB by default).
Resuming at the level you paused at means pausing again on the very next write; the gap is
what stops the pair oscillating, and it is why `drained?` takes a separate threshold from
`saturated?`.

## TCP_NODELAY, and why owning the socket is worth something

Set **by default** on every connection made here, inverting the C default deliberately.

Nagle's algorithm coalesces small writes; delayed ACK waits before acknowledging. Together
they add tens of milliseconds to a request/response exchange for no benefit. ADR-0011
measured exactly that — a **44 ms floor** — and fixed the part `Content-Length` could fix,
leaving a **p99 residual**. A *streamed* response cannot carry a `Content-Length` by
definition, so the fix does not reach it at all, which leaves the SSE progress UI (pre-publication issue 76)
exposed.

`uv_tcp_nodelay` is what closes it, and you can only call it if you own the socket. That is
a concrete reason to own the socket rather than an abstract one — and note that it is a
*control* argument, not a speed one. ADR-0011 measured Hunchentoot at p50 0.17 ms
post-fix. Nobody should claim this stack is faster; the honest claim is that it is ours.

## The typed core

`nread` is the most overloaded number in libuv: one signed integer delivered to every read
callback that means four different things.

| value | meaning |
|---|---|
| `n > 0` | this many bytes are in the buffer |
| `n == 0` | nothing was read, **and that is not an error** (the EAGAIN case) |
| `n == UV_EOF` | the peer is finished — an ordinary, expected end |
| `n < 0` otherwise | a real failure |

The classic bug is treating end-of-stream as a failure, because both are negative. `ReadOutcome`
makes the four unmergeable, and dispatch is on libuv's error **name** (`"EOF"`), never its
number — the numbers are platform errnos, the names are libuv's. The backpressure decision
and the IPv4/IPv6 classification of an address literal live beside it, both pure, both with
monomorphic CL-callable renderers so callers who never write Coalton still get decoding
that was type-checked.

## Two platform facts, one guarded exception

**The port is a big-endian `uint16` at offset 2** — every address family, every platform.
This looks like the kind of assumption that breaks somewhere, and it does not, for a
structural reason:

```
Linux/Windows  sockaddr_in { uint16 sin_family;              uint16 sin_port; }
macOS/BSD      sockaddr_in { uint8 sin_len; uint8 sin_family; uint16 sin_port; }
```

The BSD variant *splits* the first two bytes rather than adding any, and `sockaddr_in6` has
the identical prefix in both. Everything else about an address comes from libuv's own
`uv_ip_name`, which renders either family without us reading `sa_family` — the one field
whose layout genuinely differs.

**`struct addrinfo` is the exception to the no-grovel rule**, and the only hand-written
*platform* struct in the binding. It is unavoidable: the getaddrinfo callback hands us the
head of a linked list and libuv publishes no accessor for walking it. Its field order
genuinely differs — Linux puts `ai_addr` before `ai_canonname`, BSD and Windows reverse
them. Both layouts are written out, and `%check-addrinfo` proves the guess fits **before
dereferencing**: on a wrong layout `ai_addr` reads whatever `ai_canonname` holds, which
without `AI_CANONNAME` is a null pointer. Testing for that turns a mis-assumed platform
into an error message instead of a segfault.

## Why DNS has no truly synchronous form

`uv_fs_*` with a NULL callback runs inline and **returns** the answer, which is why
`read-file` needs no loop. `uv_getaddrinfo` with a NULL callback also runs inline — but
leaves its answer in `req->addrinfo`, and libuv publishes no accessor for that field.
Reading it would mean hand-writing the layout of `uv_getaddrinfo_t`, a struct with a whole
request header in front of the field we want: exactly the guess the no-grovel rule forbids.

The **async** callback is handed `struct addrinfo* res` as a parameter, no layout knowledge
required. So the async path is the real one, and `resolve` is a convenience that runs a
private loop around it. That costs a loop setup per call and is stated rather than hidden —
resolving many names should use `resolve-async` on a loop you already run.

## Gotchas for the next person

- **Chunk boundaries are not message boundaries.** TCP is a byte stream: one write by the
  peer may arrive as three chunks, or three writes as one. Framing belongs to whatever
  protocol is layered on top, and assuming otherwise is the bug that appears only under
  load.
- **Hostnames are refused, not resolved.** `connect-tcp` takes an IP literal. Hiding DNS
  inside `connect` would make an invisible network call — with its own latency and failure
  modes — on a function that looks local. Use `resolve` first.
- **An uninitialised handle is freed; an initialised one is closed.** Once `uv_tcp_init`
  succeeds the handle belongs to the loop, and `foreign-free` on it is a use-after-free
  that surfaces later as unrelated corruption. The two failure paths in `%accept` sit on
  opposite sides of that line and are written out separately for that reason.
- **`shutdown-write` then `close-handle` yields ECANCELED**, because closing cancels the
  pending shutdown request. This is correct, ordinary teardown. It arrives through the
  future rather than on `*error-output*` — the future is the error channel for anything
  returning one, matching `fs.lisp`. Pass `:on-error` if you are not awaiting it. An error
  that *escapes a handler*, by contrast, is a bug and is still kept in
  `uv:*callback-errors*`.
- **A pipe has no socket address.** `local-address` / `peer-address` are TCP-only and
  refuse a `uv_pipe_t` with a reason rather than returning nonsense.
- **Every handle here holds the loop open while active.** That is what makes `run` not
  return. Ask `(uv:describe-loop l)` — it names the Lisp object, not merely the handle
  type, which is the live-image answer to Node's most famous debugging complaint.

## What is not built yet

- **UDP** (`uv_udp_t`) and **TTY**. No consumer is asking yet.
- **TLS.** libuv does not provide it; it is a separate decision (and a separate
  dependency) whenever a consumer needs it.
- **`uv_queue_work`.** Still deliberately unbound — its work function runs on a genuinely
  foreign threadpool thread, the one place the "callbacks only on SBCL-created threads"
  rule would be violated.
- **Verification on macOS and Windows.** The suite passes on Linux/WSL against a real
  libuv. Nothing here has been run on the other two, and two things are most likely to
  need attention there: the `struct addrinfo` field order (guarded, so it fails loudly)
  and named-pipe semantics, which on Windows are genuinely different from unix domain
  sockets. That is the CI matrix's job (pre-publication issue 87).
