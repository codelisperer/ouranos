# Contributing

This page is for working **on the frameworks themselves**. If you're building an app *with*
Ouranos, [Getting Started](Getting-Started.md) has the path you want.

Most of what follows is not bureaucracy — it's the set of constraints that keep six
co-evolving frameworks from collapsing into a tangle. Each rule below exists because
something specific went wrong, or would have.

---

## The one hard rule: the dependency DAG

```
aion → cons → mnemosyne → elenchon → hyperion → praxeon
```

**A core system never depends on one to its right.** Not "shouldn't" — ASDF errors on
cycles, so the graph enforces itself the moment you try.

This is the one constraint everything else in the repo assumes, and it's what makes the
monorepo tractable. It means every framework has a well-defined *below* it can rely on and
a well-defined *above* it must know nothing about. Aion doesn't know the web exists.
Mnemosyne doesn't know about agents. Hyperion doesn't know which LLM you're calling.

Three corollaries follow, and they're where the nuance lives:

**Auxiliary systems may reach right.** A framework may ship an auxiliary system that
depends on something further up, as long as the *system-level* graph stays acyclic —
`praxeon/web → hyperion`, `elenchon/web → hyperion`, `hyperion/testing → elenchon` are all
fine. The DAG binds **core** systems. The escape hatch is real, but it's an escape hatch:
if you find yourself reaching for it in a core system, the design is wrong.

**Combined apps and examples live in the highest framework they need.** An example that
uses both hyperion and praxeon belongs under praxeon, because that's the only place both
are already in scope without inverting the order.

**hermes sits outside the line entirely.** It's a satellite leaf-lib for external
integrations — email, SMS and payments today. It depends only on `aion` plus
external HTTP/JSON libraries, never on mnemosyne, hyperion, or praxeon, and **nothing in the
core DAG depends on it**. That's what makes it a leaf: it can talk to third-party services
without any of that concern leaking inward. Persistence goes to mnemosyne; web endpoints go
to hyperion; hermes owns the provider protocol, the client, and webhook verification, and
stops there.

One more piece of hygiene that follows from all this: **consolidation is reversed and
settled.** Older docs said hyperion "absorbs aion/cons for now" — a convenience under time
pressure. The monorepo settles it the other way: the six core frameworks are conceptually
distinct, each in its own top-level directory with its own `.asd`, and cons owns all project
tooling (hyperion is a *library*, not a CLI). Keep migrating each piece to its conceptual
home — CSV to aion, persistence to mnemosyne, RBT to elenchon. Bias to clean design over
convenience unless the maintainer explicitly flags time pressure.

---

## House style

The style rules are all downstream of one idea: **push the mess to the edges and keep the
middle checkable.**

### Typed Coalton core, effectful CL/CLOS shell

Ontology and pure logic go in Coalton, where Hindley–Milner catches your mistakes at
compile time. Effects, IO, and dynamism go in the CL/CLOS shell wrapped around it.

**No IO in Coalton.** This is the version of the rule you should keep in your head. If a
function needs to touch a socket, a file, a clock, or a database, it does not belong in the
typed core — expose a pure function and call it from the shell.

Before writing any `coalton-toplevel` code, read **`docs/coalton-patterns.md`** in the
repository. It's the canonical worked reference, and it exists because Coalton has a
handful of sharp edges that cost real hours the first time. The ones that cost the most:

- Function-type `declare`s **and** `define-class` method signatures are **uncurried** and
  `*`-separated: `(A * B -> C)`.
- Coalton is **case-insensitive** — watch for collisions you didn't intend.
- `match` on a nullary constructor needs parens: `((None) …)`.
- Reserved / shadowed names to avoid: `continue`, `Fail`, `Some`, `None`, `Ok`, `Err`,
  `Tuple`, `map`, `into`.
- A typeclass-constrained function needs a **monomorphic wrapper** to be callable from CL.

Seen a new one? Add it to `docs/coalton-patterns.md`, then mirror the one-liner into the
conformance pack's Coalton section (`cons/src/conform.lisp`) so the AI assistants learn it
too.

### Neutral protocols for pluggable backends

Anything with more than one plausible implementation goes behind a **neutral protocol** — a
generic function or a Coalton class. Mnemosyne's storage backends, hermes's delivery
providers, praxeon's LLM providers, hyperion's session store: all the same shape. Adding
SQLite alongside Postgres, or Twilio alongside a dev transport, is *registering an
implementation*, not editing the core.

Provider neutrality is a hard constraint, not a nice-to-have. The core never names a
vendor.

### Conditions, not return codes

Recoverable failure uses the **condition system**. CL has one of the best error-handling
stories in any language — restarts, handlers, the ability to fix and continue from the
debugger in a live image — and threading `-1` or `nil` up through call stacks throws all of
that away.

### ADTs over booleans

Model states as algebraic data types with meaningful constructors, not as a bag of flags.
`(Pending | Active | Suspended Reason)` tells you what's legal; three booleans tell you
nothing and permit five nonsense combinations.

### Package-per-module, `:local-nicknames`

Each module gets its own package. Reach for `:local-nicknames` rather than long prefixes or
blanket `:use` clauses — it keeps the reader oriented about where a symbol came from without
turning every call site into a paragraph.

### Formatting, and one specific trap

Two-space indentation. No trailing whitespace. Small pure functions.

**LF line endings everywhere**, enforced by the repo-root `.gitattributes`
(`* text=auto eol=lf`; Windows `.ps1` / `.bat` / `.cmd` keep CRLF; binaries marked
`binary`). This forces LF in every working tree on every OS, so `core.autocrlf=true` on a
Windows machine can't hand SBCL a CRLF-mangled source file.

And the trap that motivated it: **never write a `FORMAT ~<newline>` continuation.** On a
CRLF checkout it becomes an illegal `~<Return>` directive, and SBCL's *compile-time*
format-string parser reports it as a baffling "macroexpansion" error nowhere near the real
cause. It broke `praxeon/llm`, then `praxeon/actor`, one file at a time, as successive
commits reintroduced the pattern. The `.gitattributes` fix is the belt; avoiding the pattern
entirely — fold the control string onto one line — is the suspenders. A stray CRLF from a
zip download or a misconfigured editor then can't break the build regardless. Do not
reintroduce either the setting gap or the pattern.

---

## Tests

Suites are **fiveam**. Run them either way:

```sh
cd hyperion && cons test
```

```lisp
(asdf:test-system :hyperion)
```

Elenchon deserves a mention here, since it's the house's own answer to test design:
Requirements-Based Testing via Cause-Effect Graphs, reducing a requirement to a minimal
decision table (roughly MC/DC coverage). `hyperion/testing → elenchon` is one of the
sanctioned rightward auxiliary edges.

---

## Dependencies

Dependencies are held to a **conscious minimum** — that's the whole thesis. So the rule is
mechanical: **any change to a `:depends-on` means updating `docs/dependencies.md`** in the
same change, with the surface and the pinned version.

Before adding one, ask whether it's a *true external service* (Postgres wire, Stripe,
SendGrid, Twilio, an LLM provider) that belongs behind a thin neutral protocol, or whether
it's convenience that will become the next thing you maintain.

Licensing has been audited: no strong copyleft in the tree, a few weak-copyleft **LLGPL**
transitive deps (via `trivia`), safe to use unmodified. The frameworks are MIT; consuming
apps are separately licensed. Keep it that way.

---

## Parallel work: git worktrees

Parallelism here is **git worktrees**, not branches you swap in place:

```sh
git worktree add ../ouranos-<track> -b work/<track>
```

Open each worktree as its own editor window or agent session, on its own branch, fully
isolated. Merge to `main` when green. The main checkout is the **integration hub** — one
repo per worktree branch, and **no cross-branch edits**. (Claude Code's Agent tool also
supports `isolation: "worktree"`, which does the same thing for a delegated task.)

This matters more than it sounds like it does: a live SBCL image is stateful, and two tracks
sharing one checkout means two tracks sharing one fasl cache and one set of half-loaded
systems. Worktrees keep the images honest.

---

## The editor and the REPL

Open the **repo root** in your editor; one SBCL image serves the whole tree. Two things make
that work, both configured at the root:

- **Discovery** — the ASDF `(:tree)` drop-in written by `bootstrap.lisp` puts every system
  on the path. Run the seed once.
- **Heap** — a Coalton-sized `--dynamic-space-size 4096`, so hyperion and praxeon load
  instead of exhausting the default heap on Coalton's first compile.

| Editor | Config |
|---|---|
| VS Code / Alive | root `.vscode/settings.json` sets the start command (heap + LSP) |
| Emacs / SLIME or Sly | root `.dir-locals.el` points `inferior-lisp-program` at the big-heap SBCL; `M-x slime` from any repo file |
| Neovim / vlime or slimv | start a server with the heap and connect — `sbcl --dynamic-space-size 4096 --eval '(ql:quickload :slynk)' --eval '(slynk:create-server :dont-close t)'`, then `:VlimeConnect` |

The image doesn't auto-load a system — `(ql:quickload :cons)` (or whichever) yourself, then
eval inside that system's files. Opening a single framework's *subdirectory* instead
auto-loads just that system, via its own `.vscode/settings.json`. A uniform `cons repl`
launcher is planned; until it lands the per-editor config above is the "just works" path,
and each `<framework>/docs/editor-setup.md` has more detail.

---

## Docs as handoff

Documentation here is a handoff mechanism between sessions, machines, and people (and
agents). The convention:

- Status is the [Roadmap board](https://github.com/orgs/codelisperer/projects/1) and its
  issues (filter `label:pkg:<framework>`) — open, update, and close issues rather than
  hand-maintaining a Status block. It's the first thing a fresh session reads.
- The design narrative — reasoning, trade-offs, rejected alternatives, open questions —
  goes in this wiki's `Framework-<Name>.md` page.
- Record architecturally-significant decisions as **ADRs** (see `hyperion/docs/adr/`). An
  ADR supersedes rather than gets edited — `ADR-0007` supersedes `ADR-0001` and says so.
- The committed `ECOSYSTEM.md` plus each framework's `CLAUDE.md` are the **cross-machine
  brain**. Anything that must survive a new machine or a fresh session goes there. Editor
  auto-memory is machine-local and private; never rely on it across machines.

---

## Before you propose code

- [ ] Effects and IO live in the CL shell, not in Coalton.
- [ ] New module → its own package, package-per-module, `:local-nicknames`.
- [ ] New `:depends-on` → `docs/dependencies.md` updated in the same change.
- [ ] The DAG is respected; any rightward edge is an auxiliary system and still acyclic.
- [ ] Two-space indent, no trailing whitespace, LF, no `FORMAT ~<newline>`.
- [ ] fiveam tests, and the framework's roadmap Status still tells the truth.

---

**See also:** [Getting Started](Getting-Started.md) · [Working With AI Agents](Working-With-AI-Agents.md) · [Home](Home.md) ·
[roadmap board](https://github.com/orgs/codelisperer/projects/1)
