;;;; packages.lisp --- aion/boundary (#110)

(defpackage #:aion/boundary
  (:use #:cl)
  (:documentation
   "Checks for the part of a CL-to-Coalton call that nothing else checks.

A Coalton function called from CL checks the outer type of each argument on entry: a keyword
where a String is declared signals a TYPE-ERROR. It does not check the elements of a list, so
a keyword inside a `(List String)' gets through, and code that trusts the element type can
return a wrong answer or corrupt the image (#110). An `(Optional X)' parameter is not checked
at all, because Coalton represents `(Some x)' as `x' itself and the parameter has no CL type.

A CL function that passes such a value into Coalton wraps it in CHECK-ELEMENTS or
CHECK-OPTIONAL. Both return the value, so the check sits inside the call form. On a wrong
value they signal BOUNDARY-TYPE-ERROR, a TYPE-ERROR whose datum is the offending element.")
  (:export #:boundary-type-error
           #:boundary-type-error-function
           #:boundary-type-error-argument
           #:boundary-type-error-index
           #:boundary-type-error-optional-p
           #:check-elements
           #:check-optional))
