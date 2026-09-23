;;;; conditions.lisp --- the recoverable-failure protocol for Praxeon
;;;;
;;;; Long-running agentic systems fail partially and often: a tool times out, a
;;;; provider rate-limits, a plan step returns garbage. CL's condition system is
;;;; close to ideal here: the code that SIGNALS a failure need not decide how to
;;;; recover; policy is injected at the handler. The invoker of a means should
;;;; establish the restarts below so that a supervising handler (or a human at
;;;; the REPL) can choose retry / substitute / abandon.

(cl:in-package #:praxeon/conditions)

(define-condition praxeon-error (error)
  ()
  (:documentation "Root of all Praxeon-signalled errors."))

(define-condition means-failure (praxeon-error)
  ((means :initarg :means :reader means-failure-means)
   (cause :initarg :cause :initform nil :reader means-failure-cause))
  (:report (lambda (c stream)
             (format stream "The means ~A failed~@[: ~A~]."
                     (means-failure-means c)
                     (means-failure-cause c))))
  (:documentation "Signalled when applying a means does not succeed."))

(define-condition deliberation-failure (praxeon-error)
  ((detail :initarg :detail :initform nil :reader deliberation-failure-detail))
  (:report (lambda (c stream)
             (format stream "Deliberation failed~@[: ~A~]."
                     (deliberation-failure-detail c))))
  (:documentation "Signalled when the actor cannot decide on an action."))

(define-condition missing-provenance (praxeon-error)
  ((operation :initarg :operation :initform nil :reader missing-provenance-operation)
   (subject :initarg :subject :initform nil :reader missing-provenance-subject))
  (:report
   (lambda (c s)
     (format s "~@[~A ~]refused: an observation~@[ about ~A~] must say where it came from.~%~%"
             (missing-provenance-operation c) (missing-provenance-subject c))
     (format s "Observational memory is personal data held indefinitely, and a remembered claim that cannot be traced to a conversation and a turn cannot be CORRECTED -- a member disputing it has nothing to point at, and a persona repeating it has nothing to check (#415).~%")
     (format s "Pass :provenance (praxeon/memory:make-provenance conversation turn). It is required rather than defaulted because a fabricated source is worse than an absent one: it reads as a citation.")))
  (:documentation "Signalled when a write to memory carries no provenance."))

(define-condition embedding-dimension-mismatch (praxeon-error)
  ((provider :initarg :provider :initform nil :reader embedding-dimension-mismatch-provider)
   (expected :initarg :expected :reader embedding-dimension-mismatch-expected)
   (actual :initarg :actual :reader embedding-dimension-mismatch-actual)
   (source :initarg :source :initform nil :reader embedding-dimension-mismatch-source))
  (:report
   (lambda (c s)
     (format s "Embedding width is ~D where ~D was expected~@[ (~A)~]~@[, from ~A~].~%~%"
             (embedding-dimension-mismatch-actual c)
             (embedding-dimension-mismatch-expected c)
             (embedding-dimension-mismatch-source c)
             (embedding-dimension-mismatch-provider c))
     (format s "The dimension is a property of the DEPLOYMENT, not of the code (#415): a schema declaring 1536 has declared OpenAI's text-embedding-3-small, and pointing the same schema at a 768-wide model is a configuration error rather than a bad row.~%")
     (format s "Signalled here so the message names the misconfiguration. mnemosyne refuses the wrong width again at cast time, but that error names a column, which is a long way from the variable that caused it.")))
  (:documentation "Signalled when an embedding's width is not the width that was declared."))

(define-condition tool-choice-unsupported (praxeon-error)
  ((provider :initarg :provider :initform nil :reader tool-choice-unsupported-provider)
   (requested :initarg :requested :initform nil :reader tool-choice-unsupported-requested))
  (:report
   (lambda (c s)
     (format s "~A cannot honour the tool choice ~S.~%~%~
This is signalled rather than falling back to :auto on purpose. A caller that forced a tool ~
is about to treat the reply as a record; letting the model answer freely instead returns ~
prose, and nothing downstream can tell the difference until it is stored."
             (or (tool-choice-unsupported-provider c) "This provider")
             (tool-choice-unsupported-requested c))))
  (:documentation "Signalled when a forced TOOL-CHOICE reaches a provider that cannot do it."))
(define-condition parallel-child-failure (praxeon-error)
  ((failures :initarg :failures :initform nil :reader parallel-child-failure-failures)
   (completed :initarg :completed :initform nil :reader parallel-child-failure-completed))
  (:report (lambda (c stream)
             (format stream "~D of ~D children of a PARALLEL group failed (~{~A~^, ~}); the ~D that succeeded are merged and on the blackboard."
                     (length (parallel-child-failure-failures c))
                     (+ (length (parallel-child-failure-failures c))
                        (length (parallel-child-failure-completed c)))
                     (mapcar #'car (parallel-child-failure-failures c))
                     (length (parallel-child-failure-completed c)))))
  (:documentation "Signalled when one or more children of a PARALLEL group signalled.

FAILURES is an alist of (child-name . condition). COMPLETED names the children that
succeeded and whose outputs WERE merged into the blackboard before this was signalled.

BOTH SLOTS EXIST BECAUSE A FAN-OUT HAS PARTIAL OUTCOMES and the sequential implementation
had no way to express one: a `dolist' unwound on the first error, so children after it never
ran and children before it were discarded along with the accumulated writes. One provider
hiccup cost every sibling's work, and nothing said so. Concurrency makes the partial outcome
unavoidable and therefore reportable -- every child runs to completion, what succeeded is
merged, and this names what did not (#418)."))

(define-condition budget-exceeded (praxeon-error)
  ((requested :initarg :requested :reader budget-exceeded-requested)
   (available :initarg :available :reader budget-exceeded-available))
  (:report (lambda (c stream)
             (format stream "Context budget exceeded: needed ~A, ~A available."
                     (budget-exceeded-requested c)
                     (budget-exceeded-available c))))
  (:documentation "Signalled when context assembly cannot fit within budget."))

;;; Restart invokers. Establish these around the application of a means so a
;;; handler can select recovery without unwinding the whole agent loop.

(defun retry-action (&optional condition)
  "Invoke the RETRY-ACTION restart, re-attempting the failed means."
  (let ((r (find-restart 'retry-action condition)))
    (when r (invoke-restart r))))

(defun substitute-result (value &optional condition)
  "Invoke SUBSTITUTE-RESULT, supplying VALUE in place of the means' result."
  (let ((r (find-restart 'substitute-result condition)))
    (when r (invoke-restart r value))))

(defun abandon-action (&optional condition)
  "Invoke ABANDON-ACTION, giving up on the current action."
  (let ((r (find-restart 'abandon-action condition)))
    (when r (invoke-restart r))))
