# Docs review plan

*A test plan for reading the tree's documentation deliberately, bottom-up, before
publication. Built 2026-08-04. Resumable — tick as you go.*

**Surface:** 160 markdown files + 6 LaTeX papers. *(139 when this was written; see the
2026-08-24 update at the foot of this file, which adds a second lens — voice — and one
decision that has to be made before any reading is worth doing.)*

Reading 139 files "carefully" in one sitting is not a plan, so this is triaged, ordered,
and carries a pass criterion per tier. The mechanical checks are already done (below) so
your time goes on judgment rather than link-chasing.

---

## Already checked mechanically — no action needed

- **Dead relative links: zero.** All internal `](…)` targets across all 139 files resolve.
  Do not spend time clicking links.
- **Confidentiality in issues: clean.** All ~200 issue titles and bodies scanned for the
  four covered names — no hits. *(Issue **comments** and git history are separately covered
  by [#90](https://github.com/codelisperer/ouranos/issues/90), which decided to publish from
  a fresh commit precisely because history could not be cleaned.)*

## What you are looking for

Five failure modes. These are not invented — **each was hit in this tree this week**, which
is what makes them worth checking for rather than a generic checklist.

| # | Mode | Real instance |
|---|---|---|
| 1 | **False claim** | README said `scripts/setup.{sh,ps1}` was "planned" when it exists *and does more* — costing readers at a prerequisite a script already handled |
| 2 | **Dead pointer** | README said "see per-project `LICENSE`/headers"; there are none |
| 3 | **Drifted duplicate** | `Monoid` listed as a Coalton gap in *both* the gap analysis and `aion/paper` — struck from one, still false in the other |
| 4 | **Stale vs a decision** | `ECOSYSTEM.md` called mnemosyne a "scaffold" at 139 passing checks |
| 5 | **Overclaim** | any capability described in the present tense that is actually planned |

**When you find one:** fix it immediately if it is a sentence; open an issue if it is a
section. Do not batch — the batch never happens.

---

## Tier 1 — the first-impression set *(~1 hour; do this even if you do nothing else)*

Largest blast radius. A stranger forms their entire judgment here.

- [ ] `README.md` — **just rewritten**, so read it as a stranger rather than as its author
- [ ] `ECOSYSTEM.md` — the decisions log has grown a lot this week; is it still readable start to finish?
- [ ] `AGENTS.md` — every AI instance is held to this. Contradictions here propagate everywhere
- [ ] `CLAUDE.md` (root)
- [ ] `docs/getting-started.md` — **highest risk of mode 1**; it predates the setup.sh fix
- [ ] `docs/contributing.md`
- [ ] `docs/README.md`

## Tier 2 — per-framework, in DAG order *(bottom-up, as you asked)*

Read `<fw>/README.md` then `<fw>/CLAUDE.md` together — the CLAUDE files are **always loaded
by every AI session**, so an error there is an error in every future session.

- [ ] **aion** — 16 files. Check the "Coalton-first" framing now that `coalton-story.md` exists; and that `aion/uv` is represented
- [ ] **cons** — 7 files. `cons build|test|serve|run` is still partly aspirational; is that said plainly?
- [ ] **mnemosyne** — 12 files. Was called "scaffold" until today at 139 checks; look for the same understatement elsewhere
- [ ] **elenchon** — 14 files. Five ADRs landed this week; does the vision doc still read as open where it is now decided?
- [ ] **hyperion** — 33 files, the largest surface. 11 ADRs; ADR-0011's backend half is being overtaken by [#117](https://github.com/codelisperer/ouranos/issues/117)
- [ ] **praxeon** — 10 files
- [ ] **hermes** — 4 files

## Tier 3 — cross-cutting design docs

- [ ] `docs/coalton-patterns.md` — the canonical Coalton reference; §7–8 are new
- [ ] `docs/coalton-upstream.md` · `coalton.pin` · `libuv.pin` — three files naming versions ([#111](https://github.com/codelisperer/ouranos/issues/111) folds them into one)
- [ ] `docs/versioning-and-pinning.md` · `docs/dependencies.md`
- [ ] `docs/logging.md` · `docs/migrations.md`
- [ ] `docs/working-with-ai.md` — this is launch collateral now, not just an internal note

## Tier 4 — the papers *(6 files, and they need the most work)*

**Every paper predates this week's decisions** — last touched 21–26 July. Findings already
confirmed:

- [ ] **`aion/paper`** — states the gaps include "a `Monoid` class". **False; Coalton has it.** Verified mode 3
- [ ] **No paper mentions libuv at all** — the native substrate, the no-grovel decision, and Lisp driving a C compiler are the most distinctive technical work in the tree and appear in none of them
- [ ] **`hyperion/paper` is the thinnest at 382 words** — and hyperion is the most-built framework. That inversion is worth fixing before anyone reads them as a set
- [ ] `cons/paper` (454w) · `elenchon/paper` (706w) — elenchon's needs the five ADRs folded in
- [ ] `praxeon/paper` (1432w) · `mnemosyne/paper` (2646w, the most developed)
- [ ] **`hermes` has no paper.** Decide: write one, or say in `papers/README.md` that the satellite lib does not get one
- [ ] `papers/README.md` — the ecosystem thesis; does it still match `ECOSYSTEM.md`?

## Tier 5 — the wiki narrative and the launch docs

- [ ] `docs/wiki/Framework-*.md` (7) + `Home.md` — the design narrative; `Framework-Elenchon.md` was heavily revised this week
- [ ] `docs/launch/*` (6) — **read these skeptically.** They were written fast, by me, this week, and have had no second pass

---

## If you only have an hour

Tier 1, plus these three from elsewhere: `docs/getting-started.md` (highest mode-1 risk),
`aion/paper` (a known false claim), and `aion/CLAUDE.md` + `README.md` (the "Coalton-first"
framing, which is the claim a skeptical reader checks first).

## Why bottom-up is right

Higher frameworks assume lower concepts, so reading `aion → praxeon` means never
encountering a term before its definition. The counter-argument is that root-level docs have
the largest blast radius and should come first — hence Tier 1 sits above the DAG order
rather than inside it.

---

# Update — 2026-08-24: the voice pass, and one decision first

*The plan above is an **accuracy** pass: it hunts false claims, dead pointers, drifted
duplicates and overclaims. That work stands and is not repeated here. This adds the second
lens — **does it sound like the maintainer wrote it?** — and records what changed since
2026-08-04.*

## Tier 0 — decide this before reading anything

**Does `docs/launch/` ship?** These six files are tracked on `main`, and the public repo is
a `git archive` of the tracked tree, so they publish unless moved:

```
docs/launch/release-scope.md      docs/launch/open-questions.md
docs/launch/onboarding.md         docs/launch/sites-and-cms.md
docs/launch/docs-review-plan.md   docs/launch/README.md      <- this file
```

`release-scope.md` carries a section titled *"The credibility gap, stated plainly"*, a
framework-by-framework account of what does and does not work, and a frank discussion of
maintainer capacity alongside client work. It is good reasoning written **for the
maintainer**, not for a reader.

**DECIDED 2026-08-24 — they publish. The honesty is the point.**

A project that names its own credibility gaps is harder to dismiss than one that hides them,
and a reader who finds `release-scope.md` learns something true about how this is built. It
also puts the maintainer's own standard on the record: the same document that says *"none of
these is expensive to fix, all three are fatal to leave"* is the one a sceptic would have to
argue against.

So `docs/launch/` is **in scope for the voice pass**, and should be read as public writing
rather than as internal notes — see the reframe below.

## The voice pass — a different lens from the accuracy pass

Accuracy asks *is this true?* Voice asks *would I have written this?* They find different
defects and are best done as separate reads; trying to do both at once reliably produces a
thorough accuracy pass and no voice pass at all.

**What to look for.** Not typos — register. Prose that reads as competent-and-anonymous is
the failure mode, because the thesis here is partly a *position*, and a position delivered
in neutral documentation-voice stops being one.

- **Hedging that was not yours.** "It is generally recommended that…" where you would have
  said "do this, because X."
- **Symmetry that flattens a real preference.** Presenting two options evenhandedly when you
  have a view and the reader would benefit from it.
- **Borrowed idiom.** Phrasing that belongs to a different ecosystem's documentation culture
  and arrived by osmosis.
- **Explaining what you would assume.** Over-scaffolding for a reader who chose to open a
  Common Lisp metaframework.
- **A joke that is not yours,** or an absence of one where you would have made it.

### Reading order for voice

**Read the two blog posts first**, even though they are small and not strictly part of the
release surface:

- [ ] `docs/blogs/2026-07-29-bugs-that-only-exist-on-someone-elses-machine.md`
- [ ] `docs/blogs/2026-08-04-twenty-thousand-leagues-under-the-c.md`

They are the closest thing in the tree to your public writing voice, and they calibrate the
ear for everything after. Reviewing them last is the common mistake — by then the register
has already been set by whatever you happened to read first.

**Then, in descending order of how many readers see it:**

- [ ] The **GitHub repo description** — not a file; edit in repo settings. One sentence, and
      the first thing anyone reads. Rewritten 2026-08-24; confirm it is yours.
- [ ] `README.md` — **substantially changed 2026-08-24** (see below). The new *"What this
      release promises"* section is the highest-stakes prose in the tree: it is where the
      support posture is set, and a wrong register there either sounds defensive or sounds
      like it is promising more than it means to.
- [ ] `ECOSYSTEM.md` — the thesis and the decisions log
- [ ] `AGENTS.md` and the 13 `CLAUDE.md` files — **these publish, and they reveal how you
      work.** For an audience partly composed of people curious about AI-assisted
      engineering, they may be read more closely than the frameworks. They were written as
      internal instructions; read them once as a public artifact.
- [ ] `docs/wiki/Home.md`, `Getting-Started.md`, `Contributing.md`
- [ ] The 7 framework `README.md`s
- [ ] The 7 `docs/wiki/Framework-*.md` narratives — 300–600 lines each, the most
      voice-bearing prose after the README
- [ ] The 5 user guides (`hyperion`, `mnemosyne`, `praxeon`, `cons`, `docs/coalton-patterns.md`)

Everything else — ADRs, design docs, research notes — is long tail. Spot-check. Two worth a
closer look because outsiders are likely to link to them directly:
`hyperion/docs/adr/0014-macos-runtime-linked-libraries.md` (it solves a problem others have)
and `docs/dependencies.md` (a claim readers verify).

## What changed since 2026-08-04

- **#91 is decided.** Thesis-led, all seven frameworks public with honest per-framework
  maturity, explicitly not offering support, version `0.1.0`. Ship on description + badges;
  CI (#87) and clean-machine bootstrap (#88) follow rather than gate.
- **`README.md` rewritten in three places** — check counts (they were stale by ~4x: 594
  claimed against 2293 actual), the License section (per-framework `LICENSE` files now
  exist), and a new *"What this release promises"* section.
- **#85 closed.** All seven frameworks carry the MIT text their `.asd` always declared, and
  `publish-public.sh` now fails naming any framework that does not.
- **Failure mode 2 in the table above is fixed.** "See per-project `LICENSE`/headers; there
  are none" — there are now.
- **History is a non-issue, and not because it was cleaned.** `publish-public.sh` does
  `git archive HEAD` into a fresh `git init`, so the public repo has **one commit**. The 237
  commits carrying `Co-Authored-By` trailers and the ~12 naming a client are simply not
  published. Nothing to rewrite, nothing to miss.
- **The working tree is the only thing that ships**, so it is the only thing the
  confidentiality sweep has to cover. `scripts/publish-public.sh --check` passes, and it
  re-greps the *staged* content as belt-and-braces in case `.gitattributes` changed what
  landed.

## The reframe — `docs/launch/` should become a recurring surface, not a one-time artifact

Decided in principle 2026-08-24; **execute after `0.1.0` ships**, not before. Tracked as an
issue so it does not get lost.

The problem with the current shape is that "launch" is true exactly once. The day after
`0.1.0`, `release-scope.md` is a historical document sitting in a directory whose name claims
it is current — and the tree's most reliable failure mode is a document that stopped being
true without saying so.

Deleting it is the wrong fix. **The reasoning is the asset**, and every release asks the same
questions: what is in scope, what does it promise, what is blocking, and what is deliberately
*not* blocking. That shape recurs. So keep the practice and version it:

```
docs/releases/README.md         the charter -- what belongs here and what does not
docs/releases/0.1.0.md          this launch's scope, promise, and reasoning (frozen at ship)
docs/releases/0.2.0.md          the live one -- the only file anyone needs to read
```

**The charter matters more than the layout**, because without one this becomes a third place
where facts live. `AGENTS.md` is emphatic that the board holds who / where / blocked-on and
issues hold everything else, and that *two places for one fact is the drift this repo keeps
catching*. So the boundary has to be explicit:

- **It holds release-level narrative** — goal, scope, the promise, and the argument for the
  cut. An issue cannot hold *"what is this release for"*; `release-scope.md` proved that by
  being the thing #91 needed and could not be.
- **It does not hold per-item state.** No blocker lists that duplicate the board, no status
  that a label already carries. When this file and an issue disagree, the issue wins.

One consequence worth stating plainly: **a frozen release doc is allowed to be wrong.** Once
`0.1.0.md` is stamped it is a record of what was believed at the time, not a claim about
today — which is exactly what lets it be honest without becoming a maintenance burden. Say so
at the top of each frozen file, or a future reader will file bugs against history.
