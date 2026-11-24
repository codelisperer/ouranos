;;;; tests/packages.lisp --- the package of dokimasia's tests (#1028).

(defpackage #:dokimasia/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:d #:dokimasia)
                    (#:core #:dokimasia/core)
                    (#:cdp #:aion/cdp)
                    (#:secret #:aion/secret)
                    (#:jzon #:com.inuoe.jzon))
  (:export #:run-tests))

(in-package #:dokimasia/tests)

(def-suite dokimasia :description "dokimasia: the verdict, cases and rows as data, the report, and runs in a real headless browser.")

(defun run-tests ()
  (run! 'dokimasia))

(defmacro with-env ((&rest names-and-values) &body body)
  "Run BODY with each environment variable set to its value (\"\" for unset), restoring them."
  (let ((saved (gensym)))
    `(let ((,saved (list ,@(loop for (name) on names-and-values by #'cddr
                                 collect `(cons ,name (or (uiop:getenv ,name) ""))))))
       (unwind-protect
            (progn ,@(loop for (name value) on names-and-values by #'cddr
                           collect `(setf (uiop:getenv ,name) ,value))
                   ,@body)
         (loop for (name . value) in ,saved do (setf (uiop:getenv name) value))))))

(defun temporary-directory (prefix)
  "A new, empty directory under the system's temporary directory."
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "~A-~36R" prefix (random (expt 36 8) (make-random-state t)))
                               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    dir))

(defmacro with-temporary-directory ((var prefix) &body body)
  `(let ((,var (temporary-directory ,prefix)))
     (unwind-protect (progn ,@body)
       (uiop:delete-directory-tree ,var :validate t :if-does-not-exist :ignore))))
