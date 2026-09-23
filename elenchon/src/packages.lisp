;;;; packages.lisp --- Elenchon package definitions.
;;;;
;;;; Package-per-module; :local-nicknames over long prefixes. As the library grows,
;;;; expect packages tracking the CEG engine + reasoning system (see docs/method.md):
;;;;   elenchon/ceg        -- the typed Cause-Effect Graph ADT (causes, effects,
;;;;                          AND/OR/NOT, and the E/I/O/R/M constraints)  [Coalton]
;;;;   elenchon/reason     -- the reasoning system over a CEG: minimal high-coverage
;;;;                          decision table (relational solver; miniKanren a
;;;;                          candidate)                                  [Coalton]
;;;;   elenchon/cases      -- decision table -> functional test cases + traceability
;;;;   elenchon/report     -- dangling/contradictory/non-propositional findings
;;;;   elenchon/build      -- the API for *constructing* a CEG from structured
;;;;                          causes/effects/constraints (what an agentic consumer
;;;;                          like praxeon/ChatRBT calls)                 [CL]
;;;;   elenchon/cl         -- the pure-CL face
;;;; NOTE: there is no NL->CEG extraction package here. Translating human prose to a
;;;; CEG is an agentic function ABOVE Elenchon (praxeon/ChatRBT); Elenchon's input
;;;; is a *structured* CEG. Elenchon never depends on praxeon/hyperion.

(cl:defpackage #:elenchon
  (:use #:cl)
  (:documentation
   "Elenchon: Requirements-Based Testing via Cause-Effect Graphs (Bender RBT lineage).")
  (:export #:version))

;;; --- elenchon/ceg --- the typed Cause-Effect Graph ADT (Coalton) -----------
;;; The spine: the CEG-building API constructs it, the reasoning system solves it, the
;;; renderers read it, the defect report walks it. Representation per ADR-0001 -- an
;;; expression DAG (one rooted boolean expression per effect, sharing via `Ref`), with
;;; the classic node diagram derived from it. Pure logic; no IO (house rule).

(cl:defpackage #:elenchon/ceg
  (:use #:coalton #:coalton-prelude)
  (:documentation
   "The typed Cause-Effect Graph ADT and its pure evaluation semantics: causes,
effects, the boolean wiring (Conj/Disj/Neg -- Coalton's prelude owns and/or/not), the
E/I/O/R/M constraints, and total evaluators that return (Optional Boolean) so an
underdetermined graph reports itself rather than defaulting to false.")
  (:export
   ;; identifiers
   #:ReqId #:req-id-name
   #:CauseId #:cause-id-name
   #:EffectId #:effect-id-name
   #:NodeId #:node-id-name
   ;; boolean wiring
   #:Expr #:Lit #:Ref #:Neg #:Conj #:Disj
   #:Node #:node-id #:node-expr
   ;; causes and effects
   #:Cause #:cause-id #:cause-text #:cause-source
   #:Effect #:effect-id #:effect-text #:effect-source #:effect-expr
   ;; constraints
   #:Constraint #:Excl #:Incl #:OneOnly #:Requires #:Masks
   ;; the graph
   #:Ceg #:ceg-causes #:ceg-nodes #:ceg-effects #:ceg-constraints
   ;; assignments and evaluation
   #:Assignment #:assignment-bindings #:assignment-lookup
   #:eval-expr #:eval-effects
   #:constraint-holds #:count-true #:feasible?))
