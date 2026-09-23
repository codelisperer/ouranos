;;;; dynamic.lisp --- carry declared dynamic bindings across a thread boundary (#430).
;;;;
;;;; THE DEFECT THIS EXISTS FOR. `aion/log:*context*' holds the ambient structured fields --
;;;; correlation id, user, request -- and is bound with LET by `with-context'. A LET binding
;;;; is per-thread. Work handed to another thread reads the GLOBAL value, which is the empty
;;;; list, so every field the seam established is missing from every line the child logs.
;;;; Nothing errors. The line still appears and still looks complete, which is the worst
;;;; shape a logging defect can have.
;;;;
;;;; WHY A REGISTRY RATHER THAN A FIX IN EACH PACKAGE. `*context*' is aion's and praxeon's
;;;; `*observer*' has the same problem. Two per-variable fixes are two mechanisms that
;;;; drift, and the second one is written by whoever notices next. aion sits leftward of
;;;; praxeon in the DAG, so it can hold the vocabulary for both.
;;;;
;;;; WHAT THIS DOES NOT DO: spawn threads. A registry that grew a spawn primitive would own
;;;; a concern it has no business in, and every caller already has the spawn it wants.
;;;;
;;;; REGISTRATION IS NOT EVIDENCE, and this is the part worth reading before trusting it. A
;;;; variable registered here still crosses nothing unless a caller captures. The tree keeps
;;;; that honest with a test that walks every thread-spawn site and fails on one that has
;;;; neither carried the bindings nor said why it does not -- see the sweep in aion's suite.
;;;; Without that test this file is a mechanism a reader would believe was working.

(cl:in-package #:aion/dynamic)

(defvar *inheritable* '()
  "Symbols naming dynamic variables that should cross a thread boundary.

A list rather than a set because the order is the order they are rebound in, and a caller
reading a capture should see the same order twice.")

#|
WHAT IS DELIBERATELY NOT REGISTERED, and why, because a reader who finds one of these
unregistered will otherwise assume it was overlooked and register it.

  hyperion/csrf:*token-thunk* (csrf.lisp:360). Bound per request around the whole app, so
  it has the same shape as the two that are registered. NOT registered, for two reasons.
  Its failure is LOUD -- no thunk, no token, the POST is refused -- and a loud failure is
  worth less to fix than a quiet one that writes a plausible line and moves on. And no spawn
  site has been found that loses it. Registering a variable nobody captures makes this list
  longer without making it truer, which is the same principle the sweep enforces for spawn
  sites. If a crossing that drops it is ever found, register it then, and cite the crossing.

THE LIST IS NOT CLOSED, and nothing here can make it so. The sweep proves every spawn site
has decided whether to carry bindings. It does not prove every variable that should cross
has been found -- those are different guarantees, and only the first one has a test. The
variables registered here are the ones somebody went looking for.
|#

(defun register-inheritable (symbol)
  "Declare that SYMBOL's dynamic binding should cross into threads a caller spawns.

Idempotent: registering twice leaves one entry, so a file that is loaded twice does not
rebind the same variable twice in every child.

REGISTERING IS NOT ENOUGH ON ITS OWN. The value crosses only where a caller captures it and
rebinds on the child. If you register a variable and no spawn site captures, the variable is
lost exactly as it was before, and now there is a registration suggesting otherwise."
  (check-type symbol symbol)
  (pushnew symbol *inheritable*)
  symbol)

(defun unregister-inheritable (symbol)
  "Remove SYMBOL from the inheritable set. Returns true when it was there."
  (let ((had (member symbol *inheritable*)))
    (setf *inheritable* (remove symbol *inheritable*))
    (and had t)))

(defun inheritable-variables ()
  "The registered symbols, most recently registered first."
  (copy-list *inheritable*))

(defun capture ()
  "A snapshot of every registered variable's current value.

Taken on the spawning thread, while the bindings are still visible. An unbound variable is
skipped rather than captured as NIL: rebinding it on the child would give it a global value
it never had."
  (loop for symbol in *inheritable*
        when (boundp symbol)
          collect (cons symbol (symbol-value symbol))))

(defun call-with-captured (snapshot thunk)
  "Call THUNK with the variables in SNAPSHOT bound to their captured values.

PROGV rather than a macro with LET, because the variables are not known until run time --
which is the whole point of a registry."
  ;; ORDERING MATTERS AND IS PART OF THE CONTRACT: the snapshot is established AROUND the
  ;; thunk, so a binding the thunk establishes for itself shadows the inherited one. That is
  ;; what lets a child inherit the caller's context and still replace one member of it --
  ;; `praxeon/web' inherits the request's logging context and installs its own observer for
  ;; the conversation it is reporting into, which is correct and must keep working.
  ;;
  ;; Stated here rather than left to the fact that dynamic bindings happen to nest, because
  ;; an implementation that established the snapshot INSIDE the thunk, or that restored it
  ;; afterwards, would break that site while passing every test that only checks inheritance.
  (progv (mapcar #'car snapshot) (mapcar #'cdr snapshot)
    (funcall thunk)))

(defun inheriting (thunk)
  "THUNK wrapped so it runs with the bindings visible HERE, wherever it is later called.

The capture happens now, on this thread, at the moment `inheriting' is called -- not when
the returned function runs. That is the only moment the bindings are visible, so a caller
must wrap before spawning rather than inside the child.

Intended use is at a spawn site:

    (sb-thread:make-thread (aion/dynamic:inheriting (lambda () ...)))

USE IT ONLY FOR A THREAD THAT CONTINUES THE CURRENT UNIT OF WORK. A long-lived worker --
a pool thread, a server thread, an event loop -- must NOT inherit: it outlives the context
that created it and would stamp that context's correlation id onto every unrelated piece of
work it later does. An absent field is a gap; a wrong one is a false statement about which
request a line belongs to, and it is much harder to notice because the field is present."
  (let ((snapshot (capture)))
    (lambda (&rest args)
      (call-with-captured snapshot (lambda () (apply thunk args))))))

(defmacro with-captured ((snapshot) &body body)
  "Run BODY with the variables in SNAPSHOT bound. For a child that received a capture
rather than a wrapped thunk."
  `(call-with-captured ,snapshot (lambda () ,@body)))
