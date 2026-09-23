# ADR-0015 — Keep the Ring calling convention; drop the Clack library

**Status:** Accepted — 2026-08-27

## Context

[ADR-0011](0011-desktop-server-backend-and-content-length.md) settled the desktop server on
Hunchentoot and then left one question open on purpose:

> **An open question falls out of it:** does **Clack** survive? Routing already yields a Clack
> handler (`to-app`, ADR-0012), so today the abstraction is load-bearing. A native libuv server
> could implement a Clack handler — keeping every existing app working — or bypass Clack
> entirely. Those are different amounts of work and different amounts of freedom, and pre-publication issue 117
> should answer it deliberately rather than by accident.

pre-publication issue 117 is now framed by the maintainer as
removing third-party HTTP servers *as a dependency entirely* — "third-party servers are an
application choice, never a framework dependency." **If that is the aim, Clack is a third-party
dependency too**, and it is reached only so that hyperion can talk to itself.

This ADR answers the delegated question before any of Milestone 1's code is written, because
every later commit rests on it.

## What is actually there

Measured against the tree at `f79ea4e`, not recalled:

- **The Clack *API* is used in exactly one file.** `hyperion/src/server.lisp`, two call sites:
  `clack:clackup` and `clack:stop`. Nothing else in the framework calls Clack at all.
- **`to-app` does not produce a Clack object.** It produces a closure
  `(lambda (env) -> (status headers body))`. That is the **Ring/Lack calling convention** — a
  shape, not a library. Handlers, middleware and the router all speak it directly.
- **Hyperion consumes exactly nine env keys**, enumerated across `hyperion/src/`:

  | key | key | key |
  |---|---|---|
  | `:request-method` | `:content-length` | `:raw-body` |
  | `:path-info` | `:content-type` | `:remote-addr` |
  | `:query-string` | `:headers` (hash table, lowercased string keys) | the router's `+params-key+` |

That is the entire contract. A server that synthesizes those nine keys and consumes the
response triple is indistinguishable, to every line of hyperion above `server.lisp`, from Clack.

## Decision

**Adopt the calling convention as hyperion's own; drop the library.**

1. The native server (`hyperion/server-uv`) **synthesizes the nine keys directly** and consumes
   the `(status headers body)` triple directly. It does **not** implement a `clack.handler.*`
   backend.
2. The convention is documented as **hyperion's**, described as Ring/Lack-shaped, rather than as
   "the Clack env". Compatibility with Clack becomes a happy consequence of a shared shape, not
   a dependency.
3. **`clack` leaves `hyperion.asd` in M4** — after the native path has earned trust, not before.
   Until then both paths coexist and `:uv` is opt-in via `HYPERION_SERVER`.
4. **The parser is its own pure system, `hyperion/http1`**, separate from `hyperion/server-uv`.

### Why the parser is split out (4)

Not tidiness — evidence. `scripts/verify-tree.lisp` **deliberately excludes `aion/uv*`**, because
those systems need a C toolchain and a built `vendor/libuv`. If the HTTP parser lived inside the
transport system, **the most security-critical code in the tree would sit outside the checker
`AGENTS.md` names as the standard of evidence.** Pure-and-separate puts it back inside, and makes
the parser reusable by the outbound HTTP client and by hermes later.

This is an architectural constraint, not a packaging preference, and it will not be obvious to
whoever next wonders why the parser is a separate system.

## Consequences

- **No application changes.** No application ever touched Clack — only `hyperion/server:start`
  did. Apps keep writing `(lambda (env) ...)` handlers exactly as they do today.
- **The nine keys become a contract we own, and must keep.** Previously Clack defined them and
  drift was impossible; now a missing key is our bug. The server-uv suite asserts each one.
- **We own the socket, which is the point.** `TCP_NODELAY` on every accepted connection addresses
  the residual **p99 ~40 ms** straggler ADR-0011 recorded and explicitly could not reach through
  Clack ("it may argue for setting `TCP_NODELAY` on the listening socket as well").
- **M4's removal is larger than pre-publication issue 117's proposal stated, and this is the correction.** That
  proposal said "Clack appears in exactly three files." The *API* surface is one file, but the
  **dependency** surface is six declarations across six systems — `hyperion` (`clack`), plus
  `clack-handler-hunchentoot` in `hyperion/tests`, `hyperion/assets/tests`, and three example
  apps — and roughly a dozen docstrings in `hyperion/src/packages.lisp` that teach the
  convention using the word "Clack". Removing the library means editing all of them; the
  docstrings are user-facing vocabulary, so leaving them would make the framework describe
  itself in terms of a dependency it no longer has.
- **We inherit HTTP as a security surface permanently.** ADR-0002's standing obligation now has
  a named owner. The parser-level floor (smuggling, splitting, header limits) is specified in
  pre-publication issue 117 §4 and is not optional.

## Alternatives considered

**Implement a real `clack.handler.uv`.** Every existing app keeps working with zero risk, and
the native server slots in behind an abstraction that already exists. Rejected because it keeps
a third-party dependency in the framework *in order for the framework to talk to itself* — the
exact thing pre-publication issue 117 exists to stop — and because Clack's handler protocol would then constrain the
streaming and concurrency decisions M2 has to make freely.

**Keep Clack and add the native server beside it, indefinitely.** Cheapest, and dishonest: it
declares the dependency removed while shipping it.

**Invent a new request/response shape.** Rejected quickly. The Ring shape is good, every CL web
library speaks it, and a novel vocabulary would strand apps and reviewers for no gain.

## Provenance

The measurement that shaped this was small and decisive: **the Clack API surface is two calls in
one file.** The decision felt large while it was described as "does Clack survive"; it became
easy once the code was counted rather than remembered.

The counter-check mattered more than the check. Writing this ADR, the claim inherited from
pre-publication issue 117's approved proposal — *"Clack appears in exactly three files"* — was re-run against the
tree and **did not hold**. It conflated the API surface with the dependency surface: one file
calls Clack, but six systems declare it. The decision is unchanged and slightly strengthened;
what changed is M4's cost, which would otherwise have been discovered mid-removal. Recorded
because an approved plan is exactly the kind of claim that stops being re-checked.

Also worth keeping: performance is **not** a justification here and is not claimed as one.
ADR-0011 measured Hunchentoot at p50 0.17 ms once Content-Length was set, indistinguishable from
Woo, and anyone can re-run it. The case is control and coherence. `TCP_NODELAY` fixes a specific
recorded defect; it is not a speed argument for the project.
