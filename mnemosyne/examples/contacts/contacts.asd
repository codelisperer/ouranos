;;;; contacts.asd --- system definition for contacts.

(defsystem "contacts"
  :description "A console contacts app showcasing mnemosyne migrations + query (an example)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ("mnemosyne")
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "contacts"))))
  ;; The suite lives in mnemosyne.asd as `mnemosyne/examples/contacts/tests' (pre-publication issue 357): it is
  ;; OURANOS's test of this example, not the scaffolded project's own, and the name is what
  ;; makes its checks attribute to mnemosyne's README row instead of to a framework called
  ;; "contacts" that does not exist. This system stays standalone, which is the property the
  ;; example is for.
  :in-order-to ((test-op (test-op "mnemosyne/examples/contacts/tests"))))
