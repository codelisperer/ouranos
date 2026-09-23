;;;; cons.lisp --- build spec for klio, consumed by `cons`.
;;;;
;;;; Cross-OS dev tasks: run `cons` to list them, `cons <target> KEY=VALUE` to run one.
;;;; Replaces the per-project Makefile -- no GNU-make dependency; identical on Linux /
;;;; macOS / Windows. Targets run in cons's warm image; `cons --fresh <target>` uses a
;;;; subprocess sbcl instead. Discovery is automatic once the repo-root
;;;; `sbcl --script bootstrap.lisp` has written the ASDF source-registry drop-in.

(cons:project "klio"
  :system "klio"
  :dynamic-space-size 4096
  :env (".env")
  :params ((host "127.0.0.1" :doc "web bind address; 0.0.0.0 to reach it from the LAN"))
  :default (build)
  :targets
  ((build :doc "compile klio"
          :load "klio")
   (test  :doc "run the test suite"
          :test "klio/tests")
   (repl  :doc "interactive SBCL REPL (the tree is on the ASDF path)"
          :interactive t)
   (serve :doc "serve klio on :8080 (HOST=0.0.0.0 for LAN)"
          :load "klio" :call ("klio:serve" :host host))
   (dev   :doc "serve + a REPL for interactive development (HOST=0.0.0.0 for LAN)"
          :interactive t
          :load "klio" :call ("klio:start" :host host))
   ;; save-lisp-and-die dumps the image and EXITS, so it cannot run in cons's warm
   ;; image -- a :sh target is always a subprocess sbcl. Loads scripts/build-klio.lisp.
   (bin   :doc "dump the standalone bin/klio executable"
          :sh ("sbcl" "--dynamic-space-size" "4096" "--non-interactive"
                      "--load" "scripts/build-klio.lisp"))))
