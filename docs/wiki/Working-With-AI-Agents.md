# Working With AI Agents

Ouranos is built with AI assistants in the loop, deliberately and as a first-class concern.
The thesis on [Home](Home.md) states it plainly: Lisp put AI on the map, and it is now **AI's turn
to put Common Lisp back on the map**. Modern coding assistants make a homoiconic,
typed-where-it-counts, REPL-driven stack newly approachable — including to people who
"hate parens." So AI-friendly docs and AI-friendly code are goals here, not accidents.

That commitment brings obligations. This page is the policy: where AI tasks live, how an
agent identifies itself, what it must never write down, and how a new project inherits all
of it in one command.

The canonical, tool-neutral source is **`AGENTS.md`** at the repository root. Any assistant
— Claude, Codex, Cursor, anything else — follows that file. `CLAUDE.md` simply `@`-imports
it, so there is exactly one spec and no drift between tools.

---

## AI and system tasks live as GitHub issues

**Cross-session and AI task handoffs are GitHub issues on `codelisperer/ouranos`, labeled
`ai-task`. They are not files in the tree.**

This replaced an earlier `docs/tasks/` inbox, and the reasons are worth stating because
they generalize:

- **Issues auto-number.** Two agents working in parallel worktrees can't collide on an ID
  the way two files named `task-004.md` will.
- **Issues edit and delete cleanly.** A task's state changes constantly — reworded, split,
  reprioritized, abandoned. Files in git accumulate that churn as commits.
- **Issues never enter immutable history.** A half-formed task description written at 2am
  should not be permanently attached to the source tree. Git remembers everything, which is
  exactly wrong for a scratchpad.
- **Issues are addressable from outside the checkout** — from the board, from a phone, from
  a session that hasn't cloned anything.

The workflow:

| Action | Command |
|---|---|
| Read the inbox | `gh issue list --label ai-task --state open` |
| File a task | `gh issue create --label ai-task --title … --body …` |
| Finish a task | close the issue |

Roadmap and planning live on the board — https://github.com/orgs/codelisperer/projects/1 —
and framework-scoped work is filterable, e.g.
[`pkg:hyperion`](https://github.com/codelisperer/ouranos/issues?q=is%3Aissue+is%3Aopen+label%3A%22pkg%3Ahyperion%22).
None of that is duplicated into the wiki; the board is the single source of truth for *what's
next*, and the wiki is the source of truth for *what things are and why*.

---

## Every AI-managed ticket identifies its filing agent

This is a provenance rule and a confidentiality rule at the same time, and it has two
distinct forms depending on where the session is running.

**A session working in Ouranos states its OS and instance.** Something that reads:

> Filed by Ouranos Claude (macOS)

with the variants "(Windows)" and "(Linux/WSL)". This matters because a great many issues in
this repo are platform-shaped — CRLF checkouts, Homebrew's SBCL version on macOS, PowerShell
provisioning, path handling. Knowing which instance filed a report is often the first half
of diagnosing it. It also makes it possible to tell two parallel worktree agents apart when
their issues land minutes from each other.

**A session working in a consuming application** names the app when it is the maintainer's own
or is open-source — that is the useful case, because the issue it files can then be found from
either side. When the app is a **client's**, it identifies only as:

> Claude on a private Ouranos-built app

and **never names the app, the client, or the organization.**

The asymmetry is the point. Framework issues frequently originate in real application work:
you hit a mnemosyne limitation while building a feature, and the right place for that issue
is the framework repo. The rule lets that flow happen without leaking who the work was for.

---

## Confidentiality

**This rule protects other people's confidences — not the maintainer's own products.** Those
are different things, and conflating them costs precision for no benefit.

**Never name a client's application in this repository.** Not in code, not in comments, not in
docs, not in papers, not in commit messages, not in issues, not in wiki pages. Not the app's
name, not the organization's, not a prior app it's ported from, not its static assets or
branding.

Generalize instead. "A consuming app." "A CRM app." "A prior Clojure/Kit web app." That
phrasing appears throughout the committed docs precisely so there's an obvious pattern to
follow — `ECOSYSTEM.md` describes real, funded application work driving hyperion and
mnemosyne, and never once says whose.

**The maintainer's own products may be named**, and usually should be. SoftCraft's applications
drive much of the roadmap, and "the Windows-first app needs an NT service" is a worse issue than
naming which one — a named issue can be found, compared against its sibling, and argued with.
The `app:*` labels exist for exactly this, one per product, with **`app:client`** for the
application that stays unnamed by construction.

The asymmetry is not about secrecy levels. It is about **whose** confidence is at stake: the
maintainer can choose to publish his own roadmap, and cannot choose that on someone else's
behalf.

Ouranos is a private repository today. **The rule holds regardless.** Repository visibility
changes with one click; git history does not, and neither does an issue that has already
been read. Write as though the repo were public, because one day some of it will be, and
retroactive redaction of a git history is not a thing that works.

Practical guidance for an agent: if you're carrying context from an application session into
a framework issue, strip identifiers *before* writing, not after. Describe the failure, the
framework surface involved, and the reproduction — none of which require a client name.

---

## `cons conform` — the conformance pack

Everything above, plus the house style from [Contributing](Contributing.md) and the Coalton rules, has to
reach an assistant *in whatever project it's working in*. That's what `cons conform` does:

```sh
cons conform
```

It installs the **AI-conformance pack** into a project — either a new one via `cons init`,
or an existing one:

| Artifact | Purpose |
|---|---|
| `AGENTS.md` | the canonical, tool-neutral conformance spec — the DAG, house style, Coalton rules, the `ai-task` policy, confidentiality |
| `CLAUDE.md` | a thin project constitution that `@`-imports `AGENTS.md` and adds project specifics |
| `.cursor/rules` | the same spec in Cursor's format |
| `.claude/skills` | task-shaped skills (e.g. the Coalton gotchas, mnemosyne data modeling) |

By default it's non-destructive — it skips files that already exist unless you force an
overwrite — and it can install a subset (`--tools codex` writes `AGENTS.md` alone).

This is the **metaframework dogfood**, and it's the reason the tool exists in this shape:
*cons teaches the AI to use the frameworks.* A consuming app's assistant doesn't have to
rediscover that IO stays out of Coalton, that `declare` signatures are uncurried and
`*`-separated, that queries are data rather than macros, or that a client name never appears
in a framework issue. It gets all of that installed alongside the scaffolding.

Which also means: when a rule changes, it changes in `cons/src/conform.lisp` and propagates
on the next `cons conform`. If you discover a new Coalton pitfall, the full move is —
document it in `docs/coalton-patterns.md`, then mirror the one-liner into the pack.

---

## Working well with agents here, in practice

A few habits that make agent sessions productive in this codebase specifically:

- **Point the agent at `docs/coalton-patterns.md` before it writes Coalton.** The failure
  modes are non-obvious and the compiler's error messages for them are actively misleading
  (a `FORMAT ~<newline>` on a CRLF checkout reports as a "macroexpansion" error). Reading
  the reference first is much cheaper than debugging it after.
- **Give each parallel track its own worktree.** `git worktree add ../ouranos-<track> -b
  work/<track>`, one agent per worktree, merge to `main` when green. Two agents in one
  checkout share a fasl cache and a live image, and that ends badly.
- **Keep the board honest.** The
  [Roadmap board](https://github.com/orgs/codelisperer/projects/1) and its issues (filter
  `label:pkg:<framework>`) are what the *next* session reads first — have the agent close
  what it finished and file what it found, instead of editing a Status block. Durable
  reasoning goes in this wiki's `Framework-<Name>.md` page.
- **Promote durable facts into committed files.** Editor auto-memory is machine-local and
  private; it does not travel. If something must survive a new machine or a fresh session,
  it belongs in `ECOSYSTEM.md`, a framework's `CLAUDE.md`, or `docs/`.
- **Prefer editing existing files to creating new ones**, and don't spawn summary or report
  markdown files as a side effect of doing work. The tree stays lean on purpose.

---

**See also:** [Contributing](Contributing.md) for the house style an agent must conform to ·
[Getting Started](Getting-Started.md) for the environment · [Home](Home.md) for the roster ·
`AGENTS.md` in the repository for the canonical spec.
