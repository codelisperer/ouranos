;;;; app.lisp --- Active Search, DB-backed: the HTMX example over a mnemosyne migration.
;;;;
;;;; A port of examples/active-search that sources its data from SQLite instead of an
;;;; in-memory list, to show the whole stack end to end: on startup a **migration** creates
;;;; (and an index adorns) the contacts table -- its CREATE TABLE **derived from a defschema**
;;;; via schema-ddl -- and seeds it; each keystroke drives an HTMX POST that runs a
;;;; **data-driven query** (LIKE across name/email/role) and swaps the server-rendered rows
;;;; in. The UI (Bulma + HTMX + Alpine + a Parenscript keyboard shortcut) is unchanged from
;;;; active-search; only %search + the seed/migrate startup are new.

(cl:defpackage #:hyperion/examples/active-search-db
  (:use #:cl)
  (:local-nicknames (#:srv     #:hyperion/server)
                    (#:http    #:hyperion/http)
                    (#:out     #:hyperion/output)
                    (#:dev     #:hyperion/dev)
                    (#:hjs     #:hyperion/js)
                    (#:spin    #:spinneret)
                    (#:assets  #:hyperion/assets)
                    (#:router  #:hyperion/router)
                    (#:be      #:mnemosyne/backend)
                    (#:conn    #:mnemosyne/conn)
                    (#:migrate #:mnemosyne/migrate)
                    (#:query   #:mnemosyne/query)
                    (#:schema  #:mnemosyne/schema)
                    (#:id      #:mnemosyne/id))
  (:import-from #:parenscript #:chain #:@)
  (:export #:make-app #:start #:stop #:dev #:serve #:main #:ensure-db #:*port*))

(cl:in-package #:hyperion/examples/active-search-db)

;;; --- the data layer (mnemosyne) -------------------------------------------
(defun db-path ()
  "The SQLite file, kept beside this example regardless of the working directory.

Deliberately inside a `data/` subdirectory that is NOT in the repo: SQLite creates the
database file but never its folder, so this path would once have failed a first run with a
bare \"unable to open database file\". mnemosyne/conn:connect now creates the parent, and
this example exercises that -- the layout an app actually wants (db files in their own
gitignored directory) works with no app-side guard."
  (namestring (asdf:system-relative-pathname
               :hyperion "examples/active-search-db/data/active-search.db")))
(defun backend () (be:make-sqlite (db-path)))

(schema:defschema contact (:table "contacts")
  (:_id   :string  :primary t)
  (:vid   :integer)
  (:name  :string  :required t)
  (:email :string)
  (:role  :string))

(defparameter *migrations*
  (list
   (be:make-migration
    "20260725_001_create_contacts" "create the contacts table"
    (schema:schema-ddl (schema:find-schema 'contact) :dialect "sqlite")   ; derived, not hand-written
    "DROP TABLE IF EXISTS contacts")
   (be:make-migration
    "20260725_002_index_name" "index contacts by name"
    "CREATE INDEX IF NOT EXISTS idx_contacts_name ON contacts (name)"
    "DROP INDEX IF EXISTS idx_contacts_name")))

(defparameter *seed*
  '(("Ada Lovelace"      "ada@analytical.engine" "Mathematician")
    ("Alan Turing"       "alan@bletchley.uk"     "Computer Scientist")
    ("Grace Hopper"      "grace@navy.mil"        "Rear Admiral")
    ("John McCarthy"     "jmc@stanford.edu"      "Lisp")
    ("Barbara Liskov"    "liskov@mit.edu"        "Substitution")
    ("Guy Steele"        "gls@acm.org"           "Lambda")
    ("Rich Hickey"       "rich@clojure.org"      "Clojure")
    ("Robert Smith"      "rsmith@coalton.dev"    "Coalton")
    ("Sophie Wilson"     "sophie@arm.com"        "ARM")
    ("Margaret Hamilton" "mh@nasa.gov"           "Apollo")))

(defun %col (row key)
  "Value of column KEY from a fetched ROW plist, case-insensitively (drivers vary on case)."
  (loop for (k v) on row by #'cddr
        when (and (symbolp k) (string-equal (symbol-name k) (symbol-name key)))
          do (return v)))

(defun %row-count (c)
  (or (%col (first (query:fetch c '(:select ((:as (:count :*) :n)) :from ("contacts"))
                                :dialect :sqlite))
            :n)
      0))

(defun ensure-db ()
  "Bring the database up: apply pending migrations (idempotent), then seed if the table is
empty. Each seed row is stamped by mnemosyne/id:touch! (a v6 _id + monotonic vid).

Returns (values applied-migration-ids seeded-names) -- what this run actually DID, which is
the difference between a usable first run and a silent one. An idempotent seed creates what
is missing exactly once, so the run that creates it is the only chance to tell anyone: in a
real app these are the one-time credentials, and if they only scroll past in a log nobody
can sign in. The entry points below announce them.

Called by every ENTRY POINT, never by MAKE-APP. Keeping DB bring-up out of the app factory
is what lets a test suite build the app without a database -- and stops a second entry point
(the hot-reload one) from quietly serving pages against an empty schema."
  (conn:with-connection (c (backend))
    (let ((applied (migrate:migrate (backend) c *migrations*))
          (seeded '()))
      (when (zerop (%row-count c))
        (dolist (row *seed*)
          (destructuring-bind (name email role) row
            (let ((e (make-hash-table)))
              (setf (gethash :name e) name (gethash :email e) email (gethash :role e) role)
              (id:touch! e "seed")
              (query:run c (list :insert-into "contacts"
                                 :values (list (list :_id (gethash :_id e) :vid (gethash :vid e)
                                                     :name name :email email :role role)))
                         :dialect :sqlite)
              (push name seeded)))))
      (values applied (nreverse seeded)))))

(defun %announce-db (applied seeded)
  "Say what bring-up did. In a real app the seeded principals carry one-time credentials --
print them where the operator will see them, not only into a log."
  (when applied
    (format t "~&[db] applied ~D migration~:P: ~{~A~^, ~}~%" (length applied) applied))
  (when seeded
    (format t "~&[db] seeded ~D contact~:P: ~{~A~^, ~}~%" (length seeded) seeded))
  (unless (or applied seeded)
    (format t "~&[db] up to date~%"))
  (finish-output))

(defun %search (q)
  "Rows (plists) matching Q via a LIKE across name/email/role; all rows if Q is blank."
  (conn:with-connection (c (backend))
    (query:fetch c
                 (if (or (null q) (string= q ""))
                     '(:select (:name :email :role) :from ("contacts") :order-by (:name))
                     (let ((pat (format nil "%~A%" q)))
                       (list :select '(:name :email :role) :from '("contacts")
                             :where (list :or (list :like :name pat)
                                          (list :like :email pat)
                                          (list :like :role pat))
                             :order-by '(:name))))
                 :dialect :sqlite)))

;;; --- rendering (Spinneret) -- unchanged from active-search, reading plists ---
(defun %rows (rows)
  "The <tbody> contents -- the HTMX swap target; shared by first load and the /search fragment."
  (spin:with-html-string
    (if (null rows)
        (:tr (:td :colspan "3" :class "has-text-grey has-text-centered py-5" "No matches."))
        (dolist (r rows)
          (:tr
           (:td (%col r :name))
           (:td (:a :href (format nil "mailto:~A" (%col r :email)) (%col r :email)))
           (:td (:span :class "tag is-info is-light" (%col r :role))))))))

(defun %app-js ()
  "Press '/' outside a text field to focus the search box -- Lisp compiled to JS by Parenscript."
  (out:js-string
   `(funcall
     (lambda ()
       (chain document
              (add-event-listener
               "keydown"
               (lambda (e)
                 (let ((tag (@ document active-element tag-name)))
                   (when (and (equal (@ e key) "/")
                              (not (chain (list "INPUT" "TEXTAREA") (includes tag))))
                     (chain e (prevent-default))
                     (let ((box (chain document (get-element-by-id "q"))))
                       (when box (chain box (focus)))))))))))))

(defun %page ()
  (spin:with-html-string
    (:doctype)
    (:html :lang "en"
     (:head
      (:meta :charset "utf-8")
      (:meta :name "viewport" :content "width=device-width, initial-scale=1")
      (:title "Active Search (DB) — Hyperion + mnemosyne")
      ;; Vendored and embedded in the image, not fetched from a CDN (pre-publication issue 123): the
      ;; examples are the argument for "no Node, no bundler, no asset pipeline", so
      ;; they should not be pulling their JavaScript off npm to make it.
      (:link :rel "stylesheet" :href (assets:url :bulma))
      (:script :src (assets:url :htmx) :defer t)
      (:script :src (assets:url :alpine) :defer t))
     (:body
      (:section :class "section"
       (:div :class "container"
        (:h1 :class "title" "Contacts")
        (:p :class "subtitle is-6 has-text-grey"
            "Backed by SQLite via a mnemosyne migration; HTMX filters server-side with a "
            (:code "LIKE") " query; press " (:kbd "/") " to focus.")
        (:div :x-data "{ q: '' }"
         (:div :class "field"
          (:div :class "control"
           (:input :id "q" :name "q" :class "input is-medium" :type "search"
                   :placeholder "Search name, email, or role…" :autocomplete "off"
                   :autofocus t
                   :x-model "q"
                   :hx-post "/search"
                   :hx-trigger "input changed delay:250ms, search"
                   :hx-target "#results")))
         (:p :class "help"
             :x-text "q.length ? ('Filtering: ' + q) : 'Showing all contacts.'"))
        (:table :class "table is-fullwidth is-hoverable mt-4"
         (:thead (:tr (:th "Name") (:th "Email") (:th "Role")))
         (:tbody :id "results" (:raw (%rows (%search nil)))))))
      (:script (:raw (%app-js)))))))

;;; --- the Clack app ---------------------------------------------------------
(defun %handle-search (env)
  (let ((q (http:form-param (http:body-string env) "q")))
    (list 200 '(:content-type "text/html; charset=utf-8") (list (%rows (%search q))))))

(defun %handle-home ()
  (lambda (env)
    (declare (ignore env))
    (list 200 '(:content-type "text/html; charset=utf-8") (list (%page)))))

(defun %routes ()
  "This app's route table -- DATA. The vendored assets arrive as a MOUNT, so this app
never names their paths. There is no dev wiring here: hyperion/dev:serve wraps the app in
DEV:WRAP-DEV, which serves the reload endpoints, injects the poller, and registers both
paths as QUIET so the polling does not bury the developer's own output (pre-publication issue 132)."
  (router:router
   (assets:mount)
   (router:route :get "/" (%handle-home) :name :home)
   (router:route :post "/search" #'%handle-search :name :search)))

(defun make-app ()
  "The route table above as a Clack handler, wrapped in this app's output style.

Touches NO database: bring-up belongs to the entry points (START / DEV / SERVE), so a test
suite can build this app and exercise routing without a DB, and no entry point can forget
to migrate by going around it."
  (let ((routes (%routes)))
    (lambda (env)
      (out:with-output-style ()
        (router:dispatch routes env)))))

;;; --- lifecycle -------------------------------------------------------------
(defparameter *port* 8080)

(defun start (&key (port *port*) (host "127.0.0.1") dev
                   (server (srv:default-server)) debug)
  "Ensure the DB (migrate + seed), then start the server; returns the handler (STOP to stop)."
  (setf out:*output-style* (if dev :pretty :compact))
  (multiple-value-bind (applied seeded) (ensure-db)
    (%announce-db applied seeded))
  (srv:start (make-app) :server server :port port :host host :debug debug))

(defun stop (handler) (srv:stop handler))

(defun %sources ()
  "This example's source directory -- what DEV watches. The examples live in hyperion's
tree rather than in systems of their own, so there is no `src/` for DEV:SERVE's :SYSTEM to
resolve and the root is named directly."
  (list (asdf:system-relative-pathname :hyperion "examples/active-search-db/")))

(defun dev (&key (port *port*) (host "127.0.0.1"))
  "Hot-reload dev server: edit app.lisp, save, the browser refreshes. Open http://HOST:PORT.
Stop: (hyperion/dev:unwatch).

The DB comes up HERE rather than inside the builder: DEV:SERVE calls the builder again on
every reload, and migrating on each save would be both wrong and slow."
  (setf out:*output-style* :pretty)
  (multiple-value-bind (applied seeded) (ensure-db)
    (%announce-db applied seeded))
  (dev:serve #'make-app :port port :host host :paths (%sources)))

(defun serve (&key (port *port*) (host "127.0.0.1"))
  "Start and BLOCK until interrupted (the native-binary entry). HOST \"0.0.0.0\" for LAN.

The shape a DB-backed app should copy: bring the database up HERE, in the entry point, then
hand the app to the framework. Bring-up stays out of MAKE-APP so a test suite can build the
app without a database (docs/migrations.md), and the eleven lines of banner/interrupt/
unwind that used to live here are SERVE-FOREVER's job now (pre-publication issue 124)."
  (setf out:*output-style* :compact)
  (multiple-value-bind (applied seeded) (ensure-db)
    (%announce-db applied seeded))
  (srv:serve-forever (make-app) :port port :host host :name "Active Search (DB)"))

(defun %argv (name default)
  (or (second (member name (uiop:command-line-arguments) :test #'string=)) default))

(defun main ()
  "Native-binary entry: serve, honoring --port N / --host ADDR."
  (serve :port (or (ignore-errors (parse-integer (%argv "--port" nil))) *port*)
         :host (%argv "--host" "127.0.0.1"))
  (uiop:quit 0))
