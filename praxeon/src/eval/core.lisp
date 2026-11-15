;;;; eval/core.lisp --- grades, pass rates, the comparison with a baseline and the gate (#1224).
;;;;
;;;; Pure, and in Coalton as #1224 asks. The CL shell runs the agents and the graders; what
;;;; comes back here is a grade per grader per run, and for each case its name, how many runs it
;;;; had, how many of them passed and the pass rate it requires.
;;;;
;;;; THE BOUNDARY. The shell passes only strings, non-negative fixnums and double floats, in
;;;; lists it checks with aion/boundary before the call (docs/coalton-patterns.md, sections 5y
;;;; and 7). A list of case results is built here, by MAKE-RESULTS, and handed back to the shell
;;;; as one RESULTS value, so no list of a Coalton type ever crosses from CL.
;;;;
;;;; DEFINITIONS, which the user guide repeats:
;;;;
;;;;   - A case's pass rate is the number of runs that passed divided by the number of runs.
;;;;   - A case is met when it had at least one run and its pass rate is at least the rate it
;;;;     requires.
;;;;   - The total pass rate is the mean of the cases' pass rates, so a case run ten times does
;;;;     not count for more than a case run once. With no cases it is 0.
;;;;   - A regression is a case that was met in the baseline and is not met now. A case missing
;;;;     from the baseline is new; a baseline case missing from this run is removed. Neither is a
;;;;     regression.

(cl:in-package #:praxeon/eval/core)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  ;; Whether a grade passed. A type of its own rather than a Boolean, so a grade says what it
  ;; is when it is printed or matched.
  (define-type Outcome Passed Failed)

  ;; A grade: its outcome, a score from 0 to 1, and the grader's reason in words. The match
  ;; graders score 1 or 0; a rubric grade carries the judge's score.
  (define-type Grade (Grade Outcome F64 String))

  (declare passing-grade (F64 * String -> Grade))
  (define (passing-grade score reason)
    "A grade that passed, with SCORE and REASON."
    (Grade Passed score reason))

  (declare failing-grade (F64 * String -> Grade))
  (define (failing-grade score reason)
    "A grade that failed, with SCORE and REASON."
    (Grade Failed score reason))

  (declare grade-passed? (Grade -> Boolean))
  (define (grade-passed? g)
    "True when G passed."
    (match g
      ((Grade o _ _)
       (match o
         ((Passed) True)
         ((Failed) False)))))

  (declare grade-score (Grade -> F64))
  (define (grade-score g)
    "G's score, from 0 to 1."
    (match g ((Grade _ s _) s)))

  (declare grade-reason (Grade -> String))
  (define (grade-reason g)
    "The grader's reason for G."
    (match g ((Grade _ _ r) r)))

  ;; --- one case ---------------------------------------------------------------------------

  (declare %to-f64 (UFix -> F64))
  (define (%to-f64 n)
    (lisp (-> F64) (n) (cl:coerce n 'cl:double-float)))

  (declare pass-rate (UFix * UFix -> F64))
  (define (pass-rate passes runs)
    "PASSES divided by RUNS, or 0 when there were no runs."
    (if (== runs 0)
        0
        (/ (%to-f64 passes) (%to-f64 runs))))

  (declare case-met? (UFix * UFix * F64 -> Boolean))
  (define (case-met? passes runs required)
    "True when there was at least one run and PASSES of RUNS is at least the REQUIRED rate."
    (if (== runs 0)
        False
        (>= (pass-rate passes runs) required)))

  ;; A case's result: its name, runs, passes and required pass rate.
  (define-type CaseResult (CaseResult String UFix UFix F64))

  (declare %case-name (CaseResult -> String))
  (define (%case-name c)
    (match c ((CaseResult n _ _ _) n)))

  (declare %case-rate (CaseResult -> F64))
  (define (%case-rate c)
    (match c ((CaseResult _ r p _) (pass-rate p r))))

  (declare %case-met? (CaseResult -> Boolean))
  (define (%case-met? c)
    (match c ((CaseResult _ r p q) (case-met? p r q))))

  ;; The results of one eval run, or of a baseline.
  (define-type Results (Results (List CaseResult)))

  (declare %zip-cases ((List String) * (List UFix) * (List UFix) * (List F64)
                       -> (List CaseResult)))
  (define (%zip-cases names runs passes required)
    (match names
      ((Cons n names-rest)
       (match runs
         ((Cons r runs-rest)
          (match passes
            ((Cons p passes-rest)
             (match required
               ((Cons q required-rest)
                (Cons (CaseResult n r p q)
                      (%zip-cases names-rest runs-rest passes-rest required-rest)))
               ((Nil) Nil)))
            ((Nil) Nil)))
         ((Nil) Nil)))
      ((Nil) Nil)))

  (declare make-results ((List String) * (List UFix) * (List UFix) * (List F64) -> Results))
  (define (make-results names runs passes required)
    "The results of a set of cases, given in four lists of the same length: each case's NAME,
its number of RUNS, the number of runs that PASSED, and its REQUIRED pass rate. The shell
checks the lengths; here the shortest list decides."
    (Results (%zip-cases names runs passes required)))

  (declare %cases (Results -> (List CaseResult)))
  (define (%cases rs)
    (match rs ((Results cs) cs)))

  (declare results-case-count (Results -> UFix))
  (define (results-case-count rs)
    "The number of cases in RS."
    (list:length (%cases rs)))

  (declare results-cases-met (Results -> UFix))
  (define (results-cases-met rs)
    "The number of cases in RS that met their required pass rate."
    (list:length (list:filter %case-met? (%cases rs))))

  (declare results-pass-rate (Results -> F64))
  (define (results-pass-rate rs)
    "The mean of the cases' pass rates in RS, or 0 when there are no cases."
    (let ((cs (%cases rs)))
      (if (== (list:length cs) 0)
          0
          (/ (fold + 0 (map %case-rate cs)) (%to-f64 (list:length cs))))))

  (declare cases-not-met (Results -> (List String)))
  (define (cases-not-met rs)
    "The names of the cases in RS that did not meet their required pass rate, in order."
    (map %case-name (list:filter (fn (c) (not (%case-met? c))) (%cases rs))))

  ;; --- the comparison with a baseline ------------------------------------------------------

  ;; How a case changed from the baseline.
  (define-type Change Regressed Fixed StillMet StillNotMet NewCase)

  (declare %find-case (String * (List CaseResult) -> (Optional CaseResult)))
  (define (%find-case name cs)
    (list:find (fn (c) (== (%case-name c) name)) cs))

  (declare %change (CaseResult * Results -> Change))
  (define (%change c baseline)
    (match (%find-case (%case-name c) (%cases baseline))
      ((None) NewCase)
      ((Some b)
       (if (%case-met? b)
           (if (%case-met? c) StillMet Regressed)
           (if (%case-met? c) Fixed StillNotMet)))))

  (declare %change-label (Change -> String))
  (define (%change-label ch)
    (match ch
      ((Regressed) "regressed")
      ((Fixed) "fixed")
      ((StillMet) "met")
      ((StillNotMet) "not met")
      ((NewCase) "new")))

  (declare %regressed? (Change -> Boolean))
  (define (%regressed? ch)
    (match ch
      ((Regressed) True)
      (_ False)))

  (declare change-labels (Results * Results -> (List String)))
  (define (change-labels current baseline)
    "For each case in CURRENT, in order, how it changed from BASELINE: \"regressed\", \"fixed\",
\"met\", \"not met\" or \"new\"."
    (map (fn (c) (%change-label (%change c baseline))) (%cases current)))

  (declare regressions (Results * Results -> (List String)))
  (define (regressions current baseline)
    "The names of the cases in CURRENT that were met in BASELINE and are not met now."
    (map %case-name
         (list:filter (fn (c) (%regressed? (%change c baseline))) (%cases current))))

  (declare removed-cases (Results * Results -> (List String)))
  (define (removed-cases current baseline)
    "The names of the cases in BASELINE that CURRENT does not have."
    (map %case-name
         (list:filter (fn (b)
                        (match (%find-case (%case-name b) (%cases current))
                          ((None) True)
                          ((Some _) False)))
                      (%cases baseline))))

  ;; --- the gate -------------------------------------------------------------------------

  ;; The thresholds a run must meet: the minimum total pass rate, the most regressions allowed
  ;; and the most cases allowed to miss their required pass rate.
  (define-type Thresholds (Thresholds F64 UFix UFix))

  (declare make-thresholds (F64 * UFix * UFix -> Thresholds))
  (define (make-thresholds min-pass-rate max-regressions max-cases-not-met)
    "The gate's thresholds."
    (Thresholds min-pass-rate max-regressions max-cases-not-met))

  ;; What the gate decided. A failure carries one reason per threshold that was not met.
  (define-type GateResult GateSucceeded (GateFailed (List String)))

  (declare %rate-reason (F64 * F64 -> String))
  (define (%rate-reason rate minimum)
    (lisp (-> String) (rate minimum)
      (cl:format cl:nil "the total pass rate ~,2F is below the minimum ~,2F" rate minimum)))

  (declare %names-reason (String * UFix * (List String) -> String))
  (define (%names-reason what allowed names)
    (lisp (-> String) (what allowed names)
      (cl:format cl:nil "~D case~:P ~A, and at most ~D ~:*~[are~;is~:;are~] allowed: ~{~A~^, ~}"
                 (cl:length names) what allowed names)))

  (declare gate (Results * Results * Thresholds -> GateResult))
  (define (gate current baseline thresholds)
    "Decide whether CURRENT passes THRESHOLDS, comparing it with BASELINE for regressions. An
empty BASELINE has no regressions."
    (match thresholds
      ((Thresholds min-rate max-regressions max-not-met)
       (let ((rate (results-pass-rate current))
             (regressed-names (regressions current baseline))
             (not-met (cases-not-met current)))
         (let ((reasons
                 (list:append
                  (if (< rate min-rate) (make-list (%rate-reason rate min-rate)) Nil)
                  (list:append
                   (if (> (list:length regressed-names) max-regressions)
                       (make-list (%names-reason "regressed" max-regressions regressed-names))
                       Nil)
                   (if (> (list:length not-met) max-not-met)
                       (make-list (%names-reason "did not meet the required pass rate"
                                                 max-not-met not-met))
                       Nil)))))
           (if (== (list:length reasons) 0)
               GateSucceeded
               (GateFailed reasons)))))))

  (declare gate-succeeded? (GateResult -> Boolean))
  (define (gate-succeeded? g)
    "True when the gate succeeded."
    (match g
      ((GateSucceeded) True)
      ((GateFailed _) False)))

  (declare gate-reasons (GateResult -> (List String)))
  (define (gate-reasons g)
    "Why the gate failed, one sentence per threshold not met; empty when it succeeded."
    (match g
      ((GateSucceeded) Nil)
      ((GateFailed reasons) reasons))))
