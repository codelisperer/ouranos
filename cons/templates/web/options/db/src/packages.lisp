;;;; packages.lisp --- {{name}} package definitions.
;;;;
;;;; A minimal Hyperion web app. Package-per-module; :local-nicknames over prefixes.

(cl:defpackage #:{{name}}
  (:use #:cl)
  (:local-nicknames (#:env #:cons/env)
                    (#:log #:aion/log)
                    (#:srv #:hyperion/server)
                    (#:conn #:mnemosyne/conn)
                    (#:url #:mnemosyne/url)
                    (#:session #:hyperion/session)
                    (#:session-db #:hyperion/session-db)
                    (#:auth #:hyperion/auth-db)
                    (#:dbc #:hyperion/db-connection))
  (:documentation "{{name}} -- a minimal Hyperion web app.")
  (:export #:version #:app #:start #:stop #:serve #:main
           #:*db* #:*pool* #:*sessions* #:*users* #:database-url))
