;;;; cons.lisp --- build spec for {{name}}, consumed by `cons`.
;;;;
;;;; Cross-OS dev tasks: run `cons` to list them, `cons <target> KEY=VALUE` to run one.
;;;; Replaces the per-project Makefile -- no GNU-make dependency; identical on Linux /
;;;; macOS / Windows. Targets run in cons's warm image; `cons --fresh <target>` uses a
;;;; subprocess sbcl instead. Discovery is automatic once the repo-root
;;;; `sbcl --script bootstrap.lisp` has written the ASDF source-registry drop-in.

(cons:project "{{name}}"
  :system "{{name}}"
  :dynamic-space-size 4096
  :env (".env"){{spec-params}}
  :default (build)
  :targets
  ((build :doc "compile {{name}}"
          :load "{{name}}")
   (test  :doc "run the test suite"
          :test "{{name}}/tests")
   (repl  :doc "interactive SBCL REPL (the tree is on the ASDF path)"
          :interactive t){{targets-extra}}))
