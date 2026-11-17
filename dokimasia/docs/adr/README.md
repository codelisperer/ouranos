# Architecture Decision Records (dokimasia)

Short, dated records of dokimasia's architecturally significant decisions. One decision per
file, numbered. Once a record is Accepted it is not edited; a new record supersedes it.

**Format:** Status · Context · Decision · Consequences · Alternatives considered.
**Status values:** Proposed · Accepted · Provisional (accepted but under active review) ·
Superseded by ADR-NNNN · Deprecated.

Ecosystem-wide decisions live in the root [`ECOSYSTEM.md`](../../../ECOSYSTEM.md) decisions
log.

## Index

| # | Title | Status |
|---|---|---|
| [0001](0001-browser-driver-and-acceptance-harness.md) | dokimasia: a data-driven acceptance-test harness for any app in a browser, over a browser driver in aion | Accepted |

ADR-0001 also decides the placement of `aion/websocket` and `aion/cdp`, the browser driver
dokimasia runs on. aion's ADR index points here for that decision.
