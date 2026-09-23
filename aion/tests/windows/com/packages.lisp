;;;; packages.lisp --- aion/windows/com test-suite package.

(cl:defpackage #:aion/windows/com/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:com #:aion/windows/com)
                    (#:ffi #:aion/windows/com/ffi)
                    (#:wffi #:aion/windows/ffi)
                    (#:w #:aion/windows))
  (:documentation "aion/windows/com test suite.")
  (:export #:run-tests))

(in-package #:aion/windows/com/tests)

(def-suite all :description "All aion/windows/com tests.")
(in-suite all)

(defun run-tests ()
  "Run the aion/windows/com test suite; return T when every test passes."
  (fiveam:run! 'all))
