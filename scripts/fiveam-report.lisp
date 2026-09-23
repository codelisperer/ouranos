;;;; fiveam-report.lisp --- reading FiveAM's own report, without losing half of it (#448)
;;;;
;;;; scripts/verify-tree.lisp runs each suite in its own child image and parses the text that
;;;; comes back, because that text is the only artefact that survives the child. What it
;;;; parsed until this file was "the lines under the header, while they are not blank" --
;;;; and FiveAM's DEFAULT reason for an `is' check given no reason string begins with a
;;;; blank line:
;;;;
;;;;     "~2&~S~2% evaluated to ~2&~S~2% which is not ~2&~S~2% to ~2&~S~2%"
;;;;      ^^^ fresh line, then one blank
;;;;
;;;; So a failing `(is (= 200 status))' -- the ordinary form, used all over this tree --
;;;; printed NOTHING under the gate, and took every failure after it in that suite with it.
;;;;
;;;; WHAT THAT COST, MEASURED (#446). A Windows run reported:
;;;;
;;;;     FAIL    KLIO/TESTS              167 checks, some failing
;;;;             HIGHLIGHTING-HAPPENS-AT-LOAD-... : Unexpected Error: ...
;;;;             THE-LOOK-BELONGS-TO-THE-SITE ... :
;;;;
;;;; and stopped. Twelve tests were failing, not two. The second block is empty because its
;;;; first failing check was a bare `is', and the ten behind it were never printed. Two
;;;; sessions read that report for hours as "two failures". Nothing in the output says it is
;;;; a prefix: a truncated report and a complete one have the same shape.
;;;;
;;;; THE FIX IS TO READ THE STRUCTURE FIVEAM ACTUALLY PRINTS. Failure entries are delimited
;;;; by rules of dashes (src/explain.lisp), one before and one after each entry, so the block
;;;; ends at the blank line that follows a closing rule rather than at the first blank line
;;;; anywhere. Blank lines INSIDE an entry are content and are kept.
;;;;
;;;; Split out of verify-tree.lisp and loaded by path for the same reason as
;;;; failure-origin.lisp: everything in that script runs at toplevel, so a helper defined
;;;; inline can only be exercised by running the whole gate -- which is how this survived
;;;; being written, reviewed and relied on. See cons/tests/fiveam-report-tests.lisp.

(defpackage #:ouranos-fiveam-report
  (:use #:cl)
  (:export #:failure-details #:skip-reasons #:rule-line-p))

(in-package #:ouranos-fiveam-report)

(defun rule-line-p (line)
  "True when LINE is one of FiveAM's `--------' entry rules and nothing else.

EIGHT DASHES RATHER THAN THIRTY-TWO. FiveAM prints thirty-two, but pinning the count would
make this parser fail silently -- back to reporting a prefix -- if that string ever changed
width. Requiring dashes and only dashes is the property; the exact width is not."
  (let ((trimmed (string-trim '(#\Space #\Tab #\Return) line)))
    (and (>= (length trimmed) 8)
         (every (lambda (c) (char= c #\-)) trimmed))))

(defun %lines-after (output header)
  "The lines of OUTPUT following the line containing HEADER, or NIL when it is absent."
  (let ((at (search header output)))
    (when at
      (rest (uiop:split-string (subseq output at) :separator '(#\Newline))))))

(defun %clean (line)
  (string-trim '(#\Space #\Tab #\Return) line))

(defun failure-details (output)
  "WHICH checks failed, not merely that some did: every line of FiveAM's `Failure Details:'
block, entry rules included, interior blank lines preserved.

READ TO THE STRUCTURE, NOT TO THE FIRST BLANK LINE. Each entry is wrapped in a rule, so a
blank line inside one is part of a reason and a blank line outside one is the end of the
block. That distinction is the entire content of #448: without it, the first failing check
written without a reason string hides itself and everything after it.

STOPS ON ANYTHING UNEXPECTED rather than reading on. A non-blank line outside an entry is not
a shape this knows, and consuming it would put arbitrary output into a failure report."
  (let ((lines (%lines-after output "Failure Details:"))
        (collected '())
        (inside nil)
        (seen nil))
    (dolist (line lines (nreverse collected))
      (let ((trimmed (%clean line)))
        (cond
          ((rule-line-p line)
           (setf inside (not inside) seen t)
           (push trimmed collected))
          (inside (push trimmed collected))
          ((zerop (length trimmed))
           ;; The blank line FiveAM prints after the last entry. Before the first rule there
           ;; is nothing to end, so a stray blank there is not the terminator.
           (when seen (return (nreverse collected))))
          (t (return (nreverse collected))))))))

(defun skip-reasons (output)
  "The reasons under FiveAM's `Skip Details:' block, so the gate can say WHAT did not run
rather than only how much.

TERMINATES ON A BLANK LINE, and that is correct here rather than an oversight carried over.
FiveAM prints no rules around skip entries, so there is no structure to read to -- and there
is nothing to read past: a skip reason is the string the author passed to `skip', never a
generated one, so it does not begin with the blank line that `is' emits. A skip reason
containing a blank line of its own would still truncate, which is why they are written on one
line; if that ever stops being true this needs the same treatment as the block above."
  (let ((lines (%lines-after output "Skip Details:"))
        (collected '()))
    (dolist (line lines (nreverse collected))
      (let ((trimmed (%clean line)))
        (if (zerop (length trimmed))
            (return (nreverse collected))
            (push trimmed collected))))))
