;;;; unrun-suites.lisp --- a compiled system whose /tests system the gate never runs (#992).
;;;;
;;;; #973 added aion/sexp to the list of systems verify-tree.lisp compiles, but not
;;;; aion/sexp/tests to the list it runs. Every leg was green, the total equalled main's, and
;;;; the suite's 137 checks never ran. The only thing that noticed was the rule that a new
;;;; suite's first commit must move the total.
;;;;
;;;; UNRUN-SUITES finds that state. For each system the gate compiles, if ASDF can find a
;;;; system named <system>/tests, that suite must be run: either it is in the gate's run list,
;;;; or a suite in the run list depends on it, directly or through other suites. The second
;;;; case is how aion/tests runs aion/csv/tests, aion/clock/tests and aion/log/tests. There
;;;; is no list of exceptions.
;;;;
;;;; Only dependencies that are themselves /tests systems are followed. Following every
;;;; dependency would make ASDF read the .asd files of libraries outside the tree, and the
;;;; gate's own image cannot load Coalton's .asd without Quicklisp.
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

(defun %dependency-names (system)
  "The names of the systems SYSTEM's :depends-on names on this host. (:version name ...) gives
its system's name, and so does (:feature expression name) when EXPRESSION holds here, because
ASDF skips the dependency when it does not (review of #1072). (:require module) names no ASDF
system."
  (labels ((name-of (dep)
             (cond ((or (stringp dep) (symbolp dep)) dep)
                   ((and (consp dep) (eq (first dep) :version)) (name-of (second dep)))
                   ((and (consp dep) (eq (first dep) :feature))
                    (when (uiop:featurep (second dep)) (name-of (third dep)))))))
    (loop for dep in (asdf:system-depends-on system)
          for name = (name-of dep)
          when name collect (%name name))))

(defun %suite-name-p (name)
  "Whether NAME is a /tests system's name."
  (let ((end (- (length name) (length "/tests"))))
    (and (plusp end) (string= "/tests" name :start2 end))))

(defun %run-closure (test-systems)
  "The names of TEST-SYSTEMS and of every /tests system they depend on, directly or through
other /tests systems. A run-list entry ASDF cannot find is skipped here; the gate fails it when
it runs."
  (let ((seen (make-hash-table :test #'equal))
        (queue (mapcar #'%name test-systems)))
    (loop while queue
          do (let ((name (pop queue)))
               (unless (gethash name seen)
                 (setf (gethash name seen) t)
                 (let ((system (asdf:find-system name nil)))
                   (when system
                     (setf queue (append (remove-if-not #'%suite-name-p
                                                        (%dependency-names system))
                                         queue)))))))
    seen))

(defun unrun-suites (systems test-systems)
  "The suites the gate would compile around without running, as a list of
(system . suite) name pairs, in the order of SYSTEMS. A pair names a system in SYSTEMS whose
<system>/tests ASDF can find, when that suite is neither in TEST-SYSTEMS nor a /tests
dependency of one of them (see %RUN-CLOSURE). NIL when every such suite runs."
  (let ((run (%run-closure test-systems)))
    (loop for system in systems
          for suite = (format nil "~A/tests" (%name system))
          when (and (asdf:find-system suite nil) (not (gethash suite run)))
            collect (cons (%name system) suite))))
