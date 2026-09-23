;;;; packages.lisp --- {{name}} package definitions.
;;;;
;;;; Package-per-module; :local-nicknames over long prefixes.

(cl:defpackage #:{{name}}
  (:use #:cl)
  (:documentation "{{name}}.")
  (:export #:version))
