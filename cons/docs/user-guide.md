# cons — User Guide (starter)

> **Pre-alpha (0.0.0).** Real today: project scaffolding (`cons init`), the AI-conformance
> pack (`cons conform`), and the **`cons.lisp` build spec + task runner** (`cons build | test |
> repl | run | serve | dev …`) that replaces per-project Makefiles. Dependency management
> (`cons add`, lockfiles) is still ahead. See `docs/roadmap.md` for the plan and
> `docs/cons-vision.md` for open questions.

## `cons db-repl` — a database session per environment

Open a client against the database an environment is *actually* using, without reciting
hostnames, ports and sslmode from memory:

```sh
cons db-repl                     # dev (DATABASE_URL)
cons db-repl staging             # DATABASE_URL_STAGING
cons db-repl prod -c "select count(*) from users"    # extra args pass through
cons db-url prod                 # print the URL, password redacted (--reveal to show)
```

The URL comes from `.env` (gitignored) or the platform's secrets — `DATABASE_URL` for dev,
`DATABASE_URL_<ENV>` for anything named. A suffixed variable is the *only* thing that
answers for a named environment, so a developer's plain `DATABASE_URL` can never be mistaken
for production. The client follows the scheme: `psql` for Postgres, `sqlite3` for a
`sqlite:` URL **or a bare path** (a local dev database is usually just a file).

**Guards on anything that is not dev:**

- You confirm by **typing the environment's name**. A yes/no prompt is muscle memory;
  typing `prod` is a deliberate act.
- The session opens **read-only** — Postgres via `default_transaction_read_only`, SQLite via
  `-readonly` — unless you pass `--write`. `-y` skips the confirmation for scripts.

**Credentials never reach the process table.** `psql "postgres://u:pw@host/db"` would put
the password in `argv`, where any user on the machine can read it with `ps`. The password is
stripped from the URL and handed to the child through `PGPASSWORD` in its environment
instead — invisible to `ps`, gone when the process exits, and never written to a temp file
that would outlive the session. `cons db-url` redacts by default for the same reason: the
obvious use is pasting the output somewhere.

## Prerequisites

- **SBCL** + **Quicklisp**. (cons is pure-CL and dependency-light — no Coalton or
  libev needed.)

## Setup

cons is one of six core frameworks (plus `hermes`, a satellite leaf-lib) in the
[Ouranos monorepo](../../README.md); you build the
whole tree, not this directory alone. From the repo root:

```sh
git clone https://github.com/codelisperer/ouranos.git
cd ouranos
sbcl --dynamic-space-size 4096 --script bootstrap.lisp   # → bin/cons
```

`bootstrap.lisp` points ASDF at the whole tree and writes a source-registry drop-in, so
every REPL finds the frameworks with no symlinking.

## Load it

```sh
rlwrap sbcl
```
```lisp
(ql:quickload :cons)
(cons:version)               ; => "0.0.0"
```

## The command surface

`cons` is a CLI (`bin/cons`) — cargo/npm/go-tool, for CL.

**Built-in commands** (work anywhere):

```sh
cons init my-app --template web    # scaffold a project (lib | cli | web | agent)
cons conform                       # install the AI-conformance pack into a project
cons setup                         # write this project's ASDF (:tree) drop-in, per-OS
cons env                           # which config keys does this project need?
cons db-repl / cons db-url         # a database session per environment
cons template check                # generate a template AND build it
cons version
```

**Build tasks** (inside a project that has a `cons.lisp`): the first argument is a
target from that project's build spec, and trailing `KEY=VALUE` args set its params.

```sh
cons                       # list the project's targets (like `make help`)
cons build                 # compile the system
cons test                  # run the test suite
cons repl                  # an SBCL REPL with the tree on the ASDF path
cons dev HOST=0.0.0.0      # (web templates) hot-reload serve, reachable on the LAN
cons --fresh build         # run a target in a subprocess sbcl instead of cons's image
```

**Still ahead:** dependency management — `cons add`, Quicklisp/ocicl backends, a native
resolver + lockfiles (see
[`docs/wiki/Framework-Cons.md`](../../docs/wiki/Framework-Cons.md), the dependency-source
protocol).

## `cons.lisp` — the build spec (replaces the Makefile)

A project declares its tasks in a root `cons.lisp` — a small, declarative, Lispy
manifest. `cons <target>` then works identically on Linux / macOS / Windows, with no
GNU-make dependency. `cons init` scaffolds one for you; here is the shape:

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

Target clauses: `:load` (systems to quickload), `:call` (`("pkg:fn" :key val …)`, where
a bare symbol like `host` resolves to a declared param), `:test` (an ASDF test-system),
`:sh` (a subprocess — required for `save-lisp-and-die`), `:eval` (a form as a string),
`:interactive` (drop into a REPL afterward, for `dev`/`repl`), `:steps` (run other
targets in sequence). Targets run **in cons's warm image** by default (fast — the
`bin/cons` binary already carries Quicklisp and a 4 GB heap); `--fresh` or a target's
`:isolate` runs the Lisp work in a subprocess sbcl instead.

## When the toolchain disagrees with itself

`cons` checks one thing before it does anything else: that the Lisp under it can still reach
its own contribs. If it cannot, the failure you would otherwise meet is

```
Unhandled SB-INT:EXTENSION-FAILURE: Don't know how to REQUIRE SB-POSIX.
```

which names a contrib and sends you looking for a missing dependency or a broken Quicklisp.
The cause is neither: contribs are found relative to `SBCL_HOME`, and `SBCL_HOME` is not
resolving. `cons` says that instead:

```
cons: this image is SBCL 2.6.7, but its contribs cannot be loaded.
cons: SBCL_HOME is /opt/homebrew/Cellar/sbcl/2.6.5/lib/sbcl, which does not exist.
cons: Contribs (sb-posix, sb-cltl2, ...) are found relative to SBCL_HOME, so nothing that
cons: needs one will start.
cons: Re-run bootstrap.lisp, or set SBCL_HOME to the tree matching this runtime.
```

Ordinary ways to get here: an SBCL upgrade that removed the tree a wrapper still points at,
a runtime copied out of its install tree, or a checkout whose environment was set up for a
different install.

### The quieter version: a stale `bin/cons`

`bin/cons` is a **dumped image** — it carries its own runtime and its own contribs — so an
SBCL upgrade leaves it working rather than broken, which is precisely why it goes unnoticed:

```
cons: this cons was built by SBCL 2.6.5, but SBCL 2.6.7 is now on PATH.
cons: It still runs -- a dumped image carries its own runtime and contribs -- but `--fresh`
cons: targets run under the PATH sbcl, so one build can span two compilers.
cons: Rebuild: sbcl --dynamic-space-size 4096 --script bootstrap.lisp
```

This is a **warning, not a refusal**: the image genuinely works, and refusing would block you
over a mismatch that often bites nothing — including the rebuild, which `cons` itself is not
the tool for. It matters for `--fresh` targets, which run in a subprocess `sbcl` taken from
`PATH` rather than in cons's warm image.

`cons version` reports both, so you can check without re-reading the scrollback:

```sh
$ cons version
cons 0.0.0
sbcl 2.6.5 (PATH: 2.6.7)
```

## Configuration — `.env`, and *when* it is loaded

A scaffolded project ships a committed `.env.example` and a gitignored `.env`. Values load
into the **process environment**, and the host environment wins: production sets real
variables and ships no `.env` at all, so nothing about the deployed path depends on the file
existing.

**The ordering is the part that bites.** The generated entry point calls the loader as its
first act:

```lisp
(defun main ()
  (env:load-project-env :myapp)     ; FIRST, before anything reads the environment
  ...)
```

Keep it there. This came out of a real failure in a consuming app: `.env` was loaded while
building the web handler, but the app's start path opened the database and ran a seed that
**sent mail** before the handler was constructed. That work ran against a bare environment,
and produced two bad symptoms —

- **loud, and blaming the wrong component**: a provider raised `missing required
  configuration: <KEY>` for a key sitting right there in `.env`, so the *library* looked
  broken when the app's own ordering was at fault;
- **silent**: the database path fell back to its default, and a stray database quietly
  appeared in the wrong directory.

`load-project-env` is built so the correct call is the easy one:

- it resolves `.env` **against your app's own ASDF system**, not the current directory, so a
  built binary run from anywhere still finds it;
- it is **idempotent**, so `main` can call it unconditionally without knowing whether a REPL
  session, a test fixture or `cons` already did.

A **library** does not call it. A library declares the keys it needs in its own
`.env.example` and reads them from the environment at use time; loading the environment on
its consumer's behalf, at a moment the consumer did not choose, is the same ordering bug
seen from the other side. That is why the `lib` template has no such call and the other
three do.

The loader lives in its own tiny system, `cons/env` (uiop-only), which is what your app
depends on — not the whole build tool. `cargo` is not a runtime dependency of your crate
either.

## `cons env` — what this project needs configured, and who needs it

```sh
$ cons env
Configuration for myapp and its dependencies:

      HERMES_TRANSPORT    unset       hermes
    ! SENDGRID_API_KEY    MISSING     hermes
      TWILIO_AUTH_TOKEN   unset       hermes
      DATABASE_URL        set         mnemosyne

  4 keys declared, 1 set, 1 required and missing.
```

Every framework that needs configuration ships its own `.env.example` listing **only its own
keys**. Nothing assembled those for the app depending on them, so apps hand-transcribed keys
by reading each dependency's source — which drifts silently the moment a library adds one,
and gives no signal at all when a dependency is added later.

`cons env` walks the ASDF dependency graph **transitively** and reports every declared key
with the system that declared it. Transitive matters: your app declares `hyperion`, and it is
`hermes` — two levels down — that wants a SendGrid key. Direct dependencies alone would answer
the easy half of the question.

It **exits non-zero when a required key is missing**, so it can gate a deploy. That is the
point: a missing key is not a startup error. It is a runtime `configuration-error` raised deep
inside whichever library needed it, long after start and far from anything you just changed.

`cons env myapp` names a system explicitly, for when you are not standing in the project.

### `cons env --write` — fold dependency keys into your own `.env.example`

`cons init` does this once, so a new project starts with its dependencies' keys already
listed, attributed, and carrying the comments that explain them. Run it again after adding a
dependency:

```sh
$ cons env --write
Added 3 keys to .env.example:
  SENDGRID_API_KEY          hermes
  TWILIO_ACCOUNT_SID        hermes
  TWILIO_AUTH_TOKEN         hermes
```

It **appends and never rewrites**. Your own keys, comments and ordering are yours; a
generator that rewrote the file would eat them the first time a dependency changed.
Appending also puts the delta in a diff, which is the point of running it again.

A key you have **deliberately commented out is not re-added** — commenting it out was a
decision, and re-appending it would be the generator arguing with you every time it runs.
Running it twice in a row changes nothing at all.

**Required vs optional** comes from the files' own convention, which every `.env.example` in
this tree already follows: a live `KEY=` line is a key the library expects, a commented
`# KEY=` line is an optional override. Prose is not configuration — a line like
`# Set FOO=bar to enable` is a sentence, and is not read as a declaration.

## See also
- `docs/editor-setup.md` · `docs/roadmap.md` · `docs/cons-vision.md` · `CLAUDE.md`.
