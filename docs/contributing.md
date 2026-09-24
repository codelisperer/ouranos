# Contributing to Ouranos

For working **on the frameworks themselves**. Building an app *with* Ouranos? See
[getting-started.md](getting-started.md).

## Build the tree from source

SBCL + Quicklisp, then the seed (identical on Linux/macOS/Windows — no make/just/nmake):

```sh
git clone https://github.com/codelisperer/ouranos.git
cd ouranos
sbcl --dynamic-space-size 4096 --script bootstrap.lisp   # → bin/cons
```

It builds `bin/cons` and writes `~/.config/common-lisp/source-registry.conf.d/50-ouranos.conf`
— an ASDF `(:tree <repo-root>)` drop-in covering every framework in the tree (rewritten each
bootstrap; self-heals if the repo moves). No symlinking into `~/quicklisp/local-projects`,
no `asdf:*central-registry*`.

## The one hard rule — the dependency DAG

```
aion → cons → mnemosyne → elenchon → hyperion → praxeon
```

A **core** system never depends on one to its **right** (ASDF errors on cycles). An
**auxiliary** system may reach right if the *system-level* graph stays acyclic (e.g.
`praxeon/web → hyperion`, `hyperion/testing → elenchon`). Combined apps/examples live in
the **highest** framework they need. ASDF errors on a cycle, so this is enforced rather than advisory — see
[`../ECOSYSTEM.md`](../ECOSYSTEM.md).

**hermes** sits *outside* that line — a **satellite leaf-lib** (external integrations:
email + SMS and payments today) depending only on `aion` + external HTTP/JSON libs,
never on mnemosyne / hyperion / praxeon, and nothing in the DAG depends on it.

## Parallel work — git worktrees

```sh
git worktree add ../ouranos-<track> -b work/<track>
```

Open each as its own window/agent on its own branch; merge to `main` when green. `main` is
the integration hub — one repo per worktree branch, no cross-branch edits.

## Build / test

- **Intended**: `bin/cons build | test | serve | run` over the whole tree (in progress —
  cons implements `init` / `setup` / `version` today).
- **Per framework**: a root `cons.lisp` build spec driven by `cons <target>` (run from
  inside the framework's dir — bare `cons` lists targets, then `cons build` / `test`, etc.);
  this replaced the per-framework `Makefile`s (removed). A suite also runs from a REPL via
  `(asdf:test-system :<system>)`; suites are fiveam.
- **The gate**: `sbcl --dynamic-space-size 4096 --script scripts/verify-tree.lisp` — every
  system loaded and every suite run in its own fresh image, failing on zero checks. Run it
  before committing; see *Green is not evidence* in [`AGENTS.md`](../AGENTS.md).

### Testing against Postgres

mnemosyne's claim is a **neutral** protocol over interchangeable backends, and a neutral
protocol verified against one backend is an unverified claim. Until pre-publication issue 176 every check it
reported ran on SQLite alone — the one backend the docs do *not* tell you to deploy on.
pre-publication issue 165 is what that cost: 2645 checks green on SQLite at the same commit that silently stored
the four characters `false` in a Postgres text column.

The contract is one environment variable:

```sh
export MNEMOSYNE_TEST_PG_URL='postgres://user:pw@host:port/db?sslmode=disable'
```

Set it and the portability-sensitive suites run against Postgres **as well as** SQLite. A
container is one way to provide that server and a Postgres you already run is another —
nothing in the tree depends on Docker:

```sh
scripts/test-postgres.sh up              # pgvector/pgvector:pg17 on :55432, waits until it answers
eval "$(scripts/test-postgres.sh env)"   # exports MNEMOSYNE_TEST_PG_URL
sbcl --dynamic-space-size 4096 --script scripts/verify-tree.lisp
scripts/test-postgres.sh down
```

`up` prints which image the container is running and whether it is the one
`docker-compose.test.yml` declares. An existing container is started as it is, so after the
compose file's `image:` changes, a container created before the change keeps the old image.
The line then says MISMATCH, and `scripts/test-postgres.sh down && scripts/test-postgres.sh up`
recreates it (this pulls the new image, and stops the container for any other worktree using
it). `scripts/test-postgres.sh check` prints the same line and exits 1 on a mismatch, 2 when
no container is running (#147).

**It uses its own variable, not `DATABASE_URL`.** The suite `CREATE`s and `DROP`s tables; a
developer who exported `DATABASE_URL` for their application must never discover that running
the tests reshaped it.

Three states, and the gate tells them apart:

| state | suite | `scripts/verify-tree.lisp` |
|---|---|---|
| set + reachable | runs both backends, reports a count each | passes |
| set + **unreachable** | SQLite runs, every parameterised test goes red | **fails** — never excusable |
| unset | SQLite only, `SKIPPED` said loudly | **fails**, unless `OURANOS_ALLOW_NO_PG=1` |

`OURANOS_ALLOW_NO_PG=1` excuses the skip *deliberately* — the same doctrine as
`+KNOWN-EMPTY+`: an exception someone made and can be asked about, not one that accumulated.
The summary says so explicitly, so an excused run cannot be mistaken for a covered one.

Writing a backend-parameterised test: wrap the body in `with-each-backend`, use `is*` rather
than `is` so the per-backend count is real, and take the dialect from `*current-dialect*`
rather than hardcoding one. See [`mnemosyne/tests/backends.lisp`](../mnemosyne/tests/backends.lisp).

### When your control passes, suspect the control

A control run is how you check that a test can detect the defect it was written for: break
the thing deliberately, and confirm the suite goes red. **A control that stays green is
usually reported as "the fix already worked" and is almost always a broken control.**

Twice in one day, in unrelated code, a control here passed while asserting the opposite of
the truth — and both times the checker was blind *in exactly the dimension it was built to
see*:

- **A dependency walk that could not see the declaration it was hunting.** A guard asserting
  no framework system pulls a Clack handler walked `asdf:system-depends-on` handling strings
  and symbols. The offending declaration was
  `(:feature (:not :os-windows) "clack-handler-woo")` — a *list*, silently skipped. The one
  dependency form the guard existed to catch was the one form it could not parse (pre-publication issue 218).

- **A staleness test that could not observe a stale function.** `hyperion/dev` coerces a
  named function object back to its symbol, because `#'build-app` captures the object at
  that instant and never sees a later recompile (pre-publication issue 157). The control captured
  `#'bt/build-app`, redefined it, and asserted the captured one stayed old. It didn't —
  **SBCL late-binds a `#'foo` written in the same compiled file as `foo`'s `defun`**, so the
  "captured" object tracked the redefinition and the control tested nothing.

That second one is worth knowing before you write a staleness test in this tree, because
**anyone writing one will write the same broken control, and there is no failure to notice
— the test passes.** Two ways out:

```lisp
(fdefinition 'build-app)   ; the object itself, unambiguous in any file
```

or reproduce the real mechanism, which is what `watch` actually does — `compile-file` and
`load` an edited file, from a *different* file than the one the reference is written in:

```
captured #'build -> v1
symbol   'build  -> v2
```

**The general rule:** a checker is most likely to be blind where it is most specialised, and
that is precisely where its green looks most authoritative. So when a control passes, the
question is not "was there a defect after all?" but "can this test see anything at all?" —
and the way to answer it is to make the check fail *on purpose* in a way you fully
understand, before trusting it to fail on a real one.
### You are the worst-placed reader of your own claim

A docstring that describes a security property is a claim about the code, and **the person
least able to check it is the person who wrote it.**

The instance that names this: `praxeon/ceiling:grant-permits-p` said

> *"Means are assembled FROM this rather than filtered by prompt, so a capability a caller
> lacks is absent from the tool table entirely."*

Nothing assembled anything. `agent-tool-specs` advertised every registered means,
`means-entry` had no capability field at all, and `capability-guard` gated a whole *turn*
rather than a means. The sentence described the design that was intended; the code
implemented a smaller part of it; and the sentence was then read — by its own author, more
than once, while working in the same file — as a *description of the code*, because nobody
re-derives a claim they remember writing. It was true when it was a plan and became false
without anyone editing it.

**A security property that exists only as a sentence is worse than an acknowledged gap.** A
gap is the thing a reader goes and checks. A confident sentence is the thing they build on:
this one had already propagated into `praxeon/docs/comparison.md` as the load-bearing
prompt-injection mitigation, in a document intended for publication.

What actually catches it:

- **Read your own docstrings as if someone else wrote them, especially in a file you know
  well.** Familiarity is the whole failure mode — the claim is *recalled* rather than read.
- **A claim about behaviour needs a test that would fail if the claim were false**, and the
  test belongs in the same commit as the sentence. If it cannot be written, the sentence is
  a design note and should say so — "intended", "will", "once X lands" — not the present
  tense.
- **When a doc states a property, grep for the mechanism rather than the words.** Here,
  "assembled from" implied something had to filter a catalogue; nothing did, and one `grep`
  for the capability field would have shown it.

This is the same shape as [reading the doc as the contract and the code as a claim about
it](../AGENTS.md) — one seat over. There, a decided requirement nobody implemented was
invisible because the code looked complete. Here, the requirement was written *into the
code's own documentation*, which is the one place a reader trusts most.

## Editors & the REPL (monorepo)

Open the **repo root** in your editor; one SBCL image serves the whole tree. Two things
make it "just work", both set up at the root:

- **Discovery** — the ASDF `(:tree)` drop-in from `bootstrap.lisp` puts every system in the
  tree on the path (run the seed once).
- **Alive (VS Code)** — three things must hold per machine or the LSP terminal dies instantly:
  the `rheller.alive` extension installed **in that remote** (a WSL/SSH window needs its own
  copy — `code --install-extension rheller.alive` from inside it); **`sbcl` on PATH for the
  process VS Code spawns** (the start command is literally `sbcl`; on WSL our per-user SBCL is
  in `~/.local/bin`, and `~/.profile` is read only by *login* shells, so the export belongs in
  `~/.bashrc` — then `wsl --shutdown`, since the VS Code Server keeps the environment it
  started with); and **alive-lsp on the ASDF path** — the extension *downloads* it on first
  activation, so a freshly installed copy has nothing. On Windows, a machine-local
  `source-registry.conf.d` drop-in pointing into the extension works but is version-pinned;
  on Linux/WSL, cloning alive-lsp into `~/common-lisp/` (on ASDF's default path) needs no
  drop-in and survives extension updates — pin the tag that matches the extension.
- **Heap** — a Coalton-sized heap (`--dynamic-space-size 4096`), so `hyperion` / `praxeon`
  load instead of exhausting the default heap on Coalton's first compile.

The image does **not** auto-load a system (there are several). Load the one you're on:

```lisp
(ql:quickload :cons)        ; or :aion :mnemosyne :elenchon :hyperion :praxeon :hermes
```

Then its packages exist — eval inside that system's files (the editor uses each file's
`(in-package …)`), or switch the REPL with `(in-package :cons/project)`. Several systems
can share one image; edits hot-recompile (`C-c C-k` / the Alive eval commands). Opening a
single framework's **subdirectory** instead auto-loads just that system (its own
`.vscode/settings.json`).

- **VS Code / Alive** — root [`.vscode/settings.json`](../.vscode/settings.json) sets the
  start command (heap + LSP).
- **Emacs / SLIME (or Sly)** — root [`.dir-locals.el`](../.dir-locals.el) points
  `inferior-lisp-program` at the big-heap SBCL; `M-x slime` from any repo file.
- **Neovim / vlime or slimv** — start a server with the heap and connect:
  `sbcl --dynamic-space-size 4096 --eval '(ql:quickload :slynk)' --eval '(slynk:create-server :dont-close t)'`
  (or `:swank` / `swank:create-server`), then `:VlimeConnect` / slimv-connect. (slimv:
  `let g:slimv_lisp = 'sbcl --dynamic-space-size 4096'`.)

A uniform `cons repl` launcher (heap + a Slynk/Swank server any editor connects to) is a
planned cons command; until then the per-editor config above is the "just works" path.
Per-framework `<framework>/docs/editor-setup.md` has more detail.

## House style

- Typed **Coalton** core + effectful **CL/CLOS** shell; **no IO in Coalton**. See the
  `coalton-conventions` and `coalton-gotchas` skills before writing Coalton.
- Pluggable backends behind **neutral protocols**; recoverable failure via the **condition
  system**, not return codes; small pure functions, effects at the edges, **ADTs over
  booleans**.
- Package-per-module with `:local-nicknames`; 2-space indent, no trailing whitespace.
- **Docs-as-handoff**: status is the [Roadmap board](https://github.com/orgs/codelisperer/projects/1)
  and its issues (filter `label:pkg:<framework>`) — don't hand-maintain a Status block; the
  design narrative lives in [`wiki/`](wiki/Home.md) (`wiki/Framework-<Name>.md`); record
  architecturally-significant decisions as **ADRs** (see [`../hyperion/docs/adr/`](../hyperion/docs/adr)).
  The root [`ECOSYSTEM.md`](../ECOSYSTEM.md) + per-framework `CLAUDE.md` are the
  cross-machine brain — durable facts go there.

## Troubleshooting

- **First Coalton compile is slow / OOMs** — expected; give SBCL the big heap
  (`--dynamic-space-size 4096`) and let it finish; cached after.
- **A system isn't found** — re-run the seed once (it writes the drop-in); confirm
  `~/.config/common-lisp/source-registry.conf.d/50-ouranos.conf` exists and points at your
  checkout.
