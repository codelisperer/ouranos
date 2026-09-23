# ADR-0001 — Two budgets: what `assemble` is for, and what conversation history gets instead

**Status:** Accepted *(2026-09-19)*
**Date:** 2026-09-19
**Issue:** pre-publication issue 402. Constrained by
pre-publication issue 401 (the cacheable prefix, landed);
related to [#138](https://github.com/codelisperer/ouranos/issues/138) (the retrieval seam,
deferred).

## Context

`praxeon/src/context.lisp` implements a token budget, per-item token accounting, and a greedy
`assemble` that selects the highest-value items that fit. It is exported. Nothing called it:

```
$ git grep -n 'assemble' -- 'praxeon/src/*.lisp'
praxeon/src/context.lisp:47:(defun assemble (context)
praxeon/src/packages.lisp:63:   #:add-item #:assemble #:context-tokens #:now))
```

Meanwhile `actor:deliberate` sent `(agent-history agent)` whole, so an N-turn conversation
resent the entire history every turn and input cost grew quadratically — the exact thing the
budget was written to bound.

The claim was not merely greppable, it was **rendered**. `studio:agent-summary` reported the
context object's budget as *the agent's* budget, and `describe-agent` printed it:

```
  context  : 8000-token budget
```

for an agent whose context was not budgeted in any respect. A false claim in a debugging tool is
worse than one in a docstring, because it is what someone consults when they are already
confused.

A consuming app had to solve its half app-side: it trims history to a **token** budget rather
than a message count, because a message cap makes the typical case fine and the worst case
unbounded — fifty short turns and fifty long ones differ by an order of magnitude. That work is
correct, and it duplicates what `context.lisp` was written to do.

So pre-publication issue 402 asks a design question with two candidate answers: does the turn loop own assembly, so
history becomes context items and `assemble` chooses what is sent — or is `context.lisp` for
retrieved facts only, with history budgeted elsewhere?

## Decision

**Both, separately, because they are two different scarcities over two different kinds of data.**

**1. `praxeon/context` is for retrieved facts.** Its ranking has a precondition, now stated in
the file: an item must be *independent* — any subset of items, in any order, must be a valid
prompt fragment. A retrieved fact satisfies that. A conversation turn does not.

**2. Conversation history gets its own operation, in a new module `praxeon/prompt`**: a
**prefix-pinned, whole-exchange, token-measured trim, applied at send time**. The agent's
`history` slot remains the complete record; trimming chooses what is *sent*, and never destroys
what is remembered.

**3. Both are wired into the turn loop in the same commit as this ADR.** Whichever answer was
chosen, the state pre-publication issue 402 objected to — a budget, an accounting, a comparator, and no caller — is
not one this repo leaves behind.

### Why history cannot go through `assemble`

Four reasons, each independently sufficient.

**Tool pairing is a structural invariant, and selection breaks it.** An assistant message
carrying a `tool_use` part is answered by a message carrying a `tool_result` with the matching
id; Anthropic's documentation requires the assistant content to be replayed and each
`tool_result` to carry its `tool_use_id`. `%part->json` serialises whatever list it is handed and
validates nothing, so a value-density selection that keeps one half of a pair produces a
**malformed request**, not a worse prompt. `assemble` ranks items individually and has no notion
of a pair.

**Order is meaning, and `assemble`'s order is not stable.** It sorts by `ctx-item-valid-time`,
stamped from `(get-universal-time)` — one-second resolution — with `sort`, which CL does not
require to be stable. Two messages appended in the same second may come back in either order.
For a set of facts that is a cosmetic risk; for a dialogue it is a scrambled conversation, and it
would be intermittent. (`assemble` now uses `stable-sort` regardless; this ADR does not rely on
that fix.)

**The cacheable prefix has to be pinned, and ranking has no notion of position.** pre-publication issue 401's
commentary states the constraint from the other end: a cached prefix is a saving only while its
bytes do not change, so trimming from the front defeats caching completely — every turn writes a
new entry at 1.25× and reads none. A value-density selection will drop something inside the
prefix whenever its density is low, which is both an invalidation and, if the dropped part was
the marked one, the silent loss of the breakpoint itself.

**Nobody can impute the value of a turn.** `ctx-item-value` is supplied by whoever adds the item.
For a retrieved fact there are defensible sources — a similarity score, a source's authority. For
"what the user said three turns ago" there is no such number, and the only honest proxy is
recency. A recency-ranked knapsack is an elaborate way to keep the tail, which is what the trim
does directly, in one pass, with the invariants respected.

### What `praxeon/prompt` does

- **Exchanges, not messages.** The history is grouped into indivisible units: a user message that
  is not a tool-result message starts a new exchange, and everything following it (the
  assistant's reply, its tool calls, the tool results, further assistant turns) belongs to that
  exchange. Trimming drops whole exchanges, so a `tool_use` cannot be separated from its
  `tool_result` by construction rather than by a check someone has to remember.
- **The pinned prefix is never dropped.** Every message up to and including the last one carrying
  a `:cache t` part is pinned (rounded out to its exchange boundary). What pre-publication issue 401 marked as
  cacheable stays byte-identical across turns, which is the entire point of having marked it.
- **Measured in tokens, from an estimate that says so.** `estimate-tokens` is a character-based
  approximation, named as one. The provider's reported `input-tokens` is the measurement; the
  `:usage` event now carries both, so drift between them is visible rather than assumed away.
- **The last exchange is never dropped.** If the pinned prefix plus the newest exchange already
  exceeds the budget, `trim-history` returns them anyway and emits `:context-overflow` with the
  estimate and the budget. Silently sending an over-budget request and silently dropping the
  user's actual question are both worse; this fails loud and lets the provider's own limit be the
  limit.
- **Retrieved facts are placed after the cacheable prefix.** `assemble`'s chosen items are
  rendered into the final user message, because they change every turn: putting per-turn
  retrieval inside the cached region would invalidate the cache on every request, which is the
  same mistake as trimming through it, arriving from the other side.

## Consequences

- `praxeon/prompt` is loaded between `llm` and `actor`: it needs the message vocabulary, and
  `actor` is its only consumer inside the framework. `praxeon/context` stays free of `llm` — it
  is the Kairos seed and remains plain data.
- **`agent` gains a `history-budget` slot, defaulting to 120000 estimated tokens.** A default,
  not `nil`, because an unbounded default *is* the defect pre-publication issue 402 filed: an opt-in bound that no
  existing agent opts into leaves every consumer quadratic and leaves this module with no
  caller in practice. `nil` remains available and means "send everything", for a caller who
  measures its own bound.
- Existing agents change behaviour only once a conversation passes the budget, and only in what
  is sent. Nothing in the agent's recorded history is lost, so a client that renders
  `agent-history` still shows the whole conversation.
- The consuming app can delete its own trim or keep it: the shapes agree (token budget, oldest
  dropped first), so they do not fight. Its measurement — 574 input tokens for a one-line
  question against an *empty* history — remains the reason the prefix is pinned rather than
  merely preferred.
- `studio:agent-summary` reports both budgets and what each governs. The single `:budget` key it
  used to expose was the false claim; it is now `:history-budget` and `:context-budget`.
- `ctx-item-value` still has to come from somewhere, and for retrieved facts that somewhere is
  #138 (provenance, chunking, source language). This ADR does not settle it; it makes
  `assemble`'s precondition explicit so #138 designs against a stated contract.
- A better history policy — summarise the dropped exchanges rather than discarding them — is now
  a change to one function with one caller, instead of a redesign.

## Alternatives considered

- **History as `ctx-item`s (the issue's option 1).** Rejected on the four reasons above. The
  first is fatal on its own: it turns a cost optimisation into malformed requests, intermittently,
  under load, in the code path that is hardest to reproduce.
- **Document it as a deliberate not-yet and write no code.** This was on the table and is the
  cheaper answer. Rejected because it leaves the quadratic cost in every consumer, leaves
  `describe-agent` printing a budget that governs nothing, and leaves the app owning framework
  work — and because "not yet" has to be re-litigated by whoever next greps for `assemble`.
- **Summarise instead of trim.** A real option and a better one eventually. It needs a model call
  in the middle of a turn loop, which is a second failure mode inside the deliberate/act cycle,
  and it is not a *budget* mechanism — you still have to decide what fits. Deferred, on the
  footing above.
- **A message-count cap.** Rejected on the app's own argument, which is the argument this ADR
  adopts rather than invents: a count makes the typical case fine and the worst case unbounded.
- **One budget for both.** Rejected: the numbers are not comparable. A history budget bounds a
  cost that grows with conversation length; a context budget bounds how much retrieved material
  is worth paying for on one turn. Sharing a number would make each one's tuning a regression in
  the other.

## Provenance

The decision inverted once. The module's shape — items, value, a budget, a greedy selector —
reads as an argument for option 1, and that is how pre-publication issue 402 describes it ("what the module's shape
implies"). What moved it was asking what `assemble` would actually *do* to a history containing a
tool call: drop the assistant message that requested it while keeping the result, because a
`tool_result` part carrying a long payload has low value density. The resulting request is
invalid, and nothing in this tree would have caught it — `%part->json` validates nothing, and the
suite had no history-shaped test to fail.

The `stable-sort` detail was found while writing the third reason and is a defect in `assemble`
for its *intended* use as well, independent of pre-publication issue 402.

The hub's brief supplied the constraint that the app has already solved its half and that
upstream should not fight it, which is why the trim's shape deliberately matches the app's rather
than improving on it.
