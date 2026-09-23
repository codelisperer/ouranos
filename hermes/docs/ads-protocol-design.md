# An ads protocol for hermes — the neutral vocabulary, and where portability stops

**Status:** design note, open for revision. Not an ADR yet — one decision (targeting) is
still open, and an ADR written before it would be an ADR about the easy half.
**Issue:** [#114](https://github.com/codelisperer/ouranos/issues/114) · **Date:** 2026-09-14

## Why a note before code

#114 exists because the tree has promoted an application's code into a framework twice and
lost requirements both times, the same way each time: **an app builds the shape its own
screen needs, and a framework needs the shape every app will need.** Promotion then reads as
a move rather than a redesign, and nobody re-derives the difference.

So this note fixes the vocabulary *first*, and its job is to be constraining rather than
descriptive. Every noun below is one an application can build against today.

Everything in it came from asking the consuming app what it actually has, not from reading
Meta's API and renaming things. Where the app's answer contradicted the ticket, the app won.

## The finding that reshaped the design

The ticket's "measure" half assumes the interesting outcome is one the network can see.
**For a real application it is not.** From the app:

> the network sees a signup; it cannot see that the member upgraded tier eleven weeks later

The app's existing ads touchpoint is a campaign-labelled invite link that joins a click to a
signup and thence to a paid tier. So the question it actually asks is *"which ad produced
members who are still here"*, and the answer lives in **its** database, not the network's.

That gives the protocol a hard boundary, and it is the most important line in this note:

> **The protocol owns network-observed outcomes. It does not own the app's outcomes, and it
> must not pretend to.** What it owes the app instead is the ability to *join* the two.

Concretely: every campaign, ad set and creative carries an **app-supplied correlation
reference** that the protocol undertakes to round-trip — out to the network on create, and
back on every metrics read. The app puts its own key in; the app gets its own key back; the
join is the app's and is trivial. A protocol that returned only the network's own ids would
force every consumer to maintain a side-table mapping them, which is exactly the boilerplate
a neutral layer exists to delete.

## The nouns

Neutral, and none of them a network's spelling:

| noun | what it is |
|---|---|
| **Campaign** | the objective and the thing a budget hangs off |
| **Ad set** | an **Audience** + budget + schedule. The unit that spends |
| **Audience** | who to show it to — *see the open question below* |
| **Creative** | the rendered thing: copy, media reference, destination |
| **Variant** | one arm of a test, always under an ad set |
| **Spend** | `Money`, minor units, never a float |
| **Reading** | a metric **with the time it was read** — see below |
| **Review** | the asynchronous approval state |

`Ad set` rather than a network's word for it, and `Audience` split out as its own noun
precisely because it is the part most likely to resist neutrality: keeping it separate means
the escape hatch can be scoped to it rather than smeared across everything.

## Money: reuse, and lift

`hermes/payments/money.lisp` already has it — `Money Integer Currency`, minor units, and
deliberately **no float constructor**. Ads reuses it rather than inventing a second.

Two consequences:

- **`Money` should be lifted out of `hermes/payments` into a small shared system**
  (`hermes/money`). Today an ads module reusing it would have to depend on the whole
  payments system — Stripe, jzon, ironclad — for a two-field type. Same shape as
  `aion/secret` being dependency-free so `cons` could hold a DB password without gaining
  Coalton. Cheap now, a breaking move later.
- The app confirms it stores integer minor units already (`*_cents` columns) with **no
  currency recorded** — implicit in the provider account. Adopting `Money` is a straight
  adoption that *gains* it a currency rather than a reconciliation.

## Readings are not numbers, and this is how a leaf-lib enforces it

Attribution windows mean a given day's figure **changes for days afterwards**. A store that
treats the first answer as the answer reports wrong numbers and looks stable while doing it.

hermes cannot fix this by storing anything — it is a leaf-lib and must not grow a datastore.
But it can make the loss impossible to take accidentally:

> **No metrics operation returns a bare number.** It returns a `Reading`: the figure, the
> window it covers, and **`as-of` — when the network was asked.**

The caller may still throw `as-of` away, but it has to do so on purpose. A leaf-lib that
cannot own storage can still own the *unit of data*, and make the dimension that is easy to
lose part of the value rather than part of the discipline.

This matters more than #114 suggests. From the app: it stores no metrics today, and its rows
carry `created_at`/`updated_at` and a `vid` — which is **version, not valid-time**. It
records that a row changed, not what was true when. So there is nowhere for a revised figure
to live without new columns, and the app is carrying this because
**mnemosyne's bitemporal support is designed and not built** —
[#49](https://github.com/codelisperer/ouranos/issues/49) is the implementation ticket,
gated by [#54](https://github.com/codelisperer/ouranos/issues/54). (pre-publication issue 227 is the
stale-claims sweep where that gap was *found*; a finding's provenance is not its home.)

**And this workload does not justify prioritising #49, which is worth saying plainly so
nobody cites it as if it did.** What ads metrics need is narrow: record *when a figure was
read* alongside *what day it describes*. Two time axes, so bitemporal in shape — but for one
append-only table of `(campaign, day, read_at, value)` it is roughly fifteen lines of
application code. **#49 is a convenience here, not a blocker.** Its real case is the general
one: once several entities want "what did we believe on date X", every app hand-rolling its
own read-time column is the sprawl argument, and that case stands on its own without this
one propping it up.

## Review and delivery are two axes, and the ADT says so

An earlier draft of this note had three variants, taken from the consuming app's existing
*post* review machine. **That model was from the wrong domain and the app caught it:**

> a post has one axis, an ad has two. A post is either out or not. **An ad can be approved
> and still not running.**

Two states three variants could not express — an ad **created but not yet submitted** (a
finished thing deliberately held, which is not the same as someone else being the blocker),
and an ad **approved but paused**, which has no analogue among posts at all and is the state
an app most often needs to *act* on, since pausing and resuming spend is the common
operation and is not a review outcome.

So:

    Review  =  Unsubmitted              created, deliberately not sent
            |  In-Review <who>          submitted; someone else is the blocker
            |  Approved <Delivery>      permitted -- and delivery lives HERE
            |  Refused <reason>         terminal, and the reason is carried

    Delivery = Running | Paused

**Delivery hangs off `Approved` rather than sitting beside `Review`**, because it is only
meaningful once permission exists. Nesting it makes "paused but refused" and "running but
unsubmitted" unrepresentable rather than merely undocumented — the ADTs-over-booleans rule
applied to a pair of states that a flat model would let disagree.

`Approved` rather than `Visible`: the variant is about **permission**, not about delivery,
and naming it for the wrong axis is what let the two collapse in the first place.

`Refused` still cannot exist without a reason. The app has had that complaint on its own
surface — a rejection with no reason gives the author nothing to act on — and it is the
part of the original three worth protecting unchanged.

**What getting this wrong looks like**, in the app's words: *an app that cannot tell "the
network refused this" from "we turned it off", and reports a paused campaign as rejected.*

## Who owns the statistics

Design so both are possible; implement one.

**The primitive is per-variant `Reading`s.** From those an app can compute its own
significance whenever it wants. Reading the network's own experiment verdict is then an
*additional*, optional operation — not the foundation.

The app's reasoning, which I find convincing: it has no analysis machinery and no appetite to
grow one, so reading the network's own result is the cheaper first move — but the moment
several of its own segments are running ads, the interesting question is comparison *across*
them, **which the network cannot answer because it does not know what those segments are.**
Building only on the network's verdict would make that permanently out of reach.

## The escape hatch

Where a concept has no neutral form, it is named as such rather than given a neutral-sounding
name that leaks. A typed network-specific parameters carrier, attached to the noun it
qualifies (most likely `Audience`), so a reader can see exactly where portability stops.

**A leaky neutral name is worse than an honest escape hatch**, because the first is only
discovered by the second network.

## Measured: eight platforms, and what actually ports

*Surveyed 2026-09-15 against official developer documentation, at the versions named below.
This section is **evidence for the open questions, not an answer to them** — Q1 and Q2 remain
the maintainer's call. It exists because "how neutral is `Audience`" was being argued from one
network, and the note's own rule says a leaky neutral name is only discovered by the second.*

**Versions observed:** Meta Marketing API **v26.0** (2026-07-29) · TikTok **v1.3** (no v2.0
exists) · Google Ads **v25** · LinkedIn **202608** · X Ads **v12** · Reddit Ads **v3** ·
Snapchat Marketing **v1** · Instantly **v2**. Ad APIs version quickly and several of these
pages disagree with each other *today*; every claim below carries its own source in the
research thread, and the **gaps are marked as gaps** rather than filled in from memory. An
unverified field name is worse than a blank, because it gets designed against.

### What is genuinely universal

Strictly — present on **every** ad platform surveyed, with compatible semantics:

1. **A three-tier hierarchy with targeting attached one level above the creative.** Campaign →
   Ad Set (Meta) / Ad Group (TikTok, Google, Reddit, Pinterest) / Line Item (X) / Ad Squad
   (Snapchat) / Campaign (LinkedIn, whose extra tier is above, not below).
2. **Country-level geography** — with the caveat that the *identifier space* differs on all
   eight, and ISO-3166 alpha-2 is a valid value on only some.
3. **A binary male/female selection.** The third value is not universal (below).
4. **Interest targeting by platform-assigned taxonomy ID, never free text**, with a named
   lookup endpoint on every platform.
5. **Customer-list audiences as pre-created, asynchronous, ID-referenced objects**, populated
   with SHA-256-hashed identifiers and gated on a minimum size before they can be targeted.
   **The single most robust pattern in the survey.**
6. **Pixel/tag retargeting audiences**, likewise separate objects referenced by ID.

That is the whole list. **Everything else fails on at least one platform.**

### Age is the acid test, and it fails

This bears directly on Question 1's option A, whose neutral core is *"geo, age, language"*.
**Age does not survive the second network, let alone the eighth.**

| Platform | Form | Values |
|---|---|---|
| **Meta** | continuous integers | `age_min`/`age_max`, 13–65 |
| **TikTok** | 6 fixed buckets | `AGE_13_17 … AGE_55_100` |
| **Google** (criterion) | fixed enum | `18_24 … 65_UP` |
| **Google** (Audience resource) | integers **snapped to bucket edges** | min ∈ {18,25,35,45,55,65}; max ∈ {24,34,44,54,64} |
| **LinkedIn** | 4 buckets, include-only | `(18,24) (25,34) (35,54) (55,∞)` — **35–54 is one bucket** |
| **X** | bucket name, **one per line item** | only `AGE_21_TO_34` is verifiable; the full enum is **undocumented** |
| **Reddit** | **none on the ad group at all** | integers exist only on forecast endpoints |
| **Snapchat** | buckets **and** min/max | `13-17 … 35+`; min 13–35, max 13–55 (asymmetric) |
| **Pinterest** | 10 **non-disjoint** buckets (legacy) *or* min/max, mutually exclusive | `18-24, 19+, 20+, 21+, 25-34 …` |

Four independent incompatibilities:

- **Reddit cannot express age.** Any neutral age field must be droppable, loudly.
- **No two bucket sets agree.** Google and Pinterest split 35–44/45–54; LinkedIn merges them;
  Snapchat stops at `35+`; TikTok's top bucket opens at 55 where Meta's opens at 65.
- **The floor differs** — 13 on Meta/TikTok/Snapchat, 18 elsewhere.
- **No platform has a true age range.** Google's integers are bucket boundaries wearing
  integer clothing; Snapchat's and Pinterest's min/max are bounded and asymmetric. Meta is the
  *only* continuous interval, and `age_min: 22, age_max: 27` is inexpressible on TikTok, while
  a non-contiguous `{18-24, 45-54}` is inexpressible on Meta.

A neutral `(min, max)` must snap to per-platform buckets when lowering, and **snapping is lossy
in a direction that changes who sees the ad.**

### Language fails too, more quietly

Present on all eight, meaning three different things: Meta's `locales` are **numeric platform
ids** needing a live lookup (`6` = en-US, `24` = en-GB); LinkedIn's `interfaceLocales` is the
member's **UI locale**; Google's is a **criterion id**; TikTok, X, Snapchat and Pinterest use
**ISO-639-1 strings**; Reddit uses a **closed platform enum**. Meta is locale-grained where
TikTok is language-grained, so the values are not interchangeable even between the two networks
the note was written against.

**Of option A's proposed core — geo, age, language — only geo survives, and only at country
granularity.**

### The finding that changes the shape: targeting is not always a filter

**Four platforms have a mode in which the same fields stop being constraints and become hints,
and on all four the discriminator lives *outside* the targeting object.**

| Platform | Switch | What it relaxes |
|---|---|---|
| Meta | `targeting_automation.advantage_audience` | age, gender, detailed targeting, custom-audience inclusion |
| TikTok | `smart_audience_enabled` | interests/behaviours — **explicitly not** age, gender or location |
| Google | `TargetRestriction.bid_only: true` | the criterion stops restricting reach entirely (Observation) |
| Reddit | ad group `AUTOMATED` | the identical JSON becomes **seed signals**; geo and exclusions stay hard |
| Snapchat | `auto_expansion_type: SMART_TARGETING` | gender and `max_age` become expandable |

Meta relaxes demographics; TikTok explicitly does not. **Treating these as one "expansion" flag
changes whether a stated gender is a constraint or a suggestion.** A neutral `Audience` that
does not carry this discriminator means something different on every network — and Meta's
`advantage_audience` is documented as defaulted for new ad sets from v23.0, which if it holds
means *"target exactly and only this audience"* may no longer be expressible there at all.

### Boolean structure does not port

- **Meta** — `flexible_spec` is an AND-of-ORs algebra (25 × 1,000) with a negated OR-block.
- **TikTok** — flat sibling arrays. `(A∨B) ∧ (C∨D)` is **inexpressible**, and the boolean
  relationship between its interest fields is **nowhere documented** — do not assume AND.
- **LinkedIn** — fixed-depth CNF with facet URNs as object keys, an asymmetric `exclude`, and
  **pairwise AND prohibitions** (industries may not be AND'ed with employers; seniorities not
  with job titles) that are a compatibility matrix rather than a type.
- **X** — the sharpest one. Primary types are **UNION'd across different types**:
  `[(Followers) ∪ (Custom Audiences) ∪ (Interests) ∪ (Keywords)] AND (Location) AND (Gender)`.
  Any model assuming uniform inter-type AND produces a materially different audience on X —
  **and it validates, and it serves.**
- **Google** — criteria are separate resource rows; `negative` is **immutable** (remove and
  re-add to flip).
- **Snapchat** — AND/OR is object-scoped, and EXCLUDE is a global subtraction applied last.

**Exclusions:** four mechanisms in kind, and **no platform permits exclusion on every
dimension.** TikTok can exclude *audiences only* — no excluded geography, interest or
demographic exists. LinkedIn blocks it on age/gender/locales; Pinterest on
interest/age/gender/locale; Snapchat's legality depends on the **id prefix inside a single
array**. A uniform `Not` combinator is unrepresentable roughly half the time.

### Where the escape hatch has to sit

Two structural facts argue against `Audience` being a self-contained description of people:

- **On TikTok a lookalike is bound to `placements` and `mobile_os` at creation** — both
  required. The same seed yields different audiences per placement, so audience is **not
  orthogonal to delivery** there.
- **The same capability lives at different layers.** TikTok exposes video/creator/hashtag
  interactions as ad-group *targeting fields* with a 0/7/15-day window; on Meta the equivalent
  is a **Custom Audience you create first**. One field in a neutral type cannot be both.

And the uploaded-list surface differs by an order of magnitude: **Meta accepts 15 identifier
keys** (including name, city, state, zip, country, DOB parts) where **TikTok accepts three**
(email, phone, MAID). A neutral customer-list type with name/address fields has nowhere to put
them on TikTok, and **silently dropping them changes the match rate — which is the entire point
of the object.** Retention ceilings differ too (Meta 180 days, TikTok 365), so a neutral field
must clamp, lossily, in one direction.

### False friends — same word, different thing

| Term | One network | Another |
|---|---|---|
| **Behaviors** | Meta: durable inferred traits from a taxonomy | TikTok: **on-platform interactions in the last 0/7/15 days** |
| **Saved Audience** | Meta: **read-only**, no ad-set field references it | TikTok: creatable, attachable, and **mutually exclusive** with the inline fields it contains |
| **Custom Audience** | Meta: the node type; lookalike is a `subtype` **inside** it | TikTok: an umbrella category with lookalike as a **sibling** |
| **zip** | Meta: the literal code, `"US:94304"` | TikTok: an **opaque platform id** needing a lookup |
| **Audience expansion** | Meta: relaxes demographics | TikTok: explicitly **does not** |
| **"Advanced"** | Meta: a permission tier | TikTok: a rate-limit tier |

### Credentials: the question that shapes the framework

**Is there a machine-to-machine path, or does a human have to re-authorize on a schedule?**

| Platform | M2M without periodic human re-auth | Failure mode to design for |
|---|---|---|
| **Google** | **Yes** — true service accounts, now the default path | — |
| **TikTok** | **Yes** — `access_token` **never expires**; no refresh token exists | token invalid → **raise for human re-auth**, not a refresh timer |
| **X** | Yes — OAuth 1.0a tokens do not expire | user revocation |
| **Snapchat** | Yes — refresh token never expires | dies if **the user it is tied to** loses access |
| **Reddit** | Yes, with `duration=permanent` | — |
| **Meta** | **Yes, conditionally** — System User tokens do not expire… | **…but 90 days of app inactivity invalidates every token.** Build a heartbeat |
| **Pinterest** | **Unresolved** — `client_credentials` exists; whether it reaches ads endpoints is undocumented | needs one live call |
| **LinkedIn** | **No.** *"The 2-legged client credentials flow is not available for any marketing use cases."* | refresh token 365 days and **non-rolling** |

**LinkedIn is a design constraint, not an ops detail:** human re-consent every ≤365 days per
connected account must be a **normal lifecycle state** in the framework, not an error path. Meta
is its mirror image — a real service credential that dies quietly if the app goes idle.

**Read-only scopes, which decide whether Question 2's "measure alone" is actually cheaper:**
clean separation on Meta (`ads_read` vs `ads_management`), LinkedIn (`r_ads` vs `rw_ads`),
Reddit, Pinterest and TikTok (whose numeric scopes split read from create/update per resource).
**No read-only tier exists on X or Snapchat** — Snapchat's single `snapchat-marketing-api` scope
is read *and* write, and least privilege is reachable only through the authorizing user's
Business Manager role, which is **invisible in your own credential store**. So "read first" is
genuinely cheaper on six of eight, and on two it buys nothing but discipline.

**Sandboxes are worse than they look, and they are worst exactly where this design is hardest:**

- **TikTok** has a sandbox, but it covers **22 endpoints and excludes all of DMP/audience** —
  the audience surface cannot be exercised there at all.
- **Pinterest** has a sandbox; `/audiences` is **not on its allowlist**.
- **LinkedIn** has no sandbox, and its test accounts **cannot upload audience segments**.
- **Meta**'s sandbox reaches audiences, but its own docs contradict themselves on whether ads
  and insights work there.
- **Reddit** and **Instantly** have **none at all**.
- **X**'s is the best of the eight — self-provisioned accounts, funding instruments, and
  feature flags.

**Calendar cost to a first call**, which is the number that decides a roadmap: Meta ~0 days
(Limited Access on adding the product) · Google Explorer auto-granted · Pinterest ~1 business
day · TikTok **~5–6 business days of staff review, and individual developers are barred
outright** (company domain email and a matching public website required) · LinkedIn **no
published SLA** · X 3 business days **plus a second discretionary review of your product's UI**
with no stated timeline.

### Instantly.ai is a different kind of object

Researched at the maintainer's request. It is **cold-email outreach, not an ad network** — it
sells no inventory; you connect your own mailboxes and send sequenced mail to people you supply
or buy. Under this note's vocabulary, **four of the eight nouns break**:

| Noun | Verdict |
|---|---|
| **Campaign** | Holds — a real object with a comparable status lifecycle |
| **Variant** | Holds — it is literally their word (`variants` on a step) |
| **Reading** | Holds structurally; the basis is `emails_sent`, not impressions |
| **Ad set** | **No analogue** — one sequence per campaign |
| **Audience** | **Breaks by equivocation** — see below |
| **Creative** | **Breaks** — the word does not appear; copy lives on a step |
| **Spend** | **Breaks completely** — no per-delivery cost exists anywhere |
| **Review** | **Breaks** — nothing vets copy before it sends |

**The `Audience` equivocation is the load-bearing one.** Instantly has two incompatible things
and the word "audience" is used for only one of them: a **`LeadList`, which is enumerated** (its
schema has no criteria field at all — membership is whatever rows you put in it), and
**SuperSearch `search_filters`, which are criteria** (title, industry, seniority, employee
count, technologies, funding, hiring signals). But the criteria **materialize into a list once
and then stop mattering** — an ad platform's audience stays a live predicate the network
resolves at each delivery.

Two asymmetries worth carrying into any decision:

- **`Review` inverts.** Ad networks gate on **content**, pre-flight, by the platform. Instantly's
  negative states (`Accounts Unhealthy`, `Bounce Protect`, `Account Suspended`) gate on **sender
  infrastructure health**, mid-flight, driven by your own bounce rates.
- **Authentication is not usefulness.** A Meta or Google integration works the moment it
  authenticates. Instantly authenticates in minutes and is **not useful for two to three weeks**
  — domain DNS (SPF/DKIM/DMARC, with a documented 48-hour settling period) and mailbox warmup to
  a >90% health score. That delay is a physical property of email reputation, not a policy you
  can request an exception to. API access also requires a **paid plan** — every endpoint declares
  a `402` for workspaces without one — and there is **no sandbox**: every write is against live
  production and live mailboxes.

**And the obligations are not the same.** An ads audience is anonymous and lives on the
network's side; you upload a *description*. A lead list is a **register of identified people that
you hold and transmit**, with the customer as GDPR **controller**. If this framework stores or
relays lead rows it joins that processing chain and inherits lawful-basis, retention and
deletion-propagation duties. Paid advertising carries none of this.

**Assessment: a sibling category rather than a member of this vocabulary** — sharing `Campaign`,
`Variant` and `Reading`, and *not* `Audience` or `Spend`. A nullable spend column that is always
null for a whole class of platform will eventually be read as zero by something downstream.

### What the evidence says to the open questions

It does not answer them; it narrows them.

- **Option A's core does not survive.** Of *geo, age, language*, only geo ports, and only at
  country granularity. A thin neutral skin is still defensible — but it is **thinner than the
  option as written**, and age is the field most likely to be assumed portable by a reader.
- **Option C is better supported than it looked.** Audience definition genuinely does not port:
  the boolean structure, the exclusion model, the age vocabulary and even the *filter-versus-hint
  semantics* differ structurally, not cosmetically.
- **Whatever is chosen, three things deserve to be type errors rather than silent clamps** —
  age bucketing, dropped customer-list identifier keys (it changes match rate invisibly), and
  exclusions that are not audience exclusions.
- **One shape is worth adopting regardless of Q1**: audiences are **stateful resources**, not
  values — created separately, populated asynchronously, gated on a readiness status and a size
  threshold, referenced by id. That is true on all eight and should shape the type rather than
  be an implementation detail.
- **For Q2**, read-only scopes exist on six of eight, which makes "measure alone" cheaper in
  fact and not merely in prudence. The counterweight is that audience *creation* is the surface
  sandboxes cover worst, so the create half will need live accounts whenever it is built.

**These figures rot.** Google's developer tokens were sunset **2026-09-09**, six days before this
survey, and two official Google pages dated one day apart still disagree about whether the
header is required. Re-verify before building against any specific field here.

## Open: targeting

Deliberately unfixed — and now informed by the eight-platform survey above, which narrows
the options without settling them. #114 says audience definition is the part most likely to
resist neutrality and should be prototyped first; the app's answer is that this is the founder's
call, not the code's, and inventing a taxonomy here would be precisely the
app-shape-versus-framework-shape failure this note exists to prevent.

What the answer decides:

- whether `Audience` has neutral structure at all, or is mostly escape hatch with a thin
  neutral skin. **This note originally proposed geo, age and language as "the parts every
  network has"; the survey above measured that and it is false** — only geo ports, and only at
  country granularity
- whether custom audiences from a pixel or a customer list are in scope, since those carry
  **personal data** and a neutral vocabulary for them is a privacy surface, not just an API
  one
- whether exclusions are first-class

**If the honest answer is "most of it is network-shaped and will not port", that is a
finding and it belongs in the note as the escape hatch** — not papered over with neutral
nouns that only work for one network.

## Also open: what gets built first

#114's order is create → target → test → measure. Both the app and I think the real first
deliverable is likely the **measure** half alone — reading spend and outcomes for campaigns a
human created in the network's own UI — with create and target designed but unbuilt. That is
the founder's call; it is recorded here so the note is not read as proposing the full surface
at once.

## Carried from #114 without restating

Rate limits and errors go through the condition system with restarts, never return codes.
The API version is pinned explicitly where a reader finds it. A refresh path that has never
run does not work, so token expiry needs a test that exercises it. And any operation that
creates or raises a budget is harder to invoke by accident than one that reads — **a dry-run
that renders exactly what would be sent, without sending it, is worth building first rather
than retrofitting**, because spend is real money.
