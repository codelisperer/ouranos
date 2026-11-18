;;;; dokimasia.asd --- a data-driven acceptance-test harness for any app that runs in a browser.
;;;;
;;;; A satellite attached at aion (dokimasia ADR-0001, #1028). The core systems depend only on
;;;; aion and external libraries, and nothing in the dependency line depends on them. The aux
;;;; systems that know one framework (dokimasia/hyperion, dokimasia/mnemosyne) come in a later
;;;; step and may reach right.

(defsystem "dokimasia/core"
  :description "The typed core of dokimasia: step results and how they combine into a row's verdict (#1028)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ("coalton")
  :serial t
  :components ((:module "src/core"
                :serial t
                :components ((:file "packages")
                             (:file "core")))))

(defsystem "dokimasia"
  :description "Acceptance cases as data, run in a headless Chrome or Edge against an app it starts or a deployed URL, one FiveAM test per case and row (#1028)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ("dokimasia/core"
               "aion/cdp"          ; the browser
               "aion/boundary"     ; lists are checked before they enter dokimasia/core (#110)
               "aion/sexp"         ; rows from an s-expression file, read as plain data (#972)
               "aion/csv"          ; rows from a CSV file
               "aion/secret"       ; a user's password stays redacted until a step types it
               "aion/log"
               "com.inuoe.jzon"    ; report.json
               "fiveam")           ; each case and row is one FiveAM test
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "definitions")
                             (:file "targets")
                             (:file "watch")
                             (:file "steps")
                             (:file "report")
                             (:file "run"))))
  :in-order-to ((test-op (test-op "dokimasia/tests"))))

(defsystem "dokimasia/tests"
  :description "dokimasia's tests: the verdict, cases and rows as data, the report, and runs in a real headless browser against an HTTP server written in the suite."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("dokimasia" "dokimasia/core" "aion/cdp" "aion/secret" "aion/dynamic"
               "com.inuoe.jzon" "fiveam" (:require :sb-bsd-sockets))
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "packages")
                             (:file "data-tests")
                             (:file "server")
                             (:file "browser-tests"))))
  :perform (test-op (o c)
             (uiop:symbol-call :dokimasia/tests :run-tests)))
