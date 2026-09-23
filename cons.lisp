;;;; cons.lisp --- repo-root build spec: warm the whole monorepo.
;;;;
;;;; Run from the MONOREPO ROOT. A framework's own cons.lisp sits nearer on cons's
;;;; walk-up from the cwd, so it still wins INSIDE a framework dir; this root spec is
;;;; for the tree as a whole. `cons warm` compiles every framework in DAG order so
;;;; their fasls are cached and the next `cons build` / editor load is instant.
;;;; bootstrap.lisp runs the same warm (in a throwaway sbcl) right after it dumps
;;;; bin/cons -- one `sbcl --script bootstrap.lisp` gives you cons AND a ready stack.

(cons:project "ouranos"
  :system "cons"
  :dynamic-space-size 4096            ; Coalton's first compile is heap-hungry
  :default (warm)
  :targets
  ;; DAG order (aion -> praxeon); loading right-to-left would violate the deps anyway,
  ;; but declaring the order makes the intent explicit. cons is already in this image.
  ((warm :doc "compile every framework in DAG order; warms the fasl cache (minutes cold, seconds warm)"
         :load ("aion" "cons" "mnemosyne" "elenchon" "hyperion" "praxeon"))))
