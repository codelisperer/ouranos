# CLAUDE.md -- klio

Project constitution for Claude-enabled editors. Always loaded, so keep it light: anything
not specific to THIS project belongs in AGENTS.md, not here.

@AGENTS.md

**AGENTS.md** (imported above, installed by `cons init` / `cons conform`) is canonical --
the DAG, house style, Coalton gotchas, the data layer, build/test, the evidence rules, and
the no-AI-trailer rule for commits. Follow it; do not restate it here.

## What this is

klio -- TODO: one-paragraph description.

## Project-local notes

- Config/env via cons: secrets in `.env` (gitignored), every key documented in
  `.env.example`, loaded with `cons/env:load-dotenv`.
- TODO: the decisions a newcomer would otherwise reverse-engineer from the code.
