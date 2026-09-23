# Getting started — build an agent-powered website with Ouranos

Ouranos is a toolkit for **agent-powered web apps in Common Lisp — no JVM, no Node**:

- **hyperion** — the web framework (HTMX + Parenscript + a live, hot-reload image),
- **praxeon** — the agent framework (provider-neutral LLMs; actors / means / ends),
- **mnemosyne** — data & persistence (SQLite → Postgres → XTDB 2),

with **aion** (functional stdlib), **elenchon** (testing), and **cons** (project tooling)
underneath, plus **hermes** (a satellite leaf-lib: external integrations — email + SMS
today, plus payments) off to the side. Your app is its **own repo** built *on* these
frameworks — the shipped worked
examples are under [`../praxeon/examples/`](../praxeon/examples) (Elise, ChatRBT).

> Hacking on the frameworks themselves, not building an app on them? See
> **[contributing.md](contributing.md)** instead.

## 1. Prerequisites

Three Lisp things, and **a script installs all of them** — you do not have to do this by
hand:

```sh
./scripts/setup.sh          # macOS / Linux    (setup.ps1 on Windows)
./scripts/setup.sh --check  # report what is missing, change nothing
```

**What the machine needs before that script can run.** These are ordinary tools the script
downloads *with*, so it cannot install them for you — it names all of them in one go and
refuses until they are there:

| | Linux | macOS |
|---|---|---|
| clone, download, unpack | `git`, `curl`, `tar`, **`bzip2`** | `git`, `curl`, `tar` |
| **libev** — Woo binds it at *load* time (hyperion) | `libev-dev` | `brew install libev` |
| **libsqlite3** — cl-sqlite binds it at *load* time (mnemosyne) | `libsqlite3-dev` | ships with macOS |

`setup.sh` installs the two libraries for you **when it already has root**; otherwise it
prints the exact command. They are not optional: they are bound when the system *loads*, so
without them `bootstrap.lisp` builds `bin/cons` and the tree still does not work.

`bzip2` catches people out: the SBCL tarball is bz2-compressed and `tar` shells out to the
`bzip2` **binary**, which minimal images and containers often omit.

`setup.sh` **verifies itself before claiming success**: it re-runs its own `--check` at the
end, so an exit of 0 means the machine really is provisioned and `bootstrap.lisp` is
genuinely the next step. This whole sequence is exercised on an operating system that has
none of it by [`scripts/verify-clean-machine.sh`](../scripts/verify-clean-machine.sh).

| | What | Why it is pinned |
|---|---|---|
| **SBCL** | the implementation | Version in `scripts/versions.env`. SBCL-only by design |
| **Quicklisp** | the dependency source | Pinned to a dated **dist snapshot**, so everyone resolves the same library versions |
| **Coalton** | the typed language | **A git checkout at the commit in [`coalton.pin`](../coalton.pin)** — *not* a Quicklisp system. Coalton moves fast and its ASDF `:version` is `0.0.1` on every commit, so the SHA is the only meaningful identifier |

`setup.sh` is idempotent; anything already present at the right version is left alone. It
needs no sudo for SBCL, Quicklisp or Coalton — those all land under your home directory —
but libev is a system package and does need root. Verify what actually loads with
`sbcl --script scripts/check-coalton.lisp`, which checks the pin against the checkout
*and* probes behaviour, because a stale fasl cache can make a correct setup look wrong.

The first Coalton compile is cached after; expect it once, not every time. Measured cold, from
a fresh clone with an empty fasl cache, on recent hardware: **2m09s** on Windows 11, **1m45s**
on Linux (WSL2). Older or slower machines will take longer — but if it has been sitting there
for ten minutes, something is wrong, which is the point of quoting a number rather than "a few
minutes".

**About `--dynamic-space-size 4096`.** It is not there to get the compile through: the heavy
compiling happens in child processes that set their own heap, so the seed completes without it.
It matters because `bin/cons` **inherits the heap of the process that built it** and cannot be
given a different one afterwards — the binary passes its arguments to `cons`, not to SBCL, so
`bin/cons --dynamic-space-size 4096` is read as a `cons` argument.

**You no longer have to remember it.** If your SBCL's heap is smaller than the seed wants,
bootstrap says so and restarts itself with the right one:

```
bootstrap: this SBCL has a 1024 MB heap; bin/cons would inherit it permanently.
bootstrap: restarting with --dynamic-space-size 4096. (OURANOS_BOOTSTRAP_KEEP_HEAP=1 to keep this heap.)
```

Measured on Linux: dropping the flag entirely still produces a **4096 MB** `bin/cons`. Keeping
the flag in the command above simply skips the restart. If you deliberately want the smaller
binary, `OURANOS_BOOTSTRAP_KEEP_HEAP=1` keeps it — and warns, because the consequence is
permanent and otherwise invisible. `sbcl --script scripts/baked-heap.lisp bin/cons` answers the
question at any time.

**One optional extra, for one opt-in system.** `aion/uv` (libuv: event loop, async and
sync filesystem, timers, file watching) needs **a C compiler — the one your OS already
ships**: Xcode Command Line Tools on macOS, your distribution's gcc/clang on Linux, MSVC
on Windows. Not MSYS2, not cmake, not make. Nothing else in the tree needs it, and no C
toolchain is ever required merely to *load* anything here.

## 2. Install the frameworks

Ouranos is pre-alpha, so there's no package release yet — you install the frameworks by
cloning the monorepo and running its seed once:

```sh
git clone https://github.com/codelisperer/ouranos.git
cd ouranos
sbcl --dynamic-space-size 4096 --script bootstrap.lisp
```

That builds `bin/cons` and writes a **user-global** ASDF drop-in, so **every framework in the
tree is on your Lisp load path** for every project on the machine — no per-project setup. The
drop-in is `50-ouranos.conf`, under a directory that differs by OS:

| | |
|---|---|
| macOS / Linux | `~/.config/common-lisp/source-registry.conf.d/` |
| **Windows** | `%LOCALAPPDATA%\config\common-lisp\source-registry.conf.d\` |

Bootstrap prints the full path it wrote, so you never have to guess:

```
bootstrap: source-registry -> .../common-lisp/source-registry.conf.d/50-ouranos.conf
```

To check it took, ask a plain REPL — with no `CL_SOURCE_REGISTRY` set — where it thinks `aion` is:

```lisp
(require :asdf)
(asdf:system-source-file (asdf:find-system :aion))   ;; => your checkout's aion/aion.asd
```

Bootstrap also builds the native webview launcher, which a desktop app needs to open its
window. It is gitignored, so a fresh clone does not have it. When the machine has a C++
toolchain, bootstrap builds it and prints:

```
bootstrap: launcher built -> .../hyperion/hyperion-view/hyperion-view
```

When the machine lacks a prerequisite, bootstrap prints the build script's report of what is
missing, then `bootstrap: launcher NOT built`, then the command to run once it is installed:

```sh
cd hyperion/hyperion-view && ./build.sh --check     # Windows: .\build.ps1 -Check
./build.sh                                          # Windows: .\build.ps1
```

Nothing else depends on the launcher, so bootstrap carries on without it. Set
`OURANOS_SKIP_VIEW_BUILD=1` to skip the step.

## 3. Create your app

The one-liner is `cons init my-site --template web` (or `--template agent`), and it
works today — `cons` implements `init` / `setup` / `conform` / `env` / `db-repl` / `db-url` / `template check` / `version`. `cons setup` then puts the app on the
load path with its own drop-in beside Ouranos's; the rest of this section is what that
does for you:

```lisp
;; macOS / Linux: ~/.config/common-lisp/source-registry.conf.d/60-my-site.conf
;; Windows:       %LOCALAPPDATA%\config\common-lisp\source-registry.conf.d\60-my-site.conf
(:tree "/Users/you/projects/my-site/")
;; On Windows, write the path with FORWARD slashes -- backslash is the Lisp reader's
;; escape character: (:tree "D:/projects/my-site/")
```

`conf.d` is additive, so `(ql:quickload :my-site)` resolves hyperion / praxeon /
mnemosyne from the Ouranos tree automatically. (The planned `cons setup` writes this file
for you.) Your app sits *above* the frameworks — they never depend on it.

## 4. Build something

An agent-powered page is a **hyperion** web surface driving a **praxeon** actor. The
shipped example is **Elise** ([`../praxeon/examples/elise`](../praxeon/examples/elise)) —
a reflective agent with a hyperion web UI (`praxeon/web`), a crisis guardrail, and a
multilingual translator. Run it to see the shape end to end:

```lisp
(ql:quickload :praxeon/elise)
;; set your provider in .env (PRAXEON_LLM_* — see ../praxeon/.env.example), then:
(praxeon/elise:start)
```

Then read [`../praxeon/docs/user-guide.md`](../praxeon/docs/user-guide.md) (agents,
provider config, the deliberate/act loop) and
[`../hyperion/docs/user-guide.md`](../hyperion/docs/user-guide.md) (web surface, HTMX,
hot-reload), and model your app on Elise / ChatRBT.

## 5. The dev loop

hyperion is REPL-driven with hot-reload: edit → recompile into the running image → the
browser refreshes around preserved state (state ≠ server). `(ql:quickload :your-app)`,
start its server, and edit live. (The intended `cons serve` is in progress.)

## 6. Deploy

- **Dev** resolves the frameworks from your Ouranos checkout via the drop-in.
- **Production** (e.g. a Docker image) must ship a **pinned** Ouranos — a git submodule /
  `git subtree` pin now, or the ocicl route once cons's dependency story lands — so builds
  are reproducible and don't depend on "whatever's on the build machine."

## Where next

- Per-framework user guides: [`../hyperion/docs/`](../hyperion/docs),
  [`../praxeon/docs/`](../praxeon/docs), [`../mnemosyne/docs/`](../mnemosyne/docs).
- The ecosystem thesis + dependency DAG: [`../ECOSYSTEM.md`](../ECOSYSTEM.md).
- Contributing to the frameworks: [contributing.md](contributing.md).
