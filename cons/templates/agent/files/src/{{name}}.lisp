;;;; {{name}}.lisp --- {{name}} entry.

(cl:in-package #:{{name}})

(defparameter +version+ "0.0.0"
  "{{name}} version.")

(defun version ()
  "Return the {{name}} version string."
  +version+)


(defun main ()
  "Executable entry point (dumped to ./bin/{{name}} by `cons bin`)."
  ;; FIRST, before anything reads the environment. A .env loaded lazily -- wherever the
  ;; first consumer happens to sit -- is a .env that was not loaded for whatever ran
  ;; before it, and that failure blames the library rather than this ordering.
  (env:load-project-env :{{name}})
  (format t "{{name}} ~A~%" (version))
  (uiop:quit 0))
