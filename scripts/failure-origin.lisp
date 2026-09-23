;;;; failure-origin.lisp --- did this failure come from the TREE, or from a dependency? (#192)
;;;;
;;;; scripts/verify-tree.lisp runs every system in its own image and reports the ones that
;;;; die. Until this file it reported them all the same way:
;;;;
;;;;     FAIL    PRAXEON/WEB
;;;;     ...
;;;;     VERDICT: FAIL
;;;;       - PRAXEON/WEB failed to load in a clean image
;;;;
;;;; which is a true sentence and a misleading one. The observed instance of that line was
;;;; not praxeon/web failing at all -- it was ASDF failing to load `woo.asd`, in Quicklisp,
;;;; because a cffi toolchain fasl had not been compiled yet on a cold cache:
;;;;
;;;;     Unhandled LOAD-SYSTEM-DEFINITION-ERROR: Error while trying to load definition for
;;;;     system woo from pathname .../quicklisp/.../woo.asd: Couldn't load
;;;;     .../cffi-.../toolchain/static-link.fasl: file does not exist.
;;;;
;;;; The tree was fine. It did not reproduce -- PASS warm, PASS on a cold-cache control at
;;;; unmodified main in a detached worktree, PASS on a second cold run. The cost is not the
;;;; flake, which may never recur; the cost is that the gate pointed at praxeon/web, and
;;;; the response to a red run is to go and change the code it names.
;;;;
;;;; AGENTS.md already says a green can lie. This is the other direction, and #88 is where
;;;; it lands hardest: verifying bootstrap on a clean machine is BY DEFINITION the
;;;; cold-cache case, and its output is the thing the project would publish as "bootstrap
;;;; works on three OSes."
;;;;
;;;; SO: CLASSIFY, DO NOT EXCUSE. Nothing here downgrades a failure or makes anything pass.
;;;; A third-party origin is still FAIL, still red, still exits 1. The only thing that
;;;; changes is that the gate says WHERE the failure happened, so a reader stops looking in
;;;; the wrong file. An excuse would be the false-green family this repo keeps re-finding;
;;;; a label is not.
;;;;
;;;; Plain CL in scripts/, loaded by path, for the same reason scripts/platform-packages.lisp
;;;; is: verify-tree.lisp is a SCRIPT that does its work at toplevel, so anything defined
;;;; inside it can only be tested by running the entire gate. Split out, it is pure string
;;;; classification over captured output -- and cons/tests/failure-origin-tests.lisp checks
;;;; it against the real message, both directions.

(defpackage #:ouranos-failure-origin
  (:use #:cl)
  (:export #:definition-load-failure-p #:asd-paths #:foreign-asds #:classify
           #:report-origin))

(in-package #:ouranos-failure-origin)

(defun %normalize (s)
  "S with backslashes folded to forward slashes and downcased.

So that a path comparison means the same thing on Windows as on Unix -- the tree root
arrives as `D:\\src\\ouranos\\` and the .asd path in an ASDF message may use either
separator, and comparing them raw makes every Windows path look foreign."
  (string-downcase (substitute #\/ #\\ s)))

(defun %tokens (text)
  "TEXT split on whitespace and the quoting characters that wrap paths in Lisp output.

Splitting on #\\\" as well as whitespace is what makes `#P\"/x/y.asd\"` yield the bare path:
the reader syntax prints the pathname quoted, and a token of `#P\"/x/y.asd\"` would not
match a suffix test."
  (let ((out '())
        (cur (make-string-output-stream)))
    (flet ((flush ()
             (let ((tok (get-output-stream-string cur)))
               (when (plusp (length tok)) (push tok out)))))
      (loop for ch across text
            do (if (member ch '(#\Space #\Tab #\Newline #\Return #\" #\' #\< #\> #\Page))
                   (flush)
                   (write-char ch cur)))
      (flush))
    (nreverse out)))

(defun %suffixp (suffix s)
  (let ((ls (length s)) (lx (length suffix)))
    (and (> ls lx) (string-equal suffix (subseq s (- ls lx))))))

(defun asd-paths (text)
  "Every `.asd` path mentioned anywhere in TEXT, de-duplicated, in order of appearance.

Collected by scanning for the suffix rather than by parsing ASDF's sentence, deliberately.
The message is produced by a pretty-printer with a fill directive, so it WRAPS at an
unpredictable column on a long path -- and a parser keyed to `... for system X from
pathname Y:` would work on the developer's terminal and silently stop matching in a CI log
that is 80 columns wide. A suffix scan does not care where the line breaks fall."
  (let ((seen '()))
    (dolist (tok (%tokens text) (nreverse seen))
      (let ((clean (string-right-trim ":;,.)]}" tok)))
        (when (and (%suffixp ".asd" clean)
                   (not (member clean seen :test #'string=)))
          (push clean seen))))))

(defun foreign-asds (text root)
  "The `.asd` paths in TEXT that are NOT inside ROOT (this checkout).

ROOT is passed in rather than read from a global so this stays a pure function of its
arguments -- which is what lets the tests hand it a fabricated root and a fabricated
message and get a definite answer.

ROOT may be a pathname OR a string, and the string case is not a convenience: a Windows
root is `D:\\src\\ouranos\\`, which cannot be written as a #p literal or parsed by
NAMESTRING on a Unix host at all. Accepting the string is what lets the Windows path
behaviour be TESTED from Linux, instead of being asserted and discovered on the Windows leg."
  (let ((r (%normalize (if (stringp root) root (namestring root)))))
    (remove-if (lambda (p) (search r (%normalize p))) (asd-paths text))))

(defun definition-load-failure-p (text)
  "Did the child die while loading a system DEFINITION (an .asd), as opposed to while
compiling code?

Both spellings are matched because they come from different layers: the condition's TYPE
NAME is what SBCL prints in `Unhandled ...`, and the sentence is what ASDF's report method
produces. A log may carry either depending on how deep the failure was wrapped."
  (or (search "LOAD-SYSTEM-DEFINITION-ERROR" text)
      (search "Error while trying to load definition for system" text)
      nil))

(defun classify (text root)
  "Where did the failure in TEXT come from? Returns two values:

  :TREE       and NIL   -- ordinary: something in this checkout failed. Report as before.
  :DEPENDENCY and PATHS -- the child died loading a system definition from OUTSIDE ROOT.
                           PATHS names the foreign .asd files, most relevant first.

Deliberately CONSERVATIVE. It takes BOTH a definition-load failure AND an .asd outside the
tree to earn :DEPENDENCY. A missing dependency that surfaces some other way -- `Component
\"log4cl\" not found`, the failure that motivated FAILURE-EXCERPT -- stays :TREE, because
the tree naming a dependency it does not have IS the tree's problem and was a real finding.
Widening this to \"anything that smells third-party\" would start excusing exactly those.

Note what the two values do NOT include: any notion of severity. Both are failures."
  (let ((foreign (and (definition-load-failure-p text) (foreign-asds text root))))
    (if foreign
        (values :dependency foreign)
        (values :tree nil))))

(defun report-origin (text system root &optional (stream *standard-output*))
  "Print where a dead child's failure came from, and return the sentence for the summary --
or NIL when the origin is the tree, so the caller keeps the wording it already had.

Lives HERE rather than in verify-tree.lisp so the text the gate actually prints can be
asserted. A classifier that is unit-tested while the message beside it is not leaves the
part a human reads unverified, which is the half that matters: the whole defect is that a
reader was sent to the wrong file.

CLASSIFYING, NOT EXCUSING. A dependency origin is still a failure, still red, still exits 1.
Only the wording changes."
  (multiple-value-bind (origin paths) (classify text root)
    (when (eq origin :dependency)
      (format stream "          ^^ this died inside a THIRD-PARTY system definition, NOT in tree code:~%")
      (dolist (p paths) (format stream "             ~a~%" p))
      (format stream "             A dependency outside this checkout failed to load. Look at the~%")
      (format stream "             dependency cache first -- a cold ~~/.cache/common-lisp is the~%")
      (format stream "             known cause -- rather than at ~a, which may be blameless. See #192.~%" system)
      (format nil "~a failed -- inside a THIRD-PARTY .asd (~a), NOT tree code; see #192"
              system (first paths)))))
