# Elenchon — User Guide

> **Pre-alpha (0.0.0).** The **typed Cause-Effect Graph ADT is built** (`src/ceg.lisp`,
> 46 checks) and the ten founding design questions are settled in five ADRs
> ([`docs/adr/`](../docs/adr/README.md)). The *reasoning system* — CEG to minimal decision
> table — is not. This guide grows as the rest of the pipeline lands. For *what* is being
> built and *why*, read `docs/method.md` (the design brief) then `docs/roadmap.md`.

## What Elenchon is

**The Cause-Effect Graph engine + reasoning system for Requirements-Based Testing**
(Bender RBT lineage). You give it a *structured* Cause-Effect Graph (causes,
effects, and the E/I/O/R/M constraints); it **reasons** over the graph — a
relational solver, miniKanren a leading candidate — for the *minimum* set of
functional test cases that covers the *maximum* share of the requirement's logic,
and hands back those tests plus a requirement-defect report. The name (ἔλεγχος,
"cross-examination") is the method: it interrogates your requirements.

> Turning ambiguous prose into a CEG is **not** Elenchon's job — that's an agentic
> function *above* it (praxeon's **ChatRBT**), which feeds Elenchon a structured
> graph. Elenchon does CEG crunching + reasoning; it can be driven by an agent, a
> form, or a test.

## Install / run

Elenchon is one of six core frameworks (plus `hermes`, a satellite leaf-lib) in the
[Ouranos monorepo](../../README.md); you
build the whole tree, not this directory alone. Prereqs: **SBCL + Quicklisp**
(Coalton is a **pinned git checkout**, not a Quicklisp system; `scripts/setup.sh` installs
all three — see `coalton.pin`).

```sh
git clone https://github.com/codelisperer/ouranos.git
cd ouranos
sbcl --dynamic-space-size 4096 --script bootstrap.lisp   # → bin/cons
```

`bootstrap.lisp` points ASDF at the whole tree and writes a source-registry drop-in,
so every REPL finds the frameworks with no symlinking. From any SBCL REPL:

```lisp
(ql:quickload :elenchon)
(elenchon:version)        ;; => "0.0.0"
```

First load compiles Coalton (a minute-ish; cached afterward). If you hit
`Heap exhausted`, you started SBCL without the larger heap — pass
`--dynamic-space-size 4096` (as the bootstrap line above does).

## What you'll be able to do (planned)

Once the pipeline lands, the intended REPL-first shape (subject to the vision Q&A).
Elenchon takes a **structured** CEG — causes, effects, and their boolean wiring
already extracted. Turning the prose *"If the account is overdue AND the customer is
not exempt, apply a late fee and send a notice"* into that structure is the agentic
consumer's job (praxeon/ChatRBT), **above** Elenchon; here we build the CEG directly:

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

See `docs/roadmap.md` for the thread order (start = the typed CEG ADT) and
`docs/elenchon-vision.md` for the open design questions (reasoning engine —
miniKanren vs table-walk vs SAT/SMT, the CEG-building API contract, output formats).

## See also
- `docs/method.md` — the pipeline and vocabulary (causes/effects/constraints).
- `docs/roadmap.md` · `docs/elenchon-vision.md` · `docs/editor-setup.md` · `CLAUDE.md`.
