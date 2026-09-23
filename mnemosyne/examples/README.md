# mnemosyne examples

Runnable demos of the **mnemosyne migration lifecycle** — the same engine (migrate / rollback /
status, DDL derived from a `defschema`, the data-driven query builder, `touch!` identity
stamping) shown behind two different faces. They're a pair on purpose: the data layer doesn't
care whether a console or a web app is calling it, which is the "one core, many faces" thesis
in miniature.

| Example | Where | Surface | Run |
|---|---|---|---|
| [**contacts**](contacts/) | `mnemosyne/examples/contacts/` | console (CLI) | `cd mnemosyne/examples/contacts && cons run` |
| [**active-search-db**](../../hyperion/examples/active-search-db/) | `hyperion/examples/active-search-db/` | web (HTMX) | `cd hyperion && cons example-search-db` |

Both were scaffolded/structured with `cons`, consume mnemosyne (the web one lives in
**hyperion** because it needs the web framework too — the highest framework it depends on), and
show the identical migration flow:

- a **migration** creates + indexes the `contacts` table on startup — migration #1's
  `CREATE TABLE` is **derived** from a `defschema` via `schema-ddl`, not hand-written twice;
- rows are stamped by **`mnemosyne/id:touch!`** (a time-ordered v6 `_id` + a monotonic `vid`);
- every lookup is a **`mnemosyne/query`** (`fetch`/`run`), not raw SQL — the web demo's search
  is a `WHERE … LIKE`, the console's `list <term>` the same.

Start with **contacts** for the migration mechanics laid bare (an interactive `migrate` /
`rollback` / `status` loop), then **active-search-db** to see the same engine drive a live page.

Each example's own README has the details:
[contacts](contacts/README.md) ·
[active-search-db](../../hyperion/examples/active-search-db/README.md).

> The SQLite files these create at runtime (`*.db`) are gitignored. Delete one for a clean slate.
