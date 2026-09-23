# Hyperion

**A full-stack web framework for Common Lisp, biased toward the live image.**

Hyperion is what you reach for when you want to build a *reactive* web application
in Common Lisp without a Node.js toolchain in sight — the server renders, HTMX
drives the interactivity, and the browser refreshes itself while you edit the
running program.

Hyperion is one of six co-evolving core frameworks in the
[Ouranos monorepo](../README.md), plus `hermes`, a satellite leaf-lib (external
integrations — email/SMS, later payments).
It is a **library only** — creating, building, and running Hyperion apps is the job of
`cons` (the ecosystem's "cargo for Lisp"), not a Hyperion CLI. In dependency order the
siblings are `aion` → `cons` → `mnemosyne` → [`elenchon`](../elenchon) →
**`hyperion`** → [`praxeon`](../praxeon) (which uses Hyperion for its web surface);
`hermes` sits outside that line, depending only on `aion`. An app that needs to send
email or SMS (password reset, notifications, 2FA codes) uses `hermes`, not a
Hyperion-local integration.
See the [root README](../README.md) and [`../ECOSYSTEM.md`](../ECOSYSTEM.md) for the
full ecosystem overview and governance.

## Thesis

The modern web frontend is drowning in JavaScript build tooling. **HTMX** showed
that most of that complexity is unnecessary: hypermedia + a server that renders
fragments gets you a long way toward SPA-grade interactivity. Common Lisp is an
unusually good host for that model — it has the macros to make an ergonomic HTML
DSL, the condition system for legible failure, and, decisively, a **live image**:
you can redefine the running program and watch the change appear.

Hyperion leans into all of it, with a bias toward **full-stack Common Lisp**:

1. **HTMX instead of templating.** The server renders HTML fragments; HTMX swaps
   them. Hyperion provides typed, composable coverage of HTMX's *feature surface*
   (swaps incl. OOB, triggers, targets, boosting, `hx-vals`/headers, indicators,
   history, SSE/WS extensions) — **generic components and wiring, never
   domain-specific ones**.
2. **Parenscript for all JavaScript.** No hand-written JS, no Node. What little
   client code is needed is authored in Lisp and compiled to JS.
3. **A CSS DSL.** Generate CSS from Lisp; interoperate with Bulma/Tailwind
   *without* Node tooling.
4. **REPL-driven development.** A Figwheel-style hot-reload loop — edit, save, the
   server rebuilds around preserved state, the browser refreshes itself, and a
   compile error shows as a browser overlay. It can watch **multiple systems at
   once** (co-develop an app and the framework together), with top-tier editor
   integration. Project scaffolding and build/run commands come from `cons`.

## Architecture (the common core)

- **Typed core in Coalton; effectful shell in Common Lisp.** The *ontology* of an
  HTMX interaction (a `Swap`/`Trigger`/`Target`/`Verb` value, a `Duration` that
  makes `"700ms"` unspellable-wrong) is a compile-time-checked Coalton value;
  *rendering and extensibility* live in CLOS + Spinneret. (Coalton does static
  typeclass dispatch — it is **not** CLOS under the hood; it interoperates with CL
  at the boundary.)
- **Pluggable backends behind neutral protocols** — the house style across every
  project in the tree. Here: the web server (Woo / Hunchentoot behind Clack).

## Status

**Pre-alpha (0.0.0), but no longer vacant.** A working web core has been extracted
from `praxeon/src/web.lisp` and expanded: the configurable server, the hot-reload
dev loop (with a compile-error browser overlay), request/response utilities, a
typed HTMX vocabulary (Coalton) + render bridge, Parenscript interaction helpers,
**i18n** (per-request locale — drop a `<code>.json` file to add a language), static
serving, safe Markdown, and a one-knob output style (dev pretty / prod compact) —
plus a **typed, Pedestal-style interceptor pipeline** in Coalton (`Flow` + `execute`
+ `execute-effect` — *effects at the edge*; parametric over the context, so one
shape serves HTTP **and** agentic-AI). **Praxeon already runs
on it** — dogfooding the i18n and the pipeline (Elise converses in the user's
locale; her crisis guardrail is the first real interceptor chain).

**Routing** landed too, split the same way (ADR-0012): `hyperion/path` types the path
template in Coalton (a `Segment` is a `Literal`, a `Param` — `:id` — or `Rest` — `*`),
and `hyperion/router` owns dispatch in CL, where the handlers and the Clack env are.
`/contacts/:id` is expressible, `mount` nests a sub-router so a framework module can
*contribute* routes instead of an app retyping them, and the table is **data** —
`describe-routes` prints it. Two things fall out of asking "does the path match" and
"does the method match" separately: **405** with a computed `Allow` (a hand-rolled
`cond` cannot tell that from a 404 even in principle), and **HEAD/OPTIONS derived
rather than declared**, so they cannot drift from the routes they describe. 86 checks.
Nothing in the tree is ported onto it yet — [#132](https://github.com/codelisperer/ouranos/issues/132).

Two **opt-in, mnemosyne-backed** systems sit beside the core so that hyperion itself keeps
no database dependency: **`hyperion/session-db`** (a durable session STORE behind the same
protocol as the in-memory one, 15 checks) and **`hyperion/auth-db`** (a users + password
identity store over `ironclad`, 72 checks). Neither is pulled by `hyperion`; an app that
wants persistence depends on them directly. See
the [Roadmap board](https://github.com/orgs/codelisperer/projects/1)
([`label:pkg:hyperion`](https://github.com/codelisperer/ouranos/issues?q=is%3Aissue+is%3Aopen+label%3A%22pkg%3Ahyperion%22))
for status, [`../docs/wiki/Framework-Hyperion.md`](../docs/wiki/Framework-Hyperion.md) for
the design narrative, `docs/user-guide.md` to use it (incl. the i18n and
"Interceptors, reimagined" chapters), and `docs/adr/` for the decisions. Still
ahead: the CSS DSL, a component library, session/auth + security
middleware, and the desktop story.

## Getting started

This framework is one of six core frameworks (plus the `hermes` satellite leaf-lib) in
the [Ouranos monorepo](../README.md); you build the whole tree, not this directory
alone. Prereqs: **SBCL + Quicklisp + Coalton** — the last a **pinned git checkout**, not a
Quicklisp system; `scripts/setup.sh` installs all three (see `coalton.pin`),
plus `libev` (Woo).

    git clone https://github.com/codelisperer/ouranos.git
    cd ouranos
    sbcl --dynamic-space-size 4096 --script bootstrap.lisp   # → bin/cons

`bootstrap.lisp` points ASDF at the whole tree and writes a source-registry drop-in, so
every REPL can find the frameworks with no symlinking. From any SBCL REPL:

    (ql:quickload :hyperion)   ; first load compiles Coalton — minutes, then cached

`bin/cons build | test | serve | run` is the intended one-command interface (in
progress; today `cons` implements `init` / `setup` / `conform` / `env` / `db-repl` / `db-url` / `template check` / `version`). The **hot-reload dev
loop**, output-style, and the reload/restart nuances are covered in
[`docs/user-guide.md`](docs/user-guide.md).
