;;;; tests/fixtures.lisp --- Coalton support for the elenchon/ceg suite.
;;;;
;;;; The CEG ADT is pure Coalton; fiveam is CL. Following the house boundary rule
;;;; (docs/coalton-patterns.md §5, and mnemosyne/tests/entity.lisp as precedent), the
;;;; graphs and the queries over them are built HERE, in Coalton, and exposed to the CL
;;;; suite only through helpers returning **promised** types -- String, Boolean, Integer.
;;;;
;;;; Why that matters more than convenience: `Optional` is a `define-type`, and Coalton
;;;; promises nothing about a define-type's representation across compilation modes
;;;; (coalton-patterns.md §7). A test that reached into an `(Optional Boolean)` from CL
;;;; would pass in development mode and break in release mode -- and the whole point of
;;;; this suite is that `None` (underdetermined) is not `False`.
;;;;
;;;; So tri-state answers cross the boundary as the strings "true" / "false" / "unknown".

(cl:defpackage #:elenchon/tests-fixtures
  (:use #:coalton #:coalton-prelude)
  (:local-nicknames (#:g #:elenchon/ceg))
  (:export
   #:effect-under #:effect-of #:feasible-under #:count-true-under
   #:dangling-ref-result #:masked-effect-under #:unmasked-effect-under
   #:vacuous-conj #:vacuous-disj #:negation-of
   #:excl-holds #:incl-holds #:one-only-holds #:requires-holds
   #:cause-text-of #:effect-text-of #:source-of #:node-name-of
   #:effect-count #:cause-count #:shared-node-drives-both
   #:effect-of-partial #:count-true-partial))
(cl:in-package #:elenchon/tests-fixtures)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  ;;; --- tri-state at the boundary -------------------------------------------

  (declare tri ((Optional Boolean) -> String))
  (define (tri o)
    "Render an (Optional Boolean) as a promised String. `unknown` is the interesting
case: it means the graph does not determine the value -- an unassigned cause or a
dangling Ref -- which is a requirement defect, not a false."
    (match o
      ((None) "unknown")
      ((Some b) (if b "true" "false"))))

  ;;; --- the canonical requirement -------------------------------------------
  ;;; "If the account is overdue AND the customer is not exempt, apply a late fee and
  ;;;  send a notice."  C1 = overdue, C2 = exempt, E1 = late fee, E2 = notice.
  ;;; N1 is the shared condition BOTH effects hang off -- the ADR-0001 DAG, exercised.

  (declare c1 g:CauseId)
  (define c1 (g:CauseId "C1"))
  (declare c2 g:CauseId)
  (define c2 (g:CauseId "C2"))
  (declare n1 g:NodeId)
  (define n1 (g:NodeId "N1"))
  (declare req g:ReqId)
  (define req (g:ReqId "REQ-1"))

  (declare late-fee g:Ceg)
  (define late-fee
    (g:Ceg
     (make-list (g:Cause c1 "the account is overdue" (Some req))
                (g:Cause c2 "the customer is exempt" (Some req)))
     (make-list (g:Node n1 (g:Conj (make-list (g:Lit c1) (g:Neg (g:Lit c2))))))
     (make-list (g:Effect (g:EffectId "E1") "apply a late fee" (Some req) (g:Ref n1))
                (g:Effect (g:EffectId "E2") "send a notice" (Some req) (g:Ref n1)))
     (make-list (g:Requires c2 c1))))

  (declare assign (Boolean * Boolean -> g:Assignment))
  (define (assign overdue exempt)
    (g:Assignment (make-list (Tuple c1 overdue) (Tuple c2 exempt))))

  ;;; --- effect evaluation ----------------------------------------------------

  (declare nth-effect ((List (Tuple g:EffectId (Optional Boolean))) * Integer
                       -> (Optional Boolean)))
  (define (nth-effect vs i)
    (match vs
      ((Nil) None)
      ((Cons v rest)
       (if (== i 0)
           (match v ((Tuple _ b) b))
           (nth-effect rest (- i 1))))))

  (declare effect-under (Integer * Boolean * Boolean -> String))
  (define (effect-under i overdue exempt)
    "Effect I (0 = E1 late fee, 1 = E2 notice) under the given cause assignment."
    (tri (nth-effect (g:eval-effects late-fee (assign overdue exempt)) i)))

  (declare effect-of (Boolean * Boolean -> String))
  (define (effect-of overdue exempt) (effect-under 0 overdue exempt))

  (declare shared-node-drives-both (Boolean * Boolean -> Boolean))
  (define (shared-node-drives-both overdue exempt)
    "Both effects reference the SAME node N1, so they must always agree. If a future
change duplicates the subexpression instead of sharing it, this is what notices."
    (== (effect-under 0 overdue exempt) (effect-under 1 overdue exempt)))

  ;;; --- underdetermination ---------------------------------------------------

  (declare partial-assignment g:Assignment)
  (define partial-assignment (g:Assignment (make-list (Tuple c1 True))))

  (declare effect-of-partial String)
  (define effect-of-partial
    (tri (nth-effect (g:eval-effects late-fee partial-assignment) 0)))

  (declare dangling-ref-result String)
  (define dangling-ref-result
    "A Ref to a node that does not exist. Newly expressible under the ADR-0001 DAG, and
it must evaluate to `unknown` -- a defect to report -- never to false."
    (tri (g:eval-expr late-fee (assign True False) (g:Ref (g:NodeId "NOPE")))))

  ;;; --- boolean operators, including vacuity ---------------------------------

  (declare vacuous-conj String)
  (define vacuous-conj
    (tri (g:eval-expr late-fee (assign True False) (g:Conj Nil))))

  (declare vacuous-disj String)
  (define vacuous-disj
    (tri (g:eval-expr late-fee (assign True False) (g:Disj Nil))))

  (declare negation-of (Boolean -> String))
  (define (negation-of overdue)
    (tri (g:eval-expr late-fee (assign overdue False) (g:Neg (g:Lit c1)))))

  ;;; --- masking (M) ----------------------------------------------------------
  ;;; Same two effects, but E1 true now SUPPRESSES E2.

  (declare masking g:Ceg)
  (define masking
    (g:Ceg
     (make-list (g:Cause c1 "the account is overdue" (Some req))
                (g:Cause c2 "the customer is exempt" (Some req)))
     (make-list (g:Node n1 (g:Conj (make-list (g:Lit c1) (g:Neg (g:Lit c2))))))
     (make-list (g:Effect (g:EffectId "E1") "apply a late fee" (Some req) (g:Ref n1))
                (g:Effect (g:EffectId "E2") "send a notice" (Some req) (g:Ref n1)))
     (make-list (g:Masks (g:EffectId "E1") (g:EffectId "E2")))))

  (declare masked-effect-under (Boolean * Boolean -> String))
  (define (masked-effect-under overdue exempt)
    "E2, which E1 masks."
    (tri (nth-effect (g:eval-effects masking (assign overdue exempt)) 1)))

  (declare unmasked-effect-under (Boolean * Boolean -> String))
  (define (unmasked-effect-under overdue exempt)
    "E1, the masking effect, which is itself unaffected."
    (tri (nth-effect (g:eval-effects masking (assign overdue exempt)) 0)))

  ;;; --- constraints ----------------------------------------------------------

  (declare holds (g:Constraint * Boolean * Boolean -> String))
  (define (holds k overdue exempt)
    (tri (g:constraint-holds (assign overdue exempt) k)))

  (declare both (List g:CauseId))
  (define both (make-list c1 c2))

  (declare excl-holds (Boolean * Boolean -> String))
  (define (excl-holds a b) (holds (g:Excl both) a b))
  (declare incl-holds (Boolean * Boolean -> String))
  (define (incl-holds a b) (holds (g:Incl both) a b))
  (declare one-only-holds (Boolean * Boolean -> String))
  (define (one-only-holds a b) (holds (g:OneOnly both) a b))
  (declare requires-holds (Boolean * Boolean -> String))
  (define (requires-holds a b) (holds (g:Requires c2 c1) a b))

  (declare feasible-under (Boolean * Boolean -> String))
  (define (feasible-under overdue exempt)
    (tri (g:feasible? late-fee (assign overdue exempt))))

  (declare count-true-under (Boolean * Boolean -> Integer))
  (define (count-true-under overdue exempt)
    "How many of C1/C2 are true. -1 encodes `unknown`, which cannot arise here since
both are bound -- the unbound case is covered by COUNT-TRUE-PARTIAL below."
    (match (g:count-true (assign overdue exempt) both)
      ((Some n) n)
      ((None) -1)))

  (declare count-true-partial Integer)
  (define count-true-partial
    (match (g:count-true partial-assignment both)
      ((Some n) n)
      ((None) -1)))

  ;;; --- accessors and traceability -------------------------------------------

  (declare first-cause (Unit -> (Optional g:Cause)))
  (define (first-cause _)
    (match (g:ceg-causes late-fee) ((Cons c _) (Some c)) ((Nil) None)))

  (declare cause-text-of String)
  (define cause-text-of
    (match (first-cause Unit) ((Some c) (g:cause-text c)) ((None) "")))

  (declare source-of String)
  (define source-of
    "The traceability anchor: every cause carries the requirement it came from."
    (match (first-cause Unit)
      ((Some c) (match (g:cause-source c)
                  ((Some r) (g:req-id-name r))
                  ((None) "")))
      ((None) "")))

  (declare effect-text-of String)
  (define effect-text-of
    (match (g:ceg-effects late-fee) ((Cons e _) (g:effect-text e)) ((Nil) "")))

  (declare node-name-of String)
  (define node-name-of
    (match (g:ceg-nodes late-fee) ((Cons n _) (g:node-id-name (g:node-id n))) ((Nil) "")))

  (declare len ((List :a) -> Integer))
  (define (len xs)
    (match xs
      ((Nil) 0)
      ((Cons _ rest) (+ 1 (len rest)))))

  (declare cause-count Integer)
  (define cause-count (len (g:ceg-causes late-fee)))

  (declare effect-count Integer)
  (define effect-count (len (g:ceg-effects late-fee))))
