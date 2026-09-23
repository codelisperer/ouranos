# ADR-0017 — The native `:uv` server becomes the default backend

**Status:** Proposed — 2026-09-13. Amends
[ADR-0011](0011-desktop-server-backend-and-content-length.md), whose backend half was
explicitly a waypoint: *"Amend or supersede this ADR once the desktop path actually runs on
the native server."* ADR-0011's Content-Length half is untouched and stands permanently.

## Context

[#117](https://github.com/codelisperer/ouranos/issues/117) M2 lands the native libuv server —
framing, timeouts, concurrency and streaming
([#241](https://github.com/codelisperer/ouranos/pull/241),
[#270](https://github.com/codelisperer/ouranos/pull/270)). ADR-0011 chose Hunchentoot for
desktop bundles to remove libev, and the maintainer clarified on 2026-08-05 that this was a
stop-gap: Hunchentoot and Woo are both to be removed as dependencies once #117 exists.

The flip is mechanical. `hyperion/src/server.lisp:22`:

```lisp
(defparameter +backends+
  '((:woo         . "CLACK.HANDLER.WOO")
    (:hunchentoot . "CLACK.HANDLER.HUNCHENTOOT")
    (:uv          . "HYPERION/SERVER-UV")))
```

`%choose-server` takes *the first available* when nothing is requested, so this order **is**
the default, and `:uv` is last. `server.lisp:41` already records the pending decision in
prose — `HYPERION_SERVER=uv` … *"and not yet selected: making it the default is a…"*.

One line of code with that much anticipation behind it should carry a written decision rather
than ride in on a commit.

## Decision

1. **`:uv` moves to the head of `+backends+`**, becoming the default when nothing is
   requested. `HYPERION_SERVER` and `:server` keep working; ADR-0011's escape hatch is
   untouched.
2. **Desktop targets `:uv` on every platform.** This is the point of the exercise — Windows
   desktop stops needing Hunchentoot. The platform asymmetry ADR-0011 removed by
   standardising *on* Hunchentoot is now removed by standardising off it.
3. **The flip does not happen until both preconditions land:**
   - [#273](https://github.com/codelisperer/ouranos/issues/273) — `%body-octets` has no
     `pathname` clause, so `hyperion/static` 500s on `:uv`. It returns a pathname for every
     file it serves; only `hyperion/assets` (octet vectors) works today, which is why this
     has stayed invisible.
   - [#274](https://github.com/codelisperer/ouranos/issues/274) — `desktop-release.yml`
     ships no libuv, so a `:uv` bundle would carry a runtime dependency it does not contain.
     Works on every build machine, fails on a user's.

     **Landed as [#310](https://github.com/codelisperer/ouranos/pull/310), and what it
     delivers is narrower than "#274 is closed" implies.** The workflow half is complete:
     every `desktop-release` leg now builds the pinned libuv, so a **CI-produced** release
     carries it. The guarantee half — `wake-lazy-natives` refusing to build a bundle that
     needs a native it cannot carry — has a hole
     ([#325](https://github.com/codelisperer/ouranos/issues/325)): it refuses only when the
     waker *errors*, so on a host with a **system** libuv the library resolves, is correctly
     declined as not ours to carry, and the guard is satisfied. The bundle ships without it.

     That is this precondition's own failure mode, surviving inside the fix for it — an
     artifact that works on every build machine and fails on a user's. It does not gate the
     flip, because the flip concerns released bundles and those are built by CI. It **does**
     gate telling anyone to build their own, and it must be closed before this ADR is
     Accepted.

     Why it was reported as complete: #310 measured all three directions on **Windows**,
     where there is no system libuv, so "resolves here" and "will be carried" coincide. The
     hub relayed that measurement as a general guarantee. It was found on macOS, by the
     ticket ([#312](https://github.com/codelisperer/ouranos/issues/312)) filed specifically
     to ask what the Windows verification could not see.
4. **Removing Hunchentoot and Woo as dependencies is a separate, later change.** Changing the
   default and deleting the alternatives are different risks. The second should follow a
   period in which `:uv` is the default and the others still work.

## Consequences

- **Windows loses its last need for a third-party HTTP server**, which was the goal.
- **libuv becomes a runtime dependency of the desktop artifact.** ADR-0013/0014 settled the
  mechanism; #274 is the workflow actually doing it.
- **The default changes silently for existing apps.** An app that never set
  `HYPERION_SERVER` and happened to get Woo now gets `:uv`. `start` should log which backend
  it selected and why, so the change is visible in a log rather than inferred from behaviour.
- **`:uv` becomes the exercised path.** An opt-in backend is an under-tested one. The CI
  `verify` matrix already runs `windows-2022` with `OURANOS_WITH_UV=1` and includes
  `hyperion/server-uv/tests`, so the native server is covered on the platform that matters
  most *before* it becomes the default.
- **ADR-0011's backend half is superseded.** Its Content-Length half stands, and its rule
  that pathname and function bodies stay chunked is now *more* load-bearing, since `:uv` is
  the code that has to honour it.

## Alternatives considered

- **Flip now, fix static afterwards.** Rejected. Static files would 500, and the failure is
  invisible to any app serving only embedded assets — the exact shape of bug that reaches a
  user rather than a developer.
- **Flip for desktop only; leave server deployments defaulting to Woo.** A real option, and
  the narrower one, since the stated goal is desktop. Rejected as the *end* state because it
  keeps two defaults and two code paths — but a reasonable intermediate if #274 proves slow,
  as desktop is where the Hunchentoot dependency actually hurts.
- **Leave `:uv` opt-in indefinitely.** Rejected: it contradicts ADR-0011's clarified
  direction, and an opt-in default leaves the native server the least-exercised path in the
  tree while third-party servers stay load-bearing.

## What this decision does *not* carry

**TLS.** Neither backend terminates it — not `:uv`, and not the Clack handlers either. There
is no mention of TLS, SSL or certificates in `server-uv.lisp`, anywhere under `aion/src/uv/`,
or in `server.lisp`. HTTPS today comes from a reverse proxy or a cloud load balancer, and
that is unchanged by this decision: `:uv` loses nothing, and gains nothing.

Said plainly because the rest of this ADR reads as though the native server is a complete
replacement for Hunchentoot, and on this axis both are equally empty — a reader planning an
**on-prem** deployment would reasonably infer a capability neither has. Termination is
[#292](https://github.com/codelisperer/ouranos/issues/292); an ACME client for it is
[#294](https://github.com/codelisperer/ouranos/issues/294). Neither gates this flip.

## What this decision does *not* rest on

**Performance.** ADR-0011 measured Hunchentoot at p50 0.17 ms once Content-Length was set —
indistinguishable from Woo, and anyone can re-run that benchmark. The case for the native
server is control and coherence: owning the async substrate, no unvendorable native
dependency, the typed interceptor pipeline all the way down. Claiming speed would be
falsified by our own numbers.

## Provenance

The preconditions came from a lane that went looking rather than estimating. Asked what
remained before `:uv` could be the default, it read `%body-octets` against
`hyperion/static`'s actual return type, and `desktop-release.yml` against ADR-0013/0014, and
found two gaps neither M2 branch touches.

**A third reported gap did not survive verification, and that is the part worth recording.**
HEAD was reported as unhandled everywhere — not in the parser, encoder, server, or any test —
which would have been a third precondition, and a desynchronised keep-alive connection is the
failure class this stack spends its length preventing. It is false. `router.lisp` matches
HEAD to a GET route and strips the body, and `router-tests.lisp` asserts status, headers and
an empty body. It is correct for streaming too, non-obviously: `%strip-body` runs in the
*router*, so a function body is replaced by `'()` before `server-uv` evaluates
`(functionp body)`, and `%stream-response` is never entered.

The report came from grepping `hyperion/` for `head`, which matches `h1:head-method`,
`parse-head`, `max-head-octets` and `encode-head-flat` — the **message head**, not the
method. The hits look like coverage and are not; the first verification pass made the same
mistake, reported eleven of them, and caught it only on reading the matched lines.

Two lessons priced into this ADR. A finding about an absence has to name the symbol it
searched for, because the near-miss is a homograph. And every entry in the preconditions list
was checked against the branch head (`8a63a9b`), not `main` — #270 rewrites `%body-octets`,
so `main` would have proved nothing about either the defect or its absence.
