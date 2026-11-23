# dokimasia — acceptance tests for any app in a browser (satellite)

dokimasia checks an app the way a user meets it: in a real browser, through its pages. An app
writes its acceptance tests as data. A case is a list of steps, and its rows give the inputs and
the results each input should produce: the screen the app reaches, the text it shows, and the
values it stores. dokimasia runs every case and row in a headless Chrome or Edge, against an app
it starts or one already running, and writes a report with screenshots.

Named for the Athenian *dokimasia*, the examination a citizen passed before taking office.

The user guide, with a getting-started walk-through, is
[`dokimasia/README.md`](../../dokimasia/README.md). The design is
[ADR-0001](../../dokimasia/docs/adr/0001-browser-driver-and-acceptance-harness.md), and the work
is tracked on #1028.

---

## What it is, and why it exists

Apps want to know in CI, without waiting for human testers, that each user flow works: given
these inputs, the app reaches these screens and stores this data. The checks the tree had before
dokimasia all worked at the HTTP level. A consuming app reported three failures that HTTP-level
checks cannot see:

- a script whose fetch, poll or resubmit cycle goes wrong;
- a script that the Content-Security-Policy blocks, which shows only in the browser console;
- an htmx swap that loses the user's scroll position.

Two apps had each written their own browser harness with Node and `puppeteer-core`, and a third
was waiting for the framework to provide one. dokimasia is that harness, in Common Lisp, with no
Node.

It checks **any** app that runs in a browser, not only apps built on Ouranos. The maintainer
ruled this on 2026-11-17, when the first draft placed the harness inside hyperion. An app on
another stack loads only the core system, points a `url-target` at the app, and writes its cases
in Lisp.

### What a run checks without being asked

Besides the steps a case writes, the runner checks after every step, and fails the step when it
finds:

- a console error, a failed `console.assert`, an uncaught exception, or a log entry at error
  level, which includes Content-Security-Policy violations;
- a response with status 500 or more from the app's own origin;
- more than 20 requests to one URL during one step, which catches a fetch, poll or resubmit
  loop.

These are the failures from the list above. A case does not have to remember to look for them.

### What it does not do

- It does not judge usability. That still needs people.
- It does not compare screenshots between runs yet. The fixed file layout and the masks are what
  will make that possible.
- It never opens a browser window. The headless guarantee is in the driver, `aion/cdp`, which has
  no argument that removes `--headless=new` and refuses arguments that would.

---

## Where it sits in the DAG

dokimasia is a **satellite**, like hermes. It attaches at `aion`, and nothing in the line depends
on it:

```
aion → cons → mnemosyne → elenchon → hyperion → praxeon        (the core DAG)

dokimasia  ──core system depends only on──▶  aion  +  external libs
```

The parts that know about one framework are **aux systems**, and an aux system may reach right,
as long as the system-level graph stays acyclic:

| System | Reaches | What it adds |
|---|---|---|
| `dokimasia/core` | `coalton` only | The typed verdict of a row, in Coalton: the function that combines step results into passed, failed at a step, or not run. |
| `dokimasia` | `aion` (`aion/cdp`, `aion/sexp`, `aion/csv`, `aion/secret`, `aion/log`, `aion/boundary`), `com.inuoe.jzon`, `fiveam` | The core: screens, cases, suites, probes, `url-target` and `process-target`, the steps, the checks after every step, the axe-core audit, the run and the report. |
| `dokimasia/mnemosyne` | right, to `mnemosyne` | `define-row-probe` and `define-query-probe`: stored-data probes that read the app's database. |
| `dokimasia/hyperion` | right, to `hyperion` and `mnemosyne` | `hyperion-target`: starts a hyperion app on a free port with a scratch SQLite database, waits for htmx in its settle check, and can sign a user in with a session in the app's store. |
| `dokimasia/elenchon` | right, to `elenchon` | **Not built.** It will turn an elenchon decision table into rows, each keeping its requirement id. It waits until `elenchon/cases` exists (#28), which comes after elenchon's reasoning engine (#26) and its report (#29). |
| `dokimasia/examples/active-search` | right, to `hyperion/examples/active-search` | The worked example. |

**Why the browser driver is in aion, not here.** Nothing in the line may depend on a satellite,
and praxeon needs a browser too: `praxeon/web-page` reads pages over HTTP and cannot read a page
that builds its content with JavaScript. So the driver is `aion/cdp`, over `aion/websocket`, and
praxeon and dokimasia both use it. dokimasia decides what a test is; the driver decides nothing.

**Why not elenchon.** Elenchon has no IO, and a browser run is mostly IO. Elenchon reaches the
browser through data instead: its decision table, rendered by `elenchon/cases`, becomes
dokimasia rows in `dokimasia/elenchon`.

---

## Current status

Working today, and run by the gate on Linux, macOS and Windows:

- the harness: cases, rows inline or from CSV or Lisp data files, the steps, the checks after
  every step, the report, one FiveAM test per case and row;
- the `:audit` step, with axe-core 4.14.0 vendored and pinned;
- the browser started over a pipe by default, so it opens no debugging port;
- `dokimasia/mnemosyne` and `dokimasia/hyperion`;
- the worked example, whose report and screenshots CI uploads for each leg.

Open work is on the [board](https://github.com/orgs/codelisperer/projects/1) under the label
`pkg:dokimasia`. The dark-scheme audit of the worked example is skipped until #1281 sets
hyperion's dark colour for grey text.

---

## Design narrative

### A case is data

An app writes its cases as s-expressions: steps, rows and screens. A step of an unknown kind,
or with the wrong arguments, is refused when the case is defined, not halfway through a run. A
row file with a short line or code in it is refused the same way. The same data can therefore
come from somewhere other than a person typing it, which is how `dokimasia/elenchon` will work:
elenchon derives the rows, and the app supplies how each cause becomes an input and each effect
becomes a check.

### Not run is never passed

A step that cannot run against a target is reported as **not run**, with its reason, and never as
passed. The main case is a stored-data probe. A probe's local form reads the app's store from the
test image, so against a deployed URL it cannot run unless the caller says the store is
reachable (`:local-probes t`). A suite against staging therefore reports exactly what it could
not check.

### A missing browser skips locally and fails on CI

Without a browser each test is skipped, with the reason, so a developer's machine without Chrome
still runs the rest of the gate. With `OURANOS_REQUIRE_BROWSER=1`, which CI sets, a missing
browser fails instead, so a runner without one cannot report green.

### Screenshots a later run can be compared with

Screenshots go to `<case>/<row>/NN-name-viewport-scheme.png`, beside `report.json` and
`report.txt`, so a CI job can upload one directory. Before capturing, the runner grows the
viewport to the full height of the page. Masks hide elements by selector and replace text that
matches patterns, such as clocks and temporary paths, so a second run's images match the
first's.

### Accessibility in each colour scheme

`:audit` runs axe-core once for each colour scheme of the run, so contrast is checked on the
colours the page shows in each. The worked example found a real defect this way: in the dark
scheme, some of the example page's text falls below WCAG AA contrast, in colours hyperion does not
yet set (#1281).

---

## Usage

The getting-started section of [`dokimasia/README.md`](../../dokimasia/README.md) takes an app
from nothing to a suite in CI. It covers screens, cases and suites, the three ways to give rows,
the targets, the stored-data probes, screenshots and masks, the audit, the report, and CI with
an artifact upload. Every code sample there is copied from a file the gate runs, and names that
file.

The shape of a suite, from the worked example
([`dokimasia/examples/active-search/acceptance.lisp`](../../dokimasia/examples/active-search/acceptance.lisp)):

```lisp
(d:define-screen contacts
  :path "/"
  :present '("#q" "#results"))

(d:define-case search-contacts
  :requirement "SEARCH-1"
  :rows (:file "rows/search.csv")
  :steps ((:visit "/")
          (:expect-screen contacts)
          (:fill "#q" (:input :query))
          (:expect-text "#results tr:first-child td:first-child" (:input :first))
          (:expect-text "p.help" (:input :echo))))
```

---

## Roadmap

- **`dokimasia/elenchon`**, once `elenchon/cases` exists (#28).
- **Screenshot comparison** between runs.

A suite runs from the command line with `cons acceptance SYSTEM=… SUITE=…` in `dokimasia/`, and an
app copies that target into its own `cons.lisp` (#1028). The dokimasia README's Getting started,
section 9, has the parameters and exit codes.

Open issues: https://github.com/codelisperer/ouranos/issues?q=is%3Aissue+is%3Aopen+label%3A%22pkg%3Adokimasia%22

---

## See also

- [Home](Home.md): the ecosystem overview and the DAG rule
- [Framework Aion](Framework-Aion.md): where the browser driver, `aion/cdp`, lives
- [Framework Hyperion](Framework-Hyperion.md): the apps `dokimasia/hyperion` starts
- [Framework Mnemosyne](Framework-Mnemosyne.md): the databases `dokimasia/mnemosyne` reads
- [Framework Elenchon](Framework-Elenchon.md): where derived test cases will come from
- In the repository: `dokimasia/README.md`, `dokimasia/docs/adr/`, `dokimasia/examples/active-search/`
