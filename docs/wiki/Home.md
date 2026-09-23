# Ouranos — a metaframework for full-stack Common Lisp

Welcome to the Ouranos wiki. This is the **narrative home** of the
[codelisperer](https://github.com/codelisperer) ecosystem: what we're building, why we
chose this shape, and how to work in it. The repository keeps the artifacts — READMEs,
ADRs, design specs, papers. The wiki keeps the *story*.

Ouranos is a monorepo holding **six co-evolving Common Lisp / Coalton core frameworks**,
plus one satellite library, for building real applications — web, data, agentic AI,
testing — without a JVM or a Node toolchain anywhere in the picture.

The name is not decoration. The libraries are named for **Titans and primordials** —
Hyperion, Mnemosyne, Aion — and **Ouranos** is the primordial sky, *father of the Titans*:
the source from which they all descend.

---

## Why this exists

Ouranos begins as a reaction to **dependency sprawl**.

Modern stacks — the JVM's, Node's — get their power by assembling dozens of
independently-versioned libraries, each with its own release cadence, its own idea of what
"breaking" means, and its own transitive tail. Bumping one can cascade through the rest.
You end up maintaining the *assembly* as much as the application. The maintainer here loves
Clojure the language; what wore thin was the ecosystem weight around it.

So Ouranos bets the other way, on four convictions:

### 1. CL all the way down

There is exactly one substrate. HTML is s-expressions (Spinneret). JavaScript is Lisp
compiled to JS (Parenscript — **no Node**). Queries are data structures, not string DSLs.
The build tool is Lisp. The scripts are Lisp. Even the seed that stands the whole tree up
is `sbcl --script`.

This is not purism for its own sake. A single homoiconic substrate means one set of
abstractions, one debugger, one REPL, and one mental model — instead of a host language
wrapped around N embedded mini-languages that each need their own tooling, their own
formatter, and their own way of failing.

### 2. A typed core, where it earns its keep

Ontology and pure logic live in **Coalton** — Hindley–Milner types, checked at compile
time. Effects, IO, and dynamism live in the **CL/CLOS shell** around it. You get
abstractions a human *and* an AI can reason about statically, without surrendering
REPL-driven iteration and hot-reloaded feedback.

The rule that keeps this honest is blunt: **no IO in Coalton.** The typed core stays pure;
the shell does the messy work at the edges.

### 3. Few, cohesive, co-versioned, house-owned

The frameworks evolve together in one repository with one history, so a cross-cutting
change — a protocol *and* its implementer — is a single atomic commit. Only genuine
external services (the Postgres wire protocol, Stripe, SendGrid, Twilio, LLM providers)
sit behind thin **neutral protocols**. Dependencies are held to a conscious minimum and
tracked deliberately.

### 4. SBCL, embraced rather than hedged

We target one excellent implementation and optimize for it, the way Coalton does. That
buys native binaries via `save-lisp-and-die`, a live image, real threads, and instant
scripting. `sbcl --script` *is* our Babashka. There is **no make, no just, no nmake**
anywhere in the tree — the build tool is Lisp, and the same command works identically on
Linux, macOS, and Windows.

### The deeper bet

Lisp *put AI on the map* — it was the native tongue of symbolic AI for decades. The debt
now runs the other way: it is **AI's turn to put CL back on the map**, and not merely as an
AI language but as a fully modern, multi-modal dev stack — one core, many faces (web,
desktop, CLI, mobile, API). Modern coding assistants make a homoiconic,
typed-where-it-counts, REPL-driven stack newly approachable, even for people who "hate
parens." That's why AI-friendly docs and code are a first-class goal here, not an
afterthought — see [Working With AI Agents](Working-With-AI-Agents.md).

---

## The roster

### Six core frameworks, in strict DAG order

The dependency order is the project's one hard rule, and it reads left to right:

```
aion → cons → mnemosyne → elenchon → hyperion → praxeon
```

A framework **never** depends on one to its right. ASDF enforces this by erroring on
cycles, so the rule is not aspirational — it's mechanical.

| Framework | Role | Wiki |
|---|---|---|
| **Aion** (Αἰών) | Coalton-first functional standard library — persistent collections, a pure-CL `ISeq`, a CSV reader/writer with a conformance oracle | [Framework Aion](Framework-Aion.md) |
| **cons** | Project and dev tooling — "cargo for Lisp": scaffolding, the `cons.lisp` build-spec task runner, the AI-conformance pack, dependency management next | [Framework Cons](Framework-Cons.md) |
| **Mnemosyne** | Data and persistence — Ecto-flavored, pluggable backends behind a neutral protocol (SQLite → Postgres → XTDB 2); **queries are data, not macros** | [Framework Mnemosyne](Framework-Mnemosyne.md) |
| **Elenchon** (ἔλεγχος) | Requirements-Based Testing via Cause-Effect Graphs — a pure CEG engine reducing to a minimal decision table (≈ MC/DC) | [Framework Elenchon](Framework-Elenchon.md) |
| **Hyperion** | The full-stack, HTMX-first web framework — Spinneret, Parenscript, i18n, sessions, channels, a typed interceptor pipeline, a live hot-reload image | [Framework Hyperion](Framework-Hyperion.md) |
| **Praxeon** | Praxeological framework for agentic AI — actors / means / ends, provider-neutral LLMs, workflow | [Framework Praxeon](Framework-Praxeon.md) |

Auxiliary systems inside a framework *may* reach rightward (`praxeon/web → hyperion`,
`hyperion/testing → elenchon`) as long as the system-level graph stays acyclic. It's the
**core** systems that are bound by the line. Apps and examples that combine frameworks live
in the **highest** framework they need.

### Plus hermes — a satellite leaf-lib, outside the DAG

| Framework | Role | Wiki |
|---|---|---|
| **hermes** | External integrations — all the messaging an app needs behind one neutral `deliver`/`send` protocol (email + SMS shipped, via SendGrid/Twilio and a dev transport, plus signature-verified inbound webhooks); payments next | [Framework Hermes](Framework-Hermes.md) |

hermes deliberately sits **off the line**. It depends only on `aion` plus external
HTTP/JSON libraries, and never on mnemosyne, hyperion, or praxeon. Crucially, **nothing in
the core DAG depends on hermes** — it is a leaf. Apps consume it directly, which is exactly
what lets it talk to the outside world without dragging third-party service concerns into
the core. Persistence belongs to mnemosyne; web endpoints belong to hyperion; hermes owns
only the provider protocol, the client, and webhook verification.

---

## What Ouranos is *not*

It is the **library ecosystem, not the products**. Applications that consume these
frameworks live in their own repositories, above the tree, and are separately licensed. The
frameworks themselves are MIT. A consuming app onboards by dropping its own ASDF
source-registry file beside Ouranos's — see [Getting Started](Getting-Started.md).

---

## Status

**Pre-alpha (0.0.0).** Actively built. Hyperion is furthest along and Praxeon already runs
on it; cons's bootstrap seed, scaffolding, conformance pack, and task runner are real;
mnemosyne and elenchon are earlier. Expect movement.

The roadmap is **not** duplicated in this wiki. It lives on the board:

- **Roadmap board** — https://github.com/orgs/codelisperer/projects/1
- Open issues by framework:
  [aion](https://github.com/codelisperer/ouranos/issues?q=is%3Aissue+is%3Aopen+label%3A%22pkg%3Aaion%22) ·
  [cons](https://github.com/codelisperer/ouranos/issues?q=is%3Aissue+is%3Aopen+label%3A%22pkg%3Acons%22) ·
  [mnemosyne](https://github.com/codelisperer/ouranos/issues?q=is%3Aissue+is%3Aopen+label%3A%22pkg%3Amnemosyne%22) ·
  [elenchon](https://github.com/codelisperer/ouranos/issues?q=is%3Aissue+is%3Aopen+label%3A%22pkg%3Aelenchon%22) ·
  [hyperion](https://github.com/codelisperer/ouranos/issues?q=is%3Aissue+is%3Aopen+label%3A%22pkg%3Ahyperion%22) ·
  [praxeon](https://github.com/codelisperer/ouranos/issues?q=is%3Aissue+is%3Aopen+label%3A%22pkg%3Apraxeon%22) ·
  [hermes](https://github.com/codelisperer/ouranos/issues?q=is%3Aissue+is%3Aopen+label%3A%22pkg%3Ahermes%22)

---

## Navigation

**Start here**

- [Getting Started](Getting-Started.md) — prerequisites, the one-command bootstrap, and your first REPL
- [Contributing](Contributing.md) — the DAG rule, house style, tests, worktrees
- [Working With AI Agents](Working-With-AI-Agents.md) — the `ai-task` issue policy, agent identity, confidentiality

**The frameworks**

- [Framework Aion](Framework-Aion.md) — the functional standard library
- [Framework Cons](Framework-Cons.md) — project and dev tooling
- [Framework Mnemosyne](Framework-Mnemosyne.md) — data and persistence
- [Framework Elenchon](Framework-Elenchon.md) — requirements-based testing
- [Framework Hyperion](Framework-Hyperion.md) — the web framework
- [Framework Praxeon](Framework-Praxeon.md) — agentic AI
- [Framework Hermes](Framework-Hermes.md) — external integrations (satellite leaf-lib)

**In the repository**

- `README.md` — the short pitch
- `ECOSYSTEM.md` — the committed shared brain: thesis, decisions log, how-we-work
- `AGENTS.md` — the tool-neutral conformance spec
- `docs/coalton-patterns.md` — the worked Coalton reference; read it before writing
  `coalton-toplevel` code
- `docs/dependencies.md` — the dependency surface, held to a conscious minimum
- Per-framework `CLAUDE.md` and `docs/adr/` (architecture decisions); status lives on the
  [Roadmap board](https://github.com/orgs/codelisperer/projects/1)
