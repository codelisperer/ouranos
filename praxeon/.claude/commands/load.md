---
description: Quickload Praxeon and confirm it compiles (incl. the Coalton core).
---
Load the system and confirm a clean compile:

```lisp
;; discovery is automatic — the repo-root bootstrap.lisp writes an ASDF (:tree)
;; source-registry drop-in, so this loads from any REPL (no symlink, no
;; asdf:*central-registry*)
(ql:quickload :praxeon)
```

If the Coalton core (`src/praxeology.lisp`) raises a type error, read it
carefully and fix the core — do not silence it. Report the first error with file
and form. On success, report the exported symbols now available.
