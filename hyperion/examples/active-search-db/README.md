# active-search-db

**Active Search, DB-backed** — the [`active-search`](../active-search/) HTMX example with its
data sourced from **SQLite via a mnemosyne migration** instead of an in-memory list. The same
UI (Bulma + HTMX + Alpine + a Parenscript keyboard shortcut); only the data layer changes.

## Run it

```sh
cd hyperion
cons example-search-db          # migrate + seed, serve on :8080, hot-reload dev server
```

Then open **http://127.0.0.1:8080/** and:

- **Type in the search box** — each keystroke (debounced 250 ms) fires an HTMX `POST /search`;
  the server runs a `LIKE` across name/email/role and swaps the server-rendered rows in. Try
  `lisp`, `co`, `zzz`.
- The help line updates **instantly** — Alpine reacting client-side on the *same* input HTMX drives.
- Press **`/`** to focus the box — that shortcut is Lisp compiled to JS by **Parenscript** (no Node).
- **Hot reload:** edit `app.lisp`, save, the browser refreshes. Stop with `(hyperion/dev:unwatch)`.

Build a native binary instead: `(ql:quickload :hyperion/examples/active-search-db)` then
`save-lisp-and-die` on `…:main` (it takes `--port` / `--host`).

## What it shows

The whole stack end to end, over a real migration:

- **Migrations** (`mnemosyne/migrate`) run at startup — migration #1's `CREATE TABLE` is
  **derived from a `defschema`** via `schema-ddl` (not hand-written), #2 adds an index; the
  table is seeded once (each row stamped by `mnemosyne/id:touch!` — a v6 `_id` + monotonic `vid`).
- The **data-driven query builder** — every search is `mnemosyne/query:fetch` with a
  `WHERE … LIKE` + `ORDER BY`, not raw SQL.
- The **Hyperion web loop** — server-rendered HTMX, Alpine for client reactivity, Parenscript
  for JS, hot-reload — unchanged from `active-search`.

It's the same migration engine as the console demo ([`mnemosyne/examples/contacts`](../../../mnemosyne/examples/contacts/)),
behind a different face. The SQLite file (`active-search.db`, gitignored) is created beside
this example; delete it for a clean slate. *Note: this demo opens a connection per request
(simple + thread-safe); a real app would use a pool.*

See [`../../../mnemosyne/examples/README.md`](../../../mnemosyne/examples/README.md) for the pair.
