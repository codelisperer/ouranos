;;;; command-tests.lisp --- running a suite from the command line, as the `acceptance' target of
;;;; dokimasia/cons.lisp does (#1028).
;;;;
;;;; The tests of the arguments run everywhere. The last test names a browser that does not
;;;; exist, so it starts no browser and runs everywhere too. The two between them need a browser,
;;;; like the tests in browser-tests.lisp.

(in-package #:dokimasia/tests)

(in-suite dokimasia)

(d:define-suite bt-cmd-failing :cases (bt-f-screen) :target (app-target))

(defun exit-code-of (&rest arguments)
  "COMMAND-LINE-EXIT-CODE of ARGUMENTS, and what it printed to standard output and to standard
error, as three values."
  (let* ((err (make-string-output-stream))
         (code nil)
         (out (with-output-to-string (*standard-output*)
                (let ((*error-output* err))
                  (setf code (apply #'d:command-line-exit-code arguments))))))
    (values code out (get-output-stream-string err))))

(test viewports-and-schemes-are-read-from-comma-separated-names
  (is (equal '(:desktop :phone) (d:parse-viewports "desktop, phone")))
  (is (equal '(:phone) (d:parse-viewports "PHONE,")))
  (is (equal '(:light :dark) (d:parse-schemes "light,dark")))
  (signals d:command-line-error (d:parse-viewports ""))
  (signals d:command-line-error (d:parse-viewports " , "))
  (signals d:command-line-error (d:parse-schemes "dim"))
  (handler-case (progn (d:parse-viewports "desktop,tablet") (fail "tablet was accepted"))
    (d:command-line-error (c)
      (is (equal "VIEWPORTS: \"tablet\" is not one of desktop, phone"
                 (d:command-line-error-reason c))))))

(test a-wrong-argument-exits-2-and-says-what-is-wrong
  "Each case runs no browser: the arguments are checked first."
  (dolist (case '(((:suite "bt-icon-none") "SYSTEM is empty")
                  ((:system "dokimasia/tests") "SUITE is empty")
                  ((:system "dokimasia/tests" :suite "bt-icon-none" :viewports "tablet")
                   "VIEWPORTS: \"tablet\" is not one of desktop, phone")
                  ((:system "dokimasia/tests" :suite "bt-icon-none" :schemes "")
                   "SCHEMES is empty")
                  ((:system "dokimasia/tests" :suite "no-such-suite")
                   "the system dokimasia/tests defines no suite named no-such-suite")
                  ((:system "dokimasia/no-such-system" :suite "bt-icon-none")
                   "the system dokimasia/no-such-system could not be loaded")))
    (destructuring-bind (arguments expected) case
      (multiple-value-bind (code out err) (apply #'exit-code-of arguments)
        (is (eql 2 code) "~S: ~A~A" arguments out err)
        (is (search expected err) "~S: expected ~S in ~S" arguments expected err)
        (is (string= "" out) "~S printed ~S" arguments out)))))

(test a-suite-whose-rows-all-pass-exits-0-and-writes-its-report-to-out
  (when (browser-available-p)
    (with-temporary-directory (out "dokimasia-command")
      (multiple-value-bind (code text err)
          (exit-code-of :system "dokimasia/tests" :suite "bt-icon-none"
                        :viewports "phone,desktop" :schemes "dark" :out (namestring out))
        (is (eql 0 code) "~A~A" text err)
        (is (search "1 passed, 0 failed, 0 not run" text) "~A" text)
        (let ((report (read-text (merge-pathnames "report.txt" out))))
          (is (search "Viewports: phone, desktop. Schemes: dark." report) "~A" report))))))

(test a-suite-with-a-failing-row-exits-1
  "Control for the test above: the same command with a suite whose one row fails."
  (when (browser-available-p)
    (with-temporary-directory (out "dokimasia-command")
      (multiple-value-bind (code text err)
          (exit-code-of :system "dokimasia/tests" :suite "bt-cmd-failing" :out (namestring out))
        (is (eql 1 code) "~A~A" text err)
        (is (search "0 passed, 1 failed, 0 not run" text) "~A" text)))))

(test a-run-whose-browser-cannot-start-exits-1
  "The rows of a run whose browser could not start are not passes, so the command does not exit
0. This test names a browser that does not exist, so it runs on a machine without one."
  (with-temporary-directory (out "dokimasia-command")
    (with-env ("OURANOS_BROWSER" "/nonexistent/dokimasia-test-browser")
      (multiple-value-bind (code text err)
          (exit-code-of :system "dokimasia/tests" :suite "bt-icon-none" :out (namestring out))
        (is (eql 1 code) "~A~A" text err)
        (is (search "0 passed, 1 failed, 0 not run" text) "~A" text)))))
