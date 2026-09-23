;;;; cons.lisp --- build spec for cons itself, consumed by `cons` (yes, really).
;;;;
;;;; The cross-OS replacement for cons/Makefile: `cons <target>` works identically on
;;;; Linux / macOS / Windows. Run `cons` to list targets. cons is pure-CL and
;;;; dependency-light, so it builds fast. Discovery is automatic once the repo-root
;;;; `sbcl --script bootstrap.lisp` has run.

(cons:project "cons"
  :system "cons"
  :dynamic-space-size 2048            ; cons is lean; it doesn't need the Coalton heap
  :default (build)
  :targets
  ((build :doc "compile cons"
          :load "cons")
   (test  :doc "run the fiveam test suite"
          :load "cons/tests"
          :eval "(uiop:quit (if (cons/tests:run-tests) 0 1))")
   (repl  :doc "interactive SBCL REPL (the tree is on the ASDF path)"
          :interactive t)))

;; NB: there is deliberately NO `bin` target here. Rebuilding bin/cons is the repo-root
;; SEED's job -- `sbcl --dynamic-space-size 4096 --script bootstrap.lisp` -- and must run
;; under RAW SBCL, never a live `cons`: a running bin/cons cannot overwrite its own
;; executable (Windows sharing violation; Linux ETXTBSY). The seed needs nothing but
;; SBCL + Quicklisp, which is exactly what makes the first build possible. See bootstrap.lisp.
