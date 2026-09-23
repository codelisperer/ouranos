# ADR-0003 — Ads: how neutral `Audience` is, and which half ships first

**Status:** Proposed — 2026-09-15. **Two open questions awaiting the maintainer.**
**Amended 2026-09-15** with an eight-platform survey (Meta, TikTok, Google, LinkedIn, X,
Reddit, Snapchat, plus Instantly as a non-ads comparison) — see
[`../ads-protocol-design.md`](../ads-protocol-design.md). It narrows the options and corrects
one factual claim in option A below; it does not answer either question. Everything
else in the ads protocol is settled and is being built as
[#327](https://github.com/codelisperer/ouranos/issues/327); these two are what
[#262](https://github.com/codelisperer/ouranos/issues/262) is `Blocked` on.

> **Read Question 0 first.** It was added after the other two and it may make them moot: if
> the minimum product needs no Meta credential, there is nothing to decide about targeting
> vocabulary yet. The questions below it were written assuming an integration; Q0 asks whether
> one is needed.
>
> **This file exists so the questions can be answered in one sitting.** They were spread
> across the tail of [`../ads-protocol-design.md`](../ads-protocol-design.md), an issue
> comment, and a board field, which meant answering them started with finding them. Answer
> below — pick a letter per question — and this becomes Accepted with the choice recorded.

## Context

`hermes` is growing an ads protocol, Meta first, so a consuming app can create, target, test
and measure ad spend against effect. The design note settles the vocabulary: **Campaign, Ad
set, Audience, Creative, Variant, Spend, Reading, Review** — none of them a network's
spelling. `Money` is reused from `hermes/payments` (minor units, no float constructor) rather
than reinvented. A `Reading` carries the time it was read, because a metric without one is a
number pretending to be a fact.

Two things were deliberately left open, because getting them wrong is the
*app-shape-versus-framework-shape* failure the whole note exists to prevent — a vocabulary
that looks neutral, fits exactly one network, and is only discovered to be wrong by the
second one.

`Audience` was split out as its own noun for precisely this reason: it is the part most likely
to resist neutrality, and keeping it separate means an escape hatch can be **scoped to it**
rather than smeared across every noun.

---

## Question 0 — Does the minimum product need the ads API at all?

**Asked first because it may make everything below moot.** Added 2026-09-15 after the
maintainer stated the requirement in product terms rather than API terms. Everything that
follows assumed a Meta integration; this asks whether one is needed.

The site is most visibly two things: **it generates content** members use in their own ads
anywhere, and **it tracks which leads land at which campaign on behalf of which referring
member**. A third is wanted but not required: **reading members' campaign results** to help
them judge marketing efficacy.

| capability | needs a Meta credential? | needs App Review? | needs tenancy? |
|---|---|---|---|
| **A. Content generation** | **no** | no | **no** |
| **B. Lead attribution by campaign and referring member** | **almost certainly not** — see below | no | **no** |
| **C1. Efficacy, from a member-supplied export** | **no** | no | **no** |
| **C2. Efficacy, read live from Meta** | yes, `ads_read` | **yes** + Business Verification | **yes** |

**So tenancy is required by exactly one row, and it is the optional one.**

### B is the load-bearing claim, and this project has not measured it

A member running a Meta ad sets its destination URL. Whatever parameters that URL carries
arrive at *your* server when someone clicks — so the campaign id and the referring member can
be carried in a link you generate and the member pastes, and recorded on arrival. Meta also
appends `fbclid` to outbound clicks. **None of that is an API call and none of it needs a
credential**, which is why it needs no review and no tenancy.

**Flagged rather than asserted:** the eight-platform survey measured the *ads API*. It did not
measure this, because outbound click attribution is not an ads-API problem. Treat the row above
as a strong prior to verify, not as a finding — and verify it against Meta's current outbound
URL behaviour before building on it. The failure mode if it is wrong is not subtle: attribution
is the product.

The known soft spot is not technical but procedural: **it depends on the member using the link
you gave them.** Hand-edit it, or build the ad from scratch, and attribution breaks silently.
That is a UX problem — generate the URL, make copying it the obvious path — not an API one.

### What B gives you and what it does not

B yields the **outcome** half: leads, per campaign, per referring member. It yields **nothing
about cost** — no spend, no impressions, no clicks.

Efficacy is outcome over cost, so the cost half has to come from somewhere, and that is the
entire reason to consider the API:

- **C1 — the member supplies it.** A pasted or uploaded export from Meta's own reporting. No
  credential, no review, no per-member connection, no tenancy. Costs roughly a day and is
  wrong only in being manual.
- **C2 — read it live.** `ads_read` on each member's account. Note the permission: reading
  needs `ads_read`, and `ads_management` is the superset that can *mutate*. You are not
  mutating anything, so this is a materially smaller ask than the rest of this ADR assumes.
  But it is still App Review plus Business Verification plus a connection flow per member.

### The answer, as options

- **0-A. A + B only.** Content and attribution. **No Meta integration whatsoever.** Efficacy is
  the member's own job in Meta's UI. Simplest thing that could possibly work.
- **0-B. A + B + C1.** Add member-supplied exports so the site can show outcome *and* cost
  together. Still no credential, no review, no tenancy. *(Recommended as the first target — it
  delivers the stated value and buys the option on C2 without spending it.)*
- **0-C. A + B + C2.** Live reads. Everything below becomes live, and the calendar starts now.
- **0-D. The full surface** — create, target, test, measure. What this ADR originally assumed.

**If the answer is 0-A or 0-B, Questions 1 and 2 below do not need answering yet** — they are
about a targeting vocabulary nothing would call. Q0-b would also fall away.

---

## Question 0b — If a credential is needed, whose?

**Only reachable if Q0 is 0-C or 0-D.** Three tenancies, and the middle one is the surprise —
it shares a credential with the first and a beneficiary with the third, and is neither.

| | **First-party** | **Brokered for a member** | **On behalf of a member** |
|---|---|---|---|
| Whose ad account | the platform's own | **the platform's own** | the member's |
| Who pays Meta | you | **you** | they do |
| Who is billed | nobody | **the member, cost + markup** | nobody |
| Credential | System User on your business | **the same one** | Facebook Login for Business |
| Set up by | you, once | you — nothing for the member to do | the member, by clicking Connect |
| **Needs App Review** | **no** | **no** | **yes** |
| Fails by | 90 days inactivity → `Needs-Heartbeat-By` | same | member revokes → `Needs-Human-Reauth` |

**The calendar, not the code, is the constraint on the third column.** App Review wants at
least one successful call per permission in the **30 days before submitting**, plus **Business
Verification** as a separate process, plus about a week for a decision. First-party is
therefore a *prerequisite* of on-behalf-of rather than a warm-up. That is calendar time that
cannot be compressed, and it only starts once something is calling the API.

**One decision here is irreversible and the rest are not.** If brokered is ever wanted, spend
must be attributable **at creation time** — no network reports retroactively which member a
campaign belonged to, and campaigns that already ran cannot be relabelled at any price.

**One product decision hiding as a technical one:** brokered pools risk. A member's policy
violation lands on *your* ad account, and a restriction takes down **every brokered member at
once**. First-party risk is your own conduct; brokered risk is everyone's, pooled.

### The answer, as options

- **0b-A. First-party only** — the platform advertises itself. No review.
- **0b-B. First-party + brokered** — members advertise on your account, billed back. Still no
  review; requires the attribution decision above, permanently.
- **0b-C. First-party + on-behalf-of** — members connect their own accounts. Review + BV.
- **0b-D. All three.**

---

## Question 1 — How neutral is `Audience`?

> **Conditional on Q0.** This matters only if something builds or targets an audience — that
> is, only under 0-C or 0-D. Under 0-A or 0-B nothing calls a targeting API and this question
> can wait.

**What hangs on it:** whether `Audience` is a real typed vocabulary or mostly a typed carrier
for network-specific parameters; whether custom audiences are in scope at all; and whether the
escape hatch attaches to `Audience` alone or has to spread.

### A. Thin neutral skin + honest escape hatch *(recommended)*

> **Measured 2026-09-15, after this option was written, and it does not hold as stated.** An
> eight-platform survey (`../ads-protocol-design.md`) found that of *geo, age, language*, only
> **geo** ports — and only at country granularity. **Age fails hardest**: Reddit has no age
> targeting on the ad group at all, no two platforms share a bucket set, the floor is 13 on
> three networks and 18 on the rest, and no platform has a true age range (Google's integers
> are snapped to bucket edges). **Language** means three different things — a numeric platform
> id on Meta, a UI locale on LinkedIn, an ISO code elsewhere. The option is still open; its
> *core is thinner than this paragraph claims*, and age is the field a reader is most likely
> to assume is portable.

Neutral structure for only what every network genuinely has — **geo, age, language** — and
everything else in a typed network-specific carrier attached to `Audience`, named as such.

- A reader can see exactly where portability stops, because it has a type.
- Matches the note's own rule: *a leaky neutral name is worse than an honest escape hatch,
  because the first is only discovered by the second network.*
- Cost: a consuming app targeting anything beyond geo/age/language writes Meta-shaped values,
  and knows it is doing so.

### B. Rich neutral vocabulary

Model interests, behaviours, lookalikes and demographics as neutral types.

- Best portability **if** the abstraction holds.
- Risk: it is our vocabulary invented from one network. Every term is a guess about what a
  second network will call something, and the failure is silent until that network exists.

### C. `Audience` is mostly escape hatch

Accept that audience definition does not port. Neutral wrapper, network-specific contents,
no pretence.

- The note states plainly that **"most of it is network-shaped and will not port" is a
  legitimate answer** and belongs in the document as the escape hatch.
- Cost: a second network means real work, but honest work rather than a migration away from a
  wrong abstraction.

### 1b. Are custom audiences in scope?  **Yes / No / Later**

Custom audiences built from a **pixel** or an uploaded **customer list**.

**This is a privacy question, not an API one, and it should not pass as a technical detail.**
Those carry personal data. A neutral vocabulary for them is a surface through which a
consuming app hands customer records to an ad network — so the framework's shape here decides
what an app can do casually. "Later" is a real answer and costs nothing now.

### 1c. Are exclusions first-class?  **Yes / No**

Whether "don't show to these people" is part of the `Audience` type or lives in the escape
hatch. Cheap to say yes now; awkward to retrofit, because an exclusion is not a negated
inclusion in every network.

---

## Question 2 — Which half ships first?

**What hangs on it:** what #327's successor actually builds, and how soon a consuming app gets
something usable.

### A. Measure alone *(recommended — and the recommendation is not ours alone)*

Read spend and outcomes for campaigns **a human created in the network's own UI**. Create and
target are designed but unbuilt.

- Delivers value without write access, so the risky half ships when the vocabulary has been
  exercised against real data rather than before.
- Reading is where `Reading`-carries-its-timestamp earns its keep immediately.
- **Both the design note and the consuming app independently landed on this**, which is why
  it is recommended here — not because it is the smallest.

### B. #262's stated order: create → target → test → measure

The full surface in sequence.

- Honours the original ticket.
- But `target` is Question 1, so this order blocks on the answer that is hardest to get right,
  and does so before any real data has tested the vocabulary.

### C. Create + measure, targeting deferred

Create campaigns with minimal targeting, measure them, add targeting later.

- Middle path; usable sooner than B.
- Risk: creating an ad set *requires* an audience in practice, so "minimal targeting" may
  smuggle Question 1 in without deciding it.

---

---

## Recommendation — *Ouranos Claude (macOS), from the survey. Not the decision.*

Recorded because the maintainer asked for one after reading the measurements. Both questions
remain his; this says what the evidence would lead me to and what it would cost.

### Q1 — the neutral layer belongs on a different axis than A, B or C

A, B and C all argue about **how much targeting vocabulary is neutral**. The measured answer is
*almost none*: of the proposed core only geo ports, and only at country granularity.

But the survey found a genuine universal the three options do not mention, because it is not a
vocabulary — it is a **lifecycle**. On all seven ad platforms an audience is a *stateful
resource*: created separately, populated asynchronously, gated on a readiness status and a
minimum size, referenced by id, excluded by id. That is the most robust pattern in the survey.

So: **A-shaped in structure, C-shaped in content.**

- **`Audience` is a neutral resource with a neutral lifecycle** — identity, provenance
  (`CustomerList` · `Pixel` · `LookalikeFrom <seed>`), readiness state, size gate. Real,
  portable, worth typing properly.
- **Its definition is a typed network-specific payload.** Not a thin skin over the criteria —
  the payload *is* the criteria.
- **Country-level geo** is the one neutral criterion, because it is the only one that earned it.

Three additions that are in none of the three options:

1. **A delivery-mode discriminator is mandatory.** Four platforms turn the same fields from
   filters into hints and the switch always lives *outside* the targeting object. Without it,
   `Audience` means two different things on one network depending on a sibling field. This is a
   larger correctness problem than how many interest types get modelled.
2. **Age should be a type error, not a clamp.** It is the field a reader is most likely to
   assume ports. Snapping `22–27` onto buckets changes who sees the ad, silently.
3. **Lowering must be fallible.** LinkedIn's pairwise AND prohibitions and X's
   union-across-primary-types make most well-formed neutral trees inexpressible. A lowering that
   succeeds while changing the audience is worse than one that refuses.

### Q1b — custom audiences: **Later**, and the technical ease is the reason

Customer lists were the *most* portable pattern measured. That is the trap: the easiest thing to
build is the one carrying personal data, and "it is already universal" is the argument that will
make it feel free. It is not — Meta accepts 15 identifier keys, TikTok three, and silently
dropping name/address changes match rate, which is the entire point of the object. Defer it; if
it ever ships, a dropped key is a refusal.

### Q1c — exclusions: **first-class for audiences only**

Exactly where the measurement supports it. TikTok can exclude audiences and nothing else. Every
other exclusion goes in the escape hatch, because a uniform `Not` is unrepresentable on roughly
half the platforms.

### Q2 — **A, measure alone**, for a better reason than the original one

The note's argument was prudence: spend is real money. Still true, and now the weaker case.

- **Readings port; targeting does not.** The read surface is where a neutral vocabulary actually
  works, so this builds the half the evidence supports and defers the half it undermines.
- **Read-only scopes exist on six of eight**, making this cheaper in fact rather than only in
  caution. The exceptions — X and Snapchat — have no read-only tier at all, which is worth
  knowing *before* either is chosen.

Independent of the decision: **TikTok's developer registration is calendar-bound and blocks
nothing, so it should start whenever TikTok becomes plausible.** Five to six business days of
staff review, and it bars individual developers outright — a company-domain email and a matching
public website are required. Meta is ~0 days to a first call.

And for whenever the create half arrives: sandboxes are worst exactly at the audience surface,
so audience creation will need live accounts.

## Shape: one protocol, per-tool vocabularies, two surfaces

The maintainer's instinct on reading the survey was that each marketing tool may need its own
vocabulary, and that the shape has to be polymorphic in Coalton *and* in CL for consumers not
using Coalton. The measurement supports that, with one boundary worth drawing explicitly.

**Generalize the operations and the lifecycle. Do not generalize the vocabulary.** The platforms
agreed on what an audience *is* and disagreed on everything it *contains*. A per-tool vocabulary
behind a shared protocol is not a concession — it is the shape the evidence actually has.

**But the protocol has a boundary, and Instantly is where it falls.** Even the lifecycle thins
out there: a lead list is a bag of rows with no readiness gate and no size threshold, and four
of the eight nouns break. That is the second category, not a difficult member of the first. The
useful test for any future tool is not "can we map its fields" but **"does an audience have a
lifecycle here, and does delivery cost money per event"** — two questions that separate paid
media from outbound messaging cleanly, and would have classified Instantly correctly before any
field-mapping was attempted.

**Two surfaces, and the tree already has both idioms:**

- **Coalton** — a typeclass over each network's own payload type, following
  `mnemosyne/src/entity.lisp`'s `(define-class (DTO :a) ...)`: methods that *decide* and
  *render*, returning a `Result`-shaped ADT so a refusal is a value rather than a condition. No
  IO, so lowering produces a description of a request, never a request.
- **CL** — CLOS generic functions dispatching on a provider, following
  `hermes/src/protocol.lisp`'s `(defgeneric deliver (provider message))`. This is not merely a
  courtesy for CL users: a typeclass-constrained Coalton function **needs a monomorphic wrapper
  to be callable from CL at all**, so the parallel surface is forced by the language boundary
  rather than chosen.

**The hazard to design against is the two surfaces drifting.** The CL protocol should *call* the
typed core for every decision — validation, lowering, refusal — rather than reimplementing any
of it. Two implementations of one rule disagree in the dark, and here the consumer that notices
is a live campaign spending money. (The same failure was found and removed in #335, where a path
resolver existed twice; ADR-0014's *"there is nothing here that can disagree with the resolver"*
holds only while there is one.)

## Decision

*To be recorded when answered.* Format: **Q0 = _, Q0b = _, Q1 = _, Q1b = _, Q1c = _, Q2 = _.**

**Answer Q0 first.** If it is 0-A or 0-B, record that and stop — the rest is about an API
nothing would call yet, and leaving it open is more honest than answering it hypothetically.

## Consequences

*To be recorded with the decision.* The shape is predictable: Q1 decides how much of
`Audience` is typed and where the escape hatch attaches; Q1b decides whether a privacy surface
exists at all; Q2 decides whether the first shipped code writes to a network or only reads
from one.

## Alternatives considered

The alternatives **are** the lettered options above — this ADR is a decision not yet taken,
so they are listed in place rather than after the fact. Rejected outright and not offered:
inventing a neutral audience taxonomy **without** an escape hatch, which is the leaky-neutral
failure the note names; and building a Meta backend before the protocol, since new channels
are new backends, not new APIs.

## Provenance

The design note was written before any code, by a lane working with the consuming app, and its
most useful output was **not** a recommendation: it was the refusal to invent a taxonomy for
`Audience` and the decision to name that refusal as an open question rather than resolve it
quietly. A neutral-looking vocabulary invented from one network is the failure that is only
discovered by the second one, and by then it is in every consumer's code.

**Amended 2026-09-15** by Ouranos Claude (macOS, home machine): an eight-platform survey at
the maintainer's request, then a recommendation at his request after reading it. The survey is
the substantive part and it **corrected this ADR's own option A** — "geo, age, language" was
written as the set every network has, and only geo is. That correction matters more than the
recommendation, because the option was going to be chosen against a premise nobody had measured.

The recommendation is recorded as a recommendation. The `Decision` section above is still empty
and stays that way until the maintainer fills it.

Two process notes worth keeping, because they are why this file exists:

- The questions sat in `Todo`, unassigned, for a day — looking like available work rather than
  blocked work — because the block was recorded in session messages instead of on the issue.
  A block that is not written down is not a block; it is a gap nobody can see.
- They were then spread across three places, so answering them began with finding them. The
  maintainer said so directly. Collecting a pending decision into one answerable document is
  itself part of making the decision possible — a question that is expensive to locate is a
  question that stays open.
