;;;; child-scripts.lisp --- check-child-scripts.lisp finds an undefined call (#1086).
;;;;
;;;; Each test builds a tree on disk and runs the real script in it, as checkers.lisp does for
;;;; the other gate checkers. The fixture is a real .asd with a system and its tests system, a
;;;; compiled test file, a child script no system names, and a cons template directory.

(in-package #:checkers/tests)

;;; FiveAM's current suite does not carry over from one file to the next (see dump-image.lisp).
(in-suite checkers)

(defun %child-fixture (child-source)
  "A fresh tree holding system `fx' and `fx/tests', whose compiled test file calls an undefined
function; a child script fx/tests/child.lisp holding CHILD-SOURCE, or none when it is NIL; and a
template directory whose tests/ holds a file with an undefined call. Returns the checker's path
in the tree."
  (let ((tree (%install-root-markers (%fresh-tree))))
    (%write (merge-pathnames "fx/fx.asd" tree)
            (%lines "(defsystem \"fx\" :components ((:file \"src/a\")))"
                    "(defsystem \"fx/tests\" :components ((:file \"tests/compiled\")))"))
    (%write (merge-pathnames "fx/src/a.lisp" tree) (%lines "(defun fx-a () 1)"))
    (%write (merge-pathnames "fx/tests/compiled.lisp" tree)
            (%lines "(defun fx-compiled () (fx-compiled-file-calls-nothing-real 1))"))
    (when child-source
      (%write (merge-pathnames "fx/tests/child.lisp" tree) child-source))
    (%write (merge-pathnames "fx/templates/t1/template.lisp" tree) (%lines "(:name \"t1\")"))
    (%write (merge-pathnames "fx/templates/t1/files/tests/x.lisp" tree)
            (%lines "(defun fx-template () (fx-template-calls-nothing-real 1))"))
    (%install-checker tree "check-child-scripts.lisp")))

(defun %run-child (script)
  "Run SCRIPT, the checker %CHILD-FIXTURE installed, from its tree's root, which is where
tree-root.lisp requires the caller to stand. Returns (values exit-code output)."
  (%run-in (uiop:pathname-parent-directory-pathname (uiop:pathname-directory-pathname script))
           script))

(defparameter +child-script-lines+
  (list "(require :sb-bsd-sockets)"
        "(defun child-main () (child-helper (sb-bsd-sockets:make-inet-address \"127.0.0.1\")))"
        "(defun child-helper (x) x)"
        "(child-main)")
  "A child script that passes: it names sb-bsd-sockets, and calls CHILD-HELPER before the file
defines it, which loading the file form by form would report as undefined.")

(test a-child-script-calling-an-undefined-function-fails-and-is-named
  "#1086: the child script calls a function nothing defines. The check fails, and names the
script and the function. The compiled test file's undefined call is check-compile's to report,
and the template's is `cons template check''s, so neither is named."
  (let ((script (%child-fixture
                 (apply #'%lines (append +child-script-lines+
                                         (list "(defun child-broken () (child-no-such-fn 1))"))))))
    (multiple-value-bind (code output) (%run-child script)
      (is (= 1 code) "an undefined call must fail; exit was ~D~%~A" code output)
      (is (search "FAIL    fx/tests/child.lisp" output) "the script is not named:~%~A" output)
      (is (search "undefined function: COMMON-LISP-USER::CHILD-NO-SUCH-FN" output)
          "the function is not named:~%~A" output)
      (is (not (search "FX-COMPILED-FILE-CALLS-NOTHING-REAL" output))
          "a file a system compiles was checked as a child script:~%~A" output)
      (is (not (search "FX-TEMPLATE-CALLS-NOTHING-REAL" output))
          "a template's file was checked:~%~A" output))))

(test the-same-child-script-without-the-call-passes
  "The control for the test above. CHILD-HELPER is called before it is defined, and is not
reported."
  (let ((script (%child-fixture (apply #'%lines +child-script-lines+))))
    (multiple-value-bind (code output) (%run-child script)
      (is (= 0 code) "exit was ~D~%~A" code output)
      (is (search "ok -- 1 child script," output) "exactly one child script is checked:~%~A"
          output)
      (is (not (search "CHILD-HELPER" output)) "a forward reference was reported:~%~A" output))))

(test a-child-script-that-cannot-be-read-fails
  "A script naming a package the check's image does not have cannot be compiled, and that is a
failure, not a pass: the check could not judge it."
  (let ((script (%child-fixture (%lines "(defun child-main () (no-such-package-1086:f 1))"))))
    (multiple-value-bind (code output) (%run-child script)
      (is (= 1 code) "exit was ~D~%~A" code output)
      (is (search "could not be compiled" output) "the reason is not given:~%~A" output))))

(test a-tree-with-no-child-script-fails
  "A walk that found nothing checked nothing, so it fails rather than printing ok."
  (let ((script (%child-fixture nil)))
    (multiple-value-bind (code output) (%run-child script)
      (is (= 1 code) "exit was ~D~%~A" code output)
      (is (search "found no child script" output) "~A" output))))

(test the-gate-runs-check-child-scripts
  "A check the gate does not call is not a check: verify-tree.lisp's +CHECKERS+ names it."
  (let* ((text (uiop:read-file-string (merge-pathnames "verify-tree.lisp" *scripts*)))
         (list (search "(defparameter +checkers+" text))
         (entry (search "(\"check-child-scripts.lisp\"" text)))
    (is-true (and list entry (< list entry)) "+CHECKERS+ does not name check-child-scripts.lisp")))
