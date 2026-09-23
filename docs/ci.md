# CI — what the matrix proves, and what it deliberately does not

Two workflows, and they answer different questions.

| Workflow | Question it answers | When |
|---|---|---|
| [`verify.yml`](../.github/workflows/verify.yml) | *Does the whole tree build and pass on Linux, macOS and Windows?* | all three on every PR, every push to `main`, weekly, and on demand |
| [`desktop-release.yml`](../.github/workflows/desktop-release.yml) | *Does a desktop bundle build and run on a machine that has never seen this repo?* | app-scoped tags, manual |

This page is about the first. The second is documented at
[`hyperion/docs/desktop-distribution-design.md`](../hyperion/docs/desktop-distribution-design.md)
and ADR-0010/0013.

## Why a matrix exists at all

Three claims in `ECOSYSTEM.md` and the README are load-bearing and are otherwise
unevidenced:

1. **"SBCL-exclusive, and `sbcl --script` is uniform across Linux/macOS/Windows."** The
   LF-line-endings rule exists *because* a CRLF checkout broke the Windows build twice.
   Only a Windows runner notices that class of thing.
2. **"The pinned libuv builds everywhere from its own first-party toolchain."** Every leg
   runs `scripts/build-libuv.lisp`, so this is checked three times per run.
3. **The Coalton pin is valid on native amd64.** This one cannot be checked any other way,
   and it is worth stating plainly:

> A local `docker build --platform linux/amd64` on Apple Silicon **proves nothing about
> amd64**. It runs under QEMU, which mis-emulates SBCL's compile-time 64-bit overflow
> folding and produces *spurious* failures in Coalton's `library/math/bounded` (#110). A
> red local amd64 build is not evidence of an incompatibility, and a green one is not
> evidence of compatibility. The `ubuntu-24.04` leg is the only native amd64 signal this
> project has.

## Which legs run

Every event — a pull request, a push to `main`, the weekly cron and `workflow_dispatch` —
runs all three legs, and the release-mode job on Linux. Standard GitHub-hosted runners are
free for public repositories, so there is no cost reason to run fewer.

The `ubuntu-24.04` leg is the **native amd64** signal, the one piece of evidence that cannot
be obtained any other way. The breaks the other two catch — a CRLF checkout, a path
separator, anything specific to arm64 — now show up on the pull request that causes them,
rather than after it merges.

**Before the repo went public**, Actions minutes carried a 10× multiplier for macOS and 2×
for Windows. Pull requests ran `ubuntu-24.04` alone, pushes to `main` added Windows, and
macOS ran only on the weekly cron and on dispatch. The release-mode job skipped pull
requests for the same reason.

Note that CI does **not** gate the first public release. `docs/launch/release-scope.md`
still lists it under "Hard blockers", but the #91 decision recorded in `ECOSYSTEM.md`
(2026-08-24) supersedes that: CI and clean-machine bootstrap (#88) *follow* the launch,
because they are evidence aimed at **contributors**, and v0.1 is aimed at the thesis.

## CI is a caller, not a place where build knowledge lives

Every step is a repo script a developer runs identically on their own machine:

```sh
scripts/setup.sh --ci                                    # or setup.ps1 -CI
sbcl --dynamic-space-size 4096 --script bootstrap.lisp   # OURANOS_NO_WARM=1
sbcl --dynamic-space-size 4096 --script scripts/install-deps.lisp
sbcl --dynamic-space-size 4096 --script scripts/check-coalton.lisp
sbcl --dynamic-space-size 4096 --script scripts/build-libuv.lisp
sbcl --dynamic-space-size 4096 --script scripts/verify-tree.lisp
```

### `resolve` is not `fetch` — the step the first CI run proved is not optional

`asdf:load-system` **resolves** dependencies; `ql:quickload` **fetches** them.
`verify-tree.lisp` uses the former on purpose, because quickload does not escalate a
compile-time `WARNING` to a failure. On a developer machine the difference is invisible —
the dependencies are already installed. On a runner, which has installed nothing, **23 of
30 systems failed to load** and the tree reported `FAIL` over `Component "log4cl" not
found`.

The tempting fix — drop `OURANOS_NO_WARM` and let `bootstrap.lisp` warm the stack — is
wrong, and quietly so. Warming compiles *our* tree with quickload, and once a fasl exists
the file is merely **loaded** afterwards. Coalton reports an unused binding as a full
`WARNING` that ASDF escalates to a build failure, so a warm tree makes the gate blind to
the exact class of defect it exists to catch. **The gate must do the compiling.**

### Platform-guarded dependencies

`install-deps.lisp` asks for the set **applicable to the platform it is running on**, and
the Windows leg is why. `praxeon/web` declares

```lisp
(:feature (:not :windows) "clack-handler-woo")
(:feature :windows "clack-handler-hunchentoot")
```

because Woo binds libev through CFFI at load time and libev does not build on Windows. The
tree was already right; the enumeration was flattening the guard away, so the installer
asked Quicklisp for a system that cannot exist on that platform and the leg went red.

A drift report wants the opposite — both names belong in `docs/dependencies.md`, whatever
platform you happen to run `check-deps.lisp` on — so the guard is *returned* rather than
discarded and each caller decides. Anything dropped is **printed by name** under
`not applicable to this platform`: a step that quietly installs less than the tree declares
reads as full coverage, which is this repo's recurring failure one level up.

So `scripts/install-deps.lisp` installs **third-party systems only**. It can compute that
set before a cold build because `asdf:find-system` reads a `.asd` without building it. The
enumeration lives in `scripts/tree-deps.lisp`, shared with `scripts/check-deps.lisp` —
which asks the same question in order to report drift against `docs/dependencies.md`, and
two copies of "what does this tree depend on" is exactly the drift that script exists to
catch.

If a step needs logic, the logic goes in the script. There are exactly **two** exceptions,
and both are facts about *runner images* rather than about this tree: the caches, and
standing up a Postgres.

### Reproducing a CI run locally

```sh
scripts/test-postgres.sh up
eval "$(scripts/test-postgres.sh env)"
OURANOS_WITH_UV=1 sbcl --dynamic-space-size 4096 --script scripts/verify-tree.lisp
```

That is the same gate the matrix runs. `OURANOS_WITH_UV=1` requires
`scripts/build-libuv.lisp` to have run first.

## The gate is `verify-tree.lisp`, never a bare `asdf:test-system` loop

A system with no `:perform (test-op …)` loads its files, **runs nothing, and exits 0** —
aion was reported green through an entire Coalton upgrade having executed zero checks
(#116). A workflow built on exit status alone would reproduce that failure faithfully and
call it success.

`scripts/verify-tree.lisp` fails on: a system that will not load, a suite that ran **zero**
checks, a deferred compile `WARNING`, a failing check, and — since #176 — a suite that
reports per-backend coverage which never reached Postgres. Every system and every suite
runs in **its own fresh SBCL**, so one system cannot silently satisfy another's undeclared
dependency.

## The toolchain, per OS

Pins live in [`scripts/versions.env`](../scripts/versions.env) and the repo-root
`coalton.pin` — one set for CI and dev machines both.

- **Linux** — the official SBCL binary tarball at the pinned version. That pin sets a
  **glibc floor**: SBCL 2.6.8's Linux binary needs `GLIBC_2.38`, which `ubuntu-22.04`
  (2.35) does not have, so the matrix runs `ubuntu-24.04` and binaries produced here need
  glibc 2.39+. Lowering that means building SBCL from source.
- **macOS** — **Homebrew, not the pin.** Upstream publishes no macOS SBCL binaries, so
  there is nothing to pin to and the machine gets whatever brew carries.
  `setup.sh --check` passes on the mismatch deliberately: it checks *presence*, not
  equality. `macos-14` is arm64, which is precisely why the Linux leg matters.
- **Windows** — the official MSI at the pinned version.

## The two caches, and why one has no fallback

**Downloads** (`~/quicklisp`, `~/common-lisp/coalton`) are content-addressed by the pins
and carry `restore-keys`. A near-miss restore is safe because `setup.{sh,ps1}` re-check
and re-fetch anything that does not match.

**Fasls** get **no `restore-keys` at all** — exact key or cold build. The key names both
pins and every `.asd` in the tree.

This costs wall-clock and buys truth twice over:

- Mixing fasls compiled against one dependency set with sources from another makes CI
  intermittently red for reasons that look like nothing. Observed as `The class
  <DBD-POSTGRES-QUERY> is being redefined to be a DEFTYPE` — did not reproduce in
  isolation, passed 6/6 on an identical re-run (#87).
- **Only a cold build surfaces Coalton's deferred `WARNING`s.** Once a fasl exists the file
  is merely *loaded*, so an unused binding passes locally forever and fails on someone
  else's fresh clone ([`coalton-patterns.md`](coalton-patterns.md) §8a).

## Postgres — and why no leg is excused

`MNEMOSYNE_TEST_PG_URL` is the contract (see `mnemosyne/tests/backends.lisp`); a container
is one way to satisfy it and a server the runner already ships is another.

- **Linux** calls the repo's own `scripts/test-postgres.sh up`.
- **macOS** installs and starts `postgresql@17` via Homebrew, and installs pgvector from
  Homebrew.
- **Windows** starts the PostgreSQL service the runner image already ships, discovering
  the major version rather than hardcoding a path that will rot. The image does not ship
  pgvector, so the leg builds it from a pinned tag and checks the tag's commit.

The macOS and Windows legs both check that the running server can see pgvector before any
suite runs, so a pgvector that did not install fails the step instead of letting the vector
tests skip.

**No leg sets `OURANOS_ALLOW_NO_PG`.** Every check mnemosyne had ever reported green ran
against SQLite alone — the one backend the docs do not tell you to deploy on — and #165 is
what that cost: 2645 green checks at the same commit that silently stored the four
characters `"false"` in a Postgres text column. A matrix that excuses Postgres on the
awkward platforms re-acquires that blind spot one leg at a time, and it would be
**invisible**, because the suite stays green either way. If a runner image stops shipping a
usable Postgres, the honest response is to fix the provisioning or go red — not to excuse
the leg.

The port is **not** pinned to 55432 on the native legs. That number exists in
`docker-compose.test.yml` to stop a developer's real server being shadowed or silently
`CREATE TABLE`'d into; a runner has nothing to protect, and forcing a preinstalled service
onto another port is fragility bought for nothing.

## What the matrix does **not** cover

- **The desktop window.** `hyperion-view` links WebKitGTK/GTK, which is *declared, not
  bundled*. In a bare container the app starts, serves, and exits without a window;
  verifying the window needs a runner with the GTK stack and a display.
- **Clean-room bundle verification on macOS and Windows.** Only the Linux half exists
  (`scripts/verify-bundle.sh`, in `desktop-release.yml`); the other two need a runner with
  nothing installed, or a fresh VM. The shared design is ADR-0013.
- **`elenchon/tests`.** Deliberately unwired — a `:perform` over an empty suite relocates
  the dishonesty rather than removing it.
- **Anything on a `+known-warnings+` or `+known-empty+` line** in `verify-tree.lisp`. Those
  are exceptions someone *made*, each with its reason recorded, and they are the first
  place to look when a green run feels too easy.

## When a leg dies for reasons that are not the code

- **Killed by a signal (exit ≥ 128).** 40+ sequential SBCL images each reserving a 4 GB
  heap is the shape that attracts an OOM killer. `verify-tree.lisp` retries such a child
  **once** and reports it if it dies twice — a false red is as corrosive as a false green.
- **`fail-fast: false`** everywhere: one OS failing must never hide the other two.
- **The weekly run** exists because the tree can go red with no commit — a Quicklisp dist
  that stops resolving, a runner image that drops a preinstalled Postgres, a brew formula
  that moves.
