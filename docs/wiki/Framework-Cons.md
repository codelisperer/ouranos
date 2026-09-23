# cons — the project & dev tool

*cons the magnificent.* **The missing project and dev tool for Common Lisp** —
cargo for Rust, (p)npm for Node, the `go` tool for Go; `cons` for CL. The name is
doing real work: `cons` is the primordial Lisp constructor, and the tool
*constructs* projects.

---

## What it is / why it exists

Common Lisp's tooling is not *missing* — it is **fragmented**. Each piece is good at
its job and none of them is the front door:

| Tool | Role | Analogue |
|---|---|---|
| **ASDF** | System definition + build | `make` |
| **Quicklisp** | Dependency *distribution* (curated, global-ish, no lockfiles) | — |
| **ocicl** | Modern dep manager with per-project lockfiles / reproducibility | — |
| **qlot** | Per-project Quicklisp pinning | — |
| **Roswell** | Implementation install / version management + script runner | rustup-ish |

There is no single, modern, cargo-class front-end tying these together. The
consequence is that **every CL project reinvents its own onboarding**: a `setup.sh`,
a `Makefile`, a `local-projects` symlink dance, a README section explaining all
three. That recurring boilerplate is `cons`'s reason to exist.

The founding pain was felt directly: the sibling frameworks in this monorepo each
started life with a hand-rolled `scripts/setup.{sh,ps1}` doing SBCL/Quicklisp/Coalton
checks plus symlinking, and a per-project `Makefile`. `cons` is the tool that
collapses all of that into one command — and then, dogfooding, replaces those exact
scripts across the tree.

---

## Where it sits in the DAG

```
aion → cons → mnemosyne → elenchon → hyperion → praxeon
        ▲
        second from the left; may depend only on aion
```

`cons` sits immediately after `aion` and may depend only leftward. In practice it
depends on **neither** — it is pure CL, dependency-light, and deliberately
**Coalton-free** (see the bootstrapping tension below), so `(ql:quickload :cons)`
loads fast and `bin/cons` is trivial to ship.

That position has one sharp consequence, which surfaced when the visual Coalton REPL
idea landed: **cons is to the *left* of hyperion, so cons must not depend on
hyperion.** Anything cons wants that needs a web stack has to be split — see the
Studio split in the design narrative.

---

## Current status

**Pre-alpha (0.0.0)** by version number, but the framework most of the others rest on in the
repo in practice: `cons` already drives every framework's build.

| Surface | State |
|---|---|
| `cons init <name> --template {lib,cli,web,agent}` | **Real.** Scaffolds `.asd`, package-per-module `src/`, `tests/`, hardened `.gitignore`, a committed `.env.example`, `.vscode` Alive config, a `cons.lisp` build spec, README/`CLAUDE.md`. `web` produces a minimal runnable Hyperion app. |
| `cons conform` | **Real.** Installs the AI-conformance pack into a new *or existing* project. |
| `cons <target> KEY=VALUE` | **Real.** The `cons.lisp` build-spec task runner — the Makefile replacement. Drives every framework in this repo. |
| `cons/env` (`load-dotenv`) | **Real.** The shared `.env` loader; consumers delegate to it. |
| `cons setup` | **Real.** Writes the project's ASDF source-registry `(:tree)` drop-in (per-OS via uiop), and reports a stale `local-projects` self-symlink shadowing it. |
| `cons db-repl`, `cons db-url` | **Real.** A database session per environment; the password reaches the child through the environment, never argv. |
| `cons env` | **Real.** Reports which config keys a project needs. |
| `cons template check` | **Real.** Generates a template *and builds it* — a template never generated is a template that does not work. |
| `cons version` | **Real.** |
| `cons add`, lockfiles, the dependency-source protocol | **Planned.** Not built. |

The per-framework `Makefile`s are **gone**, replaced by `cons.lisp` specs. The
per-framework `scripts/setup.sh` remain only as an interim path until `bin/cons`
reaches parity. Distribution is a self-contained binary via `save-lisp-and-die`.

---

## Design narrative

### The founding posture: delegate, don't reinvent

The first and most consequential decision is that `cons` is a **thin, opinionated
front-end that delegates to the best engines and adds DX** — ASDF for build,
Quicklisp/ocicl for dependencies. It does not attempt dependency resolution on day
one. A tool that tried to be a new build system *and* a new resolver *and* a new
scaffolder simultaneously would be unshippable, and worse, would ask users to abandon
what already works.

The escape hatch from "thin forever" is the house style: a **neutral
`dependency-source` protocol** (generic functions: resolve / fetch / load) with
pluggable backends. A **Quicklisp** backend and an **ocicl** backend come first, so
`cons add foo` works with both and meets people where they are. A **native `cons`**
backend comes later — with a real source model (registries / git / local), a genuine
constraint-solving version resolver, and **lockfiles** — and when it is ready you
register it and flip the default. Every command keeps working. The ambition "make
Quicklisp and ocicl obsolete" thereby becomes *adding an implementation*, not a
rewrite. This is exactly the pattern used for Praxeon's LLM providers and Hyperion's
web servers.

### The bootstrapping tension: Coalton, or lean?

Every other sibling has a Coalton typed core. `cons` deliberately does not, and the
reason is an irony it cannot afford: **`cons` is the tool that eliminates setup
friction.** If `cons` itself required the Coalton checkout and the big-heap ritual,
it would be hard to install — the exact disease it exists to cure.

The resolution is *pure-CL core first*, with the option held open to introduce
Coalton later for a genuinely typed sub-part (a typed dependency graph, version
constraints as ADTs). A related question — which collections library `cons` should
use — was answered by *deferral*: collections are an **aion** concern, decided in
aion's vision doc, and `cons` simply consumes whatever aion (or plain Alexandria and
hash tables) provides. It does not pick a collections library of its own.

This lean stance later became a design constraint in its own right: when the Coalton
REPL work arrived, the engine was kept out of `cons` core as an *optional* system
precisely so plain `bin/cons` stays Coalton-free.

### Scaffolding: the wheel is already invented

`cons init` was chosen as the MVP because scaffolding is the recurring pain — and the
vision doc explicitly refuses to write a generator from scratch. The prior art was
surveyed and mined:

| Prior art | What to take |
|---|---|
| **cl-project** (the 40ants fork is better maintained) | The closest existing thing: a `skeleton/` directory rendered through a templating pass. Its layout is the de-facto standard for "what a CL project looks like." *Match its skeleton conventions so generated projects look native.* |
| **quickproject** (Zach Beane) | The minimal, dependency-light generator. The best base for the *lean default* template. |
| **Roswell `ros init <template>`** | The **named-template registry** model — templates as resolvable, pluggable things rather than hardcoded strings. |
| **caveman2 / Radiance** | The framework-specific skeleton shape for a `web` template. |

The synthesis: adopt cl-project's template-directory approach and Roswell's pluggable
registry; keep generation and dependency management as **separate concerns
internally** (the way qlot and CLPM stay separate from the scaffolders), with `cons`
as the front-end unifying both. One caveat is recorded: cl-project pulls a templating
dependency and a test-framework opinion, so the truly-lean *default* template should
follow quickproject's zero-ceremony skeleton, reserving cl-project-style richness for
the framework templates.

A naming wrinkle worth preserving: the original thread called this `cons new`; the
command shipped as `cons init`. The name was reconciled in favour of `init`.

### `cons init` as ecosystem onboarding

An early founder note expanded `init`'s remit well beyond scaffolding: it should also
run the *from-scratch environment setup* a brand-new user needs — install **SBCL**,
**Quicklisp**, **ocicl**, and (if they opt in to contributing) download all the
sibling projects into a directory of their choosing. That is the ecosystem-wide
replacement for every repo's hand-rolled setup script. In the shipped surface this
split into `cons init` (project scaffolding, real) and `cons setup` (environment
bootstrap — now real) — and `setup` is named as the *zero-to-ready* step that
should come next.

### Two scaffolding gaps deliberately recorded rather than papered over

**A framework-aware, composite `.env.example`.** Today the scaffolded `.env.example`
is a generic stub. It should instead **aggregate** the env requirements of the
framework components the project actually depends on: mnemosyne's Postgres connection
vars, praxeon's LLM provider keys, hyperion's `HYPERION_SERVER`. Each framework
component that needs config declares its env keys discoverably — a fragment file, or
a small manifest — and `cons init` walks the chosen template and dependencies (and,
finer-grained, the *features* enabled, not the whole framework's kitchen sink),
composing only the relevant fragments, deduped and sectioned by component. That
closes the env loop end to end: *framework declares → `cons init` aggregates →
`cons/env:load-dotenv` reads.* The open sub-question is the declaration convention —
fragment file vs an ASDF-level manifest vs a `defenv`-style form — and the criterion
is "the lightest thing that stays discoverable **without loading the framework**."

**A working first test.** Today `cons init` emits an empty `tests/` and a test system
with no components, so `cons test` on a fresh project has nothing to run. It should
scaffold a real fiveam package, a root suite, a `run-tests`, wired to `test-op`, with
**at least one test present** — ideally a deliberately failing "implement me" test
(`(is (= 1 2) "replace me with a real test")`). That proves the entire test path is
plumbed, and the red test is a visible, self-explanatory TODO.

### The build spec: why `cons.lisp` and not a Makefile

The `make` replacement is a declarative, Lispy **`cons.lisp`** manifest plus an
**in-process task runner**. A project drops a root `cons.lisp` declaring params and
targets, and `cons <target> KEY=VALUE` then works *identically on Linux, macOS, and
Windows with no GNU-make dependency* — which is the whole point in a repo that treats
`sbcl --script` as the only uniform toolchain.

Two implementation decisions carry real weight:

- **Targets run in cons's warm image by default.** `bin/cons` already carries a 4 GB
  heap and Quicklisp, so a target starts fast instead of paying SBCL startup and
  quickload every time. `--fresh` (or a target's `:isolate`) runs the Lisp work in a
  subprocess SBCL instead, and `:sh` targets always subprocess — which is *required*
  for `save-lisp-and-die`, since an image cannot dump over itself.
- **Dispatch is layered:** a built-in first argument (`init` / `setup` / `conform` /
  `version`) goes to clingon as before; otherwise, inside a project that has a
  `cons.lisp`, the first argument is a target. Bare `cons` lists targets, like
  `make help`.

A hard-won bootstrap detail: because a dumped executable cannot pull contribs from
`SBCL_HOME`, the bootstrap now **bakes SBCL contribs into the image** (`sb-cltl2` and
friends).

And a deliberate omission, recorded in `cons/cons.lisp` itself: there is **no `bin`
target**. Rebuilding `bin/cons` is the repo-root seed's job and must run under raw
SBCL, never under a live `cons` — a running executable cannot overwrite itself
(Windows sharing violation, Linux `ETXTBSY`). The seed needs nothing but SBCL and
Quicklisp, which is exactly what makes the first build possible.

Porting the frameworks onto the runner surfaced and fixed two real framework bugs en
route — `hyperion.asd` depending on the bare Clack servers rather than the Clack
**handler** systems, and a drifted i18n locale-negotiation API in a web layer. That
is the dogfooding argument in miniature.

### `cons conform` — the metaframework dogfood

`cons conform` installs an **AI-conformance pack** into a project, new or existing, so
that an IDE assistant (Claude, Codex, Cursor) generates *spec-conformant* code: a
tool-neutral canonical `AGENTS.md` (the DAG, the typed-core/effectful-shell split, the
Coalton gotchas, the data and web patterns, build/test), with `.cursor/rules` and
`.claude/skills` pointing back at it, and a `CLAUDE.md` that `@`-imports it. It is
pure file emission (uiop only) and fiveam-tested; `cons init` installs the pack
automatically, and existing files are skipped unless `--force`.

The framing matters: this is **cons teaching the AI to use the frameworks**. In a
stack whose stated goal is to be approachable "even for people who hate parens," the
conformance pack is not a nicety — it is part of the product.

### Build targets: one template per project is not enough

The shipped `--template {lib,cli,web,agent}` conflates two things: what the project
*is* and what it *produces*. It cannot express a project that is both a library and a
CLI, or one that ships **several** binaries (a CLI plus a web server), or one that
wants control over binary names.

The resolution is to decouple targets from templates: at project-generation time the
user declares which target(s) to support, and `cons` scaffolds *all* of them at some
minimal level, installing the related AI-conformance packs so the developer (and
their assistant) can build each out. A target becomes `(kind [name])` — the kind
picks the scaffold, the conformance pack, and a default binary name; an optional name
overrides it. Default naming follows compiled-binary convention by kind:

| Kind | Default binary name |
|---|---|
| `cli` | `*-cli` |
| `desktop` | `*-desktop` |
| `lib` (shared library / DLL) | `*-lib` |
| `web` | `*-web` |
| pure CL/Coalton library | the root project name |

The current one-`main`-one-`bin`-per-exec-template gating in `src/init.lisp` is
explicitly the v0 of this; the task is to generalize it to a per-target list.

**The deeper payoff — the kinds ARE UX surfaces over one core.** `api` · `web` ·
`desktop` · `cli` · `mobile` are each a thin adapter over one domain core: the
GitHub / GitHub-Desktop / `gh` pattern. That is the concrete cash value of "declare
several targets" — one domain core, and `cons` scaffolds each surface (a JSON data
API, an HTMX web app, a webview desktop app, a CLI, a mobile client) against it. A
product is *born* multi-UX rather than retrofitted.

### The desktop template, and why sequencing matters

A desktop app is not done when it runs locally; it is done when a tagged commit
produces installers for three OSes and installed copies update themselves. None of
that is per-project thinking, so `cons init --template desktop` should emit it — but
with a specific shape:

**The generated CI workflow must be a thin caller, not a copied pipeline.** The build
knowledge belongs in `cons desktop build|bundle|publish` — the same commands a
developer runs locally — so the emitted `release.yml` is ~20 lines: check out,
provision the toolchain, `cons desktop build`, upload. Cargo users do not hand-write
`rustc` invocations in CI; this is the same argument. It also means a pipeline fix
ships with a **cons upgrade** instead of forcing every app repo to re-sync 150 lines
of YAML it does not understand. (The alternative — a reusable `workflow_call` in the
monorepo — hits a real snag: a reusable workflow's `actions/checkout` grabs the
*caller's* repo, so it needs a second pinned checkout. Worth doing eventually for
non-cons consumers; not the default path.)

The rest of the release surface belongs there too: per-app `VERSION` wiring, the
app-scoped tag convention, `.gitignore` entries for `dist/`, installer inputs (NSIS
script, `Info.plist`, `.desktop` file, icons), the `~/.<appname>` schema-versioned
config, and the updater's channel URL plus **public** key. Plus a `cons desktop
keygen`, because "generate an Ed25519 keypair, commit the public half, put the
private half in CI secrets and your password manager" is exactly the step a human
gets wrong once and notices a release later.

**And the sequencing rule, which is the real lesson:** scaffold *after* the pipeline
has run green at least once. **A template is a force multiplier for mistakes as much
as for good defaults** — propagating an unproven release pipeline into every new
project is worse than having no template at all. The existing root-level desktop
build scripts are the *prototype of these cons verbs*: right shape (repo scripts, CI
merely calls them), wrong home for an external app repo which has no `scripts/` of
ours. Lifting them into `cons desktop` is the actual task.

### A Coalton REPL — and the DAG wrinkle that shaped it

The headline idea here is the **missing interactive, *typed* front-end for Coalton**:
enter definitions and bare expressions incrementally into the live image and get
typed, richly-rendered results back — inferred types for any (sub)expression (GHCi's
`:t`), structural ADT rendering, type errors mapped to source spans. Alive and SLIME
already give a fine *CL* REPL; the entire value here is **Coalton-awareness**. The
hard part is that Coalton has *global* type inference and is not a line-at-a-time
language, so the REPL must maintain an **evolving typed environment** across inputs
and bridge the CL⇄Coalton boundary in both directions.

**This is not greenfield, and the survey mattered.** The canonical request is
coalton-lang issue **#726** ("make a simple Coalton REPL," open since 2022; the most
recent comment offers only an SBCL reader hack that auto-wraps forms). Two real tools
now exist:

- **`mine`** — the *official* Coalton IDE, alpha, with an integrated REPL pane. But it
  is a **terminal-mode (TUI)** IDE shipped inside a **Tauri 2 + xterm.js** desktop
  wrapper: textual output, **no structured or graphical value rendering**.
- **`coalton.app`** — a *community* web playground that compiles Coalton to CL and
  runs it, with share-URLs. A compile-and-run playground, **not** a live,
  type-introspecting REPL.

So the open niche is precise: a **visual, structured-value-rendering, DrRacket-style**
REPL — and doing it *CL all the way down* directly contrasts with `mine`'s
Tauri+xterm.js route, which is the very Rust/JS sprawl this monorepo reacts against.
Build-vs-adopt was weighed honestly (could the engine be contributed upstream, or
`mine` reused?) and the answer was that `mine`'s text-mode ceiling is exactly the
thing worth beating.

**The DAG wrinkle and its resolution.** A hyperion-served REPL cannot live in cons
core, because cons is left of hyperion. The founder's call splits it:

- **cons keeps the lean, in-wheelhouse part** — a headless Coalton-eval and
  type-introspection engine as an *optional* system (`cons/coalton-repl`), kept **out
  of cons core** so plain `bin/cons` stays Coalton-free and trivial to install
  (exactly the lean tension above), and/or a plain terminal `cons coalton-repl`. It
  must **build on Coalton's own API and not reimplement inference**: `coalton:type-of`
  (in-language, yields the inferred type scheme — note it shadows `CL:TYPE-OF`), the
  `describe-type-of` debug helper, and the typechecker environment internals; eval via
  `coalton` / `coalton-toplevel` / `define-toplevel-macro`.
- **the visual front-end lives in hyperion** as a side-project ("Studio") — two panes
  (definitions vs interactions), inline/hover types, structured value rendering
  (later: data tables and plots), a stepper as a stretch.

Delivery is **web first**: a Hyperion-served front-end keeps it CL all the way down
and dogfoods hyperion; a desktop shell would be richer but reintroduces the sprawl
`mine` already occupies. Desktop only if richness demands it.

### OS-level services — the `service` target kind

A newer target kind alongside `cli` / `web` / `desktop` / `lib` / `mobile`: a project
whose binary runs as a **managed OS background service** — starts at boot, restarts
on failure, logs where the OS expects, installs and uninstalls itself. Today a CL
program that wants this has **no scripted path on any OS**, and on Windows
essentially no path at all.

It matters because it is the missing *deployment shape* for everything the ecosystem
already builds: a web app serving a LAN, an agent worker, a data-sync daemon. And on
Windows it is a genuine ground-breaker — well-trodden in C#/Go/Rust,
close to unheard-of in CL.

The crucial insight is that **the three platforms are genuinely different work, not
one abstraction with three configs**:

- **Windows — the hard one, and the interesting one.** A real NT service is not "a
  process that runs in the background": the binary must call
  `StartServiceCtrlDispatcher` within ~30s of launch, hand the SCM a `ServiceMain`,
  register a control handler, and report `SERVICE_START_PENDING → RUNNING →
  STOP_PENDING → STOPPED` with checkpoints, or the SCM kills it. That is a **CFFI**
  binding over `advapi32` plus a control-request loop marshalled into a Lisp thread,
  with registration (`CreateService`/`DeleteService`, or `sc.exe` as the v0), the
  service account, recovery actions, and the Event Log as surrounding surface. **The
  open question:** whether the SCM dispatcher can safely live in SBCL's main thread,
  or wants the same out-of-process trick as the desktop webview shell — a tiny native
  supervisor that *is* the service and runs the image as a child. *Investigate before
  committing to in-process CFFI; the out-of-process variant is the low-risk fallback
  and reuses a pattern already proven.*
- **macOS — `launchd`.** A property-list job in `~/Library/LaunchAgents` (per-user) or
  `/Library/LaunchDaemons` (system), loaded with `launchctl bootstrap`. The program
  needs no special API — just correct signal handling and staying in the foreground.
- **Linux — `systemd`.** A unit file, `Type=simple` or `notify` (the latter wants
  `sd_notify` — a small CFFI or a raw `NOTIFY_SOCKET` datagram, trivially doable
  without a library). Logs to the journal via stdout/stderr, plus an SysV/OpenRC
  escape hatch for non-systemd distros.

What `cons` would own: the `service` scaffold (a `main` that runs *either* in the
foreground for dev *or* under the platform supervisor), `cons service
install|uninstall|start|stop|status`, the unit/plist/SCM registration templates, and
log/exit-code conventions. What it must **not** own: privilege-escalation policy — an
install that needs admin says so and stops. The next step is a spike proving one NT
service written in CL end to end *before* any scaffolding is designed around it.

### Questions still genuinely open

- **The native dependency source model.** Registry (crates.io-like), git refs, OCI
  artifacts (as ocicl does), or several behind the protocol? What does the lockfile
  look like, and is the constraint scheme SemVer or something CL-native?
- **Manifest ownership.** Is the `.asd` the source of truth (cons reads and augments
  it), or does a `cons.lisp`-style manifest *generate* it and hold cons-specific
  metadata? (The build spec shipped as `cons.lisp`; whether it grows to own deps is
  undecided.)
- **Roswell — ignore or interop?** Assume a system SBCL, or read Roswell's installs
  and run its scripts? And does `cons` manage Lisp *implementations* at all
  (rustup-style), or only projects? The working assumption is SBCL-only.
- **Distribution — how does someone get `cons` without `cons`?** The chicken-and-egg
  the tool must answer for itself: curl-install script, Homebrew tap,
  build-from-source, or prebuilt release binaries.
- **A console-UX layer.** Colourful, *controllable* terminal I/O is missing and
  wanted: styled prompts and output plus a real **line reader** (history, in-line
  editing, completion) instead of bare `read-line`. Raised while building a
  `cons init`-scaffolded console example whose loop uses `read-line` and hand-rolled
  ANSI. It would serve every `cli` scaffold, the planned data-layer console, and the
  interactive Coalton REPL — so it is foundational, not cosmetic. Open: **wrap** an
  existing library (`cl-readline` FFI to GNU readline, `linedit`, `replic`) versus a
  small **SBCL-native** reader (no FFI, matching the SBCL-exclusive stance); and
  whether it lives in `cons` or in a tiny shared library the CLI templates depend on.
  The lean is a dependency-light SBCL-native reader plus an ANSI style helper.

### The constraints

- Thin front-end that **delegates** — don't reinvent resolution on day one.
- **Dependency sources behind a neutral protocol** — Quicklisp/ocicl now, native
  later.
- **Bootstrap-light** — `cons` must be trivial to install; mind the Coalton question.
- Everything **AI-friendly and REPL-driven**.

---

## Usage

Build the tree from the repo root; the seed produces `bin/cons`.

```sh
git clone https://github.com/codelisperer/ouranos.git
cd ouranos
sbcl --dynamic-space-size 4096 --script bootstrap.lisp   # → bin/cons
```

**Built-in commands** (work anywhere):

```sh
cons init my-app --template web    # scaffold a project (lib | cli | web | agent)
cons conform                       # install the AI-conformance pack into a project
cons setup                         # bootstrap the Lisp environment (a stub for now)
cons version
```

**Build tasks** — inside any project that has a `cons.lisp`, the first argument is a
target from that project's spec and trailing `KEY=VALUE` args set its params:

```sh
cons                       # list the project's targets (like `make help`)
cons build                 # compile the system
cons test                  # run the test suite
cons repl                  # an SBCL REPL with the tree on the ASDF path
cons dev HOST=0.0.0.0      # (web templates) hot-reload serve, reachable on the LAN
cons --fresh build         # run a target in a subprocess sbcl instead of cons's image
```

### `cons.lisp` — the build spec that replaced the Makefile

```lisp
(cons:project "my-app"
  :system "my-app"
  :dynamic-space-size 4096
  :env (".env")                                  ; load-dotenv before any target
  :params ((host "127.0.0.1" :doc "web bind address"))
  :default (build)
  :targets
  ((build :doc "compile"            :load "my-app")
   (test  :doc "run the suite"      :test "my-app/tests")
   (serve :doc "web app on :8080"   :load "my-app" :call ("my-app:serve" :host host))
   (dev   :doc "serve + a REPL"     :interactive t
          :load "my-app" :call ("my-app:start" :host host))))
```

Target clauses: `:load` (systems to quickload), `:call` (`("pkg:fn" :key val …)`,
where a bare symbol like `host` resolves to a declared param), `:test` (an ASDF
test-system), `:sh` (a subprocess — required for `save-lisp-and-die`), `:eval` (a
form as a string), `:interactive` (drop into a REPL afterwards), `:steps` (run other
targets in sequence).

---

## Roadmap

Planning is live on the board and in issues — this page carries the *why*, not the
task list.

- **Board:** https://github.com/orgs/codelisperer/projects/1
- **Open `cons` issues:** https://github.com/codelisperer/ouranos/issues?q=is%3Aissue+is%3Aopen+label%3A%22pkg%3Acons%22

## See also

- `cons/docs/cons-vision.md` — the open questions in their original interview form.
- `cons/docs/user-guide.md` — the command surface and build-spec reference.
- The desktop-shell and API-first ADRs in `hyperion/docs/adr/` — they decide what the
  `desktop` and `api` target kinds actually scaffold.
