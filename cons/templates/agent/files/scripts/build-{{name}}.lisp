;;;; build-{{name}}.lisp --- dump a standalone bin/{{name}} executable.
;;;;
;;;; Run OUT-OF-IMAGE (save-lisp-and-die exits the process); `cons bin` does this
;;;; via a :sh subprocess sbcl -- see cons.lisp. The resulting binary runs
;;;; {{name}}:main and needs no SBCL/Quicklisp installed to run.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
;; Discovery comes from the ASDF source-registry drop-in written by the repo-root
;; bootstrap.lisp (or `cons setup`); no *central-registry* push / local-projects.
(ql:quickload "{{name}}")

(ensure-directories-exist "bin/")
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
