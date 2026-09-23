# ADR-0002 — An agent reaches data through parameterised means, not generated SQL

**Status:** Accepted *(2026-09-21)*
**Date:** 2026-09-21
**Issue:** [#400](https://github.com/codelisperer/ouranos/issues/400). Orders
[#372](https://github.com/codelisperer/ouranos/issues/372) (the semantic-search seam, deferred)
and is the pattern [#258](https://github.com/codelisperer/ouranos/issues/258)'s praxeon half will
be built on.

## Context

An app integrating praxeon wants its agent to answer questions from its database. The obvious
reading is **generated SQL**: give the model the schema, let it write the query. That is the
default answer in the wider ecosystem, and it is the wrong starting point here.

The framework has nearly every piece needed to do it the other way, which is why this is mostly a
decision to record rather than a thing to build — *nearly*, and the exception is below.
`register-means` takes a name, a description, a
function, a JSON-schema for its arguments, and a **capability**; `means-permitted-p` fails closed,
and `agent-means-for` assembles the tool table from the caller's authority so a means the caller
may not use is *absent* rather than filtered later (#122). Casting and binding are mnemosyne's:
`(:select … :where (:= :name ?))` is data, and a value travels as a bind parameter, which
mnemosyne's own suite asserts by reading back the parameter list.

What was missing is the documented pattern. **The absence of one is what makes generated SQL the
default answer**, because it is the only shape anybody has written down.

## Decision

**A means per query. Parameterised. The model selects and supplies arguments; it never composes
the query.**

```lisp
(actor:register-means
 agent "contacts-by-company"
 "Find contacts at a company the asker is allowed to see."
 (lambda (args)
   (let ((company (gethash "company" args)))
     (render (data:contacts-for :asker *asker* :company company))))  ; asker NOT from args
 :schema (one-required-string "company" "The company name to search for.")
 :capability "read:contacts")
```

Four properties follow, and each is one generated SQL does not have.

**A knowable blast radius.** The set of queries that can run is enumerable by reading the
registration sites — or at runtime, from `agent-means-for`. With generated SQL the set is whatever
the model emits, which is not a set anybody can review.

**Authorization as an argument, not a remembered discipline.** The asker's identity is supplied by
the *host* at call time and is not one of the model's arguments, so one registration serves every
caller and answers differently for each. A model cannot widen its own authority by choosing
arguments, because the argument that decides authority is not in the schema.

**An audit trail that means something.** The event stream carries the means name and its
arguments (`:tool-call`), so the record says *what was intended*. A log of generated SQL says only
what ran.

**Evidence for what to build next.** After a few weeks the logs say which questions are actually
asked. If generated SQL is ever wanted, there is a measured case for it rather than a guess — and
the same logs say which means deserve an index.

### One thing did need building, and #400's premise was wrong about it

#400 says *"Nothing needs building for an app to expose data to an agent safely."* Measured while
writing this ADR's own example: **`run-turn` took no `permit` and passed none.** `deliberate` and
`act` both accept one, but the turn loop — the framework's main entry point — called them without,
so a means declaring a capability was never described to the model and was refused as *no such
means registered* if the model named it anyway. An app following this pattern would have found its
data means silently absent, and its only recourse would have been to drive `deliberate` and `act`
by hand.

So the pattern was unexecutable through the path every reader would use, and the ADR's own example
is what found it. `run-turn`, `run-turn-through` and a delegated sub-agent now carry the permit;
the delegation case matters because a subtask that silently lost it would be the same hole one
level down.

This is the third instance this week of a surface complete, documented as load-bearing, and
unreachable from the path that matters (#435, #437), and the first found by *writing the document
that recommends it*.

## Consequences

- **A new question needs a new means.** That is the cost, and it is the point: the work of adding
  one is the review that generated SQL skips. An app that finds this friction unbearable has
  learned something about how many distinct questions it really has.
- **The pattern is what makes #372 safe to build when its trigger fires.** A semantic-search seam
  is a means like any other — an embedding argument, a *k*, a filter the host constrains — so the
  two are ordered rather than alternatives.
- **Nothing here is enforced by the framework.** An app can still hand a model a SQL string; no
  type prevents it. This is a pattern, and the honest name for it is a pattern.
- Where a means must run several queries, it is still one means: the unit is the *question*, not
  the statement.
- **A capability-bearing means needs `:permit` at the call site.** `run-turn` without one is the
  no-authority case and is correctly refused; that is the fail-closed rule of #122 rather than a
  defect, and it is now reachable rather than unconditional.

## Alternatives considered

- **Generated SQL, guarded by prompting.** Rejected, and not on style. It is three surfaces at
  once: **exfiltration** (the model reads what the *schema* permits, not what the *asker*
  permits), **injection** (the prompt is attacker-reachable wherever user content enters context —
  a retrieved document, a filename, a support ticket), and **unbounded cost** (a join nobody
  predicted, on a table nobody profiled). None of the three is mitigated by instructions; all
  three are mitigated by the model not writing the query.
- **Generated SQL against a read-only replica with a row-level-security policy.** Better, and
  still exfiltration-shaped: RLS answers *which rows may this database user see*, and the question
  is *which rows may this asker see* — which is why the asker ends up as a session variable the
  application must remember to set on every connection. That is the remembered discipline this
  decision removes, relocated into the database.
- **A single `query` means taking a structured query object.** The model composes `(:select …)`
  instead of SQL. Tempting because mnemosyne's queries are data, and rejected for the same reason
  as the first option: the blast radius is again whatever the model emits, only in parentheses.
  Data is not the safety property; *a fixed shape with bound values* is.
- **Document nothing and let each app decide.** The status quo, and the reason this ADR exists:
  with no pattern written down, the default is the one the wider ecosystem supplies.

## Provenance

Filed by a session that had checked the pieces before proposing anything — `register-means`'s
capability argument, `means-permitted-p`'s fail-closed comment, and the absence of any doc
describing their composition. What was missing was a reader being able to find the shape.

**An earlier draft of this paragraph said "this ADR adds no code because none was missing", and
that was wrong before it was written down.** Writing the example found `run-turn` carrying no
permit, so the ADR ships with the threading that makes its own recommendation executable. The
claim is corrected here rather than deleted, because a reader who finds code in a decision record
that says it added none would trust the record less, correctly.

It ships with a test rather than only prose, and that is deliberate. #435 and #129 are both
instances of *a mandated path nothing walks* — a surface complete, documented as load-bearing, and
called from nowhere but its own suite. A pattern document with no exercised example is the same
artefact one level up: it would be a document rather than a mandate on the day it landed. The
suite asserts the three properties that are praxeon's (the asker is an argument, the runnable set
is enumerable, the call is audited); the fourth (a value binds rather than interpolates) is
mnemosyne's guarantee and is asserted there, so it is cited rather than re-measured here.
