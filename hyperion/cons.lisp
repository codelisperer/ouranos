;;;; cons.lisp --- build spec for hyperion, consumed by `cons`.
;;;;
;;;; The cross-OS replacement for hyperion/Makefile: `cons <target>` works identically
;;;; on Linux / macOS / Windows (no GNU-make dependency). Run `cons` to list targets.
;;;; Discovery is automatic once the repo-root `sbcl --script bootstrap.lisp` has run.
;;;;
;;;; NOTE: the Makefile's `cli`/`install` targets (a per-framework `hyperion` binary)
;;;; are RETIRED -- project tooling is `cons`'s job -- and are intentionally not ported.

(cons:project "hyperion"
  :system "hyperion"
  :dynamic-space-size 4096            ; Coalton's first compile is heap-hungry
  :params ((host "127.0.0.1" :doc "web bind address; 0.0.0.0 to reach it from the LAN"))
  :default (build)
  :targets
  ((build :doc "compile hyperion (first run compiles Coalton; a few minutes)"
          :load "hyperion")
   (test  :doc "run the fiveam test suite"
          :load "hyperion/tests"
          :eval "(uiop:quit (if (hyperion/tests:run-tests) 0 1))")
   (repl  :doc "interactive SBCL REPL (the tree is on the ASDF path)"
          :interactive t)

   ;; Example #1: HTMX active-search (Bulma + HTMX + Alpine + Parenscript). `dev`
   ;; returns immediately (watcher + server on background threads), so drop into a
   ;; REPL to keep it alive -- the same shape as praxeon's Elise `dev`.
   (example-search :doc "run example #1 (HTMX active search) in dev on :8080 (HOST=0.0.0.0 for LAN)"
                   :interactive t
                   :load "hyperion/examples/active-search"
                   :call ("hyperion/examples/active-search:dev" :host host))

   ;; Example #1b: the same UI, DB-backed via a mnemosyne migration (SQLite).
   (example-search-db :doc "run example #1b (active search over a mnemosyne migration) in dev on :8080"
                      :interactive t
                      :load "hyperion/examples/active-search-db"
                      :call ("hyperion/examples/active-search-db:dev" :host host))

   ;; Native binary for the example (save-lisp-and-die must run out-of-image -> :sh).
   (example-search-bin
    :doc "build example #1 to bin/active-search (native)"
    :sh ("sbcl" "--dynamic-space-size" "4096" "--non-interactive"
         "--eval" "(load (merge-pathnames \"quicklisp/setup.lisp\" (user-homedir-pathname)))"
         "--eval" "(ql:quickload :hyperion/examples/active-search)"
         "--eval" "(sb-ext:save-lisp-and-die \"bin/active-search\" :toplevel (function hyperion/examples/active-search:main) :executable t)"))))
