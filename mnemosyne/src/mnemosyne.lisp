;;;; mnemosyne.lisp --- placeholder so the freshly-founded system loads clean.
;;;;
;;;; Replace as the data layer grows. First targets (see docs/roadmap.md):
;;;;   - a CONNECTION behind a neutral backend protocol (PostgreSQL wire first);
;;;;   - a typed SCHEMA + a small QUERY DSL;
;;;;   - bitemporal semantics (valid-time / tx-time) as a first-class concern;
;;;;   - MIGRATIONS.
;;;; Consumers: a consuming app (users/roles/content/subscriptions) is first; then
;;;; *Kairos* -- the bitemporal knowledge-graph store built on Mnemosyne's DB
;;;; abstractions, which Praxeon leverages for recall + context-budget economics.

(cl:in-package #:mnemosyne)

(defparameter +version+ "0.0.0"
  "Mnemosyne version. Pre-alpha; scaffold.")

(defun version ()
  "Return the Mnemosyne version string."
  +version+)
