# Aion's Coalton story

*What the typed layer is actually for, across every capability aion has today — `csv`,
`log`, and now `uv`. Written 2026-08-04 to make [#86](https://github.com/codelisperer/ouranos/issues/86)'s
claim true by describing what is really being built, rather than by softening the claim.*

Read [`coalton-gap-analysis.md`](coalton-gap-analysis.md) for what Coalton already gives us,
and [`cl-shell-design.md`](cl-shell-design.md) for where clean CL does the work. This doc is
the third leg: **why aion has a Coalton layer at all, and what belongs in it.**

---

## 1. The problem this fixes

`ECOSYSTEM.md` and the root README call aion the **"Coalton-first functional stdlib."**
Until `aion/uv` landed, aion contained **zero** `coalton-toplevel` forms, while declaring
`:depends-on ("coalton")`. That gap is the single most damaging credibility problem in the
tree, because aion is where a reader goes to see the typed-core thesis in practice.

The tempting fix — "build persistent sets, then the claim is true" — is not wrong, but it
answers the wrong question. It says *how much* Coalton aion should have. It does not say
**what aion's Coalton is for**, and without that, every future module re-litigates the
question and the answers drift.

## 2. The pattern was already discovered, in `aion/uv`

`aion/src/uv/types.lisp` is aion's first `coalton-toplevel`, and its own design doc states
the reasoning better than an abstract principle could:

> libuv speaks in integers — a bitmask for what changed about a file, a negative number for
> what went wrong — **and integers are where silent bugs live.** The Coalton layer decodes
> them into ADTs, once, at the boundary.

So `FileEvent`, `UvErrorKind`, `RunMode` and `DirentKind` exist not because ADTs are nice,
but because a `-2` and a `4` crossing a boundary untyped is a defect waiting for the worst
possible moment. The decode happens **once**, at the edge, and everything above it reasons
in names.

That is not a libuv-specific insight. It generalises across everything aion does.

## 3. The thesis

> **Aion's Coalton layer is where untyped external vocabularies become typed values.**

Every capability aion has is a boundary between something untyped and the rest of the
system, and in every case the untyped vocabulary is the bug surface:

| Capability | The untyped vocabulary crossing the boundary | What it should become |
|---|---|---|
| `uv` | integers — error codes, event bitmasks, handle kinds | `UvErrorKind`, `FileEvent`, `RunMode`, `DirentKind` **(done)** |
| `log` | keywords — `:trace`/`:info`/`:warn`, `:pretty`/`:json`, a plist of fields | `Level` (with `Ord`), `Layout`, a structured `Event` |
| `csv` | characters, and an FSM whose states are bare keywords in an `ecase` | `Dialect`, `ParseState`, a total transition |

This is a *stronger* claim than "a functional stdlib," and a more defensible one. "We have
persistent collections" invites the question *why not just use Coalton's?* — to which the
gap analysis honestly answers **you should**. "Untyped protocols become typed values exactly
once, at the edge" is a claim about where bugs come from, and it is one the codebase can be
held to.

It also composes cleanly with the other half of aion's job
([`cl-shell-design.md`](cl-shell-design.md)): **the guarantee lives in the Coalton type, the
mechanism lives in whatever CL is fastest.** Decode at the boundary; loop, mutate, and do IO
underneath it.

## 4. The constraint that keeps it honest

> **Decode once per operation, not once per byte.**

This is the rule that stops the thesis becoming a licence to Coalton-ify everything, and it
falls straight out of `cl-shell-design.md` §6: cross the boundary where a *decision* is made,
not inside a hot loop.

A `Level` is decided once per log call. A `Dialect` is decided once per reader. A
`UvErrorKind` is decided once per failed syscall. Those are the right granularity —
the decode is amortised to nothing and the type is load-bearing.

A CSV parser's state transition happens **once per character**. Putting that in Coalton
would mean a typed call per byte of every file we read, and nothing in
`cl-shell-design.md` §3 lets us guess whether that is free — we run in development mode,
where types are CLOS classes and optimizations are off, so *any* number measured today is
meaningless as a release claim. So: **model the FSM as an ADT and prove the transition total
in Coalton; then decide, by measurement, whether the loop calls it per character or whether
CL runs a table derived from it.** The design is typed either way; only the calling
convention is in question.

## 5. What each capability gets

### `aion/log` — done (the second worked example)

The smallest, the highest leverage, and the one every other framework already depends on.

- **`Level` as an ADT with an `Ord` instance.** Gating is currently a keyword comparison;
  with `Ord` it becomes `>=` and the compiler rejects a level that does not exist. Today a
  typo'd `:warm` is a runtime surprise.
- **`Layout` as an ADT** (`Pretty` | `Json`), so `render` is exhaustive by construction
  rather than by an `ecase` that a third layout would silently fall through.
- **A structured `Event`** — level, category, message, fields — because `render` is already
  a *pure function* (`level cat message fields -> String`). It is the easiest genuinely-pure
  thing in aion to lift, and the effectful `lm:info` call stays exactly where it is.

The house rule against interpolated log strings (`AGENTS.md`) becomes type-enforced rather
than review-enforced: if a field must be a `Field`, you cannot pass a `format` result.

### `aion/csv` — done, as an OPT-IN sibling system

- **`Dialect` as a Coalton record**, with the five presets as values. `dialect-with` is
  already an override-merge; typed, it cannot produce a dialect with a delimiter equal to
  its quote character.
- **`ParseState` as an ADT** — with a `transition` the compiler proves total over every
  (state × class × seen × skip-blank) combination.

  **Not by replacing the `ecase` in `parse.lisp`, which is what this section originally
  said to do — and that instruction was wrong.** `aion/csv` is `:depends-on ()`
  deliberately, so the portable backend loads on bare SBCL/CCL/ECL/ABCL with no Coalton
  compile, and [`csv-design.md`](csv-design.md) promises a CL face with *"no Coalton
  required"*. Putting Coalton inside `aion/csv` would take that away and would not load at
  all on three of the four implementations. The implementation correctly refused.

  **The generalised rule, since §3's thesis will meet this again:** decode at the boundary,
  but *not* by adding a dependency to something whose freedom from dependencies is the
  point. A sibling system plus a conformance test gets the type without the cost.

  **What stops an unexecuted type from being decorative** — §4's honest worry, since forcing
  the hot loop through Coalton is still an open measurement question — is **differential
  testing**. `aion/csv/types` carries a reference parser built entirely from the transition;
  the suite runs a corpus through both it and the shipping CL parser and requires exact
  agreement. Two independent implementations of one specification: break a rule in the
  `ecase` and the conformance test fails. It also fits what `aion/csv` already is —
  `csv-design.md` calls the portable backend *"the oracle the fast backends are tested
  against"*, and the oracle now has a typed specification.
- **`Reduced` stays a CL struct for now.** It is a *protocol* shared with the coming
  `aion/xform`, and its representation crosses the CL boundary constantly. Revisit when
  transducers land — that is when its shape is actually decided.

### `aion/uv` — done, and the reference

No further work; it is the worked example the other two should read first.

## 6. What deliberately stays CL

- **Every syscall, stream read, timer, and log emission.** No IO in Coalton (house rule).
- **The per-character parse loop**, until measured (§4).
- **`condition`s and `restart`s.** Recoverable failure is CL's condition system, not a
  `Result` threaded through the typed core — the house style is explicit about this, and
  `aion/uv/conditions.lisp` already does it correctly: decode the integer into a
  `UvErrorKind`, then *signal*.
- **`Reduced`**, for now (§5).

## 7. Sequence

1. **`log`** — **done.** `Level` + `Eq`/`Ord`, `Layout`, `FieldValue`/`Field`/`Event`, and a
   `render` that is exhaustive over `Layout`. Gating is `>=` on the type; `level!` and `setup`
   now *signal* on a level that does not exist, where a typo'd `:warm` used to be accepted and
   then silently never match. The CL shell kept exactly what must be CL: the clock, log4cl
   emission, and the one decision only CL can make — which of CL's open type universe each
   field value is, classified once per field into `FStr`/`FRaw` at the boundary.
   `aion/src/log/types.lisp`; the log suite went 24 → 62 checks.
2. **`csv`** — **done**, but not where this doc first assumed. `aion/csv` is dependency-free
   on purpose (`:depends-on ()`, so the portable backend loads on bare SBCL/CCL/ECL/ABCL,
   and L4 of csv-design.md promises a CL face with "no Coalton required"), so the typed core
   went into a SEPARATE opt-in system, `aion/csv/types`, which `aion/csv` does not depend on.
   `ParseState` + `CharClass` + `Action` and a transition the compiler proves total; a
   `Dialect` whose special characters are provably distinct, which the CL DEFSTRUCT cannot
   express. What stops an unexecuted type from being decorative is differential testing: a
   reference parser built entirely from the transition, run against the shipping parser over
   a corpus chosen for the cells where they could disagree. It found one real divergence
   (CRLF as two terminators). The §4 measurement is deferred honestly, because the hot loop
   is untouched.
3. **Persistent sets ([#5](https://github.com/codelisperer/ouranos/issues/5))** — still
   worth building, but note what changes: under this thesis it is no longer *the* thing
   that makes aion "Coalton-first." It is a gap-fill on Coalton's own substrate, valuable on
   its own terms, and no longer load-bearing for the claim.

That reordering is the practical payoff of writing this down. The claim in
[#86](https://github.com/codelisperer/ouranos/issues/86) is discharged by `log` and `csv` —
days of work on capabilities that already exist and already have tests — rather than by
persistent sets, which is weeks and was gating go-live for no good reason.

## 8. How this reads to an outsider

The launch pitch has a sharper sentence available than "a functional stdlib for CL":

> **Every untyped protocol Ouranos touches — libuv's integers, CSV's characters, a
> logger's keywords — gets decoded into an algebraic type exactly once, at the edge. Above
> that line, nothing reasons about a `-2`.**

That is checkable, it is already true of `aion/uv`, and it says something specific about
where bugs come from. It also feeds
[#103](https://github.com/codelisperer/ouranos/issues/103) directly: "what makes an Ouranos
framework LLM-consumable" has a concrete first answer — *the boundary is typed, so a
generated call site cannot invent a state that does not exist.*
