# Hyperion — Vision & Open Questions

*A working alignment doc, mirroring `praxeon/docs/praxeon-vision.md`. Claude asks
pointed questions; you answer fully and candidly. Answers re-order
`docs/roadmap.md`. Fill in inline or in chat (Claude transcribes).*

**Status:** interview open (started 2026-07-15). Founded on the vision aligned in
the Praxeon session from which Hyperion was originally spun out of
`praxeon/src/web.lisp`.

> What's already decided (from that session): HTMX-first (no templating);
> generic components + industrial HTMX wiring, **never** domain components;
> Parenscript for all JS (no Node); a CSS DSL; REPL-driven hot-reload as the
> signature feature; typed HTMX vocabulary in **Coalton**, rendering/extensibility
> in **CLOS + Spinneret**; pluggable server backends (Woo/Hunchentoot). Roadmap
> items: editor integration, a Studio (Ceramic desktop or web), AI artifact
> generation, project-gen delegated to `cons`.

---

## 1. The component model — how typed, and where's the escape hatch?

Coalton owns the typed HTMX value; CLOS+Spinneret own rendering. **Which HTMX
attributes get typed ADTs** (all of them, or the high-value swaps/triggers/targets
first)? What's the **escape hatch** for raw attributes the types don't cover yet —
a `raw-attr` case, so you're never blocked?

> **A:**

## 2. Parenscript — the whole JS story, or a stepping stone?

Is Parenscript *the* client-JS answer indefinitely, or a stepping stone to a typed
**Coalton→JS** compiler later? Do we dogfood immediately (rewrite the hot-reload
poller / auto-scroll in Parenscript), or extract Praxeon's hand-written JS as-is
first and Parenscript-ify later?

> **A:**

## 3. CSS — build a DSL, or wrap an existing one? And Tailwind-without-Node?

`cl-css` / `LASS` / bespoke for the CSS DSL? Bulma is easy (CDN). **Tailwind
normally needs a Node JIT to scan classes** — how do we want to interoperate
without Node: a CL class-scanner + generator, a prebuilt subset, or skip Tailwind?

> **A:**

I am happy to leverage existing prior art in the Lisp->CSS space. Let me know if
there are any obvious pros/cons to one or the other existing alternatives. I
vaguely feel like LASS has the best chance of helping emulate what Tailwind
does.

I am happy targeting Bulma and similar CSS frameworks first. Tailwind feels like
something that should be replaced by native CSS generation in CL. In other
words, I'd like to explore doing what tailwind does, but entirely within a
CL-powered framework and workflow for generating HTML code. A clean DSL that can
include both spinnet-targeting html and parenscript-targeting JS would be
awesome.

## 4. Client reactivity — Parenscript-generated JS, or embrace Alpine.js too?

Your proven MPP stack is HTMX + **Alpine.js** + Bulma. Does Hyperion bless
Alpine for client-side reactivity (tabs, dropdowns, keyboard nav), or aim to
cover that with Parenscript-generated behavior so there's *no* JS framework at
all?

> **A:**

I definitely want to embrace Alpine.js, too. ALso need to decide between current HTMX
or v4 which is supposedly coming out soon. See [htmx v4](https://four.htmx.org/).

*When a page needs more than Alpine (a genuinely component-shaped island), see
"Universal views" below — the same Spinneret s-expr, compiled to the client the way
Reagent compiles Hiccup. Not a replacement for HTMX+Alpine; the heavier tool for the
rare case that needs it.*

## 5. The hot-reload engine — extract as-is, or rebuild?

Praxeon's engine is a zero-dep mtime poll. Extract it verbatim first, or go
straight to OS-native file-notify (FSEvents/inotify/kqueue)? And the flagship —
**runtime conditions with restart-selection in the browser** (the debugger over
the wire) — is that an early priority or a later showpiece?

> **A:**

Rebuild using parenscript. I would like to decide on a file extension for CL
code intended to be rendered by parenscript.

## 6. Component library — which generic components ship first?

From the MPP patterns: forms, live-search, master/detail tables, modals, tabs,
pagination, toasts, file upload. **Pick the first 3–5.** (Praxeon's chat window is
a *domain* component — does a generic "conversation/stream" component belong in
Hyperion, or stay app-side?)

> **A:**

## 7. The Studio — Ceramic desktop or web service, and what does it *do*?

Which first — a **Ceramic** (Electron+CL) desktop app or a plain web service? And
what's its job: component gallery/preview, live-edit, driving the hot-reload loop,
scaffolding, AI generation? What's the MVP studio?

> **A:**

## 8. Scope vs Praxeon — where's the line?

Praxeon's `web.lisp` mixes engine (generic) with chat (domain). Confirm the split:
Hyperion gets the server + hot-reload + typed-HTMX + generic components; Praxeon
keeps the agent/turn/observer/token/chat glue and *depends on* Hyperion. Anything
you'd move differently?

> **A:**

## 9. Success at 3 / 6 / 12 months

Concrete milestones — a released framework with a demo app, the hot-reload loop
extracted and dogfooded, a component gallery, the Studio, a paper? Any deadlines?

> **A:**

## 10. What am I not asking?

The question I should have — your own framing of where Hyperion goes.

> **A:**

## Interceptors, reimagined — the thesis in one abstraction

*Status: the pure core (`Flow` + `execute`) and the effects-at-the-edge driver
(`execute-effect`) are built, tested, and dogfooded. What remains is a naming
decision and settling the effect model past the single-pivot case. Practical usage:
user-guide "Interceptors, reimagined"; depth: `docs/interceptors-design.md`.*

**The reframing.** Most frameworks treat middleware as *function-wrapping* — an
onion of `(handler)` closures you thread a request through. Pedestal's insight is to
make the cycle **data**: a queue of interceptors, each a value with `enter`/`leave`
stages over a typed **context**, walked forward then unwound in reverse. Hyperion
takes that one step further — the interceptor is a **Coalton value parametric over
the context `:c`**, so *one* compiled `execute` provably works for any context, and
the compiler rejects a chain that forgets an outcome. "Middleware as data" becomes
"middleware as a **typed, checkable** value." That is the whole thesis in one
artifact: Clojure's best idea, realized on CL + Coalton, with static guarantees
Clojure can't offer — guardrails a human *and an AI* can reason about.

**One shape, three instances.** Because it's parametric over `:c`:
- **HTTP server** — `:c = {request, response}`; stages are locale resolution,
  auth, CSRF, content-negotiation. The handler is the effect in the middle.
- **HTTP client (the "flip")** — the *same* value type, roles reversed: `enter`
  *builds* the request (URL, auth signing, body), the **network round-trip** is the
  middle, `leave` unwinds the response. Outbound services (`courier`: email/SMS)
  become request-building interceptors, not hand-rolled `dex:post`.
- **Agentic AI** — `:c = {perception, plan, action, budget}`; the deliberate/act
  loop *is* an interceptor chain. Elise's crisis guardrail is the first real one.

The context is *neutral about who originates what*; only **where the central effect
sits** differs. `execute-effect` captures exactly this: run `enter`, perform the one
impure pivot, unwind `leave` — server handler and client round-trip are the same
code, "just where the middle is."

**The killer example — Elise's translator agent.** Make Elise converse in the
user's language: a **secondary LLM agent translates** user→Elise on the way in and
Elise→user on the way out, wrapped around deliberation. Composed into the single
edge effect (`translate-in ∘ run-turn ∘ translate-out`) it runs on `execute-effect`
today; decomposed into its own effectful `enter`/`leave` **stages** it's the case
that pushes the effect model past "one central pivot" — the honest next design
pressure (see below). Either way it's the vivid demonstration: an interceptor that
*is* an agent. (Pick a translation-suited model, configured apart from Elise's main
provider; prefer the higher-quality model on the crisis path.)

**The biggest open question — the effect model.** Pure stages can't read a
cookie or call an LLM. Three ways to reconcile (see design doc): (1) effects at the
edge — *chosen and built* for the single-pivot case; (2) typed-but-effectful stages;
(3) free/monadic. The translator and any retry/redirect (`enqueue`/re-inject) are
the stress tests that decide whether 1 stretches or we adopt 2. The success
criterion is the **re-inject test**: a `leave` that re-runs the edge effect (401→
refresh, 3xx→follow) — which needs a typed `Reinject` outcome the runner loops on.

**The naming question.** *"When everything is middleware, nothing is middleware."*
"Interceptor" is accurate (Pedestal-honest) but overloaded. Candidates to weigh —
Stage, Waypoint, Relay, Conduit, Cycle, Band — or keep Interceptor and own it.
Undecided; the abstraction ships regardless.

> **Q for the roadmap:** is `hyperion/client` (the flip, driven by `courier`) the
> next build, or does the agentic instance (Elise's guardrail + translator) come
> first? Both exercise `execute-effect`; the client adds retry (the re-inject test),
> the agent adds effectful stages (the translator).

## Universal views — one s-expr, two backends (the Reagent lesson)

*Status: idea, deliberately deferred. HTMX + Alpine is the default and covers most
interactivity; this is the answer for the **rare** page that is genuinely
component-shaped (a rich client widget), when Alpine isn't enough. Keep it as
simple as ClojureScript's **Reagent** — no more.*

**The idea.** Keep **one** Spinneret-shaped view syntax — `(:div :class "x" …)` —
and give it **two compiler backends**, chosen by target:

- **server** — Spinneret as it is today: s-expr → HTML string.
- **client** — a Parenscript macro that walks the *same* s-expr and emits
  **`React.createElement`** calls, exactly the way **Reagent compiles Hiccup**.

```lisp
;; one source shape:
(:button :class "primary" :onclick inc (str "Count: " count))
;;   server  -> Spinneret     -> "<button class=primary>Count: 0</button>"
;;   client  -> Parenscript   -> React.createElement("button",
;;                                  {className:"primary", onClick:inc}, "Count: "+count)
```

No JSX, no Node build: **React vendored as a static file (UMD global)**, Parenscript
emits the `createElement` tree. The view language is the same homoiconic Lisp on both
sides — this is "CL all the way down" for the client, and the cleanest contrast with
React/Next (JSX + a bundler) and topcoat (a `view!`/`$()` grammar parsed into a
compiled host): here the "JSX section" is *literally Spinneret s-exprs*.

**Keep it simple (the explicit constraint).** Follow Reagent: **lean on React** for
the virtual DOM, diffing, and reconciliation — do **not** build a bespoke signals
runtime. React-as-a-library (via CDN) is the accepted, contained dependency; the
payoff is that the client backend is a *small macro*, not a framework. A lighter
signals/direct-DOM runtime (the SolidJS/topcoat `$()` shape) is **explicitly out of
scope** until something proves Reagent-style is insufficient — that is "more
complicated than necessary."

**Self-contained — no npm, no JVM, no asset pipeline (THE differentiator).** React
is a **vendored static file** (`resources/js/vendor/react.production.min.js`, served
by `hyperion/static`) — exactly like `htmx.min.js` / `bulma.min.css` today. No CDN
at runtime, no npm, ever. Parenscript emits `createElement`, so there is **no JSX →
no Babel**. The bundler's other jobs already have CL-native answers: whitespace
minification via `hyperion/output` `:compact`; serving via `hyperion/static`; "HMR"
via the live-image hot-reload; CSS via the CSS DSL. **The whole Webpack/Vite/
Turbopack layer is displaced, not reimplemented** — React collapses to one static
file plus a small macro.

*If* a heavier pass is ever wanted (identifier mangling, tighter gzip) — likely
**not**, since PS output + `:compact` is already tight and vendored libs ship
pre-minified — `hyperion build` shells out to a **single self-contained binary**,
never a JVM or a Node service: Go's `esbuild` or `tdewolff/minify` (one binary; JS +
CSS + HTML + SVG), or a Rust minifier (**OXC** / SWC-core / `minify-js`) if we want
Rust — a natural first "**`cons` integrates a Rust tool**" case. Crucially we do
**not** need Closure-style *advanced* optimization: that solves whole-program
dead-code elimination over a large third-party dependency graph, a problem we don't
have — we author tight Parenscript and vendor pre-minified libraries. **Avoiding the
JVM (ClojureScript's Closure) is the whole point.**

**Scope, smallest-first.**
1. A `createElement`-emitting Parenscript macro over the core Hiccup subset (tags,
   attributes, children, `dolist`/seq interpolation) + attribute normalization
   (`class`→`className`, `for`→`htmlFor`, `style` object). This alone renders
   client-side React components authored in Spinneret syntax — the whole win.
2. **Islands only** — mount such a component into a server-rendered page where
   needed; do not turn the app into an SPA.
3. **Isomorphic (SSR + hydrate)** — server-render the tree with Spinneret and
   hydrate the *same* source client-side — is the aspiration, not the starting
   point; defer until #1/#2 earn it.

**Caveats.** Syntactic parity with Spinneret is incremental (start with the subset
Reagent covers); React's runtime weight is the accepted trade for simplicity;
hydration (if pursued) needs both backends to agree on structure — which they do by
construction, since they're one source.

**Prior art to copy, not reinvent:** Reagent / Rum (ClojureScript). Same move, one
language over: Hiccup→`createElement` becomes Spinneret-s-expr→`createElement`.

---

## Synthesis (Claude fills after your answers)

*A restatement in your terms, a re-ordered roadmap top, and threads to drop/defer.*
