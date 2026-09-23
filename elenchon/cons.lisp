;;;; cons.lisp --- build spec for elenchon, consumed by `cons`.
;;;;
;;;; The cross-OS replacement for elenchon/Makefile: `cons <target>` works identically
;;;; on Linux / macOS / Windows (no GNU-make dependency). Run `cons` to list targets.
;;;; Discovery is automatic once the repo-root `sbcl --script bootstrap.lisp` has run.

(cons:project "elenchon"
  :system "elenchon"
  :dynamic-space-size 4096            ; Coalton's first compile is heap-hungry
  :default (build)
  :targets
  ((build :doc "compile elenchon (first run compiles Coalton; a few minutes)"
          :load "elenchon")
   ;; No run-tests entry yet -- the :test convenience runs the ASDF test-op.
   (test  :doc "run the test suite (once one exists)"
          :test "elenchon/tests")
   (repl  :doc "interactive SBCL REPL (the tree is on the ASDF path)"
          :interactive t)))
