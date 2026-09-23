# contacts

A tiny console app that shows off the **mnemosyne migration lifecycle** end to end over a
SQLite file. `cons run` starts it; on startup it applies pending migrations, then gives you a
command loop:

```
migrate            apply pending migrations
rollback           roll back the last migration (newest-first)
status             show applied vs pending
seed               insert a few sample contacts
add <name>[, <email>[, <role>]]   insert one, through cast -> validate (#129)
list [term]        list contacts (term → WHERE name LIKE %term%)
help · quit
```

What it demonstrates: **migrations** (`mnemosyne/migrate`, with migration #1's DDL *derived*
from a `defschema` via `schema-ddl`), the **data-driven query builder** (`fetch`/`run` with a
`LIKE` filter + `ORDER BY`), **time-ordered identity** (`touch!` stamps `_id`/`vid`/audit
— watch the monotonic `vid`s climb), and the **changeset path** the root `AGENTS.md`
mandates for external input — `cast` takes only permitted fields, `validate-*` accumulates
errors, and a refusal names the field and the reason (#94).

Try `add` with no arguments, and `add Someone, not-an-email` — the refusals come from
`changeset-errors`, not from a message the command invented. `_id` and `vid` are *not* in
the permitted list, so they cannot be set by a caller however the params arrive. Scaffolded by `cons init contacts --template cli`, then
pointed at mnemosyne — a working example of a consuming app built with the tooling.

Its web sibling — the same migration engine behind an HTMX page — is
[`active-search-db`](../../../hyperion/examples/active-search-db/); see the
[examples index](../README.md) for the pair.

## Develop

    cons build   # compile
    cons test    # run tests
    cons repl    # SBCL REPL with the tree on the path
    cons run     # run it
    cons bin     # dump a native bin/contacts
    cons         # list all targets

Tasks are declared in `cons.lisp` (the cross-OS Makefile replacement). Config/env:
copy `.env.example` to `.env` and fill it in -- it loads via `cons/env:load-dotenv`
(the host environment wins in prod).

Scaffolded by `cons init`.
