# ADR-0002 — How a row says its derived value is stale

**Status:** Accepted *(2026-09-21)*
**Date:** 2026-09-21
**Issue:** pre-publication issue 258. Ruled by the hub after a
reversal; see **Provenance**.

## Context

A row holds text and a value **derived** from that text — today an embedding, tomorrow a
translation, a summary, an extracted entity set. The text changes. Nothing about the derived
value changes, and nothing anywhere says it is now wrong.

A consuming app named the two shapes this takes and they are different problems:

- **Imported chunks** are write-once per translation revision. A correction re-derives that
  chunk.
- **Authored blocks** are edited in place, and the derived value is stale from that instant.

Serving retrieval against text that no longer exists is the failure, and it is silent: the
vector is well-formed, the query is correct, the answer is confidently about a paragraph
somebody rewrote last week. The app asked for staleness to be **representable as a column
convention** rather than four app-specific inventions, on the grounds that every
content-bearing consumer meets it. That is the request this answers.

## Decision

**A content fingerprint, computed in the CL shell, stored in an ordinary column.**

`defschema` declares what a derived column is derived *from*:

```lisp
(defschema chunk (:table "chunks")
  (:id        :uuid    :primary t)
  (:title     :string)
  (:body      :text)
  (:structure :text)                                   ; layout, not words
  (:embedding :vector  :dimensions 1536 :derived-from '(:title :body)))
```

and that declaration is the convention. (The list is quoted because a field spec's option
values are evaluated — pre-publication issue 258. A single input needs no quote: `:derived-from :body`.) mnemosyne adds two companion columns —
`embedding_fingerprint` and `embedding_deriver` — as real fields, so DDL, drift detection and
casting need no special case for them.

**THE FINGERPRINT COVERS EXACTLY THE INPUTS TO THE DERIVED VALUE.** That sentence is the whole
convention. An embedding over title and body means a fingerprint over title and body: not the
row, not everything convenient. Wider, and it reports staleness that is not there — which is
the version stamp's defect, arrived at by a different route. Narrower, and it misses real
staleness, which is the failure the convention exists to prevent.

`mnemosyne/derived:content-fingerprint` frames the inputs; the **caller supplies the hash
function** and mnemosyne does not choose one. `derived-stale-p` is the comparison. Finding
stale rows compares a stored value against a bind parameter, which every backend does.

### Why not a version stamp

A stamp says **the row changed**. That equals *the content changed* only when the row carries
nothing but content, and rows carry more. The `structure` column above is the concrete case:
reorder one block and every row below it bumps its version, so a stamp-driven check re-derives
all of them with no text changed. That is the difference between re-embedding a paragraph and
re-embedding a document because somebody moved an image — at a cost per row that is a model
call.

**The stamp is still right for row versioning**, which is a different question with a different
answer already in the tree: `mnemosyne/id:touch!` stamps `vid` and the modified time. Nobody
should unify them later; one asks *did this row change* and the other asks *did the text this
value was derived from change*.

### Why the deriver is a second column and not part of the fingerprint

An embedding is a function of text **and model**, so a reader could argue the model belongs
inside the fingerprint. It is kept out for one reason, and it is operational rather than
conceptual: a model or dimension change has to drive a **bulk** re-derive, and

```lisp
(:select (:id) :from ("chunks") :where (:<> :embedding_deriver "text-embedding-3-small"))
```

is one indexed predicate against a bind parameter, where a fingerprint that mixed the model in
would need every row read and rehashed to find the same set. So: the fingerprint answers *has
the content changed*, the deriver answers *was this produced by what we use now*, and keeping
them apart is what makes the second question cheap.

**STALENESS IS THE DISJUNCTION OF THE TWO, and that has to be said because two columns invite
checking one.** They can disagree, and each disagreement alone is staleness:

| fingerprint | deriver | meaning |
|---|---|---|
| differs | matches | the text was edited |
| matches | differs | the model or its dimension changed |
| differs | differs | both happened |

So `derived-stale-p` takes **both pairs** rather than the fingerprint alone — the disjunction is
executable rather than a sentence a reader has to remember. A caller comparing only the
fingerprint misses every row that needs re-deriving after a model change, which is the bulk case
the second column exists for; one comparing only the deriver misses every edit. The derivers are
compared only when supplied, so a consumer that does not version its deriver is asking the
fingerprint question alone and gets that answer.

## Consequences

- A schema declaring `:derived-from` gains two columns. That is visible in `schema-ddl` and in
  drift reports, which is the point: the convention is in the table, not in an app's habits.
- `content-fingerprint` **requires** a `:hash` argument. No default, because a default
  fingerprint function is a compatibility promise nobody made — two consumers that disagree
  about the hash disagree about staleness, silently.
- The framing is **length-prefixed**, not a join on a separator. `"ab" + "c"` and `"a" + "bc"`
  must not produce one fingerprint, and any separator can occur in prose.
- mnemosyne does not compute a hash in SQL and does not require one to exist there. That is
  what makes this work on SQLite, and it is the same posture as ADR-0001: the framework does
  not emulate what a backend cannot do.
- Nothing forces a consumer to use it. A row without the declaration behaves exactly as before.

## Alternatives considered

- **A version stamp on the embedding row.** Ruled first and reversed; see above and
  **Provenance**. It is cheaper — no hash — and it re-derives on writes that changed nothing
  the value depends on.
- **A hash computed by the database.** Rejected: `sha256()` exists on Postgres and not on
  SQLite, so the finding query would be backend-dependent, and mnemosyne would be emulating or
  refusing per backend for something the CL shell can do identically everywhere.
- **Let each app invent it.** What is happening today, and the reason this is in scope: four
  consumers produce four conventions, none of which a framework query can read.
- **Put the model inside the fingerprint.** Conceptually tidy, operationally worse; see above.

## Provenance

**Ruled twice, and the first ruling was wrong for a reason worth recording.** The hub ruled the
*stamp*, accepting an objection I raised: that a hash's finding query is backend-dependent,
since Postgres has `sha256` and SQLite does not. The hub then reversed it, because that
objection is true only of a hash computed **by the database**, which nobody had proposed. A
shell-computed hash in an ordinary column compares two stored values, and backend-neutrality —
the entire basis of the first ruling — does not distinguish the options at all.

What decided it on the second pass was the consuming app's own schema: a `structure` column
holding ordering and styling, which a stamp cannot tell apart from words. The same app had
already arrived at the pattern independently for re-translation — `post_blocks.text_hash` and
`post_block_texts.source_hash`, computed in the shell, stored in ordinary columns — so *has
this text changed since we last derived something from it* is one question with two consumers,
and one fingerprint answers both.

My own objection was the thing that produced the wrong ruling, which is worth stating plainly:
it was a correct fact about a design nobody had proposed, applied as though it ruled out the
design that was.
