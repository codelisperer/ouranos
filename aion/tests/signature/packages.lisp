;;;; packages.lisp --- aion/signature test-suite package.

(cl:defpackage #:aion/signature/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:sig #:aion/signature))
  (:documentation "aion/signature test suite.")
  (:export #:run-tests))

(in-package #:aion/signature/tests)

(defun run-tests ()
  "Run the aion/signature test suite; return T when every test passes."
  (fiveam:run! 'all))
