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
  :depends-on ("hades/single-instance" "hades/credentials" "hades/notify" "hades/open")
  :in-order-to ((test-op (test-op "hades/single-instance/tests" "hades/credentials/tests"
                                  "hades/notify/tests" "hades/open/tests"))))

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
  :description "A credential store over the operating system's own -- Windows Credential Manager, the macOS Keychain, and the Secret Service on Linux -- that returns aion/secret values and never falls back to a file (#357)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  ;; aion/secret for the value in and out. On Windows, Credential Manager through
  ;; aion/windows; on macOS, the Keychain through aion/darwin; on Linux, the Secret Service
  ;; through aion/libsecret (the bindings belong to aion; hades ADR-0001).
  :depends-on ("aion/secret"
               (:feature :win32 "aion/windows")
               (:feature :darwin "aion/darwin")
               (:feature :linux "aion/libsecret")
               (:feature (:or :win32 :darwin :linux) "cffi"))
  :serial t
  :components ((:module "src/credentials"
                :serial t
                :components ((:file "packages")
                             (:file "credentials"))))
  :in-order-to ((test-op (test-op "hades/credentials/tests"))))

(defsystem "hades/credentials/tests"
  :description "Tests for hades/credentials: the round trip, a missing item, and the value never appearing in text."
  :depends-on ("hades/credentials" "aion/secret" "fiveam" (:feature :linux "aion/libsecret"))
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "credentials-tests"))))
  :perform (test-op (o c) (uiop:symbol-call :hades/credentials/tests :run-tests)))

(defsystem "hades/program"
  :description "Finding a program on PATH, for the hades facades that run one on Linux (#819, #820)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  ;; sb-posix, an SBCL contrib, for stat and access; Unix-only here, as in cons.asd.
  :depends-on ((:feature :unix (:require :sb-posix)))
  :components ((:module "src" :components ((:file "program")))))

(defsystem "hades/notify"
  :description "A modal notice with one OK button that works before an app has a window, written to standard error where none can be shown (#819)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  ;; Windows: MessageBoxW and ProcessIdToSessionId, bound in aion/windows (hades ADR-0001).
  ;; macOS: /usr/bin/osascript. Linux: zenity or kdialog, found on PATH by hades/program.
  :depends-on ("hades/program"
               (:feature :win32 "aion/windows")
               (:feature :win32 "cffi"))
  :serial t
  :components ((:module "src/notify"
                :serial t
                :components ((:file "packages")
                             (:file "notify"))))
  :in-order-to ((test-op (test-op "hades/notify/tests"))))

(defsystem "hades/notify/tests"
  :description "Tests for hades/notify: every platform's decision, the standard-error path and the argument checks, with no window shown."
  :depends-on ("hades/notify" "fiveam")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "notify-tests"))))
  :perform (test-op (o c) (uiop:symbol-call :hades/notify/tests :run-tests)))

(defsystem "hades/open"
  :description "Show a file or directory in the system file manager, and open a web URL in the default browser, with no shell (#820)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  ;; Windows: explorer.exe, and ShellExecuteW and the Windows directory bound in aion/windows.
  ;; /usr/bin/open on macOS, xdg-open and dbus-send on Linux, all run as programs;
  ;; hades/program finds the Linux ones on PATH.
  :depends-on ("hades/program"
               (:feature :win32 "aion/windows"))
  :serial t
  :components ((:module "src/open"
                :serial t
                :components ((:file "packages")
                             (:file "open"))))
  :in-order-to ((test-op (test-op "hades/open/tests"))))

(defsystem "hades/open/tests"
  :description "Tests for hades/open: every platform's command, the refusals and the fallbacks, with nothing opened."
  :depends-on ("hades/open" "fiveam")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "open-tests"))))
  :perform (test-op (o c) (uiop:symbol-call :hades/open/tests :run-tests)))
