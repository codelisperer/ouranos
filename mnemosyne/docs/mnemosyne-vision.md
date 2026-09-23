# Mnemosyne — Vision & open questions

Mnemosyne is the bitemporal data layer for the codelisperer ecosystem. This file
holds the open design questions; decisions graduate to ADRs and the roadmap.

## Thesis

Escape ORM / JVM / dependency sprawl: **one cohesive, Coalton-typed,
backend-neutral data layer** that speaks the **PostgreSQL wire protocol** (so
PostgreSQL *or* XTDB 2 work behind one protocol), with **bitemporality**
(valid-time + tx-time) as a first-class concern rather than an afterthought.

Ecto (Elixir) is the inspiration — schema + changesets + a composable query DSL,
*not* a lazy-graph ORM. The **memory** theme (Mnemosyne) fits a store that
remembers all of history.

## The three-tier stack (keep distinct)

- **Mnemosyne** — general bitemporal DB abstractions (connection, schema, query,
  migrate). *This project.*
- **Kairos** — a dedicated bitemporal knowledge-**graph** store, built on
  Mnemosyne's DB abstractions. (Seeded today in `praxeon/src/context.lisp`.)
- **Praxeon** — leverages Kairos for recall + the context-budget economics
  (value-density assembly under the scarce context window), in its praxeological
  layer.

Open: does Kairos live in its own repo, in Praxeon, or as a Mnemosyne extension?
(Grow it where it's seeded; split when justified — the ecosystem's usual pattern.)

## Open questions

*Backend progression is no longer open: the settled decision is **SQLite → Postgres →
XTDB 2 over CL-DBI** (embedded-first) — see [`first-milestone.md`](first-milestone.md).
The questions below are the remaining ones.*

1. **Query DSL surface.** How much is Coalton-typed (compile-time-checked queries)
   vs. a CL macro DSL vs. HoneySQL-style data? Ecto-like changesets for writes?
2. **Backend protocol shape.** The neutral protocol over PG wire — connection,
   transaction, prepared statements, streaming results. Postmodern vs cl-postgres
   vs closer-to-the-wire.
3. **Bitemporal API.** How valid-time / tx-time surface in schema and queries
   (`AS OF`, history, erasure). XTDB 2's native model vs. a PG-side implementation.
4. **Migrations.** Auto-on-init? Bitemporal-aware schema evolution; up/down.
5. **Entity/model pattern.** A `touch!` / `with-id` stamping convention (UUID v6,
   `vid`, timestamps, audit fields) supported by the layer.
6. **CLI (`mnemo`).** migrate, db up/down, console, seed, gen.
7. **EDN interop.** XTDB 2 speaks EDN *and* JSON. Add a CL EDN library for XTDB 2's
   EDN surface, or stay JSON-first (via jzon)? (No mature EDN lib in the pinned
   Quicklisp dist; would come via Ultralisp / git.)
8. **Connection pooling & concurrency.** Pool behind the protocol; thread-safety.

## Non-goals (for now)

- A full lazy-graph ORM. Prefer explicit, data-oriented queries.
- Node / JVM anything.
