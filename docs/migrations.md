# App-owned migrations — the convention

How a consuming app owns its schema timeline. The **mechanism** is `mnemosyne/migrate`
(`make-migration`, `migrate`, `rollback`, `pending`, `applied-ids`); this document is the
**convention** around it, so every app does it the same low-friction way and a new version
resumes cleanly from whatever the last one applied.

The one-sentence version: **the app owns an append-only, ordered list of migrations
identified by stable ids, every serving entry point brings the database up, and framework
tables join the app's timeline through store-less DDL accessors.**

## 1. The list is append-only, and ids are the resume key

`schema_migrations` records the **id** of every migration applied. `migrate` applies only
those whose ids are absent. That makes the id a permanent contract:

- **Never renumber, rename, or edit an applied migration.** Its id is already recorded in
  every database that ran it, including production. Changing the id makes it look pending
  again; changing the SQL means databases silently disagree about what that id *means*.
- **Fix forward.** A mistake in an applied migration is corrected by appending a new
  migration, never by editing the old one.
- **Sortable ids**, because `pending` preserves list order but humans read the directory:
  `YYYYMMDD_NNN_snake_case_description`, e.g. `20260729_001_create_users`.

```lisp
(defparameter *migrations*
  (list (be:make-migration "20260729_001_create_users" "create the users table"
                           <up-sql> <down-sql>)
        (be:make-migration "20260729_002_index_users_email" "unique index on email"
                           <up-sql> <down-sql>)))
```

The list is the whole state. Order within it is the order of application; the ids are what
survive across versions.

## 2. Where migrations live

Give them their **own module**, not a corner of the app's startup file:

```
src/
  migrations.lisp     ; *migrations* -- the ordered list, append-only
  db.lisp             ; backend + ensure-db (bring-up)
  app.lisp            ; the app factory -- touches no database
```

`migrations.lisp` grows downward forever and is otherwise boring, which is the point: a
reviewer can see the entire schema history in one file, in order.

## 3. Every entry point brings the DB up; the app factory does not

This is the split that prevents the worst failure mode:

```lisp
(defun ensure-db ()                      ; called by START / SERVE / DEV -- every entry point
  (conn:with-connection (c (backend))
    (values (migrate:migrate (backend) c *migrations*)
            (seed c))))

(defun make-app (&key dev) ...)          ; touches NO database
```

Why it matters: an app usually grows a *second* entry point — a plain `serve` and a
hot-reload `dev`. It is easy for the second to call only the app factory and skip bring-up,
and the result is not a crash. The pages render perfectly against a database with no schema
and no accounts, so it presents as **"login silently doesn't work"** with nothing in any
log. Keeping bring-up in the entry points and out of the factory makes that mistake
impossible to make quietly — and lets a test suite build the app with no database at all.

## 4. Say what bring-up did

An idempotent seed creates only what is missing, so **the run that creates something is the
only run that can report it**. Return it and announce it:

```lisp
(multiple-value-bind (applied seeded) (ensure-db)
  (when applied (format t "~&[db] applied ~{~A~^, ~}~%" applied))
  (when seeded  (format t "~&[db] seeded ~{~A~^, ~}~%" seeded)))
```

In a real app the seeded principals carry one-time credentials. A credential that only
scrolls past in a log leaves nobody able to sign in — which is a first-run experience
failure, not a logging one.

## 5. Framework tables join the app's timeline

A framework aux system that owns a table exposes its DDL **store-lessly**, so the app folds
it into its own list under an **app-assigned id** rather than calling an `ensure-schema`
that migrates behind the app's back:

```lisp
(be:make-migration "20260729_003_hyperion_users" "identity store"
                   (auth:users-ddl :dialect :sqlite)      ; store-less accessor
                   "DROP TABLE hyperion_users")
```

`hyperion/auth-db:users-ddl` is the reference for this pattern. **Any aux system that owns
a table should provide one**: the app's timeline stays the single source of truth for what
exists in its database, and `schema_migrations` stays an honest record.

The convenience path (`:ensure t`, which creates tables on connect) is for tests and quick
starts. An app that owns migrations should not use it — two things creating tables is how
databases and `schema_migrations` drift apart.

## 6. Up, down, and dialect

- **Write the `down`.** Even if you never roll back in production, `rollback` is how you
  iterate locally without deleting the database file.
- Some migrations are genuinely irreversible (a destructive backfill). Say so in the down —
  a `SELECT` that raises, or a comment — rather than leaving it silently empty.
- **Dialect belongs to the app, not the migration.** Build the list from the backend's
  dialect once, so the same set serves SQLite locally and Postgres in production:

```lisp
(defun migrations (&key (dialect :sqlite)) (list ...))    ; dialect-parameterized
```

## 7. Generated DDL is optional — raw SQL always works

`make-migration` takes SQL **strings** and always will. Raw SQL is the escape hatch for
vendor-specific DDL and anything a generator does not cover, and a migration list may mix
generated forms and hand-written strings freely.

What is available when you want it:

- `schema:schema-ddl` — `CREATE TABLE` derived from a `defschema`, so the shape is not
  hand-written twice.
- `ddl:ddl` / `ddl:ddl-statements` — indexes, drops, and `ALTER TABLE` as data
  (see the [mnemosyne user guide](../mnemosyne/docs/user-guide.md)). `ddl-statements`
  returns a **list**, because one `:alter-table` with three actions is three statements.

```lisp
(be:make-migration "20260729_002_index_users_email" "unique index on email"
                   (ddl:ddl '(:create-index :name :idx_users_email :on :users
                              :columns (:email) :unique t)
                            :dialect "sqlite")
                   (ddl:ddl '(:drop-index :name :idx_users_email) :dialect "sqlite"))
```

Dialect limits (SQLite has no `CASCADE` or `DROP CONSTRAINT`; XTDB 2 is schemaless) signal
`ddl:unsupported-ddl` when you **render**, so a migration author sees the problem instead of
a driver failing partway through a run.

## 8. The defschema is the present; the migration list is history

This is the one that bites, and it bites on a database you do not have. `schema:schema-ddl`
derives `CREATE TABLE` from a **live, mutable** `defschema`, and a migration that calls it is
evaluated when migrations **run**, not when the migration was **written**. So editing the
defschema silently rewrites history for everyone who has not caught up.

Add one column to an existing table and all three obvious moves are wrong:

| what you do | existing database | fresh database |
|---|---|---|
| edit the defschema **and** write an `ALTER` | correct | **fails** — the original migration now creates the column, then the `ALTER` hits a duplicate |
| edit the defschema **only** | never gets the column | correct |
| write the `ALTER`, leave the defschema alone | correct | correct — but the defschema now describes something the table is not |

Note which one is loud. The duplicate-column failure only happens on a **fresh** database —
the one database whoever made the change is least likely to have. It passes locally and
breaks for the next person to clone.

**The model that survives:**

> The **defschema** is the **present**. The **migration list** is **history**.
> A fresh database replays history and must **arrive at** the present.

Say it that way and the third row stops being a workaround and becomes the rule: you never
edit an applied migration, so between an `ALTER` and the definition it changed, the
definition is the one that moves.

### A value a `defschema` reads from configuration (pre-publication issue 258)

A field spec's option values are **evaluated**, so a width can come from configuration:

```lisp
(defparameter +embedding-width+ 1536)     ; or read it from the environment

(schema:defschema chunk (:table "chunks")
  (:id        :uuid   :primary t)
  (:embedding :vector :dimensions +embedding-width+))
```

That changed in pre-publication issue 258 — the specs used to be quoted whole, so every value had to be a literal.
**If you are upgrading and a declaration passed a bare symbol or a list you meant as data,
quote it** (`:default (quote (:a :b))`); self-evaluating values — keywords, strings, numbers,
`t` — are unaffected, which is every option in every declaration in this tree.

**The rule that goes with the capability, and it is this section's rule again:** a migration's
SQL is **pinned** — generated once and committed as text — never re-derived from a
config-resolved schema at each deploy. §8 above already says a migration that calls
`schema-ddl` is evaluated when migrations *run*; a width that varies by environment turns that
from a history-rewriting hazard into two deployments that disagree about a column type. Verify
at boot (below); do not re-derive at deploy.

### Measure the arrival — don't assume it

The last line of that model is a claim, and `mnemosyne/introspect` checks it against the
actual database rather than taking your word for it:

```lisp
(defun ensure-db ()
  (conn:with-connection (c (backend))
    (migrate:migrate (backend) c *migrations*)
    (intro:verify-schema (backend) c (schema:find-schema 'profile))))   ; replay ARRIVED?
```

`verify-schema` signals `intro:schema-drift` — naming every column that is missing, extra, or
of the wrong type — and offers a `continue` restart. Put it after `migrate` in bring-up, or
in the app's test suite, and the fresh-database-only failure becomes a startup failure on
**every** database, including yours.

- `intro:table-columns` — what the table actually has, read from `information_schema` /
  `pragma_table_info`.
- `intro:diff-table` / `intro:schema-diff` — the difference as **data** (`drift-missing`,
  `drift-extra`, `drift-mismatched`). `schema-diff` is pure: it takes the columns, so the
  comparison is testable with no database.
- `intro:report-drift` — the same thing, printed for a human.
- `verify-schema … :allow-extra t` — for an app that has **deliberately** let the table run
  ahead of the definition. A check with only an off switch gets switched off; this keeps the
  missing-and-mismatched half working.

Defaults are read but **never** diffed: Postgres rewrites a default into its own normal form
(`true`, `'x'::text`, `nextval(…)`), so comparing the text would report drift on tables that
are perfectly correct, and a checker that cries wolf gets ignored.

### Derive the `ALTER` instead of writing it twice

`intro:drift-ddl` turns the difference back into `mnemosyne/ddl` forms. Edit the defschema,
ask what it would take to get there, and paste **that** into a **new** migration:

```lisp
(intro:drift-ddl (intro:diff-table (backend) c (schema:find-schema 'profile)))
;; => ((:alter-table "profiles" (:add-column :nickname :string)))
```

The already-applied migration is never touched, and the `ALTER` was still derived from the
schema rather than hand-written. Three things it will not do for you, on purpose:

- **A type change generates nothing.** It is a table rebuild on SQLite and a data-losing
  decision on Postgres. The mismatch is in the drift; you write the migration.
- **An extra column generates a `DROP` only under `:include-drops t`.** The usual cause of an
  extra column is a definition that has not caught up — destroying data over that would be a
  poor trade.
- **`ADD COLUMN … NOT NULL` with no default still fails on a table with rows.** Add it
  nullable, backfill, then set `NOT NULL`. Only you know what to backfill with.

## 9. SQLite specifics worth knowing

- **The parent directory is created for you.** `conn:connect` ensures it, so `./data/app.db`
  works on a first run. (SQLite creates the file but never the folder — that bare
  `unable to open database file` was this.) Keep db files in their own gitignored directory.
- `ALTER TABLE` understands only add/drop/rename column and rename table. Anything else —
  dropping a constraint, changing a column type — is the **table-rebuild dance**: create the
  new table, copy, drop the old, rename. Write that as an explicit migration.
- Foreign keys are **off by default** in SQLite; enable per connection with
  `PRAGMA foreign_keys = ON` if you rely on them.

## Checklist for a new DB-backed app

- [ ] `src/migrations.lisp` holds one append-only, ordered `*migrations*`.
- [ ] Ids are `YYYYMMDD_NNN_description` and are never edited once applied.
- [ ] `ensure-db` migrates + seeds, returns what it did, and is called by **every** entry
      point.
- [ ] The app factory touches no database.
- [ ] Framework tables enter through store-less DDL accessors under app-assigned ids.
- [ ] Every migration has a `down`, or says why it cannot.
- [ ] The db file lives in a gitignored directory.
- [ ] Bring-up calls `intro:verify-schema` after `migrate` — replaying history has to
      arrive at the defschema, and that is a claim worth checking on every database.
- [ ] A column added to a `defschema` got a **new** migration; the applied one was not
      touched. `intro:drift-ddl` writes the `ALTER` for you.
