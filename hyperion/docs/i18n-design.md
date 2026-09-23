# i18n design — options & open questions

*Companion to [ADR-0006](adr/0006-i18n-approach.md) (Provisional). This doc lays
out the decision axes so we can settle the i18n implementation deliberately. The
current first cut is marked **[now]**; recommendations are marked **[lean]**;
everything else is on the table.*

The one thing already settled: **the framework owns the mechanism, the app owns the
content** — `hyperion/i18n` provides loading/lookup/negotiation; the app supplies
dictionaries and keys.

---

## 1. Storage format & authoring workflow

How translations are written and loaded.

- **[now] prior-app-style `.edn`, read via brace→paren + `read`** (no EDN dep). Pro:
  reuses a prior Clojure/Kit app's files verbatim; zero deps; data stays data. Con: not a real EDN
  parser (breaks on vectors/sets/tagged literals if ever added); relies on a clever
  transform; `\n`/`\t` handled by hand.
- **Native CL data file** (`(defparameter *translations* '(:en (...) :ru (...)))`).
  Pro: no reader tricks, `read`-native, compilable, greppable. Con: hand-porting or
  a one-off generator; EDN and CL diverge (`\n`, keyword case).
- **Real EDN parser dependency** (e.g. an `edn` system). Pro: correct, general. Con:
  a dependency — mild tension with the ecosystem's minimal-dependency house style.
- **Gettext `.po`/`.mo`.** Pro: industry standard; mature tooling (Poedit, weblate),
  translator-friendly, pluralization built in. Con: heavier; a parser; keys are
  usually source strings not symbolic keys (a different key philosophy).
- **Per-locale files** (`en.edn`, `ru.edn`) vs **one combined file**. Combined is
  easier to diff key-parity; per-locale is easier for translators and lazy loading.
- **DB-backed** (translations as rows). Pro: runtime editing, non-dev translators,
  an admin UI. Con: needs the data layer; overkill until there's a translation team.

**[lean]** Keep `.edn` as the *authoring* format (translator-neutral, matches
the prior Clojure/Kit app), but decide whether we (a) keep the runtime brace-read **[now]**, or
(b) **compile `.edn` → a CL data file at build time** (a build-time step driven by
`cons`, e.g. `cons i18n build`), getting native `read` at runtime with EDN
authoring. Open.

## 2. Key structure

- **[now] Nested sections** (`:home → :join-the`), looked up as a path
  `(translate dict :en :home :join-the)`. Pro: organized; mirrors the prior app. Con:
  callers must know the section; refactors move keys across sections.
- **Flat namespaced keys** (`:home/join-the` as a single keyword or string). Pro:
  one lookup arg; matches the prior app's Selmer `{% i18n home/join-the %}` surface. Con:
  keyword interning of slashed names, or string keys.
- **Fully flat** (`:join-the`). Rejected: collisions across sections.

**[lean]** Support a flat `:section/key` surface *over* the nested store (best of
both: organized storage, one-arg lookup that reads like the template). Decide the
canonical caller form before porting many pages, since it shapes every call site.

## 3. Lookup API & the "current locale"

- **[now] Explicit locale arg** everywhere: `(tr locale :home :join-the)`. Pure,
  testable, no hidden state. Con: threads `locale` through every render function.
- **Dynamic `*locale*`** bound per request; `(tr :home :join-the)` reads it. Pro:
  call sites shrink; matches the request-scoped nature of locale. Con: hidden
  input; must remember to bind it (a `with-locale` at the request boundary, like
  `with-output-style`).

**[lean]** Bind `*locale*` at the request boundary (symmetry with output-style) and
offer `(t* …)` reading it, while keeping an explicit-locale form for tests/purity.

## 4. Interpolation (variables in strings)

Not needed for the landing page (static copy), but auth/emails will need it.

- **[now] None.**
- **`format`-style** — values are control strings, `(tr … :n 3)` → `(format nil val 3)`.
  Powerful but couples translators to CL `format` directives (fragile).
- **Named placeholders** — `"Welcome, {name}"` + `(tr … :name "Bob")`. Translator-
  friendly, framework substitutes. **[lean]** this, with `{...}` placeholders.

## 5. Pluralization

**Decided and implemented (2026-08, pre-publication issue 135)** — a real plural string appeared, which was the
trigger this section was waiting for. `~:P` pluralizes in English regardless of locale, so
every non-English dictionary either read wrong at most counts or had to be reworded around
the construction.

- **CLDR plural categories**, all six (`zero one two few many other`). A language uses a
  subset; `other` is the one every language has, which is what makes it the safe fallback.
- **The rules are GENERATED, not transcribed.** All 224 CLDR cardinal locales are vendored
  into `src/vendor/cldr-plurals.lisp` by `scripts/fetch-cldr-plurals.lisp`, pinned by CLDR
  version + sha256 in `PLURALS.pin` — the same doctrine as `libuv.pin` / `ASSETS.pin`. Run
  the script with no arguments to assert the vendored copy still matches its pin.

  Hand-writing "the families we ship" was rejected: it is wrong for the first locale nobody
  anticipated, and wrong **silently**, because a missing rule falls back to `other` and so
  reads as a bad translation rather than a missing rule. The whole set costs ~128 KB, less
  than the vendored Bulma.
- **What is hand-written is the operand model** (`n i v w f t c`), in `src/plural.lisp` —
  the part that is actual work. Every CLDR rule is expressed over those operands, so once
  they exist each locale's rule is data.

  `v` is why a category cannot be a function of the number alone: in English "1 day" is
  `one` and "1.0 days" is `other`. A caller formatting to fixed decimal places says so with
  `:digits`.
- **Separate function, not a mode on `translate`.** `translate` is total, settled, and
  called everywhere; adding a count-sensitive branch to it would change existing calls.
  `translate-plural` is additive.
- **Key convention: a suffix**, `trial/days-left.few`, not a nested object — dictionaries
  stay flat and a translator sees the forms side by side in one file. The locale's plural
  logic stays in CLDR rather than being encoded in the shape of the translation data.
- **`{count}` is interpolated automatically**, since it is the one argument every plural
  string has.
- **Fallback nests category INSIDE locale**: `KEY.<category>` → `KEY.other` → bare `KEY`,
  all within the requested locale, and only then the same three in the default locale. A
  slightly-off form in the right language beats a correct one in the wrong language — a
  German dictionary carrying only `other` should read "1 Tage", not switch that one string
  to English. Falling through to the bare key is what lets a dictionary be pluralised one
  string at a time instead of all at once.
- **Ordinals and gender are out of scope** (`1st/2nd/3rd`, grammatical agreement). Nothing
  here precludes them: ordinals are a second CLDR table the same generator and the same
  evaluator would read.

## 6. Rich content (HTML) in translations

- **[now]** Some values contain HTML (`<s>$300</s>`, `<br/>`), rendered via
  `(:raw …)`; safe only because content is trusted (we author it).
- **Alternatives:** structure the data instead (e.g. price + strikethrough as
  separate keys/markup in the page), or a tiny safe-markup subset the framework
  renders. **[lean]** minimize HTML-in-values over time; keep `(:raw …)` only for
  the few designer strikethroughs, and never render untrusted i18n raw.

## 7. Missing-key & fallback

- **[now]** locale → default-locale → visible `"[section/key]"` marker.
- **Alternatives:** signal a condition in dev (loud), log-and-mark in prod; or a
  build-time **key-parity check** (fail CI if a locale is missing keys another has).
  **[lean]** keep the visible marker at runtime *and* add a parity check as a
  `cons`/test step.

## 8. Hot-reload & runtime editing

- **[now]** Dictionary loaded once at app start.
- **Options:** watch the `.edn` and reload the dictionary on change (fits the
  Figwheel loop — translations become live-editable in dev); later, DB-backed
  runtime editing (§1) for non-dev translators. **[lean]** dev hot-reload of the
  dictionary is cheap and on-brand; add it.

## 9. Tooling (later)

- Extraction (find `(tr …)` call sites → key list), coverage/parity report, an
  authoring/validation command. Natural home: `cons` tooling (`cons i18n
  extract | build | check`). Not now.

---

## 10. Text direction (RTL)

The dictionary is only half of localization. Translation resolution is direction-agnostic,
so an app can resolve perfect Arabic and still render a visibly broken page, because
nothing in the document says which way the text runs.

**Direction is a property of the language, not of an app's content** — the same mapping is
correct for every consuming app. So it lives in the locale-display registry beside the
endonym and flag, not in an app-local RTL list that every app would duplicate and that
would drift.

```lisp
(i18n:locale-direction :ar)        ; => :RTL
(i18n:locale-direction :en)        ; => :LTR   (the default for anything unknown)
(i18n:rtl-p :he)                   ; => T
(i18n:dir-attribute :fa)           ; => "rtl"
```

Seeded with no registration required: `ar he fa ur ps sd yi dv ckb ug`, plus the legacy ISO
codes `iw`/`ji` that some browsers still send in `Accept-Language`. A **regional tag
inherits its language's direction** (`ar-EG` is RTL), so an app never registers every
region. Override or extend per locale:

```lisp
(i18n:register-locale-display :ary :endonym "الدارجة" :direction :rtl)
```

### The page shell

`lang-attributes` returns both values together, so a shell cannot emit one without the
other — a document claiming `lang="ar"` while still `dir="ltr"` is exactly the bug:

```lisp
(multiple-value-bind (lang dir) (i18n:lang-attributes locale)
  (spin:with-html (:html :lang lang :dir dir ...)))
```

### The switcher

`language-switcher` puts `lang` **and** `dir` on the current-locale element and on every
option. This matters even in an LTR page: a switcher shows each language in its own script,
so an Arabic or Hebrew endonym is a run of RTL text inside an LTR document. Without `dir`
on the element the browser applies the page's base direction to it and mixed-script labels
— anything containing a bracket, digit, or slash — reorder visibly wrong. Only the
element's own declared direction fixes this; CSS cannot.

### What an app is still responsible for

Direction attributes make **text** flow correctly. **Layout** mirroring is the app's CSS:

- Prefer **logical properties** over physical ones — `margin-inline-start` not
  `margin-left`, `padding-inline`, `inset-inline-start`, `border-inline-end`,
  `text-align: start`. These follow `dir` automatically, so one stylesheet serves both
  directions with no `[dir="rtl"]` overrides.
- Icons that encode direction (arrows, chevrons, "next"/"back") need mirroring; icons that
  do not (a clock, a logo) must **not** be flipped.
- Numbers, code, and URLs stay LTR inside RTL text. Wrap them with `dir="ltr"` where they
  are interpolated into a translated string.
- Any shipped framework CSS should use logical properties for the same reason.

## Decisions (2026-07-16) — implemented

Settled and built into `hyperion/i18n` (supersedes the first cut in ADR-0006):

- **Storage:** **per-locale JSON files** (`resources/i18n/<code>.json`, e.g.
  `en.json`, `ru.json`), loaded via `jzon` (already a dep — no new dependency).
  **Adding a language = drop a `<code>.json` file**; supported locales are derived
  from what's present (§Q "translate to any language / easy to add"). The `.edn`
  stays as the authoring source; `en.json`/`ru.json` are generated from it.
  → **Road to data-driven:** the dictionary abstraction hides the source, so a
  later DB/CMS backend (a consuming app as a multilingual content platform) swaps in
  without changing call sites.
- **Caller surface (§2/§3):** **flat `:section/key`, explicit `locale`** —
  `(t* locale :home/join-the)`. The `locale` is *resolved by middleware*, not
  threaded by hand at each call in an ad-hoc way; the page just receives it.
- **Locale resolution (§3):** `resolve-locale` is the **middleware seam**, priority
  **?lang= > user preference > cookie/session > Accept-Language > default**. Today
  cookie + Accept-Language drive it; **`user-pref` is reserved for the coming auth /
  user-preferences subsystem** (which also brings **session management + secure/
  signed cookies** — a separate ADR + implementation, tied to Phase 4 auth, *not*
  built yet). The lang switch persists via `lang-cookie`.
- **Interpolation (§4):** **`{named}` placeholders** — `(t* locale :key :name "Bob")`
  → `interpolate`. Implemented.
- **Pluralization (§5):** CLDR categories over a generated, sha256-pinned rule set;
  `translate-plural` with `key.<category>` suffixes. Implemented (pre-publication issue 135). The gettext
  question this section reserved is closed — JSON + CLDR, no gettext.
- **Missing keys (§7):** visible `"[section/key]"` marker + default-locale fallback
  (implemented); a build-time parity check is still a **[lean]**, not yet built.

## Still open / future

- **A real EDN library:** none is in the pinned Quicklisp dist. Third-party CL EDN
  libs exist (via Ultralisp / git). Worth adding **for XTDB 2 interop** (XTDB 2
  speaks EDN *and* JSON) if/when the data layer needs EDN — not needed for i18n
  (JSON-first). Tracked as an ecosystem item, not an i18n blocker.
- **AI-assisted translation:** generate a new locale's JSON from `en.json` via an
  LLM (dev brings their own API key). **Decision: this lives at the app/CMS layer**
  — a consuming app incorporating **praxeon** agents — **not** in Hyperion's i18n core.
  Hyperion's job is only the data-driven loading that accepts generated locales.
- **DB-backed translations / admin UI:** for non-dev translators; needs the data
  layer. Future.
