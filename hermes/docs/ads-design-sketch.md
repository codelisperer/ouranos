# Ads: a design sketch — where the framework stops and the app begins

**Status:** Sketch, 2026-09-15. Proposed against the survey in
[`ads-protocol-design.md`](ads-protocol-design.md) and the recommendation in
[ADR-0003](adr/0003-ads-audience-neutrality-and-first-deliverable.md). **No code exists.** The
ADR's `Decision` is still empty, and this sketch presumes its recommendation; if Q1 is answered
differently the vocabulary layer changes and the operational layer mostly does not, which is
the main reason the two are separated here.

## The question this answers first

Not "what types do we write" but **which of them does the framework get to own**. The survey
answers it with one measured fact, and the rest follows from it:

> **Targeting values are live lookups, not data.** Every platform hands interests, geos,
> postcodes and behaviours out of a search endpoint, keyed to the account, and the available
> set varies by region — Snapchat returns **33 targeting dimensions for the US and 24 for
> Germany**, each carrying a `deprecated` flag. TikTok's `location_ids` are opaque ids whose
> namespace its own documentation never names.

A framework cannot hold those. They are not stable, not global, and not knowable at the time
this library is compiled. **So the app supplies the values.**

What a framework *can* hold, and what an app should not have to rediscover, is the **grammar**
and the **rules**: that Meta's include is an AND-of-ORs while TikTok's is a flat conjunction,
that TikTok forbids overlapping geography, that LinkedIn may not AND industries with employers,
that an age range must snap to buckets and snapping changes who sees the ad. Those are stable
facts about a platform, and getting one wrong **silently changes the audience** — which is
exactly the class of error an app should not be left to discover.

| | Framework (`hermes/ads`) | Consuming app |
|---|---|---|
| Audience **lifecycle** — states, readiness, size gates | ✅ owns | — |
| **Readings** — figure + window + as-of | ✅ owns | — |
| **Credential state**, refresh, re-consent as a state | ✅ owns | supplies the secret |
| Per-network **grammar** (the shape of a valid spec) | ✅ owns | — |
| Per-network **constraints** (the refusals) | ✅ owns, and exposes individually | may add its own |
| Transport, auth, pagination, rate limits, error → condition | ✅ owns | — |
| **Which values** — interest ids, geo ids, audience ids | ✗ cannot | ✅ owns, at runtime |
| **Which audience for which campaign** | ✗ cannot | ✅ owns, at creation time |
| Fields the framework has not modelled yet | carries them, **named as unmodelled** | ✅ supplies |
| Budget, approval, who may spend | ✗ not its call | ✅ owns |

**The taxonomy endpoints are the seam.** The framework makes the lookup call; the app decides
what to search for and what to keep. The framework never vendors a taxonomy, because a
vendored taxonomy is stale the week after it ships and wrong in half the regions on the day.

---

## Layer 1 — operational semantics (shared, closed, the same on every network)

This is the layer the survey says actually ports. It is closed on purpose: these are facts
about how ad platforms *behave*, and an app wanting a new targeting field must not need a new
release of this.

```lisp
(coalton-toplevel
  ;;; --- an audience is a RESOURCE WITH A LIFECYCLE. This is the finding. -------
  (define-type Audience-Id   (Audience-Id String))
  (define-type Seed-Id       (Seed-Id String))

  (define-type Origin
    "How an audience came to exist. The three that ported."
    (Uploaded-List (List Identifier-Kind))
    (Pixel-Rule String Integer)        ; rule reference, retention in days
    (Modelled-From Seed-Id))           ; breadth is NOT here -- see below

  (define-type Identifier-Kind
    "Only the three every platform accepts. Meta takes fifteen; those live in the
network layer, so a neutral list CANNOT silently carry name or address and lose them."
    Email-Hash Phone-Hash Device-Ad-Id)

  (define-type Readiness
    "Populating is not a boolean and Too-Few is not an error -- both are ordinary
states an app renders. The minimum differs per network (LinkedIn 300, Reddit 1000,
Google ~5000) so it is carried, not assumed."
    Unpopulated
    Populating
    (Usable Integer)
    (Too-Few Integer Integer)          ; matched, minimum required
    (Rejected String))

  ;;; --- the discriminator four platforms hide outside the targeting object -----
  (define-type Relaxable
    Relax-Age Relax-Gender Relax-Interests Relax-Audiences Relax-Geography)

  (define-type Mode
    "EXACT means the values are constraints. WIDENED names precisely which of them the
network may ignore -- Meta relaxes demographics, TikTok explicitly does not, Snapchat
relaxes gender and the age ceiling. One boolean `expansion' flag would make these the
same thing, and they are not."
    Exact
    (Widened (List Relaxable)))

  ;;; --- readings: never a bare number -----------------------------------------
  (define-type Figure
    (Impressions Integer) (Clicks Integer) (Conversions Integer) (Spent Money))

  (define-struct Reading
    (figure Figure)
    (covering Span)                    ; the window the figure is FOR
    (observed-at Instant))             ; when the network said it

  ;;; --- refusals are values, not conditions (the CL shell raises) --------------
  (define-type Refusal
    (Age-Would-Snap Integer Integer)          ; requested min, max
    (Identifier-Not-Carried Identifier-Kind)
    (Exclusion-Unsupported String)            ; the dimension
    (Geography-Overlaps String String)
    (Combination-Forbidden String)            ; LinkedIn's pairwise prohibitions
    (Unmodelled-Field-Collides String))

  (define-type Rendered
    "What WOULD be sent. Produced in the typed core, so the dry-run the note asks for
is not a feature -- it is the only thing the core can make. Nothing here does IO."
    (Rendered String)))
```

### Who the credential acts for is a type, not a setting

A platform running ads for its **members** and a platform running **its own** ads are two
credential relationships, not one with a flag. They differ in whose money is spent, how the
credential is obtained, how many exist, whether App Review gates them, and how they fail
(see [`ads-meta-setup.md`](ads-meta-setup.md)). A system user token reaches only assets its
own business owns and **cannot** touch a member's account, so the distinction is enforced by
the platform whether or not the code models it.

```lisp
(coalton-toplevel
  (define-type Member-Id (Member-Id String))

  ;; FIRST-PARTY spends our money; ON-BEHALF-OF spends theirs. A misconfigured provider that
  ;; confuses the two is not a bug that shows up in a test -- it shows up on a statement. It
  ;; is worth a constructor rather than a boolean, for the same reason the rest of this
  ;; vocabulary is: a reader cannot pass the wrong one by accident.
  (define-type Tenancy
    First-Party
    (On-Behalf-Of Member-Id)
    (Brokered-For Member-Id))

  ;; Two SEPARATE questions, because the three cases cut across them: brokered and
  ;; first-party share an account, brokered and on-behalf-of share a beneficiary. One
  ;; predicate would force them together and make brokered indistinguishable from whichever
  ;; case it was modelled after.
  (declare tenancy-uses-our-account? (Tenancy -> Boolean))
  (declare tenancy-beneficiary (Tenancy -> (Optional Member-Id)))

  ;; The label that must travel WITH the campaign, so spend can be split afterwards.
  (declare spend-attribution (Tenancy -> String)))
```

**`Brokered-For` is the case that is easy to miss and impossible to retrofit.** The ad account
is ours and the beneficiary is a member: we pay the network, the member pays us for cost plus a
markup. Billing that member for their share means knowing which spend was theirs, and **no
network will tell you retroactively** — the attribution has to be written into what is sent, at
creation time. Campaigns that already ran cannot be re-labelled at any price.

It also pools risk: a member's policy violation lands on **our** account, and a restriction
takes every brokered member down together. That is a product decision rather than a code one,
but the type is where it becomes visible instead of implicit.

**Who may construct a `First-Party` provider is the app's call, not the framework's** — the
maintainer's rule is superadmins only. The framework's job is to make the distinction
impossible to pass by accident; it cannot see a role and should not pretend to.

Every provider carries one. It is also the natural place to hang the things that differ by
relationship — a spend ceiling that means something different when the money is not yours, and
an approval step that a first-party campaign may not need.

Credential state is part of this layer because the survey made it a lifecycle question rather
than an ops detail:

```lisp
(coalton-toplevel
  (define-type Credential-State
    "LinkedIn has no machine-to-machine path and its refresh token does not roll
forward, so re-consent is a NORMAL STATE, not an error. Meta's system-user token is
the mirror: it never expires until 90 days of app silence kill it."
    (Active Instant)
    (Expiring-At Instant)
    (Needs-Human-Reauth String)
    (Needs-Heartbeat-By Instant)))
```

The two constructors at the bottom are not alternatives — they belong to the two tenancies.
**`Needs-Heartbeat-By` is first-party**: a system user token does not expire on a clock, but 90
days of app inactivity invalidates every token the app holds. **`Needs-Human-Reauth` is
on-behalf-of**: a member changes agency, leaves the business, or revokes access in their own
settings. That is an **ordinary state an app renders with a Connect button**, not a fault —
an integration that treats it as an exception logs it and serves a 500.

---

## Layer 2 — per-network grammar (framework-owned shape, app-supplied values)

Each network gets a type that encodes **its** structure. They are deliberately not alike;
that they cannot be unified is the survey's central result. Each is **parametric in its leaf**,
so the app's own term vocabulary is what fills it, and each carries an explicit `unmodelled`
carrier so a field the framework has not caught up with is still expressible — **named as
unmodelled rather than disguised as neutral.**

```lisp
(coalton-toplevel
  ;;; META -- an algebra: AND of ORs, with a negated OR-block, continuous age.
  (define-struct (Meta-Spec :leaf)
    (age-min Integer) (age-max Integer)        ; 13..65, genuinely continuous
    (countries (List String))                  ; ISO alpha-2 -- Meta takes real codes
    (locales (List Integer))                   ; NUMERIC platform ids, not ISO strings
    (include (List (List :leaf)))              ; outer AND, inner OR
    (exclude (List :leaf))                     ; a full OR-block, negated
    (excluded-geo (List String))
    (unmodelled (List (Tuple String String))))

  ;;; TIKTOK -- a flat conjunction. (A or B) and (C or D) is INEXPRESSIBLE.
  (define-type Tiktok-Age
    Tt-13-17 Tt-18-24 Tt-25-34 Tt-35-44 Tt-45-54 Tt-55-Plus)

  (define-struct (Tiktok-Spec :leaf)
    (location-ids (List String))               ; opaque ids; MUST NOT overlap
    (ages (List Tiktok-Age))
    (languages (List String))                  ; ISO-639-1 -- unlike Meta
    (terms (List :leaf))                       ; flat: interests, keywords, actions
    (audiences (List Audience-Id))
    (excluded-audiences (List Audience-Id))    ; the ONLY exclusion TikTok has
    (unmodelled (List (Tuple String String))))

  ;;; GOOGLE -- criteria are ROWS, not fields. Polarity is immutable at the API,
  ;;; and a row may merely OBSERVE rather than restrict.
  (define-type Polarity Targets Excludes)
  (define-type Role     Restricts Observes)    ; bid_only: an ADT, not a boolean

  (define-struct (Google-Row :leaf)
    (criterion :leaf) (polarity Polarity) (role Role))

  (define-struct (Google-Spec :leaf)
    (rows (List (Google-Row :leaf)))
    (unmodelled (List (Tuple String String))))

  ;;; LINKEDIN -- fixed-depth CNF keyed by facet URN, and EXCLUDE is a different
  ;;; shape from INCLUDE (one or-clause, never an and-list).
  (define-struct (Li-Or :leaf) (by-facet (List (Tuple String (List :leaf)))))

  (define-struct (Linkedin-Spec :leaf)
    (include (List (Li-Or :leaf)))             ; AND over these
    (exclude (Optional (Li-Or :leaf)))
    (unmodelled (List (Tuple String String))))

  ;;; X -- rows with a COMPARISON operator, not a negation flag. And the union
  ;;; semantics across primary types live in the lowering, not the shape.
  (define-type X-Op Op-Eq Op-Ne Op-Gte Op-Lt)

  (define-struct (X-Criterion :leaf) (kind String) (value :leaf) (op X-Op))

  (define-struct (X-Spec :leaf)
    (criteria (List (X-Criterion :leaf)))
    (age (Optional String))                    ; ONE bucket per line item, enum undocumented
    (unmodelled (List (Tuple String String))))

  ;;; REDDIT -- note what is ABSENT: there is no age field, because the ad group
  ;;; has none. Communities are targeted BY NAME, not by id.
  (define-type Reddit-Mode Manual Automated)   ; Automated re-reads the same JSON as seeds

  (define-struct (Reddit-Spec :leaf)
    (communities (List String))                ; names: "aww", not "t5_2qhta"
    (terms (List :leaf))
    (geolocations (List String))               ; five id grammars in one array
    (excluded-communities (List String))
    (mode Reddit-Mode)
    (unmodelled (List (Tuple String String))))

  ;;; SNAPCHAT -- per-element operation, and geos are REQUIRED: an unfiltered
  ;;; audience is not expressible at all.
  (define-type Snap-Op Snap-Include Snap-Exclude)

  (define-struct (Snap-Criterion :leaf)
    (category String) (ids (List :leaf)) (op Snap-Op))

  (define-struct (Snapchat-Spec :leaf)
    (geos (List String))                       ; REQUIRED, non-empty
    (criteria (List (Snap-Criterion :leaf)))
    (unmodelled (List (Tuple String String)))))
```

Read the differences as the argument: Meta has an algebra, TikTok a conjunction, Google rows,
LinkedIn keyed CNF, X comparison operators, Reddit an absence where age should be, Snapchat a
required field nobody else requires. **No single record covers these without lying about at
least four of them.**

---

## Layer 3 — the app's half

### Values, at creation time

The leaf is the app's. The framework ships a trivial default (an opaque taxonomy id) so the
common case needs nothing, and an app with richer needs supplies its own type:

```lisp
(coalton-toplevel
  (define-type Taxonomy-Id (Taxonomy-Id String))   ; the default leaf

  (define-class (Term :l)
    "A leaf an app can render. The framework never interprets one -- it cannot;
these come from live lookups keyed to the app's own ad account."
    (term-key (:l -> String))
    (term-value (:l -> String))))
```

An app that wants typed interests writes its own leaf type and one instance. Nothing in Layer 1
or 2 changes.

### Extensions, and the rule that keeps them honest

An app may also add a whole spec of its own — a network the framework does not cover, or a
shape it models differently:

```lisp
(coalton-toplevel
  (define-class (Spec :s)
    "Lower a targeting spec to what would be sent. Total in the type, fallible in the
value: a refusal is data the app can render, not a condition it must catch."
    (lower (:s * Mode -> (Result Refusal Rendered)))
    (relaxes (:s -> (List Relaxable)))))
```

**The constraints are exported as functions, not sealed inside the framework's own instances.**
This is the load-bearing detail. If refusals live only inside `lower` for `Meta-Spec`, then an
app that writes its own instance silently loses every one of them — and the failure is an
audience that differs from the one intended, which no test the app writes will catch.

```lisp
(coalton-toplevel
  (declare age-snaps-to-buckets ((List (Tuple Integer Integer)) * Integer * Integer
                                 -> (Result Refusal (List Integer))))
  (declare geography-must-not-overlap ((List String) -> (Result Refusal Unit)))
  (declare exclusion-must-be-audience-only ((List String) -> (Result Refusal Unit)))
  (declare facets-may-be-anded (String * String -> (Result Refusal Unit))))
```

An app's instance is expected to call these. The framework cannot force it — but it can make
the honest path the short one, and say plainly in the docstring what skipping them costs.

### The CL surface, which is forced rather than offered

A typeclass-constrained Coalton function **cannot be called from CL without a monomorphic
wrapper**, so the parallel surface is a consequence of the language boundary, not a courtesy.
It follows `hermes/src/protocol.lisp`'s existing `deliver` shape:

```lisp
(defgeneric render (provider spec mode)
  (:documentation "What WOULD be sent. Never sends. Signals ADS-REFUSED carrying the
typed REFUSAL when the spec cannot be lowered faithfully."))

(defgeneric submit (provider rendered))
(defgeneric create-audience (provider origin &key name))
(defgeneric audience-readiness (provider audience-id))
(defgeneric readings (provider subject span))
(defgeneric credential-state (provider))

(define-condition ads-refused (error)
  ((refusal :initarg :refusal :reader ads-refused-refusal)))   ; the Coalton value, carried
```

**The hazard is these two surfaces drifting**, and it is the same failure removed from
`build-desktop-app` in pre-publication issue 335, where one path resolver existed twice. The CL methods must *call*
the typed core for every decision rather than reimplement a rule; here the consumer that
notices a disagreement is a live campaign spending money. An app extending in CL writes a
`render` method that calls the exported constraint functions, exactly as a Coalton instance
would.

---

## Meta first — what that means concretely

Following ADR-0003's Q2 recommendation (measure alone), and the survey's finding that Meta is
~0 days to a first call while TikTok is 5–6 business days of review:

1. **`credential-state` + the heartbeat.** Meta's system-user token never expires *until* 90
   days of app inactivity kill it. Build the state before anything depends on it.
2. **`readings`.** The read half: `ads_read` scope only, no mutation capability in the
   credential at all. This is where the neutral vocabulary genuinely works.
3. **`render` for `Meta-Spec`, with the refusals.** Pure, testable with no network and no ad
   account — and it is the dry-run the note asks for, obtained for free rather than retrofitted.
4. **`create-audience` + `audience-readiness`.** Where the lifecycle types earn their keep.
5. **`submit` last**, behind a credential that had to be deliberately widened to
   `ads_management` — so the ability to spend is a separate, visible act.

A second network is what proves the design, and **TikTok is the right second** precisely
because it is the most structurally distant: flat conjunction, audience-only exclusion, bucketed
age. If the split survives TikTok it will survive the rest. Its developer registration is
calendar-bound and blocks nothing, so it can start whenever TikTok becomes plausible.

## What this sketch does not decide

- **ADR-0003's Q1 and Q2 remain open.** This presumes the recommendation; it is not the answer.
- **`Money` is assumed lifted** out of `hermes/payments` into a shared `hermes/money`, per the
  design note. `Spent` above depends on it.
- **`Span` and `Instant`** are named as if they exist in a shared place; they do not yet.
**What was checked:** the Coalton constructs this sketch leans on — a **parametric
`define-struct`**, a `define-class` with an instance, and a `declare` returning
`(Result Refusal Unit)` — were compiled at the pinned Coalton before this was written, because
a design doc proposing types that will not compile is a claim like any other. Two defects in
the sketch were found that way: a `declare` missing the parens around its function type, and a
struct field named `values`, which is the CL silent-collision hazard the house rules warn about.

- **Nothing here is validated against a live API.** The grammars come from documentation read
  once, on one day, for APIs that version fast — Google sunset developer tokens six days before
  the survey and two of its own pages still disagree about it. The *shapes* should hold; any
  specific field name deserves re-checking before code is written against it.
