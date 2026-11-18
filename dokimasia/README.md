# dokimasia

Acceptance tests for any app that runs in a browser, written as data. A case is a list of steps;
rows give it inputs and the results each input should produce. dokimasia runs every case and row
in a headless Chrome or Edge, against an app it starts or one already deployed, and writes a
report. Each case and row is one FiveAM test. The design is
[ADR-0001](docs/adr/0001-browser-driver-and-acceptance-harness.md); the work is #1028.

What exists today is the harness itself and its accessibility checks with axe-core (steps b1
and b2 of #1028). The add-ons for hyperion and mnemosyne apps are still to come.

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
specialise `target-settle` to add its own condition.

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

- `(d:url-target base-url :users …)`: an app that is already running.
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
app's store (a process target). When the target can run neither form, the step is **not run**, with
that reason; it is never reported as passed.

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
