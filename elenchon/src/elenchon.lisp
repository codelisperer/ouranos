;;;; elenchon.lisp --- placeholder so the freshly-founded system loads clean.
;;;;
;;;; Replace as the library grows. The shape to build (see docs/method.md,
;;;; docs/roadmap.md): a typed Cause-Effect Graph ADT + a reasoning system over it that
;;;; emits the minimum high-coverage decision table, plus a requirement-defect report.
;;;; The engine is decided in docs/adr/0002-reasoning-engine.md: a native Coalton core
;;;; (independence-pair generation, then set cover) behind a `Solver' protocol. The
;;;; CEG ADT exists (elenchon/ceg); the reasoning core does not yet. Input is a
;;;; *structured* CEG; the NL->CEG translation is an agentic function above Elenchon
;;;; (praxeon/ChatRBT), never part of this library.

(cl:in-package #:elenchon)

(defparameter +version+ "0.0.0"
  "Elenchon version. Pre-alpha: the CEG ADT exists, the reasoning core (ADR-0002) does not yet.")

(defun version ()
  "Return the Elenchon version string."
  +version+)
