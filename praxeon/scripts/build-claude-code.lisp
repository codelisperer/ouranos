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
;;;; The executable needs no SBCL or Quicklisp to run. The hook's `claude' backend needs the
;;;; `claude' CLI on PATH; the `praxeon' backend needs a provider configured in the
;;;; environment, as praxeon's other model calls do.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
;; Found through the ASDF source-registry drop-in bootstrap.lisp writes, or CL_SOURCE_REGISTRY.
(ql:quickload :praxeon/claude-code :silent t)

(ensure-directories-exist "bin/")
(sb-ext:save-lisp-and-die
 "bin/praxeon-claude-code"
 :executable t
 :toplevel #'praxeon/claude-code:main
 :save-runtime-options t)          ; so the runtime passes --help and every other argument to MAIN
