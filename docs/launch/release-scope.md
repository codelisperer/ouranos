# Release scope — what the first public Ouranos release covers

**Status:** Decision doc, not a decision — 2026-07-29. Written to be argued with.
Once settled, the outcome belongs in the [`ECOSYSTEM.md`](../../ECOSYSTEM.md) decisions
log; this file keeps the reasoning.

---

## 1. The question behind the question

"What does v0.1 cover?" reads as a scope question. It is really a **goal** question,
because three different goals imply three different scopes, and only one of them is safe
for a solo maintainer with client work on the side:

| Goal | What it demands | Cost if you get it wrong |
|---|---|---|
| **(A) Attract users** — people building real things on Ouranos | Stability, migration discipline, responsive issue triage, docs that don't lie | Highest. Users arrive with bug reports and expectations; a stale issue queue reads as abandonware and is *worse than never launching* |
| **(B) Attract contributors** — people sending patches | Legible architecture, a working build on three OSes, a "good first issue" queue, a license | Moderate. Contributors who bounce off a broken build rarely return |
| **(C) Establish the thesis** — the argument, the reputation, the writing | A public repo people can *read*, one demo that lands, and a well-argued case | Lowest. Compounds over time and costs almost nothing to sustain |

**These are ordered by risk, and they are not simultaneous.** (C) is what makes (B)
possible; (B) is what makes (A) survivable. Launching straight at (A) with seven
frameworks and one maintainer is the failure mode this document exists to name.

The rest of this doc assumes the real question is: *what is the smallest honest thing
that serves (C), sets up (B), and does not promise (A)?*

## 2. Where the code actually is

Measured 2026-07-29, not estimated. This is the ground truth any scope decision has to
survive.

| Framework | Lisp files | Tests | Coalton forms | Honest maturity |
|---|---|---|---|---|
| **hyperion** | 36 | 10 files / 948 lines | 2 | **Most built.** HTMX+Spinneret, i18n (incl. RTL), static caching w/ ETag, sessions, channels, typed interceptors, a native-webview desktop app that runs |
| **praxeon** | 18 | 1 file / 378 lines | 1 | Actor loop, provider-neutral LLM, translator, per-agent models — real, and demoed by two example apps |
| **cons** | 18 | 6 files / 262 lines | 3 | Bootstrap seed **works**; `init`/`setup`/`conform`/`env`/`db-repl`/`db-url`/`template check`/`version` + a per-framework task runner. The advertised `build\|test\|serve\|run` surface **does not exist yet** |
| **hermes** | 12 | 1 file / 123 lines | 0 | Email + SMS shipped w/ signature-verified inbound; neutral payments with a Stripe backend shipped (pre-publication issue 47) |
| **mnemosyne** | 20 | 3 files / 367 lines | 4 | Scaffold. Backend protocol, query DSL, migrations, and the bitemporal API are all **open research issues** |
| **aion** | 13 | 2 files / 200 lines | **0** | `aion/log` and `aion/csv` are real; the "Coalton-first functional stdlib" core is **not written** |
| **elenchon** | 3 | 0 | **0** | Design-complete as of the ADR pass; ~40 lines of placeholder code |

Repo-wide: **201 test forms**, **~879 lines of Coalton across 7 files**, 74 open issues.

### The credibility gap, stated plainly

Three claims in the front-facing docs currently outrun the code, and they are exactly
the three a skeptical reader checks first:

1. **"Coalton-first functional stdlib" (aion) — with zero Coalton in it.** `aion.asd`
   even declares `:depends-on ("coalton")`. This is the single most damaging one, because
   aion is where a reader goes to see the typed-core thesis in practice, and the typed
   core *is* the differentiator. Elenchon has the same shape of gap, but elenchon is
   openly pre-alpha, so it costs far less.
2. **`bin/cons build|test|serve|run`** appears in `CLAUDE.md` and the README as the build
   story. It is marked "INTENDED / in progress" in the constitution — but a reader who
   runs it and gets nothing does not grade on marking.
3. **"MIT"** is declared in all seven `.asd` files and in `ECOSYSTEM.md` — and **there is
   no LICENSE file anywhere in the repo.** Without one, the code is all-rights-reserved
   no matter what the metadata says. Nobody can legally use or contribute to it.

None of these is expensive to fix. All three are fatal to leave.

## 3. The options

### Option A — Narrow cut: hyperion-led

Publish hyperion + cons + aion as the story; the rest are visible but labelled
in-development.

- **For:** ships what is real; hyperion genuinely is a working full-stack framework with
  a native desktop demo, which is a strong artifact. Smallest surface to support.
- **Against:** hyperion alone is "another web framework," and the *interesting* claim is
  the ecosystem — six co-evolving frameworks, CL all the way down. Narrowing to hyperion
  narrows to the least differentiated framing. It also still requires aion to be honest,
  since cons and hyperion both sit on it.

### Option B — Whole ecosystem, honest alpha

Publish all seven with per-framework maturity badges.

- **For:** the coherent story is the whole DAG, and the DAG *is* the thesis. Badges are a
  well-understood convention and readers accept them.
- **Against:** invites people into elenchon and mnemosyne, which will disappoint anyone
  who tries to use them; multiplies the surface that must be kept honest; makes the issue
  queue look like a much larger promise than one maintainer can service. Slides toward
  goal (A) whether or not you intend it.

### Option C — Thesis-first

Publish the site, the papers, and the argument. Code release follows.

- **For:** cheapest, safest, compounds. The writing is the durable asset, and the thesis
  is genuinely interesting independent of maturity.
- **Against:** a thesis about a stack nobody can read is weaker than one they can. "CL
  all the way down" invites *show me*, and a private repo cannot answer. Pure C leaves the
  strongest available evidence — a working desktop Coalton REPL with no Electron in
  sight — on the shelf.

## 4. Recommendation

**A blend of C and B, aimed at goal (C), explicitly not offering (A): make the repo
public with honest per-framework maturity, lead the narrative with the thesis, and let
one demo carry the proof.**

Concretely:

1. **Go public with all seven, badged.** Option B's *artifact* with Option C's *framing*.
   The DAG is the story; hiding four-sevenths of it to look more finished defeats the
   point, and honest badges are cheaper than a narrow release that still has to explain
   the missing frameworks.
2. **State the promise explicitly in the README**: this is a working research stack, not
   a supported product; APIs will break; issues are welcome, SLAs are not offered. This
   one paragraph is what keeps (A) from arriving uninvited.
3. **Lead with the demo, not the framework list.** The native desktop Coalton REPL —
   a typed REPL in an OS webview, no Electron, no Node, ~30–50 MB — is the most
   *immediately legible* proof of the thesis in the entire tree. It is also already
   built. That is the launch artifact.
4. **Elenchon is the strongest written asset.** Post-ADR it has a sharp, defensible
   position — *a requirement-defect finder that also generates tests*, in the Bender RBT
   lineage — that is genuinely differentiated and has nothing to do with Lisp advocacy.
   It is likely the best blog-post subject in the repo *precisely because* it is not yet
   built: it is an argument, and arguments are what stage (C) trades in.
5. **Version honestly: `0.1.0`, not `1.0`.** There is no reason to spend the 1.0 signal
   before mnemosyne's backend protocol is settled.

### Hard blockers — true under every option

These gate any public release. Rough order of effort:

- [ ] **LICENSE file(s)** — MIT at the root, matching the `.asd` metadata. *Non-negotiable
      and cheapest.* Nothing else matters until this exists.
- [ ] **Fix the aion claim** — either write the Coalton core, or restate the description
      to what aion actually is today. Writing it is the better answer (aion is the natural
      showcase for the typed core), but restating is legitimate and takes minutes. What is
      not legitimate is shipping the claim as-is.
- [ ] **A CI workflow that builds and tests the tree on Linux + macOS + Windows.** Only
      `desktop-release.yml` exists today. "SBCL-exclusive and works everywhere" is a
      claim; a green matrix is the evidence, and its absence is conspicuous.
- [ ] **`bootstrap.lisp` verified on a clean machine on all three OSes.** It is the first
      command anyone runs. A first-run failure costs the reader permanently.
- [ ] **Repo description** — currently the placeholder *"Your friendly neighborhood
      monorepo for Hyperion and related frameworks."* It is the first line of the pitch.
- [ ] **Per-framework maturity badges**, consistent between README, `ECOSYSTEM.md`, and
      each framework's README. Three sources of truth that disagree is worse than none.
- [ ] **Confidentiality sweep** before the repo goes public — the private-consuming-app
      rule in [`AGENTS.md`](../../AGENTS.md) has been enforced by convention in a private
      repo. Verify it holds across code, comments, docs, papers, **commit messages, and
      issue text**, none of which can be redacted after publication.

### Deliberately *not* blockers

Perfectionism about these would delay indefinitely for little gain: mnemosyne's research
questions, elenchon's implementation, `cons build|test|serve|run` reaching parity, the
papers being finished, the self-hosted site being live. Badge them and ship.

## 5. What this does not decide

- **Timing**, and its relationship to the site. The site is a separate repo (decided) and
  will dogfood hyperion + mnemosyne — which means it depends on the least-finished core
  framework. Whether the launch waits for the site is open, and the honest answer is
  probably no.
- **Distribution.** `ECOSYSTEM.md` names Ultralisp + ocicl as the future path. Neither is
  needed for a source release, and pushing to Ultralisp is a stronger commitment than
  going public — it puts the code in other people's builds.
- **Where the writing lives** during the transition from Hashnode to self-hosted.
- **Whether the papers ship with the release** or trail it.
