;;;; tests.lisp --- the worked example's tests (#1028, step 4): the active-search acceptance suite
;;;; run against hyperion/examples/active-search in a real headless browser, at desktop width and
;;;; at phone width, plus a control that has to fail.
;;;;
;;;; When OURANOS_DOKIMASIA_EXAMPLE_OUT names a directory, the desktop run writes its report and
;;;; screenshots there and leaves them, so CI can upload them as a workflow artifact. Otherwise each
;;;; run writes to a temporary directory that is deleted afterwards.

(defpackage #:dokimasia/examples/active-search/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:d #:dokimasia)
                    (#:ex #:dokimasia/examples/active-search)
                    (#:cdp #:aion/cdp)
                    (#:jzon #:com.inuoe.jzon))
  (:export #:run-tests))

(in-package #:dokimasia/examples/active-search/tests)

(def-suite dokimasia/examples/active-search
  :description "The worked example: dokimasia's acceptance suite for hyperion's active-search app.")
(in-suite dokimasia/examples/active-search)

(defun run-tests ()
  (run! 'dokimasia/examples/active-search))

;;; --- helpers --------------------------------------------------------------------------------

(defun browser-available-p ()
  "True when a browser can be run. Otherwise skips the test, or fails it when
OURANOS_REQUIRE_BROWSER=1."
  (cond ((cdp:find-browser) t)
        ((equal (uiop:getenv "OURANOS_REQUIRE_BROWSER") "1")
         (fail "no Chrome or Edge was found, and OURANOS_REQUIRE_BROWSER=1") nil)
        (t (skip "no Chrome or Edge was found; set OURANOS_BROWSER to run the browser tests") nil)))

(defun call-with-out (function &key keep-in)
  "Call FUNCTION with an output directory: KEEP-IN, a directory that is left in place, when it is
given, or else a new temporary directory that is deleted afterwards."
  (if keep-in
      (let ((dir (uiop:ensure-directory-pathname keep-in)))
        (ensure-directories-exist dir)
        (funcall function dir))
      (let ((dir (aion/fs:make-temporary-directory "dokimasia-example-out")))
        (unwind-protect (funcall function dir)
          (aion/fs:delete-tree dir)))))

(defun report-rows (out)
  "The rows of OUT/report.json, keyed by \"case/row\"."
  (let ((rows (make-hash-table :test 'equal)))
    (loop for r across (gethash "rows" (jzon:parse (uiop:read-file-string
                                                    (merge-pathnames "report.json" out))))
          do (setf (gethash (format nil "~A/~A" (gethash "case" r) (gethash "row" r)) rows) r))
    rows))

(defun verdict (rows key)
  (let ((r (gethash key rows)))
    (if r (gethash "verdict" r) (format nil "no row ~A" key))))

(defun png-p (path)
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((head (make-array 4 :element-type '(unsigned-byte 8))))
      (and (= 4 (read-sequence head in)) (equalp head #(137 80 78 71))))))

(defparameter +search-rows+ '("by-name" "by-email" "by-role" "no-match")
  "The ids of rows/search.csv, in the file's order.")

;;; --- the tests ----------------------------------------------------------------------------

(test the-example-suite-passes-at-desktop-width-with-a-screenshot-in-each-viewport
  (when (browser-available-p)
    (call-with-out
     (lambda (out)
       (multiple-value-bind (passed report)
           (ex:run-acceptance :out out :viewports '(:desktop :phone) :schemes '(:light)
                              :explain nil)
         (let ((rows (report-rows out))
               (text (uiop:read-file-string report)))
           (is-true passed "the run failed:~%~A" text)
           (is (= 5 (hash-table-count rows)) "four search rows and the page case: ~A" text)
           (dolist (id +search-rows+)
             (is (equal "passed" (verdict rows (format nil "search-contacts/~A" id)))
                 "the row ~A: ~A" id text))
           (is (equal "passed" (verdict rows "contacts-page/row-1")) "~A" text)
           ;; The fixed layout: <case>/<row>/NN-name-viewport-scheme.png, NN being the step.
           (let ((files (gethash "artifacts" (gethash "contacts-page/row-1" rows))))
             (is (= 2 (length files)) "one screenshot per viewport: ~S" files)
             (is (every (lambda (f) (and (probe-file f) (png-p f))) files) "~S" files)
             (dolist (name '("03-contacts-desktop-light.png" "03-contacts-phone-light.png"))
               (is (probe-file (merge-pathnames (concatenate 'string "contacts-page/row-1/" name)
                                                out))
                   "~A is not in the report directory ~A" name out))))))
     :keep-in (let ((dir (uiop:getenv "OURANOS_DOKIMASIA_EXAMPLE_OUT")))
                (and dir (plusp (length dir)) dir)))))

(test the-example-suite-passes-at-phone-width
  (when (browser-available-p)
    (call-with-out
     (lambda (out)
       (multiple-value-bind (passed report)
           (ex:run-acceptance :out out :viewports '(:phone) :schemes '(:light) :explain nil)
         (let ((rows (report-rows out)))
           (is-true passed "the run failed:~%~A" (uiop:read-file-string report))
           (is (= 5 (hash-table-count rows)))))))))

(defun run-dark-audit (out)
  "Run the page case's audit in the dark scheme alone. Returns true when it passed."
  (d:run :active-search-dark :out out :viewports '(:desktop) :schemes '(:dark) :explain nil))

;; Pending #1281. In the dark scheme the audit finds the grey subtitle and the mailto links below
;; WCAG AA contrast, in Bulma's colours, which hyperion/appearance does not yet set. The fix for
;; #1281 replaces the skip with:
;;   (when (browser-available-p) (call-with-out (lambda (out) (is-true (run-dark-audit out)))))
(test the-page-passes-the-audit-in-the-dark-scheme
  (skip "pending #1281: the grey subtitle and the mailto links fail the contrast audit in the dark scheme"))

;; The control: the same steps with a row that expects a name the search never puts first. If this
;; passed, the example's rows would pass whatever the app showed.
(d:define-case example-control
  :rows ((:id "wrong-first" :query "turing" :first "Grace Hopper" :echo "Filtering: turing"))
  :steps ((:visit "/")
          (:fill "#q" (:input :query))
          (:expect-text "#results tr:first-child td:first-child" (:input :first) :timeout 2)))

(d:define-suite example-control :cases (example-control))

(test a-row-that-expects-the-wrong-result-fails-at-its-check
  (when (browser-available-p)
    (call-with-out
     (lambda (out)
       (let ((passed (d:run :example-control :target (ex:app-target) :out out :explain nil))
             (rows (report-rows out)))
         (is-false passed "a row expecting Grace Hopper first passed")
         (is (equal "failed" (verdict rows "example-control/wrong-first")))
         (is (eql 3 (gethash "decided-at-step" (gethash "example-control/wrong-first" rows)))
             "the row failed somewhere other than its check of the first result"))))))
