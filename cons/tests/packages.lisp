;;;; packages.lisp --- cons test-suite package.

(cl:defpackage #:cons/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:tempdir #:cons/tempdir))
  (:documentation "cons test suite.")
  (:export #:run-tests))

(in-package #:cons/tests)

(def-suite all :description "All cons tests.")
(in-suite all)

(defun run-tests ()
  "Run the cons test suite; return T when every test passes."
  (fiveam:run! 'all))

;;; --- writing the environment, without a read-time dependency on sb-posix ---
;;;
;;; SBCL's Windows sb-posix is thinner than the POSIX one. A literal `sb-posix:setenv'
;;; is resolved by the READER, so on a build lacking that symbol the file dies with a
;;; package error and takes the whole test system with it — and the gate now runs every
;;; system in its own image and fails on any warning, so that is a hard failure rather
;;; than something you notice and route around. Look the symbol up at RUNTIME instead:
;;; the blast radius becomes the tests that need it, which can then say so.
;;;
;;; The tested code reads `uiop:getenv', i.e. the real C environment, so a Lisp-side
;;; shim would not do — there is no fallback here, only an honest report of absence.
;;; (`(setf uiop:getenv)' is not one either: it expands to the same sb-posix call.)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (ignore-errors (require :sb-posix)))

(defun %env-fn (name)
  "The SB-POSIX function NAME, or NIL when this build has no such thing."
  (let* ((package (find-package "SB-POSIX"))
         (symbol (and package (find-symbol name package))))
    (and symbol (fboundp symbol) symbol)))

(defun env-writable-p ()
  "True when this build can mutate the C environment that `uiop:getenv' reads."
  (and (%env-fn "SETENV") (%env-fn "UNSETENV") t))

(defun set-env (name value)
  (funcall (%env-fn "SETENV") name value 1))

(defun unset-env (name)
  (funcall (%env-fn "UNSETENV") name))
