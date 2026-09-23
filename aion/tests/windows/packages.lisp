;;;; packages.lisp --- aion/windows test-suite package.
;;;;
;;;; WINDOWS-ONLY, and the gate knows it: scripts/platform-packages.lisp (#182) declares
;;;; aion/windows as owned by :windows, so a macOS or Linux run reports `n/a' and never
;;;; reaches this file, while a Windows run that cannot load it FAILS. That is what makes
;;;; the absence of these checks on Windows a defect rather than a skip.

(cl:defpackage #:aion/windows/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:w #:aion/windows)
                    (#:ffi #:aion/windows/ffi))
  (:documentation "aion/windows test suite.")
  (:export #:run-tests))

(in-package #:aion/windows/tests)

(def-suite all :description "All aion/windows tests.")
(in-suite all)

(defun run-tests ()
  "Run the aion/windows test suite; return T when every test passes."
  (fiveam:run! 'all))
