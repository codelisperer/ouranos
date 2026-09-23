# CLAUDE.md -- contacts

Project constitution for Claude-enabled editors. Always loaded. Keep it lean.

@AGENTS.md

The codelisperer framework conformance spec is in **AGENTS.md** (imported above; installed
by `cons conform`) -- follow it. Project-specific notes below.

## What this is

contacts -- a console example that demonstrates the **mnemosyne migration lifecycle** (apply /
rollback / status) plus add/list over SQLite, with rows stamped by `mnemosyne/id:touch!` and
queried with the data-driven query builder. It consumes mnemosyne; `cons run` starts it.
Scaffolded by `cons init` (dogfooding the tooling), then adapted.

## House style

- Typed/pure core where it earns its keep; effects at the CL edge.
- Package-per-module; `:local-nicknames`; conditions for recoverable failure.
- 2-space indent, no trailing whitespace.
- Config/env via cons: secrets in `.env` (gitignored), keys documented in
  `.env.example`, loaded with `cons/env:load-dotenv`.
- REPL-driven development; docs-as-handoff.
