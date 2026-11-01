;;;; unrun-suites.lisp --- a compiled system whose /tests system the gate never runs (#992).
;;;;
;;;; scripts/unrun-suites.lisp holds UNRUN-SUITES, which verify-tree.lisp calls before it loads
;;;; anything. These tests give it a fixture tree: a real .asd, defining systems under a name
;;;; no other run has used, so the systems ASDF finds are the fixture's own.

(in-package #:checkers/tests)

;;; FiveAM's current suite does not carry over from one file to the next (see dump-image.lisp).
(in-suite checkers)

;;; At compile time too: the tests below name the package it defines.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (load (merge-pathnames "unrun-suites.lisp" *scripts*)))

(defun %unrun-fixture ()
  "Write and load an .asd in a fresh tree, and return the prefix of the systems it defines:
<p>, which has <p>/tests; <p>/extra, whose <p>/extra/tests only <p>/tests depends on, through a
(:version ...) form; <p>/versioned, whose <p>/versioned/tests nothing depends on; and
<p>/plain, which has no /tests system."
  (let* ((dir (%fresh-tree))
         (prefix (format nil "unrunfx-~(~36R~)" (random (expt 2 40) (make-random-state t))))
         (asd (merge-pathnames (format nil "~A.asd" prefix) dir)))
    (with-open-file (out asd :direction :output)
      (format out "(defsystem ~S)~%" prefix)
      (format out "(defsystem ~S :depends-on (~S (:version ~S \"0\")))~%"
              (format nil "~A/tests" prefix) prefix (format nil "~A/extra/tests" prefix))
      (dolist (suffix '("extra" "extra/tests" "versioned" "versioned/tests" "plain"))
        (format out "(defsystem ~S)~%" (format nil "~A/~A" prefix suffix))))
    (asdf:load-asd asd)
    prefix))

(test a-compiled-system-whose-tests-the-gate-does-not-run-is-reported
  "#992: #973 compiled aion/sexp and never ran aion/sexp/tests, and every leg was green. With a
system in the compile list and its /tests system absent from the run list, UNRUN-SUITES names
both. The control is the same tree with the suite in the run list."
  (let* ((p (%unrun-fixture))
         (tests (format nil "~A/tests" p)))
    (is (equal (list (cons p tests)) (ouranos-unrun-suites:unrun-suites (list p) '()))
        "the suite is not run")
    (is (null (ouranos-unrun-suites:unrun-suites (list p) (list tests)))
        "control: the same suite in the run list")
    (is (null (ouranos-unrun-suites:unrun-suites (list (intern (string-upcase p) :keyword))
                                                 (list (intern (string-upcase tests) :keyword))))
        "keywords, as verify-tree.lisp writes its lists, name the same systems")))

(test a-suite-another-run-suite-depends-on-counts-as-run
  "#992: aion/tests runs aion/csv/tests, aion/clock/tests and aion/log/tests, which it depends
on, so they are not in the run list themselves. A /tests system that a suite in the run list
depends on counts as run, including through a (:version ...) form. One that nothing in the run
list depends on is still reported."
  (let* ((p (%unrun-fixture))
         (extra (format nil "~A/extra" p))
         (versioned (format nil "~A/versioned" p))
         (run (list (format nil "~A/tests" p))))
    (is (null (ouranos-unrun-suites:unrun-suites (list p extra) run))
        "<p>/tests depends on <p>/extra/tests")
    (is (equal (list (cons p (first run)) (cons extra (format nil "~A/tests" extra)))
               (ouranos-unrun-suites:unrun-suites (list p extra) '()))
        "control: without <p>/tests in the run list, nothing runs <p>/extra/tests")
    (is (equal (list (cons versioned (format nil "~A/tests" versioned)))
               (ouranos-unrun-suites:unrun-suites (list p extra versioned) run))
        "nothing depends on <p>/versioned/tests")))

(test a-system-with-no-tests-system-is-not-reported
  (let ((p (%unrun-fixture)))
    (is (null (ouranos-unrun-suites:unrun-suites (list (format nil "~A/plain" p)) '())))))

(defun %gate-list (name)
  "The value of the DEFPARAMETER NAME in verify-tree.lisp, read from the file, because loading
the gate runs it."
  (let* ((text (uiop:read-file-string (merge-pathnames "verify-tree.lisp" *scripts*)))
         (start (search (format nil "(defparameter ~A" name) text)))
    (assert start () "verify-tree.lisp has no (defparameter ~A" name)
    (let ((form (third (read-from-string text t nil :start start))))
      (assert (and (consp form) (eq (first form) 'quote)) () "~A is not a quoted list" name)
      (second form))))

(test this-tree-runs-every-suite-of-every-system-the-gate-compiles
  "#992, the other direction: this tree passes the check. Every system in the gate's compile
lists, the optional axes' included, has its /tests system in the gate's run lists or a
dependency of one. The platform packages are not covered here; the gate checks those on the
host that owns them."
  (let ((systems (append (%gate-list "+systems+") (%gate-list "+uv-systems+")
                         (%gate-list "+tls-systems+") (%gate-list "+libgit-systems+")))
        (tests (append (%gate-list "+test-systems+") (%gate-list "+uv-test-systems+")
                       (%gate-list "+tls-test-systems+") (%gate-list "+libgit-test-systems+"))))
    (is (< 50 (length systems)) "the compile lists were read (~D systems)" (length systems))
    (is (null (ouranos-unrun-suites:unrun-suites systems tests)))
    (is (member :aion/sexp/tests tests) "the suite #973 left out is in the run list now")))

(test the-gate-calls-the-check-before-it-loads-anything
  "#992: a check the gate never calls is not a check. verify-tree.lisp loads unrun-suites.lisp,
and its toplevel calls CHECK-UNRUN-SUITES before the LOADING section."
  (let* ((text (uiop:read-file-string (merge-pathnames "verify-tree.lisp" *scripts*)))
         (call (search "  (check-unrun-suites)" text))
         (loading (search "(format t \"~%========== LOADING" text)))
    (is-true (search "\"unrun-suites.lisp\"" text) "verify-tree.lisp loads unrun-suites.lisp")
    (is-true call "the toplevel calls CHECK-UNRUN-SUITES")
    (is-true (and call loading (< call loading)) "the call comes before LOADING")))
