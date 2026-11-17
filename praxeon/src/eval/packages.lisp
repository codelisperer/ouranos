;;;; eval/packages.lisp --- the two packages of praxeon/eval (#1224).
;;;;
;;;; PRAXEON/EVAL/CORE is Coalton: the grade type and the pure aggregation, which turns run
;;;; counts into pass rates, compares a run with a baseline and decides the gate. It does no IO.
;;;; PRAXEON/EVAL is the CL shell: it runs agents, records what they did from the event stream,
;;;; calls the graders and the judge, and reads and writes reports.

(cl:defpackage #:praxeon/eval/core
  (:use #:coalton #:coalton-prelude)
  (:local-nicknames (#:list #:coalton-library/list))
  (:documentation "The typed core of praxeon/eval (#1224): grades, pass rates, the comparison
with a baseline and the gate. Pure.")
  (:export
   ;; grades
   #:passing-grade #:failing-grade #:grade-passed? #:grade-score #:grade-reason
   ;; one case's runs
   #:pass-rate #:case-met?
   ;; a set of case results, and its aggregates
   #:make-results #:results-case-count #:results-cases-met #:results-pass-rate #:cases-not-met
   ;; comparison with a baseline
   #:change-labels #:regressions #:removed-cases
   ;; the gate
   #:make-thresholds #:gate #:gate-succeeded? #:gate-reasons))

(cl:defpackage #:praxeon/eval
  (:use #:cl)
  (:local-nicknames (#:core #:praxeon/eval/core)
                    (#:llm #:praxeon/llm)
                    (#:actor #:praxeon/actor)
                    (#:evt #:praxeon/event)
                    (#:boundary #:aion/boundary)
                    (#:sexp #:aion/sexp)
                    (#:jzon #:com.inuoe.jzon)
                    (#:ppcre #:cl-ppcre))
  (:documentation "Run agents against fixed cases, grade the results, and fail a build when
they get worse (#1224). See praxeon/docs/user-guide.md, \"Evals\".")
  (:export
   ;; cases and datasets
   #:make-case #:eval-case #:case-name #:case-inputs #:case-agent #:case-graders #:case-repeats
   #:case-required #:case-max-steps #:load-dataset #:invalid-case
   ;; graders
   #:grader #:make-grader #:grader-name #:grade-run
   #:exact-match #:contains #:matches-regex #:trajectory #:rubric
   #:passing-grade #:failing-grade #:grade-passed-p #:grade-score #:grade-reason
   ;; the judge
   #:make-judge #:*judge* #:*judge-max-tokens*
   ;; a run, as graders see it
   #:run #:make-run #:run-answer #:run-status #:run-inputs #:run-trajectory #:run-input-tokens
   #:run-output-tokens #:run-duration-ms #:run-error #:run-grades #:run-passed-p
   #:call #:make-call #:call-id #:call-name #:call-arguments #:call-outcome
   ;; running and reporting
   #:run-eval #:report #:report-name #:report-cases #:report-pass-rate #:report-regressions
   #:report-removed #:report-input-tokens #:report-output-tokens #:report-duration-ms
   #:case-report #:case-report-name #:case-report-runs #:case-report-passes
   #:case-report-required #:case-report-pass-rate #:case-report-met-p #:case-report-change
   #:case-report-input-tokens #:case-report-output-tokens #:case-report-duration-ms
   #:case-report-run-records
   #:write-report #:report-json #:load-report #:summary #:gate))
