;;;; packages.lisp --- Hyperion test-suite package.
;;;;
;;;; One test package, FiveAM-based. Per-module suites hang off the root `hyperion`
;;;; suite (see suite.lisp); each src module gets a `*-tests.lisp` file. Pure logic
;;;; (i18n resolution, the typed HTMX renderers, output style, Markdown) is
;;;; deterministic and unit-tested here; IO-bound paths get integration coverage as
;;;; they land.

(cl:defpackage #:hyperion/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:srv     #:hyperion/server)
                    (#:ports   #:hyperion/test-ports)
                    (#:plural  #:hyperion/plural)
                    (#:i18n    #:hyperion/i18n)
                    (#:rt      #:hyperion/router)
                    (#:path    #:hyperion/path)
                    (#:out     #:hyperion/output)
                    (#:md      #:hyperion/markdown)
                    (#:html    #:hyperion/html)
                    (#:http    #:hyperion/http)
                    (#:session #:hyperion/session)
                    (#:csrf    #:hyperion/csrf)
                    (#:spin    #:spinneret)
                    (#:srv     #:hyperion/server)
                    (#:static  #:hyperion/static)
                    (#:channel #:hyperion/channel)
                    (#:feed #:hyperion/feed)
                    (#:sse  #:hyperion/sse)
                    (#:bt      #:bordeaux-threads)
                    (#:imp     #:hyperion/import))
  (:export #:run-tests #:hyperion))
