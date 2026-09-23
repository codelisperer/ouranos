;;;; hyperion.lisp --- placeholder so the freshly-founded system loads clean.
;;;;
;;;; Replace this as the framework grows. First real work (see docs/roadmap.md):
;;;; extract the configurable server + hot-reload watcher from praxeon/src/web.lisp.

(cl:in-package #:hyperion)

(defparameter +version+ "0.0.0"
  "Hyperion version. Pre-alpha vision scaffold.")

(defun version ()
  "Return the Hyperion version string."
  +version+)
