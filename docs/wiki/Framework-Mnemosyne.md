# Mnemosyne — data and persistence

**The bitemporal data layer for Common Lisp / Coalton — Ecto-flavored, backend-neutral,
and built on one conviction: a query is *data*, not a macro.**

Mnemosyne is named for the Titaness of **memory**, mother of the Muses — a store that can
remember all of history: **valid-time** (when a fact was true) *and* **transaction-time**
(when the system learned it). It is the ecosystem's one real database dependency.

---

## What it is, and why it exists

Every stack eventually grows a persistence story. The usual one is an ORM: an object graph
that lazily pretends to be a database, plus a migration framework, plus a query DSL that is
really a string builder wearing a costume. The maintainer had lived that story on the JVM
and wanted a different one.

Mnemosyne's thesis: **one cohesive, Coalton-typed, backend-neutral data layer** with no
lazy object graph anywhere in it. The inspiration is **Ecto** (Elixir) — schema +
changesets + a composable query language — explicitly *not* Hibernate or ActiveRecord. You
say what you want as data; the layer compiles it to parameterized SQL; nothing is hidden
behind proxies, identity maps, or session flushes.

Three commitments follow from that, and they shape everything below:

1. **Typed core in Coalton, effectful shell in CL.** Backend descriptors and field types
   are compile-time-checked Coalton; connections, IO, and effects are CL. **No IO in
   Coalton.**
2. **Pluggable backends behind a neutral protocol** over **CL-DBI**. No backend shape leaks
   above the protocol.
3. **Bitemporality is a *capability*, not the default.** Native in XTDB 2; on SQL backends
   it is the **SQL:2011 temporal model** (valid-time period columns + system-versioning),
   **opt-in per entity** so plain tables stay plain. Neither Postgres nor SQLite has native
   `WITH SYSTEM VERSIONING`, so mnemosyne implements the pattern rather than pretending the
   database provides it.

### The three-tier memory stack

Do not conflate these layers — the distinction holds across the ecosystem:

```
Praxeon    — the agent: recall + context-budget economics (praxeological layer)
   ▲
Kairos     — a dedicated bitemporal knowledge-GRAPH store, built on ...
   ▲
Mnemosyne  — general bitemporal DB abstractions (connection / schema / query / migrate)
```

**Mnemosyne is the DB; Kairos is the graph on it; Praxeon is the agent on Kairos.** The
budget economics live in Praxeon, never here. Thematically: **Aion** (time) · **Kairos**
(the opportune moment) · **Mnemosyne** (memory). Kairos is seeded today inside
`praxeon/src/context.lisp`; whether it eventually becomes its own repo, stays in Praxeon,
or lands as a Mnemosyne extension is still open — the house pattern is *grow it where it's
seeded, split when justified*.

---

## Where it sits in the DAG

```
aion → cons → mnemosyne → elenchon → hyperion → praxeon
```

Mnemosyne is a **mid-layer** framework. Apps and higher frameworks consume it; it depends
only on a DB driver, never on the web framework. That direction matters at the seam with
Hyperion: **hyperion owns session/auth middleware; mnemosyne owns persistence.** Hyperion
already ships sessions behind a `store` protocol with an in-memory reference
implementation, and the durable implementation of that protocol is mnemosyne's to provide —
not the other way around.

Lifecycle is deliberately *not* built here either. A general component system (**Atropos**,
a planned leaf lib) is coming, and mnemosyne is a consumer of it, not its home. What
mnemosyne owes the world is clean, **start/stop-symmetric** `connect` / `disconnect` with
no global side effects, shaped so a future Atropos component can wrap them in one line.

---

## Status

| Area | State |
|---|---|
| Connection / transactions over CL-DBI | **Works** — `connect`/`disconnect`, `with-connection`, `with-transaction`, `db-error` |
| SQLite backend | **Works** (zero-ops dev; `:memory:` supported) |
| Postgres backend | **Works** over the wire (`dbd-postgres`/cl-postgres, no libpq) |
| Query builder (`sql`) | **Works** — CRUD, joins, aliases, aggregates, subqueries, `RETURNING`, upserts |
| `parse` (SQL string → query data) | **Works** — round-trips across the supported surface |
| Migration runner | **Works** — `make-migration`, `migrate`, `rollback`, `pending`, `applied-ids` |
| `defschema` + `schema-ddl` | **Works** (per-dialect type resolution) |
| Changesets (`cast` → `validate-*` → `insert!`/`update!`) | **Works** |
| Time-ordered identity (`new-id`, `touch!`, typed `DTO`/`touch`) | **Works** — 20k + 40k-thread collision probes green |
| XTDB 2 | **Connection de-risked only** — `SELECT 1` verified over PG wire; the `:xtdb` dialect is a provisional seam |
| Connection pooling | **Not built** — a connection is not safe to share across concurrent requests |
| CTEs, `UNION`, window functions | **Not built** — reach them with `(:raw …)` |
| Bitemporal API (`AS OF`, history, erasure) | **Not built** — design open |
| `mnemo` CLI | **Planned** |

Version is still `0.0.0` and the surface can move. But the sentence "no data-layer code
yet," true when the framework was founded, is long obsolete: the connection, query builder,
parser, migrations, schemas, changesets, and identity layers are all real and under test.

---

## Design narrative

### Queries are data, not macros — and why that is the whole point

A mnemosyne query is a **plist of clauses whose predicates are s-exprs**, compiled by an
ordinary *function* into a parameterized SQL string plus an ordered parameter list:

```lisp
(mnemosyne/query:sql '(:select (:id :email) :from (:users)
                       :where (:and (:= :email "a@x") (:> :id 10))
                       :order-by ((:id :desc)) :limit 20))
;; => "SELECT id, email FROM users WHERE (email = ? AND id > ?) ORDER BY id DESC LIMIT ?"
;;    ("a@x" 10 20)
```

The alternative in Common Lisp is the macro DSL — Postmodern's S-SQL being the well-known
example. A macro fixes the query at *compile* time. That is fine until the day an app needs
to add a `:where` clause conditionally, merge two fragments, store a query in a table, ship
one over the wire, or let a user compose filters. Then a macro DSL forces you back to
string concatenation, which is exactly where injection bugs live.

Because `sql` is a function over quoted data, a query is a **plain value**. You can build it
programmatically, inspect it, diff it, pass it around, and compile it on demand. This is the
same bet [HoneySQL](https://github.com/seancorfield/honeysql) makes in Clojure — with one
adaptation: Clojure has literal maps and vectors (`{:select […]}` / `[:= :id 1]`) and CL has
neither, so the encoding is **plists + lists** (`(:select (…) :where (:= :id 1))`).
Keywords carry over unchanged, which is why the two dialects read so similarly.

The safety property falls out of **one convention**: *a keyword or symbol is an identifier;
anything else is a value.* Identifiers are emitted; values are **always bound as
parameters**, never interpolated. To use a keyword-shaped literal as a value, pass it as a
string. `(:raw "…")` is the escape hatch for the long tail — and, being verbatim, it is the
builder's only injection surface, so it is documented as such.

There is also an **inverse**, which is unusual for a query builder: `parse` turns a SQL
string back into the query plist. It round-trips across the entire supported surface —
joins, aliases, aggregates, subqueries, `EXISTS`, `IN (SELECT …)`, `RETURNING`, `ON
CONFLICT` upserts — so `(sql (parse s) :inline t)` reproduces `s` and `(parse (sql q :inline
t))` reproduces `q`. That is not a party trick: it is how someone who knows the SQL but not
the data form onboards, and it is a genuine test oracle for the builder. Constructs outside
the subset (CTEs, `UNION`, window functions) **signal rather than mis-parse** — a deliberate
choice to fail loudly instead of silently producing something almost right. The `:inline`
rendering exists for round-tripping, display, and logging only; **never execute inlined SQL
with untrusted values.**

### `defschema` + `schema-ddl` — one source of truth for shape

A schema names a table and its typed fields. The field *types* are the Coalton core
(`mnemosyne/field`); `defschema`, casting, and validation are the CL shell:

```lisp
(mnemosyne/schema:defschema user (:table "users")
  (:id      :uuid      :primary t)
  (:email   :string    :required t)
  (:name    :string)
  (:age     :integer)
  (:active  :boolean   :default t)
  (:created-at :timestamp))
```

`schema-ddl` then *derives* the `CREATE TABLE`, resolving types per dialect (`:uuid` → `UUID`
on Postgres, `TEXT` on SQLite; `:integer` → `BIGINT`/`INTEGER`). The rule this enforces is
simple and unglamorous: **do not hand-write the table shape twice.** The DDL still lives as
raw SQL *inside* a migration — but it comes from the schema, so schema and table cannot
drift apart by transcription error. (XTDB 2 is schemaless, so `schema-ddl` signals for
`"xtdb"` rather than emitting nonsense.)

### Changesets — the funnel external data must pass through

Ecto's best idea is that untrusted input never reaches the database directly; it goes
through a **changeset**, a value that accumulates casts and errors and is only then applied:

```lisp
(let ((c (mnemosyne/changeset:cast 'user params '(:email :name :age :active))))
  (setf c (mnemosyne/changeset:validate-required c '(:email)))
  (setf c (mnemosyne/changeset:validate-format   c :email (lambda (s) (find #\@ s))))
  (setf c (mnemosyne/changeset:validate-number   c :age :gte 18 :lte 120))
  (if (mnemosyne/changeset:changeset-valid-p c)
      (mnemosyne/changeset:insert! c connection)
      (mnemosyne/changeset:changeset-errors c)))
```

Two protections, both structural rather than advisory:

- **`cast` takes only the fields you permit** — safe mass-assignment by construction. A
  form post that smuggles `:admin t` cannot set it if `:admin` is not in the permitted list.
- **Each raw value is cast to its field's type** (`"42"` → `42`, `"yes"` → `1`); a bad cast
  records an error rather than reaching SQL.

Validators thread the changeset **immutably**, accumulating errors instead of throwing on
the first one — `validate-required`, `validate-format`, `validate-length`,
`validate-number`, `validate-inclusion`, `validate-exclusion`, and the general
`validate-change`. Note `validate-format` takes a **predicate**, not a regex: that keeps the
dependency list honest (pass a `cl-ppcre` scan if you already have it) and keeps the
validator interface open.

The bridge back to queries is explicit: `to-insert` / `to-update` produce a query plist,
`insert!` / `update!` compile and run it, and all four **signal `changeset-invalid`** on an
invalid changeset. Errors are *data* right up to the edge, where they become a condition.
So a signup handler is `cast` → `validate-*` → `insert!`, a login lookup is a `fetch` on the
same schema's table, and neither touches raw SQL.

### Migrations — and the open question about them

Today a migration carries raw up/down SQL, applied by a runner that takes pending
migrations in id order, each in a transaction, recording it in `schema_migrations`. It is
idempotent, and it is intentionally small — **no framework**:

```lisp
(mnemosyne/backend:make-migration
  "20260723_001_users" "users"
  "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT UNIQUE NOT NULL, …)"
  "DROP TABLE users")
```

with `migrate`, `rollback :steps n`, `pending`, and `applied-ids` around it.

The **design direction**, preserved here because it is the most interesting unfinished
thought in the framework, is to do to migrations what was already done to queries: make
them **data, not SQL strings**. Express a migration as pure CL data —
`(:create-table :contacts (:_id :uuid :primary) (:name :string :not-null) …)`,
`(:add-column …)`, `(:add-index …)` — compiled to DDL per dialect, with the **`down`
derived** where it can be (drop-table, drop-column) so migrations are **reversible by
construction** rather than by discipline.

The payoff is not aesthetic. It is that migrations would then stay **in sync with the typed
schema**: `defschema` + `schema-ddl` are already the seed of this (a schema renders its own
`CREATE TABLE`), so a migration could be *generated from a schema diff*.

The open questions, honestly stated:

- How much is **generated** versus **authored**? A fully generated migration set is
  seductive and historically brittle.
- How do `up`/`down` derive and round-trip? Some operations have no lossless inverse.
- **Identifier quoting.** Hyphenated keys — the entity-metadata `:utc-time-created` is the
  live example — are not SQL-safe unquoted today.
- **XTDB opts out entirely**, being schemaless. Whatever the model, it must degrade
  gracefully for a backend with no DDL at all.

### The backend protocol and the SQLite → Postgres → XTDB 2 progression

The backend is a small neutral protocol — a typed `mnemosyne/backend` core plus
`mnemosyne/conn` IO over **CL-DBI**, the DB-independent substrate. The progression was
decided deliberately, **embedded-first**:

| # | Backend | Why, and when |
|---|---|---|
| 1 | **SQLite** | The zero-ops transactional MVP. An app can ship as a binary plus a `.db` file — no cloud DB to operate on day one. |
| 2 | **Postgres** | Production. Because one CL-DBI SQL adapter covers both, this step is **mostly a connection-string change**. |
| 3 | **XTDB 2** | Bitemporal work (and Kairos). A *separate* adapter, arriving when bitemporality is actually needed. |

Two things this ordering buys, beyond convenience. It defers the unresolved XTDB **ops**
question (self-hosted JVM + object storage — there is no managed XTDB) until it genuinely
matters. And it keeps a decoy off the table: **DuckDB is OLAP** — a plausible *analytics*
backend some day, never the transactional core. Do not start there.

`?` placeholders are portable across SQLite and Postgres (verified), which is what makes the
first two rungs of that ladder cheap.

### XTDB 2 caveats — preserved, because they are easy to forget

XTDB 2 speaks the **PostgreSQL wire protocol**, and mnemosyne's Postgres path connects to
it **unchanged** — verified: `connect` + `SELECT 1` over the wire against
`ghcr.io/xtdb/xtdb`. That de-risks the eventual bitemporal migration to "point the
connection at XTDB 2, no new driver."

**But XTDB 2 is a distinct *dialect*, not "just Postgres."** It is `:xtdb` in
`mnemosyne/query`, never `:postgres`. The differences that bite:

| Caveat | Consequence |
|---|---|
| **No DDL — schemaless.** No `CREATE TABLE`/`ALTER TABLE`; tables spring into existence on insert. | The DDL migration model **does not apply**. `schema_migrations` DDL and `CREATE TABLE …` both fail. XTDB "migrations" are semantic / data-shape concerns, a different problem from the SQL migration runner. |
| **Parameters differ.** A parameterized `INSERT` via CL-DBI's `?` binding failed with *"0 parameters expected, N received"* — XTDB's pgwire prepares params differently from stock PG. | The `:xtdb` `$N` placeholder path is a **provisional seam, not verified end-to-end**. Getting params right is part of the future adapter. |
| **`INSERT` is already an upsert on `_id`.** Re-inserting an existing `_id` writes a new temporal version; there is no `ON CONFLICT`. | The builder **signals** if an `:xtdb` query carries `:on-conflict`. App-level "upsert" on XTDB is just `INSERT`. |
| **`_id` is required and is the primary key.** No `SERIAL`/autoincrement. | You supply `_id` yourself — which is exactly what `new-id` is for. |
| **No `RETURNING`.** DML goes to the tx log. | The builder **signals** on `:returning` for `:xtdb`; read the written value back with a separate query. |
| **`UPDATE`/`DELETE` are temporal**, and `ERASE` hard-removes a row across all time. | No SQL-standard analogue for `ERASE`. SELECT-side joins, subqueries, and aggregates carry over normally. |
| **Transaction semantics differ** (append-only tx log; reads vs writes). | `with-transaction` may not behave the same. Verify before relying on it. |
| **Temporal SELECT is the whole point** — `FOR VALID_TIME AS OF …`, `FOR SYSTEM_TIME …`, `FOR ALL VALID_TIME`. | The `:xtdb` dialect layers these on later; the shape to emulate is HoneySQL's `doc/xtdb.md`. |

The stance, plainly: **connection de-risked; full XTDB 2 support is a later
dialect/adapter.** Near term, ship on Postgres (working) and SQLite (dev).

### Time-ordered identity — and why mnemosyne owns a clock

> *"The best serial ID generator is time itself."*

`mnemosyne/id:new-id` mints three things at once:

```lisp
(mnemosyne/id:new-id)
;; => "1f1883e2-6b9e-…"               ; RFC-9562 v6 UUID (lexically sortable = time-ordered)
;;    140042863943625630              ; vid — the monotonic Gregorian-100ns tick
;;    "2026-07-25T15:33:14.3625630Z"  ; UTC instant, ISO-8601, 100-ns precision
```

The elegance is that the UUID's embedded 60-bit timestamp **is** the `vid`. One quantity,
three renderings: a globally unique id, a monotonic bigint version/serial you can safely
`ORDER BY`, and a human-readable instant. UUID **v6** puts the timestamp
most-significant, so lexical order equals time order — which is also why it indexes well,
unlike v4's random scatter.

**Why not just use a UUID library?** This was tested, not assumed. The whole scheme rests on
the `vid` being *unique and strictly monotonic under concurrent burst generation* — and a
stock library does not give that. **frugal-uuid's default v6 produced only 2 distinct
timestamps across 20,000 generations**: its timestamp field collides en masse, because it
reads the wall clock at whatever resolution the platform offers and does nothing to
disambiguate ties. A `vid` that repeats is not a serial.

So mnemosyne **owns the clock**. `next-vid` is a locked, strictly-increasing Gregorian-100ns
counter — clj-uuid's trick — that bumps by one within a coarse real-clock tick, so
successive calls never collide however fast they come. Assembling the 16-octet v6 around
that is pure bit-work, so the port is **dependency-free** (SBCL's `sb-thread` and
`sb-ext:get-time-of-day` are all it touches). The property is enforced in the suite rather
than asserted in a comment: **20,000 back-to-back and 40,000 across threads, zero
collisions.**

That leaves two ways to stamp an entity, matching the ecosystem's two halves:

**`touch!`** — the dynamic, Clojure-flavored path. Stamp a hash-table "universal object"
with keyword keys. No `:_id` yet means **create** (full stamp: `_id`, `vid`,
`utc-time-created`/`-modified`, `created-by`, `modified-by`); an existing `:_id` means
**update** (new `vid`, new `utc-time-modified`, new `modified-by`, `_id` and created fields
preserved). It mutates and returns the table — the CL idiom for a `!` operation; copy first
if you want Clojure's persistent semantics.

**The `DTO` typeclass** — the typed path. A Coalton `Meta` ADT plus a `DTO` typeclass makes
entity metadata **compile-time-checked**: only a type that implements `get-meta` /
`with-meta` can be touched, and `touch` is **pure**, returning a new value. This is the
typesafe upgrade over assoc-ing metadata onto any old map. Because `touch` is
typeclass-constrained, calling it from CL needs a monomorphic wrapper — see
`docs/coalton-patterns.md` §5.

Both were ported from a consuming app's `db/core`, and the port **fixes a bug in the
original**: its create branch dropped the freshly minted UUID and wrote an empty `_id`.
Preserving the behavior while fixing the defect is the reason the port has tests rather than
a changelog entry.

---

## Usage

```lisp
(ql:quickload :mnemosyne)   ; first load compiles Coalton — minutes, then cached

(defvar *be* (mnemosyne/backend:make-sqlite "app.db"))   ; or ":memory:"
;; prod: (mnemosyne/backend:make-postgres "localhost" 5432 "app" "user" "pass")

(mnemosyne/schema:defschema user (:table "users")
  (:id :uuid :primary t) (:email :string :required t) (:name :string))

(mnemosyne/conn:with-connection (c *be*)
  ;; migrate (DDL derived from the schema, not hand-written twice)
  (mnemosyne/migrate:migrate
   *be* c (list (mnemosyne/backend:make-migration
                 "20260723_001_users" "users"
                 (mnemosyne/schema:schema-ddl (mnemosyne/schema:find-schema 'user)
                                              :dialect "sqlite")
                 "DROP TABLE users")))

  ;; write through a changeset — external params never reach SQL uncast
  (let ((cs (mnemosyne/changeset:cast 'user params '(:email :name))))
    (setf cs (mnemosyne/changeset:validate-required cs '(:email)))
    (when (mnemosyne/changeset:changeset-valid-p cs)
      (mnemosyne/changeset:insert! cs c)))

  ;; read with the data query language
  (mnemosyne/query:fetch c '(:select (:id :email) :from (:users)
                             :where (:= :email "a@x"))))
```

A fuller tour — every operator, joins, subqueries, upserts, dialects, `parse` — is in
`mnemosyne/docs/user-guide.md`.

---

## Roadmap

The roadmap is **not** duplicated here. Work items live on the board, and this page keeps
only the reasoning behind them.

- **Board** — https://github.com/orgs/codelisperer/projects/1
- **Open mnemosyne issues** —
  https://github.com/codelisperer/ouranos/issues?q=is%3Aissue+is%3Aopen+label%3A%22pkg%3Amnemosyne%22

The questions those issues are working through, for context: the **bitemporal API** surface
(how valid-time / tx-time appear in schema and queries — `AS OF`, history, erasure);
**migrations as data** with derived `down`; **connection pooling and thread-safety**; the
**`mnemo` CLI** (migrate, db up/down, console, seed, gen); **EDN interop** for XTDB 2's EDN
surface versus staying JSON-first via jzon (there is no mature EDN library in the pinned
Quicklisp dist); and the remaining SQL surface — CTEs, `UNION`, window functions, and XTDB's
temporal `FOR VALID_TIME` SELECT.

Explicit **non-goals**: a full lazy-graph ORM, and anything requiring Node or a JVM in the
application's own runtime.

---

## See also

- [Framework Hyperion](Framework-Hyperion.md) — the web framework; sessions behind a `store` protocol that a
  mnemosyne-backed store implements
- [Framework Praxeon](Framework-Praxeon.md) — Kairos and the agent memory built on top of this layer
- [Home](Home.md) — the ecosystem overview and the DAG rule
- In the repository: `mnemosyne/docs/user-guide.md`, `mnemosyne/docs/xtdb-notes.md`,
  `docs/coalton-patterns.md`
