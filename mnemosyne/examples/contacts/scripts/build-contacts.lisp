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
;; Through scripts/dump-image.lisp, not `save-lisp-and-die' directly, so the binary takes its
;; temporary directory, fasl cache and ASDF configuration from the machine it runs on (#107,
;; #287). Pass :compression t to DUMP-EXECUTABLE if this SBCL was built with core compression.
(load (merge-pathnames "../../../../scripts/dump-image.lisp"
                       (uiop:pathname-directory-pathname (or *load-truename* *load-pathname*))))
(ouranos-dump:dump-executable "bin/contacts" 'mnemosyne/examples/contacts:main)
