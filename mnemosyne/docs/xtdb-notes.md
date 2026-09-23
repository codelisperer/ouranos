# XTDB 2 over PG wire — caveats

XTDB 2 speaks the **PostgreSQL wire protocol**, so mnemosyne's Postgres path
(`dbd-postgres` / `cl-postgres`) **connects to it unchanged** — verified: `connect` +
`SELECT 1` returned over the wire against `ghcr.io/xtdb/xtdb`. That de-risks the future
bitemporal migration: it's "point the connection at XTDB 2," no new driver.

**But XTDB 2 is a distinct *dialect*, not "just Postgres."** Treat it as its own dialect
in `mnemosyne/query` (`:xtdb`), not as `:postgres`:

- **No DDL — schemaless.** There is no `CREATE TABLE` / `ALTER TABLE`; tables spring into
  existence on insert. So the **migration runner's DDL model does not apply** to XTDB 2
  (`schema_migrations` DDL, `CREATE TABLE ...` all fail). XTDB "migrations" are semantic /
  data shape, not schema — a separate concern from the SQL/PG migration runner.
- **Parameter handling differs.** A parameterized `INSERT` via CL-DBI's `?` binding failed
  with *"0 parameters expected, N received"* — XTDB 2's pgwire prepares params differently
  from stock PG. The `:xtdb` placeholder path in `mnemosyne/query` (`$N`) is a **provisional
  seam, not yet verified end-to-end**; getting params right on XTDB is part of the future
  adapter.
- **DML surface differs — the wider query builder guards for it.** As `mnemosyne/query`
  grew joins / subqueries / aggregates / `RETURNING` / upsert, the DML pieces diverge on XTDB 2:
  - **`INSERT` is *already* an upsert on `_id`.** Re-inserting an existing `_id` writes a new
    temporal version — there is **no `ON CONFLICT`** clause (it is meaningless / unsupported).
    So the builder **signals** if a `:xtdb` query carries `:on-conflict`; app-level "upsert"
    on XTDB is just `INSERT`.
  - **`_id` is required and is the primary key.** No `SERIAL` / autoincrement — supply `_id`
    (e.g. a UUIDv7) yourself.
  - **No `RETURNING`.** XTDB 2 DML is submitted to the tx log; you read the written value back
    with a **separate query**, not a `RETURNING` clause. The builder **signals** on
    `:returning` for `:xtdb`.
  - **`UPDATE` / `DELETE` are temporal**, and `ERASE` hard-removes a row across all time
    (no SQL-standard analogue). SELECT-side joins, subqueries, and aggregates are standard
    and carry over.
- **Transaction gotchas.** XTDB 2's model (append-only tx log; reads vs writes) means its
  pgwire transaction semantics differ from PG's — `with-transaction` may not behave the
  same. Verify before relying on it.
- **Temporal SELECT is the point.** XTDB 2's value is bitemporal query — `FOR VALID_TIME
  AS OF …`, `FOR SYSTEM_TIME …`, `FOR ALL VALID_TIME`. The `:xtdb` dialect layers these on
  later. Emulate the shape from **HoneySQL's XTDB doc**
  (seancorfield/honeysql `doc/xtdb.md`).

**Status / stance.** Connection de-risked; **full XTDB 2 support is a later dialect/adapter**.
Near-term, ship on **Postgres** (fully working) and **SQLite** (dev). XTDB 2 comes when
bitemporality is actually needed and its deployment story (self-hosted JVM + object storage
on a DO Droplet/Spaces, or AWS S3 + log — no managed XTDB) is settled.
