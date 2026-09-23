;;;; packages.lisp --- {{name}} package definitions.
;;;;
;;;; A minimal Hyperion web app. Package-per-module; :local-nicknames over prefixes.

(cl:defpackage #:{{name}}
  (:use #:cl)
  (:local-nicknames (#:env #:cons/env)
                    (#:srv #:hyperion/server))
  (:documentation "{{name}} -- a minimal Hyperion web app.")
  (:export #:version #:app #:start #:stop #:serve #:main))
