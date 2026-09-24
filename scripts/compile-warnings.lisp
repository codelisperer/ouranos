;;;; compile-warnings.lisp --- the gate's judgement of a child image's compile warnings (#117)
;;;;
;;;; WARNINGS-IN and +KNOWN-WARNINGS+, moved verbatim out of verify-tree.lisp so that
;;;; scripts/check-compile.lisp can apply exactly the gate's judgement to one system at a time,
;;;; rather than a second copy of it that would drift. Loaded by path by both, for the same
;;;; reason as caught-errors.lisp and fiveam-report.lisp: everything in verify-tree.lisp runs
;;;; at toplevel, so a helper defined inline can only be exercised by running the whole gate.
;;;;
;;;; Why the gate reads TEXT for this is measured on #117: an undefined-variable warning, such
;;;; as the words after an unescaped quote in a docstring, is deferred to the end of the
;;;; compilation unit ASDF wraps around a build. By then compile-file has returned, so neither
;;;; ASDF's failure flags nor a handler scoped to compile-file sees it, and only the text SBCL
;;;; prints, under `; file:', says which file it came from.

(defpackage #:ouranos-compile-warnings
  (:use #:cl)
  (:export #:warnings-in #:+known-warnings+))

(in-package #:ouranos-compile-warnings)

(defparameter +known-warnings+
  '(("undefined variable: PARENSCRIPT:*JS-TARGET-VERSION*"
     . "Parenscript's own symbol, reached through a MACROEXPANSION -- it appears in no
source file of ours. Deferred to the end of the compilation unit, so SBCL attributes it to
whichever file finished last rather than to the form that caused it, and it surfaces only
on a FULLY cold build. Harmless at run time: the symbol is external and bound once
Parenscript is loaded. Listed rather than tolerated silently, because a gate that ignores
warnings by category would have hidden the docstring bug this one exists to catch.")
    ("undefined variable: CL-POSTGRES::*UNIX-SOCKET-DIR*"
     . "An upstream cl-postgres read-conditional asymmetry, and WINDOWS-ONLY. In
cl-postgres/public.lisp the DEFPARAMETER is guarded `#+(and (or ...sbcl-available ccl
allegro) unix)`, so on Windows the variable is never defined -- but the reference to it
(the `:unix` branch of INITIATE-CONNECTION) is guarded only by the implementation half,
`#+(or allegro ...sbcl-available ccl)`, with no `unix`. So the reference compiles on
Windows SBCL while the definition does not exist. Unreachable at run time: that branch
calls `(assert-unix)` FIRST, which is `#-unix (error \"Unix sockets only available on Unix
(really)\")`, so the unbound variable is never evaluated -- and Windows has no Unix domain
sockets to connect to in the first place. Not fixable from here; it is in the dependency's
own source. Surfaced by the COLD build, not by the SBCL roll that found it -- the warm fasl
had hidden it on this platform indefinitely."))
  "Warnings the gate accepts, each with the reason it is not ours to fix.

The same doctrine as +KNOWN-EMPTY+: an exception someone MADE, not one that accumulated.
A third-party library's cold-compile warning must not red the whole tree -- but the
allowance is a recorded line with a justification, so it can be re-examined when the
dependency moves, rather than a blanket `ignore warnings from dependencies` that would
also swallow ours.")

(defun warnings-in (output)
  "The `caught WARNING:` lines SBCL printed in OUTPUT, if any.

Scanned from the child's output rather than trapped with HANDLER-BIND, because the
warning that motivated this is DEFERRED: SBCL reports an undefined variable at the end of
the compilation unit, past the point ASDF inspects compile-file's failure flag -- so
`asdf:load-system` returns cleanly and the child exits 0. That is not a corner case, it is
how an unescaped quote in a docstring emitted a warning on every cold build of hyperion
for a week while this script reported PASS.

STYLE-WARNINGs are deliberately not matched: they are advisory, they are noisy in Coalton
code we do not own, and a gate that cries wolf gets switched off."
  (let ((lines (uiop:split-string output :separator '(#\Newline)))
        (out '()))
    ;; Report the marker line AND the lines around it. SBCL prints the offending form
    ;; and the file above `caught WARNING:`, and the message itself BELOW it -- so the
    ;; marker alone says only "something warned", which is nearly useless in a gate
    ;; whose whole job is to tell you what to fix. Learned by hitting it: an SBCL bump
    ;; produced a cold-build-only warning that this function reported as
    ;; "compiled with 1 warning" and nothing more, and it did not reproduce warm.
    (loop for tail on lines
          for l = (car tail)
          when (search "caught WARNING" l)
            do (let ((context (subseq tail 0 (min 5 (length tail)))))
                 ;; Excused only if a KNOWN pattern appears in this warning's own context,
                 ;; not merely somewhere in the output -- otherwise one excused warning
                 ;; would excuse every other warning in the same build.
                 (unless (some (lambda (known)
                                 (some (lambda (cl) (search (car known) cl)) context))
                               +known-warnings+)
                   (setf out (append out context)))))
    out))
