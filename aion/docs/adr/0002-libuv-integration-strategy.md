# ADR-0002 — libuv integration strategy: one async substrate, bound but not abstracted

**Status:** Provisional — 2026-08-04. The umbrella
[ADR-0001](0001-stream-contract.md) sits under; numbering is chronological, not
hierarchical.

## Context

Ouranos now carries a native library. That is unusual for a Common Lisp project and it is a
standing commitment, not a one-off binding — so the strategy deserves stating in one place
rather than being reconstructed from seven issues and a design doc.

The forcing question was narrow: desktop bundles died on a clean machine with
`libev.so.4: cannot open shared object file`, a transitive native dependency of Woo. The
cheap answer was to switch servers ([hyperion ADR-0011](../../../hyperion/docs/adr/0011-desktop-server-backend-and-content-length.md),
which did exactly that). The expensive answer was to notice that **the tree already needs
async I/O in five places and solves it five different ways**: a polling file watcher in
`hyperion/dev`, `uiop:run-program` blocking for `cons` build targets, whatever the HTTP
server brings, CL-DBI's sockets under mnemosyne, and threads-plus-hope for concurrent LLM
calls in praxeon.

That is the actual problem. libuv is one answer to all five.

## Decision

**1. One async substrate, not five per-domain solutions.**
libuv is bound once, in aion, and every framework that needs an event loop, a socket, a
subprocess, a timer, or a file-change notification uses that binding. The alternative is
what we have now, and what we have now is why a desktop bundle could not start.

**2. Bind the OS surface; never bind policy.**
The binding is thin, faithful, and 1:1 — its specification is libuv's own documentation.
Two standing exclusions, both permanent:

- **`uv_queue_work` is never bound.** Its work function runs on a genuinely foreign
  threadpool thread, which would break the invariant that Lisp is only ever re-entered on
  stacks SBCL created ([`../uv-design.md`](../uv-design.md) §5). SBCL has real threads; we
  do not need libuv's.
- **No protocol semantics in aion.** HTTP parsing, keep-alive, request/response modelling
  belong to hyperion. Aion decodes libuv; it does not decide what bytes mean.

**3. Placement follows the DAG, abstractions follow the domain.**
Recorded in the [`ECOSYSTEM.md`](../../../ECOSYSTEM.md) decisions log and not restated here.
The consequence for uv specifically: `aion/uv` (loop, fs, timers, watch), `aion/uv/net`
(streams, DNS — [#118](https://github.com/codelisperer/ouranos/issues/118)), `aion/uv/process`
(spawn, signals — [#119](https://github.com/codelisperer/ouranos/issues/119)); the HTTP
server in hyperion ([#117](https://github.com/codelisperer/ouranos/issues/117)).

**4. Sequenced so each step is provable before the next depends on it.**
Filesystem, timers and watching first — no protocol, testable in isolation, and they gave us
the callback discipline and the handle registry that everything after reuses. Then streams,
then processes, then HTTP. **The server lands desktop-first**: single user, localhost, no
hostile traffic, and the place a third-party dependency hurts most (bundling). Server
deployments stay on Woo or Hunchentoot until the native path has earned them.

**5. Opt-in, permanently.**
`aion/uv` is never in core aion's dependency set; core aion stays `coalton` + `alexandria`.
This is not tidiness — it is what makes a platform gap survivable. It is why `aion/uv` could
merge to `main` while **unproven on Windows** without exposing anyone who had not asked for
it, and it is the property that must not be traded away later for convenience.

**6. Built from source, pinned, on the OS's own toolchain.**
See [`../uv-design.md`](../uv-design.md) §1–2 and the ECOSYSTEM entry on native code. Not
restated.

## Consequences

- **Aion must be correct on three platforms, and aion is leftmost in the DAG.** Accepted
  deliberately; mitigated only by (5). It also puts the Windows work
  ([#107](https://github.com/codelisperer/ouranos/issues/107)) on more than one framework's
  critical path.
- **If #117 proceeds, we own an HTTP security surface** — request smuggling, header
  injection, slowloris, chunked-encoding edge cases. That is a standing obligation, not a
  one-time cost, and it is the strongest argument for a Coalton parser with exhaustive state
  handling rather than a hand-rolled CL state machine.
- Anyone opting into `aion/uv` needs a C compiler once. Nobody else needs one ever.
- Five subsystems eventually depend on one binding. A defect in it is a defect everywhere —
  which is the cost side of the coherence this ADR buys.

## When we would stop

A strategy without an exit is a commitment, not a plan. Two, stated in advance:

- **If the HTTP surface outgrows the maintainer** — the security obligation above is real
  and unbounded — fall back to Hunchentoot or Clack *over our own socket layer*. The
  binding keeps its value; **the server is the optional part.** #117 is the piece to
  abandon, not #118.
- **If Windows cannot be made to work on the OS toolchain**, revisit the platform matrix —
  but do **not** resolve it by taking MSYS2. That trade was considered and rejected on
  adoption grounds, and reversing it silently would undo the point.

## Alternatives considered

- **`cl-libuv` / `cl-async`.** Grovel-based, which puts a C toolchain on the *load* path of
  every dependent system — the specific thing we are trying to escape. Rejected.
- **Keep libev via Woo.** The status quo that produced unrunnable Linux and macOS bundles.
- **Switch servers and stop there** (ADR-0011's original conclusion). Correct given the
  options at the time; it fixes the bundle and leaves the five-different-ways problem
  untouched.
- **Per-domain libraries** — a file-watcher library, a process library, a socket library.
  More dependencies, none of them shareable, each with its own platform gaps. This is the
  arrangement libuv exists to replace.

## Provenance

This ADR exists because the founder **rejected ADR-0011's framing rather than its answer.**
That ADR concluded "Hunchentoot everywhere for desktop," largely because it drops libev. The
pushback: if the real objection is an unvendorable native dependency, the alternative is not
picking the other third-party server — it is owning the async substrate.

Worth recording precisely, because the reasoning is not recoverable from the outcome: the
decision was **not** made on performance. ADR-0011 measured Hunchentoot at p50 0.17 ms once
`Content-Length` was set, indistinguishable from Woo, and anyone can re-run that benchmark.
The case is coherence and control. Claiming a speed benefit would be falsified by our own
measurement.
