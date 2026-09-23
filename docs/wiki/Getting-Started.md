# Getting Started

This page takes you from a machine with nothing on it to a warm Lisp image with the whole
Ouranos tree loaded and ready to edit. It should take one command and one coffee.

There are two reasons you might be here, and the path forks near the end:

- **You want to build an app on Ouranos.** Your app is its **own repository**, sitting
  above the frameworks. Jump ahead to *Consuming the frameworks from your own repo*.
- **You want to hack on the frameworks themselves.** Read this page, then
  [Contributing](Contributing.md) for the rules of the road.

---

## 1. Prerequisites

Two things, and only two: **SBCL** and a **dependency source** (Quicklisp today; ocicl is
the likely future). Coalton comes in on first use.

Ouranos is **SBCL-exclusive by design**. This is a choice, not an oversight — see
[Home](Home.md). We optimize for one excellent implementation the way Coalton does, which is what
lets us lean on `save-lisp-and-die`, threads, `--script`, and `--dynamic-space-size`
without hedging.

### The pins

The toolchain is pinned in two files. `scripts/versions.env` is deliberately plain
`KEY=VALUE` so that `sh`, PowerShell, and GitHub Actions YAML can all parse it trivially.
It pins these:

| Pin | What it controls |
|---|---|
| `SBCL_VERSION` | the compiler itself |
| `QUICKLISP_DIST` | a dated dist snapshot — this is what actually pins every external library version |
| `APPIMAGETOOL_VERSION` | the tool that packages the Linux desktop build, with its checksum |
| `SQLITE_VERSION`, `SQLITE_YEAR` | the SQLite DLL that `setup.ps1` installs on Windows, with its checksums |

Coalton is a git checkout, not a Quicklisp system, so its commit is pinned separately, in
`coalton.pin` at the repository root. `setup.sh` and `setup.ps1` read it from there. To
change the Coalton version, edit `coalton.pin`; `versions.env` has no Coalton setting.

**A macOS caveat worth internalizing:** upstream SBCL publishes binaries for Linux x86-64
(tarball) and Windows (MSI) only — there are **no macOS binaries**. So on macOS the
provisioning script installs SBCL from **Homebrew** and you get whatever version brew
currently carries, regardless of what `SBCL_VERSION` says. The pin is honored on Linux x86-64
and Windows; on macOS it's documentation of intent. If two machines produce subtly different
builds, this is the first place to look.

**arm64 Linux has no upstream binary either** (none in 2.6.0 to 2.6.8; #9). There,
`setup.sh` stops and asks you to install an SBCL yourself, from your distribution's package
(`sudo apt install sbcl`) or built from source, and on the next run it uses that SBCL and
warns that its version differs from the pin.

### Provisioning a bare machine

```sh
scripts/setup.sh            # Linux / macOS  — install what's missing, at the pinned versions
scripts/setup.sh --check    # report only; exits 1 if something is missing
scripts/setup.ps1           # Windows
```

It is idempotent — anything already present at the right version is left alone. It installs
SBCL (tarball on Linux, Homebrew on macOS), Quicklisp into `~/quicklisp` with the dist
pinned to the dated snapshot, and Coalton as a git checkout at the pinned commit under
`~/common-lisp/coalton` (ASDF finds `~/common-lisp` by default).

Note what it deliberately does *not* do: it does not run the bootstrap. That's the next
step, and it's your call.

---

## 2. The one-command bootstrap

```sh
git clone https://github.com/codelisperer/ouranos.git
cd ouranos
sbcl --dynamic-space-size 4096 --script bootstrap.lisp
```

That is the seed. It is **identical on Linux, macOS, and Windows** — no shell-specific
variants, no platform branches for you to get wrong. It does four things in one pass:

1. **Points ASDF at the whole tree** for this run, so it can find every framework.
2. **Builds `bin/cons`** — the project tool, dumped as a self-contained warm image via
   `save-lisp-and-die`.
3. **Writes a standing ASDF source-registry drop-in** at
   `~/.config/common-lisp/source-registry.conf.d/50-ouranos.conf`, containing a
   `(:tree <repo-root>)` entry that covers every framework at once. This is the
   monorepo-era replacement for symlinking each project into
   `~/quicklisp/local-projects` or pushing onto `asdf:*central-registry*`. It is rewritten
   on each bootstrap, so it self-heals if you move the repo.
4. **Warms the stack** — compiles the six core frameworks in DAG order plus hermes, in a
   throwaway SBCL, so your first `cons build` or editor load is instant instead of a cold,
   multi-minute Coalton compile.

The warm is the part people are tempted to skip. Don't, usually. It's cheap once the fasls
exist, and compiling everything up front is the surest way to surface a build problem
*before* you start working. If you really need to skip it:

```sh
OURANOS_NO_WARM=1 sbcl --dynamic-space-size 4096 --script bootstrap.lisp
```

The warm is non-fatal either way — `bin/cons` gets built regardless.

**Why the big heap?** Coalton's first compile is heap-hungry. Without
`--dynamic-space-size 4096` you'll exhaust SBCL's default heap partway through hyperion or
praxeon. This applies to every SBCL invocation that touches the Coalton-bearing frameworks,
not just the bootstrap.

---

## 3. Your first REPL

Once the drop-in exists, *every* SBCL session on the machine can find the frameworks — no
per-project setup, no symlinks. Start a REPL with the big heap and load whichever system
you're working on:

```lisp
(ql:quickload :aion)        ; or :cons :mnemosyne :elenchon :hyperion :praxeon :hermes
```

A few things to expect:

- The image does **not** auto-load a system, because there are several. You pick.
- Several systems can share one image happily; load as many as you need.
- `cons` is lean — pure CL, no Coalton — so it loads fast. `hyperion` and `praxeon` pull in
  Coalton, so the *first* load takes minutes; it's cached after that.
- Edits hot-recompile into the running image (`C-c C-k` in SLIME/Sly, the Alive eval
  commands in VS Code). That live loop is the point of the whole stack.

For editor specifics — the root `.vscode/settings.json` for VS Code / Alive, the root
`.dir-locals.el` for Emacs / SLIME, and the vlime/slimv incantation for Neovim — see
[Contributing](Contributing.md) and each framework's `docs/editor-setup.md`.

---

## 4. Building and testing: `cons` and `cons.lisp`

**There is no make, no just, no nmake anywhere in this repo.** That is a decision, not an
omission. LaTeX-and-make on Windows was the original dealbreaker; `sbcl --script` is
uniform across all three platforms, so the build tool is Lisp and the manifests are Lisp.
The per-framework `Makefile`s that used to exist have been removed.

In their place, every project ships a root **`cons.lisp`** — a declarative build spec
listing its targets. `cons <target>`, run from anywhere in the tree, walks up from the
current directory, finds the nearest spec, and drives it:

```sh
cd praxeon
cons                        # bare cons lists this project's targets
cons build                  # compile
cons test                   # run the suite
cons repl                   # a REPL with the project loaded
cons dev HOST=0.0.0.0       # project-specific targets, with KEY=VALUE args
```

Targets run inside cons's warm image, which is why they start instantly; `--fresh` runs
them in a subprocess SBCL instead when you want a clean slate.

Because the walk-up finds the *nearest* spec, a framework's own `cons.lisp` wins inside its
directory, while the repo-root `cons.lisp` handles the tree as a whole — its `warm` target
is the same DAG-ordered compile the bootstrap runs.

Beyond the task runner, `bin/cons` today implements:

| Command | What it does |
|---|---|
| `cons init <name> --template {lib,cli,web,agent}` | scaffold a project — `.asd`, packages, `src/`, tests, `.gitignore`, editor config, a `cons.lisp`, a README. `web` scaffolds a minimal runnable Hyperion app |
| `cons conform` | install the AI-conformance pack — see [Working With AI Agents](Working-With-AI-Agents.md) |
| `cons setup` | write the project's ASDF source-registry `(:tree)` drop-in (per-OS), and report a stale `local-projects` symlink shadowing it |
| `cons env` | report which config keys a project needs |
| `cons db-repl`, `cons db-url` | a database session per environment; the password travels in the child's environment, never argv |
| `cons template check` | generate a template *and build it* |
| `cons version` | version |

The larger ambition — `cons build | test | serve | run` driving the *whole tree* from one
root spec, plus `cons add` and lockfiles over a neutral dependency-source protocol — is on
the [roadmap board](https://github.com/orgs/codelisperer/projects/1), not in this wiki.

Test suites are **fiveam**, and also run from a REPL via `(asdf:test-system :<system>)`.

---

## 5. Consuming the frameworks from your own repo

Your app is a separate repository that sits *above* the frameworks — they never depend on
it. Onboarding it is the same drop-in trick, one directory up in priority:

```lisp
;; ~/.config/common-lisp/source-registry.conf.d/60-my-site.conf
(:tree "/Users/you/projects/my-site/")
```

`conf.d` is **additive**, so with both files present `(ql:quickload :my-site)` resolves
hyperion, praxeon, and mnemosyne out of the Ouranos tree automatically. Generalizing that
drop-in write is precisely what `cons setup` does; the one-liner is
`cons init my-site --template web`, and it works today.

For a worked example of the shape, the shipped examples live under `praxeon/examples/` —
an agent-powered page is a hyperion web surface driving a praxeon actor. Read
`hyperion/docs/user-guide.md` and `praxeon/docs/user-guide.md` next.

### A note on deploying

In development your app resolves the frameworks from your Ouranos checkout via the drop-in.
**In production that is not good enough** — a Docker image must ship a *pinned* Ouranos (a
git submodule or `git subtree` pin today, the ocicl route once cons's dependency story
lands), so builds are reproducible and don't quietly depend on whatever happened to be on
the build machine.

---

## Troubleshooting

**The first Coalton compile is slow, or OOMs.** Expected. Give SBCL
`--dynamic-space-size 4096` and let it finish; it's cached afterward.

**A system isn't found.** Re-run the seed once — it rewrites the drop-in. Then confirm
`~/.config/common-lisp/source-registry.conf.d/50-ouranos.conf` exists and points at your
actual checkout. If you moved the repo without re-bootstrapping, this is why.

**Two machines behave differently.** Check `scripts/versions.env` against what's actually
installed, and remember the macOS/Homebrew caveat above.

---

**Next:** [Contributing](Contributing.md) for the DAG rule and house style · [Working With AI Agents](Working-With-AI-Agents.md)
for the agent workflow · [Home](Home.md) for the framework roster.
