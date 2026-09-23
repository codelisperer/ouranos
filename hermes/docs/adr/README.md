# Architecture Decision Records (ADRs) — hermes

Short, dated records of architecturally significant decisions in **hermes**, the satellite
leaf-lib for external integrations (email, SMS, blob storage, payments). Same conventions as
[`hyperion/docs/adr`](../../../hyperion/docs/adr/README.md), which is where this practice
started.

One decision per file, numbered, **immutable once Accepted** — supersede with a new ADR
rather than editing history.

**Format** (keep each ≤ a page): Status · Context · Decision · Consequences ·
Alternatives considered · *(optional)* **Provenance**.

**Provenance** is added when the *process* shaped the outcome: a measurement that
contradicted an assumption, a counterargument that was asked for and landed, research that
reframed the question, a lean that was abandoned. It is the part a future reader cannot
reconstruct from the outcome.

**Status values:** Proposed · Accepted · Provisional (accepted but under active review) ·
Superseded by ADR-NNNN · Deprecated.

These are **hermes-level** decisions. Ecosystem-wide decisions live in the root
[`ECOSYSTEM.md`](../../../ECOSYSTEM.md) decisions log; web-framework decisions live in
hyperion's ADR directory.

## Index

| # | Title | Status |
|---|---|---|
| [0001](0001-neutral-payments-protocol.md) | Payments behind a neutral protocol, in its own system | Accepted |
| [0002](0002-stripe-pci-posture.md) | Stripe integration: hosted Checkout only, and the PCI posture that follows | Accepted |
| [0003](0003-ads-audience-neutrality-and-first-deliverable.md) | Ads: how neutral `Audience` is, and which half ships first | **Proposed — awaiting the maintainer** |
