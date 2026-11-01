;;;; unrun-suites.lisp --- a compiled system whose /tests system the gate never runs (#992).
;;;;
;;;; #973 added aion/sexp to the list of systems verify-tree.lisp compiles, but not
;;;; aion/sexp/tests to the list it runs. Every leg was green, the total equalled main's, and
;;;; the suite's 137 checks never ran. The only thing that noticed was the rule that a new
;;;; suite's first commit must move the total.
;;;;
;;;; UNRUN-SUITES finds that state. For each system the gate compiles, if ASDF can find a
;;;; system named <system>/tests, that suite must be run: either it is in the gate's run list,
;;;; or a suite in the run list runs it through ASDF, with
;;;; :in-order-to ((test-op (test-op "<system>/tests"))), directly or through other suites
;;;; wired the same way. That is how aion/tests runs aion/csv/tests, aion/csv/types/tests,
;;;; aion/clock/tests and aion/log/tests. There is no list of exceptions.
;;;;
;;;; A :depends-on does not count, because ASDF loads a dependency and does not run its tests:
;;;; praxeon/web/tests depends on hyperion/assets/tests only for its browser helpers (review of
;;;; #1072). The hub ruled on this in #992.
;;;;
;;;; Split out of verify-tree.lisp so that checkers/tests can hand it a fixture tree; see
;;;; scripts/tests/unrun-suites.lisp.

(defpackage #:ouranos-unrun-suites
  (:use #:cl)
  (:export #:unrun-suites))

(in-package #:ouranos-unrun-suites)

(defun %name (designator)
  "The ASDF name of DESIGNATOR, a keyword or a string, in lower case."
  (string-downcase (string designator)))

(defun %dependency-name (dep)
  "The system name a dependency form DEP names on this host, or NIL. (:version name ...)
gives its system's name, and so does (:feature expression name) when EXPRESSION holds here,
because ASDF skips the dependency when it does not (review of #1072)."
  (cond ((or (stringp dep) (symbolp dep)) (%name dep))
        ((and (consp dep) (eq (first dep) :version)) (%dependency-name (second dep)))
        ((and (consp dep) (eq (first dep) :feature))
         (when (uiop:featurep (second dep)) (%dependency-name (third dep))))))

(defun %test-op-targets (system)
  "The names of the systems whose tests ASDF runs before SYSTEM's own, from SYSTEM's
:in-order-to ((test-op (test-op name ...))). ASDF stores that option in a normalised form,
which COMPONENT-IN-ORDER-TO returns; the accessor is not exported."
  (loop for (op . requirements) in (asdf::component-in-order-to system)
        when (eq op 'asdf:test-op)
          append (loop for (required-op . names) in requirements
                       when (eq required-op 'asdf:test-op)
                         append (remove nil (mapcar #'%dependency-name names)))))

(defun %run-closure (test-systems)
  "The names of TEST-SYSTEMS and of every system whose tests they run through
:in-order-to test-op wiring, directly or through other systems wired the same way. A run-list
entry ASDF cannot find is skipped here; the gate fails it when it runs."
  (let ((seen (make-hash-table :test #'equal))
        (queue (mapcar #'%name test-systems)))
    (loop while queue
          do (let ((name (pop queue)))
               (unless (gethash name seen)
                 (setf (gethash name seen) t)
                 (let ((system (asdf:find-system name nil)))
                   (when system
                     (setf queue (append (%test-op-targets system) queue)))))))
    seen))

(defun unrun-suites (systems test-systems)
  "The suites the gate would compile around without running, as a list of
(system . suite) name pairs, in the order of SYSTEMS, and as a second value the number of
systems in SYSTEMS that have a /tests suite, which is how many were checked. A pair names a
system in SYSTEMS whose <system>/tests ASDF can find, when that suite is neither in
TEST-SYSTEMS nor run by one of them through :in-order-to test-op wiring (see %RUN-CLOSURE).
The list is NIL when every such suite runs."
  (let ((run (%run-closure test-systems)))
    (loop for system in systems
          for suite = (format nil "~A/tests" (%name system))
          for found = (asdf:find-system suite nil)
          when found count t into checked
          when (and found (not (gethash suite run)))
            collect (cons (%name system) suite) into unrun
          finally (return (values unrun checked)))))
