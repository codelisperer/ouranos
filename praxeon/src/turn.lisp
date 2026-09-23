;;;; turn.lisp --- one agent turn, as a value a pipeline can operate on (#130).
;;;;
;;;; `hyperion` has had a typed interceptor pipeline since before praxeon needed one, and
;;;; it is now `aion/interceptor` (#177) precisely so an agent framework can reach it. What
;;;; was missing was never the pipeline -- it was a CONTEXT for it to be a pipeline OVER.
;;;; `execute` threads a `:c`; praxeon had no `:c`, so the composition collapsed into a
;;;; `let*` in the flagship example, and said so in its own docstring:
;;;;
;;;;   "This is the interceptor 'edge effect' composed in CL: translate-in -> run-turn ->
;;;;    translate-out, with the crisis check as the leave stage"
;;;;
;;;; A `let*` cannot be reordered, inspected or reused, and its stages cannot short-circuit
;;;; -- which is why Elise's crisis guardrail is an `if` at the bottom that APPENDS a note
;;;; to whatever the model already said, rather than a stage that can replace it. That is
;;;; the one thing a safety guardrail most wants to do.
;;;;
;;;; TURN IS THAT MISSING CONTEXT.
;;;;
;;;; WHAT GOES IN IT, AND WHAT DOES NOT. Everything here is a promised representation --
;;;; String and Boolean -- because CL must never construct or destructure a Coalton
;;;; `define-type` value (docs/coalton-patterns.md §7). The agent, the provider and the
;;;; history are CLOS/CL objects and stay on the CL side; the turn carries only the data
;;;; the stages reason about. The effect closure already closes over the agent.
;;;;
;;;; WHY `halted` IS A FIELD RATHER THAN JUST A `Flow`. The pipeline reports Proceed/Halt,
;;;; but reading that from CL means matching on the ADT, and running the chain twice to ask
;;;; two questions is worse. Carrying the outcome IN the context means one call answers
;;;; everything, and CL reads it through ordinary accessors.
;;;;
;;;; ON LEAVE STAGES AND HALT. `aion/interceptor`'s leave phase threads the context and
;;;; discards the Flow, so a LEAVE stage cannot short-circuit -- and does not need to. A
;;;; guardrail on the way out does not want to stop anything; it wants to REPLACE the
;;;; reply, which is what a leave stage does natively. `Halt` is for enter-side refusal --
;;;; a budget check (#172) that must reject before the expensive call, and skip it.

(cl:in-package #:praxeon/turn)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  (define-type Turn
    "One agent turn as data: what came in, what went out, and what the stages decided.

INPUT is the text the agent will actually deliberate over (already translated, if a stage
did that). LOCALE is the user's language tag. REPLY is the answer, empty until the effect
has run. NOTE is a stage's own message -- a refusal reason, a safety note -- kept separate
from REPLY so a stage can add to a reply or replace it without losing which is which.
HALTED is true when a stage refused, so the CL shell can tell a refusal from an answer
without matching on the pipeline's ADT."
    (Turn String String String String Boolean))

  ;;; --- accessors ----------------------------------------------------------

  (declare turn-input (Turn -> String))
  (define (turn-input tn) (match tn ((Turn i _ _ _ _) i)))

  (declare turn-locale (Turn -> String))
  (define (turn-locale tn) (match tn ((Turn _ l _ _ _) l)))

  (declare turn-reply (Turn -> String))
  (define (turn-reply tn) (match tn ((Turn _ _ r _ _) r)))

  (declare turn-note (Turn -> String))
  (define (turn-note tn) (match tn ((Turn _ _ _ n _) n)))

  (declare turn-halted (Turn -> Boolean))
  (define (turn-halted tn) (match tn ((Turn _ _ _ _ h) h)))

  ;;; --- construction and update (pure; every one returns a new Turn) -------

  (declare make-turn (String * String -> Turn))
  (define (make-turn input locale)
    "A fresh turn: the user's INPUT in LOCALE, no reply yet, not halted."
    (Turn input locale "" "" False))

  (declare with-input (Turn * String -> Turn))
  (define (with-input tn s) (match tn ((Turn _ l r n h) (Turn s l r n h))))

  (declare with-reply (Turn * String -> Turn))
  (define (with-reply tn s) (match tn ((Turn i l _ n h) (Turn i l s n h))))

  (declare with-note (Turn * String -> Turn))
  (define (with-note tn s) (match tn ((Turn i l r _ h) (Turn i l r s h))))

  (declare halt-with (Turn * String -> Turn))
  (define (halt-with tn reason)
    "Mark TN refused, carrying REASON. The reply is left alone -- a refusal that silently
blanked a reply would be indistinguishable from a failure to produce one."
    (match tn ((Turn i l r _ _) (Turn i l r reason True))))

  ;;; --- building stages from the CL side -----------------------------------
  ;;;
  ;;; An Interceptor is a `define-type`, so CL must never construct one (§7). These three
  ;;; are the seam: the CL shell writes an ordinary `Turn -> Turn` closure and gets a
  ;;; typed stage back. Every stage an application writes goes through here, which is also
  ;;; what keeps the Flow vocabulary from leaking into CL.

  (declare enter-stage (String * (Turn -> Turn) -> (aion/interceptor:Interceptor Turn)))
  (define (enter-stage nm f)
    "A stage that transforms the turn on the way IN and always proceeds."
    (aion/interceptor:on-enter nm (fn (tn) (aion/interceptor:Proceed (f tn)))))

  (declare leave-stage (String * (Turn -> Turn) -> (aion/interceptor:Interceptor Turn)))
  (define (leave-stage nm f)
    "A stage that transforms the turn on the way OUT and always proceeds.

This is where a guardrail belongs when it wants to amend or REPLACE the reply -- the leave
phase threads the context and cannot short-circuit, which is exactly right for something
that inspects an answer rather than preventing one."
    (aion/interceptor:on-leave nm (fn (tn) (aion/interceptor:Proceed (f tn)))))

  (declare guard-stage (String * (Turn -> Turn) -> (aion/interceptor:Interceptor Turn)))
  (define (guard-stage nm f)
    "An enter-side guard: F may refuse by returning a turn marked with HALT-WITH.

A refusal here SKIPS the effect entirely -- the LLM call never happens. That is the
difference between a budget check that costs nothing and one that bills you before saying
no, and between a safety refusal that replaces an answer and one appended to it."
    (aion/interceptor:on-enter
     nm
     (fn (tn)
       (let ((tn* (f tn)))
         (if (turn-halted tn*)
             (aion/interceptor:Halt tn*)
             (aion/interceptor:Proceed tn*))))))

  ;;; --- the runner, monomorphic so the CL shell can call it ----------------

  (declare run-chain ((List (aion/interceptor:Interceptor Turn))
                      * (Turn -> Turn) * Turn -> Turn))
  (define (run-chain chain effect tn)
    "Run CHAIN over TN with EFFECT as the single impure pivot, and return the final turn.

EFFECT is supplied by the CL shell -- it is the LLM round trip, and it is the only thing
here that touches the world. A stage that Halts on the way in SKIPS it entirely, which is
what makes a budget refusal cost nothing (#172) and a safety refusal genuinely a refusal."
    (aion/interceptor:flow-context
     (aion/interceptor:execute-effect chain effect tn))))
