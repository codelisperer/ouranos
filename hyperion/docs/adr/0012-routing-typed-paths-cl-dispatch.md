# ADR-0012 — Routing: typed path patterns in Coalton, dispatch in CL

**Status:** Accepted · 2026-08-05

## Context

Hyperion had no URL dispatch. Every application hand-rolled the same `cond` over
`:request-method` and `:path-info` — five of them in the tree, four inside this repo
(pre-publication issue 121):

| Where | |
|---|---|
| `hyperion/examples/active-search/app.lisp:137-152` | |
| `hyperion/examples/active-search-db/app.lisp:215-230` | |
| `hyperion/examples/coalton-repl/app.lisp:284-299` | |
| `praxeon/src/web.lisp:447-478` | the framework itself |

The cost was not verbosity. Three capabilities were missing outright:

1. **No path parameters.** `/contacts/:id` could not be expressed. Every example is
   flat-routed, and *no example in the tree has a detail view* — the examples were
   shaped by what the dispatcher could not do.
2. **405 was unreachable.** Method and path were tested in one `and`, so a wrong method
   on a known path returned 404. The two failures are indistinguishable in that shape
   even in principle.
3. **The table was opaque.** A `cond` cannot be enumerated, so a route listing, a
   dev-time overview, or the OpenAPI emit that ADR-0009 / [#46](https://github.com/codelisperer/ouranos/issues/46)
   imagine had nothing to read.

ADR-0009 lists "routes" as one bullet inside a `hyperion/api` capability, which framed
routing as a detail of the *data* API. The hypermedia surface needs it just as much and
needed it first: all four hand-rolls above serve HTML.

## Decision

**Split routing at the purity seam, per ADR-0002.**

**`hyperion/path` (Coalton).** Path templates as checked values. A `Segment` is a
`Literal`, a `Param` (`:id`) or `Rest` (`*`); a `Pattern` is their ordered list.
`parse-pattern` builds one; `path-matches?` and `path-bindings` match a request path.
Pure, total, no IO — and `%walk` matches exhaustively on `Segment`, so adding a segment
kind is a compile error at every site that must handle it rather than a silent
fallthrough.

**`hyperion/router` (CL).** Everything that cannot be pure: handler closures, the Clack
env, response shapes, and signalling on a bad declaration. `route` declares one, `router`
collects them in order, `mount` nests a sub-router, `to-app` yields a Clack handler.

**Methods reuse `hyperion/htmx:Verb`** rather than declaring a second five-constructor
enum. The `hx-<verb>` a link sends *with* and the method a route answers *on* are one
choice; two copies could drift. `verb->method` is a second rendering of the existing type
(`verb->attr` renders the attribute), and the CL side reaches it through the house bridge
established by `hyperion/html:verb-attr` — a keyword, an `ecase`, a literal constructor
*inside* `(coalton …)`, a String back.

Three consequences of the shape, which is why this is a framework capability and not app
code:

- **405 is structural.** Matching asks "does the path match" and "does the method match"
  separately, so a path claimed under another method answers 405 with a computed `Allow`.
- **HEAD and OPTIONS are derived, never declarable.** HEAD is the GET route with the body
  dropped; OPTIONS answers from the same `Allow` set. Derived, they cannot disagree with
  the routes they describe. (Declaring either signals.)
- **The table is data.** `routes` reads it back; `describe-routes` prints it.

**Handlers keep the plain Clack `(env -> response)` signature.** Bindings ride the env
under `+params-key+`, read by `path-param`. Porting a hand-rolled dispatcher moves the
clauses and touches no handler body.

**First match wins.** No specificity reordering: `/contacts/new` before
`/contacts/:id` shadows as written, and the reverse order does the surprising thing.
That is a real trap, so it is pinned by a test rather than left to the reader.

## Consequences

- Path parameters exist, so a detail view is expressible — the precondition for the
  examples pre-publication issue 132 will port and for any CRUD surface.
- 405 with a correct `Allow`, and OPTIONS, come free everywhere routing is used.
- `mount` gives framework modules a way to *contribute* routes instead of an app retyping
  them: `hyperion/dev`'s reload endpoints and `praxeon/web`'s chat surface are the two
  standing cases (pre-publication issue 132).
- The route set being data unblocks the introspective half of #46 without committing to
  the rest of it.
- **Not addressed, deliberately:** parameter *typing* (`:id` binds a string; a typed
  contract is ADR-0009's question), route *generation* (naming exists via `:name`, reverse
  URL building does not), and any interceptor integration — `hyperion/interceptor` is the
  natural composition point, but the effectful-stage question it names as open
  (`docs/interceptors-design.md`) is unresolved, and pre-publication issue 130 wants the same answer. Routing
  should not settle it by accident.
- Nothing in the tree is ported by this ADR. pre-publication issue 117 may replace the server under Hyperion,
  and the examples are frozen until then; the capability lands first, adoption follows.

## Alternatives considered

**A CL-only router (regex or a hand-written matcher).** Simplest, and what most CL web
libraries do. Rejected because pattern matching is exactly the shape Coalton is for —
a small closed ADT, total functions, exhaustive matching — and the house doctrine
(ADR-0002) would be hollow if the framework reached for CL the first time typing was
inconvenient. The `Segment` exhaustiveness check is a concrete payoff, not a gesture.

**A Coalton-only router, handlers included.** Rejected: a handler closes over the Clack
env and performs IO, which AGENTS.md forbids in Coalton and which `Pattern`'s purity
depends on. The seam is where effects begin, and that is precisely at the handler.

**A trie or radix tree instead of an ordered list.** Rejected as premature. Route tables
here are tens of entries; an ordered list is O(n) with a trivial constant, and it gives
first-match-wins semantics that are predictable to read. The `Pattern` representation is
opaque to CL, so a trie can replace the walk later without touching a call site.

**A `Method` ADT of its own, separate from `htmx:Verb`.** Rejected — see Decision. Two
enums over the same five values, one of which already exists.

**Returning `(List (Tuple String String))` from the matcher.** Rejected on the
representation rule (`docs/coalton-patterns.md` §7): `Tuple` is a `define-type`, whose
representation Coalton promises nothing about across compilation modes, so a CL caller
destructuring one would work in development mode and break in release. `path-bindings`
returns a flat `(List String)` — a promised representation — and CL pairs it up.

## Provenance

The split was not the starting position. The first sketch typed *everything* routing
touched, including a `Method` ADT that CL would construct per request; writing the CL
boundary is what killed it. `hyperion/html:verb-attr` shows the house bridge — CL passes a
keyword, Coalton renders a String — and following that pattern honestly meant method
comparison would cost an `ecase` plus a Coalton call *per request* to answer a five-way
enum question. Typing it bought a compile-time typo check at the declaration site and
nothing else. Keeping the typed vocabulary but validating **once at declaration** rather
than per request is the version that survived, and reusing `Verb` rather than minting a
second enum fell out of the same pass.

Two library details were checked rather than assumed, and both changed the code. A
`Head` constructor was drafted and abandoned: `head` is inherited from `COALTON/LIST`, and
Coalton is case-insensitive, so it would have collided — which is what prompted asking
whether HEAD should be declarable at all. It should not; deriving HEAD and OPTIONS from
the GET route and the `Allow` set is better design, and the collision is what surfaced the
question. Separately, `concat-map` was written before checking: the stdlib spells it
`concatMap`, a *different* symbol under case-insensitivity, and `make-list` is not in the
list library at all — both replaced with hand-rolled recursion.

The bug that cost the most time was not in the routing code. Every dispatch test failed
with "invalid number of arguments: 2" while the same call worked at the REPL:
`hyperion/tests` is one package shared by every `*-tests.lisp` file loaded `:serial`, and
`session-tests.lisp` defines its own `%env` of a different arity, loading *after*
`router-tests.lisp` and silently clobbering it. The helpers are `%rt-`prefixed now and the
hazard is recorded at the top of the file, because the next author will hit it too.
