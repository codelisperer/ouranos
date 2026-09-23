# AGENTS.md — codelisperer framework conformance

This project builds on the **codelisperer** frameworks (Common Lisp + Coalton). Any AI
assistant (Claude, Codex, Cursor, ...) writing code here MUST follow the rules below so its
output conforms to the frameworks. This file is tool-neutral and canonical; CLAUDE.md and
.cursor/rules point back to it. Keep it loaded.

## The frameworks (dependency DAG, low to high)

`aion -> cons -> mnemosyne -> elenchon -> hyperion -> praxeon`

- aion — Coalton-first functional standard library.
- cons — project & dev tooling (cargo for Lisp).
- mnemosyne — data / persistence (Postgres-wire; PG or XTDB 2).
- elenchon — CEG engine + reasoning for requirements-based testing.
- hyperion — HTMX-first web framework.
- praxeon — agentic-AI framework.

Plus **hermes**, a satellite leaf-lib outside the linear DAG: external integrations —
neutral email + SMS (`deliver`/`send`; SendGrid/Twilio + a dev transport, signature-verified
inbound SMS), payments later. It depends only on aion (plus external HTTP/JSON libs) and
never on mnemosyne / hyperion / praxeon; nothing in the core DAG depends on it. Apps consume
it directly.

A framework NEVER depends on one to its RIGHT (ASDF errors on cycles). Auxiliary systems may
reach right if acyclic; core systems may not. Combined apps live in the highest framework
they need.

## House style (every framework)

- Typed **Coalton** core + effectful **CL/CLOS** shell. **No IO in Coalton.**
- Pluggable backends behind **neutral protocols** (a generic function or Coalton class);
  recoverable failure via the **condition system**, not return codes.
- Small pure functions, effects at the edges, **ADTs over booleans**.
- **Package-per-module**; `:local-nicknames` over long prefixes.
- Avoid `FORMAT` `~<newline>` line-continuations in control strings — a CRLF checkout turns
  them into an illegal `~<Return>` directive (a compile-time error). Write the string on one
  line, or concatenate. (Line endings are LF everywhere via `.gitattributes`.)
- 2-space indent, no trailing whitespace.

## Coalton gotchas (compile-time; easy to get wrong)

- Function-type declarations are **uncurried, separated by `*`**: `(declare f (A * B -> C))`.
  Writing `(A B -> C)` reads as a type application and fails with a Kind mismatch; a curried
  `(A -> B -> C)` reads as a one-arg function (arity mismatch). `define-class` method
  signatures follow the SAME rule: `(with-meta (:a * Meta -> :a))`, not `->`. Single-arg
  types use a bare `->`.
- Coalton is **case-insensitive**: a constructor `Foo` collides with a function `foo`.
- **Reserved names** — do not shadow: continue, Fail, Some, None, Ok, Err, Tuple, map, into.
- `match` on a **nullary constructor needs parens**: `((None) ...)`, not `(None ...)`.
- `cond` clauses end with `(True expr)`; boolean literals are `True` / `False`.
- Coalton `define`d functions are **callable from CL** with CL scalars — that is the
  boundary. Expose CL-facing constructors + total accessors for the effectful shell.

## Data layer (mnemosyne)

- Queries are **data, not macros**. `mnemosyne/query:sql` compiles a plist to a parameterized
  SQL string + bound params (injection-safe): a keyword/symbol is an identifier, anything
  else is a bound value. Example: `(:select (:id :email) :from (:users) :where (:= :email x))`.
  Joins, subqueries, aggregates, RETURNING, and ON CONFLICT upserts are supported; `parse`
  is the inverse (round-trippable). Reach the long tail with `(:raw ...)`.
- Schemas: `mnemosyne/schema:defschema` names a table + typed fields; `schema-ddl` derives
  the CREATE TABLE (feeds a migration — do not hand-write the DDL twice).
- External input goes through a **changeset**: `cast` (takes only permitted fields — safe
  mass-assignment) then `validate-*` then `insert!` / `update!`. Raw params never reach SQL
  uncast.
- **XTDB 2** is a distinct dialect: no DDL (schemaless), INSERT already upserts on `_id` (no
  ON CONFLICT), no RETURNING. The builder signals for those under the `:xtdb` dialect.

## Web layer (hyperion)

- Server-rendered **HTMX** + **Spinneret**; **Parenscript** for any JavaScript (no Node); a
  typed HTMX vocabulary in Coalton. Ship **generic** components only — never domain-specific
  ones. Sessions live behind a `store` protocol (in-memory, or a mnemosyne-backed durable store).

## Build / test (no external build tools)

- Once at the repo root: `sbcl --dynamic-space-size 4096 --script bootstrap.lisp`. It writes
  an ASDF `(:tree)` source-registry drop-in, so every REPL finds the tree — no symlinking.
- Then `(ql:quickload :NAME)`; the first Coalton load compiles (minutes; cached after).
- Tests are **fiveam**: `(asdf:test-system :NAME)`.
- No make / just / npm — `sbcl --script` is the uniform driver. SBCL-only by design.

## Before proposing code

- [ ] Effects/IO in the CL shell, not in Coalton.
- [ ] New module → its own package (package-per-module, `:local-nicknames`).
- [ ] New `:depends-on`? update `docs/dependencies.md` — dependencies are held to a conscious
      minimum.
- [ ] Respect the DAG: no dependency on a framework to the right.
- [ ] 2-space indent, no trailing whitespace.
