;;;; caught-errors-tests.lisp --- a test body that cannot compile must be found (#263)
;;;;
;;;; scripts/caught-errors.lisp finds each `caught ERROR' in a child image's output, and
;;;; verify-tree.lisp fails the run on one. The reason the scan has to exist is a mechanism,
;;;; not a string: FiveAM compiles a test body when its fasl LOADS, so compile-file reports
;;;; no failure for a body that cannot compile. So the control here runs that mechanism for
;;;; real rather than feeding the scanner text: a fixture file with a FiveAM test is compiled
;;;; and loaded in a child SBCL, once with a DECLARE in a place where the macro around it
;;;; cannot accept one (the shape of the defect in aion/windows/com/tests) and once without.
;;;; The first must be found, and the second must not.
;;;;
;;;; IN A CHILD IMAGE ON PURPOSE. fiveam-report-tests.lisp records what happened when a test
;;;; file defined a demonstration suite in the suite's own image: on a cold build it
;;;; registered twice, and the tree's check count changed with the fasl cache. The fixture's
;;;; test is defined only in the child, and the child never runs it; this image only reads
;;;; the text the child printed.
;;;;
;;;; Tested from cons, and the helper loaded by path, for the same reasons as
;;;; fiveam-report-tests.lisp.

(in-package #:cons/tests)

(def-suite caught-errors
  :description "A FiveAM test body that cannot compile is found in the output (#263)." :in all)
(in-suite caught-errors)

(defun %load-caught-errors ()
  "Load scripts/caught-errors.lisp -- the file scripts/verify-tree.lisp loads by path."
  (let ((path (merge-pathnames "scripts/caught-errors.lisp"
                               (asdf:system-source-directory :cons))))
    (unless (probe-file path)
      ;; cons/ is a framework directory inside the monorepo; the script lives at the ROOT.
      (setf path (merge-pathnames "../scripts/caught-errors.lisp"
                                  (asdf:system-source-directory :cons))))
    (is-true (probe-file path)
             "scripts/caught-errors.lisp must exist -- verify-tree.lisp loads it by path, so a rename breaks the gate, not just this test. Looked at ~A" path)
    (when (probe-file path) (load path))
    path))

(defun %errors-in (output)
  "OURANOS-CAUGHT-ERRORS:ERRORS-IN, resolved at run time: the package does not exist until
the file is loaded, and a literal symbol would take this whole test system down with it."
  (funcall (read-from-string "ouranos-caught-errors:errors-in") output))

(defparameter +fixture-template+
  "(defpackage #:caught-errors-fixture (:use #:cl #:fiveam))
(in-package #:caught-errors-fixture)

;; The body goes inside a PROGN, where a declaration is not allowed, as in
;; aion/windows/com/tests' WITH-CSV-CONNECTION.
(defmacro with-one ((var) &body body)
  `(let ((,var 1)) (progn ,var ,@body)))

(test fixture-test
  (with-one (x)
    ~A
    (is (= 1 1))))
"
  "A FiveAM test file. ~A is replaced by the DECLARE form, or by nothing.")

(defun %fixture-output (with-error-p)
  "Compile and load the fixture in a child SBCL and return what the child printed, which
includes a line naming compile-file's failure flag and a line saying the load finished."
  (let ((setup (let ((ql (find-package "QL")))
                 (and ql (merge-pathnames "setup.lisp"
                                          (symbol-value (find-symbol "*QUICKLISP-HOME*" ql)))))))
    (tempdir:with-temporary-directory (dir "caught-errors")
      (let ((source (merge-pathnames "fixture.lisp" dir))
            (fasl (merge-pathnames "fixture.fasl" dir)))
        (with-open-file (out source :direction :output)
          (format out +fixture-template+ (if with-error-p "(declare (ignore x))" "")))
        (uiop:run-program
         (list (namestring sb-ext:*runtime-pathname*)
               "--noinform" "--no-userinit" "--no-sysinit" "--non-interactive"
               "--eval" "(require :asdf)"
               "--eval" (if setup (format nil "(load ~S)" (namestring setup)) "(progn)")
               "--eval" "(let ((*standard-output* (make-broadcast-stream))) (asdf:load-system :fiveam))"
               "--eval" (format nil "(multiple-value-bind (f w failure) (compile-file ~S :output-file ~S) (declare (ignore w)) (format t \"~~&COMPILE-FILE-FAILURE-P ~~S~~%\" failure) (load f) (format t \"~~&FIXTURE-LOADED~~%\"))"
                                (namestring source) (namestring fasl)))
         :output :string :error-output :output :ignore-error-status t)))))

(test a-test-body-that-cannot-compile-is-found
  "The defect's own shape. compile-file reports no failure, which is why ASDF never stops,
and the error is still found in what the child printed."
  (%load-caught-errors)
  (let* ((output (%fixture-output t))
         (errors (%errors-in output)))
    (is (search "FIXTURE-LOADED" output) "the child did not get as far as loading the fixture:~%~A" output)
    (is (search "COMPILE-FILE-FAILURE-P NIL" output)
        "compile-file reported a failure, so this fixture no longer shows why the scan is needed:~%~A" output)
    (is (= 1 (length errors)) "expected one caught ERROR, found ~D in:~%~A" (length errors) output)
    (let ((text (format nil "~{~A~%~}" (first errors))))
      (is (search "DECLARE" text) "the reported context does not name the DECLARE:~%~A" text)
      (is (search "FIXTURE-TEST" text) "the reported context does not name the test:~%~A" text))))

(test the-same-test-body-without-the-error-is-clean
  "The other direction, on the same fixture with the one line removed. Asserted that the child
got as far as loading it, because an empty result from a child that never ran would pass."
  (%load-caught-errors)
  (let ((output (%fixture-output nil)))
    (is (search "FIXTURE-LOADED" output) "the child did not get as far as loading the fixture:~%~A" output)
    (is (null (%errors-in output)) "a caught ERROR was reported in:~%~A" output)))

(test a-caught-warning-is-not-counted-as-an-error
  "The gate reports warnings separately, through WARNINGS-IN, so this scan must not double them."
  (%load-caught-errors)
  (is (null (%errors-in (format nil "; in: DEFUN F~%; caught WARNING:~%;   undefined variable: X~%")))))
