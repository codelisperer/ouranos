;;;; build-contacts.lisp --- dump a standalone bin/contacts executable.
;;;;
;;;; Run OUT-OF-IMAGE (save-lisp-and-die exits the process); `cons bin` does this
;;;; via a :sh subprocess sbcl -- see cons.lisp. The resulting binary runs
;;;; mnemosyne/examples/contacts:main and needs no SBCL/Quicklisp installed to run.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
;; Discovery comes from the ASDF source-registry drop-in written by the repo-root
;; bootstrap.lisp (or `cons setup`); no *central-registry* push / local-projects.
(ql:quickload "contacts")

(ensure-directories-exist "bin/")
;; Add :compression t if this SBCL was built with core compression (smaller binary).
(sb-ext:save-lisp-and-die
 "bin/contacts"
 :executable t
 :toplevel #'mnemosyne/examples/contacts:main)
