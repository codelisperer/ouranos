;;;; core/packages.lisp --- the package of dokimasia/core (#1028).
;;;;
;;;; DOKIMASIA/CORE is Coalton and does no IO: the result of each step of a row, and the rule
;;;; that turns a row's step results into its verdict. The CL shell, DOKIMASIA, runs the steps in
;;;; a browser and hands their results here.

(cl:defpackage #:dokimasia/core
  (:use #:coalton #:coalton-prelude)
  (:local-nicknames (#:list #:coalton-library/list))
  (:documentation "The typed core of dokimasia (#1028): step results and a row's verdict. Pure.")
  (:export
   #:make-row-results #:row-step-count
   #:steps-passed #:steps-failed #:steps-not-run #:total-duration-ms
   #:row-verdict #:verdict-kind #:verdict-step-index #:verdict-step-label #:verdict-reason))
