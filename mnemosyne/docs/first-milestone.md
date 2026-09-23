# Mnemosyne — first milestone (handoff)

*The persistence layer a consuming app's auth needs. Written as a cross-window handoff;
the Hyperion-side context lives in the sibling `../hyperion` dir of this monorepo.
Decisions here are settled with the maintainer — build to them.*

## What Mnemosyne is

An **Ecto-like data layer**: pluggable backends behind a **neutral protocol**. Not
XTDB-first. It is a dependency-graph *mid* layer — apps (a consuming app) and other libs
consume it; it depends only on a DB driver, never on the web framework.

## Decided backend progression (embedded-first)

Chosen for **zero-ops dev + standalone/on-prem deploy** (an app can ship as a binary
+ a `.db` file), deferring cloud-DB ops:

1. **SQLite now** — the transactional MVP: users, sessions, content.
2. **Postgres next.**
3. **XTDB 2 later** — bitemporal (→ Kairos); this also defers the unresolved
   XTDB-on-DigitalOcean-vs-AWS ops question until it actually matters.

- **Substrate: CL-DBI** (the DB-independent layer). One SQL adapter covers SQLite
  *and* Postgres, so **#1 → #2 is mostly a connection-string change**. XTDB 2 is a
  *separate* adapter later.
- **DuckDB is OLAP** — a possible *analytics* backend later, **not** the
  transactional core. Do not start there.

## First deliverables (in order)

1. **Neutral backend protocol** — `open` / `query` / `exec` / `with-transaction`
   (generic functions over a backend object) + a **SQLite adapter over CL-DBI**.
2. **Minimal migration runner** — Lisp-defined migrations, `up`/`down`, tracked in a
   `schema_migrations` table. Keep it small; no framework.
3. **Ecto-ish surface** — schema/entity definitions, **changesets** (validation +
   coercion), and a basic query builder (or HugSQL-style parameterized strings to
   start — simplest first; grow later).
4. **`users` + `sessions` schema** — what a consuming app's auth needs:
   - `users(id, email UNIQUE, password_hash, created_at, updated_at)`
   - `sessions(id PK, user_id FK NULLable, data, created_at, expires_at)`
   - **Password hashing is the app's job** (via `ironclad`, argon2id/pbkdf2) — *not*
     Mnemosyne's. Mnemosyne stores the hash.

## Key integration seam — `hyperion/session`

Hyperion already ships `hyperion/session`: cookie sessions + an in-memory store,
built behind a **STORE protocol** (generic fns `store-ref` / `store-add` /
`store-del` / `store-count` / `store-list`; `memory-store` is the reference impl,
with an explicit "mnemosyne-backed store later" note).

**Mnemosyne should provide a DBI/SQLite-backed session STORE implementing that
protocol.** Check `../hyperion/src/packages.lisp` + `../hyperion/src/session.lisp` (the
sibling dir in this monorepo) for the exact generic-function signatures before
implementing. Division
of labor: **hyperion** owns session/auth *middleware* (Lack-based for the MVP);
**mnemosyne** owns *persistence*.

## Lifecycle (Atropos) — do NOT build it here

A general component/lifecycle system (**Atropos**, a standalone leaf lib) is coming,
but Mnemosyne is a *consumer*, not its home (DBs are just one resource type). For now:

- Expose clean, **start/stop-symmetric** `connect` / `disconnect` (or
  `open-pool` / `close-pool`) that allocate/free the DBI connection(s) with **no
  global side effects**.
- Shape them so a future Atropos component wraps them in one line. That is all
  Mnemosyne needs to do re: lifecycle.

## Practicalities

- **Scaffold state:** the repo already has the ASDF system, `src/packages.lisp` +
  `src/mnemosyne.lisp`, `CLAUDE.md`, README, docs/roadmap+vision, setup scripts;
  loads clean at `version "0.0.0"`. Build the protocol + SQLite adapter into that.
- **Deps to add (keep lean):** `cl-dbi` + `dbd-sqlite3` (SQLite driver); optionally
  `sxql` for a query DSL.
- **Work the `mnemosyne/` subtree** — use a git worktree per track (see the root
  `CLAUDE.md`), merge to `main` when green. `../hyperion` is a sibling dir in this
  monorepo; a consuming app lives in a separate external repo. Commit + push often so both can
  build against it.
