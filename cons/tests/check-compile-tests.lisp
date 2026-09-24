;;;; check-compile-tests.lisp --- scripts/check-compile.lisp fails what the gate fails (#117)
;;;;
;;;; A suite can pass while its compile prints warnings the gate fails on. #117 measured it
;;;; with an unescaped quote in one docstring: `(asdf:test-system :cons)' printed four
;;;; `caught WARNING' lines and `Fail: 0', and printed nothing on a second, warm run.
;;;; scripts/check-compile.lisp exists to catch that in seconds rather than in a full gate.
;;;;
;;;; SO THE CONTROL RUNS THE REAL SCRIPT on a real system, as scripts/tests/checkers.lisp does
;;;; for the gate's checkers: a one-file fixture system in a fresh directory, once with the
;;;; quote and once without. The script finds it through the caller's CL_SOURCE_REGISTRY,
;;;; which it appends after this tree. The fixture is loaded only in the script's own child
;;;; images, never in this one.

(in-package #:cons/tests)

(def-suite check-compile
  :description "scripts/check-compile.lisp fails a system whose compile the gate would fail (#117)." :in all)
(in-suite check-compile)

(defun %tree-root ()
  "The monorepo root: the directory above cons/, where scripts/ lives."
  (uiop:pathname-parent-directory-pathname (asdf:system-source-directory :cons)))

(defparameter +fixture-asd+
  "(defsystem \"check-compile-fixture\" :components ((:file \"fixture\")))
")

(defparameter +fixture-source+
  "(defpackage #:check-compile-fixture (:use #:cl))
(in-package #:check-compile-fixture)

(defun answer ()
  \"Return the answer.~A\"
  42)
"
  "~A is replaced by the defect, an unescaped quote pair, or by nothing.")

(defun %run-check-compile (dir)
  "Run scripts/check-compile.lisp on the fixture system in DIR. (values EXIT-CODE OUTPUT)."
  (multiple-value-bind (out err code)
      (uiop:run-program
       (list (namestring sb-ext:*runtime-pathname*) "--script"
             (namestring (merge-pathnames "scripts/check-compile.lisp" (%tree-root)))
             "check-compile-fixture")
       :directory (%tree-root)
       :output :string :error-output :output :ignore-error-status t
       :environment (cons (format nil "CL_SOURCE_REGISTRY=~A//~A" (uiop:native-namestring dir)
                                  (uiop:inter-directory-separator))
                          (remove-if (lambda (e) (uiop:string-prefix-p "CL_SOURCE_REGISTRY=" e))
                                     (sb-ext:posix-environ))))
    (declare (ignore err))
    (values code out)))

(defmacro %with-fixture ((dir with-defect-p) &body body)
  `(tempdir:with-temporary-directory (,dir "check-compile")
     (with-open-file (out (merge-pathnames "check-compile-fixture.asd" ,dir) :direction :output)
       (write-string +fixture-asd+ out))
     (with-open-file (out (merge-pathnames "fixture.lisp" ,dir) :direction :output)
       (format out +fixture-source+ (if ,with-defect-p " A \"works on my machine\" trap." "")))
     ,@body))

(test the-script-exists-where-the-tests-run-it
  "Asserted directly, so a moved script is reported as that rather than as a failed check below."
  (is-true (probe-file (merge-pathnames "scripts/check-compile.lisp" (%tree-root)))))

(test a-docstring-quote-fails-the-system
  "The defect's own shape. The fixture compiles, so ASDF would load it; the script fails it
because the compiler's output has warnings the gate fails on."
  (%with-fixture (dir t)
    (multiple-value-bind (code output) (%run-check-compile dir)
      (is (= 1 code) "exit ~D, expected 1:~%~A" code output)
      (is (search "FAIL    check-compile-fixture" output) "no FAIL line for the fixture:~%~A" output)
      (is (search "undefined variable" output) "the report does not show the warning:~%~A" output)
      (is (search "MACHINE" output) "the report does not name a word after the quote:~%~A" output))))

(test the-same-system-without-the-quote-passes
  (%with-fixture (dir nil)
    (multiple-value-bind (code output) (%run-check-compile dir)
      (is (= 0 code) "exit ~D, expected 0:~%~A" code output)
      (is (search "ok      check-compile-fixture" output) "no ok line for the fixture:~%~A" output)
      (is (search "1 system checked, 0 failed" output) "the summary is missing:~%~A" output))))

(test a-second-run-still-fails
  "The property a suite lacks: on a second, warm run it printed nothing (#117). The script
sends this tree's fasls to a new directory every run, so the second run must fail as the first did."
  (%with-fixture (dir t)
    (let ((first (%run-check-compile dir))
          (second (%run-check-compile dir)))
      (is (= 1 first) "the first run exited ~D" first)
      (is (= 1 second) "the second run exited ~D: a cache hid the warning" second))))
