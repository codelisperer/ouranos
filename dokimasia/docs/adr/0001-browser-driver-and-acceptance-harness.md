# ADR-0001 — dokimasia: a data-driven acceptance-test harness for any app in a browser, over a browser driver in aion

**Status:** Accepted — 2026-11-17. Records the maintainer's rulings on
[#1028](https://github.com/codelisperer/ouranos/issues/1028):
- **2026-11-16 (issue comment 6935439985):** the route. The Chrome DevTools Protocol (CDP),
  driven from Lisp, against the runner's installed Chrome or Edge, with no Node and no
  pinned browser download.
- **2026-11-17 (issue comment 6953916317), on the first draft of this record (#1256):**
  - The harness is a new satellite, dokimasia, because it "is not limited to testing
    Hyperion apps, but literally any app that runs in a browser".
  - `hyperion/websocket` moves to `aion/websocket` now.
  - Pipe transport is the third step of the work, and becomes the default for browsers the
    harness launches.

In Athens the dokimasia was the examination a person passed before taking office. This
library examines an app before it is released.

## Context

Apps want to check, in CI and without waiting for human testers, that each user flow works:
given these inputs, the app reaches these screens and stores this data. Judging usability
still needs people. The checks that pass today are all at the HTTP level. They cannot see
three failures a consuming app has reported:
- a script whose fetch, poll or resubmit cycle goes wrong;
- a script that the Content-Security-Policy blocks, which shows up only in the browser
  console;
- an htmx swap that loses the user's scroll position.

Two apps have each written their own browser harness with Node and `puppeteer-core`, and a
third is waiting for the framework to provide one.

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
  CHANGELOG.
- `aion/uv/process` spawns a child process through libuv's `uv_spawn` with streamed stdio.
- `hyperion/test-ports` finds a free port.
- `hyperion/assets/vendor/` holds htmx with its licence and an `ASSETS.pin` entry carrying
  the version, SHA-256 and review date. This is the model for vendoring axe-core.
- Elenchon has no IO. Its output is data: its ADR-0004 makes the `Draft`/`Outcome` types
  the boundary and defers executable test stubs.

The placement rule in `ECOSYSTEM.md` (pre-publication issue 117) separates a binding from a
decision. A faithful binding to an external interface, whose specification is someone
else's documentation, goes in aion, because everything that might use it is to aion's
right. A layer that makes choices the interface does not make goes where its domain is.

## Decision

### 1. The browser driver goes in aion, as two opt-in systems

**`aion/websocket`.** `hyperion/websocket` moves to aion unchanged, and gains the client half
of the handshake:
- generating the `Sec-WebSocket-Key` with `aion/random`;
- checking the server's `Sec-WebSocket-Accept`.

`hyperion/server-uv/websocket` then depends on `aion/websocket`. No hyperion system of the
old name is kept, because no release has shipped one. The move gets a CHANGELOG entry that
names the old and new system and package names.

**`aion/cdp`.** A CDP client: launching or attaching to a browser, sessions, and the
commands and events that tests and agents need. A CDP client is a binding in the sense of
the placement rule. Its specification is Chrome's protocol documentation, and it decides
nothing about what a test is.

- **Finding a browser.** `find-browser` replaces the private `%smoke-browser`.
  - It reads `OURANOS_BROWSER`, then `HYPERION_SMOKE_BROWSER`, so existing CI settings keep
    working.
  - It then searches PATH, with `aion/windows:find-executable` on Windows, and the fixed
    install locations the smoke tests already check.
  - The smoke tests and `praxeon/tests` switch to it in step (a).
- **Launching.**
  - `launch-browser` always starts the browser with `--headless=new` and a fresh private
    profile from `aion/fs`.
  - It connects in one of two ways:
    - **Port**, the only way until step (c): `--remote-debugging-port=0`. The driver reads
      the real port and the browser's WebSocket path from the `DevToolsActivePort` file
      that the browser writes into the profile. Port 0 means two runs on one machine cannot
      race for a port.
    - **Pipe**, the default from step (c): `--remote-debugging-pipe`. The browser reads
      commands on file descriptor 3 and writes on 4, each message ended by a NUL byte, and
      `aion/uv/process` provides those descriptors. A debugging port can be reached by every
      local process for as long as the browser runs, and CDP has no authentication. A pipe
      can be reached only by the process that started the browser.

    After step (c), a caller gets the port only by asking for it (`:transport :port`), for
    example on a machine without libuv. The driver never falls back to the port by itself.
  - Process lifetime follows `hyperion/sidecar`, so a crashed test image cannot leave a
    browser running:
    - on Windows, a kill-on-close job object (`aion/windows:spawn-in-job`);
    - on Linux, `setpriv --pdeathsig KILL` where available.
  - `close-browser` sends `Browser.close`, kills the process if it is still running, and
    deletes the profile.
  - `with-browser` wraps all of this in `unwind-protect`.
- **Attaching.** `attach-browser` takes a `ws://` URL and refuses one whose host is not a
  loopback address. Attaching always uses WebSocket, because a browser that is already
  running has no pipe to this process.
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
- **Dependencies.**
  - `aion/websocket`, `aion/dynamic`, `aion/log`, `aion/fs`, `aion/random`, and
    `aion/windows` on Windows;
  - `com.inuoe.jzon`, `cl-base64`, and the SBCL contribs `sb-bsd-sockets` and
    `sb-concurrency`;
  - from step (c), `aion/uv/process`.

  Every one is already loaded somewhere in aion, so there is **no new external
  dependency**.

**The headless guarantee lives in the driver.** `launch-browser` has no argument that
removes `--headless=new`. Before starting anything, it signals an error for extra arguments
that set the headless mode, the remote-debugging port or pipe, or the profile directory. A
test asserts the exact command line. `attach-browser` connects to a browser someone else
started and opens no window. So no function in `aion/cdp`, and therefore nothing in
dokimasia, can open a window on a developer's screen.

**Why the driver is not in dokimasia itself.** Nothing in the dependency line may depend on
a satellite. `praxeon/web-page` reads pages over HTTP and cannot read pages that build their
content with JavaScript, and a CDP read would fix that. With the driver in aion, praxeon and
dokimasia both use it.

**Why not elenchon.** Elenchon has no IO, and this driver is mostly IO: a child process, a
socket or pipe, and a reader thread. Putting it there would make elenchon's test suite need
a browser. Elenchon still reaches a browser run through its data (point 3).

### 2. The harness is dokimasia, a satellite attached at aion

**The core system, `dokimasia`, depends only on aion and external libraries.** It knows
nothing about how the app under test is built, so it can check any app that runs in a
browser. It depends on:
- `aion/cdp`, `aion/sexp`, `aion/csv`, `aion/secret`, `aion/log` and `aion/fs`;
- `fiveam`.

Its pure part, `dokimasia/core`, is Coalton, following `praxeon/eval/core`. It holds the
types for a case, a step, a step result and a verdict, and the function that combines step
results into a verdict.

**A case is data.** An app writes cases as s-expressions. Each case has:
- an id and an optional requirement id;
- an optional user to sign in as;
- a list of steps;
- rows of inputs, so that one case runs once per row.

Rows can be written inline, or loaded from an s-expression file or a CSV file. That way one
table of inputs and expected results drives many runs, and a row can expect an error screen
as well as a success.

```lisp
(dokimasia:define-screen :dashboard :path "/home" :present "#dashboard")

(dokimasia:define-case :sign-up
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
`:expect-text`, `:expect-stored`, `:expect-scroll-kept`, `:screenshot` and `:audit`. A
screen is a named predicate on the path and the elements present. It is defined once and
used by every case.

**Checks that run after every step without being written:**
- **The page settles.** After an action, the runner waits until the target's settle check
  passes. The core's own check waits until no network request is in flight. An aux system
  can supply a better one, as `dokimasia/hyperion` does for htmx.
- **No console errors.** Any console error, uncaught exception or CSP violation fails the
  step. An app can list known messages to ignore, and each entry names the message.
- **No runaway requests.** The runner records the network requests made during each step.
  A step that makes more than its limit of requests to one URL fails, which catches fetch,
  poll and resubmit loops. A same-origin response of 500 or more fails the step.
- **Client error reports are rate-limited.** If the app names its client-error report
  endpoint, the runner intercepts it with the `Fetch` domain and lets through only a fixed
  number of reports per run.

`:expect-scroll-kept` records the scroll position of the window, or of a named scrolling
pane, before the action and compares it after the page settles.

**Targets.** A run has one target. A target says:
- how to reach the app: a base URL;
- how to sign in;
- how to tell that a page has settled;
- how to start and stop the app, if the harness starts it.

The core provides two targets:
- **`url-target`** takes a deployed base URL, such as staging after a deploy, and
  credentials from `aion/secret`.
- **`process-target`** takes functions that start the app and return its base URL, and
  that stop it. Any app the harness can start fits here, whatever it is written in. The
  runner calls the stop function even when a case fails.

**Sign-in.** An app defines its sign-in once, as steps. The runner signs in by running those
steps against the real sign-in form, which works for every target and goes through the
app's own CSRF and same-origin checks exactly as a user does.

**Stored data.** `:expect-stored` calls a probe the app registers by name. The core defines
the probe and runs it in the test image. It has no database code of its own.
- An aux system supplies probes that read a particular store. `dokimasia/mnemosyne` is the
  one for mnemosyne.
- A probe can also have an HTTP form, which checks the stored data through the app's own
  API.
- Against a `url-target`, a step whose probe has no HTTP form is reported as **not run**,
  with that reason, and never as passed. The report counts not-run steps separately, so a
  smaller check is not mistaken for a passing one.

**Screenshots.**
- Viewports are `:desktop` (1280×800) and `:phone` (390×844, mobile, scale factor 2), and
  colour schemes are `:light` and `:dark`. A run takes a list of each.
- Before capturing, the runner grows the viewport to the height of the document or of the
  tallest scrolling pane, whichever is larger, so that nothing below the fold is missed.
- Masks hide elements by selector and replace text that matches patterns before capture.
  This covers random temporary paths and clock values, so a second run's screenshots match
  the first's.
- Files go to `<out>/<case>/<row>/<step>-<name>-<viewport>-<scheme>.png`, next to
  `report.json` and `report.txt` in `<out>`. The default `<out>` is `build/dokimasia/`, so a
  CI job can upload the directory as one artifact.
- Comparing screenshots from two runs is left for later. The fixed layout and the masks are
  what make it possible.

**Accessibility.** `:audit` injects axe-core and runs it once for each colour scheme, so
contrast is checked on the colours actually rendered in each scheme. A violation at or
above an impact level fails the step. The default level is `serious`. axe-core (MPL-2.0) is
vendored in `dokimasia/vendor/` with its licence and an `ASSETS.pin` entry, like htmx, and
`scripts/check-pins.lisp` learns that pin file.

**FiveAM and the gate.** `define-suite` turns each case and row into one FiveAM test, so a
run counts in the gate like any other suite.
- Without a browser, a run skips each test and gives the reason.
- With `OURANOS_REQUIRE_BROWSER=1`, which CI sets, a missing browser fails instead of
  skipping, so a runner without a browser cannot report green.

**The report.** For each case and row, the report gives:
- the verdict: passed, failed at a step with the reason, or not run with the reason;
- each step with its duration;
- the console and network findings;
- the artifact paths;
- the requirement id.

**Running it.** An app adds a target to its own `cons.lisp` that loads its suite and calls
`dokimasia:run`. A `cons` command built into cons for this is not part of this decision.

**Aux systems that reach right.** A satellite depends leftward into the line, and nothing in
the line depends on it. Its aux systems may also depend on frameworks to the right of where
the satellite attaches. This is the same allowance a framework's aux systems have, and the
2026-11-17 ruling places these three for dokimasia. The core never loads them.
- **`dokimasia/hyperion`** (depends on `hyperion`, `hyperion/test-ports` and `mnemosyne`):
  - `hyperion-target` starts a hyperion app on a free port with a scratch database, runs
    the app's seeding function to create the seeded users, and stops the app and deletes
    the database afterwards. A case signs in as a seeded user through the form, as in the
    core.
  - Its settle check waits until htmx has no request in flight and has fired
    `htmx:afterSettle`, using a small listener installed with
    `Page.addScriptToEvaluateOnNewDocument`.
  - As an option, it creates a seeded user's session directly in hyperion's session store
    and sets the cookie with `Network.setCookie`. That makes sign-in faster for cases that
    do not test sign-in itself. Signing in through the form is still the default.
- **`dokimasia/mnemosyne`** (depends on `mnemosyne`): probes that read stored values
  through a mnemosyne connection.
- **`dokimasia/elenchon`** (depends on `elenchon`): point 3.

### 3. Cases derived by elenchon reach the browser through data

`dokimasia/elenchon` reads the s-expression rendering of an elenchon decision table, the
output of `elenchon/cases` (elenchon ADR-0004, point 6). The app supplies two mappings:
- each cause to the input values that make it true or false;
- each effect to the expectation steps that observe it.

Each derived test case becomes one row of a dokimasia case and keeps its requirement id.
This gives one path from a requirement, to the derived cases, to a run in a real browser,
and elenchon gains no IO.

`elenchon/cases` comes after `elenchon/report` in elenchon's own order (elenchon ADR-0005).
So this system is built when `elenchon/cases` exists, and the steps below do not wait for
it. The prose in `ECOSYSTEM.md` and the contributing guides that named a
`hyperion/testing → elenchon` edge now names this system instead. That hyperion system was
never built.

### 4. The order of work

- **(a) The driver over WebSocket.**
  - `aion/websocket`: the move, plus the client handshake.
  - `aion/cdp` with port transport.
  - The smoke tests and `praxeon/tests` switch to `aion/cdp:find-browser`.
- **(b) The harness running cases.**
  - `dokimasia` and `dokimasia/core`, with `url-target` and `process-target`.
  - The vendored axe-core.
  - `dokimasia/hyperion` and `dokimasia/mnemosyne`.
- **(c) Pipe transport.** `--remote-debugging-pipe` through `aion/uv/process` becomes the
  default for every browser that `launch-browser` starts, and so for every browser that
  dokimasia starts. libuv's `uv_spawn` can pass extra file descriptors on all three
  operating systems. Step (c) confirms that Chrome and Edge read them on each one before the
  default changes. WebSocket stays for `attach-browser`.
- **(d) A worked example.** Cases for a hyperion example app, run in CI on Linux, macOS and
  Windows.
- **Later:** `dokimasia/elenchon`, once `elenchon/cases` exists.

## Consequences

- The tree gains an eighth top-level directory. `dokimasia/` holds the satellite's systems,
  its `CLAUDE.md` and its ADRs. The satellite lists in the root `CLAUDE.md`, `AGENTS.md` and
  `ECOSYSTEM.md` name it.
- Moving `hyperion/websocket` touches:
  - `hyperion/server-uv/websocket` and its tests;
  - `docs/dependencies.md`;
  - the CHANGELOG entry from #376.

  Doing it before the next release costs no app anything.
- aion gains two systems that must work on all three platforms. The placement rule already
  accepts that cost for aion's other bindings, and both systems are opt-in, so core aion
  stays `coalton` + `alexandria`.
- After step (c), launching a browser through dokimasia needs libuv. `scripts/setup.sh` and
  `scripts/setup.ps1` build it by default since #504.
- Each runner has its own browser version, so screenshots are only comparable within one
  platform. Option 3 in #1028, a pinned Chromium, was ruled out for that cost.
- A browser run is slow. `url-target` exists so that an app can run its cases after a deploy
  rather than on every pull request.

## Alternatives considered

- **The harness inside hyperion, as `hyperion/uat`.** This was the first draft of this
  record. The maintainer rejected it on 2026-11-17, because the harness should check any
  app that runs in a browser, not only hyperion apps. The hyperion-specific parts are now
  the aux system `dokimasia/hyperion`.
- **The driver in elenchon.** Rejected for the reasons in point 1.
- **The driver inside dokimasia.** Rejected because nothing in the line, praxeon included,
  could then use it.
- **A WebSocket client from Quicklisp.** `websocket-driver`'s client brings `cl+ssl` and
  more, while the tree already has a dependency-free codec that only lacks the client
  handshake. The driver connects to a loopback port and never needs TLS.
- **Pipe transport first.** Attaching to a running browser needs WebSocket in any case, and
  the WebSocket codec already exists, so step (a) is the smaller first step. The pipe
  follows it directly as step (c) and becomes the default.

## Provenance

The first draft was written by an AI assistant (Ouranos Claude, macOS). The route, the
satellite and its name, the WebSocket move and the place of pipe transport in the order of
work are the maintainer's rulings. The rest is this record's design. It was reviewed by the
hub session and accepted with those rulings.
