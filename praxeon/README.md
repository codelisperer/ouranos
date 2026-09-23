# Praxeon

*A praxeological framework for industrial-strength agentic AI, in Common Lisp + Coalton.*

Praxeon is an attempt to build a serious agent-orchestration framework in the
lineage of Norvig's *Paradigms of AI Programming* — and to do better than the
Python `Lang*` family and TypeScript's Mastra by putting a principled model at
the core instead of an ad-hoc pile of "chains" and "runnables."

## The thesis

Praxeon targets the **agent, orchestration, and context-management layer** —
CPU-bound work where homoiconicity, macros, the condition system, CLOS/MOP, and
live image-based development are decisive, and where the ecosystem moat is
thinnest — and FFIs out to existing kernels for anything numeric. (The broader
"CL all the way down" motivation, and why Python won AI as glue over C++/CUDA
rather than on language merits, lives in the [root README](../README.md) and
[ECOSYSTEM.md](../ECOSYSTEM.md).)

## The model (why "Praxeon")

The name is coined from von Mises' **praxeology**, the science of human action,
whose ontology maps almost exactly onto agents:

| Praxeology            | Agent architecture                          |
|-----------------------|---------------------------------------------|
| ends                  | goals                                       |
| means                 | tools                                       |
| action                | a step (applying a means toward an end)     |
| preference over ends  | the objective / valuation                   |
| action under uncertainty | the LLM's probabilistic reasoning        |
| economizing scarce time | the context/token budget                  |
| imputation of value   | credit assignment for tool calls            |

So the core vocabulary is `end`, `means`, `action`, `actor`, `plan` — a more
principled agent DSL than "node/chain/runnable."

## Architecture

Two layers:

- **Typed core (Coalton).** `src/praxeology.lisp` defines what agents *are*
  (`End`, `Means`, `Action`, `Plan`, `Actor`) with Hindley–Milner types. This is
  the "statically typed core" story for a type-conscious shop.
- **Dynamic shell (Common Lisp).** Conditions/restarts for recoverable failure,
  the LLM provider protocol, the budgeted context, and the deliberate→act loop
  live in ordinary CL, where dynamism and IO belong.

```
praxeon/
  praxeon.asd              ; systems: praxeon, praxeon/elise, praxeon/tests
  src/
    packages.lisp
    praxeology.lisp       ; Coalton-typed ontology
    conditions.lisp       ; recoverable-failure protocol
    context.lisp          ; budgeted, bitemporal context (seed of Kairos)
    llm.lisp              ; provider protocol + Anthropic
    actor.lisp            ; the deliberate/act loop
  examples/elise/         ; Elise: the modern-psychology ELIZA successor (PoC)
  tests/
  paper/                  ; LaTeX write-up of the value proposition
```

## Kairos (roadmap)

The bitemporal stamps on context items (`valid-time`, `tx-time`) are the seed of
**Kairos**, a standalone bitemporal knowledge graph for context management — the
kind of substrate that lets an agent reason about *what we believed, and as of
when*. Like XTDB, it will likely FFI to Apache Arrow for zero-copy columnar
storage rather than reimplement a query engine.

## Getting started

This framework is one of six in the [Ouranos monorepo](../README.md); you build the
whole tree, not this directory alone. Prereqs: **SBCL + Quicklisp** (Coalton loads from
Quicklisp on first use).

    git clone https://github.com/codelisperer/ouranos.git
    cd ouranos
    sbcl --dynamic-space-size 4096 --script bootstrap.lisp   # → bin/cons

`bootstrap.lisp` points ASDF at the whole tree and writes a source-registry drop-in, so
every REPL can find the frameworks with no symlinking. From any SBCL REPL:

    (ql:quickload :praxeon/elise)   ; first load compiles Coalton — minutes, then cached

`bin/cons build | test | serve | run` is the intended one-command interface (in
progress; today `cons` implements `init` / `setup` / `version`).

Add a provider key to `.env` (copied from `.env.example`), then talk to Elise —
the reflective-companion demo agent, from any REPL:

```lisp
(ql:quickload :praxeon/elise)
(praxeon/elise:start)     ; interactive Elise session
```

A minimal `.env`:

```sh
PRAXEON_LLM_IMPL=anthropic
PRAXEON_ANTHROPIC_MODEL=claude-sonnet-5
PRAXEON_ANTHROPIC_API_KEY=sk-ant-...
# Cheaper/free alternative: PRAXEON_LLM_IMPL=openrouter + PRAXEON_OPENROUTER_* vars.
```

**Per-agent models.** Configuration is *not* global — each agent resolves its own
model by **role**: `PRAXEON_<ROLE>_MODEL` (also `_IMPL`/`_API_KEY`/`_AUTH`) wins over
the shared `PRAXEON_LLM_*`. So one process runs several agents, each on its own
model — e.g. Elise deliberating on a strong model while a fast one translates:

```sh
PRAXEON_LLM_MODEL=claude-sonnet-5                  # shared default
PRAXEON_ELISE_MODEL=claude-opus-4-8                # the therapist agent
PRAXEON_TRANSLATE_MODEL=claude-haiku-4-5-20251001  # the translator agent
```

**Talk in your language.** Elise localizes her chrome (en/es/ru — drop a JSON file
to add a language) *and* converses in the selected locale: a **translator agent**
renders your message into English for Elise and her reply back into your language.

Dependencies (`coalton`, `alexandria`, `dexador`, `com.inuoe.jzon`, `fiveam`) are
pulled by Quicklisp on first load. A root `cons.lisp` build spec drives the common
tasks via `cons <target>` (`cons check`, `cons paper`, or bare `cons` to list them) —
see [`docs/user-guide.md`](docs/user-guide.md).

**Full guide** — configuring providers, the studio, editor-connected REPLs, and
troubleshooting — is in [`docs/user-guide.md`](docs/user-guide.md).

## Opt-in systems beside the core

- **`praxeon/web`** — a Clack-based web + REST surface (HTMX chat UI, `POST /api/message`,
  `GET /api/progress`), rendering the same event stream the CLI does.
- **`praxeon/web-search`** — web search as a registered *means*, over the same
  provider-neutral protocol as the LLM layer.
- **`praxeon/translate`** — the translator agent (English pivot), which is how Elise
  converses in the user's locale.
- **`praxeon/elise`** — the reflective-companion example. Demoware, with prominent
  disclaimers and a crisis guardrail.
- **`praxeon/chat-rbt`** — **Elenchon's motivating example**: a natural-language
  requirement, conversed and disambiguated into a Cause-Effect Graph, then handed down to
  [`elenchon`](../elenchon) for the minimal test set. It lives here rather than in elenchon
  because the NL step is agentic and the DAG forbids elenchon depending rightward.

## Status & license

Pre-alpha (0.0.1) — a scaffold, not a product. Contributions from one future self
to another are welcome. MIT-licensed, like the rest of the monorepo; see the
[root README](../README.md) and [ECOSYSTEM.md](../ECOSYSTEM.md) for ecosystem-wide
status and governance.
