# CLAUDE.md — Praxeon

Tree-wide rules are in the root `CLAUDE.md`/`AGENTS.md`, loaded with this file. Only
praxeon-specific notes here.

## What this is

A CL + Coalton framework for agentic systems, targeting the orchestration and
context-management layer — not the tensor path. Thesis in `README.md` and `paper/`.

## The model (praxeology)

`End` (goal), `Means` (tool), `Action` (applying a means toward an end), `Plan`, `Actor`.
Use this vocabulary, not "chain/node/runnable". The scarce resource an agent economises is
the context/token budget. The name is **Praxeon**, not "Praxis".

## Layout

```
src/praxeology.lisp   Coalton-typed ontology (End/Means/Action/Plan/Actor)
src/conditions.lisp   retry-action / substitute-result / abandon-action restarts
src/context.lisp      budgeted, bitemporal context — seed of Kairos
src/llm.lisp          provider protocol; anthropic + openai-compatible
src/actor.lisp        deliberate -> act loop; means registry
examples/elise/       Elise, the PoC agent
```

## Design facts

- The LLM layer is one generic, `praxeon/llm:complete`; a provider is a new class, never a
  special case in the loop. Provider-neutral is a hard constraint.
- Failure/approval is the condition system: restarts around every application of a means.
- `praxeon/ceiling` (pre-publication issue 172): per-session token/call cap in an Ed25519-signed grant, enforced
  before the model call. **Means are assembled from the grant's capabilities** — a means the
  caller lacks is absent from the tool table, and the refusal is indistinguishable from "no
  such means" (#90). Don't reintroduce prompt-side filtering.
- `praxeon/workflow` and `register-agent-as-means` exist and are unit-tested; **no
  application uses either yet** (#100 would be the first). `Plan` is a type the loop does
  not yet construct.

## Gotchas

- Provider/model/key come from `PRAXEON_LLM_*` in a git-ignored `.env` (`.env.example`).
- Current Claude models reject a non-default `temperature`; the provider omits it.
- Reasoning models truncate the deliberate step at the default budget — bind
  `praxeon/llm:*default-max-tokens*` higher.
- hermes is a satellite: anything an agent sends or stores externally reaches praxeon as
  an injected seam, never a dependency.

## Where to look

`docs/user-guide.md` · `docs/comparison.md` · skills `add-means`, `repl-workflow`,
`coalton-conventions` · [`../docs/wiki/Framework-Praxeon.md`](../docs/wiki/Framework-Praxeon.md).
