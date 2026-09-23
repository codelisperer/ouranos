;;;; klio.asd --- system definition for klio.

(defsystem "klio"
  :description "A git-backed content engine: markdown in version control, rendered live by hyperion."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  ;; No HTTP server here. Hyperion declares none (#139) and neither does klio -- the SITE
  ;; that instantiates klio picks its backend, and ADR-0017 makes that :uv. A library that
  ;; pulled in clack-handler-hunchentoot would choose for every consumer, and choose the
  ;; backend ADR-0011 called a stop-gap.
  :depends-on ("hyperion"
               "spinneret")
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "klio")
                             (:file "visibility")    ; request-time scheduling
                             (:file "frontmatter")
                             (:file "search")         ; in-memory index, built at load
                             (:file "highlight")     ; a small CL highlighter (#359 Q3)
                             (:file "render")        ; markdown, via hyperion/markdown
                             (:file "mode")          ; dev mode: preview is a flag
                             (:file "content")       ; the tree, and the all-or-nothing swap
                             (:file "serve"))))      ; the tree as a hyperion application
  :in-order-to ((test-op (test-op "klio/tests"))))

(defsystem "klio/tests"
  :description "Test suite for klio."
  :depends-on ("klio" "fiveam")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "klio-tests"))))
  :perform (test-op (o c) (uiop:symbol-call :klio/tests :run-tests)))
