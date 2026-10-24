# ADR-0013 — Bundled native libraries: carry what we build, resolve beside the image

**Status:** Accepted · 2026-08-05

## Context

A dumped SBCL image is self-contained **Lisp**. It is not self-contained **native code**:
every CFFI binding resolves a shared library *by name*, on the end user's machine, at run
time. The proof is not hypothetical — the CI-built Linux bundle died on a clean box with
`Error opening shared object "libev.so.4"` ([#72](https://github.com/codelisperer/ouranos/issues/72),
[#78](https://github.com/codelisperer/ouranos/issues/78)).

[ADR-0011](0011-desktop-server-backend-and-content-length.md) removed *that* library by
dropping Woo from desktop bundles. It did not solve the category, and said so. We then added
`aion/uv` — so a bundle can once again ship an image that will `dlopen` something the user
does not have.

What changed between July and now is **whose artifact it is**. `libuv` is not resolved from
a distro: `scripts/build-libuv.lisp` fetches a sha-pinned tarball (`libuv.pin`) and compiles
it with the platform's own C compiler into `vendor/libuv/lib/`. We know exactly what file
would ship, at exactly what version, because we produced it. That is what makes bundling a
mechanical problem rather than a guess, and it is why #78 is tractable now.

Three platforms will implement this. Three improvised answers would cost a rewrite, so the
mechanism is settled here once, before any of them is written.

## Decision

**1. Carry the library beside the executable.** The bundle directory holds the image, the
`hyperion-view`, `VERSION`, and now the shared libraries the image may open.

**2. Resolve it from the running image's own directory, in Lisp, by absolute path.** No
loader search feature is relied upon. `aion/uv` tries, in order:

| | candidate | for |
|---|---|---|
| 1 | `AION_UV_LIBRARY` | an explicit override; always wins |
| 2 | **beside the running image** | **a shipped bundle** |
| 3 | `vendor/libuv/lib/…` | the source tree (dev) |
| 4 | the bare soname | a system install |

Step 2 is this ADR's addition. The image's own directory comes from
`sb-ext:*runtime-pathname*`, for the reasons `hyperion/desktop:image-directory` already
documents: `argv0` routinely carries no directory, and a relative merge in a dumped image
resolves against the *build* machine's `*default-pathname-defaults*`.

**3. We carry what we build.** A library under `vendor/` was produced by this tree from a
pinned source, so we know its provenance, its version and its license: it is carried.
Everything else is not:

- **Platform libraries** (`libc`, `libm`, `libdl`, the Windows CRT) — present on every
  target by definition. Carrying them is how you break a machine, not how you support one.
- **System libraries with their own packaging story** — WebKitGTK and the GTK stack, reached
  by `hyperion-view` rather than by the image. Those belong to the **packaging layer**
  (AppImage on Linux, the `.app` on macOS, the installer on Windows), not to the dumped
  image. This ADR does not solve them and does not pretend to.

The rule generalizes without new code: when the tree vendors SQLite or OpenSSL, they land in
`vendor/` and are carried by the same walk.

**4. Only permissive licenses travel inside the image.** libuv is MIT; the bundle ships its
`LICENSE` under `LICENSES/`. An **LGPL** library must not be carried this way — the relink
obligation is a real constraint, not a formality, and satisfying it is a packaging-layer job.
That is a second, independent reason WebKitGTK stays out of the image.

**5. The build reports the whole inventory.** At dump time the build script prints every
foreign library the image has loaded, each marked carried or not with the reason. "Did we
bundle everything?" is then answered by reading the build log, rather than by shipping and
waiting for a bug report.

**6. Verification is a container with no toolchain, no repo, and no copy of the library.**
A developer's machine cannot falsify this class of bug — that is precisely how the libev
failure shipped. The clean-room run is the acceptance test, not a nicety.

## Consequences

- The same mechanism works unchanged on all three platforms, because it asks the OS loader
  for nothing but an absolute path. Only the file names differ (`libuv.so.1` /
  `libuv.1.dylib` / `libuv.dll`). macOS needs no `install_name_tool`, Windows no manifest.
- `aion/uv` computes the image directory itself, in `src/uv/library.lisp` — a near-duplicate
  of `hyperion/desktop:image-directory`. It cannot share that code: `aion/uv` sits far to the
  left of `hyperion` in the DAG, and deliberately does not depend even on `aion` core. This
  is recorded as a known duplication to be resolved by
  [#91](https://github.com/codelisperer/ouranos/issues/91)'s runtime module — not by a
  comment asking two files to stay in sync.
- In a dumped image, candidate 3 (`vendor/`) is dead weight rather than a fallback:
  `asdf:system-source-directory` returns the *build* machine's path, which does not exist on
  the user's. Harmless (the `probe-file` fails), and worth knowing before it is mistaken for
  a safety net.
- **The build must RELEASE what it opened before dumping.** SBCL records every open shared
  object and reopens it during `reinit` at image startup — *before* `main` — so an image
  dumped while holding the library dies on the user's machine with the build machine's path
  in the message, no matter what is sitting beside the binary. `aion/uv:unload-libuv` exists
  for this, and the bundler calls it after the copy. This is not a theoretical hazard: it is
  what the first bundle built under this ADR actually did.
- A bundle grows by the size of what it carries — ~280 KB for libuv on Linux. Negligible
  against a dumped SBCL image.
- Nothing about the *dev* path changes: with no library beside the running SBCL, resolution
  falls through to `vendor/` exactly as before.

## Amendment, 2026-09-28: an app's own libraries (#78)

Decision 3 covers the libraries this tree builds. An app can also depend on native libraries
of its own, which the tree knows nothing about: a PDF renderer kept in the app's repository,
or a pinned `sqlite3.dll`, which stock Windows does not have (it has `winsqlite3.dll`, a
different name). The bundler reported those as system libraries and left them out, so the
installed app started and then failed on its first call into the library.

An app now names them: `scripts/build-desktop-app.lisp --carry <path>`, once per library.
`scripts/carry-natives.lisp` does the work, and follows decisions 1, 2 and 4:

- the file is copied beside the executable, and its license text goes under `LICENSES/`: the
  files and directories whose names start with `LICENSE`, `COPYING` or `NOTICE`, beside it or
  in the directory above, or the files `--carry-license` names after its `--carry`, for a
  library that ships none (SQLite is public domain). A library with no license text is
  refused, as is a path under `vendor/` or two paths with one file name;
- if the image has the library open, it is closed before the dump, for the reason the
  consequences below give for libuv, and a function added to `sb-ext:*init-hooks*` opens the
  copy by absolute path from the directory of `sb-ext:*runtime-pathname*` when the app
  starts, before `main`. If the copy is missing, the app stops with exit code 3 and names it;
- if the image does not have it open, it is still copied, and the build log says the app must
  open it itself from beside `sb-ext:*runtime-pathname*`.

The app, not the tree, is responsible for the license of what it carries (decision 4 applies:
no LGPL library this way). The checkers suite tests it by dumping an image that loaded a
library from a directory, deleting the directory, and running the image; the controls are the
same bundle with the carried copy deleted, and a dump without carrying, and both must fail.

## Amendment, 2026-10-01: libgit2, the one non-permissive library a bundle carries (#429)

Decision 4 says only permissively licensed libraries travel inside the image, and that an LGPL
library must not. This amendment records one exception, which the maintainer decided on
2026-09-30 on #429 (comment 5916493345). It does not change decision 4's text.

**libgit2, which `aion/libgit` binds, may be carried in a desktop bundle.** Its licence is the
GNU GPL version 2 with the libgit2 linking exception. The exception allows a program under any
licence to link the library. The library itself stays under the GPL, which requires that
anyone who distributes the binary also makes its source available. So a bundle that carries
libgit2 must also carry:

- **its exact pinned source**: the tarball `libgit2.pin` names, under `SOURCES/` in the
  bundle, with the sha256 `libgit2.pin` records;
- **its licence**: `COPYING` from that tarball, under `LICENSES/`.

`scripts/build-desktop-app.lisp` puts both there when it carries the library, and refuses to
build the bundle if the tarball's sha256 does not match the pin. The `verify-bundle` scripts
check that both are present whenever the library is.

**This is not a general rule for linking exceptions or for the GPL.** LGPL libraries stay
excluded, for decision 4's reason: the LGPL's relinking obligation is a real constraint, and
satisfying it is the packaging layer's job, not this mechanism's. Any other library whose
licence is not permissive needs its own decision by the maintainer, recorded here as an
amendment like this one.

## Amendment, 2026-10-04: libgit2 beside a binary that `cons bin` builds (#524)

The 2026-10-01 amendment allows libgit2 in a desktop bundle. On 2026-10-04 the maintainer
extended it to the directory that `cons bin` writes; the decision is recorded on #524. When an
app loads `aion/libgit`, `bin/` carries libgit2 beside the binary and, as a desktop bundle does:

- the tarball `libgit2.pin` names, under `bin/SOURCES/`, with the sha256 `libgit2.pin` records;
- `COPYING` from that tarball, under `bin/LICENSES/`.

`cons bin` stops with exit code 3 when the tarball is missing or its sha256 does not match the
pin. An app that distributes the binary has to distribute `bin/SOURCES/` and `bin/LICENSES/`
with it, because the binary alone does not meet the GPL's requirement that the source be
available.

This covers libgit2 only. Any other library whose licence is not permissive still needs its own
decision by the maintainer, as the 2026-10-01 amendment says.

## Amendment, 2026-10-24: SQLite, built from a pinned source and carried by default (#899)

**Status of this amendment:** Proposed (pending maintainer). It applies decision 3 to a library
the tree now builds, so the code that follows it can merge while the amendment is Proposed.

Every app that uses `mnemosyne` loads cl-sqlite, through `dbd-sqlite3`, and cl-sqlite opens
`libsqlite3` when it loads. Before this amendment a bundle carried no SQLite, so a bundled app
ran on whichever copy the user's machine had: 3.51.0 on macOS 26.6, the distribution's on
Linux, and none at all on stock Windows (it has `winsqlite3.dll`, a different name).

**1. The tree builds SQLite from a pinned source.** `sqlite.pin` names the release, the URL of
sqlite.org's `sqlite-autoconf` tarball and its sha256. sqlite.org publishes SHA3-256 rather
than SHA-256, so the pin's comment records the SHA3-256 of the same tarball, which was checked
against sqlite.org's download page when the pin was written. `scripts/build-sqlite.lisp`
checks the tarball against the sha256, compiles the one file `sqlite3.c` with the platform's
C compiler (cc on Linux and macOS, MSVC with `/MT` on Windows), and writes
`vendor/sqlite/lib/` under the file name cl-sqlite opens: `libsqlite3.dylib`,
`libsqlite3.so.0` or `sqlite3.dll`.

**2. One set of compile options on every OS.** `SQLITE_THREADSAFE=1`,
`SQLITE_ENABLE_MATH_FUNCTIONS` and `SQLITE_OMIT_LOAD_EXTENSION`; FTS5 is not compiled in.
Extension loading is left out because nothing in the tree loads an extension, and a library
built without it cannot load native code from a file at run time. Apple's copy also omits it.
The build script refuses a library that exports `sqlite3_load_extension` or
`sqlite3_enable_load_extension`. If an extension such as sqlite-vec is adopted later, that
decision changes this option, and this amendment is the place to record it.

**3. SQLite has no licence file, so the build writes one.** SQLite is public domain. The
tarball ships no `LICENSE`, and decision 4 carries no library without licence text, so
`build-sqlite.lisp` writes `vendor/sqlite/LICENSE` from the dedication at the head of
`sqlite3.c`. It is carried under `LICENSES/` as every other licence is.

**4. A bundle carries it when the app loads cl-sqlite, on Linux, macOS and Windows.**
`scripts/build-desktop-app.lisp` asks `carry-natives`'s `tree-sqlite-carry` whether cl-sqlite's
library is open in the image. If it is, the bundle carries `vendor/sqlite/lib/<name>` and its
`LICENSE` by the 2026-09-28 amendment's mechanism: cl-sqlite's open library is closed before
the dump, whichever copy the build machine had opened, and an `sb-ext:*init-hooks*` entry
opens the carried copy by absolute path from the directory of `sb-ext:*runtime-pathname*`,
exiting with code 3 if it is missing. Linux carries it too, so every OS runs one SQLite
version, as libuv does under ADR-0011. The maintainer's hub ruled this on #899.

**5. The bundle build fails when the app loads cl-sqlite and the pinned build is missing.**
It stops with exit code 3 and prints the command, `sbcl --script scripts/build-sqlite.lisp`.
It does not fall back to the build machine's copy and does not carry nothing, because either
would ship a bundle that uses whatever SQLite the user's machine has, which is the case this
amendment exists to remove. Ruled on #899 with point 4.

**6. An app's own SQLite takes precedence.** An app that passes a library with one of
cl-sqlite's file names to `--carry` keeps it, and the tree's build is not carried. The build
log says so.

**7. The tree's own suites and REPLs keep the system copy.** Only desktop bundles carry the
pinned build. `scripts/versions.env` separately pins sqlite.org's prebuilt DLL, which
`setup.ps1` installs for the Windows toolchain; it is kept at the same version, and
`upstream.sexp` lists both under one entry so that `check-upstream` reports them together.

**How it is checked.** `desktop-release.yml`'s `sqlite-probe` job builds
`praxeon/examples/sqlite-probe` into a bundle on Linux, macOS and Windows and runs it. The
probe runs praxeon's `retrieve-similar` and `retrieve-hybrid` on a fixed corpus in a fresh
SQLite file, and passes only if the ids match, the library is the copy beside the executable
and its version is the pinned one. On macOS the job also reads the dyld log, and fails if a
libsqlite3 from outside the bundle stays loaded beside the bundle's; `verify-bundle-macos.sh`
applies that rule to every carried library. On Windows it runs under
`verify-bundle-windows.ps1 -RequireLoaded sqlite3.dll`, whose control run deletes the carried
DLL and requires the probe to fail. The job uploads nothing.

This covers desktop bundles. A binary that `cons bin` builds does not carry SQLite yet.

## Alternatives considered

- **`$ORIGIN` in `DT_RUNPATH`** — the conventional Linux answer, and the initial lean here.
  It would work: glibc consults the calling object's `RUNPATH` for `dlopen`, and the calling
  object is the executable. But we do not link that executable — `save-lisp-and-die` copies
  SBCL's runtime — so setting it means either rebuilding SBCL or patching the ELF after the
  fact with **`patchelf`**, an external build tool, which the house rule (`sbcl --script` is
  the only build driver) excludes. It is also a Linux-only concept: macOS would need
  `install_name_tool` and `@loader_path`, Windows has no equivalent at all. Three mechanisms
  and three failure modes, to buy a loader search we do not need once we pass an absolute
  path.
- **A wrapper script setting `LD_LIBRARY_PATH`** — rejected on two counts. It changes *what
  the user launches*: argv[0], the PID, the file the updater swaps (ADR-0010), and the target
  of the `.desktop` entry all become the shim rather than the app. Worse,
  `LD_LIBRARY_PATH` is **inherited by children**, and this app spawns `hyperion-view`,
  which links the system WebKitGTK stack — injecting our library directory into *its* search
  path is how a webview ends up half-resolved against our copies.
- **A `lib/` subdirectory** instead of beside the binary. Tidier, and wrong for the one case
  where the resolver might be bypassed: on Windows the loader finds DLLs *beside the exe*
  with no help. "Beside" is the placement that is also correct when nothing helps it.
- **Static linking into the runtime.** Genuinely appealing — no resolution problem at all —
  but it means building SBCL itself per platform, which is a far larger commitment than
  building libuv.

## Provenance

**The clean room paid for itself on its first run.** The first bundle built under this ADR
carried the right file, resolved it correctly, and still died before reaching `main` —
because `save-lisp-and-die` had recorded the *build* machine's copy as an open shared object
and SBCL reopened it at startup. The release step meant to prevent that had failed silently:
it passed a path string to `cffi:close-foreign-library`, which identifies libraries by
generated symbol, inside an `ignore-errors`. Every part of that is invisible on a developer's
machine, where the path exists and reopening succeeds. Nothing but a machine without the
library could have found it, which is the entire argument for point 6 — recorded here
because the temptation to skip that run will recur, and because the same trap is waiting for
macOS and Windows.

The lean at the start of this was `$ORIGIN`/rpath, on the strength of it being what
everything else does. It did not survive being written down: the step where you set the
rpath needs a tool we have ruled out, on a binary we do not link, and the technique does not
exist on two of the three targets. The mechanism that won is the one already proven in this
tree for a different file — `hyperion/desktop:default-launcher` finds the native launcher
beside the image, and the commit that fixed it (`2108a41`) had already paid for the
`argv0`-versus-`*runtime-pathname*` lesson this depends on.

Worth recording that the *option* is downstream of a decision made elsewhere. ADR-0011
concluded "use Hunchentoot," and the maintainer rejected the framing rather than the answer:
if the objection to Woo was an unvendorable native dependency, the response was to own the
substrate. That produced `aion/uv` and a libuv we build from a pinned tarball — which is the
only reason this ADR can say "carry what we build" instead of "bundle whatever `apt`
resolved."
