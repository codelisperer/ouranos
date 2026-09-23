# ADR-0014 — macOS: patch the runtime before the dump, not the image after it

**Status:** Accepted · 2026-08-06

## Context

[ADR-0013](0013-bundling-native-libraries.md) settled how a bundle carries the libraries the
**image** opens: `dlopen`, resolved in Lisp, by absolute path, from beside the running image.
It states that "macOS needs no `install_name_tool`", and for that class of library it is
correct — libuv is found and carried on macOS today with no Mach-O surgery whatever.

It does not cover a second class, and the omission is not academic. A dumped image also
inherits the libraries **the SBCL runtime itself is linked against**, because
`save-lisp-and-die :executable t` prepends that runtime verbatim. On this machine:

```
$ otool -L dist/uv-probe-.../uv-probe
        /usr/lib/libSystem.B.dylib
        /opt/homebrew/opt/zstd/lib/libzstd.1.dylib
```

`libzstd` comes from Homebrew's SBCL, which builds with core compression. The load command
is **`LC_LOAD_DYLIB`, not weak and not lazy**: dyld resolves it at process start, so a Mac
without Homebrew zstd never reaches `main`. `/opt/homebrew/opt/zstd/...` exists only on a
machine that has Homebrew *and* that formula — which is to say, on developers' Macs and
almost nowhere else.

This is the libev failure again, one layer down: invisible on every machine that could
build the artifact, fatal on the machines we ship to.

## Decision

**1. Discover the runtime's non-system linked libraries.** `otool -L` on
`sb-ext:*runtime-pathname*`, keeping anything outside `/usr/lib/` and `/System/`. Those two
are OS-provided on every Mac by definition and live in the dyld shared cache; everything
else belongs to whoever built that SBCL.

**2. Patch the runtime that PERFORMS the dump, before it dumps.** Copy it, rewrite each
dependency to `@executable_path/<name>` with `install_name_tool`, re-sign ad-hoc with
`codesign`, and re-exec the build under it. The dumped image then inherits the rewritten
load command and finds the copy we place beside it.

**3. Carry those libraries into the bundle under the name in the load command.** That is the
*symlink's* name (`libzstd.1.dylib`), while the bytes come from its target
(`libzstd.1.5.7.dylib`). Copying the resolved file under its resolved name satisfies nothing.

**4. The same files must sit beside the patched runtime during the build**, because it now
resolves them against its own directory too.

**5. Signing and notarization are blocked, not merely unimplemented** — see Consequences.

## Why not the obvious things

**Patch the dumped image.** `install_name_tool` refuses it:

```
fatal error: the __LINKEDIT segment does not cover the end of the file (can't be processed)
```

`save-lisp-and-die` appends the Lisp core past the end of the Mach-O, so the file is no
longer a structurally valid Mach-O. This is the root fact the whole ADR is arranged around,
and it is why the patch has to happen *before* the dump.

**Bind `sb-ext:*runtime-pathname*` to a patched copy.** Tried; the dumped image still carried
the Homebrew path. That variable is a Lisp special, while the bytes that get prepended come
from the C runtime's own path. Setting it changes nothing about the dump.

**Build SBCL without core compression.** Removes the load command at the source and is
genuinely the cleanest answer — but it means every contributor and every CI runner builds
SBCL rather than installing it, which is a far larger commitment than ADR-0013 was willing
to make for static linking, and the same objection applies.

**A wrapper script setting `DYLD_FALLBACK_LIBRARY_PATH`.** Rejected for the reasons
ADR-0013 already gives for `LD_LIBRARY_PATH`: it changes what the user launches, and it is
inherited by `hyperion-view`, which links the system WebKit stack.

## Consequences

- **`install_name_tool`, `otool` and `codesign` join the build path.** They are Xcode Command
  Line Tools — the platform's own first-party toolchain, which the house rule permits on the
  build path. It excludes third-party build drivers (`patchelf`, MSYS) and anything on the
  *load* path; none of these three ships or is required at run time. Worth stating plainly
  because ADR-0013 rejected rpath partly to avoid `patchelf`, and this must not read as a
  reversal: the distinction is first-party versus third-party, not "no tools".
- **The build re-execs itself once on macOS.** The check runs before the system is loaded, so
  the expensive Coalton compile still happens exactly once, in the child. `OURANOS_PATCHED_RUNTIME`
  stops it recursing; `OURANOS_CARRY_DYLIBS` tells the child what to carry, since its own
  runtime now says `@executable_path` and can no longer report the original paths.
- **This class of bug is falsifiable on the build machine, unlike ADR-0013's.** Deleting a
  carried `dlopen`ed library just falls through to the next candidate — on a dev Mac, the
  source tree or Homebrew — so the control run proves nothing without a clean room. Deleting
  a carried *linked* library fails immediately and unambiguously:
  `dyld: Library not loaded: @executable_path/libzstd.1.dylib`. Verified in both directions.
- **Signing and notarization are BLOCKED for a dumped image, not merely skipped.** `codesign`
  rejects it with "main executable failed strict validation" — the appended core again — so
  a `.app` wrapping it cannot be signed either. Measured consequence: `spctl --assess`
  reports "code has no resources but signature indicates they must be present", caused by the
  ad-hoc signature *embedded* in the image and inherited from the runtime; adding a real
  Resources payload does not change the verdict, and the signature cannot be stripped because
  it is what lets the binary execute on Apple silicon. Distribution past "right-click > Open"
  therefore needs a different artifact shape — most plausibly runtime and core as separate
  files, where the runtime is an ordinary signable Mach-O — traded against the single-binary
  property the updater ([ADR-0010](0010-desktop-distribution-and-self-update.md)) relies on.
  That is a real decision and it is not made here.
- **The `.app` layout needs no re-layout.** All three resolution mechanisms — `dlopen`ed
  libraries, `@executable_path`, and the `hyperion-view` — mean "the directory the
  executable is in", which in a `.app` is `Contents/MacOS/`. The bundle directory is copied
  there unchanged. A tidier `lib/` subdirectory would have broken all three, which is the
  same conclusion ADR-0013 reached for a different reason.
- **Linux and Windows are unaffected today** but not immune: the mechanism is "inspect the
  runtime's own link-time dependencies", and a distro SBCL linking something unusual would
  raise the same question there. Only the macOS branch is implemented, because only macOS
  has been shown to need it.

## Addendum (2026-08-06) — the signable shape, measured

The Consequences above call runtime-and-core-as-separate-files "most plausibly" the way past
the signing block. It was then tested, and it works — so this is now a measurement, not a
guess. Recorded here because the next person to pick up distribution should not have to
rediscover it.

**Why the other frameworks do not have this problem.** Their main executable is an ordinary
linker-produced Mach-O, and the payload is attached somewhere `codesign` can see:

| | main executable | payload |
|---|---|---|
| Electron | ~120 KB | `Contents/Resources/app.asar` — a sibling resource |
| Tauri | small Rust binary | `include_bytes!` → real `__DATA` sections, at link time |
| Wails | small Go binary | `embed.FS` → the same |
| ours (`:executable t`) | ~77 MB | appended past `__LINKEDIT`, after the linker is done |

The difference is *when* the bytes are attached. Link-time embedding lands in segments the
signature covers; SBCL appends into the region where the signature itself belongs. Everything
downstream — Developer ID, hardened runtime, notarization — is then routine for them.

**What was verified here**, with the SBCL runtime as an ordinary 340 KB Mach-O and the core as
a separate file:

- `codesign --options runtime --entitlements … ` succeeds, and `codesign --verify --strict`
  reports valid — the exact step that fails on a dumped image.
- The image runs and **still compiles code at run time** under hardened runtime, given
  `com.apple.security.cs.allow-jit` (and `allow-unsigned-executable-memory`). This matters
  more for us than for Electron: the Coalton REPL compiles on every input. Claude.app carries
  `allow-jit` for V8 for the same reason.

**Two findings that were not anticipated, and that couple this ADR to the signing work:**

- **Hardened runtime enforces Team ID matching on every loaded dylib.** The carried
  `libzstd` was refused — "mapping process and mapped file (non-platform) have different Team
  IDs" — until library validation was disabled. Ad-hoc signatures have *no* Team ID, so two
  ad-hoc binaries do not match each other; with a real Developer ID, signing the app and its
  carried libraries with the same certificate satisfies it and no entitlement is needed. So
  **point 3 of this ADR is not independent of signing**: whatever we carry, we must also sign.
- **Hardened runtime strips `DYLD_*` environment variables.** That silently disables check 2
  of `scripts/verify-bundle-macos.sh`, which reads `DYLD_PRINT_LIBRARIES` to prove a library
  came from the bundle. It will not fail — it will stop observing, and report "never loaded".
  A false green waiting for whoever turns on hardened runtime; that check needs a different
  mechanism (`vmmap`, or a probe that reports its own resolved path) at that point.

**The cost is not Apple's fee.** It is that runtime-plus-core gives up the single-binary
property [ADR-0010](0010-desktop-distribution-and-self-update.md)'s updater relies on:
replace-and-re-exec becomes replace-two-files-consistently. That trade is unmade — see the
options below.

*Corrected 2026-08-06:* this paragraph first also claimed the runtime "must locate its core
when LaunchServices starts it with no arguments", and treated that as a second cost. It is
not one. **A bare SBCL runtime auto-finds a core named `sbcl.core` sitting beside it**, with
no arguments, no `SBCL_HOME` and no launcher shim — verified. Only that exact name works
(`myapp.core` beside `myapp` is not found). So the shape is: `Contents/MacOS/{myapp,
sbcl.core}`, and the wrapper-script problem ADR-0013 rejected does not come back.

## The open decision (2026-08-06) — tried, proven, and what is left

*The signing question is [#98](https://github.com/codelisperer/ouranos/issues/98). This
section exists so the choice can be made from evidence rather than re-derived. Everything
below was run on macOS 26 / SBCL 2.6.5 (Homebrew) / Apple silicon.*

### Tried and ruled out

| Attempt | Result | Why |
|---|---|---|
| `install_name_tool` on the dumped image | **fails** | `__LINKEDIT` does not cover the end of the file — the core is appended past it |
| Bind `sb-ext:*runtime-pathname*` to a patched copy | **no effect** | a Lisp special; the prepended bytes come from the C runtime's own path |
| `codesign` the dumped image | **fails** | `main executable failed strict validation` — same appended core |
| `codesign` the `.app` around it | **fails** | the bundle signature covers the main executable, so it inherits the failure |
| Delete the stale `_CodeSignature` | **no effect** | the cause is the signature *embedded* in the image, inherited from the runtime |
| Add a real Resources payload (`.icns`) | **no effect** | `spctl` verdict unchanged; it is not about resources |
| Strip the embedded signature | **not viable** | that ad-hoc signature is what lets the binary execute on Apple silicon |
| Ad-hoc sign app *and* carried dylib | **fails** | ad-hoc has no Team ID, so two ad-hoc binaries do not match each other |
| `$ORIGIN` / rpath (ADR-0013) | **ruled out earlier** | needs `patchelf`, and is Linux-only |
| Wrapper script setting `DYLD_*` | **ruled out earlier** | changes what the user launches; inherited by `hyperion-view` |

### Proven to work

| | Status |
|---|---|
| Patch the runtime *before* the dump → `@executable_path` | **shipped** — this ADR |
| Runtime + core as separate files: `codesign --options runtime` + `--verify --strict` | **verified valid** |
| Runtime compilation under hardened runtime, with `allow-jit` | **verified** — Coalton compiles |
| Runtime auto-finds `sbcl.core` beside it, no args, no `SBCL_HOME` | **verified** — no shim needed |
| Carried dylib + hardened runtime, same signing identity | **partly** — works with library validation disabled; the real-Team-ID path is untested (needs the Developer ID, not the Program membership) |

### The remaining options

**A — Stay as we are: ad-hoc, "right-click > Open."**
*Buys:* nothing new; costs nothing; keeps the single binary and ADR-0010's updater intact.
*Breaks:* every macOS user meets a "cannot be verified" dialog on first launch, and some
managed Macs refuse it outright. A user holding a valid Developer ID still cannot ship a
clean-installing app, which is the part that is ours rather than Apple's.

**B — Runtime + core in `Contents/MacOS/` (the Electron shape).** *Recommended.*
*Buys:* a signable, notarizable app. Every prerequisite is now verified, including the
core-discovery question that looked hardest.
*Breaks:* the single-binary property. ADR-0010's updater must swap **two** files atomically
(runtime and `sbcl.core`) and must not leave a mismatched pair on a crash or power loss —
that is the whole of the remaining work, and it is an updater problem, not a macOS one.
*Also:* carried libraries must be signed with the same identity (Team ID matching), and
`scripts/verify-bundle-macos.sh` check 2 needs a new mechanism because hardened runtime
strips `DYLD_*`.

**C — Hybrid: `:executable t` for CLI/dev artifacts, runtime + core only for the signed `.app`.**
*Buys:* keeps the single binary where the updater already works.
*Breaks:* two artifact shapes to build and test, and **the thing shipped is not the thing
tested locally** — precisely the "green is not evidence" hazard this tree keeps catching.
Worth considering only if B's updater work proves genuinely hard.

**D — Build SBCL ourselves, without core compression.**
*Buys:* removes the zstd dependency at the source, so this ADR's whole patch-the-runtime
mechanism becomes unnecessary; also gives control over the core path.
*Breaks:* every contributor and CI runner builds SBCL. ADR-0013 rejected static linking on
exactly this ground and the objection stands — building one library from a pinned tarball is
not the same commitment as building the implementation. Listed because it solves two problems
at once and should be rejected knowingly, not by omission.

**E — Distribute to developer audiences via a Homebrew cask.**
*Buys:* possibly sidesteps the first-launch dialog for the audience most likely to install
this. **UNVERIFIED** — whether a cask can still avoid quarantine, and under what conditions,
was not checked. A partial mitigation for A at best, never a substitute for signing.

### What B actually ships — the file inventory

Measured from a real bundle (`uv-probe`, macOS/arm64). **B changes exactly one file into
two; nothing is added or removed and the total size is unchanged.**

| File | Today (A) | Under B | Signed? |
|---|---|---|---|
| the dumped image | **73.3 MB** | *splits* | cannot be |
| → SBCL runtime | — | **332 KB** | yes: hardened runtime + `allow-jit` |
| → `sbcl.core` | — | **~73 MB** | data; sealed as a bundle resource |
| `hyperion-view` | 69.8 KB | 69.8 KB | yes — separate Mach-O, nested code |
| `libuv.1.dylib` (ADR-0013, dlopen'd) | 211.7 KB | 211.7 KB | yes — Team ID must match |
| `libzstd.1.dylib` (ADR-0014, linked) | 634.4 KB | 634.4 KB | yes — Team ID must match |
| `VERSION` | 6 B | 6 B | sealed |
| `LICENSES/` | 5 files | 5 files | sealed |
| `<app>.icns` (in `Resources/`) | — | — | sealed |

Two further findings, both verified, that settle how the core is placed:

- **Core discovery is EXECUTABLE-relative, not cwd-relative.** Running the runtime from `/`
  — which is the working directory LaunchServices gives a `.app` — still finds the adjacent
  `sbcl.core`. Had it been cwd-relative, B would have needed the launcher shim after all.
- **A symlink works**: `Contents/MacOS/sbcl.core` → `../Resources/sbcl.core` is followed. So
  the core can live in `Resources/`, which is where Apple expects non-executable payload and
  where the bundle signature seals it, without giving up adjacency. Preferred layout.

Worth noting for option D: `libzstd` is the largest thing in the bundle after the core, and
we carry it *only* because the SBCL in use was built with core compression. Splitting the
core does not remove the need — the runtime's `LC_LOAD_DYLIB` is unconditional — so only
building SBCL ourselves eliminates it.

### What would change the answer

1. **Does Windows `signtool` accept a dumped SBCL `.exe`?** Unchecked, and the `.exe` has the
   same appended-core structure. If it fails too, this stops being a macOS decision and B
   becomes near-mandatory. **Cheapest decisive experiment available** — a Windows session can
   settle it in minutes.
2. **Does the carried-dylib path work with a real Team ID**, without
   `disable-library-validation`? Local, needs only the existing certificate.
3. **Does notarization actually pass for shape B?** Needs an active Program membership; the
   certificate alone is not enough. Last step, not first.

### The gate is resolved: Windows fails differently and lands in the same place

*Measured 2026-08-06 by Ouranos Claude (Windows) on windows-x86-64, SBCL 2.6.6. Full
evidence in [#98](https://github.com/codelisperer/ouranos/issues/98).*

The recommendation below was gated on one question: does Windows `signtool` accept a dumped
SBCL `.exe`? **It does — and the signed binary then cannot start.**

| | macOS | Windows |
|---|---|---|
| sign the dumped image | `codesign` **refuses** ("failed strict validation") | `signtool` **succeeds**, exit 0, well-formed signature |
| the result | nothing to ship | `Can't find sbcl.core` — the image will not start |
| sign runtime + external core | works, `--verify --strict` valid | works, runs normally |

Causal, not correlational: removing the signature returns the file to a byte-exact
76,099,328 and it runs again. Authenticode appends the certificate table to the end of the
PE; SBCL seeks from the end to find its appended core. The same *shape* of collision as
macOS — the core occupies the region the signature needs — reached by a different route.

**So this is not a macOS decision.** Neither platform can ship a signed, working single-file
dumped image, and both can ship a signed runtime with a detached core. Option B is the
answer for the tree.

Two further Windows results worth recording:

- **There is no Windows analogue of the libzstd problem.** Every DLL the dumped image and
  the runtime name is a Windows system DLL (`msvcrt.dll` is the OS legacy CRT, not a
  redistributable). `:sb-core-compression` is NIL on that SBCL and libuv is built `/MT`
  (#84). ADR-0014's carry-and-repoint has nothing to carry there beyond `libuv.dll`, which
  the bundler already copies. The mechanism stays macOS-only.
- **windows-arm64 is still untested** and would have produced a false pass under emulation —
  filed as pre-publication issue 145.

### A new cost of option B: the core is not signed

Surfaced by the Windows work and not anticipated anywhere above. The core is a data file,
not a PE or a Mach-O, so **Authenticode and codesign cover the loader, not the program.**

A signed single-file image is tamper-evident in full. A signed runtime plus an unsigned core
means the application's actual logic is unsigned and replaceable, while the artifact still
presents a valid signature and a trusted publisher — which is arguably worse than being
unsigned, because it looks verified. On macOS a core placed in `Contents/Resources/` is
sealed by the bundle signature, which covers it; on Windows there is no bundle, so nothing
does.

*Narrowed 2026-08-07, by measurement.* The paragraph above first said macOS only "partly"
covers this. It covers it fully, and the correction matters because it changes the price of B.

Claude.app's `Contents/_CodeSignature/CodeResources` seals `Resources/app.asar` along with
ten other payload entries — so an Electron app's payload **is** covered by the bundle
signature on macOS. A core in `Contents/Resources/`, reached by the symlink already verified
above, gets identical treatment. **So B's integrity gap is Windows-only**, where there is no
bundle and nothing seals a sibling file.

**And it is a gap the industry already lives with rather than one we would be inventing.**
Electron on Windows has exactly this exposure and ships an opt-in asar-integrity mechanism
for it. (Looked for its fuse sentinel in Claude.app's binary and did not find one, so
whether *that* app enables it is unknown — the mechanism's existence is the point.)

So the remaining work is: **the runtime hash-verifies its core, on Windows.** Bounded, and
matching prior art rather than setting a standard. It should still be designed in rather
than retrofitted, because adding integrity to a shipped update mechanism is much worse than
starting with it.

### Where the other frameworks actually sit

Worth stating plainly, because "do Electron and Tauri just accept the warning?" is the
obvious question and the answer is that they never face it. There are three shapes and we
have access only to the worst:

| Shape | Who | Payload |
|---|---|---|
| Linked into the signed binary | **Tauri, Wails** | `include_bytes!` / `embed.FS` — inside the signed region, at LINK time |
| Signed loader + sealed sibling | **Electron** | `Contents/Resources/app.asar` |
| Appended OUTSIDE the signable region | **us, today** | the core, welded on after the linker has finished |

Tauri and Wails get one file *and* full signature coverage, which is strictly better than
either of our options — and is structurally unavailable to SBCL, because `save-lisp-and-die`
runs after the linker. That is the root of this whole ADR. **Option B is Electron's shape**,
and adopting it puts us where the mainstream already is rather than somewhere novel.

### Recommendation

**B — and the gate is now open.** Its prerequisites are verified rather than hoped, the
core-discovery objection evaporated, and the Windows measurement settled the remaining
question: this is the tree's answer, not one platform's.

Two costs to scope before starting, neither of which is Apple's fee:

1. **A two-file atomic update.** ADR-0010's updater must swap runtime and core together and
   never leave a mismatched pair. Well understood, ordinary work.
2. **Core integrity** (above). The signature does not cover the core, so the runtime should
   verify it. This was not anticipated and is the one part of B that is genuinely new
   engineering rather than rearrangement.

The maintainer owns the decision; the measurements are no longer the obstacle.

## Provenance

**This was found by looking, not by reasoning.** The macOS half of #78 was expected to be
mechanical — ADR-0013 had settled the mechanism and the library-carrying code was already
platform-neutral, so the first bundle built here carried `libuv.1.dylib` correctly on the
first attempt. The `otool -L` that turned up `libzstd` was run to confirm there was nothing
left to do.

The lean that had to be abandoned was ADR-0013's own sentence, "macOS needs no
`install_name_tool`". It was written about `dlopen` and is true about `dlopen`; it read as a
statement about macOS. Two later attempts to avoid the tool — patching the image, then
redirecting `*runtime-pathname*` — both failed for the same underlying reason, and finding
that reason (the appended core) is what produced the working mechanism *and* the notarization
finding above. The order matters: the blocked-signing consequence was not anticipated and
would not have been discovered by implementing the happy path.

The clean-room argument also came out stronger than it went in. ADR-0013 asks for a machine
that never built the tree, which macOS cannot supply as cheaply as a container. It turns out
not to need one for *this* class: because a missing linked library is fatal at process start
with no fallback chain, the control run is decisive anywhere — including on the machine that
built it.
