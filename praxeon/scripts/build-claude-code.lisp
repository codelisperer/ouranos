;;;; build-claude-code.lisp --- save the praxeon-claude-code executable to bin/praxeon-claude-code (#452).
;;;;
;;;; Run from the repository root:
;;;;   sbcl --non-interactive --load praxeon/scripts/build-claude-code.lisp
;;;;
;;;; A SAVED IMAGE, NOT A SCRIPT, because Claude Code starts the hook once per tool call it
;;;; matches, and loading praxeon's systems on every start takes seconds. The image is saved
;;;; UNCOMPRESSED: a compressed core is decompressed at every start, which costs the time the
;;;; image is there to save.
;;;;
;;;; On Linux and macOS the image holds cl+ssl, through praxeon's HTTP client, and opens OpenSSL
;;;; from the path it was built against when it starts, so it runs only where that library is.
;;;;
;;;; The executable needs no SBCL or Quicklisp to run, but see OpenSSL above. The hook's
;;;; `claude' backend needs the `claude' CLI on PATH; the `praxeon' backend needs a provider
;;;; configured in the environment, as praxeon's other model calls do.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
;; Found through the ASDF source-registry drop-in bootstrap.lisp writes, or CL_SOURCE_REGISTRY.
(ql:quickload :praxeon/claude-code :silent t)

;; THROUGH scripts/dump-image.lisp, not save-lisp-and-die directly (#107, #287). The hook writes
;; to the user's cache directory and a temporary directory, and a bare dump froze both at the
;; build machine's values. DUMP-EXECUTABLE runs UIOP's dump and restore hooks and keeps
;; :save-runtime-options t, so the runtime passes --help and every other argument to MAIN.
(load "scripts/dump-image.lisp")
(ensure-directories-exist "bin/")
(ouranos-dump:dump-executable "bin/praxeon-claude-code" 'praxeon/claude-code:main)
