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

(defun %run-check-compile (dir &rest more-dirs)
  "Run scripts/check-compile.lisp on the fixture system in DIR, with DIR and MORE-DIRS in the
source registry. (values EXIT-CODE OUTPUT)."
  (%run-check-compile-on '("check-compile-fixture") (cons dir more-dirs)))

(defun %run-check-compile-on (systems dirs)
  "Run scripts/check-compile.lisp on SYSTEMS, with DIRS in the source registry.
(values EXIT-CODE OUTPUT)."
  (multiple-value-bind (out err code)
      (uiop:run-program
       (list* (namestring sb-ext:*runtime-pathname*) "--script"
              (namestring (merge-pathnames "scripts/check-compile.lisp" (%tree-root)))
              systems)
       :directory (%tree-root)
       :output :string :error-output :output :ignore-error-status t
       :environment (cons (format nil "CL_SOURCE_REGISTRY=~{~A//~A~}"
                                  (loop for d in dirs
                                        collect (uiop:native-namestring d)
                                        collect (uiop:inter-directory-separator)))
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

;;; --- a function defined in two files (#577) -------------------------------------------------
;;;
;;; #568 defined %PROBE-REPORT in scripts/tests/release-settings.lisp, which replaced the one in
;;; windows-launcher.lisp loaded before it; SBCL's redefinition warning is a style-warning, so
;;; nothing failed until four tests did on Windows. check-compile.lisp now fails such a system,
;;; through scripts/redefinitions.lisp, as the gate does.

(defparameter +two-file-asd+
  "(defsystem \"check-compile-fixture\" :serial t :components ((:file \"a\") (:file \"b\")))
")

(defmacro %with-two-file-fixture ((dir a-source b-source) &body body)
  "A fresh DIR holding the two-file fixture system, its files a.lisp and b.lisp holding
A-SOURCE and B-SOURCE after a shared package definition."
  `(tempdir:with-temporary-directory (,dir "check-compile-redef")
     (with-open-file (out (merge-pathnames "check-compile-fixture.asd" ,dir) :direction :output)
       (write-string +two-file-asd+ out))
     (with-open-file (out (merge-pathnames "a.lisp" ,dir) :direction :output)
       (format out "(defpackage #:check-compile-fixture (:use #:cl))~%(in-package #:check-compile-fixture)~%~A~%" ,a-source))
     (with-open-file (out (merge-pathnames "b.lisp" ,dir) :direction :output)
       (format out "(in-package #:check-compile-fixture)~%~A~%" ,b-source))
     ,@body))

(test a-function-defined-in-two-files-fails-the-system
  "%PROBE-REPORT's case: b.lisp defines a function a.lisp already defined, with other arguments.
The system compiles and loads, and the script fails it, naming the function and both files."
  (%with-two-file-fixture (dir "(defun helper (program args) (list program args))"
                               "(defun helper (bundle) (list bundle))")
    (multiple-value-bind (code output) (%run-check-compile dir)
      (is (= 1 code) "exit ~D, expected 1:~%~A" code output)
      (is (search "FAIL    check-compile-fixture" output) "no FAIL line for the fixture:~%~A" output)
      (is (search "CHECK-COMPILE-FIXTURE::HELPER" output) "the report does not name the function:~%~A" output)
      (is (and (search "a.lisp" output) (search "b.lisp" output))
          "the report does not name both files:~%~A" output))))

(test the-same-two-files-with-different-names-pass
  "The control for the test above: the same two files, with b.lisp's function renamed."
  (%with-two-file-fixture (dir "(defun helper (program args) (list program args))"
                               "(defun other-helper (bundle) (list bundle))")
    (multiple-value-bind (code output) (%run-check-compile dir)
      (is (= 0 code) "exit ~D, expected 0:~%~A" code output)
      (is (search "ok      check-compile-fixture" output) "no ok line for the fixture:~%~A" output))))

(test a-function-defined-twice-in-one-file-is-left-to-the-compiler
  "Within one file SBCL's compiler already fails the system: compiling a file that defines a
function twice gives the WARNING \"Duplicate definition for HELPER found in one file\", which
the gate fails on. So #577 reports only definitions in two different files, and a duplicate in
one file is reported once, by the compiler, not again as a redefinition."
  (%with-two-file-fixture (dir "(defun helper () 1)
(defun helper () 2)"
                               "(defun other-helper () 3)")
    (multiple-value-bind (code output) (%run-check-compile dir)
      (is (= 1 code) "exit ~D, expected 1:~%~A" code output)
      (is (search "Duplicate definition for HELPER found in one file" output)
          "the compiler's warning is the reason:~%~A" output)
      (is (not (search "defined a second time in another file" output))
          "and it is not also reported as a redefinition:~%~A" output))))

(test one-file-reached-by-two-spellings-is-not-reported
  "b.lisp loads a.lisp again by another spelling of its path, sub/../a.lisp, so HELPER is
redefined from what SBCL records as a different source pathname. It is the same file, and the
script compares files by truename, so nothing is reported and the system passes."
  (%with-two-file-fixture (dir "(defun helper () 1)"
                               "(load (merge-pathnames \"sub/../a.lisp\" (asdf:system-source-directory \"check-compile-fixture\")))")
    (ensure-directories-exist (merge-pathnames "sub/" dir))
    (multiple-value-bind (code output) (%run-check-compile dir)
      (is (= 0 code) "exit ~D, expected 0:~%~A" code output)
      (is (search "ok      check-compile-fixture" output) "no ok line for the fixture:~%~A" output)
      (is (not (search "CHECK-COMPILE-FIXTURE::HELPER" output))
          "one file was reported as two:~%~A" output))))

(test a-dependency-defining-a-function-in-two-files-is-not-reported
  "Only the checked code counts. Here the checked system depends on a system in another
temporary directory, outside this tree and outside the checked system's own directory, whose
two files both define HELPER. The script loads the dependency inside the same handler, and must
not fail the checked system for what the dependency does."
  (tempdir:with-temporary-directory (dep "check-compile-dep")
    (with-open-file (out (merge-pathnames "check-compile-dep.asd" dep) :direction :output)
      (write-string "(defsystem \"check-compile-dep\" :serial t :components ((:file \"a\") (:file \"b\")))
" out))
    (with-open-file (out (merge-pathnames "a.lisp" dep) :direction :output)
      (format out "(defpackage #:check-compile-dep (:use #:cl))~%(in-package #:check-compile-dep)~%(defun helper (program args) (list program args))~%"))
    (with-open-file (out (merge-pathnames "b.lisp" dep) :direction :output)
      (format out "(in-package #:check-compile-dep)~%(defun helper (bundle) (list bundle))~%"))
    (tempdir:with-temporary-directory (dir "check-compile-redef")
      (with-open-file (out (merge-pathnames "check-compile-fixture.asd" dir) :direction :output)
        (write-string "(defsystem \"check-compile-fixture\" :depends-on (\"check-compile-dep\") :components ((:file \"fixture\")))
" out))
      (with-open-file (out (merge-pathnames "fixture.lisp" dir) :direction :output)
        (format out "(defpackage #:check-compile-fixture (:use #:cl))~%(in-package #:check-compile-fixture)~%(defun answer () 42)~%"))
      (multiple-value-bind (code output) (%run-check-compile dir dep)
        (is (= 0 code) "exit ~D, expected 0:~%~A" code output)
        (is (search "ok      check-compile-fixture" output) "no ok line for the fixture:~%~A" output)
        (is (not (search "CHECK-COMPILE-DEP::HELPER" output))
            "the dependency's redefinition was reported:~%~A" output)))))

;;; --- a system that cannot load on this host (#283) -------------------------------------------
;;;
;;; Editing aion/aion.asd made check-compile check the aion/windows systems on Linux, where they
;;; cannot load, and fail. It now skips a system scripts/platform-packages.lisp says another OS
;;; owns, and prints a SKIPPED line saying so. The tests name a real system another OS owns,
;;; chosen from the registry, so they run on every host.

(defun %foreign-system ()
  "A system some OS other than this host owns, from the registry: (values NAME OWNER)."
  (%load-platform-registry)
  (let ((pair (first (%pf not-applicable-for (%pf host-os)))))
    (values (getf (cdr pair) :system) (car pair))))

(test a-system-another-os-owns-is-skipped-and-said-so
  (multiple-value-bind (system owner) (%foreign-system)
    (%with-fixture (dir nil)
      (multiple-value-bind (code output) (%run-check-compile-on (list system "check-compile-fixture") (list dir))
        (is (= 0 code) "exit ~D, expected 0:~%~A" code output)
        (is (search (format nil "SKIPPED ~A" system) output) "no SKIPPED line for ~A:~%~A" system output)
        (is (search (format nil "~(~a~) only" owner) output) "the line does not name the owner:~%~A" output)
        (is (not (search (format nil "FAIL    ~A" system) output)) "it was checked anyway:~%~A" output)
        (is (search "ok      check-compile-fixture" output) "the other system was not checked:~%~A" output)
        (is (search "1 system checked, 0 failed, 1 skipped" output) "the summary is wrong:~%~A" output)))))

(test a-skip-does-not-hide-a-failure
  "A skipped system next to one that fails here: the run still fails."
  (multiple-value-bind (system) (%foreign-system)
    (%with-fixture (dir t)
      (multiple-value-bind (code output) (%run-check-compile-on (list system "check-compile-fixture") (list dir))
        (is (= 1 code) "exit ~D, expected 1:~%~A" code output)
        (is (search "FAIL    check-compile-fixture" output) "no FAIL line for the fixture:~%~A" output)
        (is (search (format nil "SKIPPED ~A" system) output) "no SKIPPED line:~%~A" output)))))
