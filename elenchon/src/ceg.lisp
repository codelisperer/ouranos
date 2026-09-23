;;;; ceg.lisp --- the typed Cause-Effect Graph ADT (Coalton). Elenchon's spine.
;;;;
;;;; Everything binds to this type: the CEG-building API constructs it, the reasoning
;;;; system solves it, the renderers read it, the defect report walks it. Per ADR-0001
;;;; the representation is an EXPRESSION DAG -- a boolean expression per effect, with
;;;; `Ref` naming a shared intermediate node -- not an explicit node/edge graph. The
;;;; classic node diagram is a *derived view* over this (see docs/adr/0001).
;;;;
;;;; Pure logic only, per the house rule: no IO in Coalton. The CL shell
;;;; (elenchon/build, elenchon/report) constructs and reads these values.
;;;;
;;;; Vocabulary is fixed by docs/method.md -- causes, effects, the E/I/O/R/M
;;;; constraint letters, functional variation, decision table. Prefer those terms over
;;;; ad-hoc node/rule/case language.
;;;;
;;;; Naming note (Coalton is case-insensitive, and the prelude owns `and`/`or`/`not`):
;;;; the boolean constructors are `Conj`/`Disj`/`Neg`, never And/Or/Not.

(cl:in-package #:elenchon/ceg)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  ;;; --- identifiers ---------------------------------------------------------
  ;;; Distinct newtypes rather than bare String: passing an EffectId where a CauseId
  ;;; belongs is exactly the class of wiring bug the typed core exists to reject.

  (define-type ReqId
    "The requirement a cause or effect was extracted from -- the traceability anchor.
Per ADR-0004 every cause and effect carries one, so a generated test case can always
be traced back to the prose it came from."
    (ReqId String))

  (declare req-id-name (ReqId -> String))
  (define (req-id-name r)
    (match r ((ReqId s) s)))

  (define-type CauseId
    "The identifier of a cause (an input condition), unique within a CEG."
    (CauseId String))

  (declare cause-id-name (CauseId -> String))
  (define (cause-id-name c)
    (match c ((CauseId s) s)))

  (define-instance (Eq CauseId)
    (define (== a b) (== (cause-id-name a) (cause-id-name b))))

  (define-type EffectId
    "The identifier of an effect (an output condition), unique within a CEG."
    (EffectId String))

  (declare effect-id-name (EffectId -> String))
  (define (effect-id-name e)
    (match e ((EffectId s) s)))

  (define-instance (Eq EffectId)
    (define (== a b) (== (effect-id-name a) (effect-id-name b))))

  (define-type NodeId
    "The identifier of a named intermediate node -- a boolean subexpression shared by
more than one effect, addressable so the derived diagram and the defect report can
refer to it."
    (NodeId String))

  (declare node-id-name (NodeId -> String))
  (define (node-id-name n)
    (match n ((NodeId s) s)))

  (define-instance (Eq NodeId)
    (define (== a b) (== (node-id-name a) (node-id-name b))))

  ;;; --- boolean wiring ------------------------------------------------------

  (define-type Expr
    "A boolean expression over causes: the wiring from causes to one effect.
`Ref` is what makes this a DAG rather than a tree -- it names a shared intermediate
node instead of duplicating its subexpression, which preserves both traceability and
the solver's ability to reason about a condition once."
    (Lit CauseId)          ; a cause, taken at its truth value
    (Ref NodeId)           ; a named intermediate node, resolved via the CEG's node table
    (Neg Expr)             ; NOT
    (Conj (List Expr))     ; AND  (n-ary: an empty Conj is vacuously true)
    (Disj (List Expr)))    ; OR   (n-ary: an empty Disj is vacuously false)

  (define-type Node
    "A named intermediate node: an identifier bound to a shared subexpression."
    (Node NodeId Expr))

  (declare node-id (Node -> NodeId))
  (define (node-id n)
    (match n ((Node i _) i)))

  (declare node-expr (Node -> Expr))
  (define (node-expr n)
    (match n ((Node _ e) e)))

  ;;; --- causes and effects --------------------------------------------------

  (define-type Cause
    "An input condition, stated as a yes/no proposition, traced to its requirement.
Anything that cannot be phrased as yes/no is a requirement DEFECT, reported rather
than guessed around -- it never reaches this type."
    (Cause CauseId String (Optional ReqId)))

  (declare cause-id (Cause -> CauseId))
  (define (cause-id c)
    (match c ((Cause i _ _) i)))

  (declare cause-text (Cause -> String))
  (define (cause-text c)
    (match c ((Cause _ s _) s)))

  (declare cause-source (Cause -> (Optional ReqId)))
  (define (cause-source c)
    (match c ((Cause _ _ r) r)))

  (define-type Effect
    "An output condition, together with the boolean expression over causes that drives
it. Holding the expression on the effect is the ADR-0001 representation: one rooted
expression per effect, sharing via `Ref`."
    (Effect EffectId String (Optional ReqId) Expr))

  (declare effect-id (Effect -> EffectId))
  (define (effect-id e)
    (match e ((Effect i _ _ _) i)))

  (declare effect-text (Effect -> String))
  (define (effect-text e)
    (match e ((Effect _ s _ _) s)))

  (declare effect-source (Effect -> (Optional ReqId)))
  (define (effect-source e)
    (match e ((Effect _ _ r _) r)))

  (declare effect-expr (Effect -> Expr))
  (define (effect-expr e)
    (match e ((Effect _ _ _ x) x)))

  ;;; --- constraints ---------------------------------------------------------

  (define-type Constraint
    "The classic RBT constraint vocabulary (docs/method.md). E/I/O/R constrain which
cause assignments are POSSIBLE; M constrains which effects are OBSERVABLE."
    (Excl (List CauseId))         ; E -- exclusive: at most one true
    (Incl (List CauseId))         ; I -- inclusive: at least one true
    (OneOnly (List CauseId))      ; O -- one and only one true
    (Requires CauseId CauseId)    ; R -- first true implies second true
    (Masks EffectId EffectId))    ; M -- first effect true suppresses the second

  ;;; --- the graph -----------------------------------------------------------

  (define-type Ceg
    "A Cause-Effect Graph: causes, named intermediate nodes, effects, constraints.
The whole formal object. Everything upstream feeds it; everything downstream reads it."
    (Ceg (List Cause) (List Node) (List Effect) (List Constraint)))

  (declare ceg-causes (Ceg -> (List Cause)))
  (define (ceg-causes g)
    (match g ((Ceg cs _ _ _) cs)))

  (declare ceg-nodes (Ceg -> (List Node)))
  (define (ceg-nodes g)
    (match g ((Ceg _ ns _ _) ns)))

  (declare ceg-effects (Ceg -> (List Effect)))
  (define (ceg-effects g)
    (match g ((Ceg _ _ es _) es)))

  (declare ceg-constraints (Ceg -> (List Constraint)))
  (define (ceg-constraints g)
    (match g ((Ceg _ _ _ ks) ks)))

  ;;; --- assignments ---------------------------------------------------------

  (define-type Assignment
    "A truth assignment over causes -- one column of the decision table under
construction. PARTIAL by design: a cause with no binding evaluates to `None`, which is
how an incomplete graph reports itself instead of silently defaulting to false."
    (Assignment (List (Tuple CauseId Boolean))))

  (declare assignment-bindings (Assignment -> (List (Tuple CauseId Boolean))))
  (define (assignment-bindings a)
    (match a ((Assignment bs) bs)))

  (declare assignment-lookup (Assignment * CauseId -> (Optional Boolean)))
  (define (assignment-lookup a c)
    "The truth value bound to cause C, or None if C is unassigned."
    (lookup-binding (assignment-bindings a) c))

  (declare lookup-binding ((List (Tuple CauseId Boolean)) * CauseId -> (Optional Boolean)))
  (define (lookup-binding bs c)
    (match bs
      ((Nil) None)
      ((Cons b rest)
       (match b
         ((Tuple k v) (if (== k c) (Some v) (lookup-binding rest c)))))))

  ;;; --- evaluation ----------------------------------------------------------
  ;;; Every evaluator is TOTAL and returns (Optional Boolean): None means "the graph
  ;;; does not determine this" -- an unassigned cause or a dangling Ref. Those are
  ;;; precisely the requirement defects the report exists to surface (ADR-0004), so
  ;;; they are represented, never defaulted.

  (declare eval-expr (Ceg * Assignment * Expr -> (Optional Boolean)))
  (define (eval-expr g a x)
    "Evaluate expression X under assignment A, resolving `Ref`s in G's node table."
    (match x
      ((Lit c) (assignment-lookup a c))
      ((Ref n)
       (match (find-node (ceg-nodes g) n)
         ((None) None)                                  ; dangling reference: a defect
         ((Some nd) (eval-expr g a (node-expr nd)))))
      ((Neg e)
       (match (eval-expr g a e)
         ((None) None)
         ((Some v) (Some (not v)))))
      ((Conj es) (eval-conj g a es))
      ((Disj es) (eval-disj g a es))))

  (declare eval-conj (Ceg * Assignment * (List Expr) -> (Optional Boolean)))
  (define (eval-conj g a es)
    (match es
      ((Nil) (Some True))                               ; empty AND is vacuously true
      ((Cons e rest)
       (match (eval-expr g a e)
         ((None) None)
         ((Some v)
          (match (eval-conj g a rest)
            ((None) None)
            ((Some w) (Some (if v w False)))))))))

  (declare eval-disj (Ceg * Assignment * (List Expr) -> (Optional Boolean)))
  (define (eval-disj g a es)
    (match es
      ((Nil) (Some False))                              ; empty OR is vacuously false
      ((Cons e rest)
       (match (eval-expr g a e)
         ((None) None)
         ((Some v)
          (match (eval-disj g a rest)
            ((None) None)
            ((Some w) (Some (if v True w)))))))))

  (declare find-node ((List Node) * NodeId -> (Optional Node)))
  (define (find-node ns n)
    (match ns
      ((Nil) None)
      ((Cons nd rest) (if (== (node-id nd) n) (Some nd) (find-node rest n)))))

  ;;; --- effect evaluation, with masking -------------------------------------

  (declare eval-effects (Ceg * Assignment -> (List (Tuple EffectId (Optional Boolean)))))
  (define (eval-effects g a)
    "Every effect's value under A, with M (masks) constraints applied. This is the
`effects` half of one functional variation -- one column of the decision table."
    (apply-masks (ceg-constraints g)
                 (map-effects g a (ceg-effects g))))

  (declare map-effects (Ceg * Assignment * (List Effect)
                        -> (List (Tuple EffectId (Optional Boolean)))))
  (define (map-effects g a es)
    (match es
      ((Nil) Nil)
      ((Cons e rest)
       (Cons (Tuple (effect-id e) (eval-expr g a (effect-expr e)))
             (map-effects g a rest)))))

  (declare apply-masks ((List Constraint) * (List (Tuple EffectId (Optional Boolean)))
                        -> (List (Tuple EffectId (Optional Boolean)))))
  (define (apply-masks ks vs)
    "Apply every M constraint: where the masking effect is true, force the masked
effect false. Order-independent -- a masked effect can itself mask another only
through a further pass, which a well-formed CEG should not require."
    (match ks
      ((Nil) vs)
      ((Cons k rest)
       (match k
         ((Masks a b)
          (apply-masks rest
                       (if (== (lookup-effect vs a) (Some True))
                           (force-effect vs b False)
                           vs)))
         (_ (apply-masks rest vs))))))

  (declare lookup-effect ((List (Tuple EffectId (Optional Boolean))) * EffectId
                          -> (Optional Boolean)))
  (define (lookup-effect vs e)
    (match vs
      ((Nil) None)
      ((Cons v rest)
       (match v
         ((Tuple k b) (if (== k e) b (lookup-effect rest e)))))))

  (declare force-effect ((List (Tuple EffectId (Optional Boolean))) * EffectId * Boolean
                         -> (List (Tuple EffectId (Optional Boolean)))))
  (define (force-effect vs e b)
    (match vs
      ((Nil) Nil)
      ((Cons v rest)
       (match v
         ((Tuple k old)
          (if (== k e)
              (Cons (Tuple k (Some b)) (force-effect rest e b))
              (Cons (Tuple k old) (force-effect rest e b))))))))

  ;;; --- constraint satisfaction ---------------------------------------------
  ;;; E/I/O/R rule out impossible cause assignments; the solver consults these before
  ;;; ever proposing a test case, which is what keeps generated tests physically
  ;;; realizable rather than merely logically covering.

  (declare constraint-holds (Assignment * Constraint -> (Optional Boolean)))
  (define (constraint-holds a k)
    "Does assignment A satisfy constraint K? None if A does not bind every cause K
mentions. M constrains effects, not causes, so it holds vacuously here (see
`eval-effects`, which applies it)."
    (match k
      ((Excl cs)
       (match (count-true a cs) ((None) None) ((Some n) (Some (<= n 1)))))
      ((Incl cs)
       (match (count-true a cs) ((None) None) ((Some n) (Some (>= n 1)))))
      ((OneOnly cs)
       (match (count-true a cs) ((None) None) ((Some n) (Some (== n 1)))))
      ((Requires p q)
       (match (Tuple (assignment-lookup a p) (assignment-lookup a q))
         ((Tuple (Some vp) (Some vq)) (Some (if vp vq True)))
         (_ None)))
      ((Masks _ _) (Some True))))

  (declare count-true (Assignment * (List CauseId) -> (Optional Integer)))
  (define (count-true a cs)
    "How many of CS are true under A; None if any of them is unassigned."
    (match cs
      ((Nil) (Some 0))
      ((Cons c rest)
       (match (assignment-lookup a c)
         ((None) None)
         ((Some v)
          (match (count-true a rest)
            ((None) None)
            ((Some n) (Some (if v (+ n 1) n)))))))))

  (declare feasible? (Ceg * Assignment -> (Optional Boolean)))
  (define (feasible? g a)
    "Is A a physically realizable assignment -- does it satisfy every E/I/O/R
constraint? None if the assignment is too partial to tell."
    (all-hold a (ceg-constraints g)))

  (declare all-hold (Assignment * (List Constraint) -> (Optional Boolean)))
  (define (all-hold a ks)
    (match ks
      ((Nil) (Some True))
      ((Cons k rest)
       (match (constraint-holds a k)
         ((None) None)
         ((Some v)
          (match (all-hold a rest)
            ((None) None)
            ((Some w) (Some (if v w False))))))))))
