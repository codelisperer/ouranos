;;;; {{name}}.asd --- system definition for {{name}}.

(defsystem "{{name}}"
  :description ""
  :author "{{author}}"
  :license ""
  :version "0.0.0"
  :depends-on ({{deps}})
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "{{name}}"))))
  :in-order-to ((test-op (test-op "{{name}}/tests"))))

(defsystem "{{name}}/tests"
  :description "Test suite for {{name}}."
  :depends-on ("{{name}}" "fiveam")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ())))
