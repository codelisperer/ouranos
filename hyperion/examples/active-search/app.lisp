;;;; app.lisp --- Active Search: Bulma + HTMX + Alpine + Parenscript (compiled JS).
;;;;
;;;; The first Hyperion example, and a milestone check: it exercises the whole core
;;;; loop with no Node in sight.
;;;;   - Spinneret renders the page and the fragment (server-side HTML).
;;;;   - HTMX posts the query and swaps the server-rendered result rows in.
;;;;   - Alpine handles pure client reactivity (a live echo of the query) -- on the
;;;;     SAME input HTMX drives, showing the two coexist.
;;;;   - The keyboard shortcut ('/' focuses the box) is authored in Lisp and compiled
;;;;     to JS by Parenscript -- "compiled JS doing something interesting."
;;;;
;;;; Like praxeon's elise: runnable in dev with hot-reload ((:dev t) -> the browser
;;;; refreshes as you edit), and buildable to a native binary (`make example-search-bin`).
;;;; Vendor libs come from a CDN here for a one-command demo; a real app would serve
;;;; them from resources/ via hyperion/static (see a consuming app).

(cl:defpackage #:hyperion/examples/active-search
  (:use #:cl)
  (:local-nicknames (#:srv  #:hyperion/server)
                    (#:http #:hyperion/http)
                    (#:out  #:hyperion/output)
                    (#:dev  #:hyperion/dev)
                    (#:hjs  #:hyperion/js)
                    (#:assets #:hyperion/assets)
                    (#:router #:hyperion/router)
                    (#:spin #:spinneret))
  ;; Parenscript matches its own macros by symbol identity -- import the real ones.
  (:import-from #:parenscript #:chain #:@)
  (:export #:make-app #:start #:stop #:dev #:serve #:main #:*port*))

(cl:in-package #:hyperion/examples/active-search)

;;; --- data (in-memory) ------------------------------------------------------
(defstruct (contact (:constructor contact (name email role)))
  name email role)

(defparameter *contacts*
  (list (contact "Ada Lovelace"      "ada@analytical.engine" "Mathematician")
        (contact "Alan Turing"       "alan@bletchley.uk"     "Computer Scientist")
        (contact "Grace Hopper"      "grace@navy.mil"        "Rear Admiral")
        (contact "John McCarthy"     "jmc@stanford.edu"      "Lisp")
        (contact "Barbara Liskov"    "liskov@mit.edu"        "Substitution")
        (contact "Guy Steele"        "gls@acm.org"           "Lambda")
        (contact "Rich Hickey"       "rich@clojure.org"      "Clojure")
        (contact "Robert Smith"      "rsmith@coalton.dev"    "Coalton")
        (contact "Sophie Wilson"     "sophie@arm.com"        "ARM")
        (contact "Margaret Hamilton" "mh@nasa.gov"           "Apollo"))
  "The demo dataset -- searched server-side.")

(defun %match (down c)
  (or (search down (string-downcase (contact-name c)))
      (search down (string-downcase (contact-email c)))
      (search down (string-downcase (contact-role c)))))

(defun %search (q)
  (if (or (null q) (string= q ""))
      *contacts*
      (remove-if-not (lambda (c) (%match (string-downcase q) c)) *contacts*)))

;;; --- rendering (Spinneret) -------------------------------------------------
(defun %rows (contacts)
  "The <tbody> contents -- the HTMX swap target. Rendered both on first load and as
the /search fragment, so the page and the partial share one renderer."
  (spin:with-html-string
    (if (null contacts)
        (:tr (:td :colspan "3" :class "has-text-grey has-text-centered py-5"
                  "No matches."))
        (dolist (c contacts)
          (:tr
           (:td (contact-name c))
           (:td (:a :href (format nil "mailto:~A" (contact-email c)) (contact-email c)))
           (:td (:span :class "tag is-info is-light" (contact-role c))))))))

(defun %app-js ()
  "Client behavior authored in Lisp, compiled to JS by Parenscript (no Node): press
'/' anywhere outside a text field to focus the search box (GitHub-style)."
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
      (:title "Active Search — Hyperion example")
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
            "HTMX filters server-side; Alpine echoes your query live; press "
            (:kbd "/") " to focus — that shortcut is Lisp compiled to JS.")
        ;; one input, two client techs: Alpine x-model (instant echo) +
        ;; HTMX (debounced POST that swaps in server-rendered rows).
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
         (:tbody :id "results" (:raw (%rows *contacts*))))))
      (:script (:raw (%app-js)))))))

;;; --- the Clack app ---------------------------------------------------------
(defun %handle-search (env)
  (let ((q (http:form-param (http:body-string env) "q")))
    (list 200 '(:content-type "text/html; charset=utf-8")
          (list (%rows (%search q))))))

(defun %handle-home ()
  "GET / -- the page."
  (lambda (env)
    (declare (ignore env))
    (list 200 '(:content-type "text/html; charset=utf-8") (list (%page)))))

(defun %routes ()
  "This app's route table -- DATA, not a `cond`. (hyperion/router:describe-routes
 (%routes)) prints exactly what the app answers, which the hand-rolled dispatcher
this replaces could not do for anyone, including its author.

The vendored assets arrive as a MOUNT: hyperion/assets contributes its own routes
instead of this app knowing their paths. There is no dev wiring here: hyperion/dev:serve
wraps the app in DEV:WRAP-DEV, which serves the reload endpoints and injects the poller
itself (pre-publication issue 132) -- and registers those paths as QUIET, which a hand-rolled copy cannot do."
  (router:router
   (assets:mount)
   (router:route :get "/" (%handle-home) :name :home)
   (router:route :post "/search" #'%handle-search :name :search)))

(defun make-app ()
  "The Clack handler: the route table above, wrapped so every response renders in
this app's output style (dev pretty / prod compact, per request).

404 and 405 now come from the router: a path no route claims is 404, and a known
path with the wrong method is 405 with a computed `Allow` -- which the `cond` this
replaces could not distinguish even in principle."
  (let ((routes (%routes)))
    (lambda (env)
      (out:with-output-style ()
        (router:dispatch routes env)))))

;;; --- lifecycle -------------------------------------------------------------
(defparameter *port* 8080)

(defun start (&key (port *port*) (host "127.0.0.1") dev
                   (server (srv:default-server)) debug)
  "Build the app and start the server; returns the handler (stop with STOP). DEV t
renders pretty, else compact (prod) -- the poller now comes from DEV:WRAP-DEV, so that is
the only thing DEV still selects."
  (setf out:*output-style* (if dev :pretty :compact))
  (srv:start (make-app) :server server :port port :host host :debug debug))

(defun stop (handler) (srv:stop handler))

(defun %sources ()
  "This example's source directory -- what DEV watches. The examples live in hyperion's
tree rather than in systems of their own, so there is no `src/` for DEV:SERVE's :SYSTEM to
resolve and the root is named directly."
  (list (asdf:system-relative-pathname :hyperion "examples/active-search/")))

(defun dev (&key (port *port*) (host "127.0.0.1"))
  "Hot-reload dev server: edit app.lisp, save, and the browser refreshes. Open
http://HOST:PORT. HOST \"0.0.0.0\" to reach it from another machine. Stop: (hyperion/dev:unwatch)."
  (setf out:*output-style* :pretty)
  (dev:serve #'make-app :port port :host host :paths (%sources)))

(defun serve (&key (port *port*) (host "127.0.0.1"))
  "Start and BLOCK until interrupted (the native-binary entry). HOST \"0.0.0.0\" for LAN.

This used to be eleven lines of banner, UNWIND-PROTECT and interrupt handling, copied
verbatim into four apps (pre-publication issue 124). None of it was app knowledge -- it was \"how this
framework's server runs in the foreground\" -- so it moved into the framework and this is
what is left. An app that needs setup before serving does it here, above the call."
  (setf out:*output-style* :compact)
  (srv:serve-forever (make-app) :port port :host host :name "Active Search"))

(defun %argv (name default)
  (or (second (member name (uiop:command-line-arguments) :test #'string=)) default))

(defun main ()
  "Native-binary entry (see `make example-search-bin`): serve, honoring
--port N / --host ADDR (default 127.0.0.1; 0.0.0.0 for LAN)."
  (serve :port (or (ignore-errors (parse-integer (%argv "--port" nil))) *port*)
         :host (%argv "--host" "127.0.0.1"))
  (uiop:quit 0))
