# ADR-0003 — The Windows platform binding: one Windows surface in aion, COM first

**Status:** Provisional — 2026-08-10. Follows the placement rule set in
[ADR-0002](0002-libuv-integration-strategy.md) §3 and the ECOSYSTEM entry on native code.

## Context

The goal is not a COM library. It is that **open-source Lisp becomes first-class for rapid
development on Windows** — the thing it already is on Linux and macOS, and conspicuously is
not here. That means the Windows-specific API surface generally: the Service Control Manager,
the registry, security tokens and elevation, the shell, the event log, and OLE/COM as one
subsystem among them. Two forcing cases name themselves — **proper NT services** and
**automating Office** — but they are instances, not the scope.

Nothing in Ouranos touches any of it today. `aion/uv` covers files, sockets, timers,
processes and watching *portably*; everything Windows-shaped beyond that is unreachable from
Lisp in this tree.

The natural first move was to take a dependency for the COM part. `cl-win32ole` (Yoshinori
Tahara) is the established Common Lisp binding, and it was evaluated **empirically rather
than by survey** — cloned, loaded, and driven against live COM servers on SBCL 2.6.6 x64. It
did not load (`mapcan` over a `cffi:load-foreign-library` that no longer returns a list). Its
`CoInitialize` runs once at load time on the loading thread, so any other thread gets
`CO_E_NOTINITIALIZED`, and the exported `with-co-initialize` was a dead symbol — defined in
the `-sys` package, never exported from it, so the api package minted a fresh unbound one.
Most importantly, **`VARIANT` was sized 16 bytes**: right on x86, wrong on x64 where it is
24. The argument array was under-allocated and strode 16 bytes per element, so argument 0
landed correctly and **every call with two or more arguments read garbage as pointers** —
faults at `#x0`, `#x8`, `#xFFFFFFFFFFFFFFFF`. Silent, architecture-specific memory
corruption on the core data path, in a library with no test asserting a single struct size.

Structurally absent besides, by grep: named and optional arguments (`cNamedArgs` hardcoded to
0), `IEnumVARIANT`, connection points, moniker binding, `CoInitializeEx`, `IErrorInfo`, and
any non-`IDispatch` interface. A well-made 32-bit-era artifact whose gaps are structural.
Licensing is ambiguous too — `:licence "BSD"` in two `.asd` files and nowhere else, against
our MIT posture and an audited tree.

## Decision

**1. One Windows surface, in aion, bound by us — named `aion/windows`.**
The umbrella for the Windows-specific API surface, not a COM library that grew a service
module. Its specification is Microsoft's own documentation, which by ADR-0002 §3 puts it
leftmost: `cons` will want the SCM for its service target, `hyperion/desktop` wants shell and
window APIs, and anything packaging an executable wants the registry.

**On the name**, recorded because it will otherwise be re-litigated: not `win64`. "Win32" is
the *name of the API*, not a claim about pointer width — Microsoft still calls the 64-bit API
the Win32 API, and no "Win64 API" exists (`_WIN64` is a compiler macro; `Win64` otherwise
survives only inside `WOW64`). Decisively, **SBCL pushes `:win32` and not `:win64` on x86-64
Windows** (measured: `WIN32 T`, `WIN64 NIL`, `WINDOWS NIL`, `X86-64 T`), so every reader
conditional in the tree reads `#+win32` regardless. `windows` avoids claiming a bit width,
matches `uiop:os-windows-p`, and does not name an API that does not exist. `win32` would also
have been defensible; `win64` is the one option that is both novel and inaccurate.

**2. A foundation subsystem, then peers on top of it.**
`aion/windows` itself owns what every Windows API needs and what is most expensive to get
wrong: **UTF-16 string marshalling** (every modern entry point is the `W` variant),
**`GetLastError`/`HRESULT` decoded into conditions** via `FormatMessage`, **handle
lifetime**, and the layout table of §4. On that: `aion/windows/com`, `aion/windows/service`,
`aion/windows/registry`, `aion/windows/security`, `aion/windows/shell` — added as they earn
their place, each opt-in, exactly the `aion/uv` → `aion/uv/net` → `aion/uv/process` pattern.

**3. Bind what is Windows-only; never re-bind portable ground.**
The scope boundary that keeps this finite. If `aion/uv` already provides it portably — files,
sockets, timers, subprocess spawn — `aion/windows` does not bind it again. The Windows API is
unbounded; *the Windows-specific complement of a portable substrate we already own* is not.
Where they touch (job objects over `uv_spawn`, overlapped I/O), the Windows piece extends
rather than replaces.

The other half of the boundary is that **aion owns only the binding**. Every native Windows
capability lands in three homes, the same three `aion/uv/process` already lands in: the raw
FFI here, the runtime abstraction over it in whichever system owns the domain, and any
scaffolding in `cons`. NT services are the worked example — `aion/windows/service` binds
`StartServiceCtrlDispatcher`, `RegisterServiceCtrlHandlerEx`, `SetServiceStatus` and
`CreateService`; the lifecycle mapping, the service-vs-console toplevel branch in a
`save-lisp-and-die` image, and Event Log routing for a process with no stdout are an
abstraction and belong to Hades; install/uninstall scaffolding is cons's. **Those two
placements are not aion's to record** — see the ECOSYSTEM decisions log, which puts the
abstraction in `hades/windows` (Hades being the cross-OS ergonomics layer, of which Windows
is merely the first and most painful platform) and an ADO backend in mnemosyne.

**Not "above" — off the line entirely.** Hades is a satellite leaf-lib on hermes's terms:
nothing in the DAG depends on it, and the only thing that does is a consuming app, which
depends on it *alongside* the frameworks rather than through them. So the two halves of the
service story do not compose through a dependency. **cons calls `aion/windows/service`
directly** for install/uninstall and never links Hades; the image it emits carries a toplevel
that dispatches to an **app-supplied entry point**, and it is the app — not cons — that
reaches `hades/windows` for the service lifecycle. Recorded because the alternative is the
obvious one and it is wrong: having cons own the branch would make a satellite a dependency
of the second framework in the DAG.

**4. Struct layouts are data, asserted at load.**
The one place no-grovel has no existing answer. `aion/uv` escapes hand-written layouts
because libuv *exports* `uv_handle_size`, with constants verified at load against
`uv_handle_type_name`. **Windows exports no equivalent** — nothing will tell you
`sizeof(VARIANT)`. So: a table of documented x86/x64 sizes and offsets, asserted at load
against `cffi:foreign-type-size` and `foreign-slot-offset`, covered by the suite. Same
doctrine as uv — silent divergence made loud — by a different mechanism, because the vendor
will not answer at runtime. Built in from the first commit; it is the direct lesson of the
`VARIANT` finding and it applies to every subsystem, not just COM.

**5. COM is sequenced first, because it is the meta-API.**
Not because automation is the priority, but because it has the widest reach per unit of work:
WMI, the Shell, Task Scheduler, ADO, WSH and Office all arrive through one binding. `service`
follows — it is small, self-contained, and the other named forcing case. Registry, security
and shell after, demand-driven. Each provable before the next depends on it, per ADR-0002 §4.

**6. Apartment policy is declared, never inherited.**
`CoInitializeEx` with an explicit model. Automation runs on a **dedicated STA thread with a
message pump**, because Office servers are STA and an MTA caller silently marshals every
call; an `IMessageFilter` handles `RPC_E_SERVERCALL_RETRYLATER` instead of failing at random
while Excel is busy. Interfaces cross threads through the Global Interface Table, never as
raw pointers. **A COM STA thread never also runs a uv loop** — a pump and an event loop
cannot both own a thread. This constrains `aion/windows/shell` and any future window/UI
subsystem too, which share the pump — and it reaches consumers: a COM object belongs to the
apartment that created it, so **an ADO-backed mnemosyne connection has thread affinity none
of its other backends have**, which the pool must either respect or marshal around.

**7. Services and Office automation are separate processes.**
Session 0 isolation gives a service no interactive desktop, and server-side Office automation
is unsupported by Microsoft. Anything needing both is a service plus a user-session worker
with IPC. Recorded because the constraint is invisible until it hangs in production.

**8. No C toolchain, ever, for this binding.**
`kernel32`, `advapi32`, `ole32`, `oleaut32`, `shell32` ship with the OS. Unlike `aion/uv`
there is nothing to build, so the "opt-in native system needs a compiler once" caveat does
not apply at all. The SCM's `ServiceMain` and control handler are CFFI callbacks, which SBCL
provides.

**9. Borrow knowledge, not code.**
`cl-win32ole`'s `MEMO` on VARIANT ownership and its chained accessor are worth learning from.
Written fresh against MSDN, credited in `docs/`, not vendored — which the licensing ambiguity
makes the only clean answer regardless.

## Consequences

- **Opt-in *and* platform-exclusive — a new category for this tree.** `aion/uv` is opt-in but
  cross-platform; `aion/windows` cannot load off-platform at all. Core aion stays `coalton` +
  `alexandria`, and by ADR-0002 §5's argument this is what makes the platform gap survivable.
- **`scripts/verify-tree.lisp` gains a platform axis it does not have.** Opt-in native systems
  are currently just absent from `+systems+` with a docstring reason. `aion/windows`'s absence
  is *conditional* — expected on Linux and macOS, a defect on Windows. A `cons windows-test`
  target mirrors `cons uv-test`. **Unresolved:** whether a Windows run should fail when the
  suite is missing.
- **"Aion must be correct on three platforms" acquires an exception** — a family of systems
  correct on exactly one, leftmost in the DAG.
- **We own Windows' memory and lifetime models**: COM reference counting, `VariantClear`
  ownership, handle closure, apartment marshalling. Defects are memory-unsafe rather than
  merely wrong — the evaluation produced faults, not wrong answers.
- **Office automation is unavailable to any service we build.** See §7.
- **Nobody needs a C compiler**, which makes this strictly cheaper to adopt than `aion/uv`.
- CI has only `desktop-release.yml`; coverage is a local `cons windows-test` on Windows until
  a general workflow exists.
- **Two placements this ADR records but does not own** — Hades and an ADO backend in
  mnemosyne — live in the ECOSYSTEM decisions log. Noted here only so the split is legible
  from either end.

## When we would stop

- **If the surface outgrows the maintainer**, narrow to the subsystems with named consumers —
  `service` and `registry` for packaging, `com` restricted to `IDispatch` automation — and
  abandon custom vtable interfaces and event sinks. Keep the binding, shed the ambition; the
  same move ADR-0002 reserves for the HTTP server.
- **If COM specifically proves not worth its memory-safety surface**, shell to PowerShell for
  automation and keep the rest. It spawns a process per call and marshals everything as
  strings, but it is a real fallback and the other subsystems do not depend on COM.

## Alternatives considered

- **Depend on `cl-win32ole` for the COM part.** The intended plan. Rejected on the evidence
  above — and it would have covered one subsystem of the goal in any case.
- **Fork it.** Every disqualifying gap sits in the core data path, so a fork rewrites what
  matters and inherits the licensing ambiguity. What survives is the chained accessor, the
  cheap part to reproduce.
- **Shell out to PowerShell for everything.** No binding to maintain, no memory-safety
  surface. Rejected as the general answer: a process per call, everything string-typed, no
  live handles, no callbacks. Retained as a fallback above.
- **A C shim, or .NET interop.** Both violate no-C-toolchain-on-the-load-path, and .NET adds
  a second runtime to a *CL all the way down* tree.
- **Bind Win32 broadly and exhaustively up front.** Unbounded. §3 and §5 exist to replace
  breadth-first with demand-driven, which is what makes the ambition finishable.

## Provenance

The COM decision was made by **running the code rather than reading it.** The maintainer's
stated hope was to take `cl-win32ole` as an ordinary dependency, and a documentation review
supports exactly that: mature, BSD, layered, typelib-aware, the established option. Loading it
on x64 SBCL found it would not compile; fixing that surfaced the apartment bug; fixing that
surfaced a `VARIANT` sized for 32-bit Lisp that had been silently corrupting every
multi-argument call for as long as anyone had run it on a 64-bit image.

Worth recording precisely, because it is not recoverable from the outcome: the case against
the dependency is **not** that it is old. It is that the defect found is the kind a survey
cannot find and a test suite would have — which is why §4 is a decision here rather than an
implementation detail.

The scope of this ADR was also corrected in review: the first draft framed COM as the thesis
with services as an addendum, and the maintainer's intent is the Windows API surface
generally, of which OLE/COM is one subsystem. §1, §3 and §5 are that correction.

Assisted-research note: the evaluation, the reproductions, and the upstream fixes that made
`cl-win32ole` load at all were produced in a Claude Code session; every decision recorded here
is the maintainer's.

---

## Amendment 1 — §4 is stronger and narrower than it was written (2026-08-27)

*Written by PM at the maintainer's instruction, from measurements taken by the Windows lane
as the first consumer of `aion/windows` (#181, #201). §4 stands; its premise was broader than
the facts, and its coverage narrower.*

### What §4 got wrong

§4 says *"Windows exports no equivalent — nothing will tell you `sizeof(VARIANT)`."* That is
**true of `VARIANT` and false of several structs beside it.**

`GUID`, `DISPPARAMS` and `EXCEPINFO` are `TKIND_RECORD` entries in the OLE Automation type
library, and `TYPEATTR.cbSizeInstance` is their size, **from the OS**:

| struct | OS says | our table | |
|---|---|---|---|
| `GUID` | 16 | 16 | agree |
| `DISPPARAMS` | 24 | 24 | agree |
| `EXCEPINFO` | 64 | 64 | agree |

**Three of the five registered layouts are now confirmed by Windows itself**, independently
of anyone's reading of MSDN — including `EXCEPINFO`'s 64, which was hand-computed from x64
padding rules with no second source.

`VARIANT` is not a record, has no `cbSizeInstance`, and remains documented-only. **So the one
struct that motivated the entire doctrine is precisely the one the OS will not answer for** —
which is why §4 was written from it, and why generalising from it was the error.

### Vtable slot indices are the same category, and were not covered at all

§4 made struct layouts data because getting them wrong is silent. **Slot indices are exactly
that and had no check.** `GetContainingTypeLib` is `ITypeInfo` slot 18; `ReleaseTypeAttr` is
19. A spike had 22 and 18, called `GetContainingTypeLib` where it meant `ReleaseTypeAttr`,
passed a `TYPEATTR*` as an out-parameter — and it **returned plausible numbers and survived**.
The next run faulted: *"CORRUPTION WARNING in SBCL: Memory fault at 0000000000000004."*

Wrong slot → plausible output → memory corrupted → fault arrives later, somewhere unrelated.
That is a worse shape than a wrong struct size, which usually fails near where it was wrong.

It had not bitten before because the generic `IDispatch` path uses **slots 0–6**, small enough
to be right by inspection. A typelib generator uses **a dozen across two interfaces**, and is
not.

### A slot CAN be verified against a name — where the interface describes itself

`FUNCDESC.oVft / pointer-size` gives the slot; `GetDocumentation` gives the name. Validated
end to end against `IDispatch`, whose slots are not in dispute — `3 GetTypeInfoCount`,
`4 GetTypeInfo`, `5 GetIDsOfNames`, `6 Invoke`, exactly right, which also validates the
`FUNCDESC` offset reading itself.

**And it is unavailable exactly where the risk is highest.** `ITypeLib` and `ITypeInfo` are
**not in the OLE Automation type library** — `TYPE_E_ELEMENTNOTFOUND`. That library describes
`GUID`, `DISPPARAMS`, `EXCEPINFO`, `IUnknown`, `IDispatch`, `IEnumVARIANT` and the font and
picture types, and neither of the two interfaces that read type libraries. **The
type-description system does not describe itself.**

So the checkable interfaces are the ones already safe by inspection, and the dozen slots that
actually faulted are the ones no automatic check can reach. `cbSizeVft` remains the only
guard there, catching the past-the-end class only — which is at least the class that *faults*
rather than the class that silently corrupts.

`IEnumVARIANT` **is** checkable, and #181 needs it for collection iteration. It was
structurally absent from the prior art, so its slots would otherwise have been hand-copied
with nothing verifying them.

### The amended doctrine

1. **Ask the OS wherever it answers.** `cbSizeInstance` for `TKIND_RECORD` structs;
   `oVft` + `GetDocumentation` for interfaces the type system describes.
2. **Fall back to the documented table only where it does not** — `VARIANT`, `MSG`,
   `FILETIME`, and all of Win32 outside automation, which is still most of it.
3. **Mark which kind each table entry is.** The table currently reads as uniform and is not.
   **A verified number and an asserted one must not look the same** — that is the whole of
   this amendment, and it is the same principle as the rest of the tree's evidence rules: a
   check that cannot fail is not a check, and a number nobody could have contradicted is not
   confirmed.
4. **Interface slots are table data, not literals**, bounded by `cbSizeVft` and verified by
   name where the interface is describable.

### Provenance

The vtable defect was found by *building the thing*, not by review: a spike that returned
plausible numbers, then corrupted memory, then faulted somewhere else. §4's own argument — the
defect found is the kind a survey cannot find and a test suite would have — turns out to apply
to §4.
