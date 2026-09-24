# Ouranos

[![verify](https://github.com/codelisperer/ouranos/actions/workflows/verify.yml/badge.svg)](https://github.com/codelisperer/ouranos/actions/workflows/verify.yml)

**A metaframework for full-stack Common Lisp — six co-evolving core frameworks (plus two
satellite leaf-libs) under one roof.**

Ouranos is the monorepo home of the [codelisperer](https://github.com/codelisperer)
ecosystem: a small, cohesive family of **Common Lisp / Coalton** frameworks for
building real applications — web, data, agentic AI, testing — *without* a JVM or a
Node toolchain in sight.

The name fits the family. The libraries are named for **Titans and primordials** —
Hyperion, Mnemosyne, Aion — and **Ouranos** is the primordial sky, *father of the
Titans*: the source from which they all descend.

## Why

This exists as a reaction to **dependency sprawl**. Modern stacks — the JVM's, Node's —
cobble together dozens of independently-versioned libraries where bumping one can
cascade. We love the *languages* (Clojure especially); we don't love the ecosystem
weight. So Ouranos bets the other way:

- **CL all the way down.** HTML is s-expressions (Spinneret), JavaScript is Lisp
  compiled to JS (Parenscript, no Node), the build tool is Lisp, the scripts are
  Lisp. Even the SQL language at the database layer is, you guessed it, Lisp all
  the way down. One homoiconic substrate, not a host language wrapped around N
  embedded DSLs.
- **A typed core where it earns its keep.** Ontology and pure logic live in
  **Coalton** (Hindley–Milner, compile-time-checked); effects and dynamism live in the
  CL/CLOS shell. Clean, checkable abstractions an AI *and* a human can reason about,
  without giving up REPL-driven iteration, with immediate, hot-reloaded feedback.
- **Few, cohesive, co-versioned, house-owned.** Only true external services (Postgres
  wire, Stripe, SendGrid) sit behind thin neutral protocols.
- **SBCL, embraced.** We target one excellent implementation and optimize for it (as
  Coalton does) — native binaries via `save-lisp-and-die`, a live image, instant
  scripting (`sbcl --script` *is* our Babashka).

**The deeper bet.** Lisp *put AI on the map* — it was the native tongue of symbolic AI
for decades. Now the debt runs the other way: **Lisp put AI on the map, and AI is
returning the favour** — putting Common Lisp, with Coalton, back on it, ready to compete
with the big boys. Not merely as an AI language but as a *fully modern, multi-modal dev
stack* — one core, many faces (web, desktop, CLI, mobile, API), CL all the way down.
Modern coding assistants make a homoiconic, typed-where-it-counts, REPL-driven stack newly
approachable (even for people who "hate parens"), so AI-friendly docs and code are a
first-class goal here, not an afterthought.

### Proudly engineered with AI

This stack is built *with* AI assistance, deliberately and as a practice — which is not the
same thing as what people mean by "vibe coding." The difference is method, and it is
written down and auditable rather than claimed: **state the goal before the method ·
interrupt mid-work · turn hunches into measurements · ask for the strongest counterargument
· test where the assumption is not already satisfied.**

Those are engineering practices, not prompting tricks, and the tree is the evidence — ADRs
recording what was *rejected* and why, a decisions log, a test harness that fails a suite
running zero checks, benchmarks that found a 44 ms bug in our own request path, and
"unproven on Windows" written where it is true. See
[`docs/working-with-ai.md`](docs/working-with-ai.md) for the full practice, and
[`AGENTS.md`](AGENTS.md) for what an assistant is held to here.

Ouranos also ships that spec *to your project*: `cons conform` installs a tool-neutral
`AGENTS.md` (plus `CLAUDE.md` and `.cursor/rules`) so **your** assistant knows the house
rules too, whichever assistant it is.

## The frameworks

Strict dependency order, low → high (a DAG — a framework never depends on one to its
right):

| Dir | Framework | Role |
|---|---|---|
| [`aion/`](aion) | **Aion** | Coalton-first functional standard library — logging, CSV, randomness, signatures and an opt-in libuv layer today; persistent collections / `ISeq` *(in progress)* |
| [`cons/`](cons) | **cons** | project & dev tooling — "cargo for Lisp": init / build / test / serve / run |
| [`mnemosyne/`](mnemosyne) | **Mnemosyne** | data & persistence — Ecto-like, pluggable backends (SQLite → Postgres → XTDB 2) |
| [`elenchon/`](elenchon) | **Elenchon** | Requirements-Based Testing via Cause-Effect Graphs |
| [`hyperion/`](hyperion) | **Hyperion** | full-stack, HTMX-first web framework (live image, Parenscript, i18n, typed interceptors) |
| [`praxeon/`](praxeon) | **Praxeon** | praxeological framework for agentic AI (provider-neutral LLMs, actors/means/ends) |

Plus two **satellite leaf-libs**, outside the linear core DAG:

| Dir | Framework | Role |
|---|---|---|
| [`hermes/`](hermes) | **hermes** | external integrations — neutral email + SMS (SendGrid/Twilio + a dev transport, signature-verified inbound SMS), a content-addressed blob store, and payments behind a neutral protocol (Stripe backend) |
| [`klio/`](klio) | **Klio** | git-backed content engine — markdown in version control, rendered live by hyperion; sits between a static generator and a database-backed app *(in progress — scaffold and a design doc, no engine yet)* |
| [`hades/`](hades) | **Hades** | the OS ergonomics layer over aion's raw bindings — portable facades only where every OS has a real counterpart, platform-scoped packages elsewhere *(in progress — a [charter](hades/docs/adr/0001-charter.md) and no code yet)* |

Both are **leaves**: they depend only on `aion` plus external libs, never on
mnemosyne / hyperion / praxeon, and nothing in the core DAG depends on them. Apps consume
them directly.

Apps that *consume* the frameworks (e.g. **a consuming app**) live in their own
repos — Ouranos is the library ecosystem, not the products.

## Getting started

Prerequisites: **SBCL** and a dependency source (**Quicklisp** today; ocicl later)
already installed. There is **no make / just / nmake** — the build tool is Lisp, and
the one seed command is identical on Linux, macOS, and Windows:

```sh
git clone https://github.com/codelisperer/ouranos.git
cd ouranos
sbcl --dynamic-space-size 4096 --script bootstrap.lisp   # → bin/cons + warms the whole stack
bin/cons --help                                          # the CLI: init / setup / conform / version
```

**Starting from a bare machine?** `scripts/setup.sh` (or `setup.ps1` on Windows) installs
all three prerequisites at their pinned versions — **SBCL**, **Quicklisp** with a dated dist
snapshot, and **Coalton** as a git checkout at the commit in [`coalton.pin`](coalton.pin).
It is idempotent, needs no sudo on Linux, and `--check` reports what is missing without
changing anything:

```sh
./scripts/setup.sh                                       # then run the seed above
```

It deliberately does *not* run `bootstrap.lisp` — that stays the caller's step.

**One optional extra prerequisite, for one opt-in system.** `aion/uv` (libuv: event
loop, async + sync filesystem, timers, file watching) binds a native library, which the
repo builds from a pinned source tarball rather than taking from your package manager:

```sh
sbcl --script scripts/build-libuv.lisp     # fetch (verified against libuv.pin), compile, done
```

That needs **a C compiler — the one your OS vendor already ships**, and nothing else:
Xcode Command Line Tools on macOS, your distribution's gcc/clang on Linux, MSVC on Windows.
Explicitly **not** MSYS2/MinGW, even though libuv builds fine under it: requiring a
Unix-emulation layer is one more thing to acquire before anything works, and no C toolchain
is ever required to *load* anything here (we bind by hand rather than with a groveller). Not cmake, not make, not autotools: libuv is compiled by a single direct compiler
invocation driven by the script, which is why the "no make / just / nmake" rule above
still holds. Everything else in the tree needs only SBCL.

It is deliberately **not** part of `bootstrap.lisp`. Requiring a toolchain to bootstrap
would put a native dependency on the critical path for people who never touch libuv, and
ADR-0011 is the cautionary tale: a load-time native dependency (libev, via Woo) made
every Linux/macOS desktop bundle unrunnable on a clean machine. `aion/uv` therefore loads
fine without the library present and reports what to run on first use.

`bootstrap.lisp` does four things in one pass, identically on every OS: points ASDF at
the whole tree, builds `bin/cons`, writes a standing ASDF `source-registry.conf.d`
drop-in so *future* REPL sessions find the frameworks too (the monorepo-era replacement
for symlinking each project into `~/quicklisp/local-projects`), and then **warms the
stack** — compiles the six core frameworks in DAG order plus hermes (in a throwaway SBCL) so your first
`cons build` or editor load is instant instead of a cold, multi-minute Coalton compile.
The warm is cheap once the fasls exist; `OURANOS_NO_WARM=1` skips it, but there's rarely
a reason to — compiling everything up front is also the surest way to surface any build
problem before you start.

From there the build tool is per-project **`cons.lisp` build specs** (the Makefiles are
gone). `cons <target>`, run from anywhere in the tree, finds the nearest spec and drives
it — `cons build`, `cons test`, `cons repl`, plus app-specific targets like `cons dev`;
bare `cons` lists a project's targets. `(ql:quickload :hyperion)` also works from any
REPL (first load compiles Coalton — minutes, then cached; give SBCL a big heap).

**Building an app on Ouranos?** See **[docs/getting-started.md](docs/getting-started.md)** —
agent-powered websites: consuming the frameworks from your own repo, and deploy.
**Hacking on the frameworks themselves?** See **[docs/contributing.md](docs/contributing.md)** —
the DAG rule, worktrees, tests, and house style.

## How it's organized

- **Monorepo, one history.** Cross-cutting changes (a protocol *and* its implementer)
  are one atomic commit. Individual libraries can still be published independently
  later via `git subtree split` mirrors.
- **Parallel work = git worktrees.** `git worktree add ../ouranos-<track> -b work/<track>`
  gives an isolated checkout per track; merge to `main` when green.
- **The shared brain is committed.** [`ECOSYSTEM.md`](ECOSYSTEM.md) holds the thesis,
  the dependency graph, the decisions log, and how-we-work; each framework keeps its
  own `CLAUDE.md` + `docs/`.

## Status

**`0.1.0` overall, but it varies sharply by framework** — so it is stated per framework
rather than as one averaged adjective. Check counts come from
`sbcl --script scripts/verify-tree.lisp`, which fails any suite that runs zero.

**The counts below are the Linux CI leg, libuv systems included.** They are not
host-independent and no single number could be: a Mac cannot run the Windows COM suites,
and `hyperion/update` alone is 217 checks on Linux against 261 on Windows despite carrying
no platform in its name. Linux is quoted because it is the only leg that runs on every pull
request *and* every push to `main`, which makes it the figure you can reproduce by clicking
the badge above. [`scripts/check-readme-counts.lisp`](scripts/check-readme-counts.lisp)
compares this table against that leg's own log on every run, so a stale number here is a
red build rather than something a reader has to catch.

***(in progress)*** marks something named here that is **not built yet** — the gap between
this page and the tree, stated rather than left to be discovered.

| Framework | Where it is | Checks (linux) |
|---|---|---|
| **hyperion** | **alpha** — HTMX + Spinneret, i18n (incl. RTL), sessions, channels, static caching, typed interceptors, a native libuv HTTP server (opt-in via `HYPERION_SERVER=uv`; not yet the default), and a native-webview desktop app that builds and installs on three OSes | 1768 |
| **aion** | **mixed** — `aion/log`, `aion/csv`, `aion/random`, `aion/signature` and the opt-in `aion/uv` (libuv) are real; the Coalton-first collections core *(in progress)* | 1046 |
| **cons** | **alpha** — the bootstrap seed and the per-project task runner work; the full `build/test/serve/run` CLI *(in progress)* | 658 |
| **mnemosyne** | **alpha** — DDL-as-data, a CL-DBI shell over the typed backend, exercised against **both SQLite and a real Postgres**. Six design questions still open | 852 |
| **hermes** | **alpha** — email + SMS with signature-verified inbound, a content-addressed blob store, and payments behind a neutral protocol with a Stripe backend | 440 |
| **praxeon** | **alpha** — actor loop, provider-neutral LLM, translator, per-agent models, a web/REST surface, and cost/rate/auth ceilings (`budget-guard`, `meter`, `capability-guard`) | 495 |
| **elenchon** | **design only** — the typed CEG ADT and five ADRs exist; the reasoning engine *(in progress)* | 46 |
| **klio** | **scaffold** *(in progress)* — a satellite the site program instantiates; the system loads and the suite guards that, and nothing else is built yet | 169 |
| **hades** | **planned** *(in progress)* — a charter ADR and nothing else; blocked on `aion/windows/service`, which does not exist yet | 0 |
| **checkers** | **not a framework** — the gate's own guard scripts (`check-pins`, `check-asd-collisions` and the rest), tested against trees built to break them. A row of its own because the total is the sum of the rows, and a suite that runs in the gate but is excluded from the table would make the two disagree | 115 |

Counts above are from the Linux CI leg at `fa14784`; each suite runs in its own image. Nothing here is
API-stable; expect breakage. See [`ECOSYSTEM.md`](ECOSYSTEM.md), the
[Roadmap board](https://github.com/orgs/codelisperer/projects/1) (filter
`label:pkg:<framework>`), and [`docs/wiki/`](docs/wiki/Home.md) for the design narrative.

## What this release promises

**This is a working research stack, not a supported product.** It is published so the
argument can be read and checked, not because it is finished — and the difference matters
enough to say plainly rather than leave to be inferred from a version number.

- **APIs will break.** `0.1.0` is honest, not modest. Nothing here is API-stable, and the
  per-framework table above is the real picture rather than an averaged adjective.
- **Issues and discussion are welcome; response times are not offered.** This is built by
  one maintainer alongside client work. A question may be answered quickly or not at all,
  and neither should be read as a signal about the project.
- **No support, no SLA, no deprecation policy.** If you build something load-bearing on
  this today, you are choosing to maintain it yourself against a moving target. That can
  be a perfectly good trade — it should just be a deliberate one.
- **Maturity is stated per framework and kept honest.** Where the code does not yet match
  a claim, the table says so and links the issue. If you find a place where it does not,
  that is a bug worth reporting.

What *is* offered: the reasoning is written down. Design narrative lives in
[`docs/wiki/`](docs/wiki/Home.md), decisions in [`ECOSYSTEM.md`](ECOSYSTEM.md), and
architecture decisions in each framework's `docs/adr/`. You should be able to reconstruct
why any of this is the shape it is — including the parts that are wrong.

## License

**MIT** across the frameworks — [`LICENSE`](LICENSE) at the repo root, and a copy in each
framework directory so a vendored or independently-split system carries its own terms.
Every `.asd` declares `:license "MIT"` to match. Consuming products built on these
frameworks are separately licensed.
