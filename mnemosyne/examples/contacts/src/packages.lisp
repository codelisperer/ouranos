;;;; packages.lisp --- contacts package definitions.
;;;;
;;;; Package-per-module; :local-nicknames over long prefixes. This example consumes the
;;;; mnemosyne data layer -- backend/conn/migrate/query/schema/id -- to show the migration
;;;; lifecycle end to end in a small console app.

(cl:defpackage #:mnemosyne/examples/contacts
  (:use #:cl)
  (:local-nicknames (#:be      #:mnemosyne/backend)
                    (#:conn    #:mnemosyne/conn)
                    (#:migrate #:mnemosyne/migrate)
                    (#:query   #:mnemosyne/query)
                    (#:schema  #:mnemosyne/schema)
                    (#:id      #:mnemosyne/id)
                    (#:cs      #:mnemosyne/changeset))
  (:documentation
   "A console contacts app showcasing mnemosyne migrations + query: migrate / rollback /
    status, and add / list contacts. Console input reaches the table through the changeset
    path the root AGENTS.md mandates -- cast, then validate, then insert (#129). `cons run`
    starts it.")
  (:export #:version #:main #:run-console))
