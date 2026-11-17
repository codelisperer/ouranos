# ADR-0021 — A browser driver in aion, and a data-driven acceptance-test harness in hyperion

**Status:** Proposed — 2026-11-17. Step 1 of
[#1028](https://github.com/codelisperer/ouranos/issues/1028). The route was ruled by the
maintainer on 2026-11-16 (issue comment 6935439985): the Chrome DevTools Protocol (CDP),
driven from Lisp, against the runner's installed Chrome or Edge, with no Node and no pinned
browser download. The order of work is in comment 6949634761. This ADR settles the two
questions that ruling left open: which framework the driver goes in, and what an app sees
of the harness.

## Context

Apps want to check, in CI and without waiting for human testers, that each user flow works:
given these inputs, the app reaches these screens and stores this data. The checks that pass
today are all at the HTTP level. They cannot see three failures a consuming app has
reported: a script whose fetch, poll or resubmit cycle goes wrong; a script that the
Content-Security-Policy blocks, which shows up only in the browser console; and an htmx swap
that loses the user's scroll position. Two apps have each written their own browser harness
with Node and `puppeteer-core`, and a third is waiting for the framework to provide one.

What the tree has now:

- `hyperion/tests/htmx-smoke-tests.lisp` (#717) finds the runner's Chrome or Edge
  (`%smoke-browser`), runs it with `--headless --dump-dom`, and reads the DOM it prints. It
  cannot click, wait for a condition, or take a screenshot. These functions are private to
  the package `hyperion/assets/tests`, and `praxeon/tests` reaches into that package with
  `::` to reuse them.
- `hyperion/websocket` (#376) is a WebSocket frame codec and server handshake with no
  dependencies. Its `encode-frame` takes a `:mask-key`, which a client needs, and its
  `parse-frame` accepts unmasked frames with `:masked nil`, which is what a server sends. It
  has no client half of the handshake. It has only appeared under Unreleased in the
  CHANGELOG, so no release carries it.
- `hyperion/test-ports` finds a free port, and `call-with-port` retries when the port is
  taken.
- `hyperion/assets/vendor/` holds htmx with its licence and an `ASSETS.pin` entry carrying
  the version, SHA-256 and review date. This is the model for vendoring axe-core.
- Elenchon has no IO. Its output is data: ADR-0004 makes the `Draft`/`Outcome` types the
  boundary and defers executable test stubs. The prose in `ECOSYSTEM.md` and
  `docs/wiki/Contributing.md` already sanctions an edge from a hyperion testing system to
  elenchon. No such system exists yet.

The placement rule in `ECOSYSTEM.md` (pre-publication issue 117) separates a binding from a
decision. A faithful binding to an external interface, whose specification is someone
else's documentation, goes in aion, because everything that might use it is to aion's
right. A layer that makes choices the interface does not make goes where its domain is.

## Decision

### 1. The driver goes in aion, as two opt-in systems

**`aion/websocket`.** `hyperion/websocket` moves to aion unchanged, and gains the client half
of the handshake:
- generating the `Sec-WebSocket-Key` with `aion/random`;
- checking the server's `Sec-WebSocket-Accept`.

`hyperion/server-uv/websocket` then depends on `aion/websocket`. No hyperion system of that
name is kept, because no release has shipped one. The move gets a CHANGELOG entry naming
the old and new system and package names.

**`aion/cdp`.** A CDP client: launching or attaching to a browser, sessions, and the
commands and events that tests and agents need. A CDP client is a binding in the sense of
the placement rule. Its specification is Chrome's protocol documentation, and it decides
nothing about what a test is. Its parts:

- **Finding a browser.** `find-browser` replaces the private `%smoke-browser`. It reads
  `OURANOS_BROWSER`, then `HYPERION_SMOKE_BROWSER` so existing CI settings keep working. It
  then searches PATH (with `aion/windows:find-executable` on Windows) and the fixed install
  locations the smoke tests already check. The smoke tests and `praxeon/tests` move to it in
  step 2.
- **Launching.**
  - `launch-browser` starts the browser with:
    - `--headless=new`;
    - a fresh private profile from `aion/fs`;
    - `--remote-debugging-port=0`.
  - It reads the real port and the browser's WebSocket path from the `DevToolsActivePort`
    file that the browser writes into the profile. Port 0 means two runs on one machine
    cannot race for a port.
  - Process lifetime follows `hyperion/sidecar`, so a crashed test image cannot leave a
    browser running:
    - on Windows, a kill-on-close job object (`aion/windows:spawn-in-job`);
    - on Linux, `setpriv --pdeathsig KILL` where available.
  - `close-browser` sends `Browser.close` and then kills the process if it is still running.
    It deletes the profile in both cases.
  - `with-browser` wraps all of this in `unwind-protect`.
- **Attaching.** `attach-browser` takes a `ws://` URL and refuses one whose host is not a
  loopback address, because a CDP port has no authentication.
- **Commands.** `navigate`, `evaluate`, `wait-for` (a JavaScript predicate or a CSS selector,
  with a timeout), `query`, `text-of`, `attribute-of`, `click` (scroll into view, then a
  mouse event at the element's centre), `type-text`, `set-viewport`,
  `emulate-color-scheme`, `screenshot` (PNG octets), and `send` for any other CDP method.
- **Events.** Console messages, uncaught exceptions, log entries (which carry CSP
  violations), and network requests and responses. Each page keeps them in an ordered
  buffer, and a caller drains the buffer between steps.
- **Threads.** One reader thread per connection. It calls `(aion/dynamic:unblock-interrupts)`
  first, routes each response to its waiting caller by message id, and appends events to
  the page's buffer.
- **Failures are conditions.** `browser-not-found`, `browser-exited`, `cdp-error` (the
  protocol's own error object), `cdp-timeout` and `target-crashed`.
- **Dependencies.** `aion/websocket`, `aion/dynamic`, `aion/log`, `aion/fs`, `aion/random`,
  `aion/windows` on Windows, `com.inuoe.jzon`, `cl-base64` and the SBCL contribs
  `sb-bsd-sockets` and `sb-concurrency`. Every one is already loaded somewhere in aion, so
  there is **no new external dependency**.

**The headless guarantee lives in the driver.** `launch-browser` has no argument that
removes `--headless=new`. It refuses extra arguments that set the headless mode, the
remote-debugging port or pipe, or the profile directory, by signalling an error before
anything starts. A test asserts the exact command line. `attach-browser` connects to a
browser someone else started and opens no window. So no function in `aion/cdp` can open a
window on a developer's screen.

**Why not elenchon.**
- Elenchon has no IO, and this driver is mostly IO: a child process, a socket and a reader
  thread. Putting it there would make elenchon's test suite need a browser.
- ADR-0004 keeps elenchon's output as data and leaves execution to whoever consumes it.
  Elenchon still connects to a browser run through that data, as point 3 describes.
- Testing is not the driver's only use. `praxeon/web-page` reads pages over HTTP and cannot
  read pages that build their content with JavaScript, and a CDP read would fix that. Only
  a framework to elenchon's left can serve every consumer, and aion is the one whose
  charter covers bindings.

### 2. The harness goes in hyperion, as `hyperion/uat`

`hyperion/uat` depends on `aion/cdp`, `hyperion`, `hyperion/test-ports` and `fiveam`. Its
pure part, `hyperion/uat/core`, is Coalton, following `praxeon/eval/core`. It holds the
types for a case, a step, a step result and a verdict, and the function that combines step
results into a verdict.

**A case is data.** An app writes cases as s-expressions. Each case has:
- an id and an optional requirement id;
- an optional user to sign in as;
- a list of steps;
- rows of inputs, so that one case runs once per row.

Rows can be written inline, or loaded from an s-expression file (`aion/sexp`) or a CSV file
(`aion/csv`). That way one table of inputs and expected results drives many runs, and a
row can expect an error screen as well as a success.

```lisp
(hyperion/uat:define-screen :dashboard :path "/home" :present "#dashboard")

(hyperion/uat:define-case :sign-up
  :requirement "REQ-7"
  :steps ((:visit "/sign-up")
          (:fill "#email" (:input :email))
          (:fill "#password" (:input :password))
          (:click "button[type=submit]")
          (:expect-screen (:input :expected-screen))
          (:expect-stored :user-exists (:input :email)))
  :rows (:file "uat/sign-up.csv"))
```

**The steps** are `:visit`, `:fill`, `:click`, `:select`, `:wait-for`, `:expect-screen`,
`:expect-text`, `:expect-stored`, `:expect-scroll-kept`, `:screenshot` and `:audit`. A screen
is a named predicate on the path and the elements present. It is defined once and used by
every case.

**Checks that run after every step without being written:**
- **htmx settles.** After an action, the harness waits until htmx has no request in flight
  and has fired `htmx:afterSettle`. It knows this from a small listener it installs with
  `Page.addScriptToEvaluateOnNewDocument`.
- **No console errors.** Any console error, uncaught exception or CSP violation fails the
  step. An app can list known messages to ignore, and each entry names the message.
- **No runaway requests.** The harness records the network requests made during each step.
  A step that makes more than its limit of requests to one URL fails, which catches fetch,
  poll and resubmit loops. A same-origin response of 500 or more fails the step.
- **Client error reports are rate-limited.** If the app names its client-error report
  endpoint, the harness intercepts it with the `Fetch` domain and lets through only a fixed
  number of reports per run.

`:expect-scroll-kept` records the scroll position of the window, or of a named scrolling
pane, before the action and compares it after the swap.

**Targets.** A run has one target.
- **`local-target`** takes functions from the app that build a handler and a fresh scratch
  database, plus a seeding function. The harness starts the app on a free port from
  `hyperion/test-ports`, runs the cases, and stops the app and deletes the database even
  when a case fails.
- **`url-target`** takes a deployed base URL, such as staging after a deploy, and
  credentials from `aion/secret`.

**Stored data.** `:expect-stored` calls a probe the app registers. A probe runs in the
test image against the scratch database, so it only works with `local-target`. Against a
`url-target`, a step with a probe that has no HTTP form is reported as **not run**, with
that reason. It is never reported as passed. The report counts not-run steps separately, so
an app cannot mistake a smaller check for a passing one.

**Sign-in.** An app defines its sign-in once, as steps. By default the harness signs in by
running those steps against the real sign-in form. This works on both targets and goes
through the same-origin guard and CSRF exactly as a user does (ADR-0019). With
`local-target`, an app may instead have the harness create the session in the session store
and set its cookie with `Network.setCookie`. That makes sign-in faster for cases that are
not testing sign-in itself.

**Screenshots.**
- Viewports are `:desktop` (1280×800) and `:phone` (390×844, mobile, scale factor 2), and
  colour schemes are `:light` and `:dark`. A run takes a list of each.
- Before capturing, the harness grows the viewport to the height of the document or of the
  tallest scrolling pane, whichever is larger, so that nothing below the fold is missed.
- Masks hide elements by selector and replace text that matches patterns before capture.
  This covers random temporary paths and clock values, so a second run's screenshots match
  the first's.
- Files go to `<out>/<case>/<row>/<step>-<name>-<viewport>-<scheme>.png`, next to
  `report.json` and `report.txt` in `<out>`. The default `<out>` is `build/uat/`, so a CI
  job can upload the directory as one artifact.
- Comparing screenshots from two runs is left for later. The fixed layout and the masks are
  what make it possible.

**Accessibility.** `:audit` injects axe-core and runs it once for each colour scheme, so
contrast is checked on the colours actually rendered in each scheme. A violation at or
above an impact level fails the step. The default level is `serious`. axe-core (MPL-2.0)
is vendored in `hyperion/assets/vendor/` and pinned in `ASSETS.pin` like htmx. It is loaded
only by `hyperion/uat` and never embedded in an app's image.

**FiveAM and the gate.** `define-uat-suite` turns each case and row into one FiveAM test,
so a run counts in the gate like any other suite.
- Without a browser, a run skips each test and gives the reason.
- With `OURANOS_REQUIRE_BROWSER=1`, which CI sets, a missing browser fails instead of
  skipping, so a runner without a browser cannot report green.

**The report.** For each case and row, the report gives:
- the verdict: passed, failed at a step with the reason, or not run with the reason;
- each step with its duration;
- the console and network findings;
- the artifact paths;
- the requirement id.

**Running it.** An app adds a `uat` target to its own `cons.lisp` that loads its suite and
calls `hyperion/uat:run`. A `cons uat` command built into cons is not part of this
decision.

### 3. Cases derived by elenchon reach the browser through data

The opt-in system `hyperion/uat/elenchon` reads the s-expression rendering of an elenchon
decision table, the output of `elenchon/cases` (ADR-0004, point 6). The app supplies two
mappings:
- each cause to the input values that make it true or false;
- each effect to the expectation steps that observe it.

Each derived test case becomes one row of a harness case and keeps its requirement id.
This is the sanctioned edge from a hyperion testing system to elenchon. It gives one path
from a requirement, to the derived cases, to a run in a real browser, and elenchon gains
no IO.

`elenchon/cases` comes after `elenchon/report` in elenchon's own order (ADR-0005). So this
system is built when `elenchon/cases` exists, and steps 2 to 4 of #1028 do not wait for it.
When it lands, the prose that names `hyperion/testing → elenchon` is updated to name this
system.

## Consequences

- Step 2 of #1028 is `aion/websocket` (the move plus the client handshake), `aion/cdp`, and
  switching the smoke tests and `praxeon/tests` to `aion/cdp:find-browser`.
- Step 3 is `hyperion/uat`, `hyperion/uat/core` and the vendored axe-core.
- Step 4 is an example app's cases in CI on Linux, macOS and Windows.
- Moving `hyperion/websocket` touches `hyperion/server-uv/websocket`, its tests,
  `docs/dependencies.md` and the CHANGELOG entry from #376. Doing it before the next release
  costs no app anything.
- aion gains two systems that must work on all three platforms. The placement rule already
  accepts that cost for aion's other bindings, and both systems are opt-in, so core aion
  stays `coalton` + `alexandria`.
- Each runner has its own browser version, so screenshots are only comparable within one
  platform. Option 3 in #1028, a pinned Chromium, was ruled out for that cost.
- A browser run is slow. `url-target` exists so that an app can run its cases after a
  deploy rather than on every pull request.

## Alternatives considered

- **The driver in elenchon.** Rejected for the reasons under point 1: it would add IO to a
  framework that has none, and it would put a general-purpose binding out of reach of aion's
  other consumers. The ruling allowed either framework.
- **The driver in a new satellite attached at aion, or in hades.** Nothing in the line may
  depend on a satellite, so `hyperion/uat` could not use it.
- **A WebSocket client from Quicklisp.** `websocket-driver`'s client brings `cl+ssl` and
  more, while the tree already has a dependency-free codec that only lacks the client
  handshake. The driver connects to a loopback port and never needs TLS.
- **`--remote-debugging-pipe` instead of a WebSocket.** It needs no port and no WebSocket,
  but the browser reads file descriptors 3 and 4. Passing those is only possible here
  through `aion/uv/process`, which needs libuv built with a C compiler. The pipe also cannot
  attach to a running browser. It can be added later as a second way to connect.
- **A harness on the elenchon side, with hyperion supplying only app start-up.** Waiting
  for htmx, CSRF, sign-in, session injection and the scratch database are all hyperion
  matters. A harness to hyperion's left could not know them without depending rightward.

## Provenance

Drafted by an AI assistant (Ouranos Claude, macOS) for the maintainer's review. The route
and the two-layer split are the maintainer's ruling. The placement in aion, the harness
surface and the alternatives are this ADR's proposal.
