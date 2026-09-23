# Signals and shutdown — what works, what does not, and which backend loses SIGTERM

Written while implementing `serve-forever` (pre-publication issue 124),
because the SIGTERM half did **not** work on the current server and the evidence is worth
more than the attempt. Read this before implementing signal handling in
pre-publication issue 117 (the native libuv server) or
[#37](https://github.com/codelisperer/ouranos/issues/37) (the `service` target).

**Updated 2026-08-29 (pre-publication issue 117):** the open question is closed. The matrix is complete, the cause
is located, and the fix this file used to prescribe is no longer needed. The harness that
settled it is in the tree:

```sh
hyperion/bench/signals/run.sh 3     # every backend, both modes, 3 runs each
```

One cell remains unmeasured — Windows. macOS was filled by pre-publication issue 218 (see below); that script is
how to fill the last one.

## The short version

| Stop path | Status |
|---|---|
| `Ctrl-C` at a terminal | **works** on every backend |
| `request-shutdown` (any thread) | **works** — sets a flag the wait loop polls |
| An unhandled condition | **works** — `unwind-protect` releases the socket |
| **`SIGTERM`** | **works on Hunchentoot and on the native server. Lost on Woo.** |

**The defect is Woo's, not `serve-forever`'s, and not "a running server's".** That was the
open question when this file was written and it is now settled by measurement (§*The probe*
below). `serve-forever` needs no change, and the `uv_signal_t` installer this document used
to prescribe is **not required** — the ordinary POSIX handler already works under the native
transport.

`SIGTERM` is how a container runtime, systemd, `kill`, and every process supervisor ask for a
clean exit. So the practical rule is short: **a deployed app must not run on Woo.**

## What was measured

All on macOS 15 / Apple silicon, SBCL 2.6.5, one `sb-sys:enable-interrupt` handler on
`sb-unix:sigterm` that does nothing but `setf` a flag.

| Configuration | Signal sent from | Handler fired? |
|---|---|---|
| No server at all, main thread parked in `sleep` | another thread | **yes** |
| No server at all, main thread parked in `sleep` | an external process (`/bin/kill`) | **yes** |
| Woo started, main thread at toplevel | the main thread itself | **yes** |
| **Inside `serve-forever`, Woo started** | **another thread** | **no** |

The mechanism is therefore sound in isolation — SBCL delivers `SIGTERM` to a handler while
the main thread sleeps, from another thread and from another process. What the original
round could not say was whether the loss needed `serve-forever` or only needed Woo.

## The probe — the empty cell, filled

Linux/WSL (kernel 6.18, SBCL 2.6.7), 2026-08-29. The isolating probe reproduces everything
**except** `serve-forever`: same handler shape as `%install-posix-signal-handlers`, installed
before the server starts, same poll-over-`sleep` wait, signal sent by `/bin/kill` from the
driving shell. **Three runs of every cell; all 21 agreed.**

| Backend | main thread parked, **not** `serve-forever` | inside `serve-forever` |
|---|---|---|
| none (control) | **FIRED** | — |
| **Woo** | **TIMEOUT** | **TIMEOUT** |
| Hunchentoot | **FIRED** | **FIRED** |
| **native (`:uv`)** | **FIRED** | **FIRED** |

Three things follow, and the first is the one this file was waiting for:

1. **It reproduces outside `serve-forever`.** By this document's own stated criterion, the
   fault is therefore *entirely in the transport* and nothing in `hyperion/server` needs to
   change. The hypothesis below is confirmed.
2. **It is Woo specifically, not "a running server".** Hunchentoot runs a server on a thread
   and keeps the signal. So the shape of the defect is libev's handling of the process signal
   mask, not the presence of a listener or of a background thread.
3. **The native server does not have the problem** — under the *existing* POSIX installer,
   with no new mechanism. Both rows FIRED.

### macOS, the same probe (pre-publication issue 218)

macOS 15 / Apple silicon, SBCL 2.6.5, 2026-09-02. Same script, three runs of every cell,
**all 21 agreed, and the matrix is identical to Linux's**:

| Backend | main thread parked, **not** `serve-forever` | inside `serve-forever` |
|---|---|---|
| none (control) | **FIRED** | — |
| **Woo** | **TIMEOUT** | **TIMEOUT** |
| Hunchentoot | **FIRED** | **FIRED** |
| **native (`:uv`)** | **FIRED** | **FIRED** |

So the macOS *outside-`serve-forever`* cell that this section was waiting on is filled, and
the native rows are now measured on macOS too. **The fault is not platform-specific**: it
travels with Woo, on both Unixes, in both modes. Windows remains unmeasured — it has no
POSIX signals at all and is a separate question (#37).

## Hypotheses ruled out

Each of these was tried and did **not** fix it, which is worth recording so nobody spends
the afternoon again:

- **Installing the handler before the server starts** (in case libev replaced it) — no change.
- **Waiting on a semaphore instead of sleeping.** Tried first; also does not deliver. It is
  additionally a worse design: `signal-semaphore` takes a mutex, and calling it from a
  signal handler risks deadlocking against the very thread waiting on it. The current code
  polls a flag over `sleep` for that reason independently.
- **Signal-handler safety.** The handler does one `setf` of a struct slot: no allocation, no
  lock, nothing that could hang in a signal context.

## The cause — confirmed

**libev, underneath Woo.** libev installs its own handlers and manipulates the process signal
mask when its loop starts; a handler that never runs — rather than one that runs and
misbehaves — is consistent with the signal being blocked on whichever thread the OS chose to
deliver it to. The probe confirms the *location* (the transport, not `serve-forever`, not the
mere presence of a server) rather than the mechanism inside libev, which we have no need to
establish: the remedy is the same either way, and it is not to fix libev.

## What pre-publication issue 117 turned out to need: nothing

**This section previously prescribed a `uv_signal_t` installer. The evidence retires it.**
Recorded rather than deleted, because a plan that was abandoned for a measured reason is
worth more to the next reader than a plan that was quietly dropped.

The argument was sound as an argument — libuv owns the signal, the callback has a full Lisp
stack, `aion/uv/process` already binds it — and it answered a question that turned out not to
be the one in front of us. **`SIGTERM` already works on the native server under the ordinary
POSIX installer**, in both rows of the probe. Building the installer would add a second
signal mechanism to maintain, in order to fix a defect that mechanism does not have.

So the fix for a Hyperion app is a **backend choice**, and pre-publication issue 117 delivered it in commit 5:

```lisp
;; the app's system, :depends-on
"hyperion/server-uv"            ; instead of "clack-handler-woo"
```

`hyperion/server:start` will select it (`HYPERION_SERVER=uv`, or `:server :uv`, or by being
the only backend loaded). Everything else in `serve-forever` — the banner, the wait loop,
`unwind-protect`, the shutdown hooks — is transport-independent and never needed to change.

If a `uv_signal_t` installer is ever wanted for another reason, `*install-signal-handlers*`
is still the seam and the contract is unchanged. **Verify any such change against the matrix
above, not with Ctrl-C**, which works on every backend and proves nothing about the case that
was broken.

## Consequence: the tree's own default is the broken one

`praxeon/web` declared `clack-handler-woo` on every non-Windows platform, and `+BACKENDS+`
prefers Woo when it is loaded. **So a praxeon web app deployed on Linux or macOS could not
be stopped by its supervisor** — precisely the situation `serve-forever` exists to handle.

**Fixed in pre-publication issue 218, and not by swapping one handler for another.** The deeper fault was that a
*framework* was choosing the *application's* HTTP server at all — the thing pre-publication issue 139 / ADR-0011
decided against and removed from `hyperion.asd`, which `praxeon/web` was simply missed by.
So `praxeon/web` now declares **no** backend, and `praxeon/elise` — a real deployable, and
the layer where the choice belongs — declares `clack-handler-hunchentoot` for itself. An
image with no handler fails loudly at `default-server` with `NO-SERVER-BACKEND`.

The rule is now asserted rather than merely written down (`praxeon/tests`): a framework
system pulling a `clack-handler-*`, on any platform, fails the suite. It had been decided,
documented and undefended, which is how one system went on violating it while the tree
stayed green.

## Note for #37 (`service`)

**Unblocked, with a constraint.** A `service` target could not ship while every deployed app
lost `SIGTERM`; it can ship now, provided the app does not run on Woo. A supervised process
that ignores `SIGTERM` gets `SIGKILL`ed after the grace period, so in-flight requests are
dropped and no shutdown hook runs — which defeats the point of a service target. The
constraint belongs in the target itself: a `service` target that starts an app on Woo should
refuse, or at minimum say so loudly, rather than producing a unit file that cannot be stopped.

Windows remains separate: it has no POSIX signals, and a supervisor-initiated stop there is a
console control event or a service STOP.
