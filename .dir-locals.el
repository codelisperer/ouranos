;;; Directory-local variables for the Ouranos monorepo (Emacs / SLIME / Sly).
;;;
;;; Start the inferior Lisp with a Coalton-sized heap, so hyperion / praxeon / etc.
;;; load instead of exhausting the default heap on Coalton's first compile. Discovery
;;; is automatic via the ASDF (:tree) source-registry drop-in that the repo-root
;;; `sbcl --script bootstrap.lisp` writes -- so from the REPL just
;;; `(ql:quickload :<system>)` the piece you're working on (e.g. :cons, :hyperion),
;;; then C-c C-k / C-x C-e in that system's files (SLIME uses each file's in-package).
;;;
;;; M-x slime  (or M-x sly) from any file under this repo picks this up. Emacs may ask
;;; once to confirm the inferior-lisp-program value -- that's expected.

((nil . ((inferior-lisp-program . "sbcl --dynamic-space-size 4096"))))
