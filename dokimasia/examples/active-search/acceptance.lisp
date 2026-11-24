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
;;;; The run is in the light scheme only for now. In the dark scheme the audit finds the grey
;;;; subtitle (.subtitle) below WCAG AA contrast, in Bulma's grey, which hyperion/appearance does
;;;; not yet set (#1281). Runs that switched from light to dark also reported the ten mailto
;;;; links, because the audit read them part way through their colour transition (#1288); at
;;;; rest they pass. The suite ACTIVE-SEARCH-DARK holds the dark audit; its test is skipped as
;;;; pending #1281.
;;;;
;;;; RUN-ACCEPTANCE runs the suite against the app, which dokimasia/hyperion starts on a free port
;;;; of 127.0.0.1 and stops afterwards. The app keeps its data in memory; the scratch database the
;;;; target makes is not used.
;;;;
;;;; The second suite, ACTIVE-SEARCH-DB, checks stored data (#1282). It runs against
;;;; hyperion/examples/active-search-db, the same page backed by SQLite, on the target's scratch
;;;; database: the target's setup migrates and seeds it with ENSURE-DB, and MAKE-APP is given it.
;;;; Its two cases:
;;;;   - ADD-CONTACT runs once per row of rows/add.csv. It fills in the page's add-a-contact form
;;;;     and submits it, CSRF token included, waits for the new name in the table, and then reads
;;;;     the row back from the database through dokimasia/mnemosyne.
;;;;   - INVALID-CONTACT runs once per row of rows/invalid.csv. Each row posts a contact that fails
;;;;     validation, checks that the form shows the error, and checks that no row was written.
;;;; RUN-DB-ACCEPTANCE runs it.

(defpackage #:dokimasia/examples/active-search
  (:use #:cl)
  (:local-nicknames (#:d #:dokimasia)
                    (#:dh #:dokimasia/hyperion)
                    (#:dm #:dokimasia/mnemosyne)
                    (#:app #:hyperion/examples/active-search)
                    (#:app-db #:hyperion/examples/active-search-db))
  (:export #:app-target #:run-acceptance #:db-app-target #:run-db-acceptance))

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

;;; --- stored data: hyperion/examples/active-search-db (#1282) ---------------------------------

(defun db-app-target ()
  "A dokimasia/hyperion target that starts hyperion/examples/active-search-db on a free port, on
the target's scratch SQLite database, migrated and seeded by the app's own ENSURE-DB."
  (dh:hyperion-target :setup (lambda (backend) (app-db:ensure-db backend))
                      :app (lambda (backend) (app-db:make-app backend))
                      :server :hunchentoot))

(dm:define-row-probe :stored-contact
  :source #'dh:current-database :table :contacts :match '(:name :email :role) :dialect :sqlite)

(dm:define-row-probe :no-contact-with-email
  :source #'dh:current-database :table :contacts :match '(:email) :absent t :dialect :sqlite)

(d:define-screen contacts-with-form
  :path "/"
  :present '("#q" "#results" "#add-contact"))

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

(d:define-case invalid-contact
  :requirement "ADD-2"
  :rows (:file "rows/invalid.csv")
  :steps ((:visit "/")
          (:expect-screen contacts-with-form)
          (:fill "#new-name" (:input :name))
          (:fill "#new-email" (:input :email))
          (:fill "#new-role" (:input :role))
          (:click "#add-contact-submit")
          (:expect-text "#add-contact p.help.is-danger" (:input :error))
          (:expect-stored :no-contact-with-email (:input :email))))

(d:define-suite active-search-db
  :cases (add-contact invalid-contact)
  :target (db-app-target))

(defun run-db-acceptance (&key out (viewports '(:desktop)) (schemes '(:light)) (explain t))
  "Run the active-search-db suite against the DB-backed example app on a scratch SQLite database
and write the report to OUT, by default DOKIMASIA:*DEFAULT-OUT*. Returns true when every row
passed, and the path of report.txt."
  (d:run :active-search-db :out out :viewports viewports :schemes schemes :explain explain))
