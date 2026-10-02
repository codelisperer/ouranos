;;;; build-{{name}}.lisp --- dump a standalone bin/{{name}} executable.
;;;;
;;;; Run OUT-OF-IMAGE (save-lisp-and-die exits the process); `cons bin` does this
;;;; via a :sh subprocess sbcl -- see cons.lisp. The resulting binary runs
;;;; {{name}}:main and needs no SBCL/Quicklisp installed to run. It serves on libuv, which this
;;;; script copies beside it with its license under bin/LICENSES/ (#513): copy bin/ as a whole.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
;; Discovery comes from the ASDF source-registry drop-in written by the repo-root
;; bootstrap.lisp (or `cons setup`); no *central-registry* push / local-projects.
(ql:quickload "{{name}}")

(ensure-directories-exist "bin/")
;; The native libraries the Ouranos tree builds and the app may load lazily -- libuv, for a
;; server on :uv, and mbedTLS, for TLS -- are copied beside bin/{{name}}, where the binary looks
;; for them first, and the binary is set not to look in the tree it was built from (#513).
;; Without that, a binary that loads one runs on this machine, which has the tree, and fails on
;; any other. tree-natives.lisp is the code a desktop bundle is built with; for an app that loads
;; neither library it copies nothing. It stops the build, with exit code 3 and the reason, if
;; the app loads one this machine has no built copy of.
(load (merge-pathnames "scripts/tree-natives.lisp"
                       (uiop:pathname-parent-directory-pathname
                        (asdf:system-source-directory "cons/env"))))
(ouranos-tree-natives:carry-tree-natives "bin/" :label "build-{{name}}")
;; UIOP's dump hook runs before the dump, and its restore hook runs first when the binary
;; starts. Without them the binary keeps this machine's temporary directory and fasl cache:
;; built on a CI runner, it looks for the runner's temp directory on a user's machine and
;; fails where it needs one (measured on the framework's issue #107).
(uiop:call-image-dump-hook)
;; Add :compression t if this SBCL was built with core compression (smaller binary).
(sb-ext:save-lisp-and-die
 "bin/{{name}}"
 :executable t
 :toplevel (lambda ()
             (uiop:call-image-restore-hook)
             ({{name}}:main)))
