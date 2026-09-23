# Mnemosyne User Guide

Mnemosyne is the **data layer**: a typed backend core (Coalton) + an effectful CL shell
over **CL-DBI** — **SQLite** for zero-ops dev, **PostgreSQL over the wire** for prod, XTDB 2
(PG wire) later. This guide covers loading, connecting, migrations, and — the focus — the
**HoneySQL-style query language**.

## Load

After the repo-root seed (`sbcl --dynamic-space-size 4096 --script bootstrap.lisp`), from
any REPL:
```lisp
(ql:quickload :mnemosyne)   ; first load compiles Coalton (~minutes, cached; big heap)
```

## Connect

Build a typed backend, then open a connection. Backends are constructed from CL scalars:
```lisp
(defvar *be* (mnemosyne/backend:make-sqlite "app.db"))                 ; or ":memory:"
;; prod: (mnemosyne/backend:make-postgres "localhost" 5432 "app" "user" "pass")

(mnemosyne/conn:with-connection (c *be*)        ; opens + closes (start/stop-symmetric)
  (mnemosyne/conn:exec  c "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
  (mnemosyne/conn:exec  c "INSERT INTO t (name) VALUES (?)" "Ann")     ; ? bind params
  (mnemosyne/conn:query c "SELECT id, name FROM t"))                   ; -> list of plists
```
- `connect` / `disconnect` are the explicit pair; `with-connection` is the scoped form.
- `with-transaction` scopes a transaction (commit on normal exit, roll back on error).
- Failures signal `mnemosyne/conn:db-error` (wrapping the driver's) — the condition system,
  not return codes.
- **`?` placeholders are portable** (SQLite and Postgres both — verified). Never interpolate
  values into SQL.
- **No connection pool yet**: a connection isn't safe to share across concurrent requests —
  use `with-connection` per request/operation for now.
- **A file-backed SQLite path gets its parent directory created.** `"./data/app.db"` is an
  ordinary layout, but SQLite creates the *file* and never the *folder*, so a first run
  failed with a bare `unable to open database file` naming neither the path nor the cause.
  `connect` now ensures the parent exists. `":memory:"` and `file:` URIs are left alone.

## Migrations

Migrations are Lisp data; the runner applies pending ones in id order, each in a
transaction, recording it in `schema_migrations`. Idempotent.
```lisp
(defparameter *migrations*
  (list (mnemosyne/backend:make-migration
         "20260723_001_users" "users"
         "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT UNIQUE NOT NULL,
                              password_hash TEXT NOT NULL)"
         "DROP TABLE users")))

(mnemosyne/conn:with-connection (c *be*)
  (mnemosyne/migrate:migrate  *be* c *migrations*)      ; -> ids applied (nil if up to date)
  (mnemosyne/migrate:rollback *be* c *migrations* :steps 1))
```
Also `mnemosyne/migrate:pending` and `applied-ids`. (XTDB 2 is schemaless — DDL migrations
don't apply there; see [`xtdb-notes.md`](xtdb-notes.md).)

**The mechanism is here; the convention is [`docs/migrations.md`](../../docs/migrations.md)**
— append-only ids as the resume key, bring-up in every entry point but never the app
factory, framework tables joining an app's timeline via store-less DDL accessors, and the
SQLite specifics.

## The query language (HoneySQL-style)

A query is **Lisp data** — a plist of clauses whose predicates are s-exprs — compiled to a
**parameterized SQL string + an ordered param list**. Values are *always bound*, never
interpolated, so queries stay injection-safe, composable, and inspectable. It mirrors
[seancorfield/honeysql](https://github.com/seancorfield/honeysql).

```lisp
(mnemosyne/query:sql '(:select (:id :email) :from (:users)
                       :where (:and (:= :email "a@x") (:> :id 10))
                       :order-by ((:id :desc)) :limit 20))
;; =>  "SELECT id, email FROM users WHERE (email = ? AND id > ?) ORDER BY id DESC LIMIT ?"
;;     ("a@x" 10 20)
```

### The one convention
A **keyword or symbol is an identifier** (column/table name); **anything else is a value**
(bound as a param). To use a keyword-like literal as a value, pass it as a string.
`(:raw "sql")` is the escape hatch (emitted verbatim, no params — the only injection
surface, so use it with care).

Identifiers: keywords are lowercased (`:email` → `email`); dotted keywords pass through
(`:u.email` → `u.email`); `:*` → `*`.

### Statements
| Clause set | Statement |
|---|---|
| `:select` `:from` `:join` `:where` `:group-by` `:having` `:order-by` `:limit` `:offset` | SELECT |
| `:insert-into` `:values` (list of plists; multi-row) `:on-conflict`/`:do-update`/`:do-nothing` `:returning` | INSERT |
| `:update` `:set` (plist) `:where` `:returning` | UPDATE |
| `:delete-from` `:where` `:returning` | DELETE |

`:select` defaults to `(:*)`. `:order-by` specs are a column, or `(column :asc|:desc)`.
A **select item** is a column, a function expr, or `(:as expr alias)` → `expr AS alias`.
A **`:from`/`:join` item** is a table, or `(:as source alias)` where `source` is a table
*or a subquery* (a nested `:select`).

### Operators (in `:where` / `:having` / select items)
- **Comparison:** `(:= a b)`, `(:<> a b)` / `(:!= a b)`, `(:> a b)`, `(:< a b)`, `(:>= a b)`, `(:<= a b)`
- **Logical:** `(:and e …)`, `(:or e …)`, `(:not e)`
- **Predicates:** `(:like col pattern)`, `(:in col (v …))`, `(:in col (:select …))`,
  `(:between col lo hi)`, `(:is-null col)`, `(:is-not-null col)`, `(:exists (:select …))`
- **Functions / aggregates:** `(:count :*)`, `(:sum col)`, `(:avg col)`, `(:min col)`,
  `(:max col)`, `(:coalesce a b)`, `(:lower col)`, `(:upper col)`, … and
  `(:count (:distinct col))`; arbitrary calls via `(:call "fn" args…)`
- **Upsert refs:** `(:excluded col)` → `EXCLUDED.col` (inside `:do-update`)
- **Escape:** `(:raw "…")`

### Examples
```lisp
;; INSERT (multi-row) -> "INSERT INTO users (email, name) VALUES (?, ?), (?, ?)"
'(:insert-into :users :values ((:email "a@x" :name "Ann") (:email "b@x" :name "Bob")))

;; UPDATE -> "UPDATE users SET name = ?, email = ? WHERE id = ?"   ("X" "z@x" 1)
'(:update :users :set (:name "X" :email "z@x") :where (:= :id 1))

;; DELETE + IN -> "DELETE FROM users WHERE id IN (?, ?, ?)"        (1 2 3)
'(:delete-from :users :where (:in :id (1 2 3)))

;; nested predicates
'(:select (:*) :from (:orders)
  :where (:and (:>= :total 100) (:or (:= :status "paid") (:is-null :refunded_at))))
```

### Joins, aggregates, subqueries, upserts
```lisp
;; JOINs -- :join is an ordered list of (KIND source [on-expr]); KIND is
;; :inner | :left | :right | :full | :cross; source may be aliased or a subquery.
'(:select (:u.name :o.total) :from ((:as :users :u))
  :join ((:inner (:as :orders :o)   (:= :u.id :o.user_id))
         (:left  (:as :payments :p) (:= :o.id :p.order_id)))
  :where (:> :o.total 100))
;; SELECT u.name, o.total FROM users AS u
;;   INNER JOIN orders AS o ON u.id = o.user_id
;;   LEFT JOIN payments AS p ON o.id = p.order_id WHERE o.total > ?

;; Aggregates + GROUP BY / HAVING + aliases + DISTINCT
'(:select ((:as (:count :*) :n) (:as (:sum :total) :gross)) :from (:orders)
  :group-by (:user_id) :having (:> (:count :*) 3))
'(:select ((:as (:count (:distinct :country)) :c)) :from (:users))

;; Subqueries: derived table (FROM), IN (:select …), and EXISTS
'(:select (:t.x) :from ((:as (:select (:x) :from (:big)) :t)))
'(:select (:id) :from (:users) :where (:in :id (:select (:user_id) :from (:admins))))
'(:select (:*) :from ((:as :users :u))
  :where (:exists (:select (1) :from ((:as :orders :o)) :where (:= :o.user_id :u.id))))

;; RETURNING (PG/XTDB; SQLite >= 3.35) -- use FETCH to get the rows back
'(:insert-into :users :values ((:email "a@x")) :returning (:id :created_at))

;; Upsert -- ON CONFLICT ... DO UPDATE (or :do-nothing t)
'(:insert-into :users :values ((:email "a@x" :name "A"))
  :on-conflict (:email) :do-update (:name (:excluded :name)))
```
For a `RETURNING` statement whose rows you want, call `fetch` (row-returning path), not
`run` (affected-row count).

### Running queries
`sql` just compiles; `fetch` and `run` compile *and* execute via `mnemosyne/conn`:
```lisp
(mnemosyne/query:fetch c '(:select (:email :password_hash) :from (:users)
                           :where (:= :email "a@x")))     ; SELECT -> rows (plists)
(mnemosyne/query:run   c '(:insert-into :users :values ((:email "a@x" :password_hash "…"))))
```
So a login lookup and an account insert never touch raw SQL.

### From SQL (`parse`) — the inverse
Know the SQL but not the data form? `parse` turns a SQL string (over this subset) back into
the query plist:
```lisp
(mnemosyne/query:parse "SELECT id, email FROM users WHERE email = 'a@x' AND id > 10")
;; => (:select (:id :email) :from (:users) :where (:and (:= :email "a@x") (:> :id 10)))
```
Literals become values. It **round-trips** across the whole surface — joins, aliases,
aggregates/functions, subqueries, `EXISTS`, `IN (SELECT …)`, `RETURNING`, and `ON CONFLICT`
upserts: `(sql (parse s) :inline t)` reproduces `s`, and `(parse (sql q :inline t))`
reproduces `q`. The `:inline` option to `sql` renders values inline (no params) — for
round-trip / display / logging only; **never execute inlined SQL with untrusted values**.
Genuinely unsupported constructs (CTEs, `UNION`, window functions) signal an error rather
than mis-parse — reach them with `(:raw …)`.

### Dialects
`mnemosyne/query:*dialect*` (or the `:dialect` keyword to `sql`/`fetch`/`run`) selects the
target: `:sqlite` and `:postgres` both emit `?` (verified). `:xtdb` is the seam for XTDB 2
— PG-wire but a **distinct dialect** (`$N` params, **no DDL**, temporal `FOR VALID_TIME …`
SELECT); provisional, see [`xtdb-notes.md`](xtdb-notes.md). The builder **enforces** two
XTDB DML differences: it signals on `:on-conflict` (XTDB `INSERT` already upserts on `_id`)
and on `:returning` (XTDB DML has none — read the value back with a separate query).

**One vocabulary, three spellings** ([ADR-0003](adr/0003-one-dialect-vocabulary.md), #432).
A dialect is a *designator*: the keyword `:postgres`, the string `"postgres"` and a typed
`mnemosyne/field:Dialect` all name the same thing, and every entry point that branches on a
dialect — `query:sql`, `ddl:ddl`, `schema:schema-ddl`, `introspect:schema-diff` — normalises
through `mnemosyne/field-shell:dialect-for` before anything compares it. So the `"postgres"`
below and the `:postgres` above are interchangeable, which they were **not** before: each
module accepted a different subset, and the ones it did not accept took its *other dialect*
branch. An unrecognised spelling now signals `unknown-dialect` everywhere rather than
quietly meaning SQLite in one module and Postgres in the next.

### Data, not macros
`sql` is an ordinary **function** over quoted data — a query is a plain value, not a macro
form. So you can build queries programmatically (add a `:where` conditionally, merge
clauses, store them) and compile on demand — unlike a macro-based DSL (e.g. Postmodern's
S-SQL) that fixes the query at compile time. HoneySQL uses Clojure maps/vectors
(`{:select […]}` / `[:= :id 1]`); CL has neither literal, so we use **plists + lists**
(`(:select (…) :where (:= :id 1))`) — keywords carry over directly.

### Coverage
Covers the SQL a typical app writes: CRUD, the everyday predicates, **joins** (inner/left/
right/full/cross), **aliases**, **aggregates & function calls** (`COUNT`/`SUM`/`AVG`/… +
`DISTINCT` + arbitrary `(:call …)`), **subqueries** (derived tables, `IN (SELECT …)`,
`EXISTS`), **`RETURNING`**, and **upserts** (`ON CONFLICT … DO UPDATE/NOTHING`) — all
round-trippable through `parse`. *Not yet* (roadmap): CTEs (`WITH`), `UNION`/set ops, window
functions, and XTDB temporal `FOR VALID_TIME` SELECT. Reach the long tail with `(:raw "…")`;
DDL lives in migrations (raw SQL), not the builder.

## NULL, true and false — say which you mean

SQL needs "no value", "true" and "false" to be three different things. Common Lisp `NIL` is
all three at once, and the drivers did not agree on how to resolve that: SQLite stored SQL
NULL, while Postgres rendered `NIL` as the literal **`false`**. On a numeric column that was
a hard error; on a **text** column it silently stored the four characters `false`, committed,
and every later `WHERE ... IS NULL` quietly stopped matching (#165).

So mnemosyne decides what a bound value means, rather than leaving it to whichever engine is
underneath. **Three values, and they are all spellable:**

| you write | means | Postgres | SQLite |
|---|---|---|---|
| `nil` or `:null` | SQL NULL | `NULL` | `NULL` |
| `:true` or `t` | boolean true | `true` | `1` |
| `:false` | boolean false | `false` | `0` |

```lisp
(q:run conn (list :insert-into "posts"
                  :values (list (list :title "draft"
                                      :published_at nil      ; no value  -> NULL
                                      :is_draft :true))))    ; boolean   -> true
```

`:true` is not new vocabulary — the changeset layer's `%to-bool` has always accepted
`(member raw '(t :true))`. This extends that convention rather than adding a second one.

> ### ⚠ Breaking change on Postgres: `NIL` in a boolean column
>
> `NIL` bound to a **boolean** column used to store `false` on Postgres. It now stores
> **NULL**. Call sites that meant false must say **`:false`**.
>
> Nothing detects this for you — it is a silent change of meaning, in the same column type
> where the original bug was silent. If you have Postgres code that writes booleans, grep
> for `NIL` in your insert and update plists before upgrading.
>
> Code written against **SQLite is unaffected**: `NIL` already meant NULL there, which is
> why this change makes the two backends agree rather than changing what your queries mean.

### Reading it back

The same vocabulary applies in the other direction, so a value means the same thing coming
out as going in:

| in the database | reads back as |
|---|---|
| SQL NULL | `nil` |
| boolean true | `1` |
| boolean false | `0` |

**Test for absence with `null`**, which is what the CL idiom already does:

```lisp
(defun current-p (row) (null (getf row :valid-until)))   ; NULL means "still current"
```

Before this, a NULL read back as the keyword `:NULL` on Postgres and `NIL` on SQLite. Since
`:NULL` is *truthy*, that predicate returned false for **every** row on Postgres — `WHERE ...
IS NULL` silently ceasing to match, one layer up in Lisp. A consuming app hit exactly this
and only noticed because a unique index happened to stand behind the query; without one it
would have written duplicates in silence.

> ### ⚠ `0` is truthy in Common Lisp
>
> A boolean column reads back as `1` or `0`, so **`(when (getf row :flag) ...)` runs even
> when the flag is false.** Compare explicitly:
>
> ```lisp
> (eql 1 (getf row :flag))     ; not (when (getf row :flag) ...)
> ```
>
> This is not a choice mnemosyne made lightly — it is what SQLite has always returned, and
> SQLite cannot return anything else. SQLite has no boolean type, and its driver exposes
> column *names* without declared types, so a boolean column's `1` is indistinguishable from
> an integer column's `1`. Reading booleans as `T`/`:FALSE` was considered and rejected
> because it is only achievable on Postgres, which would have left the two backends
> disagreeing about what a boolean reads as — the very defect this change exists to remove.

### Data written before this fix

A database that ran against the old behaviour already holds rows where a text column
contains the four characters `false` and meant NULL. **The fix cannot tell those from a
genuine `"false"` string afterwards.** It prevents new corruption; it does not repair what is
there. Audit nullable text columns for the literal value `false` before assuming otherwise.

## Schemas and changesets (Ecto-style)

A **schema** names a table and its typed fields; a **changeset** is the safe funnel that
casts and validates external data (form posts, JSON) before it reaches the database. The
field *types* are the typed Coalton core (`mnemosyne/field`); `defschema`, casting, and
validation are the CL shell.

### Why a changeset? (the motivating example)

Say a signup form posts to your handler. The obvious thing is to insert what arrived:

```lisp
;; DON'T
(q:run connection `(:insert-into :users :values ,params))
```

That one line has three separate problems, and a changeset exists to solve all three.

**1. It trusts every key the client sent.** Your form has `email`, `name`, `password`.
Nothing stops someone posting `role=admin&active=true&id=<an-existing-uuid>` as well —
`params` is just whatever came off the wire, and every key of it lands in the `INSERT`.
This is the classic *mass-assignment* vulnerability (the one that famously got Rails' own
GitHub repo committed to in 2012). The fix is not "validate harder"; it is to make the
permitted fields an explicit allow-list at the boundary:

```lisp
(cs:cast 'user params '(:email :name :age))   ; role, active, id cannot get through
```

Anything not named is **dropped, silently and by construction** — a field you forget to
list can never be written, which is the safe direction to fail.

**2. Everything arriving is a string.** HTTP has no types: you get `"42"`, not `42`;
`"yes"`, not true; `""` where you meant `NULL`. Insert those raw and you get a type error
from the driver at best, and a row containing the string `"yes"` in a boolean column at
worst. `cast` converts each permitted value **to its schema field's declared type**, and
records an error when a value cannot be converted rather than guessing.

**3. You want every error at once, not the first one.** A handler's job on bad input is to
re-render the form with *all* the problems marked. An exception-per-failure gives you one
error and unwinds; a changeset **accumulates** them as data and stays valid to inspect:

```lisp
(cs:changeset-errors c)   ; ((:email . "must contain @") (:age . "must be >= 18"))
```

So the shape is: **permit → cast → validate → run**, with errors as data the whole way and
a single decision point at the end. That is the whole idea — the database is never the
thing that discovers your input was bad.

### A signup handler, end to end

```lisp
(defun handle-signup (params connection)
  (let ((c (cs:cast 'user params '(:email :name :age))))       ; 1. permit + cast
    (setf c (cs:validate-required c '(:email :name)))          ; 2. accumulate errors
    (setf c (cs:validate-format   c :email (lambda (s) (find #\@ s))))
    (setf c (cs:validate-number   c :age :gte 18))
    (if (cs:changeset-valid-p c)
        (let ((user (cs:insert! c connection)))                ; 3. one decision point
          (redirect-to (format nil "/welcome/~A" (getf user :id))))
        (render-signup-form :values params                     ; re-render with everything
                            :errors (cs:changeset-errors c)))))
```

Note what is *not* in there: no manual type conversion, no allow-list scattered across the
function, no `handler-case` around the insert, and no way for an unlisted column to be
written. The validators thread immutably, so each `setf` is just rebinding a local — you can
also thread them with `let*` or a threading macro if you prefer.

### Define a schema
```lisp
(mnemosyne/schema:defschema user (:table "users")
  (:id      :uuid      :primary t)
  (:email   :string    :required t)
  (:name    :string)
  (:age     :integer)
  (:active  :boolean   :default t)
  (:created-at :timestamp))
```
Field types: `:string` `:text` `:integer` `:float` `:boolean` `:uuid` `:timestamp` `:date`
`:binary` (`:blob` is the same type) `:vector`.
Options: `:primary`, `:required`, `:default`, and `:dimensions` on a vector.

**Option values are evaluated** (#258), so a width can come from configuration —
`:dimensions +embedding-width+`. They used to be quoted whole: if you are upgrading and a
declaration passed a bare symbol or a list you meant as data, quote it
(`:default (quote (:a :b))`). Self-evaluating values — keywords, strings, numbers, `t` — are
unaffected. A migration's SQL stays **pinned** rather than re-derived per deploy; see
[`docs/migrations.md`](../../docs/migrations.md) §8.

#### When a derived value has gone stale (ADR-0002)

A row holds text and something **derived** from it — an embedding, a translation, a summary.
The text changes, the derived value does not, and nothing says it is now wrong. Declare what
the value is derived *from*:

```lisp
(mnemosyne/schema:defschema chunk (:table "chunks")
  (:id        :uuid    :primary t)
  (:title     :string)
  (:body      :text)
  (:structure :text)                                    ; layout, not words
  (:embedding :vector  :dimensions 1536 :derived-from '(:title :body)))
```

That adds two companion columns as real fields — `embedding_fingerprint` and
`embedding_deriver` — so DDL and drift detection carry them with no special case. A single
input needs no quote (`:derived-from :body`); a list does, because option values are evaluated.

**The fingerprint covers exactly the inputs to the derived value.** Not the row, not everything
convenient. That is the whole convention: wider and a write to `structure` reports staleness
that is not there, which costs a model call per row; narrower and it misses real staleness.

```lisp
(let ((fp (mnemosyne/derived:content-fingerprint
           (list title body)                  ; in the order derived-inputs returns
           :hash #'my-sha256-hex)))           ; the digest is YOURS -- there is no default
  (when (mnemosyne/derived:derived-stale-p stored-fingerprint fp
                                           :stored-deriver stored-model
                                           :current-deriver *embedding-model*)
    (re-embed row)))
```

**Staleness is the disjunction of the two columns**, which is why `derived-stale-p` takes both
pairs: a fingerprint that differs means the text was edited, a deriver that differs means the
model or its dimension changed, and either alone is stale. Compare only the fingerprint and you
miss every row needing re-derivation after a model change; compare only the deriver and you miss
every edit. Omit the derivers and you are asking the fingerprint question alone, which is a fair
question and gets that answer.

`content-fingerprint` **requires** `:hash`: two consumers that disagree about the digest
disagree about staleness, silently. mnemosyne frames the inputs (length-prefixed, so `"ab"+"c"`
and `"a"+"bc"` cannot collide) and compares the results; it computes no hash and asks the
database for none, which is what makes this work on SQLite.

A **model or dimension change** is not content changing, so it is the other column's job:

```lisp
(:select (:id) :from ("chunks") :where (:<> :embedding_deriver "text-embedding-3-small"))
```

one predicate against a bind parameter. And a row whose fingerprint is `NULL` — every row that
predates the convention — reads as stale, which is the answer you want on the day you adopt it.

Not to be confused with **row versioning**: `mnemosyne/id:touch!` answers *did this row
change*, and this answers *did the text this value was derived from change*. Reorder blocks and
every row below bumps its version with no text touched.

#### Vector columns, and the backend that cannot have them

```lisp
(:embedding :vector :dimensions 1536)
```

The dimension is part of the type, not an option beside it: pgvector's column type is
`vector(1536)`, and a vector without a width is not a narrower vector but not a column type
at all. Declaring `:vector` without a positive `:dimensions` is refused where you wrote it,
rather than at migration time.

**Postgres carries it; SQLite does not, and the difference is not hidden.** `schema-ddl`
against SQLite signals `unsupported-field-type`, naming the field, the type and the backend.
That is [ADR-0001](adr/0001-unsupported-field-types.md)'s default, and it is deliberate: a
vector stored in a `TEXT` column would accept every value and be searchable by nothing, so
the failure would arrive as poor search results rather than as an error.

Ask before declaring, rather than discovering at migration time:

```lisp
(mnemosyne/field-shell:field-type-supported-p (mnemosyne/field:ft-vector 1536) "sqlite")
;; => "unsupported"
```

ADR-0001 also describes `:on-unsupported :emulate` as an opt-in for backends that cannot
carry a type. **No emulation exists yet**, so that option is refused rather than accepted
and ignored — an app that wrote it would otherwise believe it had opted in while the column
was refused anyway.

**A changed dimension is drift.** Schema comparison drops a parenthesised precision --
`VARCHAR(255)` and `VARCHAR(80)` are the same type -- but keeps a vector's width, because
`vector(1536)` and `vector(768)` are different columns and pgvector refuses a value of the
wrong width.

#### Searching them

The three pgvector distance operators are in the query DSL, and they are Postgres-only —
on a backend with no vector column type a distance query is not slow, it is meaningless, so
it is refused rather than rendered.

```lisp
(q:fetch conn (list :select '(:id :title) :from '("docs")
                    :order-by (list (list (list :<=> :embedding query-vector)))
                    :limit 10)
         :dialect :postgres)
;; SELECT id, title FROM docs ORDER BY embedding <=> ? LIMIT ?
```

The query vector **binds as a parameter**; nothing is interpolated into the SQL. Note the
nesting in `:order-by`: an expression is wrapped in its own list, because `(:embedding :desc)`
and `(:<=> :embedding v)` are both lists starting with a keyword and nothing else tells them
apart.

| operator | measures | served only by an index built with |
|---|---|---|
| `:<->` | L2 distance | `vector_l2_ops` |
| `:<=>` | cosine distance | `vector_cosine_ops` |
| `:<#>` | negative inner product | `vector_ip_ops` |

**That last column is the trap.** An index built for one operator is not used by a query
written with another — and Postgres does not error. It returns correct rows and sequentially
scans, so the mistake is a right answer at the wrong cost, invisible until the table is
large.

So compiling a distance operator **warns**, naming the operator class that would serve it.
It warns rather than refuses because the query is correct: breaking a working query to
prevent a performance problem is the wrong trade. Silence it once you have built the index,
where a reader can see it was a decision:

```lisp
(let ((mnemosyne/query:*warn-unindexed-vector-distance* nil))
  ...)
```

#### Indexing them

```lisp
(:create-index :name :idx_docs_embedding :on :docs :columns (:embedding)
               :using :hnsw :opclass :vector_cosine_ops
               :with (:m 16 :ef_construction 64))
```

`:opclass` is **required** for `:hnsw` and `:ivfflat`. pgvector would happily default it, and
a reader of the DDL then cannot tell which distance operator the index serves — the one
thing about a vector index worth knowing.

`:with` renders index options verbatim, because the right values depend on the corpus rather
than on us: HNSW takes `m` and `ef_construction`, IVFFlat takes `lists`.

**IVFFlat has an ordering constraint nothing here can enforce.** It clusters the data that
exists when it is built, so building it on an empty table produces an index that works and
retrieves badly. That is a migration fact: build it after the table holds representative
data.

#### Where this is tested

Against a real pgvector, on Linux. `docker-compose.test.yml` carries
`pgvector/pgvector:pg17` for exactly this. The macOS and Windows CI legs provision Postgres
by Homebrew and by the runner's preinstalled service and have no pgvector, so these tests
**skip there with a named reason** rather than passing —
[#371](https://github.com/codelisperer/ouranos/issues/371) covers macOS. **Windows is a
documented exclusion**: installing pgvector against the runner's preinstalled service is a
different and much larger job, and the platform axis already names what a host cannot
answer.

The praxeon-side seam — semantic search as something an agent calls — is
[#258](https://github.com/codelisperer/ouranos/issues/258)'s remaining half and is deferred
under the app-first rule in [`ECOSYSTEM.md`](../../ECOSYSTEM.md): built in a consuming app
first, promoted once a caller has proved its shape.
#### Binary columns, and how big is too big

`:binary` is `BLOB` on SQLite and `BYTEA` on Postgres. A changeset takes an
`(unsigned-byte 8)` vector and gives one back; a string is **refused** rather than encoded,
because picking an encoding would be the framework guessing what you meant and the guess is
unreadable once the row is written. Encode it yourself if that is what you want:

```lisp
(:avatar :binary)
;; then
(cs:cast 'member (list :avatar octets) '(:avatar))
```

**Use it for values that are genuinely small** — an avatar, a thumbnail, a signature image,
tens of kilobytes. The row is read and written as a unit, so a large value is paid for on
every query that touches the row, whether or not it selects the column.

**For anything larger, keep the bytes outside the database** and store a key. `hermes/blob`
is the content-addressed store in this tree. The cost of in-row binary is not a hard limit
you will hit cleanly: SQLite has `SQLITE_MAX_LENGTH` (1 GB by default and often lower in
practice) and Postgres caps `BYTEA` at 1 GB, and an application that streams an upload
straight into a column meets those as a driver-level error rather than as a message it can
act on. Neither backend is checked here, so the ceiling is the driver's and it is worth
knowing before you rely on it.

### DDL from the schema (feeds a migration)
One source of truth: derive the `CREATE TABLE` rather than hand-write it twice. It stays raw
SQL *inside* a migration, but the shape comes from the schema.
```lisp
(mnemosyne/schema:schema-ddl (mnemosyne/schema:find-schema 'user) :dialect "postgres")
;; CREATE TABLE IF NOT EXISTS users (
;;   id UUID PRIMARY KEY, email TEXT NOT NULL, name TEXT, age BIGINT,
;;   active BOOLEAN DEFAULT TRUE, created_at TIMESTAMPTZ )
```
Types resolve per dialect (`:uuid` → `UUID` on Postgres, `TEXT` on SQLite; `:integer` →
`BIGINT`/`INTEGER`; `:binary` → `BYTEA`/`BLOB`; `:vector` → `vector(n)` on Postgres,
refused on SQLite; …). XTDB 2 is schemaless — `schema-ddl` signals for `"xtdb"`.

### DDL beyond CREATE TABLE — indexes, drops, alters

`schema-ddl` covers `CREATE TABLE`. Everything else a migration needs — indexes, drops,
column changes — is `mnemosyne/ddl`, using the same **data, not macros** convention as the
query DSL:

```lisp
(ddl:ddl '(:create-index :name :idx_users_email :on :users :columns (:email) :unique t))
;; "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email ON users (email)"

(ddl:ddl '(:drop-table :name :widgets))                      ; :if-exists t by default
(ddl:ddl '(:alter-table :users (:add-column :nickname :string)
                               (:rename-column :bio :about)))
```

Actions: `:add-column` (with `:required` / `:default` / `:primary`), `:drop-column`,
`:rename-column`, `:rename-to`, `:add-constraint`, `:drop-constraint`. Column types go
through the same typed vocabulary as `defschema`, so `:string` is `TEXT` and `:integer` is
`BIGINT` on Postgres, `INTEGER` on SQLite.

Feeding a migration — `ddl-statements` always returns a **list**, because an `:alter-table`
with three actions is three statements (SQLite requires them separately):

```lisp
(dolist (stmt (ddl:ddl-statements form :dialect "sqlite"))
  (conn:exec connection stmt))
```

**Generation is optional and additive.** `make-migration` still takes raw up/down SQL
strings and always will — raw SQL is the escape hatch for vendor-specific DDL and anything
the generator doesn't cover, and a migration may mix generated forms and hand-written
strings freely.

**Dialect limits surface at render time, not mid-migration.** SQLite has no `CASCADE` and
no `ALTER TABLE ... DROP CONSTRAINT` (that needs a table rebuild); XTDB 2 is schemaless and
has no DDL at all. Each signals `ddl:unsupported-ddl` naming the dialect and the operation
when you *render* it — where the migration author can see it — rather than failing as a
driver error halfway through a migration run.

### Does the table still match? (`mnemosyne/introspect`)

`schema-ddl` derives `CREATE TABLE` from a **mutable** definition for an **immutable**,
already-applied migration. So a defschema that grows a column has quietly stopped describing
the table, and the one failure that is loud — a fresh database creating the column in the
original migration and then hitting a duplicate `ALTER` — only fires on a database you do not
have.

The model that survives is **the defschema is the present, the migration list is history, and
a fresh database replays history to arrive at the present**. `mnemosyne/introspect` checks
that last claim against the catalog instead of asserting it:

```lisp
(intro:verify-schema (backend) conn (schema:find-schema 'user))   ; after migrate:migrate
```

It reads `information_schema` on Postgres and `pragma_table_info` on SQLite, compares names,
types, `NOT NULL` and `PRIMARY KEY`, and signals `intro:schema-drift` — naming every column
that is missing, extra, or the wrong type — with a `continue` restart. Put it in bring-up or
in the app's tests and the fresh-database-only failure becomes a failure on every database.

The difference is available as **data**, not just as a message:

```lisp
(let ((d (intro:diff-table (backend) conn (schema:find-schema 'user))))
  (intro:drift-missing d)      ; schema fields with no column   -> a migration was not written
  (intro:drift-extra d)        ; columns with no schema field   -> the definition is behind
  (intro:drift-mismatched d)   ; (field . column) that disagree
  (intro:report-drift d))      ; the same thing, printed
```

`intro:schema-diff` is **pure** — it takes the columns, so the comparison is testable with no
database — and `intro:table-columns` is the catalog read on its own.

**And it writes the reconciling `ALTER`, so nobody types it twice:**

```lisp
(intro:drift-ddl (intro:diff-table (backend) conn (schema:find-schema 'user)))
;; => ((:alter-table "users" (:add-column :nickname :string)))
```

Paste that into a **new** migration under a **new** id. The applied one is never touched, and
the `ALTER` was still derived from the schema. What it deliberately will not generate: a type
change (a table rebuild on SQLite, a data decision on Postgres), or a `DROP COLUMN` unless you
pass `:include-drops t`. Defaults are read and reported but never diffed — Postgres rewrites
them into its own normal form, and a checker that cries wolf gets ignored.

Full convention: [`docs/migrations.md`](../../docs/migrations.md) §8.

### Cast + validate + insert
```lisp
(let ((c (mnemosyne/changeset:cast 'user params '(:email :name :age :active))))  ; only these fields move
  (setf c (mnemosyne/changeset:validate-required c '(:email)))
  (setf c (mnemosyne/changeset:validate-format   c :email (lambda (s) (find #\@ s))))
  (setf c (mnemosyne/changeset:validate-number   c :age :gte 18 :lte 120))
  (if (mnemosyne/changeset:changeset-valid-p c)
      (mnemosyne/changeset:insert! c connection)              ; runs the INSERT
      (mnemosyne/changeset:changeset-errors c)))               ; ((:email . "…") …)
```
- **`cast`** takes only the fields you permit (safe mass-assignment) and casts each raw
  value to its field's type (`"42"` → `42`, `"yes"` → `1`); a bad cast records an error.
- **Validators** thread the changeset immutably, accumulating errors:
  `validate-required`, `validate-format` (takes a *predicate* — dep-free, pass a `cl-ppcre`
  scan if you have it), `validate-length`, `validate-number`, `validate-inclusion`,
  `validate-exclusion`, and the general `validate-change`.
- **Bridge:** `to-insert` / `to-update` produce a `mnemosyne/query` plist; `insert!` /
  `update!` compile and run it. All four **signal `changeset-invalid`** on an invalid
  changeset — errors are data until the edge. Raw params never reach SQL uncast.

This is the layer accounts+login writes against: a signup handler is `cast` → `validate-*`
→ `insert!`, and a login lookup is a `fetch` on the same schema's table.

## Identity and entity metadata (`touch!`)

"The best serial ID generator is time itself." `mnemosyne/id:new-id` mints a **time-ordered
v6 UUID** whose embedded 60-bit timestamp *is* the **`vid`** — a monotonic, sortable
version/serial — plus the UTC **instant**:

```lisp
(mnemosyne/id:new-id)
;; => "1f1883e2-6b9e-…"                 ; RFC-9562 v6 (sortable)
;;    140042863943625630               ; vid — the monotonic Gregorian-100ns tick
;;    "2026-07-25T15:33:14.3625630Z"   ; UTC instant, ISO-8601 (100-ns precision)
```

A locked, strictly-increasing clock makes the **`vid` unique and monotonic even under
concurrent burst generation** (thousands+/sec) — verified in the suite (20k back-to-back and
40k across threads, zero collisions). So a `vid` is a safe serial you can order by.

### `touch!` — stamp a hash-table "object"
The Clojure-flavored dynamic path: stamp a hash-table (keyword keys) with identity + audit
metadata. No `:_id` yet → **create** (full stamp); has one → **update** (bump `vid` +
`utc-time-modified` + `modified-by`, preserving `:_id`/created). Mutates and returns it.

```lisp
(let ((e (make-hash-table)))
  (mnemosyne/id:touch! e "alice")   ; create: _id, vid, utc-time-created/modified, created-by, modified-by
  (mnemosyne/id:touch! e "bob")     ; update: same _id, new vid, modified-by = bob
  e)
```

### The typed `DTO` trait — `touch` a struct
The typesafe path: a Coalton **`DTO`** typeclass makes metadata compile-time-checked — only a
type that implements it can be touched, and `touch` is pure (returns a new value). Implement
it by saying how to read/replace a `Meta` slot:

```lisp
(define-instance (mnemosyne/entity:DTO Person)
  (define (mnemosyne/entity:get-meta p) …)          ; (Optional Meta)
  (define (mnemosyne/entity:with-meta p meta) …))    ; a copy with meta set

;; from Coalton: (touch (mnemosyne/id:new-stamp) "alice" a-person)
```
`touch` is typeclass-constrained, so from **CL** call it through a monomorphic wrapper (see
[`../../docs/coalton-patterns.md`](../../docs/coalton-patterns.md) §5). Ported from MPP's
`db/core` — and it fixes that original's create-branch bug (which dropped the UUID as an empty
`_id`).

## Where to look next
- [`roadmap.md`](roadmap.md) · [`first-milestone.md`](first-milestone.md) ·
  [`mnemosyne-vision.md`](mnemosyne-vision.md) · [`xtdb-notes.md`](xtdb-notes.md) ·
  [`../../docs/coalton-patterns.md`](../../docs/coalton-patterns.md).
