# Praxeon against Mastra and DeepAgents

*A working comparison, 2026-08-23. Written to do two jobs: find the gaps worth closing
before publication, and find the claims worth making. Praxeon's column is taken from the
code, not the README — where something exists but has no consumer, it says so, because an
unused subsystem is an unvalidated one.*

The two references: **[Mastra](https://github.com/mastra-ai/mastra)** (TypeScript, agents +
graph workflows, production tooling) and **[DeepAgents](https://github.com/langchain-ai/deepagents)**
(Python, opinionated middleware over LangGraph, aimed at long-horizon work).

---

## The table

| | Praxeon | Mastra | DeepAgents |
|---|---|---|---|
| **Agent loop** | `run-turn` — deliberate/act until no tool call, `max-steps 8` | agents reason and iterate internally | ReAct plus planning |
| **Planning** | `Plan` is a **Coalton type the runtime never constructs** | graph workflows: `.then() .branch() .parallel()` | first-class, for long-horizon work |
| **Sub-agents** | `register-agent-as-means` — own model, history, means **and context**. Unit-tested; **no application uses it.** | agent networks | isolated context windows (headline feature) |
| **Explicit workflows** | `praxeon/workflow` — workflow/step/parallel over a blackboard. Unit-tested; **no application uses it.** | the core abstraction | — |
| **Failure / approval** | **condition-system restarts**: `retry-action`, `substitute-result`, `abandon-action` | suspend/resume with persisted state | HITL approval hooks |
| **Context economy** | `praxeon/context`, budgeted, bitemporal | context management + Observational Memory | summarise threads, **offload tool outputs to disk** |
| **Memory** | — (pre-publication issue 60 open, Kairos #60 unbuilt) | Observational Memory | persistent, pluggable backends |
| **Provider neutrality** | `complete` generic; anthropic + openai-compatible | model routing, 40+ providers | LangChain's model layer |
| **Tools** | `Means`, provider-neutral `tool-spec` | `createTool()` with schemas | tools + a **Skills** system |
| **MCP** | — (#64) | authors MCP servers | consumes MCP tools |
| **Filesystem for agents** | — | — | pluggable local/sandboxed/remote |
| **Evals** | **—** | built in | — |
| **Observability** | `aion/log` structured fields only | tracing/metrics as a product surface | LangSmith-adjacent |
| **Cost / rate / auth ceiling** | **per-session cost + call cap, Ed25519-signed grants, metering** (pre-publication issue 172), **capability-scoped tool assembly** (#90); rate limiting still open, and each agent has to opt in to the injection mitigation | — | — |
| **Streaming to the browser** | polling; SSE blocked on pre-publication issue 117 M2 | streaming | streaming |
| **Typed core** | **Coalton, Hindley–Milner** | TypeScript types | Python type hints |
| **Ships with a web framework** | **hyperion** | bring Next.js/React | bring your own |
| **Ships with a data layer** | **mnemosyne** | — | — |
| **Ships with integrations** | **hermes** (email/SMS, blob) | — | — |
| **Live redefinition** | **the image — redefine an agent mid-session** | restart the process | restart the process |

---

## Weaknesses, in the order I would fix them

**1. Cost ceiling: done. Capability-scoped tools: done (#90). Rate limiting: not
(pre-publication issue 172).** This was the only *blocker* on the list, and the expensive half
of it now exists — a per-session token and call cap carried in an Ed25519-signed grant the
application mints, enforced as an **enter stage** so a refusal happens *before* the model call
rather than being discovered after paying for it, with usage metered per model per *(user,
group)* and returned in-band so the agent needs no database credential.

Two things are deliberately still missing, and the honest thing is to keep naming them:

- **Rate limiting** beyond a per-session call cap. A caller can still be refused a session
  and immediately obtain another, because stopping *that* is the minting decision, which
  belongs to the application.
- **A prompt-injection posture, fully adopted.** Any public agent reads untrusted text. The
  load-bearing mitigation is #90's property — tools assembled *from* the viewer's
  capabilities, so a tool they may not use is absent from the table rather than filtered by
  prompt — and that mechanism is built: `register-means` takes a `:capability`,
  `means-permitted-p` fails closed, and `agent-means-for` assembles the table from the
  caller's permit. What remains is adoption: a means registered without a capability is
  unrestricted, and a caller that passes no permit gets every unrestricted means, which is
  every means that existed before capabilities did. That default is deliberate — it is what
  kept existing agents working — but it means an agent is protected only once its means carry
  capabilities **and its callers carry permits**.

  **That last clause was not achievable until pre-publication issue 400, and the correction is worth keeping rather
  than smoothing over.** An earlier version of this bullet said the remaining work was
  *adoption*, which presumed a caller could carry a permit. Through `run-turn` — the path every
  reader uses — it could not: the turn loop took no `:permit` and passed none to `deliberate` or
  `act`, so a capability-bearing means was invisible to the model and refused if named. So the
  gap was **reachability**, not uptake, and it was invisible to a reader of `run-turn` or
  `register-means` alone. `run-turn`, `run-turn-through` and delegated sub-agents now carry a
  permit (pre-publication issue 400, ADR-0002 §"One thing did need building"), which makes the clause true and leaves
  the genuine remainder: each agent still has to choose to use it.

So: praxeon can now be given a hard, legible spend ceiling, and the tool-assembly mitigation
exists for an agent that opts into it. An agent that has not yet registered its means with
capabilities **still should not be pointed at the open internet**. Neither reference solves
that either — but neither is about to be deployed as a public endpoint billed to one personal
API key.

**2. No evals.** The hardest gap to defend rhetorically. Praxeon's own README claims
*industrial-strength agentic systems*; Mastra ships evaluation as a first-class surface and
DeepAgents inherits LangSmith's. A framework that cannot answer *did this change make the
agent better?* is asking to be taken on faith — which is exactly the objection a sceptical
reader brings to a Lisp framework. **This is the credibility gap, not a feature gap.**

**3. Two subsystems no application uses.** `praxeon/workflow` and `register-agent-as-means`
are both implemented and both have network-free unit tests. Neither is called by Elise,
ChatRBT, or anything else in the tree — `chat-rbt.lisp` names both in a header comment
describing what it *would* do. A green unit test proves the function does what its author
expected; it does not prove the design survives a real workload, and every framework defect
this project has found came from something real trying to use the code (pre-publication issue 134, pre-publication issue 136, pre-publication issue 143,
pre-publication issue 146, pre-publication issue 165 …). Shipping an unexercised subsystem as a headline is how a framework loses trust
on first contact. **#100 would be the first application consumer of both.**

**4. `Plan` is a type the loop ignores.** Praxeon *named* long-horizon planning in its
ontology and then built only step-by-step improvisation. Deliberate-once-then-execute is a
different control flow from ReAct, not a refinement of it, and DeepAgents targets exactly the
case praxeon left empty.

**5. No MCP (#64).** Rapidly becoming table stakes; both references have it in some form.
Being provider-neutral and *protocol*-absent is an odd combination to defend.

**6. Context offload.** The most on-thesis idea in DeepAgents, and praxeon has the disk for
it (`hermes/blob`). See the DAG note below — the obvious implementation is illegal.

**7. Streaming.** Polling is a deliberate, documented choice made because Woo's event loop
could not be blocked; it becomes a limitation rather than a decision once pre-publication issue 117 lands.

---

## Strengths worth leading with

These are not "us too" items. They are things neither reference has, and two of them are
things neither reference *can* have.

**The condition system is a better approval primitive than either alternative.** Mastra
suspends a workflow and persists state; DeepAgents offers approval hooks. Praxeon establishes
`retry-action` / `substitute-result` / `abandon-action` restarts around every application of a
means — an approval point with three named outcomes, composable with the debugger, and
available to any caller up the stack without the agent knowing it exists. *The framework whose
approval mechanism is the language's own error protocol* is a sharper claim than "we support
human-in-the-loop", and it is true.

**A typed ontology, not typed plumbing.** TypeScript and Python hints type the *API*. Coalton
types the *model* — `End`, `Means`, `Action`, `Plan`, `Actor` are Hindley–Milner types, so a
malformed agent configuration is a compile-time error rather than a runtime surprise.

**Live redefinition.** Redefining an agent's behaviour inside a running session, against
preserved state, is not a workflow either reference can offer, because both restart a process
to pick up a change. This is the demo that makes the Lisp argument without an argument.

**One stack, not an assembly.** Praxeon arrives with a web framework, a data layer, external
integrations and a project tool that were designed together. Mastra expects Next.js and a
database of your choosing; DeepAgents expects LangGraph and the Python ecosystem. For a solo
developer this is the difference between a weekend and a quarter — and it is measurable, which
matters more than it sounds.

**The thesis is a thesis.** *Python won AI as glue over C++/CUDA kernels; the winnable ground
is the CPU-bound orchestration layer, where macros, the condition system and a live image are
decisive.* Neither reference makes an argument at all — they publish feature lists. A framework
with a position is easier to disagree with and much easier to remember.

---

## The DAG constraint that shapes three of these

Praxeon is **inside** the dependency line; `hermes` is a satellite that nothing in the line may
depend on. So context offload (to `hermes/blob`), any email an agent sends, and any blob an
agent writes must reach praxeon as an **injected seam** the application fills — never a direct
dependency. This is the same inversion #104 must avoid for magic-link delivery. It is now the
third place the obvious implementation is the wrong one, which is enough repetitions to be
worth stating once, here.

---

## For publication

Do not claim parity. The honest framing is narrower and stronger:

> Praxeon is not trying to be Mastra in Lisp. It is a bet that the orchestration layer — not
> the tensor path — is where the host language still matters, and that a typed core, a real
> condition system and a live image are worth more there than a larger feature list.

Then be explicit about what is missing. **A comparison table that admits the gaps is more
persuasive than one that hides them**, particularly to the reader who will go and check.
