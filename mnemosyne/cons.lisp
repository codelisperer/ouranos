;;;; cons.lisp --- build spec for mnemosyne, consumed by `cons`.
;;;;
;;;; The cross-OS replacement for mnemosyne/Makefile: `cons <target>` works identically
;;;; on Linux / macOS / Windows (no GNU-make dependency). Run `cons` to list targets.
;;;; Discovery is automatic once the repo-root `sbcl --script bootstrap.lisp` has run.

(cons:project "mnemosyne"
  :system "mnemosyne"
  :dynamic-space-size 4096            ; Coalton's first compile is heap-hungry
  :default (build)
  :targets
  ((build :doc "compile mnemosyne (first run compiles Coalton; a few minutes)"
          :load "mnemosyne")
   (test  :doc "run the fiveam test suite"
          :load "mnemosyne/tests"
          :eval "(uiop:quit (if (mnemosyne/tests:run-tests) 0 1))")
   (repl  :doc "interactive SBCL REPL (the tree is on the ASDF path)"
          :interactive t)))
