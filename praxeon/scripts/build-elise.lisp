;;;; build-elise.lisp --- dump a standalone Elise executable to bin/elise.
;;;;
;;;; Run from the repo root (the Makefile `elise` target does):
;;;;   sbcl --non-interactive --load scripts/build-elise.lisp
;;;;
;;;; save-lisp-and-die bundles the whole image; the resulting binary runs
;;;; praxeon/elise:main and needs no SBCL/Quicklisp to run -- only a provider
;;;; configured via the environment or a local .env. It defaults to an
;;;; interactive CLI session; `bin/elise --server [--port N]` runs the web app
;;;; instead (praxeon/web is bundled in, Woo's libev FFI survives the dump).

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
;; Discovery comes from the ambient ASDF source-registry drop-in written by the
;; repo-root bootstrap.lisp (run it once); no *central-registry* push / local-projects.
(ql:quickload :praxeon/elise)

(ensure-directories-exist "bin/")
(sb-ext:save-lisp-and-die
 "bin/elise"
 :executable t
 :toplevel #'praxeon/elise:main
 :compression t)          ; SBCL built with core compression; smaller binary
