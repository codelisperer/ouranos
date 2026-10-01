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

Praxeon has none of this. Its `agent` is built in code with one system-prompt string, and an app
cannot supply keys through praxeon (ADR-0003, Context).

## Decision

### The persona record

A new system, `praxeon/persona`, defines `persona` with:

- `id`, a stable string; `version`, the version of its definition; `origin`, either `:shipped` or
  `:local`; and, for a local definition, `base-version`, the shipped version it was edited from.
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
- **A local definition is an edited copy**, stored through a `persona-store` protocol that the app
  implements: `persona-get`, `persona-put`, `persona-list` and `persona-delete`. Praxeon provides an
  in-memory store and a SQLite and Postgres one in `praxeon/persona-db`.
- **A shipped version is a hash of the file's content.** A local definition records the shipped
  version it was edited from. `persona-diff` compares a local definition with its shipped one, and
  `persona-revert` deletes the local copy so the shipped one applies again. When the app ships a
  changed definition under a local edit, the app can show the diff; praxeon does not merge them.

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
resolver, the caller's permit and the turn's context:

- Its system prompt is composed as above.
- Its means are the app's registered means, narrowed to the persona's allowlist and with the rules'
  exclusions removed.
- Its provider is what the app's resolver returns for that persona and context. The resolver
  returns a provider whose key is passed explicitly, NIL included, taken from the OS credential store
  on the desktop (`hades/credentials`) or from an encrypted per-user record on the web, in whatever
  order the app sets, normally the user's key first. On this path praxeon never reads a key from the
  environment.
- It carries the caller's permit, so capability-bearing means can run (ADR-0003, rule 2).

## Consequences

- Two new systems, `praxeon/persona` and `praxeon/persona-db`, with no new external dependency.
- An agent's system prompt can be a list of parts. A string still works and counts as one part.
- The OpenAI-compatible backend separates system parts with a blank line.
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

## Provenance

Drafted by the hub on 2026-10-01 from the notes of two apps on #497, one desktop and one web, after
the survey cited in ADR-0003. The text-file format comes from the desktop app's shipped personas,
and versioning with revert from the web app's administration console.
