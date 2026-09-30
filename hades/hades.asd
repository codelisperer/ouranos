;;;; hades.asd --- system definitions for Hades, the OS ergonomics layer (ADR-0001).
;;;;
;;;; A satellite: it depends leftward into the line, at aion, and nothing in the line depends
;;;; on it. An app uses it alongside the frameworks. That is also why hyperion/desktop:run-app
;;;; cannot take the single-instance lock itself; the app takes it around run-app.

(defsystem "hades"
  :description "Hades, the OS ergonomics layer over aion's bindings: its portable facades (ADR-0001)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  ;; The facades that exist so far. ASDF also needs this primary system before it resolves a
  ;; secondary one such as hades/single-instance.
  :depends-on ("hades/single-instance" "hades/credentials")
  :in-order-to ((test-op (test-op "hades/single-instance/tests" "hades/credentials/tests"))))

(defsystem "hades/single-instance"
  :description "A per-user, per-directory single-instance lock held by the operating system, released when the process ends (#305)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  ;; Windows: CreateFileW with share mode 0, bound in aion/windows (the binding belongs to
  ;; aion; hades ADR-0001). Elsewhere: fcntl through sb-posix, which is Unix-only here, as in
  ;; cons.asd.
  :depends-on ((:feature :win32 "aion/windows")
               (:feature :win32 "cffi")
               (:feature :unix (:require :sb-posix)))
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "single-instance"))))
  :in-order-to ((test-op (test-op "hades/single-instance/tests"))))

(defsystem "hades/single-instance/tests"
  :description "Tests for hades/single-instance, in one process and across processes."
  :depends-on ("hades/single-instance" "fiveam")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "single-instance-tests"))))
  :perform (test-op (o c) (uiop:symbol-call :hades/single-instance/tests :run-tests)))

(defsystem "hades/credentials"
  :description "A credential store over the operating system's own -- Windows Credential Manager so far -- that returns aion/secret values and never falls back to a file (#357)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  ;; aion/secret for the value in and out. On Windows, Credential Manager through
  ;; aion/windows (the binding belongs to aion; hades ADR-0001).
  :depends-on ("aion/secret"
               (:feature :win32 "aion/windows")
               (:feature :win32 "cffi"))
  :serial t
  :components ((:module "src/credentials"
                :serial t
                :components ((:file "packages")
                             (:file "credentials"))))
  :in-order-to ((test-op (test-op "hades/credentials/tests"))))

(defsystem "hades/credentials/tests"
  :description "Tests for hades/credentials: the round trip, a missing item, and the value never appearing in text."
  :depends-on ("hades/credentials" "aion/secret" "fiveam")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "credentials-tests"))))
  :perform (test-op (o c) (uiop:symbol-call :hades/credentials/tests :run-tests)))
