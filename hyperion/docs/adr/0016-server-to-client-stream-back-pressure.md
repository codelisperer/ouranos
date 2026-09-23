# ADR-0016 — Server→client streams coalesce per key at a subscription's rate

**Status:** Accepted — 2026-09-02

## Context

M2 of [#117](https://github.com/codelisperer/ouranos/issues/117) gives hyperion its first
real server→client streams: a streaming response body on the native server, and SSE on top
of it. [#210](https://github.com/codelisperer/ouranos/issues/210) asks that the back-pressure
question be settled **before** that surface exists, on the grounds that *"the cheapest time
to decide is before the first stream API hardens, not after."* That is the whole reason this
ADR is written now rather than discovered later: a stream API acquires a back-pressure
policy whether or not anyone chooses one, and the one you get by not choosing is the bad one.

**The measurements are a consuming app's, not ours.** #210 carries that app's numbers from a live
market feed: **1,644 msg/sec burst, 424/sec sustained, ~10M messages/day across 30 symbols**,
sent to a webview that drowns if given them wholesale. What that app hand-rolled, none of
which is about its domain:

- deltas rather than snapshots,
- **two independent rates from one source** — a 4 Hz ranking update and a 1 Hz chart update,
- focus-scoped payloads (only the selected symbol's chart data crosses the wire),
- and a decoupling of value updates from list ordering, so a list re-sorting at 4 Hz stays
  clickable.

The last is genuinely theirs. The first two are not.

**What the tree has today is the anti-pattern.** `hyperion/channel` is an append-only
broadcast log read non-destructively by absolute index — correct and elegant for its purpose
(every reader sees every item; two browsers on one conversation do not steal from each
other), and **it never removes anything**. Nothing trims `channel-items`. At a conversation's
pace that is bounded by the conversation. At 424 msg/sec it is a memory leak with a
publication schedule.

It has **no production consumers yet** — praxeon mentions it in a comment and nothing calls
it — so this decision is still free. Had a high-rate consumer arrived first, the surface
would have hardened around the unbounded log and this ADR would be a migration plan.

## Decision

**Coalescing, keyed, with a per-subscription rate. Explicitly not queueing.**

A new module `hyperion/feed`, beside `hyperion/channel` rather than replacing it:

1. **A feed holds the latest value per key, not a history.** Publishing key `k` twice
   between two reads leaves one value: the second. Coalescing is the data structure, not a
   policy layered on one.
2. **A subscription declares the rate it wants.** The server emits to it at most that often.
   Two subscriptions on one feed may run at different rates, and **the publisher does not
   know how many subscribers exist or how fast they are**, which is precisely the coupling
   the hand-rolled version could not avoid.
3. **A slow consumer gets fewer updates, never a backlog.** This is the property the whole
   decision is for. The alternative fails as a silently growing queue that presents as a
   slow browser — a symptom pointing at the wrong component.
4. **Memory is bounded by the number of distinct keys**, not by the update rate or by how
   long anyone has been connected. 30 symbols is 30 entries whether the feed has been up for
   a second or a month.

`hyperion/channel` stays exactly as it is, for the case it is right for: every reader must
see **every** item. Each module's docstring names the other and says which question it
answers, because the two are easy to reach for interchangeably and the failure of choosing
wrongly is silent in both directions — a lost intermediate value, or unbounded memory.

## Consequences

- **Intermediate values are lost, by design.** This must be stated at the surface and not
  merely in a document. A feed is the wrong primitive for an audit trail, a chat transcript,
  or anything where a skipped value is a defect rather than a saving.
- **Focus-scoping stays the application's.** A subscription filter is domain knowledge; the
  framework has no view on which symbol a user is looking at.
- **Deltas are not addressed here.** Coalescing removes the need for most of what deltas buy
  at this layer; if a keyed value is itself large and mostly-unchanged, that is a payload
  question for the app.
- **A rate is a promise about frequency, not latency.** A subscriber at 1 Hz sees a change up
  to a second late. Anything needing "immediately" wants a rate high enough to say so.
- **The SSE surface in M2 is built on this**, so the streaming body and the back-pressure
  policy land together rather than the second being retrofitted onto the first.

## Alternatives considered

**Unbounded queueing per subscriber.** The default, and what you get by not deciding. Rejected
because its failure mode is invisible: memory grows, the browser falls behind, and nothing
reports an error — the operator sees "the app is slow". #210 names this and the maintainer's
ruling names it; recording it as *rejected* rather than *not considered* is the point.

**Bounded queue with drop-oldest.** Honest about its limit and bounded in memory, but it drops
the wrong thing: for a value stream the oldest entry is the least valuable, so a full queue
discards updates while retaining stale ones. Coalescing is what drop-oldest is trying to
approximate — for keyed values, keeping only the newest per key IS the correct eviction.
Drop-oldest remains right for a genuine event log, which is `channel`'s territory.

**Rate declaration without coalescing.** Thinning a queue by sampling still needs somewhere to
put the values it skips, so the queue is back.

**Coalescing without a rate.** Bounded memory, but a fast publisher still drives a fast
consumer loop, and two consumers of one source cannot run at different rates without the
source knowing about them — the exact coupling that app had to hand-roll around.

## Provenance

The maintainer's ruling arrived as an explicit recommendation rather than an instruction —
*"treat this as a recommendation you may argue with… if building it shows the shape is wrong,
say so and change it"* — with the reasoning drawn from that app's measurements rather than from
taste. The lane holds the code and the numbers; the recommendation was to write the decision
down before the surface, and this ADR is that.

Two things moved while writing it rather than being carried in from the ruling. **`channel`
turning out to be unbounded** reframed the decision: the question was not "what should we add"
but "the primitive we already shipped is the alternative being rejected, and it has no
consumers yet." That is a considerably stronger reason to decide now than the schedule
argument #210 makes. And **drop-oldest was the alternative that took longest to reject**,
because it is bounded and honest; what settles it is that for keyed values, coalescing *is*
drop-oldest done correctly — same intent, right unit of eviction.
