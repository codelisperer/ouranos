# Research: Hyperion as a four-surface UX layer

*Researched 2026-07-16. Sources cited inline; speculative items flagged.*

## Recommendation

> **Commit to one unifying mechanism — a CLOS `render` generic specialized per
> target over a Coalton-typed, backend-neutral component/HTMX vocabulary — and
> prove it end-to-end on a single component before promising any surface.** Build
> order by risk: **hypermedia web (now) → desktop webview (near-free) → terminal
> REPL (cl-readline + clingon)**. Treat **TUI-as-components**, **Coalton→TS SPAs**,
> and **native-mobile rendering** as *staged/speculative* — design the `render`
> seam so they're reachable, but don't put them on the near-term roadmap.

The `render` seam is what makes the "one UX layer, four surfaces" thesis credible
and it **costs nothing** to design now: HTML for web/desktop, HXML for RN mobile,
croatoan cells for terminal — all specializations of the same generic over the
same typed vocabulary.

---

## Surface 1 — CLI / terminal ("rebel-readline"-like)

**Prior art:** Clojure's [rebel-readline](https://github.com/bhauman/rebel-readline)
gets ~80% of its polish *for free* from **JLine 3** (multiline editing, live
syntax highlight, inline docs/completion, configurable keybindings, a pluggable
`Service` for completion/docs/eval).

**CL has no JLine equivalent.** You assemble it:

| Concern | Library | Notes |
|---|---|---|
| Readline (FFI) | **cl-readline** | GNU Readline bindings; best key-binding/completion control. GPL C dep. |
| Pure-CL line editor | **linedit** | No C dep, portable; older, lightly maintained. Fallback. |
| Arg parsing | **clingon** (rec.), unix-opts, adopt | Clingon = current community pick (sub-commands, hooks, shell completion). |
| Full TUI | **croatoan** (ncurses) | Actively maintained, CLOS-y; the serious choice. cl-tui is experimental. |

**Verdict:** a respectable line-editor REPL (cl-readline + clingon) is feasible
today. **rebel-readline parity** (highlighting, structural editing) is
**significant custom work** — you're rebuilding what JLine gave Clojure free.
**"Render Hyperion components to a TUI" has no prior art** — genuinely novel; the
opportunity *and* the risk.

**Approach:** split like rebel-readline — thin terminal layer + pluggable
`Service`. Target **SBCL first**. For any "app-as-TUI", treat **croatoan** as a
render backend behind the *same* CLOS `render` generic the web surface uses.
Prototype one component (list/detail) end-to-end before committing. Don't promise
structural/paren-aware highlighting early — it's the long pole.

---

## Surface 2 — Hypermedia web + eventual SPA via Coalton→TS

**Reality check:** **Coalton compiles to CL only.** The research found **no JS/TS
backend and no active/accepted roadmap item** for one. Coalton's design leans on
CL interop via the `lisp` operator, so a JS backend re-opens that problem for a JS
host. CL→JS *does* exist but **not from Coalton's typed IR**: Parenscript
(untyped), JSCL, Valtan (alpha) — all erase the type guarantees that motivate the
idea.

**What such a compiler actually entails** (reference points): Gleam added a JS
target in v0.16 (2021), and **emitting good `.d.ts` types was a *separate*
tracked project** from emitting JS. PureScript/Elm/ReScript each represent
many person-years (codegen, FFI, runtime for typeclass dictionaries, source maps,
tree-shaking, tooling).

**Verdict:** a Coalton→TS compiler is a **multi-person-year language-tooling
project, not a Hyperion feature.** Near-term: **it does not exist and will not
soon** — aspirational only.

**Approach:** **ship hypermedia-first now** (HTMX + Spinneret + Parenscript needs
no Coalton→JS). Keep the SPA path as an **architectural seam, not a build
target**: define the typed HTMX vocabulary in Coalton so it's backend-agnostic —
reusable *if* a Coalton→JS backend ever lands, nothing lost if not. If a typed
client surface is genuinely needed sooner, the pragmatic options are Parenscript
(in-stack) or an *external* typed-FP-to-JS language — **not** betting on a Coalton
backend.

---

## Surface 3 — Desktop

See [desktop-ceramic-vs-tauri.md](desktop-ceramic-vs-tauri.md) for the decision.
For the *shared UX layer* the point is: both routes are **webview shells**, so
Hyperion's desktop reach is **the same server-rendered HTMX HTML + Parenscript JS
in an embedded webview** pointed at a local Hyperion server. **This is the
strongest of the four reuse claims** — desktop is nearly free if web exists. Bias
toward keeping the **CL image in-process** (CLOG Frame / Ceramic-style) over a
separate web build (Tauri-style), so hot-reload and preserved state carry to
desktop.

---

## Surface 4 — Mobile via hypermedia

**Your remembered reference — found:** **Dom Christie's
[`turbo-native-htmx-driver`](https://github.com/domchristie/turbo-native-htmx-driver)
+ [`turbo-shim`](https://github.com/domchristie/turbo-shim)**
([essay, 2024-07-19](https://domchristie.co.uk/posts/turbo-native-without-turbo/)).
It translates **htmx** events into the calls Turbo Native adapters expect, so an
htmx web app drives a native iOS/Android shell **without Turbo**. Status:
**experimental, working iOS demo, not RN-specific** — it's a **webview + native
nav** bridge, *not* htmx rendering to native RN views.

**The mature reference architectures:**

- **[Hyperview](https://github.com/Instawork/hyperview)** (Instawork) — the
  canonical **hypermedia → React Native** system, **real and maintained
  (v0.108.1, 2026-06-27)**. Defines **HXML** — an XML hypermedia format for
  *native* UI — and a React Native client that fetches HXML from any backend and
  renders **native views** (no webview). Key difference: **different media type
  (HXML, not HTML)** — you'd emit HXML, not reuse HTML templates. **This is the
  only path that is genuinely "React Native consuming hypermedia."**
- **[Hotwire Native](https://native.hotwired.dev/)** (37signals; Turbo + Strada) —
  the reference pattern for "native shell rendering server-driven hypermedia":
  server renders HTML, a thin native wrapper shows it in a WebView with native
  nav, **Strada** upgrades chosen elements to native controls. Turbo/Rails-centric
  and webview-based, but the architecture everyone (incl. Dom Christie) imitates.

**Three paths, ranked:**

1. **Webview + native-nav shell (Hotwire-Native pattern), htmx inside.** Most
   realistic. Hyperion already emits HTMX HTML; wrap in `turbo-ios`/`turbo-android`
   + Christie's htmx→Turbo-Native driver. **Feasible in 2026, low-med effort, but
   depends on an experimental adapter you'd likely maintain. Not RN.**
2. **Hyperview (true native RN rendering).** Mature, but requires Hyperion to
   **emit HXML** — a second serializer distinct from HTML/htmx. **Buys native
   fidelity at the cost of dual output formats.**
3. **Custom RN client speaking htmx/HTML directly.** **Does not meaningfully
   exist** (only `react-native-render-html` for static HTML, no htmx event model).
   Net-new framework work — **don't assume it exists.**

**Approach:** near-term, reach mobile the **Hotwire-Native way** (existing HTMX
HTML in a native webview shell; track/adopt Christie's bridge, budget to maintain
it). If native fidelity matters more than HTML reuse, treat **Hyperview/HXML as a
distinct `render` target** — the cleanest "one UX layer → RN" story, reusing the
component model at the cost of a second serializer. **Do not** promise "RN
consumes our htmx HTML directly."

---

## Cross-cutting: the thesis keystone

- **Strongest reuse:** desktop (web renderer in a window) and — via a second
  serializer — Hyperview/HXML mobile.
- **The unifying mechanism:** Hyperion's CLOS `render` generic specialized per
  target (HTML web/desktop · HXML RN mobile · croatoan terminal) over a
  **Coalton-typed, backend-neutral component/HTMX vocabulary.** Design this seam
  now.
- **Most speculative (flag to stakeholders):** (a) Coalton→TS SPA generation
  (doesn't exist, multi-year); (b) hypermedia components → TUI (no prior art);
  (c) RN consuming htmx-HTML directly (doesn't exist — real options are
  Hotwire-Native webview or Hyperview HXML).
- **Least-risky wins first:** hypermedia web → desktop webview → terminal REPL,
  deferring TUI-component and native-mobile ambitions until the `render` seam is
  proven on one component.

## Roadmap implications

- Add a roadmap thread **"Multi-surface `render` seam"**: make the `render`
  generic + Coalton vocabulary explicitly target-parameterized from day one, even
  while only HTML is implemented.
- Near-term deliverables: web (already core), then a **desktop-window** capability
  (see desktop report) and a **terminal REPL** (cl-readline + clingon).
- Backlog / research spikes (not commitments): a croatoan `render` target
  (one-component prototype), a Hyperview/HXML `render` target, and a watching
  brief on any Coalton→JS effort.

## Flagged / unverified

- Absence of any Coalton→JS effort not exhaustively confirmed (didn't enumerate
  all coalton-lang discussions).
- Current commit freshness of Christie's two repos not re-checked.
- Whether the user's "RN + htmx" memory is Hyperview vs the Turbo-Native
  experiment — both documented above, so covered either way.
