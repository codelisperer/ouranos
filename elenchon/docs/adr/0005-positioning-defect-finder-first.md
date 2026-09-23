# ADR-0005 — Positioning: a requirement-defect finder that also generates tests

**Status:** Provisional — 2026-07-29
**Resolves:** [`elenchon-vision.md`](../elenchon-vision.md) Q7, Q9, Q10

## Context

Three questions that together decide what Elenchon *is* to a reader, and therefore what
gets built first, what the demo shows, and how it is pitched.

**Q7 — is the defect report the product or a byproduct?** Graphing a requirement is a
forcing function: dangling causes, uncaused effects, contradictory constraints, and
propositions that are not yes/no all fall out for free. Bender's own practice treats the
ambiguity review as a primary deliverable, arguably the higher-value one. Left
deliberately open rather than resolved by default.

**Q9 — how does "minimal tests, maximal value" get backed?** A benchmark corpus, a
comparison against Bender RBT's output, a worked published example.

**Q10 — stay black-box functional, or leave room for adjacent methods?**

## Decision

**Elenchon is a requirement-defect finder that also generates tests.** The report leads;
the decision table proves the analysis was rigorous.

Four reasons, in order of weight:

1. **It delivers value before any code exists.** The report is useful against a
   requirements document alone. Test generation only pays off once there is a system to
   test. Leading with the report means the tool is useful at the earliest, cheapest
   point in the lifecycle — which is precisely the thesis (*most defects are born in the
   requirements*) applied to Elenchon's own adoption path.
2. **It works on incomplete input.** Under ADR-0004 advisory findings do not block a
   build, so a half-formed CEG still yields a report. A decision table needs a complete,
   well-formed graph. The report is therefore useful at every step of the agent
   conversation; the table only at the end.
3. **It is differentiated.** There are many test generators. There are very few tools
   that read a formalized requirement and tell you it contradicts itself. "Another test
   generator" competes on a crowded axis; "your requirement has three contradictions and
   an unreachable clause" does not.
4. **The name already says it.** *Elenchos* is cross-examination — interrogating a claim
   until its ambiguities surface. The name was chosen for the defect-finding reading, not
   the generation reading.

What follows from it:

- **`elenchon/report` is a v1 module, not a later one**, and the `Finding` vocabulary
  (ADR-0004) is a first-class public type rather than an internal diagnostic.
- **The demo leads with defects.** A requirement goes in; contradictions and ambiguities
  come out; *then* the minimal suite, as the proof that the analysis was rigorous enough
  to generate from.
- **The tagline** is defect-first: *interrogate a requirement until its contradictions
  surface — then derive the minimal suite that proves the rest.*
- Test generation is **not demoted**. It is the rigor guarantee: an analysis that can
  produce a provably-minimal covering suite is demonstrably a real analysis and not a
  linter with opinions. Both ship; the report is what is led with.

**Q9 — evidence, in the order it should be built:**

1. **A mechanical coverage proof (highest leverage, cheapest).** For any CEG small enough
   to enumerate, brute-force all 2ⁿ assignments as ground truth and verify that the
   generated suite really does realize every required independence pair, and that no
   smaller suite does. This turns the minimality claim from marketing into a **property
   test that runs in CI**. Nothing else on this list is as convincing per unit of effort,
   and it is the natural first consumer of ADR-0002's determinism.
2. **A worked canonical example**, carried end to end — prose → draft → findings → graph
   → decision table → tests — published as *the* demo. One genuinely gnarly requirement,
   not a toy.
3. **A benchmark corpus** of requirement sets with known-good suites, for regression and
   for comparative claims.
4. **A Bender RBT / SoftTest comparison** where output is obtainable. Ranked last because
   availability is uncertain and it cannot be a dependency of the evidence story.

Dogfooding is a standing source of (2) and (3): the monorepo's own specs — hyperion's
i18n negotiation rules, the interceptor pipeline's flow semantics — are real requirements
with real ambiguity, and running Elenchon on them is both evidence and a bug-finding
exercise.

**Q10 — scope guard: functional black-box only, stated loudly.** Combinatorial/pairwise
generation and classification trees are **out of scope**, named as adjacent-but-different
in the docs rather than left as an implicit maybe. Saying no now costs nothing later:
under ADR-0002 they would arrive as additional `Solver` instances against the same CEG,
so the boundary is a scope decision, not an architectural one.

## Consequences

- Build order changes: `elenchon/report` moves ahead of `elenchon/cases`, and the
  `Finding` type is on the critical path immediately after the CEG ADT.
- The launch narrative for Elenchon is settled and can be written now, ahead of the
  engine — useful to the launch lane, which needs positioning before it needs a release.
- ChatRBT's demo script is implied: converse → show findings → resolve → show the suite.
  The dramatic beat is the findings.
- Risk to watch: a defect-finder pitch invites comparison to requirements-management and
  NLP-based "requirements quality" tools, which are a different and weaker category.
  Positioning must keep the *formal* basis in front — findings fall out of a graph, not
  out of a language model.

## Alternatives considered

- **Test-generator-first** (report as a byproduct). Rejected: it competes in a crowded
  category, requires a complete graph to say anything at all, and undersells the part of
  the method that Bender's own practice values most.
- **Two products, marketed separately.** Rejected: they share one engine and one
  vocabulary, and splitting them would double the explanation for no gain.
- **Leaving Q7 open until there is a working engine.** Rejected because it blocks the
  launch lane, which needs positioning before code, and because the answer visibly
  changes build order — leaving it open means building in the wrong order by default.
