;;;; router-tests.lisp --- the typed path core (hyperion/path) + dispatch (hyperion/router).
;;;;
;;;; Two suites, mirroring the split: PATH tests the pure Coalton matcher as pure
;;;; logic (no env, no handlers), ROUTER tests the CL shell's dispatch semantics --
;;;; including the three things a hand-rolled `cond` could not do: bind a path
;;;; parameter, tell 405 from 404, and be enumerated.
;;;;
;;;; Helpers are %RT-prefixed on purpose. hyperion/tests is ONE package shared by every
;;;; *-tests.lisp file, loaded :serial, so a bare helper name is a live collision: an
;;;; unprefixed %ENV here was silently clobbered by session-tests.lisp's own %ENV (a
;;;; different arity), which loads later -- every router test then failed with "invalid
;;;; number of arguments" pointing at nothing.

(in-package #:hyperion/tests)

(def-suite path :description "Path templates and matching (Coalton core)." :in hyperion)
(def-suite router :description "URL dispatch (CL shell)." :in hyperion)

;;; ==========================================================================
;;; The pure matcher
;;; ==========================================================================
(in-suite path)

(defun %rt-match? (template path)
  "Does PATH match TEMPLATE?"
  (path:path-matches? (path:parse-pattern template) path))

(defun %rt-bind (template path)
  "PATH's bindings against TEMPLATE, as the flat name/value list Coalton returns."
  (path:path-bindings (path:parse-pattern template) path))

(test literal-segments-match-exactly
  (is-true (%rt-match? "/contacts" "/contacts"))
  (is-false (%rt-match? "/contacts" "/contact"))
  (is-false (%rt-match? "/contacts" "/contacts/1"))
  (is-false (%rt-match? "/contacts/new" "/contacts")))

(test root-and-empty-are-the-same-path
  (is-true (%rt-match? "/" "/"))
  (is-true (%rt-match? "/" ""))
  (is-true (%rt-match? "" "/")))

(test trailing-and-doubled-slashes-never-decide-a-match
  ;; Dropping empty segments is what makes these one template -- so an app never
  ;; has to declare both spellings, and a stray // in a generated link still routes.
  (is-true (%rt-match? "/a/b" "/a/b/"))
  (is-true (%rt-match? "/a/b/" "/a/b"))
  (is-true (%rt-match? "/a/b" "//a//b//"))
  (is-true (%rt-match? "a/b" "/a/b")))

(test params-bind-by-name
  (is-true (%rt-match? "/contacts/:id" "/contacts/42"))
  (is (equal '("id" "42") (%rt-bind "/contacts/:id" "/contacts/42")))
  (is (equal '("id" "42" "note" "7")
             (%rt-bind "/contacts/:id/notes/:note" "/contacts/42/notes/7"))))

(test a-param-needs-a-segment-to-bind
  (is-false (%rt-match? "/contacts/:id" "/contacts"))
  (is-false (%rt-match? "/contacts/:id" "/contacts/42/extra")))

(test params-bind-anything-including-odd-characters
  ;; The matcher splits on / and binds whatever a segment holds; it deliberately does
  ;; not validate. Typing a parameter is the caller's job (and a later question).
  (is (equal '("id" "a b") (%rt-bind "/x/:id" "/x/a b")))
  (is (equal '("id" ":literal-colon") (%rt-bind "/x/:id" "/x/:literal-colon"))))

(test rest-slurps-the-remainder-joined
  (is (equal '("rest" "a/b/c") (%rt-bind "/files/*" "/files/a/b/c")))
  (is (equal '("rest" "a") (%rt-bind "/files/*" "/files/a"))))

(test rest-also-matches-nothing
  ;; "/files/*" claiming "/files" is deliberate: a catch-all that refused the bare
  ;; prefix would need every app to declare the prefix twice.
  (is-true (%rt-match? "/files/*" "/files"))
  (is (equal '("rest" "") (%rt-bind "/files/*" "/files"))))

(test bindings-are-empty-when-nothing-matched
  ;; PATH-BINDINGS cannot distinguish "no match" from "matched, bound nothing" --
  ;; both are the empty list. That is why PATH-MATCHES? exists and why the router
  ;; asks it first.
  (is (equal '() (%rt-bind "/contacts/:id" "/nope/42")))
  (is (equal '() (%rt-bind "/contacts" "/contacts"))))

(test pattern-params-lists-names-in-template-order
  (is (equal '() (path:pattern-params (path:parse-pattern "/a/b"))))
  (is (equal '("id" "note")
             (path:pattern-params (path:parse-pattern "/c/:id/n/:note"))))
  (is (equal '("rest") (path:pattern-params (path:parse-pattern "/files/*")))))

(test pattern-valid-rejects-a-rest-that-is-not-last
  (is-true (path:pattern-valid? (path:parse-pattern "/files/*")))
  (is-true (path:pattern-valid? (path:parse-pattern "/a/:b/c")))
  ;; Everything after a `*` is unreachable -- a typo, not an intention.
  (is-false (path:pattern-valid? (path:parse-pattern "/files/*/nope")))
  (is-false (path:pattern-valid? (path:parse-pattern "/*/x"))))

(test normalize-path-is-canonical-and-idempotent
  (is (string= "/a/b" (path:normalize-path "/a/b")))
  (is (string= "/a/b" (path:normalize-path "//a//b//")))
  (is (string= "/" (path:normalize-path "")))
  (is (string= "/" (path:normalize-path "///")))
  (let ((once (path:normalize-path "//x//y/")))
    (is (string= once (path:normalize-path once)))))

;;; ==========================================================================
;;; Dispatch
;;; ==========================================================================
(in-suite router)

(defun %rt-env (method path &rest extra)
  "A minimal Clack env: dispatch reads only the method and the path."
  (append (list :request-method method :path-info path) extra))

(defun %rt-ok (&optional (body "ok"))
  (lambda (env) (declare (ignore env))
    (list 200 '(:content-type "text/plain") (list body))))

(defun %rt-status (response) (first response))
(defun %rt-headers (response) (second response))
(defun %rt-body (response) (third response))

(test a-matching-route-runs-its-handler
  (let ((r (rt:router (rt:route :get "/" (%rt-ok "home")))))
    (let ((response (rt:dispatch r (%rt-env :get "/"))))
      (is (= 200 (%rt-status response)))
      (is (equal '("home") (%rt-body response))))))

(test a-handler-reads-its-path-parameters
  ;; The capability no hand-rolled dispatcher had: this is why no example in the tree
  ;; has a detail view.
  (let ((r (rt:router
            (rt:route :get "/contacts/:id"
                      (lambda (env)
                        (list 200 '(:content-type "text/plain")
                              (list (rt:path-param env "id"))))))))
    (is (equal '("42") (%rt-body (rt:dispatch r (%rt-env :get "/contacts/42")))))))

(test path-params-is-an-alist-and-a-missing-name-is-nil
  (let* ((seen nil)
         (r (rt:router (rt:route :get "/a/:x/b/:y"
                                 (lambda (env) (setf seen env) (funcall (%rt-ok) env))))))
    (rt:dispatch r (%rt-env :get "/a/1/b/2"))
    (is (equal '(("x" . "1") ("y" . "2")) (rt:path-params seen)))
    (is (string= "1" (rt:path-param seen "x")))
    (is (null (rt:path-param seen "nope")))))

(test handlers-keep-the-plain-clack-shape
  ;; Bindings ride the env, so an existing (env -> response) handler is routable
  ;; unchanged -- which is what makes porting the four hand-rolled dispatchers cheap.
  (let* ((existing (lambda (env) (list 200 '() (list (getf env :path-info)))))
         (r (rt:router (rt:route :get "/x" existing))))
    (is (equal '("/x") (%rt-body (rt:dispatch r (%rt-env :get "/x")))))))

(test an-unclaimed-path-is-404
  (let ((r (rt:router (rt:route :get "/" (%rt-ok)))))
    (is (= 404 (%rt-status (rt:dispatch r (%rt-env :get "/nope")))))))

(test a-known-path-with-the-wrong-method-is-405-with-allow
  ;; The structural win: a hand-rolled (and (eq method :get) (string= path "/x"))
  ;; answers 404 here, because it cannot tell the two failures apart.
  (let* ((r (rt:router (rt:route :get "/x" (%rt-ok))
                       (rt:route :post "/x" (%rt-ok))))
         (response (rt:dispatch r (%rt-env :delete "/x"))))
    (is (= 405 (%rt-status response)))
    (is (string= "GET, POST, HEAD, OPTIONS" (getf (%rt-headers response) :allow)))))

(test allow-omits-head-when-no-get-route-exists
  (let ((r (rt:router (rt:route :post "/x" (%rt-ok)))))
    (is (string= "POST, OPTIONS"
                 (getf (%rt-headers (rt:dispatch r (%rt-env :get "/x"))) :allow)))))

(test head-is-answered-by-the-get-route-with-no-body
  (let* ((r (rt:router (rt:route :get "/x" (%rt-ok "content"))))
         (response (rt:dispatch r (%rt-env :head "/x"))))
    (is (= 200 (%rt-status response)))
    (is (equal '(:content-type "text/plain") (%rt-headers response)))
    (is (equal '() (%rt-body response)))))

(test options-is-answered-from-the-same-allow-set
  ;; Derived, not declarable -- so it cannot drift from the routes it describes.
  (let* ((r (rt:router (rt:route :get "/x" (%rt-ok)) (rt:route :put "/x" (%rt-ok))))
         (response (rt:dispatch r (%rt-env :options "/x"))))
    (is (= 204 (%rt-status response)))
    (is (string= "GET, PUT, HEAD, OPTIONS" (getf (%rt-headers response) :allow)))))

(test options-on-an-unknown-path-is-still-404
  (let ((r (rt:router (rt:route :get "/x" (%rt-ok)))))
    (is (= 404 (%rt-status (rt:dispatch r (%rt-env :options "/nope")))))))

(test first-match-wins-so-a-literal-can-shadow-a-param
  (let ((r (rt:router (rt:route :get "/contacts/new" (%rt-ok "new"))
                      (rt:route :get "/contacts/:id" (%rt-ok "show")))))
    (is (equal '("new") (%rt-body (rt:dispatch r (%rt-env :get "/contacts/new")))))
    (is (equal '("show") (%rt-body (rt:dispatch r (%rt-env :get "/contacts/9")))))))

(test declaration-order-decides-and-is-not-specificity
  ;; Stated as a test because it is a real trap: declared the other way round, the
  ;; param swallows the literal. The router does not reorder by specificity.
  (let ((r (rt:router (rt:route :get "/contacts/:id" (%rt-ok "show"))
                      (rt:route :get "/contacts/new" (%rt-ok "new")))))
    (is (equal '("show") (%rt-body (rt:dispatch r (%rt-env :get "/contacts/new")))))))

(test to-app-is-a-clack-handler
  (let ((app (rt:to-app (rt:router (rt:route :get "/" (%rt-ok "via-app"))))))
    (is (functionp app))
    (is (equal '("via-app") (%rt-body (funcall app (%rt-env :get "/")))))))

;;; --- mounting -------------------------------------------------------------

(test a-mounted-router-sees-the-path-with-its-prefix-stripped
  (let* ((sub (rt:router (rt:route :get "/reload" (%rt-ok "reloaded"))))
         (r (rt:router (rt:mount "/api" sub))))
    (is (equal '("reloaded") (%rt-body (rt:dispatch r (%rt-env :get "/api/reload")))))
    (is (= 404 (%rt-status (rt:dispatch r (%rt-env :get "/reload")))))))

(test a-mount-prefix-matches-on-a-segment-boundary-only
  ;; "/api" must not claim "/apiary".
  (let* ((sub (rt:router (rt:route :get "/*" (%rt-ok "sub"))))
         (r (rt:router (rt:mount "/api" sub))))
    (is (equal '("sub") (%rt-body (rt:dispatch r (%rt-env :get "/api/x")))))
    (is (= 404 (%rt-status (rt:dispatch r (%rt-env :get "/apiary/x")))))))

(test a-mount-claims-its-bare-prefix
  (let* ((sub (rt:router (rt:route :get "/" (%rt-ok "index"))))
         (r (rt:router (rt:mount "/api" sub))))
    (is (equal '("index") (%rt-body (rt:dispatch r (%rt-env :get "/api")))))
    (is (equal '("index") (%rt-body (rt:dispatch r (%rt-env :get "/api/")))))))

(test params-bind-through-a-mount
  (let* ((sub (rt:router
               (rt:route :get "/contacts/:id"
                         (lambda (env) (list 200 '() (list (rt:path-param env "id")))))))
         (r (rt:router (rt:mount "/v1" sub))))
    (is (equal '("7") (%rt-body (rt:dispatch r (%rt-env :get "/v1/contacts/7")))))))

(test a-method-mismatch-inside-a-mount-is-405-not-404
  ;; The mounted table's methods have to propagate, or nesting would silently
  ;; downgrade a 405 to a 404.
  (let* ((sub (rt:router (rt:route :post "/thing" (%rt-ok))))
         (r (rt:router (rt:mount "/api" sub)))
         (response (rt:dispatch r (%rt-env :get "/api/thing"))))
    (is (= 405 (%rt-status response)))
    (is (string= "POST, OPTIONS" (getf (%rt-headers response) :allow)))))

(test mounts-nest
  (let* ((leaf (rt:router (rt:route :get "/deep" (%rt-ok "deep"))))
         (mid (rt:router (rt:mount "/b" leaf)))
         (top (rt:router (rt:mount "/a" mid))))
    (is (equal '("deep") (%rt-body (rt:dispatch top (%rt-env :get "/a/b/deep")))))))

;;; --- declaration-time validation ------------------------------------------

(test an-unroutable-method-is-rejected-at-declaration
  ;; Caught where the typo is, not on the request that needed it.
  (signals rt:route-error (rt:route :gett "/x" (%rt-ok)))
  (signals rt:route-error (rt:route :options "/x" (%rt-ok)))   ; derived, never declared
  (signals rt:route-error (rt:route :head "/x" (%rt-ok))))

(test a-rest-segment-that-is-not-last-is-rejected
  (signals rt:route-error (rt:route :get "/files/*/nope" (%rt-ok))))

(test a-repeated-parameter-name-is-rejected
  (signals rt:route-error (rt:route :get "/a/:id/b/:id" (%rt-ok))))

(test a-router-rejects-entries-that-are-not-routes-or-mounts
  (signals rt:route-error (rt:router "/x")))

(test route-error-reports-a-message
  (handler-case (progn (rt:route :nope "/x" (%rt-ok))
                       (is-true nil "declaring :nope should have signalled"))
    (rt:route-error (e)
      (is (search "not a routable method" (rt:route-error-message e))))))

;;; --- introspection --------------------------------------------------------

(test the-route-table-is-data
  (let* ((r (rt:router (rt:route :get "/" (%rt-ok) :name :home)
                       (rt:route :post "/contacts/:id" (%rt-ok) :name :update))))
    (is (= 2 (length (rt:routes r))))
    (let ((second (second (rt:routes r))))
      (is (eq :post (rt:route-method second)))
      (is (string= "/contacts/:id" (rt:route-template second)))
      (is (equal '("id") (rt:route-params second)))
      (is (eq :update (rt:route-name second))))))

(test describe-routes-renders-the-table-including-mounts
  (let* ((sub (rt:router (rt:route :get "/reload" (%rt-ok))))
         (r (rt:router (rt:route :get "/contacts/:id" (%rt-ok)) (rt:mount "/api" sub)))
         (text (with-output-to-string (s) (rt:describe-routes r :stream s))))
    (is (search "GET" text))
    (is (search "/contacts/:id" text))
    (is (search ":id" text))
    ;; the mounted route is shown under its full path, not its local one
    (is (search "/api/reload" text))))

(test routes-returns-a-copy-so-callers-cannot-mutate-the-table
  (let* ((r (rt:router (rt:route :get "/" (%rt-ok))))
         (listing (rt:routes r)))
    (setf (car listing) :clobbered)     ; mutates the copy, not the table
    (is (= 1 (length (rt:routes r))))
    (is-true (rt:route-p (first (rt:routes r))))))
