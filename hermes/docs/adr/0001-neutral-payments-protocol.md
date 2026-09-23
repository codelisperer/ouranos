# ADR-0001 — Payments behind a neutral protocol, in its own system

**Status:** Accepted (2026-09-02) · 2026-08-27 · issues pre-publication issue 48, pre-publication issue 49, pre-publication issue 47, pre-publication issue 50, #58

## Context

hermes is the satellite for external integrations. It already carries **one** neutral
protocol — `deliver` / `send` over email and SMS, with SendGrid and Twilio as
interchangeable backends behind it. Payments is the next integration, and the question is
whether it deserves the same treatment or is special enough to be written directly against
a vendor.

Payments is the *archetypal* case for the doctrine, not an exception to it. The cost of
getting it wrong is not a refactor: a payment integration accretes call sites in exactly the
places an application cannot afford to churn, so a vendor's shape adopted early is a vendor
lock-in that outlives the reason for it.

## Decision

**A neutral protocol, in its own ASDF system, with the vendor arriving last.**

1. **`hermes/payments` is its own system**, though it adds no external dependency hermes
   core lacks. The reason is load path rather than dependencies: an application that wants
   email should not compile a payments protocol it will never call, and a payments module is
   the last thing that should be reachable by accident.

2. **`payment-provider` is a sibling of `provider`, not a subclass.** A payment provider does
   not deliver messages. Inheriting from something whose contract is `DELIVER` in order to
   reuse a registry would be reuse of the wrong thing.

3. **The protocol is specified and built before any vendor exists** (pre-publication issue 48 before pre-publication issue 47).
   Building a neutral protocol with a vendor in the room is how the vendor's shape gets into
   it. A **dev provider** — in-memory, charging nobody — is the first implementation, and it
   is selected by the same `HERMES_TRANSPORT=dev` that already forces the dev transport for
   email and SMS. That is not a convenience: *a module whose local-dev path reaches a real
   vendor is one that gets tested against real money.*

4. **Subscriptions are plural.** Nothing returns *the* subscription; `subscriptions-for`
   returns a list, including when it is empty and including when it is one.

5. **Webhooks are authoritative; redirects are advisory.** State changes on the webhook. A
   success URL is a browser being told what to display — forgeable, replayable, possibly
   never visited.

6. **Events carry state, not deltas**, plus a stable id and the provider's own
   `occurred-at`. Webhooks arrive at-least-once *and out of order*.

7. **Deduplication is the application's.** We expose a stable id; the app keeps the
   processed-events table. Dedupe needs durable storage and hermes is a satellite with no
   database and none permitted.

8. **The vocabulary is closed.** A provider event outside the seven normalized kinds is
   reported as `unmapped-event` rather than widening the core. Provider-specific
   capabilities ride on `provider-call`, deliberately awkward and explicitly outside the
   compatibility promise.

## Consequences

- Every caller handles a list of subscriptions, including apps that will only ever have one.
- The neutral core is **checkout + webhook + status**. Hosted checkout plus subscriptions
  maps cleanly onto Stripe; it does **not** map cleanly onto crypto vendors, which are
  invoice- and one-time-shaped. Stated in the README rather than discovered later.
- An application reaching for `provider-call` is coupled to that provider and knows so at
  the call site.
- Adding a vendor is a class plus one `register-payment-impl`.

## Alternatives considered

**Write directly against Stripe and generalize later.** Faster to a working checkout, and
the generalization never happens — by the time a second provider is wanted, the vendor's
vocabulary is in the application's call sites. #58 exists to keep this honest.

**Payments inside hermes core.** Rejected on load path: see Decision 1.

**A richer neutral core covering invoices and one-time payments.** Rejected as premature. A
neutral core wide enough for every payment model is a union of vendors wearing a protocol's
name; the honest move is a narrow core and a named limit.

## Provenance

The design changed materially **before** it was written, because requirements were solicited
from a consuming application first — the lesson of pre-publication issue 165, where a real application running
the code decided a design that review had not.

Two of its points reshaped the surface rather than adding to it. **The first specification
was wrong**: it had `subscription-status` returning *a* status, and the app pointed out that
a per-group tier means one customer holds several concurrently — cheap to design for, and
expensive to retrofit, since unwinding it touches every event, entitlement lookup and
reconciliation path. **And the ticket's list of seven operations was incomplete**:
reconciliation is not among them, and without an authoritative read *the only recovery from
a missed webhook is a human noticing*.

The representation split — Coalton for the event vocabulary, CL structs for the records it
carries — was decided by the maintainer after pushing back on a runtime-cost claim that
turned out not to hold. Release mode flattens Coalton types to `defstruct`s and this path is
one event behind an HTTP round trip, so runtime was not the argument. The real costs were
accessor surface, §7 crossing risk in a module that handles money, and Coalton compile time
paid on every cold gate run. The deciding argument was that **exhaustive `match` only pays
off if the consumer is Coalton, and nothing downstream is.**
