;;;; packages.lisp --- aion/windows/registry tests.

(cl:defpackage #:aion/windows/registry/tests
  (:use #:common-lisp #:fiveam)
  (:local-nicknames (#:reg #:aion/windows/registry))
  (:export #:run-tests #:registry))

(cl:in-package #:aion/windows/registry/tests)

(def-suite registry :description "Reading a registry value in a named bitness view.")

(defun run-tests ()
  (let ((results (run 'registry)))
    (explain! results)
    (unless (results-status results)
      (error "aion/windows/registry tests failed"))))
