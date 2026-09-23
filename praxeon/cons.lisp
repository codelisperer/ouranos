;;;; cons.lisp --- build spec for Praxeon, consumed by `cons`.
;;;;
;;;; The cross-OS replacement for praxeon/Makefile: `cons <target> KEY=VALUE ...`
;;;; works identically on Linux / macOS / Windows (no GNU-make dependency). Run from
;;;; this directory:
;;;;
;;;;   cons                    list the targets
;;;;   cons build              compile the system
;;;;   cons test               run the network-free fiveam suite
;;;;   cons run                Elise, interactive CLI
;;;;   cons serve HOST=0.0.0.0 Elise web app on :8080, reachable on the LAN
;;;;   cons dev   HOST=0.0.0.0 hot-reload REPL + Elise web app (the Mac `make dev`)
;;;;   cons elise              dump the standalone bin/elise executable
;;;;
;;;; Targets run IN cons's warm image by default; `cons --fresh <target>` runs the
;;;; Lisp work in a subprocess sbcl instead. See cons/docs and the top-level Makefile
;;;; (INTERIM) for the tasks this supersedes.

(cons:project "praxeon"
  :system "praxeon"                 ; primary ASDF system (build)
  :dynamic-space-size 4096          ; heap for --fresh/subprocess + :sh targets
  :env (".env")                     ; load-dotenv (cwd .env) before any target
  :params ((host "127.0.0.1" :doc "web bind address; 0.0.0.0 to reach it from the LAN"))
  :default (check)                  ; the quick dev cycle (shown by `cons`)
  :targets
  ((check   :doc "compile + test -- the quick dev cycle (was `make`)"
            :steps (build test))
   (all     :doc "everything: system, tests, bin/elise, the paper (was `make all`)"
            :steps (build test elise paper))

   (build   :doc "compile the system (quickload :praxeon)"
            :load "praxeon")

   ;; An :eval clause (not the :test convenience) so the exit code reflects the fiveam
   ;; run status exactly, as the Makefile `test` target does.
   (test    :doc "run the network-free fiveam suite"
            :load "praxeon/tests"
            :eval "(let ((r (fiveam:run (uiop:find-symbol* :praxeon :praxeon/tests))))
                     (fiveam:explain! r)
                     (uiop:quit (if (fiveam:results-status r) 0 1)))")

   (run     :doc "run Elise interactively in the CLI"
            :load "praxeon/elise"
            :call ("praxeon/elise:start"))

   (serve   :doc "run Elise as a web app on :8080 (HOST=0.0.0.0 for LAN)"
            :load "praxeon/elise"
            :call ("praxeon/elise:serve" :host host))

   ;; :interactive -- dev returns immediately (watcher + server run on background
   ;; threads), so cons drops into a REPL afterwards to keep the process alive, just
   ;; as `make dev` lands in the SBCL REPL.
   (dev     :doc "hot-reload REPL: watcher + Elise on :8080 (HOST=0.0.0.0 for LAN)"
            :interactive t
            :load "praxeon/elise"
            :call ("praxeon/elise:dev" :host host))

   ;; save-lisp-and-die must run out-of-image -- :sh is always a subprocess.
   (elise   :doc "build the standalone bin/elise executable (CLI + --server modes)"
            :sh ("sbcl" "--dynamic-space-size" "4096" "--non-interactive"
                        "--load" "scripts/build-elise.lisp"))

   (paper   :doc "compile paper/main.pdf (needs a POSIX shell; best-effort on Windows)"
            :cwd "paper" :sh ("./build.sh"))))
