;;;; caught-errors.lisp --- finding each `caught ERROR' in a child image's output (#263)
;;;;
;;;; SBCL prints `caught ERROR' for a form it cannot compile and turns into a run-time error
;;;; instead, such as a DECLARE where no declaration is allowed. For an ordinary source file
;;;; that makes compile-file report failure, and ASDF stops the load. For a FiveAM test body it
;;;; does not. FiveAM passes the body to REGISTER-TEST as quoted data and EVALs it when the
;;;; fasl LOADS, so compile-file never compiles it and reports no failure, and the only trace
;;;; is the text SBCL prints during the load. So for test bodies, scanning the output is the
;;;; only compile check there is.
;;;;
;;;; verify-tree.lisp scanned for `caught WARNING' only, and passed a test in
;;;; aion/windows/com/tests whose body could not compile. Measured before this became a
;;;; failure, on every CI leg of run 36008761253: that one occurrence on Windows, none on
;;;; Linux, macOS or release mode.
;;;;
;;;; Split out of verify-tree.lisp and loaded by path for the same reason as
;;;; fiveam-report.lisp: everything in that script runs at toplevel, so a helper defined inline
;;;; can only be exercised by running the whole gate. See cons/tests/caught-errors-tests.lisp.

(defpackage #:ouranos-caught-errors
  (:use #:cl)
  (:export #:errors-in))

(in-package #:ouranos-caught-errors)

(defun errors-in (output)
  "Each `caught ERROR' SBCL printed in OUTPUT, as a list of lines: the four above the marker
\(which name the form, and for a test body the test) and the three below it (the message).
NIL when there are none."
  (let ((lines (coerce (uiop:split-string output :separator '(#\Newline)) 'vector))
        (out '()))
    (loop for i from 0 below (length lines)
          when (search "caught ERROR" (aref lines i))
            do (push (loop for j from (max 0 (- i 4)) to (min (1- (length lines)) (+ i 3))
                           collect (string-right-trim '(#\Return) (aref lines j)))
                     out))
    (nreverse out)))
