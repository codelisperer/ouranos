;;;; env-package.lisp --- the package for the .env loader.
;;;;
;;;; Separate from src/packages.lisp because `cons/env` is its OWN ASDF system (see
;;;; cons.asd): a scaffolded app must load its .env as the first act of every entry point
;;;; (pre-publication issue 120), so it depends on this loader -- and it must not drag the whole build tool in
;;;; behind it to get one file.

(cl:defpackage #:cons/env
  (:use #:cl)
  (:documentation
   "Load a project-local, git-ignored .env (KEY=VALUE) into the process environment;
    the host env wins by default (prod ships real vars, no .env). The one shared loader
    every project delegates to. `cons init` scaffolds the matching .env.example +
    .gitignore.

    LOAD-DOTENV takes a path. LOAD-PROJECT-ENV is what an ENTRY POINT calls: it resolves
    the file relative to the app's own ASDF system rather than the current directory, and
    is idempotent, so it can be the unconditional first line of `main` without caring who
    else already called it. That ordering is the whole point -- a .env loaded lazily,
    wherever the first consumer happens to sit, is a .env that was not loaded for whatever
    ran before it. uiop-only (cons stays dependency-light).")
  (:export #:load-dotenv #:load-project-env #:dotenv-path #:*loaded-from*))
