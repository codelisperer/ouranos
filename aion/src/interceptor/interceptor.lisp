;;;; interceptor.lisp --- a typed, protocol-agnostic interceptor pipeline (Coalton).
;;;;
;;;; Pedestal's insight -- middleware is just part of the request->response cycle --
;;;; made a compile-time-checked *value*. An INTERCEPTOR is a named pair of stage
;;;; functions over a context :c: `enter` on the way in (forward), `leave` on the
;;;; way out (reverse). `execute` runs a chain, threading the context and
;;;; short-circuiting via the FLOW ADT (Proceed | Halt | Failure).
;;;;
;;;; What this shows off about Coalton (and why it matters for AI-driven CL dev):
;;;;   - PARAMETRIC over :c -- one compiled `execute` provably works for ANY
;;;;     context: an HTTP {request,response} or an agent {perception,plan,budget}.
;;;;     The polymorphic type IS the proof; there is no protocol-specific pipeline.
;;;;   - The FLOW ADT + exhaustive `match` mean the compiler rejects a chain that
;;;;     forgets an outcome. A whole class of "wired it wrong" bugs can't compile,
;;;;     so an AI (or a human) reasoning about a pipeline has real guardrails.
;;;;   - Constructors are first-class functions (`Proceed` doubles as the identity
;;;;     leave stage) -- concise, and again type-checked.
;;;;
;;;; NB: this is the PURE core. How genuinely effectful stages (read a DB, sign a
;;;; JWT, call an LLM) reconcile with the pure pipeline is the biggest open
;;;; question -- see docs/interceptors-design.md. First integration: effects at the
;;;; CL edge around a pure run.

(cl:in-package #:aion/interceptor)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  ;;; --- Flow: the outcome of a stage, parametric over the context :c --------
  (define-type (Flow :c)
    "The result of an interceptor stage over a context of type :c."
    (Proceed :c)       ; proceed with this context
    (Halt :c)           ; short-circuit: stop entering; unwind `leave` now
    (Failure String :c))   ; error: a message + the context at the point of failure

  (declare flow-context ((Flow :c) -> :c))
  (define (flow-context f)
    "The context carried by a FLOW, whatever the outcome."
    (match f
      ((Proceed c) c)
      ((Halt c) c)
      ((Failure _ c) c)))

  ;;; --- Interceptor: a named pair of stage functions over :c ---------------
  (define-type (Interceptor :c)
    "A pipeline stage: a name, an `enter` (forward) and a `leave` (reverse)
function, each a context -> Flow."
    (Interceptor String (:c -> (Flow :c)) (:c -> (Flow :c))))

  (declare name ((Interceptor :c) -> String))
  (define (name i) (match i ((Interceptor n _ _) n)))

  (declare enter-of ((Interceptor :c) -> (:c -> (Flow :c))))
  (define (enter-of i) (match i ((Interceptor _ e _) e)))

  (declare leave-of ((Interceptor :c) -> (:c -> (Flow :c))))
  (define (leave-of i) (match i ((Interceptor _ _ l) l)))

  ;;; --- Constructors -------------------------------------------------------
  ;; The `Interceptor` constructor IS the 3-arg constructor function
  ;; (name, enter, leave) -- use it directly. (No lowercase `interceptor` helper:
  ;; Coalton is case-insensitive, so it would collide with the constructor.)

  ;; enter-only / leave-only: the missing side is `Proceed` -- the constructor
  ;; itself, used as an identity stage (a nice bit of Coalton: it IS a function).
  (declare on-enter (String * (:c -> (Flow :c)) -> (Interceptor :c)))
  (define (on-enter n e) (Interceptor n e Proceed))

  (declare on-leave (String * (:c -> (Flow :c)) -> (Interceptor :c)))
  (define (on-leave n l) (Interceptor n Proceed l))

  ;;; --- The runner ---------------------------------------------------------
  ;; enter phase: fold `enter` forward, short-circuiting on Halt/Failure, remembering
  ;; the interceptors that ran (head = most recently entered) for the leave phase.
  (declare %enter ((List (Interceptor :c)) * (List (Interceptor :c)) * :c
                   -> (Tuple (List (Interceptor :c)) (Flow :c))))
  (define (%enter chain done ctx)
    (match chain
      ((Nil) (Tuple done (Proceed ctx)))
      ((Cons i rest)
       (let ((done* (Cons i done)))
         (match ((enter-of i) ctx)
           ((Proceed c) (%enter rest done* c))
           ((Halt c) (Tuple done* (Halt c)))
           ((Failure m c) (Tuple done* (Failure m c))))))))

  ;; leave phase: run `leave` over the done-stack (already reverse of enter order),
  ;; threading the context.
  (declare %leave ((List (Interceptor :c)) * :c -> :c))
  (define (%leave done ctx)
    (match done
      ((Nil) ctx)
      ((Cons i rest) (%leave rest (flow-context ((leave-of i) ctx))))))

  ;; execute: run the chain enter-then-leave. The returned FLOW reports the
  ;; outcome (Proceed/Halt/Failure) and carries the final, leave-applied context.
  (declare execute ((List (Interceptor :c)) * :c -> (Flow :c)))
  (define (execute chain ctx)
    (match (%enter chain Nil ctx)
      ((Tuple done flow)
       (let ((final (%leave done (flow-context flow))))
         (match flow
           ((Proceed _) (Proceed final))
           ((Halt _) (Halt final))
           ((Failure m _) (Failure m final)))))))

  ;; execute-effect: the "effects at the edge" driver. Run `enter` forward; if it
  ;; Proceeds, perform EFFECT -- the single impure pivot supplied by the CL shell
  ;; (an LLM turn, a DB write, a network round-trip) -- then unwind `leave`. A
  ;; Halt/Failure in `enter` SKIPS the effect and still unwinds leave (a guard that
  ;; rejects the request must not spend the effect). The pipeline stays pure: the
  ;; effect is a parameter, so the very same chain runs pure (execute) or effectful
  ;; (execute-effect). This is BOTH shapes at once -- the server handler and the
  ;; client round-trip are each just "where the middle is."
  (declare execute-effect ((List (Interceptor :c)) * (:c -> :c) * :c -> (Flow :c)))
  (define (execute-effect chain effect ctx)
    (match (%enter chain Nil ctx)
      ((Tuple done flow)
       (match flow
         ((Proceed c) (Proceed (%leave done (effect c))))
         ((Halt c) (Halt (%leave done c)))
         ((Failure m c) (Failure m (%leave done c)))))))

  ;;; --- self-check (internal; moves to proper Coalton tests later) ---------
  ;; A trivial Integer "context" proves the mechanics; parametricity is proven by
  ;; execute's type, not by an example.
  (declare %demo-chain (List (Interceptor Integer)))
  (define %demo-chain
    (Cons (on-enter "add10"  (fn (c) (Proceed (+ c 10))))
      (Cons (on-enter "double" (fn (c) (Proceed (* c 2))))
        (Cons (on-enter "cap"  (fn (c) (if (> c 100) (Halt c) (Proceed c))))
          Nil))))

  (declare %demo-value (Integer -> Integer))
  (define (%demo-value n) (flow-context (execute %demo-chain n)))

  (declare %demo-halted? (Integer -> Boolean))
  (define (%demo-halted? n)
    (match (execute %demo-chain n) ((Halt _) True) (_ False)))

  ;; effects-at-the-edge: the same %demo-chain, but with an edge EFFECT (+1000)
  ;; performed between enter and leave. A Halt in enter (cap, when n grows past 100)
  ;; must SKIP the effect -- so a halted run is the pure enter result, NOT +1000.
  (declare %demo-effect-value (Integer -> Integer))
  (define (%demo-effect-value n)
    (flow-context (execute-effect %demo-chain (fn (c) (+ c 1000)) n))))
