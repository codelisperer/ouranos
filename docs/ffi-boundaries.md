# Cross at frame rate, not at data rate

*Doctrine for FFI boundaries, from the first one in the ecosystem measured under real load.
2026-08-28.*

The thesis in [`ECOSYSTEM.md`](../ECOSYSTEM.md) is that Ouranos plays at the CPU-bound
orchestration layer and **FFIs out for anything numeric**. That sentence is only as good as
the boundary it implies, and until a consuming app built one and measured it, the boundary was
an assertion.

## The rule

**Traffic does not cross the boundary. State does, when the host draws.**

The native side owns the socket, the thread, and the per-symbol state. It absorbs the full
input rate internally and keeps a current snapshot. The host polls that snapshot at the rate
it *renders*, not the rate data *arrives*.

## Why, measured

A market-data feed peaking at **1,644 messages/sec** and averaging ~10M messages/day, driven
through real C entry points over a recorded tape:

| host poll rate | µs per crossing | share of wall time | prints per crossing |
|---|---|---|---|
| 10 Hz | 8.2 | 0.0 % | — |
| 60 Hz | 8.8 | 0.1 % | 1,481 |

**Crossing rate tracked the requested poll rate exactly — 10.3/sec and 59.3/sec — regardless
of ingest speed.** That decoupling is the whole argument. Per-message crossing would have been
~1,600 calls/sec into a GC'd host with thread-registration rules: expensive, and fragile in a
way that only shows up under load.

So *"high-rate data behind an FFI"* is cheap here rather than heroic, and it is cheap because
of where the boundary sits rather than because the boundary is fast.

## Three properties to design for deliberately

**No callbacks into the host. From any thread. Ever.** Nothing for SBCL to register, no
callback lifetime to manage, no foreign thread arriving in the Lisp image uninvited. This is
the property most worth *designing for* rather than arriving at — it is very hard to retrofit,
because by then something is calling back.

**Serialisation that is fine at frame rate is not fine at message rate.** JSON per call costs
nothing at 60 Hz and would dominate at 1,600 Hz. That is a second, independent reason the
boundary sits where it does — and a useful check: if the encoding choice would be wrong one
layer down, the boundary is probably in the right place.

**Every entry point returns an error object; nothing panics.** A panic across an FFI boundary
is undefined behaviour. Pin malformed input, null pointers and unknown handles with tests, in
the native side, where the panic would originate.

## The claim this supports, and the one it does not

Worth stating precisely, because the temptation to overclaim is strongest where the numbers
are good:

> Sustains a real vendor market-data feed at ~1,600 msg/sec peak and ~10M messages/day,
> **losslessly**, with the FFI boundary costing 0.1 % of wall time.

That is defensible. What it does **not** support is anything HFT-adjacent. In the measured
application nothing auto-trades and the UI redraws at 4 Hz, so there is no latency requirement
at all.

**The demanding property is losslessness, not speed** — the model's window is a count of
prints, so a dropped message silently shifts the window rather than erroring. Make the lossless
claim rather than the latency one: it is true, it is less contestable, and it is the harder
engineering problem of the two.

## A note on benchmark hygiene, from the same source

The app first reported its engine at ~2,500 prints/sec, flagged the number as suspicious, found
an accidental O(n²) of its own making, fixed it, and re-measured at **~1,000,000 prints/sec** —
a 400× correction it volunteered rather than let stand.

Two things worth copying. It **retracted the number to everyone it had told**, because a wrong
number in someone else's scoping is worse than a wrong number in your own notes. And it fixed
the cost by computing on demand rather than incrementally — *"running sums for variance would
change floating-point rounding and move every golden fixture"* — keeping identical arithmetic
so the no-change stays provable. **The faster algorithm was available and was the wrong one.**
