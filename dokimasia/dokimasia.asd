;;;; dokimasia.asd --- a data-driven acceptance-test harness for any app that runs in a browser.
;;;;
;;;; A satellite attached at aion (dokimasia ADR-0001, #1028). The core systems depend only on
;;;; aion and external libraries, and nothing in the dependency line depends on them. The aux
;;;; systems that know one framework may reach right: dokimasia/mnemosyne and
;;;; dokimasia/hyperion.

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
  ;; The vendored axe-core comes before the source that embeds it, so a new axe.min.js
  ;; recompiles src/audit.lisp rather than leaving the old text in its fasl.
  :components ((:module "vendor"
                :components ((:static-file "ASSETS.pin")
                             (:static-file "axe.min.js")
                             (:static-file "axe.LICENSE")
                             (:static-file "axe.LICENSE-3RD-PARTY.txt")))
               (:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "definitions")
                             (:file "targets")
                             (:file "watch")
                             (:file "steps")
                             (:file "audit")
                             (:file "report")
                             (:file "run"))))
  :in-order-to ((test-op (test-op "dokimasia/tests"))))

(defsystem "dokimasia/tests"
  :description "dokimasia's tests: the verdict, cases and rows as data, the report, and runs in a real headless browser against an HTTP server written in the suite."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("dokimasia" "dokimasia/core" "aion/cdp" "aion/secret" "aion/dynamic"
               "com.inuoe.jzon" "fiveam" (:require :sb-bsd-sockets)
               "ironclad")         ; the hash of the axe-core compiled into the image
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "packages")
                             (:file "data-tests")
                             (:file "server")
                             (:file "browser-tests"))))
  :perform (test-op (o c)
             (uiop:symbol-call :dokimasia/tests :run-tests)))

(defsystem "dokimasia/mnemosyne"
  :description "Stored-data probes for dokimasia's :expect-stored step that read the app's database through mnemosyne (#1028)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ("dokimasia" "mnemosyne")
  :serial t
  :components ((:module "src/mnemosyne"
                :serial t
                :components ((:file "packages")
                             (:file "probes"))))
  :in-order-to ((test-op (test-op "dokimasia/mnemosyne/tests"))))

(defsystem "dokimasia/mnemosyne/tests"
  :description "dokimasia/mnemosyne's tests: its probes against a SQLite database, with no browser."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("dokimasia/mnemosyne" "dokimasia" "mnemosyne" "fiveam")
  :serial t
  :components ((:module "tests/mnemosyne"
                :serial t
                :components ((:file "tests"))))
  :perform (test-op (o c)
             (uiop:symbol-call :dokimasia/mnemosyne/tests :run-tests)))

(defsystem "dokimasia/hyperion"
  :description "A dokimasia target for a hyperion app: started on a free port with a scratch SQLite database and seeded users, a settle check that waits for htmx, and sign-in through a session in the app's store (#1028)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ("dokimasia" "aion/cdp" "aion/fs" "hyperion" "hyperion/test-ports" "mnemosyne")
  :serial t
  :components ((:module "src/hyperion"
                :serial t
                :components ((:file "packages")
                             (:file "target"))))
  :in-order-to ((test-op (test-op "dokimasia/hyperion/tests"))))

(defsystem "dokimasia/hyperion/tests"
  :description "dokimasia/hyperion's tests: a small hyperion app started by the target, run in a real headless browser where one is found."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("dokimasia/hyperion" "dokimasia/mnemosyne" "dokimasia" "aion/cdp" "aion/fs" "hyperion"
               "hyperion/assets" "hyperion/test-ports" "mnemosyne" "com.inuoe.jzon" "fiveam"
               "clack-handler-hunchentoot") ; the server the test app runs on, as hyperion's tests use
  :serial t
  :components ((:module "tests/hyperion"
                :serial t
                :components ((:file "tests"))))
  :perform (test-op (o c)
             (uiop:symbol-call :dokimasia/hyperion/tests :run-tests)))

;;; The worked example (#1028, step 4): an acceptance suite for hyperion's active-search example
;;; app, run through dokimasia/hyperion. It reaches right to hyperion's examples, as the aux
;;; system it uses does to hyperion.
(defsystem "dokimasia/examples/active-search"
  :description "A worked example of dokimasia: acceptance tests, as data, for hyperion's active-search example app and its SQLite-backed twin, whose stored rows are checked through dokimasia/mnemosyne (#1028)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ("dokimasia" "dokimasia/hyperion" "dokimasia/mnemosyne"
               "hyperion/examples/active-search" "hyperion/examples/active-search-db")
  :serial t
  :components ((:module "examples/active-search"
                :serial t
                :components ((:file "acceptance")
                             (:static-file "rows/search.csv")
                             (:static-file "rows/add.csv")
                             (:static-file "rows/invalid.csv"))))
  :in-order-to ((test-op (test-op "dokimasia/examples/active-search/tests"))))

(defsystem "dokimasia/examples/active-search/tests"
  :description "The worked example's tests: its suites run against the apps in a real headless browser, at desktop and phone width, with stored rows checked in the database, and controls that fail."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("dokimasia/examples/active-search" "dokimasia" "aion/cdp" "aion/fs"
               "hyperion/examples/active-search-db" "mnemosyne" "com.inuoe.jzon" "fiveam")
  :serial t
  :components ((:module "examples/active-search"
                :serial t
                :components ((:file "tests"))))
  :perform (test-op (o c)
             (uiop:symbol-call :dokimasia/examples/active-search/tests :run-tests)))
