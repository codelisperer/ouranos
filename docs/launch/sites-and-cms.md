# The site program — three sites, one engine

*Design doc for the self-hosted web properties. 2026-07-29; **amended 2026-09-16** by the
maintainer, who settled the engine's name and the scope of both private sites. The
amendments are marked; the original reasoning is unchanged where it survived.*

Three sites are wanted, all built on Ouranos, all dogfooding hyperion:

| Site | Purpose | Domain |
|---|---|---|
| **codelisperer.org** | The framework site — docs, blog, demo hosting | **not yet registered** ([#101](https://github.com/codelisperer/ouranos/issues/101)); `.com` is held (Hashnode) |
| Personal site | Blog, living CV, **AI resume/cover-letter fit generator** | held, resolving |
| Company site | Consulting, **product sales**, Ouranos advocacy | held |

> **Naming note — corrected 2026-09-16.** The original said the confidentiality rule covered
> the company name. **It does not.** SoftCraft is the maintainer's own sole company, not a
> client, and it and its products — **wordcrafter** and **soloflow** — may be named and
> **explicitly credited as built on Ouranos**. That credit is a goal of the launch, not an
> exposure. `docs/wiki/Working-With-AI-Agents.md` already carried the general rule; this doc
> was the stale copy.
>
> **What the rule does cover:** a **client's** app — a separate company, confidential by
> agreement and by commercial preference — is never named anywhere in this repo, and neither
> is the prior app whose CMS features are being ported. Those appear only as "a consuming
> app". A client link may go under an *"Other users of Ouranos"* list on the public site
> **once there are users that are not of our own creation**; until then, off.
>
> Sites in this doc are therefore named where they may be: `codelisperer.org`,
> **bobcalco.net** (personal), and the SoftCraft site.

---

## 1. The decision that unblocks everything: content in git, not in a database

The obvious plan is a CMS on hyperion + mnemosyne. **That plan makes all three sites
depend on the least-finished framework in the tree** — mnemosyne has six open research
questions, and the [open-questions triage](open-questions.md) identifies it as the
critical path for the entire launch.

But look at what these sites actually are. A blog, a CV, and a documentation site are
**read-mostly, single-author, and versioned by nature.** Every one of those properties
argues for the same thing:

- Content changes ~daily at most, and is written by one person.
- Reads vastly outnumber writes — and with git-backed content, reads are served from
  memory with no query layer at all.
- You already want history, diffs, and rollback for prose. That is git, and a database
  would be reimplementing it worse.
- Editing in an editor beats editing in a browser form, for someone who lives in an
  editor.

**Recommendation: content is markdown + front-matter in a git repo, loaded into the live
image at boot and hot-reloaded on change.** Not a database.

What this buys, in order of importance:

1. **The sites stop being gated on mnemosyne.** They can ship while the persistence
   questions are still open — which converts the site program from *blocked on the
   critical path* to *running alongside it*. Given that the launch's second case study is
   meant to be codelisperer.org, this is the single most valuable consequence.
2. **Deployment gets trivial.** No database to provision, back up, or migrate. A single
   binary plus a content directory.
3. **It is a better hyperion demo.** "Server-rendered hypermedia over an in-memory content
   tree, hot-reloaded" shows off exactly what hyperion is good at, with nothing else in
   the frame.

**Where a database genuinely is needed** — and only here:

| Feature | Needs a DB? |
|---|---|
| Posts, pages, docs, CV | No — git |
| Tags, search index, RSS | No — derived at boot |
| Contact form submissions | Yes, but a trivial append-only table |
| **Products, orders, entitlements, licence keys** | **Yes, genuinely** |
| **Recruiter fit-generator sessions, rate limits, cost ceilings** | **Yes — see below** |

**Amended 2026-09-16.** Two sites now need mnemosyne, for different reasons:

- The **company site** needs it for products, orders and entitlements, plus
  [hermes payments](https://github.com/codelisperer/ouranos/issues/47). It sells
  **wordcrafter** and **soloflow**. Unchanged from the original.
- The **personal site's fit generator** needs it for whatever a recruiter session persists,
  and it needs praxeon's **ceilings** (`budget-guard`, `meter`, `capability-guard`) rather
  than optionally wanting them. An LLM endpoint open to unauthenticated strangers is a cost
  surface, an abuse surface and a prompt-injection surface at once. This is the first real
  dogfood of that work — the ceilings exist precisely for a case like it.

Neither dependency reaches the **static** half of either site, which is the whole point of
the layer split in §4.

## 1b. Why a live image, and where klio stops

*Maintainer, 2026-09-16 — the positioning statement. Added because §1 argued content should
not be in a database without saying why the site still needs a server at all.*

**It is not an SPA.** Generating SPAs is not in this stack's quiver — there are valid use
cases and it should be supported eventually, but it is not the model here. So a klio site
cannot run on content alone: **HTMX fragments are generated on demand**, and generation
needs a running server.

Precisely, because the loose version invites an easy rebuttal: HTMX over *pre-generated*
fragments can be served from static files. What cannot is anything **parameterised** —
search over an index built at boot, filtered pagination, forms, anything reflecting request
state. Those are the ordinary case, not the exotic one, which is why the server is not
optional.

**The dividing line is the database, and it is the whole product boundary:**

| | |
|---|---|
| No database needed | **klio is enough** |
| A database is needed | **you want a full hyperion web service** |

That is a question a user can answer about their own project. *"Is my site dynamic enough?"*
is not — which is why this framing is the pitch rather than an adjective about liveness.

**klio sits in the gap between static-only and full-on data-driven apps**, and the gap is
real: spinning up, backing up and migrating a database for a brochure site or a blog is
overkill, while a static generator cannot serve a search box. Nearly every tool picks a side.

## 2. Shape: a CMS library, three thin sites

Not one repo with three modes, and not three repos each with their own CMS.

```
ouranos/klio                MIT, IN THE MONOREPO — the engine. A hyperion library:
   │                        content loading, rendering, feeds, search, admin preview.
   │                        THIS is the case study; the sites are its instances.
   ├── codelisperer.org     separate repo, PUBLIC  — theme + content + config
   ├── bobcalco.net         separate repo, private — theme + content + config
   └── SoftCraft site       separate repo, private — theme + content + config, plus commerce
```

> **Corrected 2026-09-16.** The original diagram showed the engine as its own repo. **No
> decision ever said that** — it inherited the framing from the 2026-07-22 note about *the
> website*, whose reasons were (a) outside contributors must not get write to the
> maintainer's site and (b) proprietary content above MIT frameworks. Both are about the
> **sites**. Neither touches an MIT *library*.
>
> `ECOSYSTEM.md`'s actual rule is *"a consuming app stays a SEPARATE repo (proprietary)"* —
> and klio is neither a consuming app nor proprietary, so it fails both halves of the test.
> It is a satellite in the monorepo, coequal with `hermes` and `hades`, attaching at
> `hyperion` rather than `aion`. In-tree it co-versions with hyperion instead of needing a
> pinned-Ouranos dependency, and the gate loads it.
>
> The **sites** remain separate repos, for the original reasons, which still hold.

The reasoning:

- **The engine, not any one site, is the case study.** "Here is a real, non-trivial,
  MIT-licensed application built on Ouranos — read the source" is worth more to a
  skeptical reader than three sites they cannot inspect. It also gives the launch a second
  showable artifact without inventing a contrived example.
- **Visibility differs per site.** codelisperer.org's source should be public (that is the
  point); the company site's should not. One repo cannot be both.
- **A site becomes small.** A theme, a content directory, a config. If instantiating the
  third site is not nearly trivial, the engine's abstraction is wrong — a useful forcing
  test.

**Named `klio`** (maintainer, 2026-09-16) — the Muse of history, chosen because the
engine's load-bearing decision is that content lives in git, so every page has a history.
The name says what distinguishes it from every other static-site generator. The Fates
(Clotho/Atropos/Lachesis) were already taken; the Muses were the unclaimed family.

## 3. What is genuinely shared, and what is not

Guarding against the classic failure — over-abstracting three things that turn out to
differ where it matters.

| | Shared | Per-site |
|---|---|---|
| Content loading, front-matter, hot reload | ✅ | |
| Routing, pagination, tags, RSS/Atom | ✅ | |
| Search (in-memory index) | ✅ | |
| Markdown → Spinneret rendering | ✅ | |
| Syntax highlighting | ✅ (docs and blog both need it) | |
| Theme / layout / typography | | ✅ |
| Nav structure, taxonomy | | ✅ |
| **Docs versioning, API reference** | | codelisperer.org only |
| **Live demo hosting** | | codelisperer.org only |
| **CV as structured data** | | personal site only |
| **Products, checkout, entitlements** | | company site only |

The middle block is the real engine. The bottom block is why they are three sites and not
one with a switch.

## 4. Sequencing

> **AMENDED 2026-09-16 — the original argument no longer holds, and the replacement is
> better.** This section assumed the personal site was the simplest of the three. It is
> not: it carries an **AI resume and cover-letter fit generator** for recruiters, which is
> a live praxeon surface rather than content. And the company site was deferred for needing
> commerce, which it confirmedly does — it sells **wordcrafter** and **soloflow**.
>
> So *neither* private site is trivial, and sequencing by whole-site simplicity no longer
> discriminates. **Sequence by layer instead:** every site has a static half that is pure
> `klio`, and at most one dynamic half that is not.
>
> | | static half (klio alone) | dynamic half |
> |---|---|---|
> | personal | bio, work history, writing, the CV as structured data | the fit generator — **praxeon** |
> | company | consulting, domains, Ouranos advocacy, Leadership | commerce — **mnemosyne + hermes/payments** |
> | codelisperer.org | docs, blog | demo hosting |
>
> **Build `klio` plus both static halves first, then the two dynamic halves independently.**
> That puts two sites live early, proves the engine against two instances at once — the
> doc's own forcing test, applied immediately rather than deferred to a third site — and
> isolates the two risky pieces so neither blocks a site from existing.
>
> This is the same app-first/layer-it principle the maintainer applied to the marketing
> integrations on 2026-09-16 (see [`ECOSYSTEM.md`](../../ECOSYSTEM.md)): get something
> working, keep the seam visible, promote what proves reusable.

**Original argument, superseded:** personal site first, not because it matters most but
because it matters least — the simplest of the three, so it proves the engine where a
mistake costs nothing.

**codelisperer.org second.** Adds docs versioning, syntax highlighting, and demo hosting.
By then the engine is real and the site is mostly content. It becomes launch case study
number two, alongside the desktop Coalton REPL.

**Company site last.** It is the only one that needs mnemosyne *and* hermes payments, and
it is the only one where being wrong costs money. It should be built on an engine that has
already run in production twice.

Note the release-scope decision doc concluded the **launch should not wait on the sites**.
With the git-backed content model this is comfortable rather than a compromise: the sites
can land before, during, or after the launch without blocking it either way.

## 5. Ported CMS features

The engine borrows from a prior consuming app's CMS. Two constraints on that port:

- **Nothing identifying travels with it** — no client name, no branding, no static assets,
  in code, comments, commit messages, or history. The engine is a clean-room reimplementation
  in the sense that matters: the *ideas* port, the artifacts do not.
- **The prior app is Clojure/Kit/Postgres.** Its content model assumes a database. Do not
  port that assumption along with the feature list — §1 deliberately departs from it, and
  a straight port would drag mnemosyne back onto the critical path.

Worth porting: the editorial workflow (draft/publish/schedule), taxonomy handling, media
handling, and the admin preview. Worth leaving: anything that exists only because content
lived in Postgres.

## 6. Open questions

- **The engine's name** (§2) — a public package name; decide deliberately.
- **Admin surface**: does the engine need a browser-based editor at all, or is
  editor-plus-git the whole authoring story? Leaning strongly toward the latter for v1 —
  it is less code and a better fit for the author. A preview surface is still wanted.
- **Deployment target**: DigitalOcean is the presumption. A single binary plus a content
  directory is a low bar; decide once and script it.
- **Comments**: none for v1. It is a moderation burden, and the ecosystem convention is to
  discuss on the issue tracker.
- **How content updates reach production** — git push triggering a rebuild, or a running
  image pulling and hot-reloading. The second is more in the spirit of the live-image
  thesis and would itself be a good demo.
