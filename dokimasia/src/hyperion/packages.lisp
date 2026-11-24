;;;; packages.lisp --- the package of dokimasia/hyperion (#1028, dokimasia ADR-0001).

(cl:defpackage #:dokimasia/hyperion
  (:use #:cl)
  (:local-nicknames (#:d #:dokimasia)
                    (#:cdp #:aion/cdp)
                    (#:fs #:aion/fs)
                    (#:srv #:hyperion/server)
                    (#:ports #:hyperion/test-ports)
                    (#:session #:hyperion/session)
                    (#:be #:mnemosyne/backend))
  (:documentation "A dokimasia target for a hyperion app: started on a free port with a scratch
SQLite database and seeded users, a settle check that waits for htmx, and an optional sign-in
that makes a session in the app's store (#1028). See dokimasia/README.md, \"Hyperion apps\".")
  (:export #:hyperion-target #:target-database #:current-database #:+htmx-listener+))
