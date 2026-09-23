# klio — questions before the first slice

*Ouranos Claude (macOS), 2026-09-16; **all three answered 2026-09-18**. Tracked as pre-publication issue 359, which is the short form — answerable with a letter per question.*

* Read `docs/launch/sites-and-cms.md` as the contract
first; this asks only what that doc leaves open or what a first implementation would have to
guess. **Answer inline** — a sentence each is plenty, and "your default is fine" is an answer.*

Two premises checked against the doc rather than taken from a summary, because both shape
everything below and both turned out to be exactly as described:

- **§1** — content is markdown + front-matter in git, loaded into the live image, **not a
  database**. Load-bearing: it is what takes the sites off mnemosyne's critical path.
- **§1b** — the product boundary **is** the database. No DB needed → klio is enough. A DB
  needed → a full hyperion service. So anything implying persistence beyond the content tree
  is out of scope *by definition*, not by preference.

---

## Part 1 — three I cannot sensibly guess

### Q1. Front-matter: what is typed, and what happens to a key klio does not know?

**Why it matters:** §3 puts **taxonomy per-site**, so sites will certainly carry front-matter
keys the engine does not define. Whatever I choose here is the thing every site writes against
and the hardest to change later.

| | |
|---|---|
| **A. Closed schema** | klio defines every legal key; an unknown key is an error. |
| **B. Typed core + named carrier** *(my default)* | `title`, `date`, `slug`, `tags`, `draft`, `publish-at` are typed; everything else lands in an explicitly-named `extra` the site reads. |
| **C. Open map** | It is all just data; klio types nothing. |

**I would take B**, and the reason is a lesson from this week rather than taste: a neutral name
that silently absorbs what it does not understand is discovered by the *second* consumer. An
honest carrier named `extra` shows a reader exactly where the engine's knowledge stops. A
refuses what §3 says sites are supposed to do; C gives up the typing that makes a bad post a
build error instead of a blank page.

**Sub-question that is really the same question:** should an unknown key be *reported* at load
(a line per file, once) or silent? I default to reported — a typo'd `tgs:` is otherwise a tag
that never appears, with nothing anywhere saying so.

> **Answer: B**, ruled 2026-09-18. Typed core — `title`, `date`, `slug`, `tags`, `draft`,
> `publish-at` — plus a named `extra` for everything else. Unknown keys reported once per file
> at load, naming the file and the key, in the same place Q2's load errors go.
>
> Implemented. `extra` carries **nested** values, which the CV forced: a role's bullets are a
> list of objects each with an optional list of metric objects, so a flat string-to-string
> `extra` fails on the first real document (pre-publication PR 360).

### Q2. A malformed file — does the site refuse to start, or skip the page?

**Why it matters:** these are opposite failures and both are defensible, and the right answer
is probably *different at boot than at reload*. A running site that dies because one post has a
bad date is worse than the typo. A fresh deploy that silently ships without your newest page is
also worse than the typo.

**My default, which is two answers:**

- **At boot: refuse, loudly, naming the file.** A deploy that cannot load its content has not
  succeeded, and this is the moment someone is watching.
- **At hot reload: keep the last good version of that one file, report, carry on.** The site
  stays up; the editor sees the error immediately because they just saved it.

**And the part that has to be decided with it:** a reload swaps the content tree **atomically**
— a request sees the old tree or the new one, never a half-built one. Anything else produces
the failure mode `hyperion/dev` hit in pre-publication issue 234, where an image holds two versions of a thing at
once and the symptom looks impossible.

**This one is ADR-shaped** — two failure policies plus an atomicity guarantee, and every later
feature inherits it. Say the word and I will write it up as `klio/docs/adr/0001-...` with the
alternatives, rather than burying it in a commit message.

> **Answer: neither A nor B — one rule, two outcomes**, ruled 2026-09-18. Validate the whole
> candidate tree; if any file fails, do not swap, and report the file and the reason. At boot
> there is no previous tree, so that means refusing to start. At reload the site keeps serving
> the last good tree. Dev mode skips, reports and carries on.
>
> Recorded as ADR-0001. Carries a requirement for whatever ships the deploy: **a reload that
> reports errors has to be a failed deploy**, or the silent partial returns somewhere else.
>
> Implemented in `klio/src/content.lisp`. `load-tree` validates and returns no tree at all when
> a file fails; `boot` signals (phase `:boot`); `reload` returns `:published` / `:refused` and
> leaves the published tree untouched on a refusal; `reload-or-fail` signals, which is the
> entry point a deploy calls, because a returned value can be dropped by forgetting to check
> it and an unhandled condition exits non-zero on its own. A **duplicate slug** is a
> tree-level failure — neither file is wrong alone, which is the clearest case for validating
> the tree rather than each file.

### Q3. Syntax highlighting — how, given the dependency budget?

**Why it matters:** §3 lists it as **shared** (docs and blog both need it), and **nothing in
the tree does it today**. Every option costs something different and the dependency surface is
yours to rule on — `docs/dependencies.md` exists because deps are held to a conscious minimum.

| | Cost |
|---|---|
| **A. A CL highlighter as a new external dep** | One more dep in the surface; highlighting happens server-side at render, no client JS. |
| **B. Client-side (highlight.js / Prism), vendored** *(my default)* | No CL dep; `hyperion/assets` already vendors htmx/Alpine/Bulma the same way, so the pattern exists. Costs a JS file and renders after paint. |
| **C. Highlight at content-load time** | Done once per file at boot rather than per request; still needs a highlighter from A or B. |

**I lean B**, on the precedent that `hyperion/assets` already vendors third-party front-end
assets into the image, so this adds no *new kind* of thing — and because a CL highlighter is a
dependency whose language coverage we would then own.

But this is genuinely your call: B puts a visible dependency in the page where A puts it in the
build, and the site is a *showcase for a Lisp stack* — "we highlight Lisp with JavaScript" is a
fair thing to not want.

> **Answer: a small CL highlighter, Lisp only, at content-load time**, ruled 2026-09-18.
> Other languages render as plain `<pre>`. Not B: a site arguing "CL all the way down" that
> ships JavaScript to colour its Lisp makes the opposite argument on every page. Not A: a
> general highlighter buys coverage for languages the site does not use.
>
> The cost, so it is not a surprise: shell and YAML blocks render uncoloured until someone
> extends it. Reversible — B costs nothing to adopt later, since `hyperion/assets` already
> vendors front-end assets that way.
>
> Implemented in `klio/src/highlight.lisp`, applied at load (the rendered HTML is stored on the
> document, so a request does no highlighting work). Classes, not colours — the stylesheet is
> the site's. The classes are **structural**: comments, strings, characters, numbers and
> keywords are lexical facts, and `operator` is the head of a **top-level** form, which is a
> fact about position rather than a list of names. Narrowed to top level deliberately: `(x)` in
> `(defun f (x) …)` is not a call, and telling a parameter list from a call needs a vocabulary
> of binding forms — a list that is wrong the first time a site writes a macro.
>
> **Correction to the premise above, measured rather than assumed.** "Nothing in the tree does
> it today" was false: 3bmd's default renderer is `colorize`, so a ```lisp fence was *already*
> being coloured server-side, and the colorize path prints a `could not find hyperspec map
> file` line to standard output while doing it. `hyperion/markdown`'s own comment — "Emit plain
> `<pre><code>` (no server-side colorize)" — is true only for an **unlabelled** fence. That is
> why klio renders through 3bmd's `:nohighlight` renderer and re-marks the Lisp blocks itself:
> `:nohighlight` is the one path that emits a plain block **while recording the language**,
> which is the only thing a post-pass needs. The ruling still holds — it is a CL highlighter
> under klio's control, with markup a site can style — but it was made against a premise that
> did not survive contact with the renderer, and the next person to read this should know that.

---

## Part 2 — I will do these unless you say otherwise

Stated so they are visible rather than assumed. Each is cheap to reverse; none blocks the first
slice.

1. **Scheduling is evaluated at request time.** `publish-at: <future>` means a post is visible
   when `now >= publish-at` — checked when a listing is built, not by a timer. No daemon, no
   database, and a scheduled post appears **exactly on time without a deploy**, which is the
   version of "schedule" that actually works under §1. Cost: listings filter by time, which is
   a comparison over an in-memory list.
2. **Routing: klio exposes handlers plus a default route table the site mounts and extends.**
   The site owns its own routes (`/cv`, `/pricing`); klio owns the content routes and can be
   mounted under a prefix. §3 puts routing shared and nav per-site, which is this split.
3. **Preview is a dev-mode flag, not a URL.** In dev, drafts and scheduled posts render; in
   production they do not exist. §6 wants a preview surface and no browser editor — a secret
   production URL would be an auth surface with no auth, which is the kind of thing that ships
   once and is found by a scanner.
4. **Markdown goes through `hyperion/markdown`**, which already wraps 3bmd and is
   **safe-by-default** (raw HTML in source is neutralised). klio should not grow a second
   markdown path; one renderer, one escaping policy.
5. **Media lives beside content in git**, served as static files. No upload endpoint — an
   upload is a write, and writes go to git through an editor, per §6.
6. **Search: tokenised, field-weighted (title > tags > body), no stemming, built at boot.**
   Enough for three sites' worth of prose; a real ranking story is a later question and a bad
   one to guess now.
7. **`hyperion/assets` is a dependency**, not a copy. If Q3 lands on B it is required anyway.

---

## Part 3 — deliberately not asking yet

§6's **"how content updates reach production"** (git push triggers a rebuild vs. a running
image pulling and hot-reloading) is a real ADR and I am *not* asking now: it does not block the
engine, and it is a better question once there is a running site to deploy. Worth noting that
it partly answers itself if Q2's reload semantics and item 1's request-time scheduling land —
a pull that fails leaves the last good tree, and a scheduled post does not need a pull at all.

**The name is settled** (klio, §2), **comments are out for v1** (§6), and **there is no
browser-based editor** (§6, and PM's instruction). I have not re-opened any of those.
