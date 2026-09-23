;;;; heap-guard.lisp --- the heap a dumped image is born with, decided once (pre-publication issue 88).
;;;;
;;;; SAVE-LISP-AND-DIE HAS NO HEAP PARAMETER. A dumped image inherits the heap of the
;;;; process that dumped it, and `:save-runtime-options t' -- which every executable in this
;;;; tree uses, because without it the binary parses SBCL's runtime flags instead of passing
;;;; them to the program -- then freezes that choice. `bin/cons --dynamic-space-size 4096' is
;;;; read as a `cons' argument, not as a resize. The heap an image is born with is the heap
;;;; it dies with.
;;;;
;;;; So the heap of every artifact this tree produces is decided by how the machine that
;;;; built it happened to invoke SBCL, and NOTHING ABOUT THE ARTIFACT ANNOUNCES IT.
;;;; Bootstrapping without the documented flag produced a working bin/cons with a quarter of
;;;; the intended headroom; the only symptom was a memory ceiling arriving much later, far
;;;; from the cause. Confirm any artifact with scripts/baked-heap.lisp.
;;;;
;;;; SHARED BY TWO CALLERS, which is the whole reason this is a file rather than a paragraph
;;;; repeated twice. 4096 was already written three times in bootstrap.lisp before pre-publication PR 195 --
;;;; twice as a literal passed to children, once implicitly as a flag the reader was told to
;;;; type -- and the only copy anyone could get wrong was the one nobody checked. Adding
;;;; build-desktop-app.lisp as a second caller would have recreated exactly that.
;;;;
;;;; PLAIN CL, NO DEPENDENCIES, NOT PART OF ANY ASDF SYSTEM -- the same constraint
;;;; scripts/platform-packages.lisp is under, and for the same reason: bootstrap.lisp
;;;; consumes it before `cons' exists, because bootstrap is what builds cons. `load' is the
;;;; only mechanism available to both callers.

(defpackage #:ouranos-heap
  (:use #:common-lisp)
  (:export #:*wanted-heap-mb* #:current-heap-mb #:ensure-heap))

(in-package #:ouranos-heap)

(defparameter *wanted-heap-mb* 4096
  "The heap every image this tree dumps should be born with, and the ONE place it is written.

Also the value passed to every child process the build scripts spawn, so the number a reader
is told to type and the number the code uses cannot drift apart.")

(defun current-heap-mb ()
  (round (sb-ext:dynamic-space-size) (* 1024 1024)))

(defun ensure-heap (script &key (reexec-var "OURANOS_HEAP_REEXEC")
                                (keep-var "OURANOS_KEEP_HEAP")
                                (what "the dumped image"))
  "Make sure this process has *WANTED-HEAP-MB*, re-executing SCRIPT if it does not.

Returns normally when the heap is already big enough, when the caller opted out, or when a
re-exec is not possible. Otherwise it does not return: the child's exit code becomes ours.

RE-EXEC RATHER THAN WARN, and the arms were run before that was chosen. A warning is honest
and still hands you the wrong artifact if you miss it during a multi-minute compile. The
failure being defended against is a COPIED COMMAND THAT LOST A FLAG -- from a README, a CI
file, a colleague's notes -- so the fix has to work for someone who never reads this file.

The precedent is already here: build-desktop-app.lisp re-execs itself under a patched
runtime on macOS, guarded by an environment variable so it cannot loop. Same shape.

KEEP-VAR is read with GETENVP, not GETENV. GETENV returns \"\" for a name exported with an
empty value and \"\" is true in Lisp, so a bare GETENV escape hatch is one a CI expression can
trip by accident -- which is the pre-publication PR 178 finding, and precisely the accident an escape hatch
must not have."
  (when (>= (current-heap-mb) *wanted-heap-mb*)
    (return-from ensure-heap :already-big-enough))
  (when (uiop:getenvp keep-var)
    ;; Deliberate small heap. Said out loud, because the consequence is invisible in the
    ;; artifact and permanent -- someone reading a log later should be able to see the choice.
    (format t "~&heap: WARNING -- ~D MB, not ~D. ~A will inherit ~D MB and cannot be resized afterwards (~A is set).~%"
            (current-heap-mb) *wanted-heap-mb* what (current-heap-mb) keep-var)
    (finish-output)
    (return-from ensure-heap :opted-out))
  ;; Already re-exec'd and STILL short: the runtime refused the size we asked for. Say so
  ;; rather than looping, which would be an infinite build that looks like a hang.
  (when (uiop:getenv reexec-var)
    (format t "~&heap: re-exec did not raise the heap (still ~D MB, wanted ~D). Continuing.~%"
            (current-heap-mb) *wanted-heap-mb*)
    (finish-output)
    (return-from ensure-heap :reexec-ineffective))
  (unless script
    (return-from ensure-heap :no-script))
  (format t "~&heap: this SBCL has a ~D MB heap; ~A would inherit it permanently.~%"
          (current-heap-mb) what)
  (format t "heap: restarting with --dynamic-space-size ~D. (~A=1 to keep this heap.)~%"
          *wanted-heap-mb* keep-var)
  (finish-output)
  (let ((code (nth-value 2
               (uiop:run-program
                (append (list (namestring sb-ext:*runtime-pathname*)
                              "--dynamic-space-size" (princ-to-string *wanted-heap-mb*)
                              "--script" (namestring script))
                        (rest sb-ext:*posix-argv*))
                :environment (cons (concatenate 'string reexec-var "=1")
                                   (remove-if (lambda (e)
                                                (uiop:string-prefix-p
                                                 (concatenate 'string reexec-var "=") e))
                                              (sb-ext:posix-environ)))
                :output :interactive :error-output :interactive :input :interactive
                :ignore-error-status t))))
    (uiop:quit (or code 0))))
