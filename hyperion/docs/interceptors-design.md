# Typed interceptor pipeline (design)

*A flagship abstraction: a Coalton-typed, Pedestal-style interceptor pipeline,
protocol-agnostic (HTTP **and** agentic AI). Supersedes the "Lack middleware vs
interceptors" question in [middleware-security.md](middleware-security.md).*
**Status:** the pure pipeline core is **built and green** (`hyperion/interceptor`:
the `Flow` ADT + `execute`), and **`execute-effect`** — *effects at the edge*
(option 1) — is built, tested, and dogfooded (Elise's crisis guardrail: enter Halts
on blank input, the LLM turn is the edge effect, a leave stage appends resources).
What's left: the effectful-stage cases (the translator; retry/re-inject) that decide
whether option 1 stretches, the HTTP Context, and a name — see Sequencing.*

## The idea

Model the **request→response cycle as data**: a queue of **interceptors**, each a
value with `enter`/`leave`/`error` stages over a typed **Context**. The runner walks
the queue forward calling `enter`, then unwinds calling `leave` (reverse), routing to
`error` on failure; any stage may short-circuit (enqueue/dequeue, terminate). This is
Pedestal's model — middleware as *data in the cycle*, not opaque function-wrapping.

**Parameterize over the Context type**, and the *same* machinery serves multiple
protocols:

- **HTTP.** `Context = { request, response, ... }`. Interceptors: security headers,
  CSRF, session, **i18n locale resolution**, auth (JWT/session), content-negotiation
  (JSON API vs HTML/HTMX render). The pages/ui/api split becomes interceptor chains.
- **Agentic AI (praxeon).** `Context = { perception, plan, action, budget (Kairos) }`.
  Interceptors: context assembly (Kairos), tool-call dispatch, guardrails (Elise's
  crisis check), usage accounting. The deliberate/act loop *is* an interceptor chain.

One unified, compile-time-checked pipeline for HTTP and AI — the common-core dream.

## The client "flip" — a third instance (and the best first prototype)

*Provenance: raised while designing a consuming app's outbound-services layer
(`courier`: email/SMS behind a neutral protocol), captured here so
Hyperion is read into the loop.*

Pedestal interceptors are **server-side**: the request arrives from outside
(given), `enter` folds forward until a **handler** produces the response, `leave`
unwinds the outbound response. The natural question when we needed an outbound HTTP
*client* (hyperion has none; praxeon calls `dex:post` inline): **is it blasphemous
to reverse the roles** — the client originates the request and processes the
response through the *same* pipeline?

**It isn't. It's the deeper symmetry.** Both directions are one shape — **a
bidirectional pipeline wrapped around a single central request→response effect**:

- **Server.** Request given → `enter` folds forward → the **handler** produces the
  response *(the effect in the middle)* → `leave` unwinds.
- **Client (the flip).** `enter` folds forward *building* the request (URL,
  headers, auth signing, body) → the **network round-trip** *(the effect in the
  middle)* → `leave` unwinds the received response (status→outcome, deserialize,
  map errors).

The `Context = { request, response }` is **neutral about who originates what**;
only the **location of the central effect** differs (your handler vs. the
network). So a third instance joins HTTP-server and agentic-AI:

- **HTTP client.** `Context = { request, response }`. Interceptors: `auth-header`
  (sign/refresh), `json-body`, `retry`/backoff, `rate-limit`, `log`, redirect
  handling. `courier`'s SendGrid/Twilio/SES/SNS backends become request-building
  interceptors + a response-parsing `leave`, not hand-rolled `dex:post`.

**Why this is the best first prototype for the effect question below.** Pedestal's
handler *is already* an effectful pivot, so "effects at the edge" (option 1) maps
onto the client **exactly**: one obvious, singular round-trip is the edge effect
between a pure `enter` and a pure `leave` — cleaner than a server handler, which
can fan out into many effects. Prototype the effect model on the client flip
first, then generalize to server and agentic.

**Prior art vs. what's novel.** Client-side request/response *middleware stacks*
are well-trodden — Finagle `Filter` (explicitly symmetric client/server), Rust
Tower `Service`/`Layer`, clj-http middleware, Go `RoundTripper`. **Novel here:**
the Pedestal *interceptor* form (enter/leave as data, reverse-order unwind, a typed
outcome/`Flow`) rendered **in Coalton and parametric over the Context, so the exact
same `(Interceptor :c)` value type serves both directions** — `execute`'s
polymorphic type is the proof it works for either.

**Two subtleties to preserve.** (1) Reverse-order `leave` still *means* something
client-side: the outermost interceptor should wrap everything (sign auth early,
refresh-and-retry on 401 late; log request first, response last) — proper nesting
needs the reverse unwind. (2) **Retry/redirect re-runs the effect** — a
401-refresh or a 3xx-follow wants to perform the round-trip again. That is the
typed analog of Pedestal's `enqueue`/re-inject in `leave`, and a concrete stress
test for whichever effect model wins.

## Why Coalton (and where the effects go)

The **pure, typed** part is the pipeline mechanics + the Context transitions: the
queue, ordering, short-circuit, error routing, and a Context type that makes a
mis-wired chain unspellable. That belongs in Coalton.

**The tension:** real interceptors *perform IO* in `enter`/`leave` (read a cookie,
sign a JWT, call an LLM) — that's not pure. Options to resolve (this is the key open
design question):

1. **Effects at the edge (recommended to explore first).** Interceptor stages are
   pure `Context → Context`; the Context *carries* pending effects (requests to
   perform), and a CL **runner** executes them between stages. Keeps the core pure;
   costs a small effect-description vocabulary.
2. **Typed-but-effectful stages.** Stages are CL functions constrained by a Coalton
   *protocol* (the shape is typed; the bodies do IO). Less pure, more pragmatic —
   the Context type still prevents mis-wiring.
3. **Free/monadic.** Stages return descriptions of effects; the runner interprets
   them. Most principled, most machinery.

## Relationship to what exists

- **Lack middleware (Clack's model)** is the pragmatic baseline the MVP ships on
  (Ring-style function wrapping). Interceptors *wrap or replace* it later — a Lack
  middleware can host the interceptor runner.
- **`hyperion/output` `with-output-style`, i18n `resolve-locale`, the coming
  session/auth** are all interceptor-shaped already (they act at the request
  boundary) — they become the first interceptors, which is why the MVP informs the
  design.

## Sequencing (updated — pipeline first)

**Decision: pipeline first** (revised from an earlier "defer past the MVP" stance —
the deadline is soft, and a clean typed abstraction the AI *and* the human can reason
about is worth it). Where we are:

1. **Done — the pure pipeline core** (`hyperion/interceptor`): the `Flow` ADT and
   `execute` (enter-forward / leave-reverse, short-circuit), parametric over the
   context `:c`. Compiles + green.
2. **Next — settle the effect model on the client "flip"** (above): a small
   `hyperion/client` (outbound HTTP), driven by a consuming app's `courier` need. Its
   single round-trip is the cleanest edge effect; **retry/redirect is the stress
   test** (Open Questions). This is where effect model 1/2/3 gets picked.
3. **Then — the HTTP *server* Context** (request/response) + the first real
   interceptors: locale resolution, content-negotiation, session/JWT auth, security
   headers. The consuming app's MVP request path flows through these.
4. **Then — unify praxeon's** deliberate/act loop onto the same `(Interceptor :c)`.

The consuming app's **MVP can still ship in parallel** on the current modules where the
pipeline isn't ready yet; the two converge as interceptors land — nothing blocks the
landing page on the effect model.

## The Context is where aion (immutable data) layers in — cleanly

The thing threaded through the chain is the **Context**, and every stage returns a
*new* Context. That is exactly Clojure's model — a persistent map flowing through an
interceptor queue — and it is the clean seam to introduce **aion's immutable /
persistent data structures** later: today the Context can be a simple record; when
aion's persistent map lands, the Context *becomes* one, and structural sharing makes
the "return a new Context per stage" pattern cheap. Nothing above the Context type
changes. (Design the Context as an opaque, value-semantics thing now so that swap is
non-breaking.)

## Why this is the pitch: Clojure's lessons, realized in CL

This is the thesis in one artifact. Clojure's best ideas — **data-oriented design,
immutability/persistent structures, and interceptors (middleware as data in the
cycle)** — are borrowed here, but realized on **Common Lisp + Coalton**: a live
image, macros, the condition system, and *static* types where they earn their keep —
**without the JVM ecosystem's weight**. Coalton adds what Clojure can't: the pipeline
is **compile-time checked and parametric**, so a mis-wired chain doesn't run, and an
AI reasoning about it has real guardrails. CL was always the better host for these
ideas; this shows it.

## Open questions

- Effect model (1/2/3 above) — the decision the rest depends on.
- Context representation across protocols: one generic `Context` with protocol
  payloads, or a typeclass/`Into` boundary per protocol?
- How the queue is manipulated (Pedestal's `enqueue`/`terminate`) in a typed setting.
- Where it lives: `hyperion` (HTTP) + a shared core for the agentic reuse, or a
  standalone typed-pipeline lib the ecosystem depends on.
- Relationship to the typed HTMX vocabulary (`hyperion/htmx`) and content-negotiation.
- The client "flip" as first prototype: does a `hyperion/client` module land as the
  effect-model proving ground (driven by a consuming app's `courier`), before the
  server/agentic unification?
- **Prototype success criterion — the re-inject test.** Retry/redirect needs a
  `leave` stage to *re-run the edge effect* (401-refresh, 3xx-follow). Under "effects
  at the edge" that stays pure ONLY if `Flow` (or the Context) gains a typed
  **`Reinject`/`Retry`** outcome the runner loops on — Pedestal's `enqueue`, typed.
  The current core has **no** re-inject variant, so **adding one is the first
  concrete task**, and whether a *pure* re-inject expresses refresh/redirect cleanly
  decides effect model 1 vs. 2/3.
