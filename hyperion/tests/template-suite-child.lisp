;;;; template-suite-child.lisp --- run in a fresh sbcl by server-uv-template-tests.lisp (#711).
;;;;
;;;; Not part of any system: the test starts `sbcl --load' on this file, after --eval forms
;;;; that set CL-USER::*PROJECT-ROOT* and CL-USER::*PROJECT-NAME*. It loads the scaffolded
;;;; project's test system, runs the project's own FiveAM suite, and prints how many checks
;;;; passed, failed and were skipped as SUITE-... lines, followed by FiveAM's explanation of
;;;; any failure.
;;;;
;;;; When TEMPLATE_DROP_NEW_TABLES names tables (comma-separated), the child asks the database at
;;;; DATABASE_URL which of them exist before the suite runs, and drops the others afterwards: the
;;;; Postgres project creates its stores' tables under their default names, and the database the
;;;; suite is given may be a developer's own.

(in-package #:cl-user)

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(asdf:initialize-source-registry
 `(:source-registry (:tree ,*project-root*) :inherit-configuration))
(let ((*standard-output* (make-broadcast-stream)))
  (funcall (intern "QUICKLOAD" "QL") (format nil "~A/tests" *project-name*)))

(defun child-symbol (name package) (find-symbol name package))

(defun call-with-database-connection (function)
  "Call FUNCTION with a mnemosyne connection to DATABASE_URL, and disconnect afterwards."
  (let ((c (funcall (child-symbol "CONNECT" "MNEMOSYNE/CONN")
                    (funcall (child-symbol "BACKEND-FROM-URL" "MNEMOSYNE/URL")
                             (uiop:getenv "DATABASE_URL")))))
    (unwind-protect (funcall function c)
      (funcall (child-symbol "DISCONNECT" "MNEMOSYNE/CONN") c))))

(defun absent-tables (names)
  "The tables in NAMES that do not exist in the database at DATABASE_URL."
  (call-with-database-connection
   (lambda (c)
     (remove-if (lambda (name)
                  (getf (first (funcall (child-symbol "QUERY" "MNEMOSYNE/CONN") c
                                        "SELECT to_regclass(?) IS NOT NULL AS present" name))
                        :present))
                names))))

(defun drop-tables (names)
  (when names
    (call-with-database-connection
     (lambda (c)
       (dolist (name names)
         (funcall (child-symbol "EXEC" "MNEMOSYNE/CONN") c
                  (format nil "DROP TABLE IF EXISTS ~A" name)))))))

(defparameter *new-tables*
  (let ((names (uiop:getenv "TEMPLATE_DROP_NEW_TABLES")))
    (and names (plusp (length names))
         (absent-tables (uiop:split-string names :separator ",")))))

(let* ((suite (find-symbol (string-upcase *project-name*)
                           (format nil "~:@(~A~)/TESTS" *project-name*)))
       (results (funcall (find-symbol "RUN" "FIVEAM") suite)))
  (flet ((count-of (type)
           (count-if (lambda (r) (typep r (find-symbol type "FIVEAM"))) results)))
    (format t "~&SUITE-CHECKS ~D~%SUITE-PASSED ~D~%SUITE-FAILED ~D~%SUITE-SKIPPED ~D~%"
            (length results) (count-of "TEST-PASSED")
            (count-of "TEST-FAILURE") ; UNEXPECTED-TEST-FAILURE, an error, is a subclass
            (count-of "TEST-SKIPPED")))
  (funcall (find-symbol "EXPLAIN!" "FIVEAM") results)
  (finish-output))

(drop-tables *new-tables*)

(uiop:quit 0)
