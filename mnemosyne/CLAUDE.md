# CLAUDE.md — Mnemosyne

Tree-wide rules are in the root `CLAUDE.md`/`AGENTS.md`, loaded with this file. Only
mnemosyne-specific notes here.

## What this is

The data layer: an Ecto-like schema/query DSL, migrations and connections, backend-neutral
over CL-DBI. Postgres over the wire for prod, SQLite for zero-ops dev, XTDB 2 later.

The memory stack, not to be conflated: **Mnemosyne** is the DB · **Kairos** is a bitemporal
knowledge graph *on* it (praxeon, unbuilt) · **Praxeon** is the agent on Kairos.

## Design facts

- Queries are data: `(:select … :from … :where (:= …))`. `defschema` + `schema-ddl` feed
  migrations; `mnemosyne/ddl` for index/drop/alter. External input flows
  `cast → validate → insert!`.
- **Bitemporal is DESIGNED, NOT BUILT.** The SQL:2011 model (valid-time period columns +
  system versioning, opt-in per entity) is the plan; there is no period column or temporal
  DDL in `src/` today. Don't describe it as present. **#49** is the implementation
  ticket (migrations bitemporal-aware), gated by **#54** (settle the bitemporal API);
  #60 is Kairos and a separate concern. (pre-publication issue 227 is the sweep that *found* the gap --
  a finding's provenance is not its home.)
- A backend that cannot support a declared field type **refuses at migration time**;
  emulation is opt-in at the declaration site — ADR-0001 (accepted). `field-type-sql`
  returns `Native | Emulated | Unsupported`, never a bare string.
- `cl+ssl` is deliberately not a dependency (pre-publication issue 146): `conn` degrades `sslmode=prefer` to
  plaintext with a warning and refuses `require`/`verify-*` unless the app declares it.
  Note this is now undercut by `aion/http-client` pulling `cl+ssl` on non-Windows (#115).

## Gotchas

- SQLite accepts any type name (`VECTOR(1536)`, `FLURBLE(9)`) and stores text. Postgres
  errors. Test type-refusal on both.
- The gate needs a real Postgres: `scripts/test-postgres.sh up` then
  `eval "$(scripts/test-postgres.sh env)"`. `verify-tree` fails if the backend didn't run.
- `field-type-from` falls back to `FT-String` on an unknown name.

## Where to look

`docs/mnemosyne-vision.md` · `docs/first-milestone.md` · `docs/adr/` ·
[`../docs/wiki/Framework-Mnemosyne.md`](../docs/wiki/Framework-Mnemosyne.md).
