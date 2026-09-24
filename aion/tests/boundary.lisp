;;;; boundary.lisp --- tests for aion/boundary (#110)
;;;;
;;;; The Optional values here are built by Coalton, not by CL, because what CHECK-OPTIONAL
;;;; relies on is how Coalton represents them: Some unboxed and None recognised by
;;;; COALTON-IMPL/RUNTIME/OPTIONAL:CL-NONE-P. A Coalton that boxes Some fails
;;;; `coalton-built-optionals-are-accepted', and one that removes CL-NONE-P fails the build.

(defpackage #:aion/boundary/tests/values
  (:use #:coalton #:coalton-prelude)
  (:export #:some-string #:none-string #:some-integer))

(in-package #:aion/boundary/tests/values)

(coalton-toplevel
  (declare some-string (Optional String))
  (define some-string (Some "abc"))
  (declare none-string (Optional String))
  (define none-string None)
  (declare some-integer (Optional Integer))
  (define some-integer (Some 12)))

(defpackage #:aion/boundary/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:b #:aion/boundary) (#:v #:aion/boundary/tests/values))
  (:export #:run-tests))

(in-package #:aion/boundary/tests)

(def-suite boundary :description "aion/boundary (#110).")
(in-suite boundary)

(defun run-tests () (run! 'boundary))

(defun %signal-of (thunk)
  "The BOUNDARY-TYPE-ERROR THUNK signals, or NIL if it returns."
  (handler-case (progn (funcall thunk) nil)
    (b:boundary-type-error (e) e)))

(test a-list-of-the-right-type-is-returned-unchanged
  (let ((xs (list "a" "b" "c")))
    (is (eq xs (b:check-elements xs 'string)))
    (is (null (b:check-elements '() 'string)))))

(test a-wrong-element-is-named-by-its-index
  (let ((e (%signal-of (lambda () (b:check-elements (list "a" "b" :c "d") 'string
                                                    :function 'encode-head :argument 'headers)))))
    (is (typep e 'b:boundary-type-error))
    (is (eql 2 (b:boundary-type-error-index e)))
    (is (eq 'encode-head (b:boundary-type-error-function e)))
    (is (eq 'headers (b:boundary-type-error-argument e)))
    (is (search "element 2 of argument HEADERS is :C, not a STRING" (princ-to-string e))
        "report: ~A" e)))

(test a-generic-type-error-handler-sees-the-element-not-the-list
  ;; The ruling on #110: a handler written for plain TYPE-ERROR reports the element.
  (let ((seen (handler-case (b:check-elements (list "a" 42) 'string)
                (type-error (e) (list (type-error-datum e) (type-error-expected-type e))))))
    (is (equal '(42 string) seen))))

(test something-that-is-not-a-proper-list-signals
  (is (typep (%signal-of (lambda () (b:check-elements :foo 'string))) 'b:boundary-type-error))
  (is (typep (%signal-of (lambda () (b:check-elements (cons "a" "b") 'string)))
             'b:boundary-type-error)))

(test coalton-built-optionals-are-accepted
  ;; Some and None as Coalton itself builds them. If Coalton boxed Some, the first would not
  ;; be a STRING and this would fail.
  (is (equal "abc" (b:check-optional v:some-string 'string)))
  (is (eq v:none-string (b:check-optional v:none-string 'string))))

(test an-optional-of-the-wrong-inner-type-signals
  ;; A Coalton-built (Some 12) where (Optional String) is expected, and a bare CL keyword.
  (let ((e (%signal-of (lambda () (b:check-optional v:some-integer 'string
                                                    :function 'money-or :argument 'amount)))))
    (is (typep e 'b:boundary-type-error))
    (is (b:boundary-type-error-optional-p e))
    (is (null (b:boundary-type-error-index e)))
    (is (search "argument AMOUNT is 12, not None or a STRING" (princ-to-string e))
        "report: ~A" e))
  (is (typep (%signal-of (lambda () (b:check-optional :foo 'string))) 'b:boundary-type-error)))
