;;;; cons.lisp --- build spec for aion, consumed by `cons`.
;;;;
;;;; The cross-OS replacement for aion/Makefile: `cons <target>` works identically on
;;;; Linux / macOS / Windows (no GNU-make dependency). Run `cons` to list targets.
;;;; Discovery is automatic once the repo-root `sbcl --script bootstrap.lisp` has run.

(cons:project "aion"
  :system "aion"
  :dynamic-space-size 4096            ; Coalton's first compile is heap-hungry
  :default (build)
  :targets
  ((build :doc "compile aion (first run compiles Coalton; a few minutes)"
          :load "aion")
   (test  :doc "run the fiveam test suite"
          :load "aion/tests"
          :eval "(uiop:quit (if (aion/tests:run-tests) 0 1))")
   (uv-test :doc "run the aion/uv suite (needs scripts/build-libuv.lisp first)"
            :load "aion/uv/tests"
            :eval "(uiop:quit (if (aion/uv/tests:run-tests) 0 1))")
   (net-test :doc "run the aion/uv/net suite: TCP, pipes, DNS, backpressure"
             :load "aion/uv/net/tests"
             :eval "(uiop:quit (if (aion/uv/net/tests:run-tests) 0 1))")
   (process-test :doc "run the aion/uv/process suite: spawn, stdio, signals"
                 :load "aion/uv/process/tests"
                 :eval "(uiop:quit (if (aion/uv/process/tests:run-tests) 0 1))")
   (repl  :doc "interactive SBCL REPL (the tree is on the ASDF path)"
          :interactive t)))
