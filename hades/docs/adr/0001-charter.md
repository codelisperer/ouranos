# ADR-0001 — Hades: what earns a portable facade, and what does not

**Status:** Provisional — 2026-08-27. Charters the framework named in the
[ECOSYSTEM decisions log](../../../ECOSYSTEM.md) (2026-08-10) and in
[aion ADR-0003](../../../aion/docs/adr/0003-windows-platform-binding.md) §2.

## Context

Hades was decided and untracked. It had a row in `ECOSYSTEM.md`, a decisions-log entry, and a
charter paragraph inside *another framework's* ADR — but no issue, no board presence and no
directory. An architectural decision that nothing tracks is indistinguishable from one nobody
made, and the maintainer reasonably asked whether it had been lost.

The decided part is the split: **OS-specific *bindings* are aion; OS-specific *functionality* is
Hades.** `aion/windows` (pre-publication issue 170) binds UTF-16 marshalling, `GetLastError`/`HRESULT` as conditions,
handle lifetime, COM. Hades is the layer that makes those pleasant to use, and makes porting
between platforms a non-event.

What was **not** decided is the part that actually determines whether Hades is any good: **which
capabilities get a portable facade, and which get a platform-scoped package.** That question has
one correct answer per capability and no general rule, and getting it wrong is expensive in a
specific way — a facade that quietly does nothing on one platform is worse than no facade,
because the caller cannot tell.

## Decision

### 1. Two contracts, and a bar that decides between them

**A portable facade** — `hades/…` — is offered only when **every supported OS has a real
counterpart**, and porting is a non-event.

**A platform-scoped package** — `hades/windows`, `hades/darwin`, `hades/linux` — is for
everything else. These **fail loudly off-platform and never silently no-op.** Structurally Hades
mirrors aion: the core loads everywhere, only its platform packages do not.

**The bar is about the concept, not the API.** Two platforms can implement something in
completely different ways and still both have it; two platforms can have near-identical APIs and
still not both have it. What matters is whether the *thing being asked for* exists on all three.

### 2. The candidates, tested against the bar

Six capabilities were tested rather than assumed. **Three fail**, and that is the useful half of
the result: each failure is a facade somebody would otherwise have written.

| | verdict | why |
|---|---|---|
| paths / known folders | **facade**, with a delegation rule | concepts map cleanly on all three |
| service / daemon lifecycle | **facade** — the strongest case | "run supervised, stop cleanly" is real everywhere |
| single-instance lock | **facade**, with an implementation rule | but only via `flock`, never a lock *file* |
| notifications | **platform-scoped** | preconditions differ, and absence is *silent* |
| clipboard | **platform-scoped** | the *semantics* differ, not the API |
| autostart | **platform-scoped** | no counterpart at all when headless |

Three of these carry a rule that is easy to get wrong and expensive to get wrong late:

**Paths delegate to UIOP; they do not reimplement it.** UIOP already provides
`xdg-config-home`, `xdg-data-home`, `xdg-cache-home`, `xdg-runtime-dir` and
`temporary-directory`, and they already behave correctly on Windows — measured, not assumed. A
facade that reimplements those is duplication with a second set of bugs. It earns its place
**only** for the `FOLDERID_*` known folders UIOP does not cover — Documents, Desktop, Downloads
— and delegates for everything else. This is aion ADR-0003 §3 one level up: *never re-bind
portable ground.*

**The single-instance lock uses `flock`, never a lock file.** A lock *file* does not match a
Windows named mutex: the mutex is kernel-owned and vanishes when the process dies, while a stale
lock file survives a crash and locks the application out of its own next start. `flock`/`fcntl`
are kernel-owned and released on process death, so they match the Windows semantics closely.
**The naive implementation is the one that diverges**, which is exactly the case a facade exists
to get right once.

**The clipboard fails on semantics, and this is the clearest example of the whole doctrine.** On
Windows and macOS the clipboard is a **store**: set it, exit, the data persists. On X11 it is a
**protocol** — the owning process *serves* the selection on demand, so when it exits the content
vanishes unless a clipboard manager happened to take a copy. A portable `set-clipboard` would
work on two platforms and silently lose data on the third, **after returning successfully.**

### 3. The rule of thumb the results produced

The three that pass are **service-shaped**. The three that fail are **desktop/interactive**.

That is not a coincidence, and it generalises: **the interactive surface is where the platforms
genuinely disagree, and it is where platform-scoped packages earn their keep.** A new candidate
that is interactive should be assumed platform-scoped until it clears the bar; a new candidate
that is about running, storing and supervising should be assumed portable until it fails.

This is a prior, not a verdict. Every candidate still gets tested.

### 4. Iteration 1 is driven by a real application, not by mirroring the binding

The binding is sequenced by reach per unit of work (COM first, because WMI, the Shell, Task
Scheduler, ADO, WSH and Office all arrive through it). **Hades is sequenced by what an
application actually needs**, because a layer whose job is ergonomics has no way to be right
about ergonomics in the abstract.

The first Windows-first consuming app has four surfaces: a product website, a downloadable
desktop app, **a background service — an NT service on Windows, a daemon elsewhere — whose job
is peer-to-peer connection between users**, and mobile last.

So iteration 1 is **service lifecycle + single-instance + paths** — exactly the three that pass
the bar — with the app's desktop surface needing exactly the three that fail, as
`hades/windows`.

**Honestly weighted:** one application agreeing with the analysis is one data point, and it is
the same data point that motivated the bar. It does not prove the bar is right. What it
establishes is that iteration 1 is not a guess.

### 5. The prerequisite, which is not pre-publication issue 170

**`aion/windows/service` does not exist.** Hades has nothing to be ergonomic *over* for the
service surface until that binding lands — `StartServiceCtrlDispatcher`,
`RegisterServiceCtrlHandlerEx`, `SetServiceStatus`, `CreateService`. ADR-0003 §5 already
sequences `service` as the next subsystem after COM, and COM landed.

The real order is **`aion/windows/service` → the Hades lifecycle facade → an application's
service surface.**

### 6. Off the DAG entirely, on hermes's terms

Nothing in the DAG depends on Hades. The only thing that does is a consuming application, which
depends on it *alongside* the frameworks rather than through them.

This is load-bearing rather than tidy. `cons` needs the Windows service binding for
install/uninstall scaffolding — so **`cons` calls `aion/windows/service` directly and never
links Hades.** The image `cons` emits carries a toplevel that dispatches to an **app-supplied
entry point**, and it is the app that reaches `hades/windows` for the service lifecycle. Putting
the binding in Hades would make the second framework in the DAG depend on a satellite, which is
the one hard rule.

### 7. What Hades is not

- **Not a Windows library.** Windows is first because it is furthest from POSIX, not because
  Hades is about Windows. `hades/darwin` and `hades/linux` are peers, not afterthoughts.
- **Not the binding.** That is aion, and §6 explains why it cannot be otherwise.
- **Not a home for portable file formats.** OOXML is *not* Hades: a `.docx` reader has no OS
  binding, no platform difference and no ergonomics over anything — it is zip plus XML. It
  belongs in aion by direct precedent with `aion/csv`, and the maintainer has settled it there.
  Recorded because "Windows-adjacent" is the drift this framework is most likely to suffer.

## Consequences

- **A capability may be refused a facade and still be implemented** — three of the first six
  are. Callers of a platform-scoped package accept that their code is platform-specific, which
  is honest, rather than portable-looking and wrong.
- **`hades/windows` will be larger than the facades for some time.** The interactive surface is
  where applications actually live and where the platforms disagree most.
- **Notifications need a contract that can say "unavailable".** If a facade is ever offered, it
  must be `:delivered | :unavailable`, never a call that returns normally having done nothing.
- **`bootstrap.lisp` compiles the host platform package** — `hades/windows` on Windows,
  `hades/darwin` on macOS — rather than leaving it opt-in the way `aion/uv` is. Opt-in there was
  *bought* by the C-toolchain requirement; a Hades platform package has none, so deferring buys
  nothing. The mechanism exists already: `scripts/platform-packages.lisp` (pre-publication issue 182), where
  `hades/windows` is currently registered `:planned`.
- **A verify-tree run that never loads `hades/windows` on Windows is a defect, not a skip**, and
  the platform axis already reports it as such.

## Alternatives considered

- **Put everything in platform-scoped packages; offer no facades.** Honest and useless: it makes
  every consuming application write three of everything, which is the cost Hades exists to
  remove.
- **Offer a facade for everything and no-op where a platform lacks it.** The failure mode the
  doctrine explicitly forbids. A caller cannot distinguish "did nothing" from "worked", and the
  clipboard case shows the loss can happen *after* a successful return.
- **Mirror the binding's sequence** — COM ergonomics first, since COM landed first. Rejected:
  the binding is sequenced by reach, and ergonomics cannot be validated without a consumer.
- **Fold Hades into aion as `aion/platform`.** Would put OS *functionality* on the DAG and make
  the abstraction a dependency of everything to its right. The split exists precisely so the
  binding can be depended on without the opinions.

## Provenance

**The facade/platform-scoped split was decided by testing candidates against the bar rather than
by surveying them**, and the informative result is that **half of the first six failed** — each
for a different reason, and each a facade that looked obviously portable beforehand.
Notifications in particular look like the easiest facade on the list: all three platforms have a
notification API. They fail on *preconditions*, and the failure is silent.

The rule of thumb in §3 — passes are service-shaped, failures are interactive — was **noticed
after the fact**, not used to derive the results. It is recorded as a prior for the next
candidate rather than as a shortcut past testing.

Iteration 1's scope was **not** derived from the application; the candidates were tested first,
and the application's requirements were read afterwards. They agreed. That ordering is why §4
claims only that iteration 1 is not a guess, rather than that the bar is validated.

Assisted-research note: the candidate analysis, the UIOP measurement on Windows, and this
charter were produced in a Claude Code session; every decision recorded here is the maintainer's.
