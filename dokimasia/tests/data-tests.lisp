;;;; data-tests.lisp --- dokimasia without a browser (#1028): the verdict rule in dokimasia/core,
;;;; screens, cases, suites, probes and rows as data, and the report.

(in-package #:dokimasia/tests)

(in-suite dokimasia)

;;; --- the verdict -------------------------------------------------------------------------

(defun results (&rest steps)
  "Row results from STEPS, each (label kind reason ms)."
  (core:make-row-results (mapcar #'first steps) (mapcar #'second steps)
                         (mapcar #'third steps) (mapcar #'fourth steps)))

(test a-row-whose-steps-all-passed-passed
  (let* ((r (results '("a" "passed" "" 3) '("b" "passed" "" 4)))
         (v (core:row-verdict r)))
    (is (equal "passed" (core:verdict-kind v)))
    (is (equal "" (core:verdict-reason v)))
    (is (= 2 (core:steps-passed r)))
    (is (= 7 (core:total-duration-ms r)))))

(test the-first-failed-step-decides-a-failed-row
  (let ((v (core:row-verdict (results '("a" "passed" "" 1) '("b" "not-run" "no form" 1)
                                      '("c" "failed" "first" 1) '("d" "failed" "second" 1)))))
    (is (equal "failed" (core:verdict-kind v)) "a failure outranks a step that was not run")
    (is (= 2 (core:verdict-step-index v)))
    (is (equal "c" (core:verdict-step-label v)))
    (is (equal "first" (core:verdict-reason v)))))

(test a-row-with-a-step-not-run-is-not-passed
  (let* ((r (results '("a" "passed" "" 1) '("b" "not-run" "the probe has no HTTP form" 1)))
         (v (core:row-verdict r)))
    (is (equal "not-run" (core:verdict-kind v)))
    (is (= 1 (core:verdict-step-index v)))
    (is (equal "the probe has no HTTP form" (core:verdict-reason v)))
    (is (= 1 (core:steps-not-run r)))
    (is (= 0 (core:steps-failed r)))))

(test a-row-with-no-steps-was-not-run
  (is (equal "not-run" (core:verdict-kind (core:row-verdict (results))))))

(test an-unknown-outcome-kind-fails-rather-than-passes
  (let ((v (core:row-verdict (results '("a" "pased" "" 1)))))
    (is (equal "failed" (core:verdict-kind v)))
    (is (search "pased" (core:verdict-reason v)))))

;;; --- steps, screens, cases, suites, probes -------------------------------------------------

(defmacro refused ((&optional (fragment "")) &body body)
  `(let ((c (handler-case (progn ,@body nil) (d:invalid-definition (c) c))))
     (is (typep c 'd:invalid-definition) "~S was accepted" ',body)
     (when c (is (search ,fragment (d:invalid-definition-reason c))
                 "the reason ~S does not mention ~S" (d:invalid-definition-reason c) ,fragment))))

(test every-kind-of-step-is-accepted-with-its-arguments
  (finishes
    (d::%define-case :t-every-step
                     :steps '((:visit "/a") (:visit (:input :path))
                              (:fill "#e" (:input :email)) (:fill "#p" (:user :password))
                              (:click "button") (:select "#s" "two")
                              (:wait-for "#x" :timeout 2) (:wait-for (:expression "true"))
                              (:expect-screen :home :timeout 3) (:expect-screen (:input :screen))
                              (:expect-text "h1" "Hello") (:expect-stored :probe (:input :email) "x")
                              (:expect-scroll-kept (:click "#more") :pane "#list" :scroll 10)
                              (:screenshot "home-page")))))

(test a-malformed-step-is-refused-when-the-case-is-defined
  (refused ("not a step") (d::%define-case :t-bad :steps '((:hover "#x"))))
  (refused ("CSS selector") (d::%define-case :t-bad :steps '((:click ""))))
  (refused ("a value goes") (d::%define-case :t-bad :steps '((:fill "#x" (:env "HOME")))))
  (refused ("needs a selector and a value") (d::%define-case :t-bad :steps '((:fill "#x"))))
  (refused ("accepts") (d::%define-case :t-bad :steps '((:click "#x" :timeout 3))))
  (refused ("positive number") (d::%define-case :t-bad :steps '((:wait-for "#x" :timeout 0))))
  (refused ("action step") (d::%define-case :t-bad :steps '((:expect-scroll-kept (:expect-text "a" "b")))))
  (refused ("for its file") (d::%define-case :t-bad :steps '((:screenshot "../escape"))))
  (refused ("no steps") (d::%define-case :t-bad :steps '()))
  (refused (":ROWS") (d::%define-case :t-bad :steps '((:visit "/")) :rows '((:a))))
  (is (null (d:find-case :t-bad)) "a refused case is not stored"))

(test a-screen-must-say-something-about-the-page
  (refused ("every page") (d::%define-screen :t-empty))
  (refused ("both") (d::%define-screen :t-both :path "/a" :path-prefix "/a"))
  (refused ("strings") (d::%define-screen :t-list :present '("#a" 3)))
  (d:define-screen :t-screen :path "/a" :present "#a")
  (is (equal '("#a") (d::screen-present (d:find-screen "T-SCREEN")))
      "a single selector becomes a list, and the name is found without regard to case"))

(test a-suite-is-checked-when-it-is-defined-and-when-it-runs
  (refused ("MAX-REQUESTS-PER-URL") (d::%define-suite :t-s :cases :all :max-requests-per-url 0))
  (refused ("IGNORE-CONSOLE") (d::%define-suite :t-s :cases :all :ignore-console '(1)
                                                    :max-requests-per-url 5))
  (refused ("not a step") (d::%define-suite :t-s :cases :all :sign-in '((:login))
                                                :max-requests-per-url 5))
  (d::%define-suite :t-s :cases '(:t-no-such-case) :max-requests-per-url 5)
  (refused ("not defined") (d::suite-dcases (d:find-suite :t-s)))
  (refused ("no :TARGET") (d:run :t-s :explain nil))
  (refused ("no suite") (d:run :t-no-such-suite)))

(test a-probe-needs-a-form-and-a-target-needs-a-web-address
  (refused ("neither") (d:define-probe :t-p))
  (refused ("functions") (d:define-probe :t-p :local 3))
  (refused ("http://") (d:url-target "ftp://example.com"))
  (refused (":NAME") (d:url-target "http://localhost" :users '((:email "a"))))
  (refused (":START") (d:process-target :start "go"))
  (is (equal "https://example.com" (d:target-base-url (d:url-target "https://example.com/")))
      "a trailing slash is dropped"))

;;; --- rows ----------------------------------------------------------------------------------

(defun write-file (path text)
  (with-open-file (s path :direction :output :if-exists :supersede :external-format :utf-8)
    (write-string text s))
  path)

(test rows-are-read-inline-from-csv-and-from-s-expressions
  (with-temporary-directory (dir "dokimasia-rows")
    (write-file (merge-pathnames "r.csv" dir)
                (format nil "id,Email,expected~%first,a@example.com,yes~%~%,b@example.com,no~%"))
    (write-file (merge-pathnames "r.sexp" dir)
                "; rows for a test
((:email \"c@example.com\" :count 3) (:email \"d@example.com\" :count 4))")
    (d::%define-case :t-csv :steps '((:visit "/")) :rows '(:file "r.csv")
                            :base-directory (namestring dir))
    (d::%define-case :t-sexp :steps '((:visit "/")) :rows '(:file "r.sexp")
                             :base-directory (namestring dir))
    (d::%define-case :t-inline :steps '((:visit "/")) :rows '((:email "e@example.com")))
    (d::%define-case :t-none :steps '((:visit "/")))
    (let ((rows (d::case-rows (d:find-case :t-csv))))
      (is (= 2 (length rows)) "a blank line is not a row")
      (is (equal "a@example.com" (cdr (assoc "email" (first rows) :test #'string=)))
          "column names are compared in lower case")
      (is (equal "first" (d::row-id (first rows) 0)))
      (is (equal "row-2" (d::row-id (second rows) 1)) "an empty id falls back to the position"))
    (let ((rows (d::case-rows (d:find-case :t-sexp))))
      (is (equal '(("email" . "c@example.com") ("count" . 3)) (first rows))))
    (is (equal '((("email" . "e@example.com"))) (d::case-rows (d:find-case :t-inline))))
    (is (equal '(()) (d::case-rows (d:find-case :t-none))) "a case without rows runs once")))

(test a-row-file-that-cannot-be-used-is-refused-with-its-reason
  (with-temporary-directory (dir "dokimasia-rows")
    (write-file (merge-pathnames "short.csv" dir) (format nil "a,b~%1~%"))
    (write-file (merge-pathnames "code.sexp" dir) "((:a #.(delete-file \"x\")))")
    (write-file (merge-pathnames "flat.sexp" dir) "(:a 1)")
    (flet ((rows-of (file)
             (d::%define-case :t-file :steps '((:visit "/")) :rows (list :file file)
                                      :base-directory (namestring dir))
             (d::case-rows (d:find-case :t-file))))
      (refused ("has 1 field;") (rows-of "short.csv"))
      (refused ("not plain data") (rows-of "code.sexp"))
      (refused ("list of plists") (rows-of "flat.sexp"))
      (refused ("does not exist") (rows-of "missing.csv")))))

;;; --- helpers --------------------------------------------------------------------------------

(test a-step-label-shows-names-without-their-package
  (is (equal "(:expect-screen :bt-home :timeout 2)"
             (d::step-label '(:expect-screen dokimasia/tests::bt-home :timeout 2)))))

(test origins-and-javascript-literals
  (is (equal "http://127.0.0.1:8080" (d::%origin "http://127.0.0.1:8080/a/b?c")))
  (is (equal "https://example.com" (d::%origin "HTTPS://Example.com")))
  (is (null (d::%origin "about:blank")))
  (is (equal "null" (d::%js nil)))
  (is (equal "\"a\\\"b\"" (d::%js "a\"b")))
  (is (equal "[\"#a\",\"#b\"]" (d::%js '("#a" "#b")))))

;;; --- the report ---------------------------------------------------------------------------

(defun sample-reports ()
  (d::%define-case :t-report :requirement "REQ-1" :steps '((:visit "/")))
  (let ((c (d:find-case :t-report)))
    (list (d::%row-report c "good" nil (list (d::%step-record "(:visit \"/\")" "passed" "" 5)))
          (d::%row-report c "bad" nil (list (d::%step-record "(:visit \"/\")" "passed" "" 5)
                                            (d::%step-record "(:click \"#go\")" "failed"
                                                             "nothing matched #go" 7)))
          (d::%row-report c "partial" nil (list (d::%step-record "(:expect-stored :p)" "not-run"
                                                                 "no HTTP form" 1))))))

(test report-txt-starts-with-each-row-failures-first
  (let* ((text (with-output-to-string (s)
                 (d::write-report-text (sample-reports)
                                       (list :suite "s" :base-url "http://x" :viewports '(:desktop)
                                             :schemes '(:light))
                                       s)))
         (lines (uiop:split-string text :separator (string #\Newline))))
    (is (search "3 rows: 1 passed, 1 failed, 1 not run." (second lines)))
    (is (equal "FAILED   t-report bad [REQ-1]: step 2 (:click \"#go\"): nothing matched #go"
               (fourth lines)))
    (is (equal "NOT RUN  t-report partial [REQ-1]: step 1 (:expect-stored :p): no HTTP form"
               (fifth lines)))
    (is (equal "PASSED   t-report good [REQ-1]" (sixth lines)))))

(test report-json-carries-each-row
  (let* ((json (jzon:parse (d::report-json (sample-reports)
                                           (list :suite "s" :viewports '(:desktop :phone)
                                                 :schemes '(:light)))))
         (rows (gethash "rows" json)))
    (is (= 1 (gethash "failed" json)))
    (is (equalp #("desktop" "phone") (gethash "viewports" json)))
    (is (= 3 (length rows)))
    (let ((bad (aref rows 1)))
      (is (equal "failed" (gethash "verdict" bad)))
      (is (= 2 (gethash "decided-at-step" bad)))
      (is (equal "REQ-1" (gethash "requirement" bad)))
      (is (= 2 (length (gethash "steps" bad))))
      (is (= 12 (gethash "duration-ms" bad))))))
