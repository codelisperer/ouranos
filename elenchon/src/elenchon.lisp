;;;; elenchon.lisp --- placeholder so the freshly-founded system loads clean.
;;;;
;;;; Replace as the library grows. The shape to build (see docs/method.md,
;;;; docs/roadmap.md): a typed Cause-Effect Graph ADT + a reasoning system over it
;;;; (a relational solver -- miniKanren is a candidate) that emits the minimum
;;;; high-coverage decision table, plus a requirement-defect report. Input is a
;;;; *structured* CEG; the NL->CEG translation is an agentic function above Elenchon
;;;; (praxeon/ChatRBT), never part of this library.

(cl:in-package #:elenchon)

(defparameter +version+ "0.0.0"
  "Elenchon version. Pre-alpha vision scaffold.")

(defun version ()
  "Return the Elenchon version string."
  +version+)
