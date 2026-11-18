# dokimasia

Acceptance tests for any app that runs in a browser, written as data. A case is a list of steps;
rows give it inputs and the results each input should produce. dokimasia runs every case and row
in a headless Chrome or Edge, against an app it starts or one already deployed, and writes a
report. Each case and row is one FiveAM test. The design is
[ADR-0001](docs/adr/0001-browser-driver-and-acceptance-harness.md); the work is #1028.

What exists today is the harness itself, its accessibility checks with axe-core, ready-made
stored-data probes for apps that use mnemosyne, and a target for hyperion apps (steps b1 to b3 of
#1028).

## A first suite

```lisp
(asdf:load-system :dokimasia)

(defpackage #:my-app/acceptance (:use #:cl) (:local-nicknames (#:d #:dokimasia)))
(in-package #:my-app/acceptance)

;; A screen is what the page must look like for a step to say "we are on it".
(d:define-screen dashboard :path "/dashboard" :present "#welcome")
(d:define-screen sign-in :path "/login" :present "form#login")
(d:define-screen sign-up :path "/signup" :present "form#signup")

;; A case: steps, run once per row. (:input key) is the row's value for KEY.
(d:define-case sign-up
  :requirement "ACCT-1"
  :rows (:file "rows/sign-up.csv")          ; relative to this file
  :steps ((:visit "/signup")
          (:fill "#email" (:input :email))
          (:fill "#password" (:input :password))
          (:select "#plan" (:input :plan))
          (:click "button[type=submit]")
          (:expect-screen (:input :screen))  ; each row names the screen it expects
          (:screenshot "after-sign-up")
          (:audit)))                          ; axe-core, in each colour scheme

(d:define-suite smoke
  :cases :all
  :target (d:url-target "https://staging.example.com"
                        :users (list (list :name :admin :email "admin@example.com"
                                           :password (aion/secret:make-secret "…"))))
  :sign-in ((:visit "/login")
            (:fill "#email" (:user :email))
            (:fill "#password" (:user :password))
            (:click "button[type=submit]")
            (:expect-screen dashboard))
  :mask ("#clock")                  ; hidden in screenshots
  :mask-text ("Updated \\d+s ago")) ; replaced in screenshots

(d:run :smoke :viewports '(:desktop :phone) :schemes '(:light :dark))
;; => T, #P".../build/dokimasia/report.txt"
```

`rows/sign-up.csv`:

```
id,email,password,plan,screen
new-user,new@example.com,correct-horse,free,dashboard
weak-password,weak@example.com,1,free,sign-up
```

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
| `(:screenshot name)` | Writes one PNG per viewport and colour scheme, grown to the page's full height. |
| `(:audit)` | Runs axe-core in the page once for each colour scheme and fails on a violation at or above `:serious` (below). |

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
  `:ignore-console` (matched as a substring);
- a response with status 500 or more from the app's own origin;
- more than `:max-requests-per-url` (20) requests to one URL during one step, which catches a fetch,
  poll or resubmit loop.

A row stops at its first failed step. Before each row the runner opens a new page and clears
cookies and the app origin's storage, so no row sees another's session.

## Accessibility

`(:audit)` loads axe-core into the page and runs it once for each colour scheme of the run, so
contrast is checked on the colours the page actually shows in each scheme. The step fails when a
rule finds a violation at or above its impact level, and the reason names each one:

```
FAILED   sign-up new-user [ACCT-1]: step 8 (:audit): axe-core 4.14.0 found 1 violation at serious or above: dark: color-contrast (serious, 3 elements, first at .hint): Elements must meet minimum color contrast ratio thresholds
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

- `(d:url-target base-url :users … :local-probes nil)`: an app that is already running. Set
  `:local-probes t` when the test image can reach the store that app uses (see "Probes").
- `(d:process-target :start fn :stop fn :users …)`: START starts the app and returns its base URL;
  STOP runs after the run, however it ended.

A user is a plist with a `:name` and whatever the sign-in steps read with `(:user key)`. Keep
passwords in `aion/secret` values; they are revealed only when typed into the page.

## Probes

```lisp
(d:define-probe :account-stored
  :local (lambda (email plan) …)                ; reads the store from the test image
  :http (lambda (page base-url email plan) …))  ; asks the app's API, e.g. through cdp:evaluate
```

Each form returns true, or NIL and a reason. `:local` runs only against a target that can see the
app's store: a process target, or a URL target made with `:local-probes t`. When the target can run
neither form, the step is **not run**, with that reason; it is never reported as passed.

`:local-probes t` is for an app at a local or staging URL whose database the test machine can
connect to, which includes an app not written in Lisp:

```lisp
(d:url-target "http://localhost:3000" :local-probes t)
```

dokimasia cannot check this. It is your statement that the store your probes read is the one the
app at that URL uses. If it is not, the probes pass or fail on another store's data.

### Probes that read a mnemosyne database

The aux system `dokimasia/mnemosyne` defines the local form for you:

```lisp
(asdf:load-system :dokimasia/mnemosyne)

(dokimasia/mnemosyne:define-row-probe :account-stored
  :source #'my-app:database          ; a mnemosyne backend, a pool, or a function returning one
  :table :accounts
  :match '(:email :plan))            ; (:expect-stored :account-stored (:input :email) (:input :plan))

(dokimasia/mnemosyne:define-row-probe :no-account
  :source #'my-app:database :table :accounts :match '(:email) :absent t)
```

`define-row-probe` passes when `:table` has a row whose `:match` columns hold the step's values, in
order, or with `:absent t` when none does. A step's values are strings; the database compares them
with the column's type. When no row matches, the reason gives the other columns' stored values in
the rows that match the first column:

```
the probe account-stored: accounts has no row with email = "new@example.com" and plan = "team"; the rows with email = "new@example.com" have plan = "free"
```

`define-query-probe` takes `:query`, a function of the step's values that returns a mnemosyne query,
and passes when the query returns a row (or none, with `:absent t`). A function given as `:source` is
called when the step runs, so it can name a database that exists only once the app has started.
`:dialect` defaults to `mnemosyne/query:*dialect*`. A table, column or dialect mnemosyne refuses is
refused with `invalid-definition` when the probe is defined. Both kinds are local probes. Against a
URL target they run only when it was made with `:local-probes t`; otherwise pass `:http` as well.

## Hyperion apps

The aux system `dokimasia/hyperion` starts a hyperion app for the run:

```lisp
(asdf:load-system :dokimasia/hyperion)

(dokimasia/hyperion:hyperion-target
  :setup #'my-app:migrate                 ; (lambda (backend) …): create the tables
  :seed (lambda (backend users) …)        ; store the users a case signs in as
  :app #'my-app:make-app                  ; (lambda (backend) …) → the Ring handler
  :teardown #'my-app:close-database       ; optional: close what :app opened
  :users (list (list :name :admin :email "admin@example.com" :password "…")))
```

Before the first case it makes a new SQLite file in a temporary directory, calls `:setup`, then
`:seed`, then `:app` with that database's mnemosyne backend, and starts the handler with
`hyperion/server` on a free port of 127.0.0.1. `:server` names the backend (`:uv`, `:hunchentoot`,
…); by default hyperion picks one. After the run, or when starting fails part way, it stops the
server, calls `:teardown` and deletes the directory.

**Settling.** After an action the runner also waits until htmx has no request in flight and no
swap still settling. A listener installed in every page before the page's own scripts counts
htmx's requests and swaps; on a page without htmx only the network check applies.

**Signing in.** By default a case signs in through the suite's `:sign-in` steps, as with any
target. For cases that do not test signing in, `:sign-in :session` adds a session for the user to
the app's store and sets its cookie, which is faster:

```lisp
(dokimasia/hyperion:hyperion-target …
  :sign-in :session
  :session-store (lambda () my-app:*sessions*)          ; the store the app gave wrap-session
  :session-data (lambda (user backend)                  ; the session's data for USER
                  (list (cons :user-id (my-app:user-id-by-email backend (getf user :email))))))
```

`:cookie-name` is the name the app gave `wrap-session`, `hyperion-session` by default. The report
shows the sign-in as one step, "sign-in: a session for admin in the app's store".

**Probes.** Local probes run against this target. `dokimasia/hyperion:current-database` returns the
running target's database, for a probe's `:source`:

```lisp
(dokimasia/mnemosyne:define-row-probe :account-stored
  :source #'dokimasia/hyperion:current-database :table :accounts :match '(:email :plan))
```

## The report

`run` writes `report.txt` and `report.json` to `:out` (default `build/dokimasia/`), with
screenshots under `<case>/<row>/NN-name-viewport-scheme.png`. `report.txt` starts with one line per
case and row, failures first, then rows not run, then passes, so the result can be read without
opening anything else:

```
FAILED   sign-up weak-password [ACCT-1]: step 6 (:expect-screen (:input :screen)): the page is not the screen sign-up: the path is /dashboard, not /signup
PASSED   sign-up new-user [ACCT-1]
```

Below that are each row's steps with their durations, and the console and network findings and
files written.

## Running without a browser

`aion/cdp:find-browser` looks at `OURANOS_BROWSER`, then PATH and the usual install locations.
With no browser, every test is skipped with the reason, or fails when `OURANOS_REQUIRE_BROWSER=1`,
which CI sets. The browser always runs headless, with a fresh profile that is deleted afterwards.
