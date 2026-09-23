;;;; packages.lisp --- aion/platform test-suite package.

(cl:defpackage #:aion/platform/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:plat #:aion/platform))
  (:documentation "aion/platform test suite.")
  (:export #:run-tests))

(in-package #:aion/platform/tests)

(defun run-tests ()
  "Run the aion/platform test suite; return T when every test passes."
  (fiveam:run! 'all))
