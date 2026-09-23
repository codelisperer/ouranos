# Elenchon — the CEG engine

*ἔλεγχος — "cross-examination, refutation."* **The Cause-Effect Graph engine and
reasoning system for Requirements-Based Testing**, in the lineage of Myers'
cause-effect graphing as industrialized by Bender RBT.

The name is the method. *Elenchos* is Socratic cross-examination: you interrogate a
claim until its ambiguities and contradictions surface, and what survives is sound.
Elenchon does that to requirements.

---

## What it is / why it exists

The thesis is a single empirical claim with large consequences:

> **Most defects are born in the requirements, not the code.**

If that is true, the highest-leverage testing artifact is not a test suite — it is a
*formalized requirement*, from which a provably-minimal, provably-sufficient set of
functional tests can be **derived**. Elenchon is the rigorous engine for that
derivation: a typed Cause-Effect Graph plus a reasoning system that crunches it into
minimal, sufficient tests and a requirement-defect report.

Given a **structured** CEG — causes, effects, and the classic `E`/`I`/`O`/`R`/`M`
constraints — Elenchon:

1. **Builds** the typed Cause-Effect Graph (a Coalton ADT).
2. **Reasons** over it to the minimal decision table whose columns show each cause
   *independently* driving its effect (≈ **MC/DC** coverage).
3. **Renders** the table into functional test cases, each traceable to the
   originating requirement.
4. **Reports** the requirement defects that graphing surfaces for free — dangling
   causes and effects, contradictory constraints, non-propositional requirements.

### The scope boundary decides the architecture

Elenchon does CEG **crunching and reasoning** — *not* natural-language translation.
Turning human prose into a CEG (step 0 of the classic RBT method) is where an LLM
earns its keep, and it is an **agentic function that lives above Elenchon**, in
`praxeon` (its **ChatRBT** example), modelled as an `End`/`Means`/`Action` loop where
ambiguity is a *recoverable failure* — retry, substitute, or abandon and ask the
human. That layer produces the structured causes and effects and calls Elenchon's
CEG-building API.

Elenchon itself knows nothing about natural language, and can therefore be driven by
an agent, a form, or a test. **Engine below, AI above: each does what it is best at.**

### The constraint vocabulary

The CEG wires causes to effects through `AND`/`OR`/`NOT`, plus the classic
constraints — the vocabulary the code is expected to use verbatim:

| Constraint | Among | Meaning |
|---|---|---|
| `E` (exclusive) | causes | at most one true |
| `I` (inclusive) | causes | at least one true |
| `O` (one-only) | causes | exactly one true |
| `R` (requires) | causes | a true ⇒ b true |
| `M` (masks) | effects | a true ⇒ b suppressed |

Each column of the resulting decision table is a **functional variation** — a
complete true/false assignment of causes with its resulting effects, i.e. one test
case.

---

## Where it sits in the DAG

```
aion → cons → mnemosyne → elenchon → hyperion → praxeon
                             ▲
                             may depend only leftward — never on hyperion/praxeon
```

Elenchon may depend on `aion` (persistent collections, constraint sets — likely v1)
and later `mnemosyne` (persisting CEGs and projects). It must **never** depend on
`praxeon` or `hyperion`.

This is not a stylistic preference; it is the structural fact that determines the
entire architecture. `praxeon`/ChatRBT depends on Elenchon, so Elenchon depending
back would be a cycle, and ASDF would simply refuse. The dependency direction is
therefore what *forces* the NL→CEG extraction to live above Elenchon rather than
inside it — and that forcing turns out to be a feature. It keeps the engine
deterministic, testable, and drivable by anything: an agent, a web form, or a unit
test.

Elenchon is a **framework** (the engine). The *application* is always a consumer
above it.

---

## Current status

**Pre-alpha (0.0.0) — the spine exists; the reasoning system does not.**

**The ten founding design questions are resolved** (2026-07-29) in five ADRs —
[`elenchon/docs/adr/`](../../elenchon/docs/adr/README.md) — and
`elenchon/docs/elenchon-vision.md` is now the index from question to decision. Two
decisions departed from the leans recorded at founding: the reasoning engine
([ADR-0002](../../elenchon/docs/adr/0002-reasoning-engine.md)) and the extraction seam
([ADR-0004](../../elenchon/docs/adr/0004-builder-contract-and-extraction-seam.md)).

What exists: the founding docs — above all `docs/method.md`, the design brief that
defines the pipeline and fixes the vocabulary — the five ADRs, the scaffold, and
**`elenchon/ceg`: the typed Cause-Effect Graph ADT in Coalton**, with total evaluation
semantics (expression evaluation with `Ref` resolution, effect evaluation with `M`
masking, and `E`/`I`/`O`/`R` feasibility checking).

**The next move** is `Finding` + `Draft` and the validating builder
([ADR-0004](../../elenchon/docs/adr/0004-builder-contract-and-extraction-seam.md)) —
ahead of the reasoning system, because
[ADR-0005](../../elenchon/docs/adr/0005-positioning-defect-finder-first.md) makes the
defect report the product rather than a byproduct. No LLM is involved at any point —
that is the consumer's job.

The module shape:

| Module | Language | Role | State |
|---|---|---|---|
| `elenchon/ceg` | Coalton | The typed Cause-Effect Graph ADT — the spine | **exists** |
| `elenchon/report` | Coalton + CL | The `Finding` vocabulary and the requirement-defect report | next |
| `elenchon/build` | CL | The validating CEG-building API the consumer drives | next |
| `elenchon/reason` | Coalton | CEG → minimal decision table (the reasoning system) | planned |
| `elenchon/cases` | Coalton | Decision-table columns → test cases + traceability | planned |
| `elenchon/cl` | CL | The pure-CL face for users who never touch Coalton | planned |

---

## Design narrative

### Why Coalton, specifically, for this problem

Elenchon is arguably the strongest case for Hindley–Milner types anywhere in the
monorepo. Causes, effects, boolean wiring, and the constraint letters are a
*textbook* algebraic data type, and the reasoning is pure logic over that type with
no IO anywhere near it. There is no dynamic-typing convenience being sacrificed here;
there is only a formal object that wants to be typed. **Get the CEG ADT right and the
reasoning system follows** — which is exactly why the ADT is the recommended first
thread rather than the solver.

### CEG representation: node graph, or boolean expression tree?

The first real design fork. The graph can be modelled either as an explicit **graph
of cause/effect nodes with typed edges**, or as a **boolean expression tree per
effect** (`effect = (AND c1 (NOT c2) …)`) with the constraints held in a side table.

The trade-off is clean: the expression tree is simpler to solve and simpler to type;
the node graph matches the classic diagrams from the literature and carries
traceability naturally.

**Settled ([ADR-0001](../../elenchon/docs/adr/0001-ceg-representation.md)): an
expression *DAG*, with the node diagram derived.** Working the type out exposed a
defect in the pure-tree form — real CEGs share subexpressions ("overdue AND not
exempt" typically drives several effects), and a tree per effect duplicates them. That
breaks the thing the tree was supposed to preserve: a reviewer, the literature, and the
defect report all want to point at *node N1*, and duplicated subtrees give them nothing
to point at. So sharing is made **explicit** — a `Ref` constructor naming an
intermediate node — rather than implicit via hash-consing, because an implicitly shared
node has no name.

`Conj`/`Disj` are n-ary (the literature's nodes are), constructors avoid `And`/`Or`/`Not`
(Coalton's prelude owns those and the language is case-insensitive), identifiers are
distinct newtypes, and evaluation is total in `(Optional Boolean)` — `None` meaning
*underdetermined*, which is a finding rather than a false. Constraints stay in a side
table, as expected: they constrain across expressions and belong inside none of them.

### The reasoning engine — the marquee technical fork

This is the headline decision, and it is deliberately kept behind **one neutral
protocol** so that it stays a decision rather than a commitment. Three candidates:

- **(a) Relational / miniKanren.** Express the CEG as relations and let a
  miniKanren-style logic engine search for the covering assignments. This is the
  leading candidate and the natural fit: **the CEG *is* a set of logical relations,
  and minimality is a search over models.** It is also the most Lisp-native option,
  and it is what makes the "reasoning system" framing — as opposed to "table
  generator" — actually true rather than aspirational.
- **(b) The classic Bender/Myers table-walk**, implemented in Coalton. Self-contained,
  matches the literature exactly, no search machinery. The conservative baseline.
- **(c) SAT/SMT via FFI.** Reduce coverage to constraint satisfaction and hand it to a
  mature solver. Scales best; costs a foreign dependency, which the monorepo's
  minimal-dependency stance treats as a real price.

**Settled ([ADR-0002](../../elenchon/docs/adr/0002-reasoning-engine.md)) — and it
departs from the lean.** Writing the decision out surfaced that this is *two* problems,
and the interesting one is not a search problem:

1. **Independence-pair generation** — for each (cause, effect), find two feasible
   assignments differing only in that cause, whose effect values differ. Constraint
   satisfaction; the part miniKanren and SAT are genuinely good at.
2. **Minimization** — choose the fewest columns realizing *every* required pair. This is
   **set cover**, and it is where the "minimum tests" claim is actually won.

Neither miniKanren nor a plain SAT solver solves (2). Adopting a relational engine buys
a stream of satisfying assignments, leaves the load-bearing half untouched, and adds a
dependency. Scale also argues against reaching for a solver: RBT works one requirement
at a time, at roughly 5–25 causes.

The decider is **determinism**. Elenchon's output is meant to be *evidence*, and a suite
that differs run to run because search order differed is a far weaker artifact than one
that is bit-identical every time. Native code with fixed traversal order gets that by
construction.

So **v1 is a native Coalton core — deterministic pair generation, then greedy set cover
with an exact pass where affordable — behind a `Solver` class that keeps (a) and (c)
pluggable.** miniKanren remains a live prototype for pair generation *only*, worth
building precisely to measure rather than assume; SAT/SMT stays the documented escape
hatch for scale. The "reasoning system, not a table generator" framing survives intact,
and arguably strengthens: what distinguishes Elenchon is the **minimality argument**,
not the search technology under it.

### The coverage target, and why it is stated so precisely

The default target is not "all effects seen" — that is the weak criterion that makes
generated test suites look impressive and prove little. The target is **each cause
independently drives its effect**: flip one cause, hold the rest, show the effect
changes. That is essentially **MC/DC** (Modified Condition/Decision Coverage), the
criterion DO-178C requires for safety-critical avionics software.

Minimum tests, maximum requirement-logic coverage — that is the whole value
proposition, and it only means something if the criterion is named and held.

**Settled ([ADR-0003](../../elenchon/docs/adr/0003-coverage-target.md)): configurable,
defaulting to the strong criterion.** A `Coverage` ADT — `Decision` / `Independence` /
`MultipleCondition` — parameterizes pair generation, and `Independence` is the default
everywhere. A tool that silently imposes one criterion is not more rigorous than one
that names three and defaults to the strong one; it is only less legible, and the
trade-off *is* the pitch. It also costs nothing: the generator has to know which pairs
are required either way.

Two guardrails. Every emitted artifact **states the criterion it was generated under** —
a decision table without its criterion is not evidence. And `MultipleCondition` is
bounded: past a configured size it returns a structured error naming the size, rather
than running until the heap dies.

### Traceability is a first-class output, not an afterthought

Every rendered test case must be traceable back to the originating requirement and to
the causes and effects it exercises. This is not documentation polish: **traceability
is what makes the coverage claim auditable.** A minimal test set nobody can verify
against the requirement is a claim, not evidence.

**Settled ([ADR-0004](../../elenchon/docs/adr/0004-builder-contract-and-extraction-seam.md)):**
the anchor is `requirement = ID + text` — every cause and effect carries an optional
`ReqId`, already in the ADT. The `DecisionTable` value is canonical and renderers are
separate and pure; v1 ships a human-readable table and a machine-readable s-expression,
each case carrying its `ReqId`, the causes it fixes, the effects it asserts, and the
criterion it was generated under. Executable stubs are deferred — and when they arrive,
generic given/when/then before fiveam, because Elenchon tests *requirements* and the
system under test is usually not Common Lisp.

### The Elenchon ↔ agentic-layer contract

The "does the LLM decide or propose?" question belongs to the *consumer*, not to
Elenchon. Elenchon's own question is narrower and more interesting: **what exactly
must a caller hand the CEG-building API?**

Fully-formed causes, effects, and constraints only — or may the API accept *partial*
input and report what is missing or ill-formed, so the agent above can iterate? And
should the API **validate propositions** — reject anything that is not genuinely
yes/no — and surface that rejection as a *defect*, closing the loop with the agent?

**Settled ([ADR-0004](../../elenchon/docs/adr/0004-builder-contract-and-extraction-seam.md)):
a validating builder that returns structured "what is still ambiguous or incomplete" —
and *every* reason, not the first.** That last part is load-bearing: the caller is
typically an agent iterating toward a well-formed graph, and one-finding-at-a-time turns
one round trip into many. It is the same posture the whole stack takes toward failure —
recoverable, structured, reported rather than guessed around. (The condition system is,
as the project constitution notes, *literally* the model for requirement ambiguity here.)

One refinement to the boundary: **Elenchon validates structure, never propositions.**
Deciding whether "the response must be fast" is a genuine yes/no proposition requires
understanding the sentence — agentic work, above the line, by construction. A caller can
*mark* an item non-propositional and Elenchon carries that through as a finding. The
boundary stays honest: Elenchon never reads prose and never pretends to.

**On the extraction seam, the decision departs from the lean: there is no protocol —
the seam is data.** A generic function that Elenchon defines but never *dispatches on*
is not a protocol; it is documentation with a compile step, and one nobody is obliged to
implement. What actually crosses the boundary is a `Draft` going in and an `Outcome`
coming back, and those types *are* the contract — inspectable, serializable, diffable,
and equally usable by an agent, a web form, or a unit test. Elenchon documents a data
contract without depending rightward and without inventing machinery.

**Input formats** are likewise settled by the same ADR: `requirement = ID + text` is the
traceability anchor, and richer sources (user stories, Gherkin, a requirements document)
are the consumer's parsing problem. They all reduce to a `ReqId` plus text at this
boundary. Elenchon targets no document format, ever.

### Is the defect report a byproduct, or the actual product?

This is the question that most shapes the pitch. **Settled
([ADR-0005](../../elenchon/docs/adr/0005-positioning-defect-finder-first.md)): it is the
product.** Elenchon is a requirement-defect finder that also generates tests.

Graphing a requirement is a *forcing function*. Causes with no path to any effect,
effects with no cause, contradictory constraints, and requirements that cannot be
reduced to yes/no propositions all fall out **for free** as ambiguity /
incompleteness / contradiction findings. Surfacing those before a line of code is
written is often worth more than the generated tests — and **Bender's own practice
treats the ambiguity review as a primary deliverable**, arguably the higher-value one.

Four things decided it. The report **delivers value before any code exists** — it works
against a requirements document alone, which is the thesis applied to Elenchon's own
adoption path. It **works on incomplete input**, since advisory findings do not block a
build, whereas a decision table needs a complete graph — so the report is useful at
every step of the agent conversation and the table only at the end. It is
**differentiated**: there are many test generators and very few tools that read a
formalized requirement and tell you it contradicts itself. And **the name already says
it** — *elenchos* is cross-examination, chosen for the defect-finding reading.

Test generation is not demoted; it is the **rigor guarantee**. An analysis that can
produce a provably-minimal covering suite is demonstrably a real analysis and not a
linter with opinions. Both ship — the report is what is led with.

Consequences: `elenchon/report` is a v1 module ahead of `elenchon/cases`; the `Finding`
vocabulary is a first-class public type; the demo leads with contradictions and *then*
shows the suite; and the tagline is defect-first — *interrogate a requirement until its
contradictions surface, then derive the minimal suite that proves the rest.*

The risk to watch is that a defect-finder pitch invites comparison to NLP-flavoured
"requirements quality" tooling, which is a weaker category. Positioning has to keep the
**formal** basis in front: these findings fall out of a graph, not out of a language
model.

### Scope guard: functional black-box, and saying so

CEG/RBT is a black-box, functional technique. **Settled
([ADR-0005](../../elenchon/docs/adr/0005-positioning-defect-finder-first.md)): stay
there deliberately, and say so loudly.** Combinatorial/pairwise generation and
classification trees are out of scope and named as adjacent-but-different in the docs,
rather than left as an implicit maybe. Saying no now costs nothing later: under ADR-0002
they would arrive as additional `Solver` instances over the same CEG, so the boundary is
a scope decision, not an architectural one.

### Evidence — how the claim gets backed

"Minimal tests, maximal value" is a strong claim and needs more than a README.
**Settled ([ADR-0005](../../elenchon/docs/adr/0005-positioning-defect-finder-first.md)),
in build order:**

1. **A mechanical coverage proof.** For any CEG small enough to enumerate, brute-force
   all 2ⁿ assignments as ground truth and verify that the generated suite realizes every
   required independence pair — and that no smaller suite does. This turns the minimality
   claim from marketing into **a property test that runs in CI**, and it is the natural
   first consumer of ADR-0002's determinism. Nothing else here is as convincing per unit
   of effort.
2. **A worked canonical example** carried end to end — prose → draft → findings → graph
   → decision table → tests — published as *the* demo. One genuinely gnarly requirement,
   not a toy.
3. **A benchmark corpus** of requirement sets with known-good suites, for regression and
   comparative claims.
4. **A Bender RBT / SoftTest comparison** where output is obtainable — ranked last
   because availability is uncertain and the evidence story cannot depend on it.

Dogfooding feeds (2) and (3) continuously: the monorepo's own specs — hyperion's i18n
negotiation rules, the interceptor pipeline's flow semantics — are real requirements with
real ambiguity, so running Elenchon on them is evidence and a bug hunt at once.

### Positioning

| Prior art | Relationship |
|---|---|
| **Bender RBT / SoftTest** | The commercial methodology and tool Elenchon descends from — the target to *match on rigor*, then exceed on openness plus AI-assisted extraction |
| **Myers, cause-effect graphing** | The original technique (*The Art of Software Testing*) |
| **MC/DC (DO-178C)** | The coverage criterion the minimal-set generator targets |
| **Classification-tree / pairwise tools** | Adjacent black-box test-design methods; useful contrasts, not the same thing |

### The constraints

- **Typed CEG and reasoning system in Coalton**; the CEG-building API, reporting, and
  IO in CL — **no IO in the core**.
- Elenchon's input is **structured** causes and effects (yes/no propositions).
  Elenchon validates and reasons; it does **not** translate natural language.
- **Depends only leftward** — `aion` now, `mnemosyne` later. Never
  `praxeon`/`hyperion`.
- The coverage target is **each cause independently drives its effect** (≈ MC/DC),
  not merely "all effects seen."
- **Traceability is a first-class output**, because it is what makes the coverage
  claim auditable.
- The reasoning engine stays **behind a neutral protocol** — miniKanren, table-walk,
  and SAT/SMT must remain interchangeable.

---

## Usage

Elenchon is one of six core frameworks in the Ouranos monorepo; you build the whole
tree, not this directory alone. Prerequisites: **SBCL + Quicklisp** (Coalton loads
from Quicklisp on first use).

```sh
git clone https://github.com/codelisperer/ouranos.git
cd ouranos
sbcl --dynamic-space-size 4096 --script bootstrap.lisp   # → bin/cons
```

```lisp
(ql:quickload :elenchon)
(elenchon:version)        ;; => "0.0.0"
```

First load compiles Coalton (a minute or so; cached afterwards). `Heap exhausted`
means SBCL was started without the larger heap — pass `--dynamic-space-size 4096`.

### The intended shape (planned)

Elenchon takes a **structured** CEG — causes, effects, and their boolean wiring
already extracted. Turning the prose *"If the account is overdue AND the customer is
not exempt, apply a late fee and send a notice"* into that structure is the agentic
consumer's job, **above** Elenchon; here the CEG is built directly:

```lisp
;; illustrative -- not yet implemented
;; The causes/effects below are already-extracted structure (a consumer above --
;; praxeon/ChatRBT, a form, or this literal -- did the NL->CEG step). Elenchon
;; reasons over the structured graph; it does not read prose.
(elenchon:examine
  (elenchon:ceg
    :causes  '((C1 . account-overdue) (C2 . customer-exempt))
    :effects '((E1 . apply-late-fee)  (E2 . send-notice))
    :graph   '((E1 (and C1 (not C2)))
               (E2 (and C1 (not C2))))))
;; => tests:   minimal decision table (each cause shown to drive its effect)
;;    report:  0 contradictions; note: "exempt" undefined -> possible ambiguity
```

---

## Roadmap

Planning is live on the board and in issues — this page carries the *why*, not the
task list.

- **Board:** https://github.com/orgs/codelisperer/projects/1
- **Open `elenchon` issues:** https://github.com/codelisperer/ouranos/issues?q=is%3Aissue+is%3Aopen+label%3A%22pkg%3Aelenchon%22

## See also

- `elenchon/docs/method.md` — the founding design brief: the pipeline, the
  constraint vocabulary, and the boundary. Read it before writing code; it fixes the
  terms the code uses (causes, effects, constraint letters, functional variation,
  decision table) in preference to ad-hoc "node/rule/case" language.
- `elenchon/docs/adr/` — the five decision records that resolve the founding design
  questions. Read [ADR-0001](../../elenchon/docs/adr/0001-ceg-representation.md) before
  touching the ADT and
  [ADR-0002](../../elenchon/docs/adr/0002-reasoning-engine.md) before touching the solver.
- `elenchon/docs/elenchon-vision.md` — the index from each founding question to the ADR
  that resolved it, plus what is still genuinely open.
