;;;; cons.lisp --- build spec for contacts, consumed by `cons`.
;;;;
;;;; Cross-OS dev tasks: run `cons` to list them, `cons <target> KEY=VALUE` to run one.
;;;; Replaces the per-project Makefile -- no GNU-make dependency; identical on Linux /
;;;; macOS / Windows. Targets run in cons's warm image; `cons --fresh <target>` uses a
;;;; subprocess sbcl instead. Discovery is automatic once the repo-root
;;;; `sbcl --script bootstrap.lisp` has written the ASDF source-registry drop-in.

(cons:project "contacts"
  :system "contacts"
  :dynamic-space-size 4096
  :env (".env")
  :default (build)
  :targets
  ((build :doc "compile contacts"
          :load "contacts")
   (test  :doc "run the test suite"
          :test "contacts/tests")
   (repl  :doc "interactive SBCL REPL (the tree is on the ASDF path)"
          :interactive t)
   (run   :doc "run contacts"
          :load "contacts" :call ("mnemosyne/examples/contacts:main"))
   ;; save-lisp-and-die dumps the image and EXITS, so it cannot run in cons's warm
   ;; image -- a :sh target is always a subprocess sbcl. Loads scripts/build-contacts.lisp.
   (bin   :doc "dump the standalone bin/contacts executable"
          :sh ("sbcl" "--dynamic-space-size" "4096" "--non-interactive"
                      "--load" "scripts/build-contacts.lisp"))))
