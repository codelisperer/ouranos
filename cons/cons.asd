;;;; cons.asd --- system definitions for cons
;;;;
;;;; cons the magnificent: the missing project & dev tool for Common Lisp --
;;;; cargo/npm/go-tool, for CL. Scaffolds projects, manages dependencies (behind a
;;;; neutral source protocol: Quicklisp/ocicl now, native later), and runs the
;;;; build/test/repl loop. Pure-CL and dependency-light on purpose (it is a
;;;; bootstrapping tool). See docs/roadmap.md and docs/cons-vision.md.

;;; The .env loader, as its OWN system. A scaffolded app must load its .env as the first
;;; act of every entry point (#120), which means depending on the loader -- and depending on
;;; all of `cons` to get it would make the build tool a runtime dependency of every app it
;;; ever generates. This is uiop-only and holds one file, so an app pays almost nothing.
;;; cargo is not a runtime dependency of your crate either.
(defsystem "cons/env"
  :description "Load a project-local .env into the process environment (uiop-only)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "env-package")
                             (:file "env")))))

(defsystem "cons"
  :description "cons the magnificent -- project & dev tooling for Common Lisp."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  ;; sb-posix, on Unix only and for one reason: MKDIR is the atomic create-or-fail this
  ;; tree needs for a scratch directory (#204), and CL has no portable equivalent. The
  ;; :feature guard is on the PLATFORM rather than on :sbcl, because SBCL's Windows
  ;; sb-posix does not carry the same surface -- the same axis mistake that once made
  ;; hyperion/server fail to READ on Windows.
  ;; aion/secret is DEPENDENCY-FREE and Coalton-free by construction, which is what makes
  ;; it admissible here: cons's core stays trivial to install (#209).
  :depends-on ("alexandria" "cons/env" "aion/secret"
               (:feature :unix (:require :sb-posix)))
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "tempdir")  ; private scratch dirs, created not chosen
                             (:file "upstream") ; is the framework checkout behind? (#240)
                             (:file "db")       ; db-repl/db-url: a session per environment
                             (:file "toolchain"); is the Lisp under us the one we think it is?
                             (:file "env-scan") ; which config keys does this project need?
                             (:file "project")  ; runtime root discovery + registry init
                             (:file "setup")    ; put a project on the ASDF path (drop-in)
                             (:file "conform")  ; install the AI-conformance pack
                             (:file "init")     ; scaffold a new project (installs the pack)
                             (:file "template") ; check a template by generating + building it
                             (:file "cons")
                             (:file "spec")     ; read a project's cons.lisp build spec
                             (:file "run"))))   ; execute build-spec targets
  :in-order-to ((test-op (test-op "cons/tests"))))

;;; The `cons` command-line tool. A separate system so the core library never
;;; pulls the CLI dep (clingon). The bin/cons binary is built by the repo-root
;;; bootstrap.lisp seed (under raw SBCL), not from here -- a running cons cannot
;;; overwrite its own executable. See cons.lisp and bootstrap.lisp.
(defsystem "cons/cli"
  :description "The cons command-line tool: init / setup / conform / version (cargo-for-Lisp)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("cons" "clingon")
  :serial t
  :components ((:file "src/cli")))

;;; The headless Coalton REPL engine (eval + type introspection) -- the "cons's share"
;;; of the visual Coalton REPL (roadmap §6). A SEPARATE system because it pulls Coalton:
;;; cons core stays Coalton-free and trivial to install; only this opt-in system (and the
;;; hyperion front-end that consumes it) load Coalton. `(ql:quickload :cons/coalton-repl)`.
(defsystem "cons/coalton-repl"
  :description "Headless Coalton eval + type-introspection engine (the REPL core)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("coalton")
  :serial t
  :components ((:file "src/coalton-repl")))

(defsystem "cons/tests"
  :description "Test suite for cons."
  :depends-on ("cons" "cons/env" "aion/secret" "fiveam")  ; env-tests.lisp calls cons/env: directly
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "packages")
                             (:file "tempdir-tests")
                             (:file "env-tests")
                             (:file "db-tests")
                             (:file "toolchain-tests")
                             (:file "env-scan-tests")
                             (:file "project-tests")
                             (:file "setup-tests")
                             (:file "upstream-tests")
                             (:file "dev-port-tests")
                             (:file "conform-tests")
                             (:file "init-tests")
                             (:file "template-tests")
                             (:file "spec-tests")
                             (:file "platform-tests")
                             (:file "failure-origin-tests")
                             (:file "fiveam-report-tests")
                             (:file "view-launcher-tests"))))
  :perform (test-op (op c) (uiop:symbol-call :cons/tests :run-tests)))

;;; Tests for the OPT-IN Coalton REPL engine, kept out of `cons/tests` for the same reason
;;; the engine is kept out of `cons`: the core suite depends on `cons` alone and must not
;;; drag Coalton into a plain `(asdf:test-system :cons/tests)`.
(defsystem "cons/coalton-repl/tests"
  :description "Test suite for the headless Coalton REPL engine."
  :depends-on ("cons/coalton-repl" "fiveam")
  :serial t
  :components ((:module "tests"
                :components ((:file "coalton-repl-tests"))))
  :perform (test-op (op c) (uiop:symbol-call :cons/coalton-repl/tests :run-tests)))
