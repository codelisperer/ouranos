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
  "Write and load an .asd in a fresh tree, and return the prefix of the systems it defines.
<p>/tests runs, through :in-order-to ((test-op (test-op ...))): <p>/extra/tests, named with a
(:version ...) form; <p>/here/tests, under a feature that holds on SBCL; and <p>/absent/tests,
under a feature that holds nowhere. It only :depends-on <p>/loaded/tests. Nothing names
<p>/versioned/tests, and <p>/plain has no /tests system."
  (let* ((dir (%fresh-tree))
         (prefix (format nil "unrunfx-~(~36R~)" (random (expt 2 40) (make-random-state t))))
         (asd (merge-pathnames (format nil "~A.asd" prefix) dir)))
    (flet ((name (suffix) (format nil "~A/~A" prefix suffix)))
      (with-open-file (out asd :direction :output)
        (format out "(defsystem ~S)~%" prefix)
        (format out "(defsystem ~S :depends-on (~S ~S) :in-order-to ((test-op (test-op ~A))))~%"
                (name "tests") prefix (name "loaded/tests")
                (format nil "(:version ~S \"0\") (:feature :sbcl ~S) ~A"
                        (name "extra/tests") (name "here/tests")
                        (format nil "(:feature :ouranos-no-such-feature ~S)"
                                (name "absent/tests"))))
        (dolist (suffix '("extra" "extra/tests" "versioned" "versioned/tests" "plain"
                          "here" "here/tests" "absent" "absent/tests" "loaded" "loaded/tests"))
          (format out "(defsystem ~S)~%" (name suffix)))))
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

(test a-suite-another-run-suite-runs-through-test-op-counts-as-run
  "#992: aion/tests runs aion/csv/tests, aion/csv/types/tests, aion/clock/tests and
aion/log/tests through :in-order-to ((test-op (test-op ...))), so they are not in the run list
themselves. A /tests system a run suite reaches that way counts as run, including through a
(:version ...) form. One that nothing in the run list reaches is still reported."
  (let* ((p (%unrun-fixture))
         (extra (format nil "~A/extra" p))
         (versioned (format nil "~A/versioned" p))
         (run (list (format nil "~A/tests" p))))
    (is (null (ouranos-unrun-suites:unrun-suites (list p extra) run))
        "<p>/tests runs <p>/extra/tests")
    (is (equal (list (cons p (first run)) (cons extra (format nil "~A/tests" extra)))
               (ouranos-unrun-suites:unrun-suites (list p extra) '()))
        "control: without <p>/tests in the run list, nothing runs <p>/extra/tests")
    (is (equal (list (cons versioned (format nil "~A/tests" versioned)))
               (ouranos-unrun-suites:unrun-suites (list p extra versioned) run))
        "nothing runs <p>/versioned/tests")))

(test a-suite-a-run-suite-only-depends-on-is-reported
  "The hub's ruling on #992, after the review of #1072: ASDF loads a :depends-on and does not
run its tests, so a suite reached only that way is reported. praxeon/web/tests depends on
hyperion/assets/tests for its browser helpers and does not run it. The control is the same
suite in the run list."
  (let* ((p (%unrun-fixture))
         (loaded (format nil "~A/loaded" p))
         (run (list (format nil "~A/tests" p))))
    (is (equal (list (cons loaded (format nil "~A/tests" loaded)))
               (ouranos-unrun-suites:unrun-suites (list loaded) run)))
    (is (null (ouranos-unrun-suites:unrun-suites (list loaded)
                                                 (cons (format nil "~A/tests" loaded) run)))
        "control: the same suite in the run list")))

(test a-dependency-under-a-feature-that-does-not-hold-is-not-run
  "Review of #1072: ASDF skips (:feature expression name) when EXPRESSION does not hold, so a
suite a run suite names that way in its test-op wiring is not run on this host and is
reported. The control is the same form under :sbcl, which holds here."
  (let* ((p (%unrun-fixture))
         (here (format nil "~A/here" p))
         (absent (format nil "~A/absent" p)))
    (is (equal (list (cons absent (format nil "~A/tests" absent)))
               (ouranos-unrun-suites:unrun-suites (list here absent)
                                                  (list (format nil "~A/tests" p)))))))

(test a-system-with-no-tests-system-is-not-reported
  "A system with no /tests suite is neither reported nor counted as checked. The second value
counts only systems that have one, so the gate can fail when it checked nothing (review of
#1072). The control is a system that has one, counted whether or not its suite runs."
  (let ((p (%unrun-fixture)))
    (multiple-value-bind (unrun checked)
        (ouranos-unrun-suites:unrun-suites (list (format nil "~A/plain" p)) '())
      (is (null unrun))
      (is (eql 0 checked)))
    (is (eql 2 (nth-value 1 (ouranos-unrun-suites:unrun-suites
                             (list p (format nil "~A/plain" p) (format nil "~A/extra" p))
                             (list (format nil "~A/tests" p)))))
        "control: <p> and <p>/extra have a /tests suite, <p>/plain does not")))

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
lists, the optional axes' included, has its /tests system in the gate's run lists, or reached
from them through :in-order-to test-op wiring. The platform packages are not covered here; the
gate checks those on the host that owns them."
  (let ((systems (append (%gate-list "+systems+") (%gate-list "+uv-systems+")
                         (%gate-list "+tls-systems+") (%gate-list "+libgit-systems+")))
        (tests (append (%gate-list "+test-systems+") (%gate-list "+uv-test-systems+")
                       (%gate-list "+tls-test-systems+") (%gate-list "+libgit-test-systems+"))))
    (is (< 50 (length systems)) "the compile lists were read (~D systems)" (length systems))
    (multiple-value-bind (unrun checked) (ouranos-unrun-suites:unrun-suites systems tests)
      (is (null unrun))
      (is (< 50 checked) "the systems with a /tests suite were counted (~D)" checked))
    (is (member :aion/sexp/tests tests) "the suite #973 left out is in the run list now")))

(test the-gate-resolves-systems-in-its-own-tree
  "Review of #1072: the gate's own image resolves systems for this check, so it searches the
tree it is verifying first, as its children do. Otherwise a registry naming another checkout
answers, and a suite added only in this tree is not found. The registry is set before the
toplevel form that runs the gate."
  (let* ((text (uiop:read-file-string (merge-pathnames "verify-tree.lisp" *scripts*)))
         (init (search "(asdf:initialize-source-registry `(:source-registry (:tree ,*root*)"
                       text))
         (toplevel (search "(let ((t0 (get-internal-real-time)))" text)))
    (is-true init "verify-tree.lisp puts its own tree in the source registry")
    (is-true (and init toplevel (< init toplevel)) "before the gate runs")))

(test the-gate-calls-the-check-before-it-loads-anything
  "#992: a check the gate never calls is not a check. verify-tree.lisp loads unrun-suites.lisp,
and its toplevel calls CHECK-UNRUN-SUITES before the LOADING section."
  (let* ((text (uiop:read-file-string (merge-pathnames "verify-tree.lisp" *scripts*)))
         (call (search "  (check-unrun-suites)" text))
         (loading (search "(format t \"~%========== LOADING" text)))
    (is-true (search "\"unrun-suites.lisp\"" text) "verify-tree.lisp loads unrun-suites.lisp")
    (is-true call "the toplevel calls CHECK-UNRUN-SUITES")
    (is-true (and call loading (< call loading)) "the call comes before LOADING")
    (is-true (search "((zerop checked)" text)
             "CHECK-UNRUN-SUITES fails when it found no /tests suite to check")))
