# dokimasia

Acceptance tests for any app that runs in a browser, written as data. A case is a list of steps;
rows give it inputs and the results each input should produce. dokimasia runs every case and row
in a headless Chrome or Edge, against an app it starts or one already deployed, and writes a
report. Each case and row is one FiveAM test. The design is
[ADR-0001](docs/adr/0001-browser-driver-and-acceptance-harness.md); the work is #1028.

What exists today is the harness itself, its accessibility checks with axe-core, ready-made
stored-data probes for apps that use mnemosyne, a target for hyperion apps (steps b1 to b3 of
#1028), and a worked example that runs in CI (step 4). "Getting started" below takes an app from
nothing to a suite in CI; the sections after it are the reference.

## Getting started

This section takes an app from nothing to a suite that runs in CI. The reference is the worked
example, [`examples/active-search/`](examples/active-search/): a suite for hyperion's
active-search example app that the gate runs on Linux, macOS and Windows. Every code sample
below is copied from a file the gate runs, and names that file so you can check it against the
code.

dokimasia does not need your app to be written in Lisp. The suite is Lisp, and the app is
whatever answers at a URL: a hyperion app that dokimasia starts itself, a process that your
start function launches, or an app already running somewhere. Only the parts that start a
hyperion app, or read a mnemosyne database, need those frameworks, and they are separate
systems (see "Systems" below).

### 1. A screen, a case and a suite

A **screen** says what the page must show for a step to accept "we are on it". A **case** is a
list of steps, run once per row. A **suite** names its cases and the target they run against.
From [`examples/active-search/acceptance.lisp`](examples/active-search/acceptance.lisp):

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

(d:define-case contacts-page
  :requirement "PAGE-1"
  :steps ((:visit "/")
          (:expect-screen contacts)
          (:screenshot "contacts")
          (:audit)))

(d:define-suite active-search
  :cases (search-contacts contacts-page)
  :target (app-target))
```

`d` is the package nickname for `dokimasia`. `define-screen` evaluates its options, so a list
needs a quote. `define-suite` evaluates `:target` each time the suite runs, so each run gets a
new target. `:requirement` is the id of the requirement the case checks; the report prints it on
every line. A case name is a symbol in your package, so do not name a case after a symbol your
package inherits, such as `search` from `cl`.

`(:input key)` is the current row's value for KEY. The "Steps" table below lists every step.

### 2. Rows: inline, a Lisp data file, or CSV

A case without `:rows` runs once, as `row-1`. Otherwise `:rows` takes one of three forms.

**Inline**, as a list of plists. `:id` names the row in the report. From
[`tests/browser-tests.lisp`](tests/browser-tests.lisp):

```lisp
(d:define-case bt-signup
  :requirement "SIGNUP-1"
  :rows ((:id "free-user" :email "free@example.com" :password "pw-1" :plan "free")
         (:id "pro-user" :email "pro@example.com" :password "pw-2" :plan "pro"))
  :steps ((:visit "/signup")
          (:fill "#email" (:input :email))
          (:fill "#password" (:input :password))
          (:select "#plan" (:input :plan))
          (:click "#submit")
          (:expect-screen bt-home)
          (:expect-text "#welcome" (:input :email))
          (:expect-stored :bt-user-stored (:input :email) (:input :plan))
          (:screenshot "home")))
```

**CSV**, with `(:file "path.csv")`. The path is relative to the file that defines the case. The
first line names the columns, and the column `id`, when present, names each row. Column names
are compared in lower case, and a blank line is not a row. This is
[`examples/active-search/rows/search.csv`](examples/active-search/rows/search.csv), which the
case above reads:

```
id,query,first,echo
by-name,turing,Alan Turing,Filtering: turing
by-email,nasa,Margaret Hamilton,Filtering: nasa
by-role,coalton,Robert Smith,Filtering: coalton
no-match,zzz,No matches.,Filtering: zzz
```

**A Lisp data file**, with `(:file "path.sexp")`: one list of plists. It is read as data, so
`#.` and anything else that would run code is refused. This is the file
[`tests/data-tests.lisp`](tests/data-tests.lisp) writes and reads in
`rows-are-read-inline-from-csv-and-from-s-expressions`:

```lisp
; rows for a test
((:email "c@example.com" :count 3) (:email "d@example.com" :count 4))
```

A row file with a short line, code in it, or the wrong shape is refused with
`invalid-definition` when the case is defined, not during a run.

### 3. Targets: where the app comes from

**An app that is already running**, on any stack: `url-target`. From
[`tests/mnemosyne/tests.lisp`](tests/mnemosyne/tests.lisp):

```lisp
(d:url-target "https://staging.example.com")
(d:url-target "http://127.0.0.1:1" :local-probes t)
```

`:local-probes t` says that the test image can reach the store the app at that URL uses, so the
probes' local forms may run (section 4). dokimasia cannot check this: if the store is not the
app's, the probes pass or fail on another store's data. Without it, a probe that has only a
local form is reported as not run, never as passed.

**An app that a function starts and stops**: `process-target`. `:start` returns the base URL,
and `:stop` runs after the run however it ended. Your start function can launch anything, such
as a server for an app written in another language. From
[`tests/browser-tests.lisp`](tests/browser-tests.lisp), where the app is a small test server:

```lisp
(defun app-target (&key (favicon t))
  "A process target that starts and stops a fresh test app with Alice signed up. FAVICON NIL
starts it without a /favicon.ico, and :SLOW with one answered after 1.5 seconds."
  (d:process-target :start (lambda ()
                             (setf *app* (start-app :users (list +alice+) :favicon favicon))
                             (app-base-url *app*))
                    :stop (lambda () (stop-app *app*))
                    :users (list (list :name :alice :email "alice@example.com"
                                       :password (secret:make-secret "pw-alice")))))
```

A user is a plist with a `:name` and whatever the sign-in steps read with `(:user key)`. Keep
passwords in `aion/secret` values (`secret` above); they are revealed only when typed into the
page.

**A hyperion app**: `dokimasia/hyperion:hyperion-target` starts it on a free port of 127.0.0.1
with a new SQLite database, and stops it and deletes the database afterwards. The worked
example's `app-target`, from
[`examples/active-search/acceptance.lisp`](examples/active-search/acceptance.lisp):

```lisp
(defun app-target ()
  "A dokimasia/hyperion target that starts hyperion/examples/active-search on a free port. The
app does not use a database, so its :APP function ignores the scratch database it is given."
  (dh:hyperion-target :app (lambda (backend)
                             (declare (ignore backend))
                             (app:make-app))
                      :server :hunchentoot))
```

An app that has tables passes `:setup` and `:seed` as well. From
[`tests/hyperion/tests.lisp`](tests/hyperion/tests.lisp):

```lisp
(defun app-target (&rest options)
  (apply #'dh:hyperion-target :app #'make-app :setup #'setup-app :seed #'seed-app
                              :users +users+ :server :hunchentoot options))
```

"Hyperion apps" below covers the settle check and signing in with a session.

### 4. Stored data: probes

`(:expect-stored probe value…)` asks a probe whether the app stored what it should. A probe
defined with `define-probe` has a `:local` form, which reads the store from the test image, an
`:http` form, which asks the app, or both. Each returns true, or NIL and a reason. From
[`tests/browser-tests.lisp`](tests/browser-tests.lisp):

```lisp
(d:define-probe :bt-user-stored
  :local (lambda (email plan)
           (let ((user (app-user *app* email)))
             (cond ((null user) (values nil (format nil "no user ~A is stored" email)))
                   ((equal (getf user :plan) plan) t)
                   (t (values nil (format nil "~A is stored with the plan ~A, not ~A"
                                          email (getf user :plan) plan)))))))
```

When the app's database is one mnemosyne can open, `dokimasia/mnemosyne` writes the local form
for you. `define-row-probe` passes when the table has a row whose `:match` columns hold the
step's values, and with `:absent t` when none does. `:source` is a mnemosyne backend, a pool, or
a function that returns one when the step runs. From
[`tests/mnemosyne/tests.lisp`](tests/mnemosyne/tests.lisp):

```lisp
(dm:define-row-probe :t-account :source db :table :accounts :match '(:email :plan))
(dm:define-row-probe :t-no-account :source db :table :accounts :match '(:email) :absent t)
```

Against a hyperion target, `dokimasia/hyperion:current-database` is the running target's
database. From [`tests/hyperion/tests.lisp`](tests/hyperion/tests.lisp):

```lisp
(dm:define-row-probe :dh-user :source #'dh:current-database :table :users :match '(:email :plan))

(d:define-case dh-stored
  :steps ((:visit "/") (:expect-stored :dh-user "alice@example.com" "team")))
```

The worked example's `active-search-db` suite does the same for a form that writes to the
database: each row of `add-contact` fills in the form and checks the stored row, and each row of
`invalid-contact` checks the error shown and that no row was written. From
[`examples/active-search/acceptance.lisp`](examples/active-search/acceptance.lisp):

```lisp
(dm:define-row-probe :stored-contact
  :source #'dh:current-database :table :contacts :match '(:name :email :role) :dialect :sqlite)

(d:define-case add-contact
  :requirement "ADD-1"
  :rows (:file "rows/add.csv")
  :steps ((:visit "/")
          (:expect-screen contacts-with-form)
          (:fill "#new-name" (:input :name))
          (:fill "#new-email" (:input :email))
          (:fill "#new-role" (:input :role))
          (:click "#add-contact-submit")
          (:expect-text "#results" (:input :name))
          (:expect-stored :stored-contact (:input :name) (:input :email) (:input :role))))
```

`dm` is `dokimasia/mnemosyne` and `dh` is `dokimasia/hyperion`. "Probes" below gives the rest:
`define-query-probe`, the failure reasons, and what happens against a URL.

### 5. Screenshots and masks

`(:screenshot name)` writes one PNG for each viewport and colour scheme of the run, grown to the
page's full height. A suite's `:mask` lists selectors whose elements are hidden in its
screenshots, and `:mask-text` lists regular expressions whose matching text is replaced, so a
clock or a timestamp does not change the image from run to run. From
[`tests/browser-tests.lisp`](tests/browser-tests.lisp):

```lisp
(d:define-suite bt-passing
  :cases (bt-signup bt-signed-in bt-signin-rows bt-scroll-kept bt-known-console)
  :target (app-target)
  :sign-in ((:visit "/login")
            (:fill "#email" (:user :email))
            (:fill "#password" (:user :password))
            (:click "#submit")
            (:expect-screen bt-home))
  :ignore-console ("known noise")
  :mask ("#clock")
  :mask-text ("Generated at \\d+"))
```

A suite with no `:mask` takes its screenshots unmasked.

### 6. The accessibility audit

`(:audit)` runs axe-core in the page once for each colour scheme of the run, and fails on a
violation at or above `:serious`. `:impact` changes that level and `:ignore` turns rules off. From
[`tests/browser-tests.lisp`](tests/browser-tests.lisp):

```lisp
(d:define-case bt-a-ok :steps ((:visit "/a11y-ok") (:audit :impact :minor)))
(d:define-case bt-a-image-ignored :steps ((:visit "/a11y-image") (:audit :ignore ("image-alt"))))
```

"Accessibility" below gives the options and what a failure reports.

### 7. Running a suite, and the report

`run` takes the suite's name. The first viewport and scheme are the ones the cases run in; each
`:screenshot` step captures every combination, and each `:audit` runs in every scheme. From
[`examples/active-search/acceptance.lisp`](examples/active-search/acceptance.lisp), with its
docstring left out:

```lisp
(defun run-acceptance (&key out (viewports '(:desktop :phone)) (schemes '(:light))
                            (explain t))
  (d:run :active-search :out out :viewports viewports :schemes schemes :explain explain))
```

`run` returns true when every row passed, and the path of `report.txt`. It writes to `:out`, by
default `build/dokimasia/`. A run of the worked example's suite wrote these files:

```
report.txt
report.json
contacts-page/row-1/03-contacts-desktop-light.png
contacts-page/row-1/03-contacts-phone-light.png
```

A screenshot is `<case>/<row>/NN-name-viewport-scheme.png`, where NN is the step's number. This
is the start of `report.txt` from a run of the worked example's suite:

```
dokimasia: the suite active-search against http://127.0.0.1:59723
5 rows: 5 passed, 0 failed, 0 not run. Browser: Chrome/157.0.8103.79. Viewports: desktop, phone. Schemes: light.

PASSED   search-contacts by-name [SEARCH-1]
PASSED   search-contacts by-email [SEARCH-1]
PASSED   search-contacts by-role [SEARCH-1]
PASSED   search-contacts no-match [SEARCH-1]
PASSED   contacts-page row-1 [PAGE-1]
```

and from its control suite, whose one row expects the wrong first result
([`examples/active-search/tests.lisp`](examples/active-search/tests.lisp)):

```
FAILED   example-control wrong-first: step 3 (:expect-text "#results tr:first-child td:first-child" (:input :first) :timeout
 ...): the text of #results tr:first-child td:first-child does not contain "Grace Hopper"; it is "Alan Turing"
```

Failures come first, then rows not run, then passes. Below them are each row's steps with their
durations, the console and network findings, and the files written. `report.json` holds the
same: at the top `suite`, `base-url`, `browser`, `viewports`, `schemes`, the `passed`, `failed`
and `not-run` counts, and `rows`. Each row has `case`, `row`, `requirement`, `user`, `verdict`,
`decided-at-step`, `decided-by`, `reason`, `duration-ms`, `steps` (each with `label`, `outcome`,
`reason` and `ms`), `console`, `network` and `artifacts`, the screenshot paths.

Each case and row is also one FiveAM test, so a suite run inside `asdf:test-system` reports
through FiveAM as well.

### 8. In CI

`aion/cdp:find-browser` looks at `OURANOS_BROWSER`, then PATH and the usual install locations.
With no browser a test is skipped with the reason. Set `OURANOS_REQUIRE_BROWSER=1` in CI, so a
runner without a browser fails instead of passing on skips. GitHub's hosted runners for Linux,
macOS and Windows have Chrome. The browser always runs headless, with a new profile that is
deleted afterwards.

To keep the report and screenshots, write them to a directory the job then uploads, and upload
when the job fails too, since that is when the screenshots help most. The worked example's
tests write to `OURANOS_DOKIMASIA_EXAMPLE_OUT` when it is set
([`examples/active-search/tests.lisp`](examples/active-search/tests.lisp)), and this repository's
workflow sets it and uploads the directory. From
[`.github/workflows/verify.yml`](../.github/workflows/verify.yml):

```yaml
    env:
      OURANOS_TEST_REAL_CREDENTIAL_STORE: "1"
      OURANOS_REQUIRE_BROWSER: "1"
```

```yaml
          # dokimasia's worked example (#1028, step 4) writes its report and screenshots here,
          # and the next step uploads them, so a reader can see what the suite saw on each leg.
          OURANOS_DOKIMASIA_EXAMPLE_OUT: ${{ runner.temp }}/dokimasia-example
```

```yaml
      - name: Upload the dokimasia example's report and screenshots
        id: upload-the-dokimasia-example-s-report-and-screenshots
        if: always()
        uses: actions/upload-artifact@v7
        with:
          name: dokimasia-example-${{ matrix.platform }}
          path: ${{ runner.temp }}/dokimasia-example
          if-no-files-found: ignore
          retention-days: 14
```

`OURANOS_TEST_REAL_CREDENTIAL_STORE` belongs to another suite in this repository; an app needs
only `OURANOS_REQUIRE_BROWSER`.

## Systems

| System | Depends on | What it adds |
|---|---|---|
| `dokimasia/core` | `coalton` | The typed verdict of a row. |
| `dokimasia` | `dokimasia/core`, `aion` systems, `com.inuoe.jzon`, `fiveam` | Screens, cases, suites, probes, `url-target` and `process-target`, the steps, the checks after every step, the audit, the run and the report. |
| `dokimasia/mnemosyne` | `dokimasia`, `mnemosyne` | `define-row-probe` and `define-query-probe`, which read the app's database. |
| `dokimasia/hyperion` | `dokimasia`, `hyperion`, `mnemosyne` | `hyperion-target`, the settle check that waits for htmx, and sign-in with a session in the app's store. |
| `dokimasia/examples/active-search` | `dokimasia`, `dokimasia/hyperion`, `hyperion/examples/active-search` | The worked example. |

dokimasia attaches at `aion`: `dokimasia` itself never loads hyperion, mnemosyne, elenchon or
praxeon, so an app on another stack loads only it. `dokimasia/mnemosyne` and
`dokimasia/hyperion` are aux systems that reach right into the line. `dokimasia/elenchon`, which
will turn an elenchon decision table into rows, waits until `elenchon/cases` exists (#28).

## Steps

| Step | What it does |
|---|---|
| `(:visit path-or-url)` | Opens the base URL plus PATH, or a full URL, and waits for the load event. |
| `(:fill selector value)` | Clears the field, types VALUE, and fires `input` and `change`. |
| `(:click selector)` | Clicks the first element that matches. |
| `(:select selector value)` | Chooses the option whose value is VALUE; fails when there is none. |
| `(:wait-for selector)` or `(:wait-for (:expression "js"))` | Waits for a match, or for the expression to be true. |
| `(:expect-screen name)` | Waits until the page is the screen NAME; the failure says which part did not hold. |
| `(:expect-text selector value)` | Waits until the element's text contains VALUE. |
| `(:expect-stored probe value…)` | Asks the probe whether the app stored what it should (below). |
| `(:expect-scroll-kept action :pane selector :scroll n)` | Runs ACTION and fails if the scroll position of PANE, or of the window, moved. |
| `(:screenshot name)` | Writes one PNG per viewport and colour scheme, grown to the page's full height, with CSS transitions and animations turned off so each image shows the page at rest. |
| `(:audit)` | Runs axe-core in the page once for each colour scheme, with CSS transitions and animations turned off, and fails on a violation at or above `:serious` (below). |

The steps that wait take `:timeout` in seconds; otherwise they wait `*step-timeout*` (10).
A value is a string, a number, `(:input key)` or `(:user key)`. A step of an unknown kind, or with
the wrong arguments, is refused with `invalid-definition` when the case is defined, not during a run.

After `:visit`, `:fill`, `:click` and `:select`, the runner waits for the page to settle: no
request in flight for `*quiet-period*` seconds, within `*settle-timeout*`. A target class can
specialise `target-settle` to add its own condition. A target class can also specialise `target-prepare-page`, called on each row's new
page before its first step, and `target-sign-in`, which signs a case's user in without the suite's
`:sign-in` steps; `dokimasia/hyperion` (below) does all three.

## The checks made after every step

Each of these fails the step it happened in, with the reason in the report:

- a console error, a failed `console.assert`, an uncaught exception, or a log entry at error level,
  which includes Content-Security-Policy violations, unless the suite lists it in
  `:ignore-console` (matched as a substring). The log error for the browser's own request for
  `/favicon.ico` is not counted when the page links no icon, because the page did not ask for it;
  the report lists it with `"ignored": true`. A page that links an icon that is missing, including
  one at `/favicon.ico`, still fails;
- a response with status 500 or more from the app's own origin;
- more than `:max-requests-per-url` (20) requests to one URL during one step, which catches a fetch,
  poll or resubmit loop.

A row stops at its first failed step. Before each row the runner opens a new page and clears
cookies and the app origin's storage, so no row sees another's session.

## Accessibility

`(:audit)` loads axe-core into the page and runs it once for each colour scheme of the run, so
contrast is checked on the colours the page actually shows in each scheme. The step fails when a
rule finds a violation at or above its impact level, and the reason names each one. This line is
from the worked example's page case run in the dark scheme alone (`run-dark-audit` in
[`examples/active-search/tests.lisp`](examples/active-search/tests.lisp)), the failure that keeps
that test skipped until #1281:

```
FAILED   contacts-page row-1 [PAGE-1]: step 4 (:audit): axe-core 4.14.0 found 1 violation at serious or above: dark: color-contrast (serious, 1 element, first at .subtitle): Elements must meet minimum color contrast ratio thresholds
```

| Option | Default | |
|---|---|---|
| `:impact` | `*audit-impact*`, `:serious` | The lowest impact that fails the step: `:minor`, `:moderate`, `:serious` or `:critical`. |
| `:ignore` | none | axe-core rule ids to turn off, such as `("region")`. An id axe-core does not know fails the step. |
| `:timeout` | `*audit-timeout*`, 30 | Seconds axe-core may take, for each colour scheme. |

axe-core 4.14.0 is vendored unmodified in `vendor/axe.min.js`, under its own licence, MPL-2.0
(`vendor/axe.LICENSE`, and `vendor/axe.LICENSE-3RD-PARTY.txt` for the code it bundles). It is
pinned by version and sha256 in `vendor/ASSETS.pin` and compiled into the image, so a run needs
no network for it.

## Targets

- `url-target base-url &key users local-probes`: an app that is already running. Pass
  `:local-probes t` when the test image can reach the store that app uses (see "Probes").
- `process-target &key start stop users`: START starts the app and returns its base URL; STOP
  runs after the run, however it ended.

Section 3 of "Getting started" has an example of each, and of `hyperion-target`.

A user is a plist with a `:name` and whatever the sign-in steps read with `(:user key)`. Keep
passwords in `aion/secret` values; they are revealed only when typed into the page.

## Probes

`define-probe name &key local http`. LOCAL is a function of the step's values that reads the
store from the test image. HTTP is a function of the page, the base URL and the step's values
that asks the app, for example through `aion/cdp:evaluate`. Section 4 of "Getting started" has an
example. Each form returns true, or NIL and a reason. `:local` runs only against a target that can see the
app's store: a process target, or a URL target made with `:local-probes t`. When the target can run
neither form, the step is **not run**, with that reason; it is never reported as passed.

`:local-probes t` is for an app at a local or staging URL whose database the test machine can
connect to, which includes an app not written in Lisp. dokimasia cannot check this. It is your statement that the store your probes read is the one the
app at that URL uses. If it is not, the probes pass or fail on another store's data.

### Probes that read a mnemosyne database

The aux system `dokimasia/mnemosyne` defines the local form for you. Section 4 of "Getting
started" has examples. `define-row-probe` passes when `:table` has a row whose `:match` columns hold the step's values, in
order, or with `:absent t` when none does. A step's values are strings; the database compares them
with the column's type. When no row matches, the reason gives the other columns' stored values in
the rows that match the first column. This reason is asserted in
[`tests/mnemosyne/tests.lisp`](tests/mnemosyne/tests.lisp); the report puts "the probe NAME: "
in front of it:

```
accounts has no row with email = "new@example.com" and plan = "team"; the rows with email = "new@example.com" have plan = "free"
```

`define-query-probe` takes `:query`, a function of the step's values that returns a mnemosyne query,
and passes when the query returns a row (or none, with `:absent t`). A function given as `:source` is
called when the step runs, so it can name a database that exists only once the app has started.
`:dialect` defaults to `mnemosyne/query:*dialect*`. A table, column or dialect mnemosyne refuses is
refused with `invalid-definition` when the probe is defined. Both kinds are local probes. Against a
URL target they run only when it was made with `:local-probes t`; otherwise pass `:http` as well.

## Hyperion apps

The aux system `dokimasia/hyperion` starts a hyperion app for the run with `hyperion-target`,
which takes:

- `:app`, a function of the database's mnemosyne backend that returns the app's handler;
- `:setup`, a function of the backend that creates the tables, for example by running the app's
  migrations;
- `:seed`, a function of the backend and the users that stores the users a case signs in as;
- `:teardown`, optional, which closes what `:app` opened;
- `:users`, `:server`, and the sign-in options below.

Section 3 of "Getting started" has two examples. Before the first case it makes a new SQLite file in a temporary directory, calls `:setup`, then
`:seed`, then `:app` with that database's mnemosyne backend, and starts the handler with
`hyperion/server` on a free port of 127.0.0.1. `:server` names the backend (`:uv`, `:hunchentoot`,
…); by default hyperion picks one. After the run, or when starting fails part way, it stops the
server, calls `:teardown` and deletes the directory.

**Settling.** After an action the runner also waits until htmx has no request in flight and no
swap still settling. A listener installed in every page before the page's own scripts counts
htmx's requests and swaps; on a page without htmx only the network check applies.

**Signing in.** By default a case signs in through the suite's `:sign-in` steps, as with any
target. For cases that do not test signing in, `:sign-in :session` adds a session for the user to
the app's store and sets its cookie, which is faster. `:session-store` is a function that
returns the store the app gave `wrap-session`, and `:session-data` a function of the user and the
backend that returns the session's data. This is the target built in
`sign-in-with-a-session-needs-no-sign-in-steps` in
[`tests/hyperion/tests.lisp`](tests/hyperion/tests.lisp), with the call around it left out; the
test app keeps its store in `*sessions*`:

```lisp
(app-target :sign-in :session :session-store (lambda () *sessions*)
            :session-data (lambda (user db)
                            (declare (ignore db))
                            (list (cons :user-id (getf user :email)))))
```

`:cookie-name` is the name the app gave `wrap-session`, `hyperion-session` by default. The report
shows the sign-in as one step, "sign-in: a session for admin in the app's store".

**Probes.** Local probes run against this target. `dokimasia/hyperion:current-database` returns the
running target's database, for a probe's `:source`, as in section 4 of "Getting started".

## The report

`run` writes `report.txt` and `report.json` to `:out` (default `build/dokimasia/`), with
screenshots under `<case>/<row>/NN-name-viewport-scheme.png`. `report.txt` starts with one line per
case and row, failures first, then rows not run, then passes, so the result can be read without
opening anything else. Section 7 of "Getting started" shows a run's report and the keys of
`report.json`. Below that are each row's steps with their durations, and the console and network findings and
files written.

## Running without a browser

`aion/cdp:find-browser` looks at `OURANOS_BROWSER`, then PATH and the usual install locations.
With no browser, every test is skipped with the reason, or fails when `OURANOS_REQUIRE_BROWSER=1`,
which CI sets. The browser always runs headless, with a fresh profile that is deleted afterwards.
