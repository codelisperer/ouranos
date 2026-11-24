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

(defun report-text (out)
  "The report.txt that a run wrote in OUT, or a sentence saying there is none."
  (let ((path (merge-pathnames "report.txt" out)))
    (if (probe-file path)
        (read-text path)
        (format nil "(there is no report.txt in ~A)" (namestring out)))))

(test a-suite-whose-rows-all-pass-exits-0-and-writes-its-report-to-out
  "This failed once on macOS and passed on a rerun of the same commit (#1353). The command's
output says only that the row failed; the row's reason is in report.txt. So when a check here
fails, its message carries the whole report, and the run's directory is kept, with the report and
any screenshots, instead of being deleted. It is deleted when every check passes."
  (when (browser-available-p)
    (let ((out (temporary-directory "dokimasia-command"))
          (passed nil))
      (unwind-protect
           (multiple-value-bind (code text err)
               (exit-code-of :system "dokimasia/tests" :suite "bt-icon-none"
                             :viewports "phone,desktop" :schemes "dark" :out (namestring out))
             (let ((report (report-text out)))
               (setf passed (and (eql 0 code)
                                 (search "1 passed, 0 failed, 0 not run" text)
                                 (search "Viewports: phone, desktop. Schemes: dark." report)
                                 t))
               (is (eql 0 code) "~A~A~%The report, kept in ~A:~%~A" text err (namestring out) report)
               (is (search "1 passed, 0 failed, 0 not run" text)
                   "~A~%The report, kept in ~A:~%~A" text (namestring out) report)
               (is (search "Viewports: phone, desktop. Schemes: dark." report)
                   "The report, kept in ~A:~%~A" (namestring out) report)))
        (when passed
          (uiop:delete-directory-tree out :validate t :if-does-not-exist :ignore))))))

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
