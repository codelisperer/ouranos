;;;; {{name}}.lisp --- {{name}} entry.

(cl:in-package #:{{name}})

(defparameter +version+ "0.0.0"
  "{{name}} version.")

(defun version ()
  "Return the {{name}} version string."
  +version+)
