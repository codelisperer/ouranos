;;;; eval-tests.lisp --- praxeon/eval with stub providers for the agent and the judge (#1224).
;;;;
;;;; No check here makes a network call. The agent's provider is STUB-AGENT-PROVIDER, which
;;;; picks a scripted conversation from the first user message, and the judge is STUB-JUDGE,
;;;; which answers every request with the score it was made with. Every grader has a check that
;;;; it fails when it should, not only that it passes.

(defpackage #:praxeon/eval/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:eval #:praxeon/eval)
                    (#:core #:praxeon/eval/core)
                    (#:ex #:praxeon/examples/eval)
                    (#:llm #:praxeon/llm)
                    (#:actor #:praxeon/actor)
                    (#:evt #:praxeon/event)
                    (#:boundary #:aion/boundary)
                    (#:jzon #:com.inuoe.jzon))
  (:export #:eval))

(in-package #:praxeon/eval/tests)

(def-suite eval :description "praxeon/eval: graders, runs, reports, baselines and the gate (#1224).")
(in-suite eval)

;;; --- stub providers -------------------------------------------------------------------

(defvar *call-id* 0)

(defun %hash (alist)
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k . v) in alist do (setf (gethash k h) v))
    h))

(defun %calls (&rest specs)
  "A completion that calls the means in SPECS, each (NAME . ARGUMENT-ALIST)."
  (llm:make-completion
   :text "" :stop-reason :tool-use :input-tokens 10 :output-tokens 5
   :tool-calls (loop for (name . arguments) in specs
                     collect (llm:make-tool-call :id (format nil "call-~D" (incf *call-id*))
                                                 :name name :arguments (%hash arguments)))))

(defun %say (text)
  (llm:make-completion :text text :stop-reason :end :input-tokens 10 :output-tokens 5))

(defclass stub-agent-provider (llm:provider)
  ((choose :initarg :choose :reader stub-choose)
   (queue :initform :unset :accessor stub-queue))
  (:documentation "Answers from a script that CHOOSE picks from the first user message, the
first time it is asked. One instance serves one run."))

(defmethod llm:supports-tool-choice-p ((p stub-agent-provider)) t)

(defmethod llm:complete ((p stub-agent-provider) messages
                         &key system tools max-tokens temperature tool-choice)
  (declare (ignore system tools max-tokens temperature tool-choice))
  (when (eq (stub-queue p) :unset)
    (let ((first-user (find "user" messages :key #'llm:role :test #'equal)))
      (setf (stub-queue p) (funcall (stub-choose p) (llm:content first-user)))))
  (or (pop (stub-queue p))
      (%say "")))

(defun %support-script (message)
  "What a well-behaved support agent does for each message of the example dataset."
  (cond ((search "A1" message)
         (list (%calls '("lookup-order" ("order_id" . "A1")))
               (%calls '("issue-refund" ("order_id" . "A1") ("reason" . "arrived broken")))
               (%say "I have refunded 25.00 for order A1.")))
        ((search "B2" message)
         (list (%calls '("lookup-order" ("order_id" . "B2")))
               (%say "Order B2 has shipped.")))
        ((search "C3" message)
         (list (%calls '("lookup-order" ("order_id" . "C3")))
               (%say "Order C3, a chair, is being processed. What would you like to know?")
               (%say "Order C3 cost 120.00.")))
        (t (list (%say "I do not know.")))))

(defun %careless-script (message)
  "The support agent with a defect: for order A1 it answers without refunding."
  (if (search "A1" message)
      (list (%calls '("lookup-order" ("order_id" . "A1")))
            (%say "Sorry to hear that. I cannot help with that order."))
      (%support-script message)))

(defun %agent-with (script)
  "An agent function for the example agent on a fresh stub following SCRIPT."
  (lambda () (ex:make-support-agent
              :provider (make-instance 'stub-agent-provider :choose script))))

(defclass stub-judge (llm:provider)
  ((score :initarg :score :reader judge-score)
   (reasoning :initarg :reasoning :initform "stub reasoning" :reader judge-reasoning)
   (prompts :initform '() :accessor judge-prompts)
   (systems :initform '() :accessor judge-systems))
  (:documentation "A judge that answers every request with SCORE and REASONING, and keeps the
prompts it was sent."))

(defmethod llm:supports-tool-choice-p ((p stub-judge)) t)

(defmethod llm:complete ((p stub-judge) messages
                         &key system tools max-tokens temperature tool-choice)
  (declare (ignore max-tokens temperature))
  (push (llm:content (first messages)) (judge-prompts p))
  (push system (judge-systems p))
  (let ((name (if (consp tool-choice) (second tool-choice) (llm:tool-spec-name (first tools)))))
    (llm:make-completion
     :text "" :stop-reason :tool-use
     :tool-calls (list (llm:make-tool-call
                        :id "judge-1" :name name
                        :arguments (%hash (list (cons "score" (judge-score p))
                                                (cons "reasoning" (judge-reasoning p)))))))))

(defclass failing-judge (llm:provider) ())

(defmethod llm:complete ((p failing-judge) messages
                         &key system tools max-tokens temperature tool-choice)
  (declare (ignore messages system tools max-tokens temperature tool-choice))
  (error "the judge is unavailable"))

(defmethod llm:supports-tool-choice-p ((p failing-judge)) t)

;;; --- helpers --------------------------------------------------------------------------

(defun %run (&key (answer "") calls (inputs '("hello")))
  "A RUN with ANSWER and CALLS, each (NAME . ARGUMENT-ALIST) or (NAME . :WITHHELD)."
  (eval:make-run :answer answer :inputs inputs
                 :trajectory (loop for (name . arguments) in calls
                                   for i from 1
                                   collect (eval:make-call
                                            :id (format nil "c~D" i) :name name
                                            :arguments (if (eq arguments :withheld)
                                                           :withheld
                                                           (%hash arguments))
                                            :outcome :ok))))

(defun %passes (grader run) (eval:grade-passed-p (eval:grade-run grader run)))

(defun %reason (grader run) (eval:grade-reason (eval:grade-run grader run)))

(defmacro with-temporary-path ((var name) &body body)
  "Bind VAR to a path in a new temporary directory, and remove the directory afterwards."
  (let ((dir (gensym "DIR")))
    `(let* ((,dir (uiop:ensure-directory-pathname
                   (merge-pathnames (format nil "praxeon-eval-~D-~D/" (get-universal-time)
                                            (random 1000000 (make-random-state t)))
                                    (uiop:temporary-directory))))
            (,var (merge-pathnames ,name ,dir)))
       (ensure-directories-exist ,dir)
       (unwind-protect (progn ,@body)
         (uiop:delete-directory-tree ,dir :validate t :if-does-not-exist :ignore)))))

;;; --- the match graders ----------------------------------------------------------------

(test exact-match-passes-on-equal-text-and-fails-otherwise
  (let ((g (eval:exact-match "Order B2 has shipped.")))
    (is (%passes g (%run :answer "  Order B2 has shipped.
")))
    (is (not (%passes g (%run :answer "Order B2 has shipped"))))
    (is (search "expected" (%reason g (%run :answer "no"))))
    (is (not (%passes g (%run :answer "order b2 has shipped."))))
    (is (%passes (eval:exact-match "Order B2 has shipped." :ignore-case t)
                 (%run :answer "order b2 has shipped.")))))

(test contains-passes-on-a-substring-and-fails-otherwise
  (let ((g (eval:contains "refund")))
    (is (%passes g (%run :answer "I have issued a refund.")))
    (is (not (%passes g (%run :answer "I have issued a Refund."))))
    (is (not (%passes g (%run :answer "Nothing was done."))))
    (is (search "does not contain" (%reason g (%run :answer "Nothing."))))
    (is (%passes (eval:contains "refund" :ignore-case t) (%run :answer "REFUND issued")))))

(test matches-regex-passes-on-a-match-and-fails-otherwise
  (let ((g (eval:matches-regex "\\b\\d+\\.\\d{2}\\b")))
    (is (%passes g (%run :answer "It cost 120.00 in total.")))
    (is (not (%passes g (%run :answer "It cost a lot."))))
    (is (search "does not match" (%reason g (%run :answer "It cost a lot.")))))
  (is (%passes (eval:matches-regex "shipped" :ignore-case t) (%run :answer "SHIPPED")))
  (is (not (%passes (eval:matches-regex "shipped") (%run :answer "SHIPPED"))))
  ;; A pattern that does not parse is refused when the grader is made, not at grading time.
  (signals error (eval:matches-regex "(unclosed")))

;;; --- the trajectory grader ------------------------------------------------------------

(defparameter +lookup-then-refund+
  '(("lookup-order" ("order_id" . "A1"))
    ("issue-refund" ("order_id" . "A1") ("reason" . "broken"))))

(test trajectory-in-order-passes-and-fails-on-the-wrong-order
  (let ((g (eval:trajectory '("lookup-order" "issue-refund") :order :in-order)))
    (is (%passes g (%run :calls +lookup-then-refund+)))
    ;; other calls are allowed between and around the steps
    (is (%passes g (%run :calls (list '("greet") (first +lookup-then-refund+) '("note")
                                      (second +lookup-then-refund+)))))
    (is (not (%passes g (%run :calls (reverse +lookup-then-refund+)))))
    (is (not (%passes g (%run :calls (list (first +lookup-then-refund+))))))
    (is (not (%passes g (%run :calls '()))))
    (is (search "the agent called issue-refund" (%reason g (%run :calls (reverse +lookup-then-refund+)))))))

(test trajectory-exact-fails-on-an-extra-call
  (let ((g (eval:trajectory '("lookup-order" "issue-refund") :order :exact)))
    (is (%passes g (%run :calls +lookup-then-refund+)))
    (is (not (%passes g (%run :calls (append +lookup-then-refund+ '(("note")))))))
    (is (not (%passes g (%run :calls (reverse +lookup-then-refund+)))))))

(test trajectory-set-ignores-order-and-fails-on-a-missing-call
  (let ((g (eval:trajectory '("issue-refund" "lookup-order") :order :set)))
    (is (%passes g (%run :calls +lookup-then-refund+)))
    (is (%passes g (%run :calls (reverse +lookup-then-refund+))))
    (is (not (%passes g (%run :calls (list (first +lookup-then-refund+))))))
    ;; one call cannot match two steps
    (is (not (%passes (eval:trajectory '("lookup-order" "lookup-order") :order :set)
                      (%run :calls (list (first +lookup-then-refund+))))))))

(test trajectory-set-finds-an-assignment-the-first-fit-would-miss
  ;; The first step accepts either call and the second only the first call, so taking the first
  ;; fit for the first step would leave nothing for the second.
  (let ((g (eval:trajectory '("lookup-order"
                              ("lookup-order" :arguments (("order_id" "A1"))))
                            :order :set)))
    (is (%passes g (%run :calls '(("lookup-order" ("order_id" . "A1"))
                                  ("lookup-order" ("order_id" . "B2"))))))))

(test trajectory-argument-checks-fail-on-a-wrong-or-withheld-argument
  (let ((g (eval:trajectory '("lookup-order" ("issue-refund" :arguments (("order_id" "A1")))))))
    (is (%passes g (%run :calls +lookup-then-refund+)))
    (is (not (%passes g (%run :calls '(("lookup-order" ("order_id" . "A1"))
                                       ("issue-refund" ("order_id" . "B2")))))))
    (is (not (%passes g (%run :calls '(("lookup-order" ("order_id" . "A1"))
                                       ("issue-refund"))))))
    ;; A private agent's arguments are withheld from the event stream, so a check cannot pass.
    (is (not (%passes g (%run :calls '(("lookup-order" . :withheld) ("issue-refund" . :withheld))))))
    ;; A step without argument checks still matches a withheld call.
    (is (%passes (eval:trajectory '("lookup-order"))
                 (%run :calls '(("lookup-order" . :withheld))))))
  (let ((g (eval:trajectory (list (list "issue-refund"
                                        :arguments (lambda (arguments)
                                                     (plusp (length (gethash "reason" arguments "")))))))))
    (is (%passes g (%run :calls (list (second +lookup-then-refund+)))))
    (is (not (%passes g (%run :calls '(("issue-refund" ("order_id" . "A1")))))))))

;;; --- the rubric grader and the judge --------------------------------------------------

(test rubric-passes-at-the-threshold-and-fails-below-it
  (let ((g (eval:rubric "States the amount refunded." :threshold 0.7))
        (run (%run :answer "Refunded 25.00." :inputs '("Refund order A1."))))
    (let ((eval:*judge* (make-instance 'stub-judge :score 0.9d0 :reasoning "It states 25.00.")))
      (let ((grade (eval:grade-run g run)))
        (is (eval:grade-passed-p grade))
        (is (= 0.9d0 (eval:grade-score grade)))
        (is (search "It states 25.00." (eval:grade-reason grade))))
      ;; the judge saw the rubric, the user's message and the answer
      (let ((prompt (first (judge-prompts eval:*judge*))))
        (is (search "States the amount refunded." prompt))
        (is (search "Refund order A1." prompt))
        (is (search "Refunded 25.00." prompt))))
    (let ((eval:*judge* (make-instance 'stub-judge :score 0.3d0 :reasoning "No amount.")))
      (let ((grade (eval:grade-run g run)))
        (is (not (eval:grade-passed-p grade)))
        (is (= 0.3d0 (eval:grade-score grade)))
        (is (search "below" (eval:grade-reason grade)))))
    (let ((eval:*judge* (make-instance 'stub-judge :score 0.7d0)))
      (is (%passes g run)))))

(test rubric-fails-when-the-judge-fails-or-scores-out-of-range
  (let ((g (eval:rubric "Anything."))
        (run (%run :answer "x")))
    (let ((eval:*judge* (make-instance 'stub-judge :score 7)))
      (is (not (%passes g run)))
      (is (search "not from 0 to 1" (%reason g run))))
    (let ((eval:*judge* (make-instance 'failing-judge)))
      (is (not (%passes g run)))
      (is (search "the judge is unavailable" (%reason g run))))))

(llm:register-provider-impl "eval-test-judge"
                            (lambda () (make-instance 'stub-judge :score 1)))

(test the-judge-is-configured-as-its-own-role
  (let ((saved (uiop:getenv "PRAXEON_JUDGE_IMPL")))
    (unwind-protect
         (progn
           (setf (uiop:getenv "PRAXEON_JUDGE_IMPL") "eval-test-judge")
           (is (typep (eval:make-judge) 'stub-judge))
           ;; another role reads its own PRAXEON_<ROLE>_IMPL
           (setf (uiop:getenv "PRAXEON_GRADER2_IMPL") "eval-test-judge")
           (is (typep (eval:make-judge :role :grader2) 'stub-judge))
           (let ((given (make-instance 'failing-judge)))
             (is (eq given (eval:make-judge :provider given)))))
      (setf (uiop:getenv "PRAXEON_JUDGE_IMPL") (or saved "")
            (uiop:getenv "PRAXEON_GRADER2_IMPL") ""))))

(test a-custom-grader-and-a-grader-that-signals
  (let ((g (eval:make-grader "short" (lambda (run)
                                       (if (< (length (eval:run-answer run)) 10)
                                           (eval:passing-grade "short enough")
                                           (eval:failing-grade "too long" :score 0.2d0))))))
    (is (%passes g (%run :answer "ok")))
    (is (not (%passes g (%run :answer "this is far too long"))))
    (is (= 0.2d0 (eval:grade-score (eval:grade-run g (%run :answer "this is far too long"))))))
  (let ((g (eval:make-grader "broken" (lambda (run) (declare (ignore run)) (error "grader bug")))))
    (is (not (%passes g (%run))))
    (is (search "grader bug" (%reason g (%run))))))

;;; --- the typed core -------------------------------------------------------------------

(test pass-rates-and-the-gate-in-the-core
  (is (< (abs (- (core:pass-rate 2 3) 2/3)) 1d-12) "2 of 3")
  (is (= 0d0 (core:pass-rate 0 0)))
  (is (core:case-met? 2 3 0.5d0))
  (is (not (core:case-met? 1 3 0.5d0)))
  (is (not (core:case-met? 0 0 0d0)) "a case with no runs is not met")
  (let ((baseline (core:make-results '("a" "b" "c") '(2 2 2) '(2 2 0) '(1d0 1d0 1d0)))
        (current (core:make-results '("a" "b" "d") '(2 2 2) '(2 1 2) '(1d0 1d0 1d0))))
    (is (= 3 (core:results-case-count current)))
    (is (= 2 (core:results-cases-met current)))
    (is (< (abs (- (core:results-pass-rate current) (/ (+ 1 1/2 1) 3))) 1d-12))
    (is (equal '("met" "regressed" "new") (core:change-labels current baseline)))
    (is (equal '("b") (core:regressions current baseline)))
    (is (equal '("c") (core:removed-cases current baseline)))
    (is (equal '("b") (core:cases-not-met current)))
    (flet ((decide (min regressions not-met)
             (let ((g (core:gate current baseline (core:make-thresholds min regressions not-met))))
               (list (core:gate-succeeded? g) (core:gate-reasons g)))))
      (destructuring-bind (ok reasons) (decide 0d0 0 1)
        (is (not ok))
        (is (= 1 (length reasons)))
        (is (search "1 case regressed" (first reasons))))
      (destructuring-bind (ok reasons) (decide 0d0 1 0)
        (is (not ok))
        (is (search "did not meet the required pass rate" (first reasons))))
      (destructuring-bind (ok reasons) (decide 0.9d0 1 1)
        (is (not ok))
        (is (search "below the minimum 0.90" (first reasons))))
      (destructuring-bind (ok reasons) (decide 0.8d0 1 1)
        (is-true ok)
        (is (null reasons))))
    ;; with no baseline there is nothing to regress from
    (is (null (core:regressions current (core:make-results '() '() '() '()))))))

(test the-shell-checks-case-lists-before-they-enter-the-core
  (signals boundary:boundary-type-error
    (praxeon/eval::%results
     (list (praxeon/eval::%make-case-report :name :not-a-string :runs 1 :passes 1 :required 1)))))

;;; --- running cases --------------------------------------------------------------------

(test the-example-dataset-runs-against-the-example-agent
  (let* ((judge (make-instance 'stub-judge :score 0.9d0))
         (cases (ex:load-support-dataset :agent (%agent-with #'%support-script)))
         (report (eval:run-eval cases :name "support" :judge judge)))
    (is (= 3 (length cases)))
    (is (equal '("refund-delivered-order" "status-of-shipped-order" "two-turn-question")
               (mapcar #'eval:case-report-name (eval:report-cases report))))
    (is (every #'eval:case-report-met-p (eval:report-cases report)))
    (is (= 1d0 (eval:report-pass-rate report)))
    (let ((refund (first (eval:report-cases report))))
      (is (= 2 (eval:case-report-runs refund)))
      ;; each run: three model calls of 10 input and 5 output tokens, from the :usage events
      (is (= 60 (eval:case-report-input-tokens refund)))
      (is (= 30 (eval:case-report-output-tokens refund)))
      (is (integerp (eval:case-report-duration-ms refund)))
      (let ((run (first (eval:case-report-run-records refund))))
        (is (equal '("lookup-order" "issue-refund") (mapcar #'eval:call-name (eval:run-trajectory run))))
        (is (equal '(:ok :ok) (mapcar #'eval:call-outcome (eval:run-trajectory run))))
        (is (equal "I have refunded 25.00 for order A1." (eval:run-answer run)))))
    ;; the two runs of the refund case each asked the judge once
    (is (= 2 (length (judge-prompts judge))))
    (multiple-value-bind (ok reasons) (eval:gate report)
      (is-true ok)
      (is (null reasons)))))

(test a-baseline-from-a-saved-report-finds-a-regression-and-the-gate-fails
  (with-temporary-path (path "baseline.json")
    (let* ((judge (make-instance 'stub-judge :score 0.9d0))
           (good (eval:run-eval (ex:load-support-dataset :agent (%agent-with #'%support-script))
                                :name "support" :judge judge)))
      (eval:write-report good path)
      (let ((json (with-open-file (s path) (jzon:parse s))))
        (is (= 3 (gethash "cases" (gethash "total" json))))
        (is (= 2 (gethash "runs" (aref (gethash "cases" json) 0)))))
      (let* ((baseline (eval:load-report path))
             (careless (eval:run-eval
                        (ex:load-support-dataset :agent (%agent-with #'%careless-script))
                        :name "support" :judge judge :baseline baseline)))
        (is (equal '("refund-delivered-order") (eval:report-regressions careless)))
        (is (equal '("regressed" "met" "met")
                   (mapcar #'eval:case-report-change (eval:report-cases careless))))
        (multiple-value-bind (ok reasons) (eval:gate careless)
          (is (not ok))
          (is (some (lambda (r) (search "regressed" r)) reasons)))
        ;; the same run against the path itself gives the same answer
        (is (equal '("refund-delivered-order")
                   (eval:report-regressions
                    (eval:run-eval (ex:load-support-dataset :agent (%agent-with #'%careless-script))
                                   :judge judge :baseline path))))
        ;; and the summary names the failure and its reason
        (let ((text (with-output-to-string (s) (eval:summary careless s))))
          (is (search "NOT MET  refund-delivered-order" text))
          (is (search "regressed: refund-delivered-order" text))
          (is (search "trajectory: expected the calls" text)))))))

(test repeats-give-a-pass-rate
  (let* ((n 0)
         (agent (lambda ()
                  (let ((i (incf n)))
                    (ex:make-support-agent
                     :provider (make-instance 'stub-agent-provider
                                              :choose (lambda (message)
                                                        (declare (ignore message))
                                                        (list (%say (if (oddp i) "yes" "no")))))))))
         (half (eval:make-case "half" :input "?" :agent agent :repeats 4 :pass-rate 1/2
                                      :graders (list (eval:exact-match "yes"))))
         (strict (eval:make-case "strict" :input "?" :agent agent :repeats 4
                                          :graders (list (eval:exact-match "yes"))))
         (report (eval:run-eval (list half strict))))
    (destructuring-bind (h s) (eval:report-cases report)
      (is (= 2 (eval:case-report-passes h)))
      (is (= 0.5d0 (eval:case-report-pass-rate h)))
      (is-true (eval:case-report-met-p h))
      (is (= 0.5d0 (eval:case-report-pass-rate s)))
      (is (not (eval:case-report-met-p s))))
    (is (= 8 n) "every run built a fresh agent")
    (multiple-value-bind (ok reasons) (eval:gate report)
      (is (not ok))
      (is (search "strict" (first reasons))))
    (is-true (eval:gate report :max-cases-not-met 1))))

(test a-run-that-signals-fails-and-says-why
  (let* ((bad (eval:make-case "bad" :input "hi"
                                    :agent (lambda () (error "no model configured"))
                                    :graders (list (eval:contains "hi"))))
         (report (eval:run-eval (list bad)))
         (run (first (eval:case-report-run-records (first (eval:report-cases report))))))
    (is (not (eval:run-passed-p run)))
    (is (search "no model configured" (eval:run-error run)))
    (is (equal "run" (car (first (eval:run-grades run)))))
    (is (= 0 (eval:case-report-passes (first (eval:report-cases report)))))))

(test an-observer-bound-outside-the-eval-still-gets-every-event
  (let ((seen '()))
    (evt:with-observer ((lambda (e) (push (evt:event-type e) seen)))
      (eval:run-eval (list (eval:make-case "status" :input "Where is my order B2?"
                                                    :agent (%agent-with #'%support-script)
                                                    :graders (list (eval:contains "shipped"))))))
    (is (member :tool-call seen))
    (is (member :tool-result seen))
    (is (member :usage seen))
    (is (member :answer seen))))

;;; --- datasets -------------------------------------------------------------------------

(defun %write-file (path text)
  (with-open-file (s path :direction :output :if-exists :supersede :external-format :utf-8)
    (write-string text s))
  path)

(test load-dataset-refuses-malformed-cases
  (with-temporary-path (path "cases.sexp")
    (let ((agents (list (cons "support" (%agent-with #'%support-script)))))
      (flet ((load-text (text)
               (eval:load-dataset (%write-file path text) :agents agents)))
        (is (= 1 (length (load-text "((:name \"a\" :agent \"support\" :input \"x\" :graders ((:contains \"x\"))))"))))
        ;; an unknown key
        (signals eval:invalid-case
          (load-text "((:name \"a\" :agent \"support\" :input \"x\" :graders ((:contains \"x\")) :max-tokens 2))"))
        ;; an agent not in :AGENTS
        (signals eval:invalid-case
          (load-text "((:name \"a\" :agent \"other\" :input \"x\" :graders ((:contains \"x\"))))"))
        ;; a grader that does not exist
        (signals eval:invalid-case
          (load-text "((:name \"a\" :agent \"support\" :input \"x\" :graders ((:tool-call \"x\"))))"))
        ;; no graders
        (signals eval:invalid-case
          (load-text "((:name \"a\" :agent \"support\" :input \"x\" :graders ()))"))
        ;; an option a grader does not take
        (signals eval:invalid-case
          (load-text "((:name \"a\" :agent \"support\" :input \"x\" :graders ((:contains \"x\" :order :set))))"))
        ;; code in the file is refused, not run
        (signals aion/sexp:unsafe-data
          (load-text "((:name #.(error \"ran\") :agent \"support\" :input \"x\" :graders ((:contains \"x\"))))"))))))
