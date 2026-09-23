;;;; tests/ceg.lisp --- fiveam suite for elenchon/ceg, the typed Cause-Effect Graph ADT.
;;;;
;;;; Pins the semantics ADR-0001 committed to. The graphs live in tests/fixtures.lisp
;;;; (Coalton); this file asserts over the promised-type answers they expose.
;;;;
;;;; What is worth testing here is narrower than "does it compute booleans." The ADT makes
;;;; three claims that the rest of Elenchon is built on, and each has a section below:
;;;;
;;;;   1. `Ref` gives real SHARING -- one node, many effects (the DAG, not a tree).
;;;;   2. `None` means UNDERDETERMINED and is never silently a false. This is the whole
;;;;      reason evaluation returns (Optional Boolean); collapsing it would turn a
;;;;      requirement defect into a passing test case.
;;;;   3. The E/I/O/R/M constraint vocabulary means what docs/method.md says it means.

(defpackage #:elenchon/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:f #:elenchon/tests-fixtures))
  (:export #:run-tests #:ceg))
(in-package #:elenchon/tests)

(def-suite ceg :description "elenchon/ceg: the typed CEG ADT and its evaluation semantics.")
(in-suite ceg)

;;; --- the canonical requirement --------------------------------------------
;;; "If the account is overdue AND the customer is not exempt, apply a late fee
;;;  and send a notice."

(test effect-fires-only-on-overdue-and-not-exempt
  (is (string= "true"  (f:effect-of t   nil)) "overdue, not exempt -> late fee")
  (is (string= "false" (f:effect-of t   t))   "exempt suppresses the fee")
  (is (string= "false" (f:effect-of nil nil)) "not overdue -> no fee")
  (is (string= "false" (f:effect-of nil t))   "neither condition met"))

(test negation-inverts-its-operand
  (is (string= "false" (f:negation-of t)))
  (is (string= "true"  (f:negation-of nil))))

;;; --- 1. sharing: the DAG, not a tree --------------------------------------

(test both-effects-hang-off-the-same-shared-node
  ;; E1 and E2 are both (Ref N1). Under ADR-0001 that is one node, not two identical
  ;; subtrees -- so they can never disagree. Duplicating the subexpression instead of
  ;; sharing it would still pass the value tests above; this is what would catch it.
  (dolist (overdue '(t nil))
    (dolist (exempt '(t nil))
      (is-true (f:shared-node-drives-both overdue exempt)
               "E1 and E2 must agree: they reference the same node"))))

(test the-shared-node-is-addressable
  ;; Traceability and the defect report both need to point AT a node, which is the
  ;; reason sharing is explicit rather than hash-consed.
  (is (string= "N1" f:node-name-of)))

;;; --- 2. underdetermined is not false --------------------------------------

(test an-unassigned-cause-yields-unknown-not-false
  ;; The load-bearing one. C2 is unbound, so the graph does not determine E1. Returning
  ;; "false" here would silently convert a requirement defect into a valid test case.
  (is (string= "unknown" f:effect-of-partial)))

(test a-dangling-ref-yields-unknown-not-false
  ;; Node cycles and dangling refs became expressible when ADR-0001 chose a DAG. The
  ;; evaluator must surface that as underdetermined; the builder (#27) rejects it.
  (is (string= "unknown" f:dangling-ref-result)))

(test count-true-is-unknown-when-a-cause-is-unbound
  (is (= -1 f:count-true-partial)
      "count-true must not treat an unbound cause as false"))

;;; --- vacuity --------------------------------------------------------------

(test empty-conjunction-is-true-and-empty-disjunction-is-false
  ;; The n-ary identities. Worth pinning: an implementation that folded these the other
  ;; way would make an effect with no conditions fire never instead of always.
  (is (string= "true"  f:vacuous-conj))
  (is (string= "false" f:vacuous-disj)))

;;; --- 3. the constraint vocabulary (docs/method.md) ------------------------

(test exclusive-allows-at-most-one
  (is (string= "false" (f:excl-holds t   t)))
  (is (string= "true"  (f:excl-holds t   nil)))
  (is (string= "true"  (f:excl-holds nil t)))
  (is (string= "true"  (f:excl-holds nil nil)) "none true satisfies at-most-one"))

(test inclusive-requires-at-least-one
  (is (string= "true"  (f:incl-holds t   t)))
  (is (string= "true"  (f:incl-holds t   nil)))
  (is (string= "false" (f:incl-holds nil nil))))

(test one-only-requires-exactly-one
  (is (string= "false" (f:one-only-holds t   t)))
  (is (string= "true"  (f:one-only-holds t   nil)))
  (is (string= "true"  (f:one-only-holds nil t)))
  (is (string= "false" (f:one-only-holds nil nil))))

(test requires-is-implication-not-equivalence
  ;; R(C2, C1): exempt implies overdue. False only when the antecedent holds and the
  ;; consequent does not -- an implication, which is easy to over-tighten into iff.
  (is (string= "true"  (f:requires-holds t   t))   "both true")
  (is (string= "false" (f:requires-holds nil t))   "exempt but not overdue violates R")
  (is (string= "true"  (f:requires-holds t   nil)) "antecedent false -> vacuously true")
  (is (string= "true"  (f:requires-holds nil nil))))

(test feasibility-rejects-assignments-the-constraints-forbid
  ;; This is what keeps generated test cases physically realizable rather than merely
  ;; logically covering (ADR-0002).
  (is (string= "true"  (f:feasible-under t   t)))
  (is (string= "false" (f:feasible-under nil t)) "R(C2,C1) forbids exempt-and-not-overdue")
  (is (string= "true"  (f:feasible-under t   nil))))

(test counting-true-causes
  (is (= 2 (f:count-true-under t   t)))
  (is (= 1 (f:count-true-under t   nil)))
  (is (= 0 (f:count-true-under nil nil))))

;;; --- masking (M) ----------------------------------------------------------

(test a-true-effect-suppresses-the-effect-it-masks
  ;; M is the only constraint over EFFECTS rather than causes, so it applies after
  ;; evaluation rather than filtering assignments.
  (is (string= "true"  (f:unmasked-effect-under t nil)) "E1 fires")
  (is (string= "false" (f:masked-effect-under   t nil)) "and therefore suppresses E2"))

(test masking-does-nothing-when-the-masking-effect-is-false
  (is (string= "false" (f:unmasked-effect-under nil nil)))
  (is (string= "false" (f:masked-effect-under   nil nil))))

;;; --- structure and traceability -------------------------------------------

(test accessors-round-trip-and-carry-their-requirement
  (is (= 2 f:cause-count))
  (is (= 2 f:effect-count))
  (is (string= "the account is overdue" f:cause-text-of))
  (is (string= "apply a late fee" f:effect-text-of))
  ;; Traceability is a first-class output, not documentation polish: it is what makes
  ;; the coverage claim auditable (ADR-0004).
  (is (string= "REQ-1" f:source-of)))

;;; --- entry point ----------------------------------------------------------

(defun run-tests ()
  "Run the Elenchon suite; return T on success (for `asdf:test-system`).
Named RUN-TESTS, not RUN -- FiveAM already exports RUN."
  (run! 'ceg))
