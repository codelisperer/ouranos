;;;; build-{{name}}.lisp --- dump a standalone bin/{{name}} executable.
;;;;
;;;; Run OUT-OF-IMAGE (save-lisp-and-die exits the process); `cons bin` does this
;;;; via a :sh subprocess sbcl -- see cons.lisp. The resulting binary runs
;;;; {{name}}:main and needs no SBCL/Quicklisp installed to run. It serves on libuv, which this
;;;; script copies beside it with its licence under bin/LICENSES/ (#513): copy bin/ as a whole.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
;; First, so that a source file rewritten in the same second as its last compile is compiled
;; again, rather than its previous fasl being loaded into the binary (#573).
(asdf:load-system "cons/fasl-dates")
;; Discovery comes from the ASDF source-registry drop-in written by the repo-root
;; bootstrap.lisp (or `cons setup`); no *central-registry* push / local-projects.
(ql:quickload "{{name}}")

(ensure-directories-exist "bin/")
;; The native libraries the Ouranos tree builds and the app may load lazily -- libuv, for a
;; server on :uv, mbedTLS, for TLS, and libgit2, for aion/libgit -- are copied beside
;; bin/{{name}}, where the binary looks for them first, with their licences under bin/LICENSES/,
;; and the binary is set not to look in the tree it was built from (#513). Without that, a
;; binary that loads one runs on this machine, which has the tree, and fails on any other.
;; libgit2's licence, the GPL version 2 with a linking exception, requires its source to be
;; available wherever the binary goes, so its pinned source tarball is copied under
;; bin/SOURCES/ as well (ADR-0013, #524). Distribute bin/ as a whole.
;; tree-natives.lisp is the code a desktop bundle is built with; for an app that loads none of
;; these libraries it copies nothing. It stops the build with exit code 3, and says why, if the
;; app loads one of them from somewhere other than the tree's vendor/ directory, if this machine
;; has no built copy of one, or if libgit2's tarball is missing or does not match libgit2.pin.
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
