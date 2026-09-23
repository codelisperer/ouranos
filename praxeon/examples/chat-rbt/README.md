# ChatRBT — Elenchon's motivating example (hosted in Praxeon)

**Conversational Requirements-Based Testing.** A user states functional
requirements in plain English; ChatRBT converses to disambiguate them, reframes
each as a **Cause-Effect Graph** (via Elenchon), and runs the CEG to generate the
minimal set of **functional test cases**. It is Elenchon's PoC — the same role
Elise plays for Praxeon.

> **Where it lives.** ChatRBT is an *agentic app*, so it sits in Praxeon beside
> Elise and depends on **both praxeon and elenchon**. Keeping it here means the
> dependency flows one way (example → frameworks); Elenchon's repo never pulls
> praxeon/hyperion, so there's no circular dependency.

> **Status: placeholder.** Elenchon's CEG core and solver don't exist yet (v0.0.0).
> ChatRBT is scaffolded *first, on purpose*: a motivating example is the forcing
> function that drives the framework (the same pull-model that drove Hyperion from
> a consuming app's landing page). It loads and reports its version; `start` signals the
> pipeline is pending.

## What it does (target)

1. **Converse & disambiguate** — a Praxeon actor elicits and clarifies each
   functional requirement (ambiguity handled as a recoverable failure, per
   Elenchon's method).
2. **Reframe as a CEG** — turn each requirement into a typed Cause-Effect Graph
   (causes/effects + `E`/`I`/`O`/`R`/`M` constraints).
3. **Run the CEG** — solve for the minimal, high-coverage decision table and emit
   functional test cases with traceability.

## The UX pattern: a popup agent over an artifact app

The chat is **not** the app — it's a **popup** over the real surface. ChatRBT's
surface is a **project view** that collates the structured artifacts as they're
produced during the conversation: each captured requirement (structured), its CEG,
and its generated test cases, accumulating into a browsable project.

This is a **shared ecosystem pattern** (see the sibling PoC, Elise):

| | ChatRBT | Elise |
|---|---|---|
| **App surface** | project view of requirements → CEGs → test cases | clinical note-taking |
| **Foreground agent** | requirements analyst (converses) | the reflective companion |
| **Background "capture" agent** | structures each requirement + collates CEGs | a **Scribe**: key points + possible diagnoses (**not** shown in chat) |
| **Persisted** | the artifacts (structured), per project | transcript in English **and** the user's language + the Scribe's notes |

**The key realization:** that background "capture" agent is exactly the
**multi-agent coordination** now in Praxeon — a second agent, coordinated with the
conversational one (`praxeon/actor:register-agent-as-means` or `praxeon/workflow`),
producing **structured artifacts alongside the chat** that the app surface renders.
ChatRBT's collator and Elise's Scribe are the same shape.

Two framework capabilities this pattern needs upstream:

- **Hyperion**: a generic, mountable **chat-popup component** that overlays an app
  surface (today `praxeon/web` renders a *full-page* chat) + an artifact/side-panel
  region the app owns. Generic component, never domain-specific.
- **A background/observer agent role** whose output is *structured data for the app*
  (not chat turns) — Praxeon coordination provides the wiring; the app defines the
  schema and the view.

## Open questions (clarify before building)

1. **Interaction granularity** — one requirement per turn (tight loop: state →
   CEG → cases → confirm), or free-form conversation with the capturer extracting
   requirements in the background? (Leaning: background extraction, with an explicit
   "formalize this" affordance.)
2. **Human-in-the-loop on the CEG** — does the user review/confirm the CEG before
   test generation (Elenchon's ambiguity review as a first-class step), or is it
   generate-then-inspect?
3. **Project persistence** — where do the artifacts live? This is `mnemosyne`'s
   job when it exists; until then, in-image + export (JSON/EDN)? What's the artifact
   schema (requirement, CEG, decision table, cases, traceability)?
4. **Test-case output format(s)** — human-readable, machine-readable, framework
   stubs (which)? Same question as Elenchon vision Q6.
5. **Popup vs full-page for v1** — build the popup component now (drives Hyperion),
   or start full-page like Elise and extract the popup later?
6. **Relationship to Elise's chrome** — Elise already has a localized web chat
   (`praxeon/web` + `hyperion/i18n`). Should ChatRBT share that chat surface (and
   the popup component be extracted from it), or start fresh?
7. **Multi-agent shape** — is the capturer a *delegated means* (the analyst calls
   it) or a *workflow step* (a deterministic "after each requirement, run the
   capturer") or an *observer* on the event stream? (Leaning: observer + workflow —
   deterministic capture, not model-discretion.)

## Run

```lisp
(ql:quickload :praxeon/chat-rbt)
(praxeon/chat-rbt:version)   ;; => "0.0.0"
(praxeon/chat-rbt:start)     ;; => signals "placeholder; pipeline pending"
```
