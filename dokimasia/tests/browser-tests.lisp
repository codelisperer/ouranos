;;;; browser-tests.lisp --- dokimasia runs in a real headless browser against the test app (#1028).
;;;;
;;;; Each test runs a whole suite through DOKIMASIA:RUN and reads its report. Without a browser
;;;; these tests are skipped, or fail when OURANOS_REQUIRE_BROWSER=1, which CI sets. The last test
;;;; names a browser that does not exist, so it starts no browser and runs everywhere.

(in-package #:dokimasia/tests)

(in-suite dokimasia)

(defvar *app* nil "The test app of the run in progress.")

(defparameter +alice+ '(:email "alice@example.com" :password "pw-alice" :plan "pro"))

(defun app-target (&key (favicon t))
  "A process target that starts and stops a fresh test app with Alice signed up. FAVICON NIL
starts it without a /favicon.ico, and :SLOW with one answered after 1.5 seconds."
  (d:process-target :start (lambda ()
                             (setf *app* (start-app :users (list +alice+) :favicon favicon))
                             (app-base-url *app*))
                    :stop (lambda () (stop-app *app*))
                    :users (list (list :name :alice :email "alice@example.com"
                                       :password (secret:make-secret "pw-alice")))))

(d:define-screen bt-home :path "/home" :present "#welcome")
(d:define-screen bt-login :path "/login" :present "#login")

(d:define-probe :bt-user-stored
  :local (lambda (email plan)
           (let ((user (app-user *app* email)))
             (cond ((null user) (values nil (format nil "no user ~A is stored" email)))
                   ((equal (getf user :plan) plan) t)
                   (t (values nil (format nil "~A is stored with the plan ~A, not ~A"
                                          email (getf user :plan) plan)))))))

(d:define-probe :bt-local-only
  :local (lambda (&rest values) (declare (ignore values)) t))

;;; --- the cases a passing run is made of ---------------------------------------------------

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

(d:define-case bt-signed-in
  :user :alice
  :steps ((:expect-text "#welcome" "alice@example.com")))

(d:define-case bt-signin-rows
  :rows (:file "rows/signin.csv")
  :steps ((:visit "/login")
          (:fill "#email" (:input :email))
          (:fill "#password" (:input :password))
          (:click "#submit")
          (:expect-screen (:input :screen))))

(d:define-case bt-scroll-kept
  :steps ((:visit "/pane")
          (:expect-scroll-kept (:click "#more") :pane "#list" :scroll 300)))

(d:define-case bt-known-console
  :steps ((:visit "/known-console")
          (:expect-text "#title" "Known")))

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

;;; --- the cases a failing run is made of ---------------------------------------------------

(d:define-case bt-f-console :steps ((:visit "/console-error") (:expect-text "#title" "Console")))
(d:define-case bt-f-loop :steps ((:visit "/loop")))
(d:define-case bt-f-server-error :steps ((:visit "/server-error")))
(d:define-case bt-f-screen
  :steps ((:visit "/home") (:expect-screen bt-home :timeout 1) (:click "#never-reached")))
(d:define-case bt-f-scroll
  :steps ((:visit "/pane") (:expect-scroll-kept (:click "#top") :pane "#list" :scroll 300)))
(d:define-case bt-f-missing
  :steps ((:visit "/signup") (:click "#no-such-button")))

(d:define-suite bt-failing
  :cases (bt-f-console bt-f-loop bt-f-server-error bt-f-screen bt-f-scroll bt-f-missing)
  :target (app-target)
  :max-requests-per-url 10)

;;; --- an app with no /favicon.ico ---------------------------------------------------------
;;; Each suite is its own run, so its own browser: a browser that has already had a 404 for
;;; /favicon.ico may not ask again.

(d:define-case bt-icon-none
  :steps ((:visit "/no-icon") (:expect-text "#title" "No icon")
          (:wait-for (:expression "true") :timeout 1)
          (:expect-text "#title" "No icon")))

(d:define-suite bt-icon-none :cases (bt-icon-none) :target (app-target :favicon nil))

(d:define-case bt-icon-own-favicon
  :steps ((:visit "/own-favicon") (:expect-text "#title" "Icon")
          (:wait-for (:expression "true") :timeout 1)
          (:expect-text "#title" "Icon")))

(d:define-suite bt-icon-own-favicon :cases (bt-icon-own-favicon)
  :target (app-target :favicon nil))

(d:define-case bt-icon-own-missing
  :steps ((:visit "/own-icon") (:expect-text "#title" "Icon")
          (:wait-for (:expression "true") :timeout 1)
          (:expect-text "#title" "Icon")))

(d:define-suite bt-icon-own-missing :cases (bt-icon-own-missing)
  :target (app-target :favicon nil))

;;; A page replaced while the browser's /favicon.ico request for it is unanswered: the browser
;;; sends no event that ends that request, so the settle check must not wait for it.

(d:define-case bt-replaced
  :steps ((:visit "/replaced") (:expect-text "#title" "No icon" :timeout 5)))

(d:define-suite bt-replaced :cases (bt-replaced) :target (app-target :favicon :slow))

;;; --- a target whose store the test image cannot see ---------------------------------------

(d:define-case bt-n-local-probe
  :steps ((:visit "/signup") (:expect-stored :bt-local-only "anything")))

(d:define-suite bt-not-run :cases (bt-n-local-probe))

;;; --- the :audit step -------------------------------------------------------------------------

(d:define-case bt-a-ok :steps ((:visit "/a11y-ok") (:audit :impact :minor)))
(d:define-case bt-a-moderate :steps ((:visit "/a11y-moderate") (:audit)))
(d:define-case bt-a-moderate-strict :steps ((:visit "/a11y-moderate") (:audit :impact :moderate)))
(d:define-case bt-a-image :steps ((:visit "/a11y-image") (:audit)))
(d:define-case bt-a-image-ignored :steps ((:visit "/a11y-image") (:audit :ignore ("image-alt"))))
(d:define-case bt-a-dark :steps ((:visit "/a11y-dark") (:audit)))
(d:define-case bt-a-unknown-rule :steps ((:visit "/a11y-ok") (:audit :ignore ("no-such-rule"))))

(d:define-suite bt-audit
  :cases (bt-a-ok bt-a-moderate bt-a-moderate-strict bt-a-image bt-a-image-ignored bt-a-dark
          bt-a-unknown-rule)
  :target (app-target))

;;; --- helpers --------------------------------------------------------------------------------

(defun browser-available-p ()
  "True when a browser can be run. Otherwise skips the test, or fails it when
OURANOS_REQUIRE_BROWSER=1."
  (cond ((cdp:find-browser) t)
        ((equal (uiop:getenv "OURANOS_REQUIRE_BROWSER") "1")
         (fail "no Chrome or Edge was found, and OURANOS_REQUIRE_BROWSER=1") nil)
        (t (skip "no Chrome or Edge was found; set OURANOS_BROWSER to run the browser tests") nil)))

(defun read-text (path)
  (uiop:read-file-string path :external-format :utf-8))

(defun report-rows (out)
  "The rows of the report.json in OUT, keyed by \"case/row\"."
  (let ((rows (make-hash-table :test 'equal)))
    (loop for r across (gethash "rows" (jzon:parse (read-text (merge-pathnames "report.json" out))))
          do (setf (gethash (format nil "~A/~A" (gethash "case" r) (gethash "row" r)) rows) r))
    rows))

(defun png-p (path)
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((head (make-array 4 :element-type '(unsigned-byte 8))))
      (and (= 4 (read-sequence head in)) (equalp head #(137 80 78 71))))))

;;; --- the tests ----------------------------------------------------------------------------

(test a-suite-runs-each-case-and-row-in-the-browser-and-writes-its-report
  (when (browser-available-p)
    (with-temporary-directory (out "dokimasia-pass")
      (multiple-value-bind (passed-p report)
          (d:run :bt-passing :out out :viewports '(:desktop :phone) :schemes '(:light :dark)
                             :explain nil)
        (let* ((text (read-text report))
               (lines (uiop:split-string text :separator (string #\Newline)))
               (rows (report-rows out)))
          (is-true passed-p "the run failed:~%~A" text)
          (is (search "7 rows: 7 passed, 0 failed, 0 not run." (second lines)) "~A" text)
          (is (equal "PASSED   bt-signup free-user [SIGNUP-1]" (fourth lines)))
          (is (= 7 (hash-table-count rows)))
          (is (equal "passed" (gethash "verdict" (gethash "bt-signin-rows/wrong-password" rows)))
              "the row's own expected screen, from the CSV file, was the sign-in page")
          (is (= 6 (length (gethash "steps" (gethash "bt-signed-in/row-1" rows))))
              "the suite's five sign-in steps ran before the case's one")
          (let ((console (gethash "console" (gethash "bt-known-console/row-1" rows))))
            (is (= 1 (length console)))
            (is (eq t (gethash "ignored" (aref console 0)))))
          (let ((files (gethash "artifacts" (gethash "bt-signup/pro-user" rows))))
            (is (= 4 (length files)) "one screenshot per viewport and scheme: ~S" files)
            (is (every (lambda (f) (and (probe-file f) (png-p f))) files))
            (is (some (lambda (f) (search "09-home-phone-dark.png" f)) files) "~S" files)))
        (is (null (app-user *app* "nobody@example.com")))
        (is (equal "pro" (getf (app-user *app* "pro@example.com") :plan)))))))

(defun reason-of (rows key)
  (or (gethash "reason" (gethash key rows) nil) ""))

(test each-check-made-after-a-step-fails-the-step-with-its-reason
  (when (browser-available-p)
    (with-temporary-directory (out "dokimasia-fail")
      (multiple-value-bind (passed-p report) (d:run :bt-failing :out out :explain nil)
        (let ((rows (report-rows out))
              (lines (uiop:split-string (read-text report) :separator (string #\Newline))))
          (is-false passed-p)
          (is (search "6 rows: 0 passed, 6 failed, 0 not run." (second lines)))
          (maphash (lambda (k r) (is (equal "failed" (gethash "verdict" r)) "~A" k)) rows)
          (is (search "console error: boom from the page" (reason-of rows "bt-f-console/row-1")))
          (is (search "/api/ping in one step; the limit is 10" (reason-of rows "bt-f-loop/row-1"))
              "~A" (reason-of rows "bt-f-loop/row-1"))
          (is (search "had the status 500" (reason-of rows "bt-f-server-error/row-1"))
              "~A" (reason-of rows "bt-f-server-error/row-1"))
          (let ((screen (gethash "bt-f-screen/row-1" rows)))
            (is (= 2 (gethash "decided-at-step" screen)))
            (is (search "is not the screen bt-home" (reason-of rows "bt-f-screen/row-1")))
            (is (= 2 (length (gethash "steps" screen))) "the steps after a failure are not run"))
          (is (search "moved from 300 to 0" (reason-of rows "bt-f-scroll/row-1"))
              "~A" (reason-of rows "bt-f-scroll/row-1"))
          (is (search "nothing matched #no-such-button" (reason-of rows "bt-f-missing/row-1"))
              "~A" (reason-of rows "bt-f-missing/row-1")))))))

(test a-local-probe-against-a-url-target-is-not-run-rather-than-passed
  (when (browser-available-p)
    (let ((app (start-app)))
      (unwind-protect
           (with-temporary-directory (out "dokimasia-not-run")
             (let ((*app* app))
               (multiple-value-bind (passed-p report)
                   (d:run :bt-not-run :target (d:url-target (app-base-url app)) :out out
                                      :explain nil)
                 (let ((text (read-text report)))
                   (is-true passed-p "no step failed")
                   (is (search "1 row: 0 passed, 0 failed, 1 not run." text) "~A" text)
                   (is (search "NOT RUN  bt-n-local-probe row-1: step 2" text) "~A" text)
                   (is (search "cannot see the store of a url-target" text) "~A" text)))))
        (stop-app app)))))

(test the-audit-step-fails-on-violations-at-or-above-its-impact-in-each-colour-scheme
  (when (browser-available-p)
    (with-temporary-directory (out "dokimasia-audit")
      (multiple-value-bind (passed-p report)
          (d:run :bt-audit :out out :viewports '(:desktop) :schemes '(:light :dark) :explain nil)
        (let ((rows (report-rows out))
              (text (read-text report)))
          (flet ((verdict (key) (gethash "verdict" (gethash key rows)))
                 (reason (key) (reason-of rows key)))
            (is-false passed-p)
            (is (search "7 rows: 3 passed, 4 failed, 0 not run." text) "~A" text)
            (is (equal "passed" (verdict "bt-a-ok/row-1"))
                "a page with no violation passes even at :minor: ~A" (reason "bt-a-ok/row-1"))
            (is (equal "passed" (verdict "bt-a-moderate/row-1"))
                "moderate violations pass at the default, :serious: ~A" (reason "bt-a-moderate/row-1"))
            (is (equal "failed" (verdict "bt-a-moderate-strict/row-1")))
            (is (search "region (moderate" (reason "bt-a-moderate-strict/row-1"))
                "~A" (reason "bt-a-moderate-strict/row-1"))
            (is (equal "failed" (verdict "bt-a-image/row-1")))
            (is (search "image-alt (critical, 1 element, first at img)" (reason "bt-a-image/row-1"))
                "~A" (reason "bt-a-image/row-1"))
            (is (search "axe-core 4.14.0 found 2 violations" (reason "bt-a-image/row-1"))
                "one for each colour scheme: ~A" (reason "bt-a-image/row-1"))
            (is (equal "passed" (verdict "bt-a-image-ignored/row-1"))
                "a rule in :ignore is not run: ~A" (reason "bt-a-image-ignored/row-1"))
            (let ((dark (reason "bt-a-dark/row-1")))
              (is (equal "failed" (verdict "bt-a-dark/row-1")))
              (is (search "dark: color-contrast (serious" dark) "~A" dark)
              (is (not (search "light:" dark)) "the light scheme has enough contrast: ~A" dark))
            (is (equal "failed" (verdict "bt-a-unknown-rule/row-1"))
                "a rule id axe-core does not know is not ignored silently: ~A"
                (reason "bt-a-unknown-rule/row-1"))
            (is (search "no-such-rule" (reason "bt-a-unknown-rule/row-1"))
                "~A" (reason "bt-a-unknown-rule/row-1"))))))))

(test a-browser-that-cannot-start-fails-every-row-with-the-reason
  (let ((app (start-app)))
    (unwind-protect
         (with-temporary-directory (out "dokimasia-no-start")
           (with-env ("OURANOS_BROWSER" "/nonexistent/dokimasia-test-browser")
             (multiple-value-bind (passed-p report)
                 (d:run :bt-not-run :target (d:url-target (app-base-url app)) :out out
                                    :explain nil)
               (let ((text (read-text report)))
                 (is-false passed-p)
                 (is (search "FAILED   bt-n-local-probe row-1: step 1 starting the target and the browser"
                             text)
                     "~A" text)
                 (is (search "dokimasia-test-browser" text) "~A" text)))))
      (stop-app app))))

(defun run-one (suite)
  "Run SUITE into a temporary directory. Returns whether it passed and its one row's report."
  (with-temporary-directory (out "dokimasia-icon")
    (let ((passed-p (d:run suite :out out :explain nil)))
      (values passed-p
              (let ((rows (report-rows out)))
                (gethash (format nil "~(~A~)/row-1" suite) rows))))))

(defun favicon-entries (row)
  "ROW's console entries about a request for /favicon.ico."
  (remove-if-not (lambda (c) (search "favicon.ico" (or (gethash "why" c) (gethash "message" c) "")))
                 (coerce (gethash "console" row) 'list)))

(test a-request-of-a-replaced-page-does-not-hold-the-settle-check
  ;; The CI failure of train 64: a form's response navigated twice, and the settle check waited
  ;; ten seconds for the first page's /favicon.ico request, which the browser never ends.
  (when (browser-available-p)
    (multiple-value-bind (passed-p row) (run-one :bt-replaced)
      (is-true passed-p "~A" (gethash "reason" row)))))

(test the-browser-s-own-favicon-request-fails-no-step-when-the-page-links-no-icon
  (when (browser-available-p)
    (multiple-value-bind (passed-p row) (run-one :bt-icon-none)
      (is-true passed-p "~A" (gethash "reason" row))
      (let ((entries (favicon-entries row)))
        (is (= 1 (length entries))
            "the report does not show the 404 for /favicon.ico, so the run did not see it: ~S"
            (gethash "console" row))
        (when entries
          (is (eq t (gethash "ignored" (first entries))))
          (is (search "404" (gethash "message" (first entries)))))))
    ;; The controls: the same 404 for /favicon.ico fails the page that links it, and a page that
    ;; links a different missing icon fails as before.
    (multiple-value-bind (passed-p row) (run-one :bt-icon-own-favicon)
      (is-false passed-p "a page that links a missing /favicon.ico itself passed")
      (is (search "log error (network)" (or (gethash "reason" row) "")) "~A" (gethash "reason" row)))
    (multiple-value-bind (passed-p row) (run-one :bt-icon-own-missing)
      (is-false passed-p "a page that links a missing icon passed")
      (is (search "log error (network)" (or (gethash "reason" row) "")) "~A" (gethash "reason" row)))))
