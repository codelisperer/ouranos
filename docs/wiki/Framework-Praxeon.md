# Praxeon — the praxeological agentic-AI framework

*A framework for industrial-strength agentic AI in Common Lisp + Coalton, in the lineage of
Norvig's* Paradigms of AI Programming *— with a principled model at the core instead of an
ad-hoc pile of "chains" and "runnables."*

---

## What it is, and why it exists

Praxeon targets the **agent, orchestration, and context-management layer** — not the tensor
hot path.

The thesis is deliberately narrow, because narrowness is what makes it winnable. Python won
AI as **glue over C++/CUDA kernels**, not on language merits; no host language gets "closer
to Rust" on tensors, because that path is already not Python either. The winnable ground is
the **CPU-bound orchestration layer**, where homoiconicity, macros, the condition system,
CLOS/MOP and live-image development are decisive and the ecosystem moat is thinnest. Praxeon
plays there and FFIs out for anything numeric.

### The model (why "Praxeon")

The name is coined from von Mises' **praxeology**, the science of human action, whose
ontology maps almost exactly onto agents:

| Praxeology | Agent architecture |
|---|---|
| ends | goals |
| means | tools |
| action | a step (applying a means toward an end) |
| preference over ends | the objective / valuation |
| action under uncertainty | the LLM's probabilistic reasoning |
| economizing scarce time | the context / token budget |
| imputation of value | credit assignment for tool calls |

So the public vocabulary is `end`, `means`, `action`, `actor`, `plan` — a more principled
agent DSL than "node/chain/runnable", and one that keeps its meaning as the system grows.
**The scarce resource an agent economizes is the context/token budget**; that framing is not
decoration, it is what makes context management, model routing and memory the *same* problem
rather than three features.

### Two layers

- **Typed core (Coalton)** — `src/praxeology.lisp` defines what agents *are* (`End`,
  `Means`, `Action`, `Plan`, `Actor`) with Hindley–Milner types.
- **Dynamic shell (Common Lisp)** — conditions/restarts for recoverable failure, the LLM
  provider protocol, the budgeted context, the deliberate→act loop. Effects, IO and dynamism
  belong here.

Rule of thumb: **ontology and pure logic go in Coalton; effects, IO and dynamism go in CL.**

---

## Where it sits in the DAG

```
aion → cons → mnemosyne → elenchon → hyperion → praxeon
                                    (hermes — off-DAG satellite leaf-lib)
```

| Rule | What it means for Praxeon |
|---|---|
| Praxeon is **rightmost** | It may depend on anything to its left — and *only* it can reach an LLM *and* the web framework in the same system. Several designs land here for exactly that reason. |
| Nothing depends on Praxeon | No framework may reach right into it. That is why the web engine was extracted *out* of praxeon into Hyperion rather than the reverse. |
| Combined apps live highest | **ChatRBT** — the agentic NL→Cause-Effect-Graph app that *drives* elenchon — lives in `praxeon/examples/chat-rbt`, not in elenchon, so the graph stays acyclic. |
| `hermes` is off-DAG | An agent that must send email or SMS uses `hermes` (which depends only on `aion`), never a praxeon-local integration. |

`praxeon/web` depends on `hyperion` and keeps only the agent/chat domain glue.

---

## Current status

**Pre-alpha (0.0.1).** The full system loads with the real Coalton core and the network-free
fiveam suite is green. The demo agent, **Elise** — a reflective-companion PoC — runs both in
the CLI and as a web app.

### Shipped

| Area | What works |
|---|---|
| **Tool-use dispatch** | The `deliberate → act` loop closes (`actor.lisp`): `agent-tool-specs` advertises the means registry, each chosen means is applied through `act` under the retry/substitute/abandon restarts, `tool-result`s feed back, bounded by `:max-steps`. |
| **Provider neutrality** | Two providers proven live — `anthropic` (Messages API, `x-api-key`) and `openai-compatible` (any OpenAI `/v1` endpoint: Ollama, LM Studio, OpenRouter) — plus a network-free `scripted` provider for tests. |
| **Config** | Env-driven selection with `PRAXEON_LLM_*` and per-provider `PRAXEON_<IMPL>_*` overrides, loaded from a git-ignored `.env`. |
| **Per-agent models (roles)** | Config is **not global**: `PRAXEON_<ROLE>_*` > `PRAXEON_<IMPL>_*` > `PRAXEON_LLM_*`, so one process runs several agents each on its own model/vendor. |
| **Studio DX** | `agent-summary` / `describe-agent` / `show-transcript` / `trace-turn`, with a deliberate data/render split. |
| **Live progress** | `praxeon/event` — the loop emits neutral `:deliberating` / `:tool-call` / `:tool-result` / `:answer` events to an observer; CLI and web render the *same* stream. |
| **Web + REST** | `praxeon/web` (now on Hyperion): an HTMX chat page, `POST /api/message` (background turn; JSON for REST clients), `GET /api/progress`. One endpoint serves browser and program by content negotiation. |
| **Hot-reload dev loop** | Layers 1–2: watch → recompile → rebuild the server around a *persistent agent*, auto-refreshing `:dev` pages, and compile errors as a red browser overlay. Plus transcript rehydration on load. |
| **Multi-agent coordination** | Both halves: **delegation** (`register-agent-as-means`) and **workflows** (`praxeon/workflow`) — network-free tested. |
| **Token-cost visibility** | Neutral `completion` carries usage; the loop emits `:usage`; the web header shows a running `· N tokens`. |
| **Spend / rate / capability ceiling** | `praxeon/ceiling` (#172) — an Ed25519-signed **grant** carrying principal, capability set, expiry and audience, verified with a **public key only** so the agent host cannot mint one. `budget-guard` refuses a turn *before* the model call rather than discovering the ceiling after paying; `meter` charges the completed turn; usage comes back in-band. This is what lets a consuming app price AI into tiers. |
| **First real means** | `praxeon/web-search` — Tavily-backed, registered when `TAVILY_API_KEY` is set, compact results to respect the budget. |
| **Translation** | `praxeon/translate` — one-shot, locale-aware, provider-neutral; Elise converses in the user's locale via a **translator agent** on its own model. |
| **Standalone binary** | `bin/elise` via `save-lisp-and-die`; Woo's libev FFI survives the dump, verified. |
| **Build** | A root `cons.lisp` spec driven by `cons <target>` (`check`, `build`, `test`, `elise`, `paper`, `run`, `serve`, `dev`), replacing the removed `Makefile`. |

### Planned

Growing the Coalton typed core; **Kairos** (the bitemporal context engine) and observational
memory with semantic retrieval; LLM-layer hardening (streaming, retry/backoff, real token
counting); **MCP** client support; model routing; a graphical studio; per-session agents for
multi-user "as a service"; live-reload layer 3 (conditions with restart selection in the
browser).

### Constraints

- **Provider-neutral:** no vendor shape leaks above `llm.lisp`.
- **Coalton is a local checkout**, not a Quicklisp dep in the historical setup, and
  **Ultralisp must stay disabled** (it breaks `fset` on recent SBCL).
- Deps stay on Quicklisp for now; ocicl is deferred.

---

## Design narrative

### 0. The guiding constraint — the provider abstraction

> *"I want an abstraction layer to make Praxeon extensible to any LLM (including any custom
> LLM some day built from scratch using Praxeon). Anthropic is perfect for bootstrapping."*

This is **the** decision the framework is organised around, and it is a hard constraint rather than a preference.
Everything the agent loop touches is provider-neutral; a vendor wire format appears only
inside a `complete` method.

- `complete (provider messages &key system tools max-tokens temperature)` is the **entire**
  protocol — one generic function.
- It returns a neutral `completion` (`text` + `tool-calls` + `stop-reason` + usage), never a
  string or a vendor blob.
- Requests carry neutral `tool-spec`s and neutral message *content parts* (`:text` /
  `:tool-use` / `:tool-result`).
- Any vendor is *one translation* of that vocabulary. A future provider — a local model,
  another vendor, or a model grown inside Praxeon itself — is a new class with one method.
  **The actor loop never changes.**

The invariant to police: **no `actor.lisp` code, and nothing above it, may reference a
vendor-specific shape.** Reaching for JSON or `stop_reason` strings outside `llm.lisp` means
pushing it back down.

**Status: validated live.** The same `run-turn` loop drives Anthropic, OpenAI-compatible
endpoints (tested across several hosted and local models, including a reasoning model), and
the network-free `scripted` provider — with **zero actor-layer changes across all four.**
The abstraction is not aspirational; it has been falsified-tested and held.

Two smaller decisions that fall out of neutrality: `temperature` is **omitted by default**
because current models reject a non-default value (so new params stay opt-in for the same
reason), and `*default-max-tokens*` is tunable because reasoning models need headroom or
their deliberate step silently truncates.

### 1. Tool use — "means" and the dispatch loop

Tool use is not a bolt-on; it is the praxeological reading of what an agent *is*. A means is
registered with a description and an optional JSON `:schema` — the schema is how a means
advertises its shape — and `run-turn` is the agentic loop: deliberate, apply each chosen
means through `act` under the restart protocol, feed results back, repeat until the model
answers.

Recoverable failure goes through the **condition system**, not return codes:
`retry-action` / `substitute-result` / `abandon-action` restarts are established around the
application of a means. This is the piece that has no equivalent in Python or TypeScript
agent frameworks — a failing tool call is a *resumable* computation, not an exception that
unwinds the turn.

Open follow-ups: **parallel tool calls** (providers can return several `tool_use` blocks at
once; today they are applied sequentially — fan-out is a natural extension of the
tool-results message), and streaming so long tool loops surface progress.

### 2. The Coalton typed core — how far to push it

The core defines `End/Means/Action/Plan/Actor` but no *execution* or *preference* semantics
yet. That logic is pure and total — exactly what Coalton is for — and a typed `Plan` fold
would let the type checker guard plan construction.

The planned steps are each a praxeology idea made typed: a **`Valued` instance** so competing
plans and ends can be ranked (imputation of value); an **`Outcome`-typed action result** so
the pure core can describe success/substitution/abandonment *without performing IO*; and
**plan execution as a fold over `Action`s** — still pure, the fold sequences intent while
effects stay in CL.

The open question, honestly stated in the vision doc, is whether the typed core should become
a *real typed engine* driving the runtime, or remain a minimal elegant statement with CL
doing the heavy lifting at the edges. The answer changes how much of the ontology is worth
lifting.

### 3. Kairos — the bitemporal context engine

Context started as `src/context.lisp`: a greedy in-memory list with `valid-time` / `tx-time`
stamps and a `TODO` admitting that "greedy by value-density" is really a **knapsack**. Those
stamps are the seed of the real thing — a bitemporal knowledge graph that answers *what we
believed, and as of when.*

Kairos is the substrate, and the design is a stack of increasingly ambitious layers:

- **Proper selection** — knapsack, or value-density with recency/validity decay folded in
  from the bitemporal stamps.
- **`as-of` queries** over valid-time and tx-time.
- **Eviction plus a summarization/compaction hook** when the working set exceeds budget.
- **Semantic retrieval via a pluggable vector store** — recall by *meaning*, not only
  recency and value. First integration is **Qdrant over its REST API**, deliberately the
  same thin HTTP-at-the-edges pattern as the LLM providers, **behind a neutral vector-store
  protocol** so other stores slot in, with embeddings behind an embedding-provider protocol.
  Neutrality is applied here for the same reason it is applied to LLMs.
- **Later:** FFI to a columnar store (Apache Arrow, XTDB-style) rather than reimplementing a
  query engine — the same "FFI out for the heavy machinery" instinct as the tensor story.

Kairos is also the storage layer that observational memory reads and writes, which is why it
is sequenced first: memory needs the store.

### 4. Hardening the LLM layer

Make the provider production-grade **without breaking the neutral protocol**:

- **Streaming completions** forwarded as token `:delta` events into the *same*
  `praxeon/event` observer stream, so CLI and web renderers get token-by-token output for
  free — it builds on the shipped live-progress contract rather than adding a second one.
- **Retry/backoff on 429 / overload expressed through the condition system** — a
  `provider-overloaded` condition plus a `retry` restart — not an ad-hoc loop. The free-tier
  429s hit during development made this concrete.
- **Real token counting** via the count-tokens endpoint, feeding Kairos budgeting.
- Splitting or stripping a provider's `reasoning` field so chain-of-thought models render
  cleanly.

### 5. Mastra borrowings — adapted, not copied

Mastra (the TypeScript agent framework) is the closest comparable, and several of its
capabilities were worth taking. The discipline was to **re-express each in Praxeon's own
vocabulary** rather than port its API — if a borrowed feature can't be said in
ends/means/actions, it probably doesn't belong.

#### Multi-agent coordination — the two halves (shipped)

Mastra offers agent networks and workflows; Praxeon ships both, and names why they are
*two* things rather than one:

- **Delegation — agent-as-means (model-driven).** Register one agent as a **Means** of
  another; when the coordinator's model calls it, the sub-agent runs its *own* `run-turn`
  and returns its answer as the tool result. The praxeological reading is exact: *a sub-agent
  is a Means whose effect is "another Actor acts."* Because of that framing it reuses the
  entire deliberate/act loop, the restart protocol and the event stream — **no new control
  structure at all** — and each agent keeps its own provider, hence its own vendor and model.
  It emits a `:delegate` event. This is the shape a writing assistant with research /
  continuity / style specialists wants.
- **Workflow — the Plan runtime (code-driven).** A `workflow` sequences agents through
  ordered **steps** (and `parallel` fan-out groups) toward a shared **End**, threading
  outputs through a shared **blackboard**. A step's prompt is a string *or a function of the
  blackboard*, so later steps consume earlier ones; parallel groups have explicit fan-out
  semantics — each child sees the blackboard as of the group's start, not each other. This
  is the runtime for the ontology's `Plan`: praxeology.lisp types it, the CL shell drives it
  and performs the IO. It emits `:workflow-start` / `:workflow-step` / `:workflow-end`.

The distinction that matters: **delegation is the model's choice; a workflow is your
deterministic plan.** Both are network-free tested with scripted providers — delegation
through the loop, plus sequential threading and parallel fan-out+gather.

Next: real concurrency for `parallel` (bordeaux-threads — the isolation contract is already
the promise, so it's a drop-in); a blackboard backed by **Kairos** for budgeted shared
context; studio visualization of a running workflow (the `:workflow-*` events are already
the substrate); and typed `Plan` construction from Coalton feeding `run-workflow`.

#### Agent memory — "observational memory"

Memory that accrues from what the agent *observes* across turns and sessions, not just the
verbatim transcript: salient facts, corrections, learned preferences, distilled from the
conversation and recalled when relevant.

- **Where:** a `memory` module reading and writing **Kairos**. An observation is a context
  item with a role/value and bitemporal stamps; a recall is a budgeted `assemble` filtered
  to memory items.
- **The Praxeon framing:** observation → imputed value → retained means/ends. It is the
  *same economizing model* as context assembly, extended across sessions — which is exactly
  why it doesn't need a new subsystem, only a new use of the one being built.
- **First step:** a `remember`/`recall` pair over the existing context structs, then a
  distillation pass (an LLM call turning a transcript window into a few high-value
  observations).

#### "Studio" developer experience

Mastra's studio is a local **web app**: build and inspect agents, configure memory stores,
visualize workflows, plus a REST interface to call agents and workflows.

Praxeon's counter-position is that **the live image is already a studio** — so make it
legible first, and expose the same *data* a graphical studio would need so the two share one
substrate. Concretely that produced a deliberate **data/render split**: `agent-summary`
returns a plist (the structured hook a future web/REST studio renders), `describe-agent`
prints it. Everything in the studio is provider-neutral — it reads only messages, content
parts, tool specs and `model-of`, so no vendor coupling leaks in.

The same instinct governs live traces: the loop emits **plain-data events**, so the CLI
renderer and the web renderer are one line apart (`with-observer`), and a future graphical
studio renders the same stream. The intended endgame is *a view/controller onto the live
image*, not a separate runtime.

Next foundations: an animated (threaded) CLI spinner, a means catalog as data, per-session
agents, and a native SSE renderer for threaded backends.

#### Why the web layer polls instead of streaming SSE

The event contract is transport-neutral **by design**, so the studio *could* push over SSE.
It doesn't, and the reason is the default server, **Woo** — a single-threaded async (libev)
server that imposes two rules hit head-on while building the web surface:

1. **A handler must never block the event loop.** A blocking SSE drain inside a handler froze
   the *entire* server — every other request, including the page itself, timed out.
2. **A socket can only be written from its own event-loop thread.** Draining events on a
   background thread and writing to the Clack streaming writer blew up with
   `The value NIL is not of type SB-SYS:SYSTEM-AREA-POINTER`.

True SSE therefore needs a thread-per-connection server (Hunchentoot), or a Woo-specific
`ev_async` integration that would be fragile and non-portable — **defeating the "backend is
configurable" goal**, which outranks the transport upgrade. So the shipped design is: `POST
/api/message` echoes the user's bubble immediately and runs the turn on a **background
thread** (keeping the event loop free), while a poller hits `GET /api/progress` every ~700 ms
to append new bubbles and OOB-update the status line. Every handler stays quick, so it works
**identically on Woo and Hunchentoot with no per-server code.**

The upshot: **polling is the portable floor, not a ceiling.** Because the event data is
transport-neutral, a native SSE renderer can be added for threaded backends as a swappable
transport, without touching the agent loop or the event contract. Revisit when a
token-by-token streaming UX justifies the second code path — for a "… thinking / → tool"
indicator at human reading speed, 700 ms polling is indistinguishable.

#### Modular design

Keep the package-per-module boundary sharp so pieces compose and swap. Providers, means,
memory backends and context stores should each be a **small protocol** (a generic function or
Coalton class) with interchangeable implementations — the way `provider`/`complete` already
works. The first step is giving **means** and **memory** the treatment `provider` got: a
documented protocol plus a registry, so a third party can add one without editing the loop.

**MCP (Model Context Protocol) — planned, and it needs no new abstraction.** The means
registry is the natural seam for consuming external tool servers: an MCP client discovers a
server's tools and registers each as a Praxeon means (name + JSON schema + an effect that
RPCs the server) — after which any MCP server's tools are available to the Actor with **no
loop changes**, exactly as `register-means` gave us web search. MCP is the *transport*;
`register-means` stays the *abstraction*, so it is provider-neutral by construction. That the
web-search vendor already offers an MCP endpoint makes it the obvious first server to point
a client at.

#### Live-reload dev server — "Figwheel for Common Lisp"

Three layers, increasing in ambition and payoff:

1. **Watch → recompile → reload — shipped.** A background thread recompiles a changed file on
   save and, on a clean compile, rebuilds the server around the *persistent agent*, bumping a
   reload epoch that `:dev` pages poll to `location.reload()`. Today a zero-dep mtime poll;
   the planned upgrade is OS-native file-notify behind the same `watch` interface.
2. **Compile errors in the browser — shipped.** Captured compiler diagnostics (the real
   message, line, column) are served and shown as a red overlay, hidden again once the
   compile is clean. **The last good server keeps running underneath**, so you never lose the
   session while fixing a typo.
3. **Runtime conditions in the browser with restart selection — the flagship, unbuilt.** When
   a request or turn handler signals, don't drop to the REPL debugger: capture the condition
   *and its restarts*, render them in the browser, and let the user **pick a restart** to
   resume the very computation. The debugger, over the wire — no JS framework can do this.
   Mechanism: `handler-bind`/`restart-case` around the turn parks the background thread on a
   channel, the browser POSTs the chosen restart, `invoke-restart` resumes. It ties directly
   into Praxeon's *existing* recoverable-failure restarts — `retry`/`substitute`/`abandon`
   literally *become* the browser's choices. Best sequenced after the session model so
   overlays are scoped to a session; note the Woo caveat that parking must happen on the
   turn's background thread.

The crucial property throughout: **the agent lives in the builder's closure, outside the
server**, so rebuilding the server never touches the conversation. *State ≠ server.*

Worth noting why this is a differentiator and not a nicety: Figwheel-style hot source reload
*with state preserved* is essentially absent from the CL web world. 40ants **Reblocks** does
reactive server-side widgets over WebSocket — a different, heavyweight animal. A lightweight
"edit → recompile → browser refreshes, session intact" loop is genuinely novel here.

#### Markdown in the chat — and the security gotcha

Rendering replies (and user input) as Markdown is cheap and confirmed feasible with **3bmd**
(pure CL), injected via Spinneret's `(:raw …)` — the same path transcript rehydration uses.

The gotcha, verified rather than assumed: **3bmd passes raw HTML through by default**, so a
`<script>` in the input survives into the output. Harmless for a single-user local demo; a
**stored-XSS hole** the moment it is multi-user. Before that line is crossed: sanitize with
an allowlist or disable raw-HTML passthrough. The **user's input is the untrusted surface**;
the model's own replies are lower-risk but not zero (prompt-injected markup). Because
rehydration stores raw text, this is purely a render-time concern.

#### Chat UX — and the `--server` vs `--service` split

The first pass shipped: a full-height window, auto-scrolling transcript, fixed multiline
input (Enter sends, Shift+Enter for a newline). The interesting design question it raised is
**how much rendering lives in the app**.

The principle settled on: *app-specific customization is defined at the app level and passed
into the generic components* — never baked into the generic layer. The first concrete step
shipped is styling-by-parameter (`:theme-css` overrides the neutral bubble classes), so the
generic web layer stays app-agnostic and the demo agent's palette lives in its own file. The
open spectrum runs: **bundled page + theme/slot hooks** (today) → **app supplies templates,
the library supplies plumbing** (routes, turn loop, progress poller, fragment helpers) →
**headless, the app owns the whole view.** The expectation is to grow hooks/slots (header,
footer, bubble renderers) before going fully headless.

That spectrum has a CLI shape too: **`--server`** is the *bundled UI* (the whole window is
the chat; basic is fine), **`--service`** is *headless* — the agent exposed as an
API/protocol for an external front end. The REST endpoints already exist; `--service` merely
formalizes "Praxeon as the orchestrator behind someone else's UI."

Also captured: a dedicated, themeable chat *widget* in its own package that a host app drops
into a popup or side panel, the way traditional agent integrations embed — with the generic
web layer staying plumbing. And a sequencing preference: **push HTMX as far as it goes**
(OOB swaps, SSE on a threaded backend, richer fragments) before reaching for compile-to-JS.

#### Model routing — economic calculation over means

> *"The science of means must find the least expensive among viable alternatives and be able
> to quantify the savings of this choice over that, when the end is feasible at all."*

**Token-cost visibility is shipped** — the neutral `completion` carries usage from either
vendor's field names, the loop emits `:usage` events, and the header shows a cumulative
count. That is the prerequisite, stated plainly: *you cannot economize a resource you cannot
measure.*

What it unlocks, in order:

1. **Change the provider/model mid-conversation**, user-driven first — a UI control and a
   REST field to switch between turns. Because the history is provider-neutral, the next
   turn runs on a different model **with no state loss**. Provider neutrality is what makes
   this free.
2. **Then Praxeon-driven routing**: the agent picks the least-cost *viable* model per turn —
   a cheap model for easy turns, a frontier model for hard reasoning, a vision model when
   the input has images. **This is praxeology applied to the model itself, not just to
   tools**: economic calculation over means.

The design seam is small and legible: an agent holds *a* provider today; routing generalizes
that to "select a provider per turn" — a policy over a provider registry. The per-agent
**role** resolution already shipped (`PRAXEON_<ROLE>_*`) is the same seam viewed statically.

#### The Hyperion spin-out

Typed HTMX began life as a praxeon roadmap thread — the web layer used HTMX through
stringly-typed Spinneret attributes, one typo from silent breakage, with nothing checking
that a combination was valid. That is precisely the error class Coalton's type checker should
own.

In 2026-07 it was **spun out into its own framework**, Hyperion, sitting immediately left of
praxeon in the DAG. `praxeon/web`'s generic engine — configurable server, hot-reload watcher,
request utils, theme hook — was extracted, and `praxeon/web` now depends on Hyperion and
keeps only agent/chat domain glue. Every export was preserved and the demo agent was
unchanged by the move.

The lesson worth keeping: the *domain* framework should shed anything generic, and the DAG is
the tool that forces the question. See [Hyperion](Framework-Hyperion.md) for the typed-HTMX
design in its new home.

#### i18n orchestration — the AI half

Localization is split across two frameworks by DAG position. Hyperion owns the **LLM-free
extractor** (template → base dictionary + rewritten template). Praxeon owns the
**orchestration**: optionally have an LLM suggest *semantic* key names, then batch
`translate-dictionary(en.json, locales)` over the existing provider-neutral
`praxeon/translate` — turning a template into a fully translated i18n directory. Only praxeon
can compose these, because only praxeon may reach both an LLM and the web framework. This is
high value to a consuming app with a multilingual CMS/CRM mandate: a user localizes a page
into as many languages as they want, AI in the loop.

The same machinery already runs live in the demo agent: it localizes its chrome *and*
converses in the selected locale via a **translator agent** — your message rendered into
English for the main agent, its reply rendered back into your language. The main agent always
deliberates in English, so its history and its (English) safety cues stay in one language,
and localized resources are appended in yours. The translator is its own agent with its own
model, so a fast multilingual model translates while a stronger model thinks.

### 6. LLM-consumability of the code and docs

> *"I want the code and documentation to be easier for LLMs to consume, so they can generate
> high-quality code from the core."*

Praxeon is a framework whose users *writing against it* will often be LLMs, so that reader is
optimized for explicitly:

- **One vocabulary, everywhere.** The praxeology terms already do this; enforce it in names,
  docstrings and skills so a model sees the same word for the same concept in the API, the
  tests, and the prose.
- **Docstrings state the contract, not just intent** — argument shapes, return type, and
  which conditions/restarts are in play. The provider protocol and `register-means` are the
  template.
- **Executable examples are the best spec.** The `scripted`-provider tests double as "here is
  how you implement a provider" and "here is how the loop behaves" — an LLM can pattern-match
  from them. One canonical example per extension point (provider, means, memory).
- **Skills are the generation surface.** The `.claude/skills/*` how-tos (add-means,
  coalton-conventions, repl-workflow) are the LLM-facing layer; when an API changes, the skill
  changes **in the same commit.**

The cheap, compounding first step is a short statement of the invariants a code generator must
respect: the provider-neutral rule, the condition/restart protocol, and the Coalton-vs-CL
boundary.

### Tooling & distribution — deferred, with reasons

Dependency management stays on **Quicklisp** for now. **ocicl** (OCI-registry, lockfile-pinned
deps) is attractive for reproducibility — exactly the version-drift bug class already hit —
but is **deferred**: the full dependency scope isn't known yet, and ocicl's coverage of what
will be pulled in (and of bleeding-edge Coalton) is unverified. Revisit before the dep set
grows large. Publishing to Quicklisp and/or an ocicl registry is a separable, additive step.

One hard-won environment gotcha belongs with it: an `fset` / `named-readtables`
incompatibility from the **Ultralisp** dist on very new SBCL breaks loading outright. The fix
is to disable Ultralisp, update the Quicklisp dist, and clear stale fasls.

### Sequencing rationale

The recorded order is not arbitrary: close out tool-use follow-ups first (small, tidies the
current work); then **LLM-consumability** (cheap and compounding — every later thread is
easier to build and to generate against once conventions are written down); then **Kairos**
before **observational memory** (memory needs the store); the **Coalton core** and **LLM
hardening** are independent and can go in either order; the **studio and modularity** grow
naturally as there is more to inspect and more implementations to swap.

The stated headline want is **Kairos + observational memory with semantic recall** — the
foundation for agents that remember.

---

## Usage

Build the tree once from the monorepo root, then talk to the demo agent.

```sh
git clone https://github.com/codelisperer/ouranos.git
cd ouranos
sbcl --dynamic-space-size 4096 --script bootstrap.lisp   # → bin/cons + ASDF (:tree) drop-in
cp praxeon/.env.example praxeon/.env                     # add a provider key
```

```lisp
(ql:quickload :praxeon/elise)   ; first load compiles Coalton (~minutes; cached after)
(praxeon/elise:start)           ; interactive CLI session
```

A minimal `.env` — note that per-agent **roles** override the shared default:

```sh
PRAXEON_LLM_IMPL=anthropic
PRAXEON_LLM_MODEL=claude-sonnet-5                  # shared default (any role)
PRAXEON_ELISE_MODEL=claude-opus-4-8                # the deliberating agent
PRAXEON_TRANSLATE_MODEL=claude-haiku-4-5-20251001  # the translator agent
```

**In the browser, with hot reload** — the conversation survives every edit:

```lisp
(praxeon/elise:dev)     ; persistent agent + watcher; http://127.0.0.1:8080
;; edit a source file, save, keep chatting
(praxeon/web:unwatch)   ; stops watcher and server
```

**Inspect the live image** (the studio is on-demand, all provider-neutral):

```lisp
(defparameter *e* (praxeon/elise:make-elise))
(praxeon/studio:describe-agent *e*)        ; provider, model, budget, means
(praxeon/actor:run-turn *e* "add 2 and 3")
(praxeon/studio:trace-turn *e* "…")        ; deliberate → act → result → answer
(praxeon/studio:show-transcript *e*)
```

**Coordinate several agents** — delegation (the model decides) and workflows (you decide):

```lisp
(actor:register-agent-as-means coordinator translator)   ; model-driven delegation

(defvar *flow*
  (wf:make-workflow :report "Produce a report"
    (wf:step :research researcher "find sources on X")
    (wf:parallel                                   ; fan-out: independent, isolated
      (wf:step :pro pro "argue for")
      (wf:step :con con "argue against"))
    (wf:step :write writer
      (lambda (bb) (format nil "Write using: ~A / ~A"
                           (wf:bb-result bb :pro) (wf:bb-result bb :con))))))

(wf:bb-final (wf:run-workflow *flow*))
```

**Live progress** — the same neutral event stream the web UI renders:

```lisp
(praxeon/event:with-observer ((praxeon/studio:status-observer))
  (praxeon/actor:run-turn *e* "add 2 and 3"))
;;   … thinking
;;   → add(a=2, b=3)
;;   ← 5
```

Full setup, provider configuration, editor-connected REPLs and troubleshooting are in the
in-repo [user guide](https://github.com/codelisperer/ouranos/blob/main/praxeon/docs/user-guide.md).

---

## Roadmap

Actionable work lives in GitHub issues and the project board, not in this page.

- **Board:** https://github.com/orgs/codelisperer/projects/1
- **Open Praxeon issues:** https://github.com/codelisperer/ouranos/issues?q=is%3Aissue+is%3Aopen+label%3A%22pkg%3Apraxeon%22
- **Related:** [Hyperion](Framework-Hyperion.md) (the web surface praxeon runs on), and the
  ecosystem-wide decisions log in
  [`ECOSYSTEM.md`](https://github.com/codelisperer/ouranos/blob/main/ECOSYSTEM.md).
