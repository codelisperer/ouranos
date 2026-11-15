;; The example dataset for praxeon/eval (#1224), graded against the agent in support.lisp.
;; Each case is a plist; see PRAXEON/EVAL:LOAD-DATASET for the keys and the graders.
((:name "refund-delivered-order"
  :agent "support"
  :input "My order A1 arrived broken. Please refund it."
  :repeats 2
  :graders ((:trajectory ("lookup-order"
                          ("issue-refund" :arguments (("order_id" "A1"))))
             :order :in-order)
            (:contains "25.00")
            (:rubric "The reply confirms that order A1 was refunded and states the amount, 25.00. It does not ask the customer for anything else."
             :threshold 0.7)))
 (:name "status-of-shipped-order"
  :agent "support"
  :input "Where is my order B2?"
  :graders ((:trajectory ("lookup-order") :order :exact)
            (:regex "\\bshipped\\b" :ignore-case t)))
 (:name "two-turn-question"
  :agent "support"
  :input ("Hi, I have a question about order C3." "How much did it cost?")
  :graders ((:trajectory ("lookup-order") :order :set)
            (:contains "120.00"))))
