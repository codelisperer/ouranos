# Hyperion — the HTMX-first web framework

**A full-stack web framework for Common Lisp, biased toward the live image.**

Hyperion is what you reach for when you want a *reactive* web application in Common Lisp
with no Node.js toolchain in sight: the server renders, HTMX drives the interactivity, and
the browser refreshes itself while you edit the running program.

---

## What it is, and why it exists

The modern web frontend is drowning in JavaScript build tooling. HTMX showed that most of
that complexity is unnecessary — hypermedia plus a server that renders fragments gets you a
long way toward SPA-grade interactivity. Common Lisp is an unusually good host for that
model: it has the macros for an ergonomic HTML DSL, the condition system for legible
failure, and — decisively — a **live image**, so you can redefine the running program and
watch the change appear.

Hyperion leans into all of it, with a bias toward **full-stack Common Lisp**:

1. **HTMX instead of templating.** The server renders HTML fragments; HTMX swaps them.
   Hyperion provides typed, composable coverage of HTMX's *feature surface* — swaps
   (including out-of-band), triggers, targets, boosting, `hx-vals`/headers, indicators,
   history, the SSE/WS extensions — as **generic components and wiring, never
   domain-specific ones.**
2. **Parenscript for all JavaScript.** No hand-written JS, no Node. What little client code
   is needed is authored in Lisp and compiled to JS.
3. **A CSS DSL.** Generate CSS from Lisp; interoperate with Bulma/Tailwind *without* Node.
4. **REPL-driven development.** A Figwheel-style hot-reload loop — edit, save, the server
   rebuilds around preserved state, the browser refreshes itself, and a compile error shows
   as a browser overlay.

Hyperion is a **library only** — no CLI, no project manager of its own. Creating, building
and running Hyperion apps is [`cons`](Framework-Cons.md)'s job (the ecosystem's "cargo for
Lisp"); Hyperion supplies web-app *templates*, `cons` supplies the machinery.

Its initial code was **extracted from `praxeon/src/web.lisp`**, which already had a working
configurable Clack server, the Figwheel-style watcher with a compile-error browser overlay,
request utilities, and a theming hook. That prior art is why the framework arrived working
rather than hypothetical.

---

## Where it sits in the DAG

The Ouranos dependency order is strict, low → high; a framework **never** depends on one to
its right (ASDF errors on cycles).

```
aion → cons → mnemosyne → elenchon → hyperion → praxeon
                                    (hermes — off-DAG satellite leaf-lib)
```

| Rule | What it means for Hyperion |
|---|---|
| May depend leftward | `aion`, `cons`, `mnemosyne`, `elenchon` are fair game. |
| May never depend rightward | Nothing in Hyperion may reference `praxeon`. Praxeon consumes Hyperion for its web surface, not the other way round. |
| Aux systems may reach right (if acyclic) | Core systems may not. Hyperion's DB-touching pieces are **aux ASDF systems** so the core carries no DB dependency. |
| `hermes` is off-DAG | It depends only on `aion` and nothing in the core DAG depends on it. **An app that needs to send email or SMS** (password reset, notifications, 2FA codes) **reaches for `hermes`, not a Hyperion-local integration.** |
| Combined examples live highest | An example needing agents lives in praxeon, not here. |

The aux-system discipline is visible in the ASDF file: `hyperion` core depends on Coalton +
the web stack; `hyperion/session-db` and `hyperion/auth-db` add `mnemosyne` (a *leftward*
dep, kept aux so core stays DB-free); `hyperion/desktop` adds the webview lifecycle;
`hyperion/import` is Plump-only so you can convert markup without loading the framework.

---

## Current status

**Pre-alpha (0.0.0), but no longer vacant.** The web core is extracted, live, and green;
Praxeon runs on it and dogfoods it.

### Working today

| Module | What it does |
|---|---|
| `hyperion/server` | The Clack backend behind a neutral protocol — the **app** declares the handler, `default-server` picks from what is loaded, `HYPERION_SERVER` overrides — plus `start`/`stop`. |
| `hyperion/http` | Request/response utilities over the raw Clack env: body, form/query params, cookies, headers, JSON. |
| `hyperion/htmx` (Coalton) + `hyperion/html` | The typed HTMX vocabulary (`Swap`/`Verb`/`Trigger`/`Target`/`Duration`) with pure `->string` renderers, plus a CL/Spinneret render bridge and a generic OOB combinator. |
| `hyperion/dev` | The hot-reload loop: `watch`/`reload!`/`mark-reloaded`/`unwatch` + the compile-error browser overlay. Multi-system watch shipped. |
| `hyperion/js` | Parenscript helpers (no Node): the hot-reload poller plus generic, selector-parametrized interaction helpers (`stick-to-bottom`, `autogrow-textarea`, `enter-submits`, sticky-solidify). |
| `hyperion/interceptor` | A typed, Pedestal-style pipeline in Coalton: `Flow` + `execute` (pure) + `execute-effect` (effects at the edge), parametric over the context. |
| `hyperion/session` | Cookie identity, a `store` protocol, an in-memory backend, a thread-safe per-session bag, and REPL/dev management (list/inspect/reset/kill). |
| `hyperion/channel` | A broadcast channel: an append-only log many readers consume by cursor, non-destructively. Transport-agnostic. |
| `hyperion/i18n` | Per-locale JSON dictionaries, flat `:section/key` lookup, `{named}` interpolation, `resolve-locale` + a cookie language switch. Adding a language is dropping a file. |
| `hyperion/static` | Static file serving — content-type by extension, `..`-traversal-guarded, cross-platform. |
| `hyperion/markdown` | Markdown → HTML, **safe by default** (raw HTML in the source is escaped). |
| `hyperion/output` | One knob for output formatting — dev **pretty**, prod **compact** — for HTML *and* JS. |
| `hyperion/import` | HTML snippet → Spinneret s-expressions (a porting aid; separate Plump-only system). |
| `hyperion/session-db` *(aux)* | A **mnemosyne-backed** `store` backend — sessions survive a restart and span processes. Dogfoods the mnemosyne query builder (upsert via `ON CONFLICT`, `COUNT(*)`). |
| `hyperion/auth-db` *(aux)* | A mnemosyne-backed identity store: users, PBKDF2 passwords, temp-password flag, and roles that can be **granted and revoked** after creation (`grant-role` / `revoke-role`, idempotent, compare-and-swap on `vid` so a second process cannot silently lose an edit); store-less `users-ddl` so an app owns its own migration timeline. |
| `hyperion/desktop` *(aux)* | `run-app` + lifecycle + the native `hyperion-view`. **M1 proven end to end on all three platforms.** |
| Examples | `active-search` (Bulma + HTMX + Alpine + Parenscript), `active-search-db` (over a mnemosyne migration), `coalton-repl` (a typed Coalton REPL in a native desktop window; CSS via LASS, JS via Parenscript). |

Test suites are **fiveam** and green (sessions 100/100; the DB-backed session store 15/15
against in-memory SQLite).

### Planned / in progress

Routing (generalize the hand-rolled `cond` dispatch), the CSS DSL proper, a generic
component library, security middleware (`secure-app` over Lack), the dev-reload endpoints
owned by the framework rather than hand-rolled per app, tier-2 dynamic-resource hot-reload,
`hyperion/api` (the typed data API), and desktop M2–M5 (dialogs, `cons desktop` scaffold,
the updater/installers).

An interim `hyperion/cli` system still exists in-tree but is **slated for retirement** once
`cons build|serve` reach parity — see [ADR-0007](https://github.com/codelisperer/ouranos/blob/main/hyperion/docs/adr/0007-split-into-six-frameworks-monorepo.md).

---

## Design narrative

This is the reasoning, the trade-offs, the rejected alternatives, and the questions still
open. Decisions that are expensive to reverse are recorded as ADRs — linked, not restated.

### Typed HTMX vocabulary in Coalton, rendering in CLOS + Spinneret

The split is the house style ([ADR-0002](https://github.com/codelisperer/ouranos/blob/main/hyperion/docs/adr/0002-coalton-core-cl-shell.md)) applied to the web:

- **Coalton owns the ontology of an interaction.** `Swap (InnerHTML | OuterHTML | BeforeEnd
  | AfterBegin | None | …)`, `Trigger (Event | Every Duration | Revealed | Intersect | Load
  | …)`, a checked `Target`, `Verb (Get | Post | …)`, plus OOB, `hx-vals`, headers,
  indicators, history/push-URL and the SSE/WS extensions. A real `Duration` type makes
  `"700ms"` unspellable-wrong; today's stringly-typed alternative is one typo
  (`"beforend"`) away from silent breakage, and nothing checks that a *combination* is
  valid. That is exactly the error class a type checker should own.
- **CLOS + Spinneret own rendering and extensibility.** A `render` generic that apps and
  Hyperion both specialize, runtime-open so components compose. Coalton does *static*
  typeclass dispatch — it is **not** CLOS underneath — so the two layers meet at a thin,
  deliberate boundary.

**Open question:** how much of HTMX gets typed ADTs (all of it, or the high-value
swaps/triggers/targets first), and what the **escape hatch** looks like for attributes the
types don't cover yet — a `raw-attr` case, so you are never blocked by the framework's own
coverage gap. Also unsettled: whether to target current HTMX or **v4**.

**All-Spinneret templating** is decided ([ADR-0003](https://github.com/codelisperer/ouranos/blob/main/hyperion/docs/adr/0003-all-spinneret-templating.md)) — no Selmer/Djula. The cost of that
purity is porting existing HTML, which is why `hyperion/import` exists: it converts a
snippet to pasteable Spinneret source. It is honest about its limits — attribute order is
normalized, and exotic attribute names (`@click`, `hx-on:click`) may want a hand touch-up.
Treat the output as a faithful starting point, not a style-perfect transcription.

A related sharp edge, now handled: Spinneret validates attribute names **during
macroexpansion** and warns on anything off-spec (`HX-POST is not a valid attribute for
<INPUT>`). Hyperion registers the client-framework prefixes (`hx-`, `ws-`, `sse-`, `x-`,
`@`, `_`) on load, so HTMX, Alpine and hyperscript just work; adding another must happen
inside `eval-when (:compile-toplevel …)` because validation is a compile-time event.

### Parenscript — CL → JS, zero Node

All client JS is authored in Lisp and compiled by Parenscript
([ADR-0004](https://github.com/codelisperer/ouranos/blob/main/hyperion/docs/adr/0004-parenscript-client-js.md)). The dogfooding rule is explicit: the framework's own
hot-reload poller, auto-scroll and textarea helpers are Parenscript, not hand-written JS.

An **audit result worth keeping true**: the `hyperion/js` helpers are *generic* — selectors
are passed in by the app, and the only URLs are the framework's own dev endpoints
(parameterized). No app-specific JS belongs in `hyperion/js`.

Two open threads. Whether Parenscript is *the* answer indefinitely or a stepping stone to a
typed **Coalton→JS** compiler ("v42.5" on the far horizon); and a small but unresolved
ergonomics question — what file extension marks CL source that is meant to be rendered as
JS.

**Alpine.js is blessed**, not competed with. The proven stack is HTMX + Alpine + Bulma, and
Hyperion covers Alpine's attribute prefixes deliberately. Parenscript-generated behavior is
not meant to replace Alpine for tabs, dropdowns and keyboard nav.

### The CSS DSL, and Tailwind without Node

Bulma is easy (a vendored/CDN stylesheet). Tailwind is the hard one, because it normally
needs a **Node JIT** to scan classes — precisely the dependency the thesis exists to avoid.
The stated preference is to *do what Tailwind does entirely within a CL-powered workflow*:
a CL class-scanner + generator, or a prebuilt subset, rather than shell out to Node. Prior
art is welcome rather than reinvented — `cl-css` and **LASS** are the candidates, with LASS
judged the likeliest to emulate the Tailwind model. The `coalton-repl` example already uses
LASS for CSS and Parenscript for JS, which is the intended end state in miniature: a clean
DSL covering both Spinneret-targeting HTML and Parenscript-targeting JS.

Theming stays an **app-level hook** — neutral framework defaults plus app CSS passed in —
so the generic layer never learns a specific app's colors.

### The hot-reload dev loop — the signature feature

The property everything else follows from: **state ≠ server.**

Your app hands `watch` a **builder thunk** that returns a fresh Clack handler, closing over
persistent state. On save, the changed file is recompiled; on a clean compile the old server
is stopped, the builder is called again — *reusing the same state* — and a reload epoch is
bumped, which `:dev` pages poll and answer with `location.reload()`. A **compile error
becomes a red browser overlay**, and the last-good server keeps serving underneath, so you
never lose the session while fixing the typo.

Honest limits, documented rather than papered over:

- **Function edits are automatic** (render functions are resolved by symbol, so the next
  request uses them). **Structural changes** — a new file, package or dependency — need a
  `ql:quickload` or a restart, because the watcher does per-file `compile-file`+`load` and
  cannot reorder for a newly introduced package. An `asdf:load-system`-based reload for
  structural changes is a possible future refinement.
- Reload systems **in dependency order** or you hit `The name "X" does not designate a
  package` — a dependent's `defpackage` referencing a local-nickname whose package doesn't
  exist yet.
- The watcher is a **zero-dep mtime poll** with 1-second `file-write-date` resolution. The
  planned upgrade is OS-native file-notify (FSEvents/inotify/kqueue, via Shinmera's
  `file-notify`) behind the *same* `watch` interface, so it's a drop-in.
- **Multi-system watch shipped**: `:systems '("my-app" "hyperion")` lets you co-develop an
  app and the framework together. The common case stays zero-config.

**The flagship, still unbuilt: runtime conditions in the browser with restart selection.**
When a handler signals, don't drop to the REPL debugger — capture the condition *and its
restarts*, render them in the browser, and let the user **pick a restart** to resume the
very computation. The debugger, over the wire. No JS framework can do this, because no JS
framework has restarts. Mechanism: `handler-bind`/`restart-case` parks the turn's
background thread on a channel, the browser POSTs a choice, `invoke-restart` resumes. Best
sequenced *after* the session model so overlays are scoped to a session rather than global.

Why this matters strategically: Figwheel-style hot source reload **with state preserved**
is essentially absent from the CL web world. 40ants **Reblocks** does reactive server-side
widgets over WebSocket — a different, heavier animal. A lightweight "edit → recompile →
browser refreshes, session intact" loop is a genuine differentiator; lean into it.

### Server backends behind a protocol — and why polling, not SSE

Hyperion declares **no HTTP server** (pre-publication issue 139). The application depends on the Clack handler
it wants — `clack-handler-hunchentoot` (pure CL, every platform) or `clack-handler-woo`
(Unix, and it binds libev at load time) — and `default-server` picks from the backends
actually loaded into the image, overridable with `HYPERION_SERVER`. No backend shape leaks
above the protocol, and neither of these two is a destination: both go when the native
libuv server lands (pre-publication issue 117).

Framework-declared backends were how every Linux desktop bundle came to die at startup on
`libev.so.4` — the framework had made a native-dependency decision on behalf of apps that
never asked for one.

That neutrality has a real cost, and it produced the framework's most instructive design
note. Woo is a **single-threaded async (libev)** server, which imposes two hard rules that
were hit head-on while building the agent chat surface:

1. **A handler must never block the event loop.** A blocking SSE drain inside a handler
   froze the *entire* server — every other request, including the page itself, timed out.
2. **A socket can only be written from its own event-loop thread.** Draining events on a
   background thread and writing to the Clack streaming writer blew up with
   `The value NIL is not of type SB-SYS:SYSTEM-AREA-POINTER` — the libev write path is
   invalid off the loop thread.

True SSE therefore needs a thread-per-connection server (Hunchentoot) or a Woo-specific
`ev_async` integration that would be fragile and non-portable — defeating the "backend is
configurable" goal. So the shipped transport is **HTMX polling**: handlers stay quick and
non-blocking, long work runs on a background thread, and a small poller picks up results.
It behaves **identically on Woo and Hunchentoot with no per-server code.**

The upshot: **polling is the portable floor, not a ceiling.** `hyperion/channel` is
deliberately transport-agnostic — a poller reads it via `since`; a WebSocket or SSE
transport would *push* from the same channel. That makes real-time an **additive step, not
a rewrite**, and WebSockets are worth promoting to a first-class Hyperion protocol once a
low-latency UX (token streaming, presence) justifies the second code path.

### Sessions behind a `store` protocol

A `session` is an id plus a thread-safe key/value bag that is **opaque to Hyperion** — the
framework never learns what an app keeps in it. Backends sit behind a small `store`
protocol: `make-memory-store` is the default, `hyperion/session-db` is the mnemosyne-backed
durable one (the data bag serialises as a readable s-expr, read back with `*read-eval*`
bound to nil).

This is the **HTTP layer of a two-layer session design**: the agent/conversation session —
where *many* browsers attach to *one* conversation — lives in praxeon and is built on top of
this. It was also the fix for a shared-session "bubble-stealing" bug, and it is the same
generic infrastructure an app uses for **auth/login** (`hyperion/auth-db` builds on it).

Session ids are 128 bits from the OS CSPRNG (`aion/random`, pre-publication issue 95) and **rotate at privilege
change** (`rotate-session`, pre-publication issue 207) — and `wrap-session` holds the `Set-Cookie` so an
application is never handed a header it can silently drop. Both were real defects: ids came
from `cl:random`, a Mersenne Twister whose state is recoverable from observed output, and a
session id *is* observable by design.

**A curated `secure-app` middleware stack (security headers/CSP, CSRF, secure cookies) is
PLANNED, not shipped** — see "Planned / in progress" above, and
[`hyperion/docs/middleware-security.md`](../../hyperion/docs/middleware-security.md), which
still calls it a *proposed* shape. There is no `secure-app`, no CSRF token machinery and no
security-header middleware in `hyperion/src` today. This paragraph claimed it was bundled
while the same page listed it as planned nine sections earlier (pre-publication issue 227).

XSS *is* already defended **at output** — Spinneret auto-escapes and
`hyperion/markdown:render` is safe by default — which is real, and is the reason the
overstatement was plausible enough to survive: one true sentence next to an aspirational one.

### Interceptors, reimagined — the thesis in one abstraction

Most frameworks treat middleware as *function wrapping* — an onion of closures. Pedestal's
insight is to make the request→response cycle **data**: a queue of interceptors, each a
value with `enter`/`leave` stages over a typed context, walked forward then unwound in
reverse. Hyperion takes it one step further: the interceptor is a **Coalton value
parametric over the context `:c`**, so *one* compiled `execute` provably works for any
context, and the compiler rejects a chain that forgets an outcome. "Middleware as data"
becomes "middleware as a **typed, checkable** value" — Clojure's best idea with static
guarantees Clojure can't offer.

**One shape, three instances**, precisely because it's parametric:

- **HTTP server** — `:c = {request, response}`; stages are locale resolution, auth, CSRF,
  content negotiation; the handler is the effect in the middle.
- **HTTP client (the "flip")** — same value type, roles reversed: `enter` *builds* the
  request, the network round-trip is the middle, `leave` unwinds the response. Outbound
  integrations become request-building interceptors rather than hand-rolled `dex:post`.
- **Agentic AI** — `:c = {perception, plan, action, budget}`; the deliberate/act loop *is*
  an interceptor chain. Praxeon's crisis guardrail is the first real one in production use.

`execute-effect` captures the shape exactly: run `enter`, perform the one impure pivot,
unwind `leave`. A `Halt`/`Failure` in `enter` **skips the effect** — a guard that rejects a
request never spends the LLM call.

**The biggest open question is the effect model.** Pure stages can't read a cookie or
call an LLM. Three reconciliations were considered: (1) *effects at the edge* — chosen and
built for the single-pivot case; (2) typed-but-effectful stages; (3) free/monadic. The
stress tests that will decide whether (1) stretches or (2) is adopted are a translator agent
decomposed into effectful `enter`/`leave` stages, and the **re-inject test**: a `leave` that
re-runs the edge effect (401 → refresh, 3xx → follow), which needs a typed `Reinject`
outcome the runner loops on.

A smaller open item: **the name.** "When everything is middleware, nothing is middleware."
*Interceptor* is Pedestal-honest but overloaded; Stage, Waypoint, Relay, Conduit, Cycle and
Band were floated. Undecided — the abstraction ships regardless.

### i18n — drop a file, get a language

`resources/i18n/<code>.json` files *are* the set of supported locales; per-request
resolution is `?lang=` > cookie > user preference > `Accept-Language` > default, with an
explicit choice persisted to a cookie ([ADR-0006](https://github.com/codelisperer/ouranos/blob/main/hyperion/docs/adr/0006-i18n-approach.md), Provisional).

The interesting half is the **split with praxeon**. String *extraction* — parse an HTML
template with Plump, pull translatable text and attributes (`title`/`alt`/`placeholder`/
`aria-label`), generate heuristic `section/key`s, emit a base `en.json` plus the template
rewritten with `translate` calls — is deliberately **LLM-free** and lives here, low in the
DAG. The **AI translation** half (base dictionary → N locales) lives in praxeon, because
only the rightmost framework may reach an LLM. Keeping JSON ↔ template keys in sync so
renaming a key is one edit is the design constraint. The dictionary is also the seam toward
DB-backed translation later, with `translate` unchanged.

### The desktop capability — decided, and M1 proven

The "Ceramic vs Tauri vs web" question is settled by
[ADR-0008](https://github.com/codelisperer/ouranos/blob/main/hyperion/docs/adr/0008-desktop-shell-cl-native-webview.md): a **CL-native, out-of-process OS webview.** A dumped SBCL image
runs the Hyperion server **in-process** on `127.0.0.1:<free port>` and `uiop:launch-program`s
a tiny per-OS launcher (a `webview.h`-style shim over WebView2 / WKWebView / WebKitGTK)
pointed at that URL. The webview is a pure renderer; all interaction is HTMX-over-HTTP to a
local server that already has full OS and filesystem access **because it is the native
process.**

**Out-of-process is the crux.** `webview_run()` must own the GUI main thread and blocks;
in-process it collides with SBCL's main thread and crashes macOS AppKit calls into `ldb`.
Because HTMX means we need **no in-process JS↔native bridge at all**, the webview can live
in its own process and the hazard simply disappears.

The framing that made the decision tractable: "from scratch" splits in two. Writing an
**HTML renderer** is infeasible (engineer-millennia) and was never on the table; **FFI to
the OS-native webview** plus CL glue is feasible and bounded — it is literally Tauri's
architecture with the Rust layer replaced by CL. An OS webview is an unavoidable C
dependency in *every* language; the only choice is which small shim to bind.

**Rejected alternatives**, each for a reason worth remembering:

| Option | Why not |
|---|---|
| **Tauri (Rust)** | Off-thesis (not CL) — but the **rational fallback** if cross-platform time-to-ship ever outranks purity for a specific app. Say so up front when it applies. |
| **Electron / Ceramic** | Node + bundled Chromium (~150–200 MB); Ceramic is ~5 years unmaintained, pinned to Electron 5, coupled to the old Lucerne stack. |
| **In-process CFFI to `webview.h`** | The main-thread/`ldb` crash above; out-of-process avoids it for free. |
| **`cl-webkit` / WebKitGTK direct** | Linux-only in practice — Nyxt, the flagship pure-CL webview app, is *adding Electron* in 4.0 over WebKitGTK's weak macOS/Windows support. |
| **EQL5 (ECL + Qt/QtWebEngine)** | ECL, not SBCL — a second implementation plus a Qt/Chromium dependency; abandons the SBCL-exclusive thesis. |
| **McCLIM** | Renders its own widget world; no HTML/CSS/DOM engine, so it cannot run a Spinneret/HTMX page. |

**The honest cost**, stated in the ADR rather than discovered later: the webview is the easy
~10%; **Tauri's non-rendering glue is the ~90%** — updater self-replace, installers, native
FFIs, the CI matrix — weeks-to-months of real work Tauri hands you free. OS code-signing and
macOS notarization are an unavoidable tax, identical for Tauri and Electron.

Placement follows the DAG: **Hyperion owns the capability** (launcher + localhost lifecycle
+ the thin native-FFI layer), **`cons` scaffolds it** (a `desktop` target kind), **apps
consume it.** The backend is a *mode*, not a hardcode — `:embedded` (default, offline-capable
one-off), `(:remote url)` (the GitHub-Desktop model, webview over a remote backend), or
`(:hybrid url)`. The lifecycle closes the launch race with a readiness poll before pointing
the webview anywhere.

**Status: M1 done (2026-07-25)** — `hyperion/desktop:run-app`, the native launcher (with a
`--check` prerequisite doctor that names what's missing and how to install it), verified on
Windows 11 (MSVC *and* mingw-w64), macOS/Apple clang and Ubuntu/WebKitGTK 4.1. The example
app is the **visual Coalton REPL**, chosen deliberately because it is local-only — no
updater or installer needed — so it validates window + webview + localhost + Hyperion +
lifecycle before taking on the shipping glue.

### Distribution and self-update

[ADR-0010](https://github.com/codelisperer/ouranos/blob/main/hyperion/docs/adr/0010-desktop-distribution-and-self-update.md) answers what ADR-0008 hid behind one line. The forcing question was
sharp: *SBCL cannot cross-compile — `save-lisp-and-die` dumps an image for the host platform
only — so must every release be hand-built by a developer on each OS?* If true, a
self-updating app is impractical, because irregular releases make an updater pointless.

The answers:

- **Native-runner CI matrix; never cross-compile.** A tagged commit builds on
  ubuntu/windows/macos-arm64 runners. Tauri and Electron do the same; the SBCL constraint
  costs nothing here.
- **A signed manifest is the contract** — one schema-versioned JSON per channel at a
  permanent URL, listing per-platform payload (updater) and installer (human) with size,
  SHA-256 and signature.
- **Ed25519 over both artifact and manifest** (Ironclad), verified against a public key
  shipped inside the bundle. Artifact signing defends against a compromised host; *manifest*
  signing defends against a substituted manifest pinning users to a vulnerable version. The
  client refuses versions ≤ installed.
- **Update sources are a neutral protocol with two backends from day one** — GitHub Releases
  (zero infrastructure) and S3 (private products, permanent human link).
- **Per-user install locations** so the app can rewrite itself with no elevation; a
  per-machine install is reported as a *state* (`NotWritable`), not a failure.
- **One artifact per platform**, its `format` named in the manifest: Windows ships an NSIS
  installer that *is also* the update payload; Linux an AppImage likewise; only macOS splits
  (`.dmg` for humans, `.app.tar.gz` for the updater). **The user never extracts an archive,
  and no archive library is needed.**
- **Stage, verify, then apply; keep the old version.** Never write into the live bundle;
  never verify after applying.
- **The update UI is HTMX served by the app itself**, progress streamed over
  `hyperion/channel` — no JS bridge, because the app is already an HTTP server.

Rejected: **Sparkle/WinSparkle via FFI** (two more C deps, appcast XML, no Linux story, and
the in-process bridge ADR-0008 deliberately avoided — most of what they add is UI HTMX gives
free); **package managers only** (release latency isn't ours, coverage is partial, the app
can't tell the user anything — kept as a *complement*); **bsdiff deltas** (real bandwidth
saving on a ~40 MB image, but complicates verification and rollback — deferred behind a
measurement); **a privileged updater service** (Omaha model — a large attack surface for a
case per-user installs avoid entirely).

Two consequences worth carrying forward: **a lost signing key strands every installed app**,
so key rotation must be a tested release path, not a fire drill; and **macOS reproducibility
is weaker** than the other two, because upstream SBCL publishes no macOS binaries, so macOS
builds use Homebrew's SBCL and cannot honour the version pin.

### API-first and multi-UX

A product is **not one UX**. [ADR-0009](https://github.com/codelisperer/ouranos/blob/main/hyperion/docs/adr/0009-api-first-multi-ux.md) adopts the GitHub / GitHub-Desktop / `gh`
pattern: web, desktop, CLI, native mobile and a pure programmatic API, each a thin adapter
over one core, with a specialized client free to consume only *part* of the API rather than
replicate the whole app.

The tension is real: classic HTMX returns HTML fragments, not JSON. "API-first = everything
JSON, render client-side" would throw away HTMX's entire advantage; ignoring API-first
strands every non-web surface. The hypermedia community's answer is that these are **two
different APIs**:

- **Application/hypermedia API** — HTML fragments, UI-shaped, **un-versioned**, free to
  change with the UI. Consumed by web and desktop-webview.
- **Data API** — JSON, stable, **versioned**; the contract mobile, CLI and third parties
  bind to.

Both are thin effectful CL shells over the same domain core, so the split is a *feature*
(contract stability vs UI agility), not duplication. **The data contract is Coalton-typed**:
DTOs as `define-type`s, JSON codecs generated from them, OpenAPI *emitted* as an output —
extending the typed-core thesis to the edge. Spec-first (OpenAPI → CL) was considered and
rejected as inverting that direction. The hypermedia API is deliberately *not* typed this
way; it emits HTML and is coupled to the UI on purpose.

Open: the typed-contract tooling shape (a `hyperion/api` capability, likely leaning on
aion), unified auth (session cookie for web, bearer for the data API), per-product data-API
opt-in, and the versioning scheme. The forcing function is the first real SaaS product.

### Mobile via HTMX — a native shell over the same hypermedia

The fifth surface, kept as its own thread because the research is done and the paths ranked.

**Near-term, the realistic path: the Hotwire-Native pattern.** A thin native iOS/Android
shell shows Hyperion's existing HTMX HTML in a webview with **native navigation**, and
chosen elements upgrade to native controls. *Nothing in Hyperion changes* — it already emits
the HTML. The bridge is `turbo-native-htmx-driver` + `turbo-shim`, which translates htmx
events into what Turbo Native adapters expect. Upstream status is experimental with a
working iOS demo, so **budget to maintain the bridge ourselves** — that is the real cost of
this path and should be a deliberate yes.

**If native fidelity outranks HTML reuse: Hyperview/HXML** — a React Native client that
renders **native views** from an XML hypermedia format. That would make mobile a second
**`render` target** rather than a second app: the same Coalton-typed component vocabulary, a
different serializer. This is the strongest argument for designing the CLOS `render` seam
(HTML · HXML · TUI) **now**, before components proliferate — cheap today, expensive later.

**Do not promise** "React Native consumes our htmx HTML directly." It does not exist;
`react-native-render-html` is static HTML with no htmx event model. That would be net-new
framework work.

### Universal views — one s-expr, two backends (deferred on purpose)

An idea kept, and deliberately *not* started: keep **one** Spinneret-shaped view syntax and
give it **two compiler backends** — Spinneret on the server, and a Parenscript macro that
walks the *same* s-expr emitting `React.createElement`, exactly the way **Reagent compiles
Hiccup**. React vendored as a static file (like `htmx.min.js` today), no JSX so no Babel, no
npm ever. The bundler's other jobs already have CL-native answers: minification via
`hyperion/output :compact`, serving via `hyperion/static`, "HMR" via the live image, CSS via
the CSS DSL. **The whole Webpack/Vite layer is displaced, not reimplemented.**

The explicit constraint is *keep it as simple as Reagent*: lean on React for the virtual DOM
and reconciliation; a bespoke signals runtime (the Solid/topcoat shape) is **out of scope**
until something proves Reagent-style insufficient. Scope is smallest-first — a
`createElement`-emitting macro over the core subset, then **islands only** (never turn the
app into an SPA), with isomorphic SSR+hydrate as an aspiration, not a starting point.

Why deferred: HTMX + Alpine covers the overwhelming majority of interactivity. This is the
answer for the *rare* genuinely component-shaped page, not the default.

### Studio, and the visual Coalton REPL

The Studio is a build/inspect/preview surface — live-edit components, see them render, drive
the hot-reload loop from a UI — and the natural home for **AI-assisted artifact generation**
(a praxeon agent wielding `cons` + Hyperion as Means).

Its first real inhabitant is a **visual Coalton REPL**: the missing interactive, *typed*
front end for Coalton — enter definitions incrementally, get typed and richly rendered
results, inferred types for any sub-expression (GHCi's `:t`), structural ADT rendering,
DrRacket-style definitions/interactions panes, a stepper as a stretch goal. It lands here
rather than in `cons` because it needs the web stack, and `cons` is *left* of hyperion in
the DAG. The split: **`cons` owns a lean, headless Coalton-eval + type-introspection
engine**; **Hyperion owns the visual front end** that consumes it.

The niche is real and was checked: Coalton's official **`mine`** IDE has a *text-mode* REPL
in a Tauri+xterm shell, and the community **`coalton.app`** is a compile-and-run playground,
not a live typed REPL. The open space is precisely the **visual, structured-value-rendering**
REPL neither provides — and doing it web-served keeps it *CL all the way down.*

### Project generation is `cons`'s job

Creating a new Hyperion app is `cons init NAME --template web`, not a Hyperion feature.
Hyperion supplies the *template*; `cons` supplies the *machinery*. This is why the in-tree
`hyperion/cli` is an interim artifact awaiting retirement rather than a design.

### Native reach — "CL all the way down" (far horizon)

The ambition is a stack that competes with the JS ecosystem without leaving Lisp. Beyond
Parenscript: **Coalton→TypeScript** (typed "functional JavaScript" for when HTMX genuinely
isn't enough), **Coalton→Dart** for mobile, and **libev on Windows** integrated into Woo so
the async server story is truly cross-platform rather than falling back to Hunchentoot. All
of it is gated on `aion` maturing, and sequenced well after the core framework.

### Constraints (don't violate without cause)

- Typed core in Coalton; effects and IO in the CL/CLOS shell. **No IO in Coalton.**
- Pluggable backends behind neutral protocols.
- **No Node.js in the toolchain** — Parenscript for JS, a CL DSL for CSS.
- **Generic components only; never domain-specific ones.**

---

## Usage

Build the whole monorepo tree once; discovery is then automatic.

```sh
git clone https://github.com/codelisperer/ouranos.git
cd ouranos
sbcl --dynamic-space-size 4096 --script bootstrap.lisp   # → bin/cons + ASDF (:tree) drop-in
```

```lisp
(ql:quickload :hyperion)    ; first load compiles Coalton (~minutes; cached after)
(hyperion:version)          ; => "0.0.0"
```

**The hot-reload loop** — hand `watch` a builder thunk that closes over persistent state:

```lisp
(hyperion/dev:watch
  (lambda () (my-app:start-web :dev t))   ; builder -> a fresh Clack handler
  :system "my-app")                       ; or :systems '("my-app" "hyperion")
;; edit a source file, save: recompiled, server rebuilt around the same state,
;; :dev tabs refresh themselves. A compile error becomes a red overlay.
(hyperion/dev:unwatch)
```

**Sessions** — cookie in, session out; emit the `Set-Cookie` only when one was minted:

```lisp
(defvar *store* (session:make-memory-store))

(multiple-value-bind (sess set-cookie) (session:ensure-session env *store*)
  (session:session-set sess :conversation "conv-42")
  (list 200 (append '(:content-type "text/html; charset=utf-8")
                    (when set-cookie (list :set-cookie set-cookie)))
        (list "…")))
```

**Interceptors** — the same chain runs pure or with one impure pivot in the middle:

```lisp
(interceptor:execute-effect chain
                            (fn (turn) (with-reply turn (run-turn (turn-input turn))))
                            (make-turn input ""))
```

**i18n** — one dictionary, per-request locale, `{named}` interpolation:

```lisp
(i18n:translate *dict* :ru :home/join-the)
(i18n:translate *dict* :en :cart/total :count 3)
```

**Desktop** — the same app in a native window:

```lisp
(hyperion/desktop:run-app app :title "My App" :width 1200 :height 800)
;; :backend :embedded (default) | (:remote url) | (:hybrid url)
;; :shell   :webview (native)   | :browser (dev convenience)
```

Full walkthroughs — the dev loop's reload/restart rules, i18n, sessions, interceptors,
HTML→Spinneret porting, and the attribute-prefix gotcha — are in the in-repo
[user guide](https://github.com/codelisperer/ouranos/blob/main/hyperion/docs/user-guide.md).

---

## Roadmap

Actionable work lives in GitHub issues and the project board, not in this page.

- **Board:** https://github.com/orgs/codelisperer/projects/1
- **Open Hyperion issues:** https://github.com/codelisperer/ouranos/issues?q=is%3Aissue+is%3Aopen+label%3A%22pkg%3Ahyperion%22
- **Decisions:** [`hyperion/docs/adr/`](https://github.com/codelisperer/ouranos/blob/main/hyperion/docs/adr/README.md) — ADR-0002 (Coalton core / CL shell),
  0003 (all-Spinneret), 0004 (Parenscript), 0005 (output style), 0006 (i18n), 0007 (the
  six-framework monorepo), 0008 (desktop shell), 0009 (API-first multi-UX), 0010 (desktop
  distribution & self-update).
- **Design notes in-repo:** `desktop.md`, `desktop-distribution-design.md`,
  `interceptors-design.md`, `i18n-design.md`, `dynamic-resources.md`,
  `middleware-security.md`, `compliance-design.md`, `research/multi-target-ux.md`.
