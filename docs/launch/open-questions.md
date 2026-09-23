# Open questions — triage, merge, sequence

*An agenda for the dedicated decision time, not a backlog. Built 2026-07-29 from the 50
open issues labelled `design` or `research`.*

The instinct is to sit down and start answering 50 questions. Don't. **Three cheap passes
shrink the list before any real deciding happens**, and each pass is faster than answering
even one question properly:

1. **Strike** — some are already answered, or implemented and never closed.
2. **Merge** — several are one question asked in three frameworks.
3. **Sequence** — they are not independent, and one framework gates most of the others.

Only what survives all three needs your dedicated time.

---

## Pass 1 — Strike: which of these are actually still open?

The tracker is not ground truth. Work has landed ahead of the issue text more than once,
and **a stale-open question is worse than a known-open one** — it inflates the backlog,
hides the real work, and makes the project look less finished than it is (which matters
directly for the launch).

### Provable — referenced by a commit, still open

| Issue | Evidence |
|---|---|
| pre-publication issue 1 aion/log adoption across frameworks | `26ce870 feat(logging): adopt aion/log across hyperion, mnemosyne, praxeon (#1)` |
| pre-publication issue 3 App-owned migration convention | `db1ccae docs: the app-owned migration convention (#3)` |
| pre-publication issue 83 First-run DB bring-up | `728b69d feat(hyperion/examples): demonstrate first-run DB bring-up patterns (#83)` |

### Strong candidates — the code exists, the issue reads as unstarted

| Issue | What is already there |
|---|---|
| [#36](https://github.com/codelisperer/ouranos/issues/36) Headless Coalton eval + type introspection (`epic+design+research`) | `cons/src/coalton-repl.lisp` — sessions, `eval-input`, expression-vs-definition, inferred types. The engine is **built**. |
| [#43](https://github.com/codelisperer/ouranos/issues/43) Studio surface + CL-native desktop | The desktop half is **done** — ADR-0008/0010, `hyperion/src/desktop.lisp`, `hyperion-view/`, NSIS installers, `desktop-release.yml`. Only *Studio* remains. |
| [#63](https://github.com/codelisperer/ouranos/issues/63) Praxeon "Studio" DX | The issue body itself lists what has shipped: `studio.lisp`, `praxeon/event`, `praxeon/web`. Four checkboxes remain out of a large scope. |
| [#33](https://github.com/codelisperer/ouranos/issues/33) Task runner over ASDF via `cons.lisp` | Every framework ships a `cons.lisp` spec and `cons <target>` drives it. |
| [#39](https://github.com/codelisperer/ouranos/issues/39) Hot-reload dev loop | `hyperion/src/dev.lisp`, and the poller has been through at least two fix commits. |
| [#40](https://github.com/codelisperer/ouranos/issues/40) All client JS via Parenscript | `hyperion/src/js.lisp`; the coalton-repl app is written this way. |
| [#72](https://github.com/codelisperer/ouranos/issues/72) Per-OS installers | Windows NSIS exists (`scripts/installers/windows.nsi`, WebView2 bootstrapper). `.dmg`/AppImage unclear — likely *partial*, not done. |
| pre-publication issue 64 Typesafe HTMX "spun out to its own web-framework repo" | Reads as a pre-monorepo artifact. Hyperion **is** the spun-out web framework. Probably strike-or-merge into [#38](https://github.com/codelisperer/ouranos/issues/38). |
| pre-publication issue 12 Typed CEG ADT | Done on `work/elenchon-design`; closes on merge. |
| [#23](https://github.com/codelisperer/ouranos/issues/23) Lazy-seq, **Monoid**, itertools | The `Monoid` third was never a real gap — Coalton has it. Already corrected in-issue. |

### ✅ Pass 1 was run on 2026-07-29 — and it found something about triage itself

**Closed (4):** pre-publication issue 1 ·
pre-publication issue 3 ·
pre-publication issue 83 ·
pre-publication issue 64 (stale framing; its four design items
moved verbatim into [#38](https://github.com/codelisperer/ouranos/issues/38), where they
belong — Hyperion *is* the "spun out web framework" the title imagined).

**Trimmed (7)** with an explicit STATUS block so the tracker stops overstating remaining work:
[#23](https://github.com/codelisperer/ouranos/issues/23) ·
[#33](https://github.com/codelisperer/ouranos/issues/33) ·
[#36](https://github.com/codelisperer/ouranos/issues/36) ·
[#43](https://github.com/codelisperer/ouranos/issues/43) ·
[#63](https://github.com/codelisperer/ouranos/issues/63) ·
[#72](https://github.com/codelisperer/ouranos/issues/72) ·
[#83](https://github.com/codelisperer/ouranos/issues/83).

**The lesson, which is worth more than the cleanup:** the list above predicted *eight* closes.
Only four survived checking, because **"the code exists" is not the same as "the issue is
done."** #33, #39, and #40 all have working implementations and real unchecked scope
remaining — #39's file-notify item is a genuine gap that #84 (libuv) would fill. Closing
them on filename evidence would have destroyed real backlog.

So the rule for future passes: **read the checklist, not the source tree.** An issue with no
checklist and a commit naming it is closable; an issue with five unchecked boxes and some
shipped code is a *trim*.

> A cheap standing fix: put `Closes #N` in commit messages. Every issue closed above would
> have closed itself.

---

## Pass 2 — Merge: one question, asked in three frameworks

These are not duplicates to delete — they are **single decisions currently scheduled to be
made three times, inconsistently.** Merging them is the highest-leverage thing on this
page, because each merge converts N shallow framework-local answers into one deep
ecosystem answer.

### Cluster A — "AI-friendliness" · **this is the value proposition**

[#25](https://github.com/codelisperer/ouranos/issues/25) (aion) ·
[#31](https://github.com/codelisperer/ouranos/issues/31) (elenchon, the second half) ·
[#70](https://github.com/codelisperer/ouranos/issues/70) (praxeon) ·
[#42](https://github.com/codelisperer/ouranos/issues/42) (hyperion, partly)

Four frameworks each independently planning "keep the docs LLM-consumable." Meanwhile the
README's central claim is that **it is AI's turn to put CL back on the map** — this *is*
the differentiator, and it is currently the most fragmented thing in the tree.

Praxeon's [#70](https://github.com/codelisperer/ouranos/issues/70) is much the most
developed thinking (one vocabulary enforced across names/docstrings/skills; docstrings
stating contracts; executable examples as the real spec; skills changing in the same
commit as the API). **That should be promoted to an ecosystem standard**, not left as one
framework's plan.

→ **One decision: what makes an Ouranos framework LLM-consumable?** Then apply it
per-framework as mechanical work. Highest launch leverage of anything on this page.

### Cluster B — Bitemporality, designed twice

[#54](https://github.com/codelisperer/ouranos/issues/54) (mnemosyne: valid-time /
transaction-time API) · [#60](https://github.com/codelisperer/ouranos/issues/60) (praxeon:
Kairos, "the bitemporal context engine")

Kairos's own issue says the `valid-time`/`tx-time` stamps already in `context.lisp` are
"the seed of a bitemporal knowledge graph." mnemosyne #54 is designing exactly those two
axes for persistence. **Two independent bitemporal models in one ecosystem is a genuine
architectural risk** — and an avoidable one, since praxeon sits to the *right* of
mnemosyne in the DAG and can simply consume its model.

→ **One decision: the ecosystem's bitemporal model**, in mnemosyne, with Kairos as its
first consumer. Do not let these diverge.

### Cluster C — Two products called "Studio"

[#43](https://github.com/codelisperer/ouranos/issues/43) (hyperion: live component
editing, render preview, hot-reload control) ·
[#63](https://github.com/codelisperer/ouranos/issues/63) (praxeon: agent inspection,
memory config, workflow visualization)

These are **different products sharing a name**, which is its own decision. Either they
unify onto one surface (they both want a live-image inspector over a web UI — praxeon's is
already built and could host hyperion's) or one gets renamed. Shipping two things called
Studio would be a documentation problem forever.

→ **One decision: is Studio one surface or two?**

### Cluster D — The pure-CL face, as a house convention

[#19](https://github.com/codelisperer/ouranos/issues/19) (aion) ·
[#30](https://github.com/codelisperer/ouranos/issues/30) (elenchon)

Both are "expose the typed core to CL users who never touch Coalton." That is a
*convention*, not two designs — and `docs/coalton-patterns.md` §5 already carries half of
it (CL-facing constructors, total accessors, monomorphic wrappers for constrained
functions).

→ **One decision: the house pattern for a pure-CL face**, written once in the patterns
doc, then applied per framework.

**Merging these four clusters turns ~11 issues into 4 decisions.**

---

## Pass 3 — Sequence: mnemosyne is the critical path

After striking and merging, what remains is not a flat list. **Mnemosyne gates most of the
tree, and it is the least-settled framework** — six open research questions
([#52](https://github.com/codelisperer/ouranos/issues/52)–[#57](https://github.com/codelisperer/ouranos/issues/57))
plus two on migrations ([#49](https://github.com/codelisperer/ouranos/issues/49),
[#51](https://github.com/codelisperer/ouranos/issues/51)).

Everything downstream waits on it:

- **All three websites** need a CMS, which needs persistence.
- **Auth** for the consuming app.
- **Kairos** (via cluster B).
- **The case studies** — and this is the part that matters most for the launch, below.

Within mnemosyne there is an internal order, and getting it wrong means redesigning:

```
#42 backend protocol shape          ← foundational; the DSL, bitemporal API,
      │                                and migrations all bind to it
      ├── #41 query-DSL surface (Coalton-typed vs CL macro)
      ├── #43 bitemporal API  ────────→ unblocks Kairos (#56)
      └── #44 migrations end-to-end ── #40 specs-as-data · #38 bitemporal-aware
#45 entity/stamping pattern         ← partly settled in practice (mnemosyne/id, entity.lisp)
#46 EDN interop for XTDB 2          ← DEFER. XTDB 2 is a later adapter by design.
```

**Also triage mnemosyne itself.** It is labelled "scaffold," but it has DDL-as-data, a
CL-DBI connection shell over the typed backend, PG-wire + SQLite, and hyperion already has
`auth-db.lisp` and `session-db.lisp` written against it. Several of its six "research"
questions may be substantially answered in code already — pass 1 applies here more than
anywhere.

---

## Criticality for go-live, and who should take it

*Added 2026-07-29. "Go-live" here means **you can point a dev community at the repo without
embarrassment** — not "the software is done." Measured against the release-scope
recommendation: public, honestly badged, thesis-first, with the desktop Coalton REPL as the
artifact people actually try.*

Instances: **win** (Windows proper — NSIS, WebView2, cross-platform verification) ·
**linux** (native amd64, AppImage, anything Linux-only) · **mac** (design, docs, Coalton
typed-core, arm64, `.dmg`) · **any** (no platform dependency).

> **Updated 2026-08-02.** `win` originally read "Windows/WSL". WSL now runs its **own**
> instance with a native clone, so WSL work belongs to **linux** — leaving `win` claiming it
> is how the same Linux leg gets done twice.

### P0 — blocks go-live

| # | Issue | Who | Client |
|---|---|---|---|
| pre-publication issue 85 | LICENSE files — no LICENSE means all-rights-reserved regardless of `.asd` metadata | any | |
| pre-publication issue 90 | Confidentiality sweep — must precede the visibility flip; commits and issues can't be redacted after | mac | **yes** |
| pre-publication issue 91 | Settle release scope — **maintainer**, not an AI task; everything sequences off it | — | |
| pre-publication issue 86 | aion's "Coalton-first" claim — the first thing a skeptic checks, on the framework carrying the differentiator | mac | |
| pre-publication issue 89 | Repo description + maturity badges — the description is still a placeholder naming only Hyperion | any | |
| pre-publication issue 84 | coalton-repl input box scrolls away — trivial, except it is a visible bug *in the launch artifact* | any | |

Four of six are hours of work.

### P1 — shapes the first impression

| # | Issue | Who |
|---|---|---|
| [81](https://github.com/codelisperer/ouranos/issues/81) | AI-friendliness standard — **the value prop**; wants deciding before the release | mac |
| pre-publication issue 109 | Collaboration teachable — the other half of the pitch; `working-with-ai.md` mostly does it | any |
| pre-publication issue 87 | CI matrix — the evidence for "works everywhere", and the only native-amd64 gate | linux |
| pre-publication issue 88 | Clean-machine bootstrap — the first command anyone runs | all three |
| [72](https://github.com/codelisperer/ouranos/issues/72) | `.dmg` + AppImage — people must be able to install the demo | mac / linux |
| pre-publication issue 102 | Triage — visitors read the tracker | mac |
| [74](https://github.com/codelisperer/ouranos/issues/74) · [75](https://github.com/codelisperer/ouranos/issues/75) | Demo polish: window icon; REPL sees the invoking project | win / any |
| pre-publication issue 98 | Release-mode builds — needed the moment you make a performance claim, and after the 44 ms find you will | any |
| [78](https://github.com/codelisperer/ouranos/issues/78) | Native/FFI bundling — **downgraded by ADR-0011** (libev dropped); verify before treating as P1 | linux + win |
| pre-publication issue 101 | Register codelisperer.org — gates the site, not the announcement | maintainer |

### P2 / P3

Everything else is post-announcement. Strategically important within P2 but *not*
launch-blocking: [#53](https://github.com/codelisperer/ouranos/issues/53) (mnemosyne backend
protocol — the critical path for auth, Kairos, and the company site) and
pre-publication issue 95 (CSPRNG — a real security defect).

**Park explicitly, with a note in the issue:**
[#44](https://github.com/codelisperer/ouranos/issues/44) ·
[#47](https://github.com/codelisperer/ouranos/issues/47) ·
[#41](https://github.com/codelisperer/ouranos/issues/41) ·
[#57](https://github.com/codelisperer/ouranos/issues/57) ·
[#34](https://github.com/codelisperer/ouranos/issues/34)/[#35](https://github.com/codelisperer/ouranos/issues/35) ·
pre-publication issue 47–[#58](https://github.com/codelisperer/ouranos/issues/58) (payments — nothing is being sold) ·
[#85](https://github.com/codelisperer/ouranos/issues/85) (YottaDB — premature before #53) ·
[#84](https://github.com/codelisperer/ouranos/issues/84) (libuv — decide *after* the release).

### The client-app column is thinner than expected

Only pre-publication issue 83 was genuinely app-filed and
open, and it is now closed. The app's real historical needs — RTL i18n, static caching,
`db-repl`, the hot-reload log flood — are **all already closed**. Its live dependencies are
mnemosyne persistence and auth, both P2. **Client work is not competing with go-live**, which
is better news than the backlog's shape suggests.

## The sessions

Sequenced so each one unblocks the next. Times are for focused work, not calendar.

| # | Session | Output | Why here |
|---|---|---|---|
| **1** | **Triage** (pass 1) — half a day | ~15 issues closed or trimmed | Everything downstream is cheaper against an honest list |
| **2** | **AI-friendliness standard** (cluster A) — one sitting | An ecosystem doc; #25/#31/#70/#42 become mechanical | It is the value prop, and the launch needs it before code |
| **3** | **Mnemosyne #53 → #52 → #54** — the big one, two or three sittings | ADRs; unblocks Kairos, the CMS, auth, the case studies | The critical path. Nothing else here is as blocking |
| **4** | **Bitemporal + Studio + CL-face** (clusters B, C, D) — one sitting | Three decisions, two of them mostly implied by session 3 | Cheap once #54 is settled |
| **5** | **Release scope** (pre-publication issue 91) — one sitting | The decision, into the ECOSYSTEM.md log | Wants sessions 1–2 done so it decides against reality |

**Explicitly deferred, and say so in the issues** — payments
(pre-publication issue 48–[#58](https://github.com/codelisperer/ouranos/issues/58),
nothing is being sold yet), native reach to TypeScript/Dart
([#44](https://github.com/codelisperer/ouranos/issues/44)), mobile
([#47](https://github.com/codelisperer/ouranos/issues/47)), the CSS DSL
([#41](https://github.com/codelisperer/ouranos/issues/41)), cons distribution
([#34](https://github.com/codelisperer/ouranos/issues/34),
[#35](https://github.com/codelisperer/ouranos/issues/35)), EDN interop
([#57](https://github.com/codelisperer/ouranos/issues/57)). A deferred question you have
*decided* to defer costs nothing; an open one you keep re-reading costs every time.

---

## The uncomfortable part: the case studies

You want a release that "deserves to go viral, with case studies and everything." Held
against what actually exists, **the case-study story is the thinnest part of the launch**,
and it is worth saying plainly before the effort goes elsewhere.

What is genuinely showable today:

| Candidate | State | Verdict |
|---|---|---|
| **Native desktop Coalton REPL** | Built, runs, installs | **Ready.** Typed REPL in an OS webview, no Electron, ~30–50 MB. The most legible proof of the thesis in the tree |
| Hyperion i18n + RTL, static caching, interceptors | Shipped | Features, not case studies |
| **Elise** (praxeon) | Partly working | Delicate — clinical demoware needs prominent disclaimers, and "AI therapist" is a fraught frame for a launch |
| **ChatRBT** (elenchon's motivating demo) | Engine not built | The best *story* in the tree and currently unavailable |
| The real production app | Working | **Cannot be named** — confidentiality |
| **codelisperer.org + the CMS engine** | Not built, **not blocked** | See [`sites-and-cms.md`](sites-and-cms.md) — a git-backed content model takes it off mnemosyne's critical path |

That is **one ready case study**, not a portfolio. Three consequences worth accepting
early:

1. **One outstanding demo beats five adequate ones.** Virality is not additive — nobody
   shares a framework because it had a fifth example. Put the effort into making the
   desktop REPL undeniable (a 30-second video, a one-click installer per OS, a page that
   sells what just happened) rather than into breadth.
2. **The second case study is the CMS engine behind codelisperer.org** — a real,
   non-trivial, MIT-licensed hyperion application whose source a skeptic can read, and one
   you have to build anyway. Worth more than any contrived example.
3. **And it does not have to wait for mnemosyne.** The natural assumption is that a CMS
   needs a database, which would put case study two behind the six persistence questions.
   [`sites-and-cms.md`](sites-and-cms.md) argues the content model should be **git-backed
   markdown loaded into the live image**, not a database — read-mostly, single-author,
   already-versioned content wants git, and a database would reimplement it worse. That
   decision **takes the site off the critical path entirely**, and lets the launch's
   second case study proceed in parallel with session 3 instead of behind it.

So mnemosyne remains the critical path — for auth, for Kairos, for the company site — but
**not for the launch narrative.** That decoupling is worth more than it looks: it is the
difference between one blocked sequence and two independent ones.

The honest sequence: **triage → value prop → (mnemosyne ‖ the CMS as case study two) →
launch.** Not: launch, then discover the case studies were thin.
