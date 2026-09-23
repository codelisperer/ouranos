# ADR-0001 — What happens when a backend cannot support a declared field type

**Status:** Accepted *(2026-09-02, by the maintainer; pre-publication issue 213 existed to have this made
deliberately rather than by accident)*. Extended by
[ADR-0003](0003-one-dialect-vocabulary.md), which adopts the closed `Dialect` type built
here across the four modules that branch on a dialect — it had spread to the field-type path
and nowhere else (pre-publication issue 432).
**Date:** 2026-09-02
**Issue:** pre-publication issue 213, blocking
pre-publication issue 142 (binary) and
pre-publication issue 212 (vector)

**Implemented 2026-09-16 (pre-publication issue 334).** `field-type-sql` returns `Native | Emulated | Unsupported`,
the dialect is a closed `Dialect` type, and the CL shell (`mnemosyne/field-shell`) turns a
refusal into `unsupported-field-type`. Emulation is refused rather than applied, because the
opt-in this ADR requires at the declaration site does not exist yet — accepting it silently
would be the implicit degradation this ADR rejected, arriving through the door marked *not yet
implemented*. pre-publication issue 142 and pre-publication issue 212 now build **through** that signature, which is what this ADR
exists to make unavoidable.

## Context

`mnemosyne/field:Field-Type` is a closed set of eight types, and every one of them exists
on every backend. Two requests now exceed it — a binary column (pre-publication issue 142) and a vector column
(pre-publication issue 212) — and a third is predicted by a consuming app. So the protocol must answer a
question it has never had to: **what happens when a backend genuinely cannot support a
declared field type?**

### The decision is already made, by a type signature, in the wrong direction

```lisp
(declare field-type-sql (Field-Type * String -> String))
```

**Total.** Every field type has a SQL rendering in every dialect, by construction. There
is no value that means *this backend cannot do this*, so refusal is not something the
protocol declines to do — it is something the protocol **cannot express**.

This matters more than it first appears, because `field-type-sql` is in the **Coalton
core**, where the house rule is no IO and therefore no conditions. An implementer adding
`FT-Vector` cannot signal there even if they want to. The only thing they can write is a
string. Whatever they write for the non-Postgres branch becomes the precedent — which is
precisely the accident pre-publication issue 213 was filed to prevent, and it is structural rather than a
matter of anyone's care.

### Measured: the weaker backend is the quieter one

| Backend | `CREATE TABLE t (v VECTOR(1536))` | When the app finds out |
|---|---|---|
| Postgres 18, no `pgvector` | `ERROR: type "vector" does not exist` | migration time, loud |
| SQLite | **accepted**, stored verbatim, NUMERIC affinity | never |

SQLite accepts `FLURBLE(9)` too. It records the declared type as written and applies
affinity rules, so a vector column becomes a text column and every later similarity query
is wrong somewhere far from the cause.

Two consequences. First, **"refuse at migration time" is not the default — silence is**;
refusal is something mnemosyne must implement, because the substrate will not provide it.
Second, **"degrade" as it exists today is not the benign option pre-publication issue 212 describes.** It is not
"correct results, 10,000× slower"; it is a text column and wrong answers. A real emulation
— a blob plus a brute-force scan in Lisp — is a thing somebody has to *write*, and is a
different proposal from letting a type name through.

### The tree has already answered this once

```lisp
(when (string= dialect "xtdb")
  (error "mnemosyne/schema: XTDB 2 is schemaless -- no CREATE TABLE. See docs/xtdb-notes.md."))
```

`schema-ddl` refuses, names the reason, and points at the doc that explains it. So there
**is** a precedent — at whole-operation granularity — and it is *refuse loudly*. This ADR
extends the existing answer to field-type granularity rather than inventing one.

## Decision

**Neutral, not portable: the protocol may say what a backend cannot do.** Three parts.

**1. "Cannot" becomes representable.** `field-type-sql` returns an ADT rather than a bare
string — `(Native sql)` · `(Emulated sql)` · `Unsupported`. The Coalton core keeps its
purity: it *returns* the refusal as a value, and the CL shell turns it into a condition.
This is the ADTs-over-booleans rule applied to the one place a boolean was never even
available.

**2. The default is refuse, at migration time, with a named reason.** An app that declares
a vector column and migrates against SQLite gets a `unsupported-field-type` condition
naming the field, the type, the backend, and what to do about it — matching the XTDB
precedent above. Default, because the alternative default is silence, and silence is what
the measurement shows the substrate gives.

**3. Emulation is opt-in at the declaration site, never implicit:**

```lisp
(:embedding :vector :dimensions 1536 :on-unsupported :emulate)
```

This is the part that answers pre-publication issue 212's reporter, whose argument deserves to win on its
merits: *"a dev environment that cannot run the feature is a dev environment where the
feature is never tested."* That is right, and a design that costs them their SQLite test
story is worse than one that does not. The change is not whether emulation is available
but **who chooses it** — stated once, in the schema, where a reader sees it, rather than
inferred from a backend's silence.

Plus a predicate an app can ask, so production can assert what dev merely tolerated:
`(field-type-support backend type)` → `:native` · `:emulated` · `:unsupported`.

## Consequences

- **pre-publication issue 142 (binary) needs none of this machinery** — `BYTEA` and `BLOB` are native
  everywhere, so it is `Native` on both backends. But it must be implemented **through**
  the new signature, which is the whole reason pre-publication issue 213 blocks it: otherwise the easy case
  ships a total function and pre-publication issue 212 has to argue against it.
- An app pinned to SQLite cannot silently ship a vector column. That is the point.
- `Emulated` obliges someone to write a real emulation. Until one exists, `:emulate` on a
  vector column is itself unsupported — which is honest, and loud.
- **A related defect, same class:** `field-type-sql` takes its dialect as a `String`, so a
  typo silently takes the non-Postgres branch. It should be an ADT. Worth folding in while
  this signature is open; noted here rather than smuggled in.

## Alternatives considered

- **Portable — everything must work everywhere.** Rejected: it means nothing may exceed
  the weakest backend, which is how a neutral protocol quietly becomes SQLite-shaped. It
  also cannot be honoured — Postgres already refuses `vector` without the extension, so
  "works everywhere" is not on offer regardless of what we decide.
- **Refuse always, no emulation.** Rejected on pre-publication issue 212's evidence. It is coherent and it
  costs a real app its dev-and-test story for no gain that a stated opt-in does not give.
- **Degrade implicitly.** Rejected: it is the status quo, it is the thing `docs/vocabulary-and-layers.md`
  and the tree's "no facade that silently does nothing useful" rule already forbid, and
  the measurement shows it does not even produce correct-but-slow results.

## Provenance

Two measurements moved this. The first — that SQLite accepts `VECTOR(1536)` and
`FLURBLE(9)` without complaint — inverted the framing: pre-publication issue 213 and pre-publication issue 212 both present "refuse
at migration time" as the strict option and "degrade" as the lenient one, when in fact
degradation is what happens if nobody does anything, and it is silent. The second — that
`schema-ddl` already refuses for XTDB — meant this was never a question without a
precedent, only one whose precedent nobody had looked up.

The maintainer stated a lean toward *neutral* over *portable* before reading the tickets,
and explicitly flagged it as a lean rather than a decision. It is recorded here because it
matches where the evidence landed, not as the reason it landed there; the argument above
stands on the two measurements without it. The one place the analysis changed direction
was pre-publication issue 212's reporter's objection, which is the reason emulation survives at all rather than
being refused outright.
