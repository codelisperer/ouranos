;;;; elenchon.asd --- system definitions for Elenchon
;;;;
;;;; Elenchon (elenchos, "cross-examination / refutation"): the Cause-Effect Graph
;;;; engine + reasoning system for Requirements-Based Testing (Bender RBT lineage).
;;;; It takes a *structured* CEG (causes, effects, and the E/I/O/R/M constraints),
;;;; reasons over it (a relational solver -- miniKanren is a candidate), and emits
;;;; the minimum set of functional test cases covering the maximum share of the
;;;; requirement logic, plus a requirement-defect report. A typed Coalton core.
;;;;
;;;; SCOPE: Elenchon does CEG crunching and reasoning -- NOT natural-language
;;;; translation. Turning human prose into a CEG (and driving Elenchon to build
;;;; CEGs from human input) is an *agentic function that lives ABOVE Elenchon* in
;;;; praxeon (see praxeon's ChatRBT example). Elenchon must never depend on praxeon
;;;; or hyperion (dependency order: aion -> cons -> mnemosyne -> elenchon -> ...);
;;;; it may depend on aion/cons/mnemosyne only. See docs/method.md, docs/roadmap.md,
;;;; docs/elenchon-vision.md.
;;;;
;;;; Deps are deliberately minimal at founding (loads standalone). aion (and later
;;;; mnemosyne, for persisting CEGs/projects) are the planned leftward dependencies.

(defsystem "elenchon"
  :description "Requirements-Based Testing via Cause-Effect Graphs (Bender RBT lineage)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ("coalton"
               "alexandria")
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "ceg")
                             (:file "elenchon"))))
  :in-order-to ((test-op (test-op "elenchon/tests"))))

;;; The suite is wired -- it has a `:perform`, so `asdf:test-system` really runs it (the
;;; false-green class of bug in issue #116). fixtures.lisp is Coalton and must load first:
;;; it builds the graphs and exposes them to fiveam through promised types only.
(defsystem "elenchon/tests"
  :description "Test suite for Elenchon: the typed CEG ADT and its evaluation semantics."
  :depends-on ("elenchon" "fiveam")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "fixtures")
                             (:file "ceg"))))
  :perform (test-op (o c) (uiop:symbol-call :elenchon/tests :run-tests)))
