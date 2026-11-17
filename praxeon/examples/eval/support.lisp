;;;; support.lisp --- an example agent and dataset for praxeon/eval (#1224).
;;;;
;;;; A small order-support agent with two means, lookup-order and issue-refund, over three
;;;; fixed orders, and the dataset support.sexp beside this file that grades it. RUN-EXAMPLE
;;;; runs the dataset and prints the summary:
;;;;
;;;;     (asdf:load-system "praxeon/examples/eval")
;;;;     (praxeon/examples/eval:run-example)
;;;;
;;;; With no arguments the agent uses the provider PRAXEON_LLM_* configures and the rubric
;;;; grader's judge the one PRAXEON_JUDGE_* configures, so it calls the models those name.
;;;; praxeon/eval/tests runs the same dataset with stub providers and no network.

(defpackage #:praxeon/examples/eval
  (:use #:cl)
  (:local-nicknames (#:actor #:praxeon/actor)
                    (#:llm #:praxeon/llm)
                    (#:eval #:praxeon/eval))
  (:export #:make-support-agent #:dataset-path #:load-support-dataset #:run-example
           #:*orders*))

(in-package #:praxeon/examples/eval)

(defparameter *orders*
  '(("A1" :item "kettle" :status "delivered" :total "25.00")
    ("B2" :item "lamp" :status "shipped" :total "40.00")
    ("C3" :item "chair" :status "processing" :total "120.00"))
  "The orders the example agent can see: (id :item :status :total).")

(defun %order-schema (&rest extra)
  (let ((properties (make-hash-table :test #'equal))
        (schema (make-hash-table :test #'equal)))
    (setf (gethash "order_id" properties)
          (let ((h (make-hash-table :test #'equal)))
            (setf (gethash "type" h) "string") h))
    (loop for name in extra
          do (setf (gethash name properties)
                   (let ((h (make-hash-table :test #'equal)))
                     (setf (gethash "type" h) "string") h)))
    (setf (gethash "type" schema) "object"
          (gethash "properties" schema) properties
          (gethash "required" schema) (coerce (cons "order_id" extra) 'vector))
    schema))

(defun %order (arguments)
  (assoc (and (hash-table-p arguments) (gethash "order_id" arguments)) *orders*
         :test #'equal))

(defun make-support-agent (&key provider)
  "A fresh order-support agent on PROVIDER, or on the provider PRAXEON_LLM_* configures."
  (let ((agent (actor:make-agent
                :name "support"
                :provider (or provider (llm:make-provider-from-env))
                :system-prompt "You answer questions about customers' orders. Look an order up before you say anything about it. Refund an order only when the customer asks for a refund and the order has been delivered, and then state the amount refunded.")))
    (actor:register-means
     agent "lookup-order" "Look up an order by its id: its item, status and total."
     (lambda (arguments)
       (let ((order (%order arguments)))
         (if order
             (destructuring-bind (id &key item status total) order
               (format nil "Order ~A: ~A, ~A, total ~A." id item status total))
             "No order has that id.")))
     :schema (%order-schema))
    (actor:register-means
     agent "issue-refund" "Refund a delivered order in full. Give the reason."
     (lambda (arguments)
       (let ((order (%order arguments)))
         (cond ((null order) "No order has that id.")
               ((not (equal (getf (rest order) :status) "delivered"))
                "Refused: the order has not been delivered.")
               (t (format nil "Refunded ~A for order ~A." (getf (rest order) :total)
                          (first order))))))
     :schema (%order-schema "reason"))
    agent))

(defun dataset-path ()
  "The path of the example dataset, support.sexp."
  (asdf:system-relative-pathname "praxeon/examples/eval" "examples/eval/support.sexp"))

(defun load-support-dataset (&key (agent (lambda () (make-support-agent))))
  "The example dataset's cases, with AGENT (a function returning a fresh agent) as the agent the
dataset calls \"support\"."
  (eval:load-dataset (dataset-path) :agents (list (cons "support" agent))))

(defun run-example (&key (agent (lambda () (make-support-agent))) judge baseline)
  "Run the example dataset with AGENT and JUDGE, compared with BASELINE when one is given, print
the summary, and return the report and the gate's decision."
  (let ((report (eval:run-eval (load-support-dataset :agent agent)
                               :name "support" :judge judge :baseline baseline)))
    (eval:summary report)
    (multiple-value-bind (ok reasons) (eval:gate report)
      (format t "~&gate: ~:[failed~;succeeded~]~{~%  ~A~}~%" ok reasons)
      (values report ok))))
