;;;; klio.asd --- system definition for klio.

(defsystem "klio"
  :description "A git-backed content engine: markdown in version control, rendered live by hyperion."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  ;; No HTTP server here. Hyperion declares none (pre-publication issue 139) and neither does klio -- the SITE
  ;; that instantiates klio picks its backend, and ADR-0017 makes that :uv. A library that
  ;; pulled in clack-handler-hunchentoot would choose for every consumer, and choose the
  ;; backend ADR-0011 called a stop-gap.
  :depends-on ("hyperion"
               "spinneret"
               "aion/log"        ; watch.lisp logs each reload and what refused it (#353)
               "com.inuoe.jzon") ; listing.lisp writes the search index as JSON (#353)
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "klio")
                             (:file "visibility")    ; request-time scheduling
                             (:file "dates")         ; ISO 8601 in, RFC 822 and 3339 out (#353, #359)
                             (:file "frontmatter")
                             (:file "vocabulary")    ; a controlled list and its check (#353)
                             (:file "search")         ; in-memory index, built at load
                             (:file "highlight")     ; a small CL highlighter (pre-publication issue 359 Q3)
                             (:file "render")        ; markdown, via hyperion/markdown
                             (:file "mode")          ; dev mode: preview is a flag
                             (:file "content")       ; the tree, and the all-or-nothing swap
                             (:file "collection")    ; collections and lookups for themes (#353)
                             (:file "listing")       ; feeds, tags, pages, search, and the resolver (#353)
                             (:file "export")        ; the site rendered to static files (#353)
                             (:file "watch")         ; reload on change, for development (#353)
                             (:file "serve"))))      ; the tree as a hyperion application
  :in-order-to ((test-op (test-op "klio/tests"))))

(defsystem "klio/tests"
  :description "Test suite for klio."
  :depends-on ("aion/fs" "klio" "fiveam"
               "plump"            ; the feed tests parse RSS and Atom as XML (#353)
               "com.inuoe.jzon")  ; and the search index as JSON
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "klio-tests"))))
  :perform (test-op (o c) (uiop:symbol-call :klio/tests :run-tests)))
