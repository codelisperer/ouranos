# ADR-0004 — A persona is a versioned definition that an agent is built from, with the app's rules composed in front

**Status:** Proposed *(2026-10-01)*
**Date:** 2026-10-01
**Issue:** [#497](https://github.com/codelisperer/ouranos/issues/497) (the notes from a desktop
writing app and a web app) and [#148](https://github.com/codelisperer/ouranos/issues/148). Stage one
of [ADR-0003](0003-personas-workflows-collaboration.md).

## Context

Two apps keep persona definitions today, and both need the same things (#497):

- A persona is data: a name, title, summary and accent, with per-locale names and summaries;
  visibility, either shown to users or used only by operators; a pinned vendor and model, or else
  the user's choice, or else a platform default; the tools it may use; and the reference corpora it
  may search, gated by persona, group and the user's tier.
- Definitions are edited, and an edit can be reverted to the definition the app shipped.
- One rules brief applies to every persona in an app, including personas users write themselves, and
  no persona can remove it. The desktop app's rules include never drafting the user's prose and
  staying silent during a timed freewrite.
- The desktop app ships its personas as text files, a `key: value` header followed by the brief,
  read from source in development and embedded at build, and lets users rename, tailor or write
  their own.
- A persona is chosen per project, then by the user's default, then by a built-in default, and a
  single call can override that.
- Keys come from the OS credential store on the desktop and from encrypted per-user records on the
  web. Users bring their own model, and a saved key must win over an environment variable.

Praxeon has none of this. Its `agent` is built in code with one system-prompt string. An app can
pass a provider with an explicit key, but nothing chooses the provider and key for a persona and a
user (ADR-0003, Context).

## Decision

### The persona record

A new system, `praxeon/persona`, defines `persona` with:

- `id`, a stable string; `version`, a hash of the definition's content; and `origin`, one of:
  - `:shipped`, a definition the app ships as a file;
  - `:edited`, a local copy of a shipped definition, which also records `base-version`, the
    version of the shipped definition it was copied from;
  - `:authored`, a definition written locally from scratch, by a user or an operator, with no
    shipped definition behind it.
- Display fields: `name`, `title`, `summary` and `accent`, each with per-locale values.
- `visibility`: `:user` or `:operator`.
- `model`: NIL, meaning the user's choice and then the platform default, or a pinned vendor and
  model.
- `means`: the names of the means it may use. `corpora`: the corpora it may search. Both are
  allowlists. The app decides which means and corpora exist, and a persona can only narrow them.
- `brief`: its instructions, as text.

`validate-persona` checks a definition and returns its problems as data. Loading a definition that
fails validation signals an error naming the field.

### Shipped and local definitions

- **A shipped definition is a text file:** a `key: value` header, a blank line, and the brief.
  `load-persona-file` reads one. An app reads its files from source in development and embeds them
  at build.
- **A local definition, edited or authored, is stored through a `persona-store` protocol** that the
  app implements: `persona-get`, `persona-put`, `persona-list` and `persona-delete`. Praxeon
  provides an in-memory store and a SQLite and Postgres one in `praxeon/persona-db`.
- **A version is a hash of the definition's content, taken over its text-file form**, for shipped
  and local definitions alike, so a local copy whose content matches the shipped file has the
  shipped file's version. A turn records the version it ran under (see "Records and logs" below).
- **An edited definition has the id of the shipped definition it was copied from, and is used in
  its place while it exists.** A persona id resolves to its edited definition when there is one, and
  otherwise to the shipped one.
  - `persona-diff` compares it with the definition the app ships now. It returns the differences
    field by field, and whether the shipped definition is still the one it was copied from, has
    changed since, or is no longer shipped. When it has changed, the app can show the diff; praxeon
    does not merge them.
  - `persona-revert` deletes the edited copy, so the shipped definition applies again.
  - If a later release stops shipping that id, the edited definition keeps working, and
    `persona-revert` signals an error, because there is nothing to go back to.
- **An authored definition gets an id that the store generates**, so it can never take the id of a
  shipped definition, in this release or a later one. It has no shipped definition to compare with
  or go back to: `persona-diff` and `persona-revert` signal an error naming its id, and the app
  removes it with `persona-delete`.

### The rules layer

An app supplies one rules brief for all of its personas. An agent built from a persona has a system
prompt made of parts: the rules brief first, then the persona's brief. A persona has no field that
could remove, reorder or override the rules part. Rules are also enforced structurally where that is
possible: the app can name means that no persona may be granted, for example any that write into the
user's document, and can attach a check that runs on every persona's replies, as a leave stage of
the turn.

### Choosing a persona

`select-persona` takes an ordered list of scopes that the app supplies, typically a per-call
override, then the project or context, then the user's default, then the built-in default. It
returns the first persona named that exists and that the caller may see.

### Building an agent, and the provider hook

`persona-agent` builds a praxeon `agent` from a persona, given the app's rules brief, a provider
resolver, the caller's permit, the caller's ledger, a provider policy and the turn's context. It
signals an error when the ledger or the provider policy is missing, or when the policy is `:hosted`
and the consent function is missing (see "How the rules in ADR-0003 apply" below).

- Its system prompt is composed as above.
- Its means are the app's registered means, narrowed to the persona's allowlist and with the rules'
  exclusions removed.
- Its provider is what the app's resolver returns for that persona and context. The resolver
  returns a provider whose key is passed explicitly, NIL included, taken from the OS credential store
  on the desktop (`hades/credentials`) or from an encrypted per-user record on the web, in whatever
  order the app sets, normally the user's key first. On this path praxeon never reads a key from the
  environment.
- It carries the caller's permit, so capability-bearing means can run (ADR-0003, Consequences).
- It has stages of its own, which `run-turn` and `run-turn-through` apply outside any stages a
  caller passes, so they run on every path that runs the agent. They are the ceiling's stages
  (below) and the app's check on replies from the rules layer.
- It belongs to one caller, because the permit, the ledger and the consent answers are that
  caller's. An app builds one for each user session and does not share it between users.

### How the rules in ADR-0003 apply

ADR-0003 requires each protocol to keep five rules. `persona-agent` sets them on the agent it
builds, so they hold on every path that runs that agent: `run-turn`, `run-turn-through`, a workflow
step, or another agent calling it as a means. No rule depends on the caller remembering to apply
it.

1. **Keys.** The provider and its key come from the app's resolver, as above.
2. **Data rules.** The provider policy is `:local-only` or `:hosted`.
   - Under `:local-only`, the resolver must return a provider that runs on this machine, and
     `persona-agent` signals an error when it does not. A provider says whether it runs on this
     machine through a new generic function: `openai-compatible` does when its base URL is a
     loopback address, and `anthropic` never does. Every result goes to that provider.
   - Under `:hosted`, the app also supplies a consent function, which answers whether the user has
     consented to a given provider seeing results with a given label. Unlabelled results are sent.
   - A means labels its result by returning the label as a second value. A means that returns one
     value, as every means does today, gives an unlabelled result.
   - Each time the agent sends the conversation to its provider, it checks every labelled result in
     it against the policy for that provider. A result the policy does not allow is replaced, in
     that request only, by a note that the tool ran and its output was withheld under the app's
     data policy, and the agent emits an event naming the means, the label and the provider. The
     history keeps the result itself.
   - A result kept outside the conversation (#319) keeps its label when the model reads it back.
   - The app asks the user for consent and records it, per run and per provider, as ADR-0003
     requires. Praxeon only calls the consent function.
3. **Metering.** The agent's own stages include the ceiling's `budget-guard` on the way in and
   `meter` on the way out, both for the caller's ledger, so a turn of this agent cannot run without
   them. `meter` charges the tokens of every model call in the turn, with the four counts the
   `:usage` event carries (#179). Reaching the cap signals a condition with restarts, as ADR-0003's
   metering rule requires. Today `budget-guard` halts the turn instead, so implementing this
   protocol includes changing it. An app that wants no cap passes a ledger whose grant has a cap it
   will not reach, so usage is still recorded. For persona turns this answers the question #161
   leaves open: the framework wires the ceiling, not an example.
4. **Local first.** This protocol adds one store, `persona-store`. Its in-memory and SQLite
   implementations need no running service.
5. **Records and logs.** The agent's events carry the persona's id and version, the model and the
   provider, so an app can record which definition, model and provider produced a reply. Logs from
   the persona path carry ids, counts and durations, never a brief, a message or a tool result.

## Consequences

- Two new systems, `praxeon/persona` and `praxeon/persona-db`, with no new external dependency.
- An agent's system prompt can be a list of parts. A string still works and counts as one part.
- The OpenAI-compatible backend separates system parts with a blank line.
- `agent` gains a list of stages of its own, applied on every path that runs it, and a means can
  label its result with a second value. Code that builds agents directly, and means that return one
  value, are unaffected.
- The ceiling's stages get their first caller outside their own tests (#161), and `budget-guard`
  signals with restarts at the cap instead of halting the turn.
- A persona agent belongs to one user session.
- Apps move over in steps: wrap their current definitions as personas, move storage to a
  `persona-store`, then build agents with `persona-agent`.
- Not decided here: a routing table that maps kinds of request to models (#68), beyond a pinned
  model; collaboration between personas (ADR-0006); and memory per persona. Memory stays keyed by
  subject, so personas share a subject's memory, as today.

## Alternatives considered

- **A persona as a subclass of `agent`.** Rejected: a definition has to be stored, versioned and
  compared with no provider or history attached. The agent is what a turn runs, built from the
  definition.
- **The rules as a field of each persona.** Rejected: a user-written persona could then remove them,
  and the desktop app's requirement is that no persona can.
- **Merging a changed shipped definition into a local edit automatically.** Rejected: the apps ask
  for revert, not merge, and there is no correct merge of two sets of instructions that a framework
  could choose for them.
- **Keys from the environment by default inside apps.** Rejected: an unrelated variable could then
  silently win over a user's own key (#497).
- **Metering and the data check as stages that each caller adds.** Rejected: a caller that leaves
  them out runs the agent unmetered and unchecked, which is the state #161 describes.
- **Checking a labelled result once, when it is added to the conversation.** Rejected: the
  conversation is sent again on later turns, possibly to another provider after the user changes
  model, and the user's consent can change in between.
- **A persona written from scratch as an edit of an empty shipped definition.** Rejected: it would
  make `persona-revert` empty the persona, and a later release could ship a definition under the
  same id.

## Provenance

Drafted by the hub on 2026-10-01 from the notes of two apps on #497, one desktop and one web, after
the survey cited in ADR-0003. The text-file format comes from the desktop app's shipped personas,
and versioning with revert from the web app's administration console.

Revised on 2026-10-03 after the review on #503, which found three gaps. A persona written from
scratch had no representation, because every local definition needed a shipped base; this revision
adds the `:edited` and `:authored` origins. `persona-agent` left metering and the data rules to
whoever ran the agent; the section on ADR-0003's rules now sets them on the agent. The Context said
an app could not supply a key, when it can pass a provider with one; it now says what is missing.
