# CLAUDE.md — dokimasia

Tree-wide rules are in the root `CLAUDE.md`/`AGENTS.md`, loaded with this file. Only
dokimasia-specific notes here.

## What this is

A data-driven acceptance-test harness for any app that runs in a browser. An app writes
cases as data: steps, plus rows of inputs with the screens and stored values each row
should produce. dokimasia runs them in a headless Chrome or Edge, against an app it starts
or a deployed URL, and reports each case and row as one FiveAM test.

A satellite library attached at `aion`. The core system `dokimasia` depends only on aion
and external libraries, and never on hyperion, mnemosyne, elenchon or praxeon. Nothing in
the dependency line depends on dokimasia. The parts that know about one framework are aux
systems, which may reach right:
- `dokimasia/hyperion`: the htmx-settled check, a hyperion app on a scratch database, and
  seeded sign-in;
- `dokimasia/mnemosyne`: stored-data probes through mnemosyne;
- `dokimasia/elenchon`: cases derived from an elenchon decision table.

The design is [ADR-0001](docs/adr/0001-browser-driver-and-acceptance-harness.md), and the
work is tracked on #1028 (label `pkg:dokimasia`). Step b1 is the harness against a URL or a
started app: `dokimasia/core` (the verdict, in Coalton) and `dokimasia` (definitions, targets,
steps, the checks after every step, the report and the run). The user guide is
[`README.md`](README.md). Step b2 adds the `:audit` step, which runs the vendored axe-core
(`vendor/`, pinned in `vendor/ASSETS.pin`) in the page once for each colour scheme. Step b3's
first part is `dokimasia/mnemosyne` (`src/mnemosyne/`): `define-row-probe` and
`define-query-probe`, stored-data probes that read the app's database through mnemosyne. Its
tests use a SQLite file and no browser. `dokimasia/hyperion` has not landed.

## Design facts

- **The browser driver is not here.** It is `aion/cdp`, over `aion/websocket`, so that
  frameworks in the line (praxeon) can use it too. dokimasia decides what a test is; the
  driver decides nothing.
- **Headless only.** `aion/cdp:launch-browser` cannot start a browser with a window, and
  refuses arguments that would change that. Do not add a way around it.
- **Close what you launch.** Use `with-browser`, or `close-browser` in an `unwind-protect`.
  Before a change runs a browser on the maintainer's machine for the first time, tell the
  hub.
- **Not run is never passed.** A step that cannot run against a target, such as a
  stored-data probe with no HTTP form against a deployed URL, is reported as not run with
  its reason.
- **A missing browser skips locally and fails on CI.** CI sets `OURANOS_REQUIRE_BROWSER=1`.

## Where to look

[`docs/adr/`](docs/adr/README.md) · #1028 · `aion/cdp` and `aion/websocket` ·
`src/core/core.lisp` (the verdict rule) · `src/run.lisp` (one FiveAM test per case and row) ·
`tests/server.lisp` (the HTTP app the browser tests run against).
