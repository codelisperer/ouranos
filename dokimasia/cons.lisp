;;;; cons.lisp --- build spec for dokimasia, consumed by `cons`.
;;;;
;;;; Run from this directory: `cons` lists the targets, `cons <target> KEY=VALUE ...` runs one.
;;;; Discovery is automatic once the repo-root `sbcl --script bootstrap.lisp` has run.
;;;;
;;;;   cons build                  compile dokimasia
;;;;   cons test                   run dokimasia's tests (the browser tests need Chrome or Edge)
;;;;   cons acceptance SYSTEM=dokimasia/examples/active-search SUITE=active-search \
;;;;                   VIEWPORTS=desktop,phone SCHEMES=light,dark OUT=build/acceptance
;;;;
;;;; `acceptance' runs any app's suite: SYSTEM is the ASDF system that defines it, which must be
;;;; on the ASDF path. An app can copy the target into its own cons.lisp unchanged. The browser
;;;; always runs headless; nothing in the target can show a window.

(cons:project "dokimasia"
  :system "dokimasia"
  :dynamic-space-size 4096            ; Coalton's first compile is heap-hungry
  :params ((system "" :doc "the ASDF system that defines the suite (acceptance)")
           (suite "" :doc "the suite's name (acceptance)")
           (viewports "desktop" :doc "comma-separated: desktop, phone (acceptance)")
           (schemes "light" :doc "comma-separated: light, dark (acceptance)")
           (out "" :doc "directory for report.txt, report.json and screenshots; default build/dokimasia/ (acceptance)"))
  :default (build)
  :targets
  ((build :doc "compile dokimasia"
          :load "dokimasia")
   ;; An :eval clause, not :test, so the exit code is the FiveAM run's status.
   (test  :doc "run dokimasia's tests (the browser tests need Chrome or Edge)"
          :load "dokimasia/tests"
          :eval "(uiop:quit (if (dokimasia/tests:run-tests) 0 1))")
   (repl  :doc "interactive SBCL REPL (the tree is on the ASDF path)"
          :interactive t)
   ;; :isolate runs it in an sbcl of its own, because RUN-FROM-COMMAND-LINE quits with the
   ;; exit code: 0 every row passed, 1 a row failed or was not run, 2 a wrong parameter.
   ;; :call passes the parameters as strings, so a Windows path in OUT keeps its backslashes.
   (acceptance :doc "run an app's suite headless: SYSTEM= SUITE= [VIEWPORTS= SCHEMES= OUT=]"
               :isolate t
               :load "dokimasia"
               :call ("dokimasia:run-from-command-line" :system system :suite suite
                      :viewports viewports :schemes schemes :out out))))
