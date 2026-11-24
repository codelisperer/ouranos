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
;;;;
;;;; A call to a function that does not exist is a STYLE-WARNING in SBCL, not a WARNING, so
;;;; WARNINGS-IN did not match it, and neither the gate nor check-compile failed on one (#1076).
;;;; On #1066 a test called `is*', which its package does not have; the test was skipped on
;;;; the machine that ran check-compile, and failed on CI. WARNINGS-IN now also returns each
;;;; undefined function whose package this tree defines. A function undefined in a
;;;; dependency's own package is not ours to fix, and on a cold build it would fail the run
;;;; for a library's code, so it is left out. The package is the only reliable sign of where
;;;; the call came from: SBCL defers an undefined function to the end of the compilation unit
;;;; and prints it after whichever file compiled last, with no `; file:' line.

(defpackage #:ouranos-compile-warnings
  (:use #:cl)
  (:export #:warnings-in #:+known-warnings+ #:tree-packages #:undefined-functions-in))

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

(defun %skip-directory-p (directory root)
  "Whether TREE-PACKAGES skips DIRECTORY: any .git, and ROOT's vendor/ and dist/, which hold
gitignored build output rather than this tree's source. A vendor/ deeper down, such as
hyperion/src/vendor/, holds source this tree generated, and is read."
  (or (equal (car (last (pathname-directory directory))) ".git")
      (member (truename directory)
              (remove nil (mapcar (lambda (name) (probe-file (merge-pathnames name root)))
                                  '("vendor/" "dist/")))
              :test #'equal)))

(defun %package-names-in (text)
  "The names of the packages TEXT defines with DEFPACKAGE or DEFINE-PACKAGE, upper-cased.
Read as text, because a file may hold forms for a platform this host cannot read."
  (let ((names '()))
    (dolist (word '("defpackage" "define-package") names)
      (loop for start = (search word text :test #'char-equal)
              then (search word text :test #'char-equal :start2 (1+ start))
            while start
            do (let* ((after (+ start (length word)))
                      (open (and (plusp start) (find (char text (1- start)) "(:"))))
                 (when (and open (< after (length text))
                            (member (char text after) '(#\Space #\Tab #\Newline #\Return)))
                   (let* ((from (position-if-not (lambda (c) (find c '(#\Space #\Tab #\Newline
                                                                       #\Return #\# #\: #\")))
                                                 text :start after))
                          (to (and from (position-if (lambda (c) (find c '(#\Space #\Tab
                                                                           #\Newline #\Return
                                                                           #\) #\")))
                                                     text :start from))))
                     (when (and from to (> to from))
                       (pushnew (string-upcase (subseq text from to)) names
                                :test #'string=)))))))))

(defun tree-packages (root)
  "The names of every package a .lisp file under ROOT defines, upper-cased, as WARNINGS-IN
compares them with the package SBCL prints for an undefined function."
  (let ((names '())
        (root (uiop:ensure-directory-pathname root)))
    (uiop:collect-sub*directories
     root
     (lambda (directory) (not (%skip-directory-p directory root)))
     (lambda (directory) (not (%skip-directory-p directory root)))
     (lambda (directory)
       (dolist (file (uiop:directory-files directory "*.lisp"))
         (dolist (name (%package-names-in (uiop:read-file-string file
                                                                 :external-format :utf-8)))
           (pushnew name names :test #'string=)))))
    names))

(defun %undefined-function-package (line)
  "The package SBCL names in LINE when LINE reads `undefined function: PKG::NAME', or
`undefined function: (COMMON-LISP:SETF PKG::NAME)' for a SETF function; NIL otherwise."
  (let ((at (search "undefined function: " line)))
    (when at
      (let* ((name (string-left-trim " (" (subseq line (+ at (length "undefined function: ")))))
             (name (if (and (> (length name) 17) (string= "COMMON-LISP:SETF " name :end2 17))
                       (subseq name 17)
                       name))
             (colon (position #\: name)))
        (when (and colon (plusp colon))
          (subseq name 0 colon))))))

(defun undefined-functions-in (output tree-packages)
  "The `undefined function:' lines in OUTPUT whose package is in TREE-PACKAGES, each with the
`caught STYLE-WARNING:' line before it (#1076)."
  (let ((lines (uiop:split-string output :separator '(#\Newline)))
        (out '()))
    (loop for (previous line) on (cons "" lines)
          for package = (and line (%undefined-function-package line))
          when (and package (member package tree-packages :test #'string=))
            do (setf out (append out (list previous line))))
    out))

(defun warnings-in (output tree-packages)
  "The `caught WARNING:` lines SBCL printed in OUTPUT, if any, and the undefined functions
whose package is in TREE-PACKAGES (see UNDEFINED-FUNCTIONS-IN and TREE-PACKAGES).

Scanned from the child's output rather than trapped with HANDLER-BIND, because the
warning that motivated this is DEFERRED: SBCL reports an undefined variable at the end of
the compilation unit, past the point ASDF inspects compile-file's failure flag -- so
`asdf:load-system` returns cleanly and the child exits 0. That is not a corner case, it is
how an unescaped quote in a docstring emitted a warning on every cold build of hyperion
for a week while this script reported PASS.

Other STYLE-WARNINGs are deliberately not matched: they are advisory, they are noisy in
Coalton code we do not own, and a gate that cries wolf gets switched off. An undefined
function is the exception (#1076): the call fails whenever it runs, and in a test that is
skipped on one machine it ran first on CI. TREE-PACKAGES is required, so that no caller can
leave that check out by omitting it."
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
    (append out (undefined-functions-in output tree-packages))))
