;;;; cons.lisp --- placeholder so the freshly-founded system loads clean.
;;;;
;;;; Replace as the tool grows. First real work (see docs/roadmap.md): `cons init`
;;;; -- generate the shared "just works" scaffold these six projects hand-rolled.

(cl:in-package #:cons)

(defparameter +version+ "0.0.0"
  "cons version. Pre-alpha vision scaffold.")

(defun version ()
  "Return the cons version string."
  +version+)
