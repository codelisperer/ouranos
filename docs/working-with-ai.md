# Working with an AI assistant on Ouranos

*Build with AI, for Humans — reviving the true Lisp tradition.*

`AGENTS.md` tells an assistant what conformant **code** looks like here. This document is for
the **human**: how to work with the assistant so it produces work worth keeping. It is
descriptive, not prescriptive — every practice below earned its place in a real session, and the
evidence is kept alongside it deliberately. Adopt what fits how you think.

It is also, for the maintainer, the **cross-machine memory**. A Claude session keeps private
notes under `~/.claude/`, but that directory is machine-local *and* its name is derived from the
checkout path, so it never crosses machines. Per the root `CLAUDE.md`: anything that must
survive a new machine goes in committed docs. This file is that promotion.

## The division of labour

The maintainer is an architect who spent years in the trenches and returned to hands-on work
without a team. The bottleneck is not the ability to write code — it is the distance between an
idea and a shipped thing. So:

- **The human** owns vision, architecture, and the code he cares about personally.
- **The assistant** carries the grind end to end: cross-platform plumbing, CI, per-OS
  packaging, provisioning, the tenth variation of a shell quoting bug.
- **Finishing beats presenting.** A plan handed back is often work handed back.

## Seven practices, and what each one bought

### 1. State the goal before the method

Say the *outcome*; let the assistant choose the mechanism.

> A session opened with "let's get CI building native desktop binaries." Several hours in, the
> human asked what problem was actually being solved. The real goal was **an app that updates
> itself** — CI was one link in that chain, and the work had been aimed one level too low.
> Ten seconds of typing redirected hours of effort.

### 2. Interrupt mid-work

Do not wait for a natural pause. Mid-turn corrections were the highest-leverage input in every
session that had them — "what problem are you solving right now?" is a complete and useful
message.

### 3. Turn hunches into measurements

An assistant's reasoning is fluent and sometimes confidently wrong. A number settles it.

> "Woo just *feels* like it should handle that better." That hunch forced a benchmark, which
> found that Hunchentoot took **44.00 ms** per request on a keep-alive connection where Woo took
> **0.15 ms** — and then that the same server with a `Content-Length` header took **0.17 ms**.
> The 44 ms was never the server: it was chunked encoding's terminating write sitting in Nagle's
> algorithm, i.e. **a bug in our own framework** on the main request path, affecting every
> Hyperion app on Windows. The hunch was wrong about the cause and completely right to insist on
> measuring. See [ADR-0011](../hyperion/docs/adr/0011-desktop-server-backend-and-content-length.md).

### 4. Ask for the strongest counterargument

The assistant will volunteer objections; *asking* makes it reliable rather than a matter of its
judgement about when to interject.

> Proposing our own event-loop server "around libev" drew the reply that libev on Windows wraps
> only `select()` with no IOCP — which is precisely why Woo is Unix-only, so the plan would have
> inherited the exact weakness it was meant to escape. The idea survived; the primitive changed
> to libuv.

### 5. Say "capture" or "act"

Ideas that arrive mid-flight are usually to be **filed**, not implemented. One word removes the
guess. Cross-session and AI-facing work goes to GitHub issues with the `ai-task` label
(see `AGENTS.md`), never to files in the tree.

### 6. Timebox investigations

"Park it and capture it" is cheaper than hoping the assistant stops digging on its own. It will
chase a puzzle through its own tooling bugs for longer than the puzzle is worth.

### 7. Test where the assumption is *not* already satisfied

The one with the highest hit rate. Almost every real defect in a week of desktop work was
**invisible on a machine that had already built the tree**:

| what looked fine | where it broke | why it was hidden |
|---|---|---|
| the installer's provisioning step | a CI runner | Quicklisp was already installed on the dev box, so that code had never run |
| a bundled desktop app | the bundle copied elsewhere | a stray source tree nearby satisfied the launcher lookup |
| the Linux binary | any machine without `libev` | dev boxes have it; users do not |
| every HTTP response | a reused connection | one request per connection hides the 44 ms floor completely |
| "Coalton loaded without recompiling, so it's correct?" | — | that is *also* the symptom of stale fasls; ambiguous evidence, so `scripts/check-coalton.lisp` now proves it |

A corollary for the assistant: a green exit code is not evidence. Run the artifact somewhere it
has no help.

## What a good session looks like

1. The human states the outcome and any hard constraints up front (*"installers, not zips"*;
   *"Windows Server will want Woo-class throughput"*). Constraints arriving late reshape
   decisions that are already built.
2. The assistant proposes the shape, names the forks it cannot decide, and recommends rather
   than surveys.
3. It builds, and **verifies on a machine that does not already work**.
4. Findings that change a decision become an ADR; ideas become issues; nothing important stays
   in the chat.
5. Commits carry the reasoning — including what was measured, what is still unproven, and what
   was deliberately left out.

## Worth knowing about the failure modes

- **Confident wrongness on environment facts.** Action versions, package names, upstream URLs,
  which library ships which symbol — verify rather than accept. Five consecutive CI failures in
  one session were each a real environmental truth (glibc floors, an HTML interstitial saved as
  an `.msi`, a load-time FFI dependency, a `PATH` snapshot taken before an installer ran, quotes
  stripped from a native-command argument). None were reasoning errors; none were findable by
  reasoning.
- **Over-thoroughness.** It will keep going. Bound the work.
- **Its own tooling is a source of bugs.** A benchmark that crashes on a stall reports "the tool
  is broken" instead of "the server stalled" — and the finding is lost. Make harnesses report
  failures as measurements.
