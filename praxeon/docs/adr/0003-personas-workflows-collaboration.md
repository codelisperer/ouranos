# ADR-0003 — Praxeon provides personas, workflows and agent collaboration as framework protocols, in that order

**Status:** Proposed *(2026-10-01)*
**Date:** 2026-10-01
**Issue:** [#497](https://github.com/codelisperer/ouranos/issues/497), the design thread, with
requirement notes from three apps. Builds on
[#148](https://github.com/codelisperer/ouranos/issues/148),
[#289](https://github.com/codelisperer/ouranos/issues/289),
[#62](https://github.com/codelisperer/ouranos/issues/62),
[#161](https://github.com/codelisperer/ouranos/issues/161),
[#68](https://github.com/codelisperer/ouranos/issues/68),
[#425](https://github.com/codelisperer/ouranos/issues/425) and
[#100](https://github.com/codelisperer/ouranos/issues/100).

## Context

Three apps need agent personas, and one of them also needs workflows in which agents, tools and
people take turns: a desktop writing app, a document-automation desktop app for solo
practitioners, and a web app. Two of them already keep persona definitions in their own code, and
that code is growing into what a framework should provide. The third is waiting for workflows. On
2026-10-01 the maintainer set personas and agents collaborating in workflows as praxeon's
differentiator.

What praxeon has today, surveyed on `main` at 51c1c32:

- **No persona type.** The `agent` struct (`praxeon/actor`) holds a name, a provider, one
  system-prompt string, a table of means and an in-memory history, and an app builds it in code.
- **One system prompt per agent.** The provider layer already accepts a list of system parts: the
  Anthropic backend sends them as blocks, and the OpenAI-compatible backend joins their text with
  no separator.
- **Tools are means registered on each agent**, each with an optional capability, and
  `means-permitted-p` refuses a capability the caller's permit lacks. Workflow steps, praxeon/web's
  responder and the Elise example pass no permit, so no capability-bearing means can run there.
  A tool result is a string with no label.
- **An app can already pass a provider with its own key, but nothing chooses the provider and key
  for a persona or a user.** `make-agent` takes a `:provider`, and the exported `anthropic` and
  `openai-compatible` classes take an `:api-key`, which wins over the environment when given, NIL
  included. `make-provider-from-env` builds a provider from environment variables, for development
  and examples. What is missing is a hook through which praxeon asks the app which provider and key
  to use for a given persona, user and context. Praxeon does not read keys from
  `hades/credentials`.
- **praxeon/ceiling** has grants, a per-session ledger, `budget-guard` and `meter`, and nothing
  outside its tests calls them (#161).
- **praxeon/workflow** runs fixed steps and parallel groups over an in-memory blackboard of strings,
  with no branches, no persistence, and no permit, budget or model per step.
- **No hook runs before a means to ask a person for approval**, and nothing can suspend a run and
  resume it later.

## Decision

**1. Praxeon owns three protocols, personas, workflows and collaboration, and each app supplies
storage and UI through them.** Each protocol gets its own ADR before it is built, and they are built
in this order:

1. **Personas** ([ADR-0004](0004-persona-protocol.md)). Two apps can use it as soon as it lands.
2. **Workflows** (ADR-0005, to be written when this stage starts). Its input is the
   document-automation app's note on #497: steps that are AI, tool or human; a GATE step kind for
   human approval, with a contract for what the reviewer sees; resumable state that can wait days
   for a person; and a run that pins the version of its definition.
3. **Collaboration** (ADR-0006, likewise). One persona asks another as a bounded sub-turn with its
   own model, tools and spend; a hand-off that says what context is passed, summarised or
   withheld; and a shared workspace in which every write is attributed.

**2. Five rules hold across all three, and each protocol's ADR must keep them.**

- **The app resolves keys, and they are passed explicitly.** Praxeon calls a provider-resolution
  hook that the app supplies. The hook decides between a user's own key and a platform key, and the
  key it returns is passed to the provider explicitly, NIL included, so an environment variable
  never silently wins inside an app. Environment variables remain for development and examples.
- **Data rules are set per step, and a tool result can carry a sensitivity label.** A means may
  label its result (for example, "contains a client's values" or "counts only") and may return an
  opaque record handle instead of values. A provider policy, either local only or hosted with
  consent, decides which labelled results a provider may see. Consent is recorded per run and per
  provider.
- **Every model call is metered.** Persona turns and workflow steps run through the ceiling's stages
  (#161). Reaching a cap stops the run and asks, through a restart, instead of failing it.
- **Local first.** Every store a protocol defines has a SQLite implementation and works with no
  service running (#425). Nothing leaves the machine unless a step's policy allows it and the user
  has consented.
- **Records and logs hold ids, counts and kinds, never values**, as `aion/log` already requires. An
  audit records who approved what and when, under which definition version, with which model and
  provider.

**3. Instructions are composed in layers, and an app's rules come first and cannot be removed by a
persona.** An agent's system prompt becomes a list of parts: the app's rules brief, then the
persona's own brief. The OpenAI-compatible backend separates the parts with a blank line instead of
joining them with nothing.

## Consequences

- The `agent` struct stays the object a turn runs on. A persona is the stored definition an agent is
  built from, so code that builds agents directly keeps working.
- Three existing gaps become part of this work: a provider-resolution hook, the ceiling's wiring
  into turns and steps (#161), and a permit on every path that runs a turn.
- Each app keeps its persona code in shapes that lift out, and moves to praxeon's version as each
  stage lands.
- The apps raised four questions that none of them owns: conflicting edits between peers, moving
  runs or templates between machines, reviewer roles beyond a single person, and regulatory
  retention periods. They stay open here; ADR-0005 and ADR-0006 say which they settle.

## Alternatives considered

- **One ADR for all three protocols.** Rejected: praxeon's ADRs record one decision per file, and
  deciding the workflow and collaboration designs now would decide them before the persona stage has
  shown what the runtime needs.
- **Leave personas and workflows to each app.** The present state. Rejected: two apps are already
  writing the same code, and the third cannot start without workflows.
- **Adopt another framework's model wholesale**, for example Mastra's workflows. Rejected: praxeon
  exists to provide this in Common Lisp under the rules above (explicit keys, local first, labelled
  data), which those frameworks do not hold as defaults. #62 records what is worth borrowing.

## Provenance

Drafted by the hub on 2026-10-01 at the maintainer's request, from the three requirement notes on
#497 and a survey of `main` at 51c1c32, which is where every statement under Context comes from. The
maintainer confirmed the direction and the order of the three stages before drafting began.

Revised on 2026-10-03 after the review on #503. The Context said there was no way for an app to
supply a key. At 51c1c32, as now, `make-agent` takes a provider and both provider classes take an
`:api-key`, so the statement now says that what is missing is choosing the provider and key for a
persona and a user.
