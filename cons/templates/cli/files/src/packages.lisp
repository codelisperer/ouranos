;;;; packages.lisp --- {{name}} package definitions.
;;;;
;;;; Package-per-module; :local-nicknames over long prefixes.

(cl:defpackage #:{{name}}
  (:use #:cl)
  (:local-nicknames (#:env #:cons/env))
  (:documentation "{{name}}.")
  (:export #:version #:main))
