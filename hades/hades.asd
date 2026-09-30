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
  :depends-on ("hades/single-instance")
  :in-order-to ((test-op (test-op "hades/single-instance/tests"))))

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
