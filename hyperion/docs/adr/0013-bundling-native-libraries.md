# ADR-0013 — Bundled native libraries: carry what we build, resolve beside the image

**Status:** Accepted · 2026-08-05

## Context

A dumped SBCL image is self-contained **Lisp**. It is not self-contained **native code**:
every CFFI binding resolves a shared library *by name*, on the end user's machine, at run
time. The proof is not hypothetical — the CI-built Linux bundle died on a clean box with
`Error opening shared object "libev.so.4"` ([#74](https://github.com/codelisperer/ouranos/issues/74),
[#94](https://github.com/codelisperer/ouranos/issues/94)).

[ADR-0011](0011-desktop-server-backend-and-content-length.md) removed *that* library by
dropping Woo from desktop bundles. It did not solve the category, and said so. We then added
`aion/uv` — so a bundle can once again ship an image that will `dlopen` something the user
does not have.

What changed between July and now is **whose artifact it is**. `libuv` is not resolved from
a distro: `scripts/build-libuv.lisp` fetches a sha-pinned tarball (`libuv.pin`) and compiles
it with the platform's own C compiler into `vendor/libuv/lib/`. We know exactly what file
would ship, at exactly what version, because we produced it. That is what makes bundling a
mechanical problem rather than a guess, and it is why #94 is tractable now.

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
  [#125](https://github.com/codelisperer/ouranos/issues/125)'s runtime module — not by a
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
