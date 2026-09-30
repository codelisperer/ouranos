# Hades

**The OS ergonomics layer.** It makes each platform's own features pleasant to use from Common
Lisp, and porting between platforms a non-event — over the raw bindings aion provides.

*Hades, who rules a realm nobody visits willingly and everybody eventually needs.* Windows is
first, being furthest from POSIX; macOS and Linux are peers, not afterthoughts.

> **Status: one facade.** The charter is [ADR-0001](docs/adr/0001-charter.md).
> `hades/single-instance` (#305) is the first code: a per-user, per-directory lock that the
> operating system holds and releases when the process ends. The service lifecycle facade is
> still blocked on `aion/windows/service`, which does not exist yet.

## The two contracts, kept distinct

**Portable facades** (`hades/…`) are offered **only** where every supported OS has a real
counterpart. **Platform-scoped packages** (`hades/windows`, `hades/darwin`, `hades/linux`) are
for everything else, and they **fail loudly off-platform — they never silently no-op.** A facade
that quietly does nothing is worse than no facade, because the caller cannot tell.

Six capabilities were tested against that bar. **Three failed**, which is the useful half:

| facade | | platform-scoped | |
|---|---|---|---|
| paths / known folders | delegates to UIOP | notifications | preconditions differ, silently |
| service / daemon lifecycle | the strongest case | clipboard | semantics differ, not the API |
| single-instance lock | `flock`, never a lock file | autostart | no counterpart when headless |

The pattern is worth more than the list: **the passes are service-shaped and the failures are
desktop/interactive.** The interactive surface is where the platforms genuinely disagree.

## What Hades is not

- **Not a Windows library.** Windows leads because it is hardest, not because Hades is about it.
- **Not the binding.** That is [`aion/windows`](../aion/docs/adr/0003-windows-platform-binding.md).
  `cons` calls `aion/windows/service` **directly** and never links Hades — putting the binding
  here would make a DAG member depend on a satellite.
- **Not a home for portable file formats.** OOXML is not Hades: a `.docx` reader has no OS
  binding and no platform difference. It belongs in aion, by precedent with `aion/csv`.

## Where it sits

**Off the dependency line entirely**, on hermes's terms: nothing in the DAG depends on Hades.
The only thing that does is a consuming application, which depends on it *alongside* the
frameworks rather than through them.

## The single-instance lock

`hades/single-instance` keeps a second copy of an app from running against the same data
directory. The operating system holds the lock for the process and releases it when the
process ends, however it ends, so a crash never locks the app out of its next start. On
Windows it is a `CreateFileW` handle with share mode 0; on Linux and macOS it is an `fcntl`
write lock. The file it is held on, `<directory>/<name>.lock`, holds nothing and is never
deleted.

```lisp
(hades/single-instance:with-single-instance ("wordcrafter" :on-busy (lambda () (uiop:quit 0)))
  (hyperion/desktop:run-app app ...))
```

The lock is scoped to a directory: by default the app's per-user data directory,
`(uiop:xdg-data-home "<name>/")`, or `:directory`. `acquire-single-instance` returns a lock or
`:busy`, and `release-single-instance` releases it early. A second acquire from the same
process is `:busy` too. `hyperion/desktop:run-app` does not take the lock itself, because
nothing in the dependency line may depend on hades; the app takes it around `run-app`.
Handing the second launch's arguments to the first copy is not built yet (#305).
