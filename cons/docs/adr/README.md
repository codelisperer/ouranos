# Architecture Decision Records (cons)

Short, dated records of decisions about cons and the toolchain it provisions: `scripts/setup.sh`,
`scripts/setup.ps1`, `bootstrap.lisp` and the pinned tools they install. Each records the *why*
behind a choice that is expensive to reverse or that a later session or machine would otherwise
argue again. One decision per file, numbered, and not edited once Accepted: a changed decision
gets a new ADR that supersedes the old one.

**Format** (keep each to about a page): Status · Context · Decision · Consequences ·
Alternatives considered · *(optional)* **Provenance**.

**Provenance — how the decision was reached**, added when the process shaped the outcome: a
measurement that contradicted an assumption, a counterargument that was asked for and landed,
research that changed the question, a plan that was dropped. See
[`hyperion/docs/adr/README.md`](../../../hyperion/docs/adr/README.md) for the convention and
[`docs/working-with-ai.md`](../../../docs/working-with-ai.md) for why it exists.

Rules that bind the whole tree are listed in the [`ECOSYSTEM.md`](../../../ECOSYSTEM.md)
decisions log. When such a rule needs a full record, the record is an ADR here and the log entry
points to it, so the decision is written in one place.

**Status values:** Proposed · Accepted · Provisional (accepted but under active review) ·
Superseded by ADR-NNNN · Deprecated.

## Index

| # | Title | Status |
|---|---|---|
| [0001](0001-own-sbcl-builds.md) | Ouranos builds and publishes its own SBCL binaries | Accepted |
