# ADR-0001: Ouranos builds and publishes its own SBCL binaries

**Status:** Accepted. Decided by the maintainer on 2026-11-15 (#1251); recorded 2026-11-24.
Partly carried out: the Linux x86-64 and macOS arm64 builds run in CI (#1253, #1262). The
Windows build, the first published release and the switch of setup to these builds are still to
do; #1251 lists them.

## Context

`scripts/setup.sh` and `scripts/setup.ps1` installed the SBCL binaries that SBCL's maintainers
publish on SourceForge, checked against SHA-256 values in `scripts/versions.env`. Two things made
that a weak foundation:

- **SourceForge refused SBCL downloads in some locations.** From 2026-11-12, two of the
  maintainer's machines got a 445-byte "Download Forbidden ... We cannot send this file to your
  location" page for every SBCL file, through both of SourceForge's download hosts (#1216). A fresh
  setup there could not install the pinned SBCL at all, and the SBCL 2.6.10 bump (#1214) could not
  read the new checksums. On 2026-11-24 SourceForge served one of those machines again, so the
  block came and went; it was never under this project's control.
- **The project depended on someone else's build and hosting.** If SBCL's maintainers stopped
  publishing a binary for a platform, or stopped publishing at all, a new machine could not be set
  up. Upstream already publishes no macOS binary and no arm64 Linux binary, which is why macOS
  takes whatever SBCL Homebrew carries.

## Decision

Ouranos builds SBCL from source in its own CI and publishes the binaries as releases of this
repository. Setup will download those, checked against pinned SHA-256 values, instead of
SourceForge's.

1. **Source.** `codelisperer/sbcl` is a fork of `github.com/sbcl/sbcl`, the official mirror of
   SBCL's git repository, with all release tags and no patches of our own. A patch, if one is ever
   needed, goes on a named branch and is recorded in a new ADR. `sbcl.pin` names the repository,
   the release tag and the tag's commit; `scripts/build-sbcl.sh` refuses a checkout whose commit
   differs from the pin. The first build is SBCL 2.6.10, tag `sbcl-2.6.10`, commit `ee8952af`.
2. **Build.** `.github/workflows/sbcl-build.yml` runs `scripts/build-sbcl.sh` on each platform. The
   script builds SBCL twice, as SBCL's own `release.sh` does: a host Lisp compiles the first build,
   and the first build compiles the second, which is the one that ships. SBCL's own test suite runs
   on the second build, and this tree's gate (`verify-tree.lisp`) runs against it in a separate job.
3. **Options.** `--dynamic-space-size=4096`, `--with-sb-thread` and `--with-sb-core-compression`;
   everything else is `make.sh`'s default for the platform. Upstream's binary has a 1 GB default
   heap and no core compression. The script fails the build if the result reports a different
   version, lacks either feature, has a different default heap, or (on x86-64) did not build
   `sb-simd`, which `make-config.sh` silently leaves out on a build machine without AVX2.
4. **zstd.** Core compression links libzstd. On Linux the runtime links the system's
   `libzstd.so.1`, which every Debian and Ubuntu system has (`libzstd1` is `Priority: required`).
   On macOS and Windows it is linked statically from a zstd release that `sbcl.pin` pins by version
   and SHA-256, and the build fails if the runtime still lists libzstd as a dependency. Compression
   is on for every platform: a feature that some platforms lack is one no app can rely on.
5. **Host Lisp.** Any SBCL can compile the first build: the distribution's package on Linux,
   Homebrew's on macOS. The build record states which one was used. Once our own build of a version
   exists, the next build's host can be our previous release.
6. **Build images.** Linux builds on `ubuntu-24.04` and macOS on `macos-15`, the same images
   `desktop-release.yml` builds on, because a binary needs at least the glibc or macOS of its build
   machine (#766, #763). Each build records the newest glibc symbol or the minimum macOS it needs.
7. **Publishing.** A tag `sbcl-v<version>-ouranos.<n>`, or a dispatch with `publish=true`, creates
   that release and uploads each platform's tarball with a `.sha256` file and a build record. Only
   the publish job can write to the repository, and it cannot run on a pull request. An asset that
   is already in a release is never replaced, so a pinned checksum keeps naming the same file; a
   different build of the same version takes the next `<n>`.
8. **A bump** moves `version`, `tag` and `commit` in `sbcl.pin` and sets `release` back to 1, runs
   the workflow on every platform, reads every leg's SBCL tests and gate, and then publishes.

## Consequences

- A machine that cannot reach SourceForge can be set up once setup downloads our releases. Until
  then, `setup.sh --sbcl-tarball=FILE` and `--use-installed-sbcl` (#1216) let it use a file or an
  installation it already has.
- The SBCL that apps are tested on is one this project built and tested, with the options this
  tree needs, on every platform including macOS, where upstream publishes nothing.
- The project now maintains a build. A new SBCL release needs a workflow run on every platform and
  a look at its tests before it can be pinned, instead of a checksum copied from SourceForge.
- Trust moves from SBCL's maintainers' signature on their binary to this repository's CI. The
  build record (source commit, options, host Lisp, compiler, linked libraries, test result) is what
  a reader has instead, and it is published with every asset.

## Alternatives considered

- **Use a package manager's SBCL** (Homebrew, apt, winget): rejected. Those are different builds
  from the one the tree pins and checksums, at whatever version each manager carries, with options
  this project does not choose (#1216, option 2).
- **Redistribute copies of SourceForge's binaries**, obtained by the maintainer through a network
  SourceForge serves (#1216, option 3): it removes the download problem but keeps the dependency
  on upstream's builds, and gives no macOS binary.
- **Fetch SourceForge's files from a CI runner in another region**: rejected, because it works
  around SourceForge's refusal rather than removing the dependency on it (#1216).

## Provenance

The question started as an SBCL version bump (#1214) and became this decision because of a
download refusal nobody expected. The first response was to read the 2.6.10 checksums from a
GitHub runner; the permission check in the session doing the work refused that push as a way round
SourceForge's block, and the hub withdrew the plan and wrote into #1216 that the project would not
route around the block. Of the three options then put to the maintainer (accept a local file, use a package manager's
build, redistribute SourceForge's binaries), the maintainer chose the first for now and replaced
the third with this one: build from source, so the project depends on SBCL's source rather than on
anyone's binaries. The build options were proposed in #1251 and checked against `make-config.sh`
at the 2.6.10 tag before the first build; that check found that `sb-simd` depends on the build
machine's CPU, which is now a build failure rather than a silent difference. Static zstd on macOS
and Windows was the hub's ruling after the check showed that neither platform has libzstd on a
clean machine. The research, drafting and CI runs were done by AI sessions working for the
maintainer, who made each decision named above.
