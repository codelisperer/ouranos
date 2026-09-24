;;;; boundary.lisp --- check list elements and Optional values before they cross into Coalton (#110)
;;;;
;;;; WHAT IS AND IS NOT CHECKED WITHOUT THIS, measured in both Coalton modes (#110):
;;;;
;;;;   a wrong value as an argument, e.g. :foo where String is declared   TYPE-ERROR on entry
;;;;   a wrong element inside a list, e.g. (list :foo) for (List String)  not checked
;;;;   any value for an (Optional X) parameter, e.g. :foo                 not checked
;;;;
;;;; An unchecked wrong value reaches code compiled on the promise that it is right. For a
;;;; String that ends in COALTON/STRING:REF-UNCHECKED, a plain CL:CHAR in unsafe code: the
;;;; result was a wrong character and "The integrity of this image is possibly compromised",
;;;; or a memory fault, depending on the value.
;;;;
;;;; WHO CALLS THIS. A CL function that passes a list or an Optional into a Coalton function
;;;; wraps that argument, in the call form:
;;;;
;;;;   (h1:encode-head-flat status
;;;;                        (boundary:check-elements (%ring-headers-flat headers) 'string
;;;;                                                 :function 'h1:encode-head-flat
;;;;                                                 :argument 'headers)
;;;;                        size keep-alive)
;;;;
;;;; scripts/coalton-boundary.lisp lists the Coalton functions that take such a parameter and
;;;; are called from CL.
;;;;
;;;; Vectors are not handled: no Coalton function the tree calls from CL takes one (#110).

(in-package #:aion/boundary)

(define-condition boundary-type-error (type-error)
  ((function :initarg :function :initform nil :reader boundary-type-error-function)
   (argument :initarg :argument :initform nil :reader boundary-type-error-argument)
   (index :initarg :index :initform nil :reader boundary-type-error-index)
   (optional-p :initarg :optional-p :initform nil :reader boundary-type-error-optional-p))
  (:report
   (lambda (c stream)
     (format stream "~@[~S: ~]" (boundary-type-error-function c))
     (if (boundary-type-error-index c)
         (format stream "element ~D of argument ~@[~A ~]is ~S, not a ~S."
                 (boundary-type-error-index c) (boundary-type-error-argument c)
                 (type-error-datum c) (type-error-expected-type c))
         (format stream "argument ~@[~A ~]is ~S, not ~:[a~;None or a~] ~S."
                 (boundary-type-error-argument c) (type-error-datum c)
                 (boundary-type-error-optional-p c) (type-error-expected-type c)))))
  (:documentation
   "A value about to cross into Coalton is not of the type the Coalton function declares.

TYPE-ERROR-DATUM is the offending value itself (for a list, the element, not the list) and
TYPE-ERROR-EXPECTED-TYPE its expected type, so a handler written for any TYPE-ERROR reports
the right thing. FUNCTION and ARGUMENT name the call; INDEX is the element's position in the
list, or NIL; OPTIONAL-P is true when the value was an (Optional X), which also accepts
None."))

(defun check-elements (list element-type &key function argument)
  "Return LIST if it is a proper list whose every element is of ELEMENT-TYPE; otherwise signal
BOUNDARY-TYPE-ERROR naming the first element that is not, and its index.

For a Coalton `(List X)' parameter. ELEMENT-TYPE is a CL type specifier: STRING for Coalton's
String, and the type's own name for a type defined with DEFINE-TYPE or DEFINE-STRUCT, which
Coalton makes a CL class. A type parameter of the element, such as the `Turn' in
`(Interceptor Turn)', does not exist at run time and cannot be checked."
  (unless (listp list)
    (error 'boundary-type-error :datum list :expected-type 'list
                                :function function :argument argument))
  (loop for tail on list
        for i from 0
        do (unless (listp (cdr tail))
             (error 'boundary-type-error :datum list :expected-type 'list
                                         :function function :argument argument))
           (unless (typep (car tail) element-type)
             (error 'boundary-type-error :datum (car tail) :expected-type element-type
                                         :function function :argument argument :index i)))
  list)

(defun %coalton-none-p (value)
  "Whether VALUE is Coalton's None.

THE ONE PLACE THE TREE READS COALTON'S REPRESENTATION OF A VALUE. docs/coalton-patterns.md §7
says CL never inspects a Coalton representation, and records this as the sanctioned
exception: an Optional parameter has no CL type, so nothing else can tell None from a wrong
value (#110). It depends on COALTON-IMPL/RUNTIME/OPTIONAL:CL-NONE-P, an internal of the
Coalton runtime, and on Some being unboxed. aion/boundary/tests checks both with values
Coalton itself constructs, so a Coalton that changes either fails that suite or this build."
  (coalton-impl/runtime/optional:cl-none-p value))

(defun check-optional (value inner-type &key function argument)
  "Return VALUE if it is None or of INNER-TYPE; otherwise signal BOUNDARY-TYPE-ERROR.

For a Coalton `(Optional X)' parameter, which Coalton does not check at all, even as a plain
argument, because `(Some x)' is represented as `x'. INNER-TYPE is the CL type of X, as for
CHECK-ELEMENTS. Not for an `(Optional (Optional X))', whose inner None is represented
differently."
  (unless (or (%coalton-none-p value) (typep value inner-type))
    (error 'boundary-type-error :datum value :expected-type inner-type
                                :function function :argument argument :optional-p t))
  value)
