;;;; acceptance.lisp --- a worked example of dokimasia (#1028, step 4): acceptance tests for
;;;; hyperion's active-search example app, written as data.
;;;;
;;;; The app is hyperion/examples/active-search: a contacts table and a search box. Typing in the
;;;; box sends an htmx POST to /search after a 250 ms delay and swaps the server-rendered rows
;;;; into #results; Alpine echoes the query under the box as it is typed.
;;;;
;;;; The suite has two cases:
;;;;   - SEARCH-CONTACTS runs once per row of rows/search.csv. It types the row's query and
;;;;     checks the first result row and the Alpine echo. The first result before any search is
;;;;     Ada Lovelace, and every row expects another name, so a row passes only after htmx has
;;;;     swapped new rows in.
;;;;   - CONTACTS-PAGE checks that the page is the contacts screen, takes a screenshot in every
;;;;     viewport and colour scheme of the run, and runs the axe-core audit in each scheme.
;;;;
;;;; The run is in the light scheme only for now. In the dark scheme the audit finds 11 elements
;;;; below WCAG AA contrast: the grey subtitle and the mailto links, in Bulma's colours, which
;;;; hyperion/appearance does not yet set (#1281). The suite ACTIVE-SEARCH-DARK holds the dark
;;;; audit; its test is skipped as pending #1281.
;;;;
;;;; RUN-ACCEPTANCE runs the suite against the app, which dokimasia/hyperion starts on a free port
;;;; of 127.0.0.1 and stops afterwards. The app keeps its data in memory; the scratch database the
;;;; target makes is not used.

(defpackage #:dokimasia/examples/active-search
  (:use #:cl)
  (:local-nicknames (#:d #:dokimasia)
                    (#:dh #:dokimasia/hyperion)
                    (#:app #:hyperion/examples/active-search))
  (:export #:app-target #:run-acceptance))

(in-package #:dokimasia/examples/active-search)

(defun app-target ()
  "A dokimasia/hyperion target that starts hyperion/examples/active-search on a free port. The
app does not use a database, so its :APP function ignores the scratch database it is given."
  (dh:hyperion-target :app (lambda (backend)
                             (declare (ignore backend))
                             (app:make-app))
                      :server :hunchentoot))

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

(d:define-suite active-search-dark
  :cases (contacts-page)
  :target (app-target))

(defun run-acceptance (&key out (viewports '(:desktop :phone)) (schemes '(:light))
                            (explain t))
  "Run the active-search suite against the example app and write the report to OUT, by default
DOKIMASIA:*DEFAULT-OUT*. The cases run in the first of VIEWPORTS and SCHEMES, and the screenshot
step captures every combination. SCHEMES is light only by default, because the audit fails in
the dark scheme until #1281 is fixed. Returns true when every row passed, and the path of
report.txt."
  (d:run :active-search :out out :viewports viewports :schemes schemes :explain explain))
