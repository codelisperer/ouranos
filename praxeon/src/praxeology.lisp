;;;; praxeology.lisp --- the typed core ontology of Praxeon, in Coalton
;;;;
;;;; This file describes what an agent *is*, borrowing its vocabulary from
;;;; praxeology (von Mises). An actor pursues ENDS; it applies MEANS; the
;;;; application of a means toward an end is an ACTION; an ordered bundle of
;;;; actions is a PLAN. Effects (actually running a means) live in the dynamic
;;;; CL shell -- Coalton describes the ontology, CL performs the IO.
;;;;
;;;; NOTE: this is a starting skeleton. Load it in a REPL with Coalton present
;;;; and iterate; type errors here are a feature, not a bug.

(cl:in-package #:praxeon/praxeology)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  ;;; --------------------------------------------------------------------------
  ;;; Ends: the states of affairs an actor seeks to bring about.
  ;;; --------------------------------------------------------------------------
  (define-type End
    "A goal an actor seeks to realize, described in natural language."
    (End String))

  (declare end-description (End -> String))
  (define (end-description e)
    (match e
      ((End d) d)))

  ;;; --------------------------------------------------------------------------
  ;;; Means: the instruments (tools) an actor may employ. Here a means is
  ;;; identified by name and description; its *effect* is supplied by the CL
  ;;; shell, which owns IO and the condition system.
  ;;; --------------------------------------------------------------------------
  (define-type Means
    "An instrument an actor may employ: a name and a description."
    (Means String String))

  (declare means-name (Means -> String))
  (define (means-name m)
    (match m
      ((Means n _) n)))

  (declare means-description (Means -> String))
  (define (means-description m)
    (match m
      ((Means _ d) d)))

  ;;; --------------------------------------------------------------------------
  ;;; Action: applying a means toward an end, with an argument.
  ;;; --------------------------------------------------------------------------
  (define-type Action
    "The application of a Means toward an End, with a textual argument."
    (Action Means End String))

  (declare action-means (Action -> Means))
  (define (action-means x)
    (match x
      ((Action m _ _) m)))

  (declare action-end (Action -> End))
  (define (action-end x)
    (match x
      ((Action _ e _) e)))

  (declare action-argument (Action -> String))
  (define (action-argument x)
    (match x
      ((Action _ _ arg) arg)))

  ;;; --------------------------------------------------------------------------
  ;;; Plan: an ordered bundle of actions.
  ;;; --------------------------------------------------------------------------
  (define-type Plan
    "An ordered sequence of actions intended to realize an end."
    (Plan (List Action)))

  (declare plan-actions (Plan -> (List Action)))
  (define (plan-actions p)
    (match p
      ((Plan as) as)))

  (declare plan-length (Plan -> UFix))
  (define (plan-length p)
    (length (plan-actions p)))

  ;;; --------------------------------------------------------------------------
  ;;; Actor: an agent -- a name and the means available to it.
  ;;; --------------------------------------------------------------------------
  (define-type Actor
    "An agent: a name together with the means available to it."
    (Actor String (List Means)))

  (declare actor-name (Actor -> String))
  (define (actor-name x)
    (match x
      ((Actor n _) n)))

  (declare actor-means (Actor -> (List Means)))
  (define (actor-means x)
    (match x
      ((Actor _ ms) ms)))

  ;;; --------------------------------------------------------------------------
  ;;; Preference: praxeology insists action ranks ends. `Valued` lets an actor
  ;;; impute a scalar value to a thing (an end, a plan) so that competing
  ;;; options can be ordered. Instances belong downstream; this is the hook.
  ;;; --------------------------------------------------------------------------
  (define-class (Valued :a)
    (value (:a -> Integer))))
