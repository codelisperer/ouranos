# Research: HTMX v4 — status and impact on Hyperion's typed vocabulary

*Researched 2026-07-16. Primary sources: htmx.org, four.htmx.org,
github.com/bigskysoftware/htmx, Carson Gross's "The fetch()ening." Items reached
only via page-summarization (not exact-string reads) are marked **[verify]** —
confirm against `four.htmx.org` before encoding.*

## Recommendation

> **Target v4 — the "first framework to fully support HTMX 4" window is genuinely
> open (v4 is still beta; no server framework has final-release support). But
> scope the claim to the *emitted attribute + header vocabulary*, pin to a
> specific beta (currently beta5), and VERIFY the request-header changes directly
> before encoding them into the Coalton model.** Build the typed vocabulary
> against v4 semantics from the start, and ship a `htmx-2-compat`-aware mode so
> Hyperion can emit either 2.x or v4 attribute forms.

This is a real differentiator: most integrations (django-htmx etc.) are thin
header helpers with little incentive to rush a beta. A *typed CL vocabulary* that
actually models v4's new swap/inheritance/partial/header surface would be
genuinely first-in-class — **if** the request-header specifics are confirmed
(they're the one under-corroborated area, and a typed model that gets header
strings wrong is worse than none).

---

## (a) Status & timeline

- **v4 is BETA, not released.** Current pre-release **`v4.0.0-beta5` (2026-06-26)**;
  betas 3/4 in May, an alpha earlier in 2026. **Stable remains 2.x.**
- **Roadmap** (Carson Gross, [The fetch()ening](https://htmx.org/essays/the-fetchening/)):
  4.0 final "early-to-mid 2026", promoted to `latest` only "early 2027", **2.0
  supported "in perpetuity."** Rollout is deliberately multi-year.
- Docs/progress: **[four.htmx.org](https://four.htmx.org)**, tracked on the `four`
  branch.
- **Lineage: htmx 3 was skipped.** Gross had promised "no 3.0", then decided there
  *would* be another major — so it goes straight to 4.0. His word: *"Oops."*
- **Driver:** replacing `XMLHttpRequest` (an IE-era holdover) with the **Fetch
  API** — hence "The fetch()ening" — which cascades into a new event model and
  native streaming.
- **Note:** InfoWorld's "production-ready" framing (2026-04-14) conflicts with the
  actual beta track — **treat "released" claims in secondary press as incorrect.**

## (b) Verified changelist: 2.x → v4

**Core architecture**
- `fetch()` replaces `XMLHttpRequest` (not revertible); native **streaming** via
  `ReadableStream`; **idiomorph morphing moved into core**; **SSE returns to
  core** (WS/SSE extensions rewritten).

**Defaults changed (breaking)**
- **Attribute inheritance is now explicit** (opt-in `:inherited` modifier; restore
  old behavior via `htmx.config.implicitInheritance = true`).
- **4xx/5xx responses now swap by default** (only 204/304 skip); restore via
  `htmx.config.noSwap`.
- History no longer snapshots the DOM to storage — back-nav issues a fresh
  request.
- `defaultTimeout` now `60000ms`; `defaultSettleDelay` now `1`. **[verify]**

**Attributes — renames/removals/additions [verify exact]**
- **Renames:** `hx-disable`→`hx-ignore`; old `hx-disabled-elt`→`hx-disable`;
  `hx-vars`→`hx-vals`.
- **Removed:** `hx-ext` (extensions loaded by script include + config allowlist),
  `hx-params`, `hx-prompt`, `hx-disinherit`, `hx-inherit`, `hx-request`,
  `hx-history`.
- **New:** `hx-action` + `hx-method` (URL/method split), `hx-config` (per-element
  request config), `hx-ignore`, `hx-validate`, **`hx-status:<code>`** (per-status
  swap control, e.g. `hx-status:422="swap:innerHTML target:#errors"`; supports
  `404`, `50x`, `5xx`).

**Swap**
- **New styles:** `innerMorph`/`outerMorph` (essay also says `morphInner`/
  `morphOuter` — **[verify which]**), `textContent`, `delete`.
- **New aliases:** `before`/`after`/`prepend`/`append`.
- **Modifier syntax changed** to space-delimited key:value: `show:top
  showTarget:#other`, `scroll:bottom scrollTarget:#other` — **old
  `show:#other:top` breaks.**

**OOB / multi-target**
- **New `<hx-partial>` tag** for explicit multi-target updates; a response of only
  partials skips the main swap. `hx-swap-oob` remains (simplified).
- **OOB order flipped:** main content swaps first, then partials in document order
  (was OOB-first).

**Events (breaking)**
- New convention **`htmx:<phase>:<system>[:<sub>]`** (`htmx:before:request`,
  `htmx:after:swap`, …); **error events consolidated to a single `htmx:error`**;
  new `htmx:before:response`, `htmx:finally:request`, etc.; `hx-on:` supports
  `await`.

**Headers (HX-*)  [verify — most important for Hyperion]**
- **Response headers largely stable:** `HX-Location`, `HX-Push-Url`, `HX-Redirect`,
  `HX-Refresh`, `HX-Replace-Url`, `HX-Retarget`, `HX-Reswap`, `HX-Reselect`,
  `HX-Trigger` all remain.
- **Removed response headers:** `HX-Trigger-After-Swap`, `HX-Trigger-After-Settle`.
- **⚠️ Request headers changed (least-corroborated):** docs summary reports
  `HX-Trigger`/`HX-Trigger-Name` consolidating into **`HX-Source`** (format
  `tagName#id`), `HX-Target` reformatted to `tagName#id`, and a new
  **`HX-Request-Type: full|partial`**. **These need direct confirmation before
  Hyperion parses them.**

**Extensions / JS API**
- Callback API → event-hook API (`htmx.defineExtension`→`htmx.registerExtension`);
  loaded by script include + allowlist. Core-bundled extensions include
  `htmx-2-compat`, `sse`, `ws`, `preload`, `optimistic`, `head-support`,
  `alpine-compat`, `browser-indicator`, `upsert`. DOM sugar removed in favor of
  native (`htmx.addClass`→`classList.add`, etc.).
- Migration checker: `npx htmx.org@4.0.0-beta5 upgrade-check -- ./project`.

## (c) Checklist — what Hyperion's typed Coalton model must add/change

Hyperion models Swap, Trigger, Target, Verb, Duration, OOB, SSE, and `HX-*`
response headers.

**Swap type**
- [ ] Add `innerMorph`/`outerMorph`, `textContent`, `delete`.
- [ ] Add aliases `before`/`after`/`prepend`/`append` (keep positional names as
      synonyms).
- [ ] **Re-model swap modifiers as space-delimited key:value pairs** — split old
      `show:#target:pos` into `show:pos` + `showTarget:#sel` (and `scroll`/
      `scrollTarget`). Structural change, not just new enum cases.

**Target / Verb / new attributes**
- [ ] Model `hx-action` + `hx-method` split as an alternative to verb attributes.
- [ ] Add `hx-status:<code>` as a typed status→swap-config map (exact / `50x` /
      `5xx`).
- [ ] Add `hx-config`, `hx-ignore`, `hx-validate`; apply renames; drop removed
      attrs from the core vocabulary.

**Inheritance (new type-system axis)**
- [ ] Add `:inherited` (and `:inherited:append`) as a first-class per-attribute
      wrapper — inheritance becomes a typed per-attribute decision, not implicit
      runtime behavior. **Arguably the biggest modeling change.**

**OOB / partials**
- [ ] Add a typed `<hx-partial>` element (target + swap) as the preferred
      multi-target primitive; keep `hx-swap-oob` secondary; encode main-first
      ordering.

**HX-* response headers**
- [ ] Keep the stable set; **remove** `HX-Trigger-After-Swap` /
      `HX-Trigger-After-Settle` from the ADT.
- [ ] **[verify]** Confirm request-side changes (`HX-Source`, `HX-Request-Type`,
      reformatted `HX-Target`) **before** building request parsing.

**SSE / events / config**
- [ ] SSE is core again — model `text/event-stream` + `ReadableStream` streaming
      swaps.
- [ ] If client event names are typed, migrate to `htmx:<phase>:<system>`, collapse
      errors to `htmx:error`.
- [ ] Update any emitted `htmx.config` keys + new default timeout.

## (d) Competitive-timing assessment

- **Window is open:** v4 is beta5, so *nobody* has final-release "launch" support.
- **Server frameworks mostly don't "support" an htmx version** — the integration
  surface is thin (parse `HX-*` request headers, set `HX-*` response headers).
  django-htmx/flask-htmx do just that; Hyperion goes *beyond* with a typed
  vocabulary, so "fully support" here means emitting the new/renamed attributes,
  swap/modifier syntax, `:inherited`, `<hx-partial>`, and updated headers.
- **Competitors today:** only blog/experiment level (django-htmx still 2.x;
  "HTMX 4 in Django" is Medium posts, not shipped). No Rails/Laravel/Go/Fastify v4
  support merged. **The "first" claim is credible.**
- **What it concretely requires:** (1) a typed model covering (b)/(c), pinned to a
  beta; (2) **direct verification of the request-header changes**; (3) shipping
  alongside/just after 4.0.0 final, honest that "support" precedes htmx's own
  `latest` promotion (~2027); (4) ideally a `htmx-2-compat`-aware emit mode.

## Roadmap implications

- The existing roadmap thread **"Typed HTMX components (Coalton)"** should be
  **specified against v4, not 2.x**, from the start — the (c) checklist is its
  acceptance criteria. This is the cheapest moment to do it (no code yet).
- Add a small **"verify v4 request headers against four.htmx.org"** task as a
  blocker on the request-parsing side.
- Consider **timing the 1.0 release to HTMX 4.0 final** (summer 2026 target) for
  the "first to fully support" positioning — with honest framing about beta/`next`
  status.

## Flagged / unverified

- **Request-header renames** (`HX-Source`, `HX-Request-Type`, `HX-Target`
  reformat), exact new config defaults, and `innerMorph`/`outerMorph` vs
  `morphInner`/`morphOuter` — **confirm directly against four.htmx.org** before
  encoding.
- InfoWorld's "production-ready" framing ≠ the actual beta track — htmx 4 is **not
  finally released** as of 2026-07-16.
