;;;; tests.lisp --- dokimasia/hyperion's tests (#1028): a small hyperion app, written here, that
;;;; the target starts on a scratch SQLite database. The tests without a browser check starting,
;;;; seeding and cleaning up; the browser tests run suites against it in a headless Chrome or Edge
;;;; where one is found.

(defpackage #:dokimasia/hyperion/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:d #:dokimasia)
                    (#:dh #:dokimasia/hyperion)
                    (#:dm #:dokimasia/mnemosyne)
                    (#:cdp #:aion/cdp)
                    (#:router #:hyperion/router)
                    (#:assets #:hyperion/assets)
                    (#:http #:hyperion/http)
                    (#:session #:hyperion/session)
                    (#:ports #:hyperion/test-ports)
                    (#:be #:mnemosyne/backend)
                    (#:conn #:mnemosyne/conn)
                    (#:jzon #:com.inuoe.jzon))
  (:export #:run-tests))

(in-package #:dokimasia/hyperion/tests)

(def-suite dokimasia/hyperion :description "dokimasia/hyperion: a hyperion app started on a scratch database, the htmx settle check and sign-in with a session.")
(in-suite dokimasia/hyperion)

(defun run-tests ()
  (run! 'dokimasia/hyperion))

;;; --- the app --------------------------------------------------------------------------------

(defvar *sessions* nil "The running test app's session store.")

(defun %html (body &rest headers)
  (list 200 (list* :content-type "text/html; charset=utf-8" headers) (list body)))

(defun %page (title body)
  (%html (format nil "<!doctype html>
<html lang=\"en\"><head><meta charset=\"utf-8\"><title>~A</title>
<meta name=\"htmx-config\" content='{\"includeIndicatorStyles\": false}'>
<script src=\"~A\"></script></head>
<body><main>~A</main></body></html>" title (assets:url :htmx) body)))

(defun %user-known-p (backend email)
  (conn:with-connection (c backend)
    (conn:query c "SELECT email FROM users WHERE email = ?" email)))

(defun setup-app (backend)
  (conn:with-connection (c backend)
    (conn:exec c "CREATE TABLE users (email TEXT NOT NULL PRIMARY KEY, plan TEXT NOT NULL)")))

(defun seed-app (backend users)
  (conn:with-connection (c backend)
    (dolist (u users)
      (conn:exec c "INSERT INTO users (email, plan) VALUES (?, ?)" (getf u :email) (getf u :plan)))))

(defun make-app (backend)
  "The test app. / has a button whose htmx request swaps its answer in after a one-second swap
delay; /login signs a stored user in; /me says who is signed in."
  (let ((store (session:make-memory-store)))
    (setf *sessions* store)
    (session:wrap-session
     (router:to-app
      (router:router
       (assets:mount)
       ;; The browser asks for it on every page; a 404 would be logged as an error and fail the step.
       (router:route :get "/favicon.ico" (lambda (env) (declare (ignore env)) (list 204 () (list ""))))
       (router:route :get "/"
                     (lambda (env) (declare (ignore env))
                       (%page "Home" "<h1>Home</h1>
<button id=\"load\" hx-get=\"/later\" hx-target=\"#out\" hx-swap=\"innerHTML swap:1s\">Load</button>
<p id=\"out\">before</p>")))
       (router:route :get "/later"
                     (lambda (env) (declare (ignore env)) (%html "after")))
       (router:route :get "/login"
                     (lambda (env) (declare (ignore env))
                       (%page "Sign in" "<h1>Sign in</h1>
<form id=\"login\" method=\"post\" action=\"/login\">
<label for=\"email\">Email</label><input id=\"email\" name=\"email\" type=\"email\">
<button type=\"submit\">Sign in</button></form>")))
       (router:route :post "/login"
                     (lambda (env)
                       (let ((email (http:form-param (http:body-string env) "email"))
                             (s (session:request-session env)))
                         (cond ((and email (%user-known-p backend email))
                                (session:rotate-session store s)
                                (session:session-set s :user-id email)
                                (list 303 (list :location "/me") (list "")))
                               (t (%page "Sign in" "<h1>Sign in</h1><p>unknown user</p>"))))))
       (router:route :get "/me"
                     (lambda (env)
                       (let ((who (session:session-get (session:request-session env) :user-id)))
                         (%page "You" (format nil "<h1>You</h1><p id=\"who\">~A</p>"
                                              (if who (format nil "signed in as ~A" who)
                                                  "not signed in"))))))))
     store)))

(defparameter +users+
  (list (list :name :alice :email "alice@example.com" :plan "team")))

(defun app-target (&rest options)
  (apply #'dh:hyperion-target :app #'make-app :setup #'setup-app :seed #'seed-app
                              :users +users+ :server :uv options))

;;; --- helpers --------------------------------------------------------------------------------

(defun browser-available-p ()
  "True when a browser can be run. Otherwise skips the test, or fails it when
OURANOS_REQUIRE_BROWSER=1."
  (cond ((cdp:find-browser) t)
        ((equal (uiop:getenv "OURANOS_REQUIRE_BROWSER") "1")
         (fail "no Chrome or Edge was found, and OURANOS_REQUIRE_BROWSER=1") nil)
        (t (skip "no Chrome or Edge was found; set OURANOS_BROWSER to run the browser tests") nil)))

(defun call-with-out (function)
  (let ((dir (aion/fs:make-temporary-directory "dokimasia-hyperion-out")))
    (unwind-protect (funcall function dir)
      (aion/fs:delete-tree dir))))

(defun run-suite (suite target)
  "Run SUITE against TARGET, writing the report to a temporary directory. Returns whether the run
passed and the rows of report.json keyed by \"case/row\"."
  (call-with-out
   (lambda (out)
     (let ((passed (d:run suite :target target :out out :explain nil))
           (rows (make-hash-table :test 'equal)))
       (loop for r across (gethash "rows" (jzon:parse (uiop:read-file-string
                                                       (merge-pathnames "report.json" out))))
             do (setf (gethash (format nil "~A/~A" (gethash "case" r) (gethash "row" r)) rows) r))
       (values passed rows)))))

(defun row-verdict (rows key)
  (let ((r (gethash key rows)))
    (if r (gethash "verdict" r) (format nil "no row ~A" key))))

(defun row-reason (rows key)
  "The reason report.json gives for the row KEY, or \"\" when it gives none."
  (let ((why (let ((r (gethash key rows))) (and r (gethash "reason" r)))))
    (if (stringp why) why "")))

;;; --- starting and stopping, without a browser ------------------------------------------------

(test the-target-starts-the-app-on-a-scratch-database-and-deletes-it-after
  (let* ((target (app-target))
         (base (d:target-start target))
         (db (dh:target-database target))
         (file (be:sqlite-path db))
         (port (parse-integer base :start (1+ (position #\: base :from-end t)))))
    (unwind-protect
         (progn
           (is (uiop:string-prefix-p "http://127.0.0.1:" base))
           (is (ports:listening-p port) "nothing is listening at ~A" base)
           (is (probe-file file) "the database ~A was not made" file)
           (is (%user-known-p db "alice@example.com") "the seeding function did not store alice"))
      (d:target-stop target))
    (is (ports:await-released port) "the port was still accepting after the target stopped")
    (is (null (probe-file file)) "the database ~A is still there" file)
    (is (null (dh:target-database target)))))

(test a-target-whose-setup-fails-leaves-nothing-behind
  (let* ((made nil)
         (target (dh:hyperion-target
                  :app #'make-app :server :uv
                  :setup (lambda (backend)
                           (setf made (be:sqlite-path backend))
                           (error "the migrations failed")))))
    (signals error (d:target-start target))
    (is (stringp made))
    (is (null (probe-file made)) "the database of a target that did not start is still there")))

(test a-hyperion-target-that-cannot-work-is-refused-when-it-is-made
  (flet ((refused (fragment thunk)
           (let ((c (handler-case (progn (funcall thunk) nil) (d:invalid-definition (c) c))))
             (is (typep c 'd:invalid-definition))
             (when c (is (search fragment (d:invalid-definition-reason c))
                         "~S does not mention ~S" (d:invalid-definition-reason c) fragment)))))
    (refused ":APP" (lambda () (dh:hyperion-target)))
    (refused ":SEED" (lambda () (dh:hyperion-target :app #'make-app :seed 3)))
    (refused ":SIGN-IN" (lambda () (dh:hyperion-target :app #'make-app :sign-in :cookie)))
    (refused ":SESSION-STORE" (lambda () (dh:hyperion-target :app #'make-app :sign-in :session)))
    (refused ":SESSION-DATA" (lambda () (dh:hyperion-target :app #'make-app :sign-in :session
                                                            :session-store (lambda () *sessions*))))
    (refused ":NAME" (lambda () (dh:hyperion-target :app #'make-app :users '((:email "a")))))))

;;; --- in the browser ------------------------------------------------------------------------

;; :WAIT-FOR with a timeout far shorter than the swap delay reads the page as the step before it
;; left it, so it passes only if that step waited for htmx to settle.
(d:define-case dh-settle
  :steps ((:visit "/")
          (:click "#load")
          (:wait-for (:expression "document.querySelector('#out').textContent === 'after'")
           :timeout 0.05)))

(d:define-suite dh-settle :cases (dh-settle))

(d:define-case dh-signed-in
  :user :alice
  :steps ((:visit "/me") (:expect-text "#who" "signed in as alice@example.com" :timeout 2)))

(d:define-suite dh-session :cases (dh-signed-in))

(d:define-suite dh-form
  :cases (dh-signed-in)
  :sign-in ((:visit "/login")
            (:fill "#email" (:user :email))
            (:click "button[type=submit]")
            (:expect-text "#who" "signed in as" :timeout 5)))

(dm:define-row-probe :dh-user :source #'dh:current-database :table :users :match '(:email :plan))

(d:define-case dh-stored
  :steps ((:visit "/") (:expect-stored :dh-user "alice@example.com" "team")))

(d:define-suite dh-stored :cases (dh-stored))

(test the-settle-check-waits-for-htmx-to-swap-and-settle
  (when (browser-available-p)
    (multiple-value-bind (passed rows) (run-suite :dh-settle (app-target))
      (is-true passed "~A" (row-reason rows "dh-settle/row-1")))
    ;; The control: the same app and case behind a plain process target, whose settle check
    ;; waits only for the network, so the swap delay is still running when the next step reads.
    (let ((inner (app-target)))
      (multiple-value-bind (passed rows)
          (run-suite :dh-settle (d:process-target :start (lambda () (d:target-start inner))
                                                  :stop (lambda () (d:target-stop inner))))
        (is-false passed "the case passed without the htmx check, so it does not test it")
        (is (equal "failed" (row-verdict rows "dh-settle/row-1")))
        (is (eql 3 (gethash "decided-at-step" (gethash "dh-settle/row-1" rows)))
            "the row failed somewhere other than the read after the click: ~A"
            (row-reason rows "dh-settle/row-1"))))))

(test sign-in-with-a-session-needs-no-sign-in-steps
  (when (browser-available-p)
    (multiple-value-bind (passed rows)
        (run-suite :dh-session
                   (app-target :sign-in :session :session-store (lambda () *sessions*)
                               :session-data (lambda (user db)
                                               (declare (ignore db))
                                               (list (cons :user-id (getf user :email))))))
      (is-true passed "~A" (row-reason rows "dh-signed-in/row-1"))
      (let ((steps (gethash "steps" (gethash "dh-signed-in/row-1" rows))))
        (is (search "a session for alice in the app's store" (gethash "label" (aref steps 0)))
            "the first step is ~S" (gethash "label" (aref steps 0)))))
    ;; The control: the same suite and target signing in through the form, which this suite has
    ;; no steps for, fails rather than running the case signed out.
    (multiple-value-bind (passed rows) (run-suite :dh-session (app-target))
      (is-false passed)
      (is (search "has no :SIGN-IN steps" (row-reason rows "dh-signed-in/row-1"))))))

(test sign-in-through-the-form-is-the-default
  (when (browser-available-p)
    (multiple-value-bind (passed rows) (run-suite :dh-form (app-target))
      (is-true passed "~A" (row-reason rows "dh-signed-in/row-1")))))

(test a-probe-reads-the-running-target-s-database
  (when (browser-available-p)
    (multiple-value-bind (passed rows) (run-suite :dh-stored (app-target))
      (is-true passed "~A" (row-reason rows "dh-stored/row-1")))))
