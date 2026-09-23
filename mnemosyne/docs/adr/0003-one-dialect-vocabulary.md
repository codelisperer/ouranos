# ADR-0003 — One dialect vocabulary, and what a module does with a spelling it does not know

**Status:** Accepted *(2026-09-21)*
**Date:** 2026-09-21
**Issue:** pre-publication issue 432, from the Linux/WSL
lane's finding while building pre-publication issue 258's
changeset slice. Extends [ADR-0001](0001-unsupported-field-types.md), which made the dialect
a closed type for the field-type path and got adopted nowhere else.

## Context

Four modules branched on the dialect and three of them had their own idea of what one is.

| module | held it as | compared with | an unrecognised value |
|---|---|---|---|
| `mnemosyne/query` | keyword | `eq` | refused (since pre-publication PR 431) |
| `mnemosyne/ddl` | string, via a private `%dialect-name` | `string=` | **rendered as Postgres** |
| `mnemosyne/schema` | string | `string=` | partly refused, by accident |
| `mnemosyne/field` | typed `Dialect` ADT | `==` on the **rendered name** | took the SQLite arm |
| `hyperion/auth-db`, `session-db` | keyword | — | converted by hand at each call |

The finding that opened the ticket was the first row meeting the second: a caller holding
the string `"postgres"` — which `ddl` and `schema` both accept — fell through **every**
Postgres branch in `query` at once, and the vector-distance check told a caller *who was on
Postgres* that *the postgres backend has no vector column type at all*. Not an error: a
wrong answer, delivered confidently, by a check whose logic was correct and whose input was
a spelling it did not recognise.

`%check-dialect` (pre-publication PR 431) stopped that fall-through by refusing the other module's spelling at
`query`'s boundary. That was right while two vocabularies existed — quietly normalising
would have hidden the inconsistency rather than naming it — but it left the inconsistency
in place, and it is not the only instance.

### The same defect existed in the other direction, and nothing had found it

Measured on `7fe5459`, Linux/WSL, before this change:

* `(ddl '(:drop-table :name :users :cascade t) :dialect "sqlrite")` returned
  `"DROP TABLE IF EXISTS users CASCADE"`. `%sqlite-p` was a **two-way** test whose else-arm
  means Postgres, so a typo was not refused — it was rendered, as valid Postgres, against
  the SQLite the caller meant. `CREATE EXTENSION` and the XTDB guard had the same shape.
  `%dialect-name` fell back to `princ-to-string`, so **every object had a dialect name**.
* `(schema-ddl … :dialect :xtdb)` walked **past** the guard that exists to say XTDB is
  schemaless: `string=` compares a symbol designator by `SYMBOL-NAME`, so `"XTDB"` did not
  equal `"xtdb"`. The caller got `Pattern match not exhaustive` from further in, naming
  neither the dialect nor the reason — and `:xtdb` is precisely the spelling `query` takes.
* `field-shell:column-sql` trusted **any non-string** to already be a typed `Dialect`, so
  the single normaliser had an unguarded door.
* `field-type-sql` asked `(== (dialect-name dialect) "postgres")` — a two-way test on a
  three-constructor ADT, put by rendering the closed type back into the open string it
  exists to replace. `D-Xtdb` took the SQLite arm and reported `INTEGER`, `TEXT`, `BOOLEAN`
  for a backend that has no columns at all.

The last one is the ticket's sharpest point: **there is a third dialect, so "the other one"
is already wrong as a concept**, and it was wrong inside the typed core that ADR-0001 built
to prevent exactly this.

## Decision

**The vocabulary is `mnemosyne/field:Dialect`, and it already existed.** ADR-0001 built the
closed ADT, the single normaliser `dialect-from`, the CL boundary `field-shell:dialect-for`
and the `unknown-dialect` condition. The field-type path adopted them; the four modules that
branch on a dialect did not. So this ADR is not a new design — it is the decision to *use
the one that shipped*, which is why `field` already loads third in the `.asd`, ahead of
`query`, `schema`, `ddl` and `introspect`.

Three rules:

1. **`field-shell:dialect-for` is the one normaliser.** It accepts a **designator** — a
   typed `Dialect`, a string, or a symbol/keyword — and refuses everything else with
   `unknown-dialect`. It is idempotent, so a caller that has normalised can pass the result
   on without a second vocabulary meaning *already checked*. Accepting three shapes here is
   not the permissiveness the ticket objected to; the objection was to each module
   accepting a **different subset** and treating the rest as the other dialect.
2. **Every module normalises once, at its public entry, and branches on the typed value.**
   `query:sql`, `ddl:ddl`, `ddl:ddl-statements`, `schema:schema-ddl` and
   `introspect:schema-diff`. A Coalton nullary constructor is a singleton, so `eq` against
   `D-Postgres` is exact — the same comparison the old code made against `:postgres`, but
   against a value that cannot be a spelling nobody recognised.
3. **A module refuses a value it does not recognise rather than treating it as the other
   one.** This is the property that prevents the recurrence, and it matters more than the
   representation. Corollary, from the third dialect: a two-way `if` on a dialect is a
   defect unless something upstream has already excluded the third.

### What this changes about pre-publication PR 431's rule

`query` now **accepts** `"postgres"` and compiles it identically to `:postgres`. The ticket
proposed the acceptance bar as *pass the other module's spelling and assert a refusal*,
which assumed the ruling would pick one spelling and reject the rest. It did not; it picked
one **type** with designators normalised at each boundary. The bar therefore becomes two
properties, and the second is the ticket's own, unchanged:

* **Agreement** — the same dialect under any spelling produces identical output. A module
  can refuse the other spelling and still *disagree* with the module that uses it, so
  refusal alone does not establish that the vocabulary is one.
* **Refusal** — an unrecognised spelling is refused by every module that branches.

`tests/query.lisp`'s `an-unknown-dialect-spelling-is-refused-rather-than-taking-the-sqlite-branch`
was rewritten rather than deleted: the claim in its name is untouched, and the part that
asserted `"postgres"` is refused — pre-publication PR 431's contract — is gone, with the reason recorded in
the test.

## Consequences

* `mnemosyne/query:+dialects+` **is removed**; `mnemosyne/field-shell:+dialects+` (typed
  values) and `+dialect-names+` (their canonical spellings, *derived*) replace it. A second
  list of the same three dialects is the defect in miniature, and a message listing its own
  copy of the names is a fourth place for them to disagree — so `unknown-dialect`'s report
  reads `+dialect-names+`. This is a **breaking change to an exported symbol**; nothing in
  the tree outside `query.lisp` used it.
* `field-type-sql` returns `Unsupported` for **every** field type on `D-Xtdb`, where it used
  to return SQLite's affinities. Nothing reaches it on XTDB today — `schema-ddl` and every
  `ddl` form refuse XTDB first — which is exactly why a wrong answer there could sit unread.
* `ddl` and `schema` now refuse a spelling they used to render or ignore. A migration that
  was passing a typo has been generating the wrong dialect's DDL and will now fail loudly.
  That is the intended direction of the break.
* `hyperion`'s three hand-rolled `(string-downcase (symbol-name dialect))` conversions are
  gone. They existed only because the two vocabularies disagreed, and each was also
  keyword-only — a string spelling hit a type error from `SYMBOL-NAME`.
* Adding a fourth dialect is now a compile error in `field-type-sql` rather than a silent
  membership in *not postgres*.

## Alternatives considered

**Keywords everywhere.** Cheap `eq`, and a typo is a distinct keyword a strict comparison
can refuse. But a dialect arrives from a `DATABASE_URL` or a config file as a *string*, so
every entry point would need a conversion anyway — which is the hand-rolled conversion
hyperion already wrote three times, promoted to policy.

**Strings everywhere.** Needs a case decision at every comparison, and `string=` against a
mis-cased value is the same silent miss in a different costume — as `schema-ddl`'s XTDB
guard proved, having missed `:xtdb` for as long as it existed.

**Leave `%check-dialect` and unify later.** Rejected because the inconsistency was still
producing new defects in the modules the ticket described as merely permissive: `ddl`
rendering Postgres DDL for a typo was live, unreported, and the same failure shape.

## Provenance

The ticket asked for a ruling between three options and asked for a sweep of two-way `if`s
as part of the fix. The sweep changed the answer: the third option — *a named type with a
single normaliser* — turned out not to be a proposal but a description of
[ADR-0001](0001-unsupported-field-types.md), already built, already loaded before every
module that needed it, and adopted by one path out of five. That reframed the decision from
*which vocabulary should we pick* to *why did the one we picked not spread*, and the answer
is visible in the table above: nothing refused the spellings the other modules used, so
every module that met one wrote a conversion or took a branch, and both workarounds are
invisible at the exit code.

The two-way `if` in `field-type-sql` was found by the sweep the ticket asked for, not by the
reasoning that opened it, and it is the instance that most justifies the rule: it sat inside
the typed core built to make this class of bug impossible, asked by rendering the closed
type back into a string.

Filed and implemented by Ouranos Claude (Linux/WSL).
