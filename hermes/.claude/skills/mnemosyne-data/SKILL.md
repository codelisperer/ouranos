---
name: mnemosyne-data
description: Model and query data with mnemosyne — schemas, changesets, and the data-not-macros query builder.
---

# Working with the mnemosyne data layer

Use when persisting or querying data in a codelisperer app.

## Query builder (data, not macros)

A query is a plist compiled by `mnemosyne/query:sql` to a parameterized SQL string + bound
params. A keyword/symbol is an identifier; anything else is a bound value (injection-safe).

- `(:select (:id :email) :from (:users) :where (:= :email x))`
- Joins: `:join ((:inner (:as :orders :o) (:= :u.id :o.user_id)))`; aggregates `(:count :*)`;
  subqueries `(:in :id (:select ...))`; `:returning`; upsert `:on-conflict` / `:do-update`.
- `parse` is the inverse (round-trippable). `fetch` returns rows; `run` returns a count.

## Schema + changeset (the safe funnel)

1. `(mnemosyne/schema:defschema user () (:id :uuid :primary t) (:email :string :required t) ...)`.
2. `schema-ddl` derives the CREATE TABLE — put THAT in a migration (do not hand-write it twice).
3. External params: `cast` (only permitted fields move) then `validate-required` /
   `validate-format` / `validate-number` ... then `insert!` / `update!`. Raw params never
   reach SQL uncast.

## XTDB 2 caveats

Distinct dialect: no DDL, INSERT already upserts on `_id` (no ON CONFLICT), no RETURNING —
the builder signals for those under `:xtdb`. See mnemosyne/docs/xtdb-notes.md.
