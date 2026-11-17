;;;; core/core.lisp --- step results and a row's verdict (#1028, dokimasia ADR-0001).
;;;;
;;;; THE RULE, which the README of the harness repeats:
;;;;
;;;;   - A row FAILED when any of its steps failed. The verdict names the first failed step and
;;;;     its reason.
;;;;   - Otherwise a row was NOT RUN when any of its steps was not run, such as a stored-data probe
;;;;     with no HTTP form against a deployed URL. The verdict names the first such step and its
;;;;     reason. A row with a step that did not run is never reported as passed, so a smaller
;;;;     check is not mistaken for a passing one.
;;;;   - A row with no steps at all was not run either.
;;;;   - Otherwise the row PASSED.
;;;;
;;;; THE BOUNDARY. The shell passes only strings and non-negative fixnums, in lists it checks with
;;;; aion/boundary before the call (docs/coalton-patterns.md, sections 5y and 7). The list of step
;;;; results is built here, by MAKE-ROW-RESULTS, and handed back as one ROWRESULTS value.

(cl:in-package #:dokimasia/core)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  ;; How one step ended. A failure and a step that was not run each carry their reason.
  (define-type StepOutcome
    StepPassed
    (StepFailed String)
    (StepNotRun String))

  ;; One step's result: its label, how it ended, and how long it took in milliseconds.
  (define-type StepResult (StepResult String StepOutcome UFix))

  ;; The results of one row's steps, in the order they ran.
  (define-type RowResults (RowResults (List StepResult)))

  ;; A row's verdict. A failure and a row not run carry the index (from 0) and label of the step
  ;; that decided it, and that step's reason.
  (define-type Verdict
    VerdictPassed
    (VerdictFailed UFix String String)
    (VerdictNotRun UFix String String))

  (declare %outcome (String * String -> StepOutcome))
  (define (%outcome kind reason)
    "The outcome named by KIND: \"passed\", \"failed\" or \"not-run\". Any other KIND is a failure
that says so, so a misspelt kind cannot pass."
    (cond ((== kind "passed") StepPassed)
          ((== kind "failed") (StepFailed reason))
          ((== kind "not-run") (StepNotRun reason))
          (True (StepFailed (lisp (-> String) (kind)
                              (cl:format cl:nil "dokimasia: the step outcome ~S is not one of passed, failed or not-run"
                                         kind))))))

  (declare %zip-steps ((List String) * (List String) * (List String) * (List UFix)
                       -> (List StepResult)))
  (define (%zip-steps labels kinds reasons durations)
    (match labels
      ((Cons l labels-rest)
       (match kinds
         ((Cons k kinds-rest)
          (match reasons
            ((Cons r reasons-rest)
             (match durations
               ((Cons d durations-rest)
                (Cons (StepResult l (%outcome k r) d)
                      (%zip-steps labels-rest kinds-rest reasons-rest durations-rest)))
               ((Nil) Nil)))
            ((Nil) Nil)))
         ((Nil) Nil)))
      ((Nil) Nil)))

  (declare make-row-results ((List String) * (List String) * (List String) * (List UFix)
                             -> RowResults))
  (define (make-row-results labels kinds reasons durations)
    "The results of a row's steps, given in four lists of the same length, in the order the steps
ran: each step's LABEL, its KIND (\"passed\", \"failed\" or \"not-run\"), its REASON (empty when
it passed) and its duration in milliseconds. The shell checks the lengths; here the shortest
list decides."
    (RowResults (%zip-steps labels kinds reasons durations)))

  (declare %steps (RowResults -> (List StepResult)))
  (define (%steps rs)
    (match rs ((RowResults ss) ss)))

  (declare %step-outcome (StepResult -> StepOutcome))
  (define (%step-outcome s)
    (match s ((StepResult _ o _) o)))

  (declare %passed? (StepOutcome -> Boolean))
  (define (%passed? o)
    (match o
      ((StepPassed) True)
      (_ False)))

  (declare %failed? (StepOutcome -> Boolean))
  (define (%failed? o)
    (match o
      ((StepFailed _) True)
      (_ False)))

  (declare %not-run? (StepOutcome -> Boolean))
  (define (%not-run? o)
    (match o
      ((StepNotRun _) True)
      (_ False)))

  (declare %count (RowResults * (StepOutcome -> Boolean) -> UFix))
  (define (%count rs pred)
    (list:length (list:filter (fn (s) (pred (%step-outcome s))) (%steps rs))))

  (declare row-step-count (RowResults -> UFix))
  (define (row-step-count rs)
    "The number of steps in RS."
    (list:length (%steps rs)))

  (declare steps-passed (RowResults -> UFix))
  (define (steps-passed rs)
    "The number of steps in RS that passed."
    (%count rs %passed?))

  (declare steps-failed (RowResults -> UFix))
  (define (steps-failed rs)
    "The number of steps in RS that failed."
    (%count rs %failed?))

  (declare steps-not-run (RowResults -> UFix))
  (define (steps-not-run rs)
    "The number of steps in RS that were not run."
    (%count rs %not-run?))

  (declare total-duration-ms (RowResults -> UFix))
  (define (total-duration-ms rs)
    "The sum of the durations of the steps in RS, in milliseconds."
    (fold + 0 (map (fn (s) (match s ((StepResult _ _ d) d))) (%steps rs))))

  (declare %first-failure ((List StepResult) * UFix -> (Optional Verdict)))
  (define (%first-failure ss i)
    (match ss
      ((Nil) None)
      ((Cons s rest)
       (match s
         ((StepResult label outcome _)
          (match outcome
            ((StepFailed reason) (Some (VerdictFailed i label reason)))
            (_ (%first-failure rest (+ i 1)))))))))

  (declare %first-not-run ((List StepResult) * UFix -> (Optional Verdict)))
  (define (%first-not-run ss i)
    (match ss
      ((Nil) None)
      ((Cons s rest)
       (match s
         ((StepResult label outcome _)
          (match outcome
            ((StepNotRun reason) (Some (VerdictNotRun i label reason)))
            (_ (%first-not-run rest (+ i 1)))))))))

  (declare row-verdict (RowResults -> Verdict))
  (define (row-verdict rs)
    "RS's verdict, by the rule at the top of this file."
    (let ((ss (%steps rs)))
      (match (%first-failure ss 0)
        ((Some v) v)
        ((None)
         (match (%first-not-run ss 0)
           ((Some v) v)
           ((None)
            (if (== (list:length ss) 0)
                (VerdictNotRun 0 "" "the row has no steps")
                VerdictPassed)))))))

  (declare verdict-kind (Verdict -> String))
  (define (verdict-kind v)
    "\"passed\", \"failed\" or \"not-run\"."
    (match v
      ((VerdictPassed) "passed")
      ((VerdictFailed _ _ _) "failed")
      ((VerdictNotRun _ _ _) "not-run")))

  (declare verdict-step-index (Verdict -> UFix))
  (define (verdict-step-index v)
    "The index, from 0, of the step that decided V; 0 for a row that passed."
    (match v
      ((VerdictPassed) 0)
      ((VerdictFailed i _ _) i)
      ((VerdictNotRun i _ _) i)))

  (declare verdict-step-label (Verdict -> String))
  (define (verdict-step-label v)
    "The label of the step that decided V; empty for a row that passed."
    (match v
      ((VerdictPassed) "")
      ((VerdictFailed _ l _) l)
      ((VerdictNotRun _ l _) l)))

  (declare verdict-reason (Verdict -> String))
  (define (verdict-reason v)
    "Why V is not a pass; empty for a row that passed."
    (match v
      ((VerdictPassed) "")
      ((VerdictFailed _ _ r) r)
      ((VerdictNotRun _ _ r) r))))
