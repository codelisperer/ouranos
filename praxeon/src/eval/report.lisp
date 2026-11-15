;;;; eval/report.lisp --- running every case, the report, the baseline and the gate (#1224).
;;;;
;;;; RUN-EVAL runs each case its number of times and returns a REPORT. The pass rates, the
;;;; comparison with a baseline and the gate's decision come from praxeon/eval/core; this file
;;;; collects the counts, hands them over, and writes the report as JSON and as a short text
;;;; summary. A saved JSON report is read back with LOAD-REPORT and passed to the next RUN-EVAL
;;;; as its baseline.

(in-package #:praxeon/eval)

(defstruct (case-report (:constructor %make-case-report))
  "One case's result: its NAME; RUNS, the number of runs, and PASSES, how many passed; the
REQUIRED pass rate and the PASS-RATE it got; MET-P, whether it met the required rate; CHANGE, how
it changed from the baseline (\"regressed\", \"fixed\", \"met\", \"not met\" or \"new\"); the token
counts and DURATION-MS summed over its runs; and RUN-RECORDS, its RUNs. A case read back by
LOAD-REPORT has no RUN-RECORDS."
  name runs passes required pass-rate met-p change input-tokens output-tokens duration-ms
  run-records)

(defstruct (report (:constructor %make-report))
  "The result of RUN-EVAL: its NAME; the CASES, a list of CASE-REPORTs; the total PASS-RATE (the
mean of the cases' pass rates); the names of the cases that REGRESSED from the baseline and of the
baseline cases this run REMOVED; the token counts and DURATION-MS over every run. RESULTS and
BASELINE-RESULTS are praxeon/eval/core values for the gate."
  name cases pass-rate regressions removed input-tokens output-tokens duration-ms
  results baseline-results)

(defun %sum (values)
  "The sum of the integers in VALUES, or NIL when none is an integer."
  (reduce #'%add values :initial-value nil))

(defun %results (case-reports)
  "CASE-REPORTS as a praxeon/eval/core RESULTS value. Each list is checked before it enters
Coalton, which checks only that it is a list (docs/coalton-patterns.md, section 5y)."
  (flet ((checked (list type argument)
           (boundary:check-elements list type :function 'core:make-results :argument argument)))
    (core:make-results
     (checked (mapcar #'case-report-name case-reports) 'string 'names)
     (checked (mapcar #'case-report-runs case-reports) '(and fixnum unsigned-byte) 'runs)
     (checked (mapcar #'case-report-passes case-reports) '(and fixnum unsigned-byte) 'passes)
     (checked (mapcar (lambda (c) (coerce (case-report-required c) 'double-float)) case-reports)
              'double-float 'required))))

(defun %empty-results ()
  (core:make-results '() '() '() '()))

(defun %run-case (the-case)
  (let* ((runs (loop repeat (case-repeats the-case) collect (%run-once the-case)))
         (passes (count-if #'run-passed-p runs))
         (n (length runs)))
    (%make-case-report :name (case-name the-case) :runs n :passes passes
                       :required (case-required the-case)
                       :pass-rate (core:pass-rate passes n)
                       :met-p (core:case-met? passes n (case-required the-case))
                       :input-tokens (%sum (mapcar #'run-input-tokens runs))
                       :output-tokens (%sum (mapcar #'run-output-tokens runs))
                       :duration-ms (%sum (mapcar #'run-duration-ms runs))
                       :run-records runs)))

(defun run-eval (cases &key (name "eval") baseline judge)
  "Run every case in CASES, each its REPEATS times on a fresh agent, grade the runs and return a
REPORT called NAME. BASELINE is an earlier REPORT, or a pathname or string naming a JSON report
WRITE-REPORT saved; the report then says how each case changed and which regressed. JUDGE is the
provider rubric graders ask; without it, the first rubric grader makes one with MAKE-JUDGE."
  (check-type cases list)
  (let* ((*judge* (or judge *judge*))
         (baseline (etypecase baseline
                     (null nil)
                     (report baseline)
                     ((or pathname string) (load-report baseline))))
         (case-reports (mapcar #'%run-case cases))
         (results (%results case-reports))
         (baseline-results (if baseline (report-results baseline) (%empty-results))))
    (loop for c in case-reports
          for label in (core:change-labels results baseline-results)
          do (setf (case-report-change c) label))
    (%make-report :name name :cases case-reports
                  :pass-rate (core:results-pass-rate results)
                  :regressions (core:regressions results baseline-results)
                  :removed (core:removed-cases results baseline-results)
                  :input-tokens (%sum (mapcar #'case-report-input-tokens case-reports))
                  :output-tokens (%sum (mapcar #'case-report-output-tokens case-reports))
                  :duration-ms (%sum (mapcar #'case-report-duration-ms case-reports))
                  :results results :baseline-results baseline-results)))

;;; --- the gate ------------------------------------------------------------------------

(defun gate (report &key (min-pass-rate 0) (max-regressions 0) (max-cases-not-met 0))
  "Decide whether REPORT is good enough to pass a build. Returns T or NIL, and as a second value
a list of reasons, one sentence per threshold not met. The thresholds:

  MIN-PASS-RATE      the lowest total pass rate allowed (the mean of the cases' pass rates).
  MAX-REGRESSIONS    the most cases allowed to regress from the baseline given to RUN-EVAL.
  MAX-CASES-NOT-MET  the most cases allowed to miss their own required pass rate.

With the defaults, every case must meet its required pass rate and none may regress. A script
for CI exits with (uiop:quit (if (gate report) 0 1))."
  (unless (and (realp min-pass-rate) (<= 0 min-pass-rate 1))
    (error "praxeon/eval: :MIN-PASS-RATE is a number from 0 to 1, not ~S." min-pass-rate))
  (check-type max-regressions (and fixnum unsigned-byte))
  (check-type max-cases-not-met (and fixnum unsigned-byte))
  (let ((decision (core:gate (report-results report) (report-baseline-results report)
                             (core:make-thresholds (coerce min-pass-rate 'double-float)
                                                   max-regressions max-cases-not-met))))
    (values (core:gate-succeeded? decision) (core:gate-reasons decision))))

;;; --- JSON ----------------------------------------------------------------------------

(defun %json-or-null (x) (if (null x) 'null x))

(defun %json-arguments (arguments)
  (if (hash-table-p arguments) arguments (string-downcase (princ-to-string arguments))))

(defun %run-json (run)
  (%object "passed" (if (run-passed-p run) t nil)
           "answer" (run-answer run)
           "status" (if (run-status run) (string-downcase (run-status run)) 'null)
           "error" (%json-or-null (run-error run))
           "duration_ms" (%json-or-null (run-duration-ms run))
           "input_tokens" (%json-or-null (run-input-tokens run))
           "output_tokens" (%json-or-null (run-output-tokens run))
           "calls" (map 'vector (lambda (call)
                                  (%object "name" (call-name call)
                                           "arguments" (%json-arguments (call-arguments call))
                                           "outcome" (if (call-outcome call)
                                                         (string-downcase (call-outcome call))
                                                         'null)))
                        (run-trajectory run))
           "grades" (map 'vector (lambda (entry)
                                   (%object "grader" (car entry)
                                            "passed" (if (core:grade-passed? (cdr entry)) t nil)
                                            "score" (core:grade-score (cdr entry))
                                            "reason" (core:grade-reason (cdr entry))))
                         (run-grades run))))

(defun %case-json (c)
  (%object "name" (case-report-name c)
           "runs" (case-report-runs c)
           "passes" (case-report-passes c)
           "required" (coerce (case-report-required c) 'double-float)
           "pass_rate" (case-report-pass-rate c)
           "met" (if (case-report-met-p c) t nil)
           "change" (%json-or-null (case-report-change c))
           "input_tokens" (%json-or-null (case-report-input-tokens c))
           "output_tokens" (%json-or-null (case-report-output-tokens c))
           "duration_ms" (%json-or-null (case-report-duration-ms c))
           "run_records" (map 'vector #'%run-json (case-report-run-records c))))

(defun report-json (report)
  "REPORT as a hash table ready for COM.INUOE.JZON:STRINGIFY: the totals, the regressions, and
each case with its runs, their answers, calls and grades."
  (%object "name" (report-name report)
           "total" (%object "cases" (length (report-cases report))
                            "cases_met" (count-if #'case-report-met-p (report-cases report))
                            "pass_rate" (report-pass-rate report)
                            "input_tokens" (%json-or-null (report-input-tokens report))
                            "output_tokens" (%json-or-null (report-output-tokens report))
                            "duration_ms" (%json-or-null (report-duration-ms report)))
           "regressions" (coerce (report-regressions report) 'vector)
           "removed" (coerce (report-removed report) 'vector)
           "cases" (map 'vector #'%case-json (report-cases report))))

(defun write-report (report path)
  "Write REPORT to PATH as JSON, replacing any file there. Returns PATH. The file holds each run's
answer and the arguments of each call, so it holds whatever the cases' inputs led the agent to
write."
  (ensure-directories-exist path)
  (with-open-file (s path :direction :output :if-exists :supersede :external-format :utf-8)
    (jzon:stringify (report-json report) :stream s :pretty t)
    (terpri s))
  path)

(defun %json-count (value key path)
  (unless (typep value '(and fixnum unsigned-byte))
    (error "praxeon/eval: the report ~A has ~S for a case's ~S, where a count was expected."
           path value key))
  value)

(defun load-report (path)
  "The JSON report WRITE-REPORT saved at PATH, as a REPORT to pass to RUN-EVAL as :BASELINE. Each
case keeps its name, runs, passes and required pass rate; the runs themselves are not kept."
  (let* ((json (with-open-file (s path :external-format :utf-8) (jzon:parse s)))
         (cases (and (hash-table-p json) (gethash "cases" json))))
    (unless (vectorp cases)
      (error "praxeon/eval: ~A is not an eval report: it has no list of cases." path))
    (let ((case-reports
            (map 'list
                 (lambda (c)
                   (let ((name (gethash "name" c))
                         (required (gethash "required" c)))
                     (unless (stringp name)
                       (error "praxeon/eval: the report ~A has a case without a name." path))
                     (unless (and (realp required) (<= 0 required 1))
                       (error "praxeon/eval: the report ~A has ~S for case ~S's required pass rate."
                              path required name))
                     (let ((runs (%json-count (gethash "runs" c) "runs" path))
                           (passes (%json-count (gethash "passes" c) "passes" path)))
                       (%make-case-report :name name :runs runs :passes passes
                                          :required (coerce required 'double-float)
                                          :pass-rate (core:pass-rate passes runs)
                                          :met-p (core:case-met? passes runs
                                                                 (coerce required 'double-float))))))
                 cases)))
      (let ((results (%results case-reports)))
        (%make-report :name (let ((n (gethash "name" json))) (if (stringp n) n "baseline"))
                      :cases case-reports
                      :pass-rate (core:results-pass-rate results)
                      :results results :baseline-results (%empty-results))))))

;;; --- the text summary ----------------------------------------------------------------

(defun %tokens-text (in out)
  (if (or in out)
      (format nil "~:[?~;~:*~D~] in, ~:[?~;~:*~D~] out tokens" in out)
      "no token counts"))

(defun summary (report &optional (stream *standard-output*))
  "Write a short text summary of REPORT to STREAM: one line per case, the reasons of each failed
run's failing grades, and the totals. Returns REPORT."
  (format stream "~&~A: ~D case~:P, ~D met, pass rate ~,2F, ~A, ~D ms~%"
          (report-name report) (length (report-cases report))
          (count-if #'case-report-met-p (report-cases report))
          (report-pass-rate report)
          (%tokens-text (report-input-tokens report) (report-output-tokens report))
          (or (report-duration-ms report) 0))
  (dolist (c (report-cases report))
    (format stream "  ~:[NOT MET~;MET    ~]  ~A  ~D/~D runs passed (required ~,2F)~@[  ~A~]~%"
            (case-report-met-p c) (case-report-name c) (case-report-passes c)
            (case-report-runs c) (case-report-required c)
            (and (case-report-change c) (not (equal (case-report-change c) "new"))
                 (case-report-change c)))
    (loop for run in (case-report-run-records c)
          for i from 1
          unless (run-passed-p run)
            do (loop for (grader . grade) in (run-grades run)
                     unless (core:grade-passed? grade)
                       do (format stream "      run ~D, ~A: ~A~%" i grader
                                  (%clip (core:grade-reason grade) 300)))))
  (when (report-regressions report)
    (format stream "  regressed: ~{~A~^, ~}~%" (report-regressions report)))
  (when (report-removed report)
    (format stream "  not in this run but in the baseline: ~{~A~^, ~}~%" (report-removed report)))
  report)
