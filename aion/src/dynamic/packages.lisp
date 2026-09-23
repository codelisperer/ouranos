;;;; packages.lisp --- aion/dynamic package definition.

(cl:defpackage #:aion/dynamic
  (:use #:cl)
  (:documentation
   "Dynamic bindings that should survive a thread boundary.

    A dynamic variable bound with LET is visible only on the thread that bound it. A child
    thread sees the global value, which for an ambient context is usually the empty one --
    so the binding is silently absent rather than absent with an error. This package is how
    a package declares that one of its variables should cross, and how a caller carries the
    declared set onto a thread it spawns.

    It owns no threading. The caller spawns; this only moves bindings.")
  (:export #:register-inheritable #:inheritable-variables #:unregister-inheritable
           #:capture #:call-with-captured #:inheriting #:with-captured))
