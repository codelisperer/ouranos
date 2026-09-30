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
;; Through scripts/dump-image.lisp, not `save-lisp-and-die' directly, so the binary takes its
;; temporary directory, fasl cache and ASDF configuration from the machine it runs on (#107,
;; #287). :COMPRESSION because this SBCL is built with core compression: a smaller binary.
(load (merge-pathnames "../../scripts/dump-image.lisp"
                       (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))
(ouranos-dump:dump-executable "bin/elise" 'praxeon/elise:main :compression t)
