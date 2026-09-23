;;;; aion.lisp --- placeholder so the freshly-founded system loads clean.
;;;;
;;;; Replace as the library grows. First real work (see docs/roadmap.md): audit
;;;; what Coalton's stdlib already gives (docs/coalton-gap-analysis.md), then build
;;;; the gap-fills (sets, transducers, optics, lazy-seq, Monoid) and the pure-CL face.

(cl:in-package #:aion)

(defparameter +version+ "0.0.0"
  "Aion version. Pre-alpha vision scaffold.")

(defun version ()
  "Return the Aion version string."
  +version+)
