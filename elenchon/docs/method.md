# The Method: Requirements-Based Testing via Cause-Effect Graphs

*Elenchon's founding design brief. **Read this first.** It defines the method and
fixes the vocabulary the code uses — and where Elenchon's boundary sits.*

> **Scope up front.** Elenchon is the **CEG engine + reasoning system**: given a
> *structured* Cause-Effect Graph it reasons over it to emit a minimal, sufficient
> set of functional test cases (plus a defect report). It does **not** do
> natural-language translation. Turning human prose into a CEG — step (1) below — is
> an **agentic function that lives *above* Elenchon**, in praxeon (see its ChatRBT
> example). This doc describes the whole RBT method for context, but Elenchon owns
> only steps (2)–(4) and the defect report; step (1) is a consumer's job. Elenchon
> never depends on praxeon/hyperion (dependency order forbids it).

The lineage is Myers' cause-effect graphing (*The Art of Software Testing*) as
industrialized by Richard Bender's **Requirements-Based Testing (RBT)**. The thesis
in one line: **most defects are born in the requirements, not the code**, so the
highest-leverage testing artifact is a *formalized* requirement from which a
provably-minimal, provably-sufficient set of functional tests can be derived.

The name says the method. *Elenchos* is Socratic cross-examination: you interrogate
a claim until its ambiguities and contradictions surface, and what survives is
sound. Elenchon does that to requirements.

---

## The pipeline

```
  Ambiguous NL requirement
        ┊  (1) extract + disambiguate     [ABOVE Elenchon — agentic, praxeon/ChatRBT]
        ▼
  ┌─ Elenchon's boundary ──────────────────────────────────────────────────┐
  │ Structured causes & effects ──(2) build──►  Cause-Effect Graph  [Coalton ADT]
  │       │                                          │                        │
  │       │  (dangling/contradictory/                │  (3) reason/solve      │
  │       │   non-propositional findings)            ▼                        │
  │       ▼                                  Minimal decision table [reasoning │
  │ Requirement-defect report                        │            system]     │
  │                                                  │  (4) render            │
  │                                                  ▼                        │
  │                            Functional test cases + traceability           │
  └───────────────────────────────────────────────────────────────────────────┘
```

### 1. Extract & disambiguate  *(ABOVE Elenchon — an agentic consumer)*
Turning a human-language requirement into distinct **causes** (input conditions)
and **effects** (output conditions / transformations) — as *yes/no* propositions,
flagging anything that can't be phrased that way rather than guessing — is where an
LLM earns its keep. **This step is not Elenchon's.** It lives in an agentic layer
*above* Elenchon (praxeon's ChatRBT), modeled as a praxeon `End`/`Means`/`Action`
loop where **ambiguity is a recoverable failure** (retry / substitute / *abandon →
ask the human*). That layer produces the *structured* causes/effects and calls
Elenchon's CEG-building API. Elenchon itself takes structured input and knows
nothing about natural language — so it can be driven by an agent, a form, or a test.

### 2. Build the Cause-Effect Graph  *(Coalton ADT — `elenchon/ceg`)*
A boolean graph wiring causes to effects through `AND` / `OR` / `NOT`, plus the
classic **constraint vocabulary**:

| Constraint | Among | Meaning |
|---|---|---|
| `E` (exclusive) | causes | at most one true |
| `I` (inclusive) | causes | at least one true |
| `O` (one-only) | causes | exactly one true |
| `R` (requires) | causes | a true ⇒ b true |
| `M` (masks) | effects | a true ⇒ b suppressed |

This is a textbook algebraic data type — the reason the core is Coalton. The graph
is *the* formal object; everything upstream feeds it and everything downstream
reads it.

### 3. Reason to a minimal decision table  *(the reasoning system — `elenchon/reason`)*
Each column of the decision table is a **functional variation** — a complete
true/false assignment of causes with its resulting effects — i.e. one test case.
The reasoning system seeks the **minimum number of columns that still demonstrates
each cause *independently* drives its effect**. That independence criterion is
essentially **MC/DC** (Modified Condition/Decision Coverage): flip one cause,
hold the rest, show the effect changes. Minimum tests, maximum requirement-logic
coverage — the whole value proposition. This is the heart of Elenchon: a **reasoning
system over the CEG**, not just a table generator.

Candidate engines (a headline vision question) — behind a neutral protocol so any
can plug in:
- **(a) Relational / miniKanren** — express the CEG as relations and let a
  miniKanren-style logic engine search for the covering assignments. A natural fit:
  the CEG *is* a set of logical relations, and minimality is a search over models.
  A leading candidate for the reasoning core.
- **(b) Classic Bender/Myers table-walk** — the self-contained algorithm from the
  literature, in Coalton.
- **(c) SAT/SMT** — FFI to a mature solver, reducing coverage to constraint
  satisfaction; best for scale.

### 4. Render test cases + traceability  *(`elenchon/cases`)*
Emit each column as a concrete functional test case, each **traceable back to the
originating requirement and the causes/effects it exercises**. Traceability is not
a nicety here — it is what makes the coverage claim auditable.

### Cross-cutting: the requirement-defect report  *(`elenchon/report`)*
Graphing is a forcing function: causes with no path to any effect, effects with no
cause, contradictory constraints, and requirements that can't be reduced to
yes/no propositions all fall out as **ambiguity / incompleteness / contradiction**
findings. Surfacing these early — before a line of code — is often worth more than
the generated tests.

---

## Why this fits the ecosystem

- **Coalton typed core** — the CEG and the reasoning system are pure logic over an
  ADT: the strongest possible case for Hindley–Milner types. No IO in the core.
- **A framework, not an application** — Elenchon is the reusable RBT/CEG *engine*.
  The *application* is a consumer above it (praxeon's ChatRBT), which does the
  natural-language work and drives Elenchon's API.
- **Dependency direction** — Elenchon sits at
  `aion → cons → mnemosyne → **elenchon** → hyperion → praxeon`; it may depend
  **only leftward** (aion for collections; mnemosyne later to persist CEGs/projects).
  It must **never** depend on praxeon/hyperion — which is exactly why the agentic
  NL→CEG extraction lives above it, not inside it.
- **Neutral protocols** — the reasoning engine (miniKanren / table-walk / SAT-SMT)
  is pluggable behind one protocol; so is the CEG-building API the consumer calls.

---

## Positioning & prior art

- **Bender RBT / SoftTest** — the commercial methodology and tool this descends
  from; the target to match on rigor, then exceed on openness + AI-assisted
  extraction.
- **Myers, cause-effect graphing** — the original technique.
- **MC/DC** (DO-178C) — the coverage criterion the minimal-set generator targets.
- **Classification-tree / combinatorial (pairwise) tools** — adjacent black-box
  test-design methods; useful contrasts, not the same thing.

*(Snapshot at founding, 2026-07. Refine the constraint semantics and the coverage
target against the RBT literature before hardening the solver.)*
