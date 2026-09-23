;;;; numerics.lisp --- what does Coalton's numeric tower actually cost?
;;;;
;;;;   sbcl --dynamic-space-size 4096 --script cons/bench/numerics.lisp
;;;;
;;;; The question this exists to answer, because it is the first one a skeptic asks: is a
;;;; typed functional layer over CL slower than CL? Every case below runs the SAME naive
;;;; algorithm (fib, 18.4M calls at n=34) against a hand-written CL version of it, so the
;;;; only variable is what the number IS -- fixnum, machine int, arbitrary-precision,
;;;; double -- plus one case where the type is left polymorphic.
;;;;
;;;; That last case is the interesting one, and the reason this file exists: an unannotated
;;;; Coalton definition carries `Num` dictionaries at runtime, which costs ~40x. It is the
;;;; only large number here, and it has nothing to do with the numeric stack.
;;;;
;;;; MODE MATTERS. Coalton compiles in development mode unless :coalton-release is pushed
;;;; onto *features* BEFORE Coalton loads (and the fasls are rebuilt -- see cons #98). The
;;;; header line reports which mode produced the numbers; quoting them without it is how a
;;;; benchmark becomes a lie.
(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(handler-bind ((warning #'muffle-warning))
  (ql:quickload :coalton :silent t))

(defpackage #:cons/bench/numerics (:use #:cl))
(in-package #:cons/bench/numerics)

(defparameter *n* 34 "fib argument: 18,454,929 calls at 34, 2.6x that at 36.")
(defparameter *fact-n* 20000
  "factorial argument for the bignum case. 20000! is ~77k digits; 2000! finished inside the
clock's own resolution, which is not a measurement.")
(defparameter *runs* 5
  "Runs per row. We report the MINIMUM: the fastest run is the one least interrupted by GC
and the scheduler, and a single timed run reported Coalton doubles as 2.6x FASTER than CL
-- which was a collection landing in the CL row, not a result.")

(defun elapsed-ms (thunk)
  (let* ((start (get-internal-real-time))
         (value (funcall thunk))
         (end (get-internal-real-time)))
    (values (round (* 1000 (- end start)) internal-time-units-per-second) value)))

(defvar *floor* nil "The CL baseline for the current group, in ms -- what we compare to.")

(defun bench (label thunk &key baseline (runs *runs*))
  "Run THUNK RUNS times after a full GC, print the best against *FLOOR*, and return it.
Ratios only mean something WITHIN a group -- each group sets its own baseline.

BYTES CONSED is reported because on the double-float rows it is the whole story: boxing a
return value 18M times is what separates the fast rows from the slow ones, and a timing
column alone leaves that looking like magic."
  (sb-ext:gc :full t)
  (funcall thunk)                       ; warm: first call pays for anything lazy
  (let ((best nil) (value nil) (consed nil))
    (dotimes (i runs)
      (let ((c0 (sb-ext:get-bytes-consed)))
        (multiple-value-bind (ms v) (elapsed-ms thunk)
          (setf value v)
          (when (or (null best) (< ms best))
            (setf best ms consed (- (sb-ext:get-bytes-consed) c0))))))
    (when baseline (setf *floor* (max best 1)))
    (format t "~&  ~42A ~6D ms  ~8A ~15:D B   ~A~%"
            label best
            (if (and *floor* (not baseline))
                (format nil "~,2Fx" (/ (float best) *floor*))
                "")
            consed
            (let ((s (princ-to-string value)))
              (if (> (length s) 24) (format nil "~A…(~D digits)" (subseq s 0 18) (length s)) s)))
    best))

;;; --- the CL side: hand-written, one per numeric type -----------------------

(defun cl-fib-fixnum (n)
  (declare (type fixnum n) (optimize (speed 3) (safety 0)))
  (if (< n 2) n (+ (cl-fib-fixnum (- n 1)) (cl-fib-fixnum (- n 2)))))

(defun cl-fib-generic (n)               ; no declarations at all: default policy
  (if (< n 2) n (+ (cl-fib-generic (- n 1)) (cl-fib-generic (- n 2)))))

;;; Two CL doubles, because the obvious one is not the fast one. Declaring only the ARGUMENT
;;; leaves SBCL to box every return value -- 443 MB of garbage across 18M calls. Declaring
;;; the RETURN type as well (via ftype below) removes a third of that. Neither reaches
;;; Coalton's zero, which is the finding worth reporting: comparing against the naive
;;; version alone would flatter Coalton for the wrong reason.
(defun cl-fib-double (n)
  (declare (type double-float n) (optimize (speed 3) (safety 0)))
  (if (< n 2d0) n (+ (cl-fib-double (- n 1d0)) (cl-fib-double (- n 2d0)))))

(declaim (ftype (function (double-float) double-float) cl-fib-double/typed))
(defun cl-fib-double/typed (n)
  (declare (type double-float n) (optimize (speed 3) (safety 0)))
  (if (< n 2d0) n (+ (cl-fib-double/typed (- n 1d0)) (cl-fib-double/typed (- n 2d0)))))

(defun cl-fact (n)                      ; bignum multiply: 2000! is 5736 digits
  (declare (optimize (speed 3) (safety 0)))
  (if (zerop n) 1 (* n (cl-fact (- n 1)))))

;;; --- the Coalton side: the same algorithm, five ways -----------------------
;;;
;;; Read in a Coalton package so `+`, `==` and friends are Coalton's, and compiled through
;;; EVAL so this file stays loadable by a plain `sbcl --script` with no build step.

(defpackage #:cons/bench/numerics/coalton (:use #:coalton #:coalton-prelude))

(defun ceval (src)
  (let ((*package* (find-package "CONS/BENCH/NUMERICS/COALTON")))
    (eval (read-from-string src))))

(defun fib-src (name type zero one)
  "The same definition every time, differing only in its declared type."
  (format nil "(declare ~A (~A -> ~A))
               (define (~A n)
                 (if (== n ~A) ~A
                     (if (== n ~A) ~A
                         (+ (~A (- n ~A)) (~A (- n ~A))))))"
          name type type name zero zero one one name one name
          (if (string= type "F64") "2.0d0" "2")))

(ceval (format nil "(coalton-toplevel
                      ~A
                      ~A
                      ~A
                      ~A
                      ;; No declare: inferred as (Num :a, Eq :a) => :a -> :a, and every
                      ;; arithmetic operation goes through a dictionary at RUNTIME.
                      (define (fib-poly n)
                        (if (== n 0) 0 (if (== n 1) 1 (+ (fib-poly (- n 1)) (fib-poly (- n 2))))))
                      (declare fact (Integer -> Integer))
                      (define (fact n)
                        (if (== n 0) 1 (* n (fact (- n 1))))))"
                (fib-src "fib-ifix" "IFix" "0" "1")
                (fib-src "fib-i64" "I64" "0" "1")
                (fib-src "fib-integer" "Integer" "0" "1")
                (fib-src "fib-f64" "F64" "0.0d0" "1.0d0")))

;;; Compile each Coalton call ONCE, here, and time only the call. `(coalton (fib-f64 34d0))`
;;; inside a timed thunk would re-run the Coalton COMPILER on every iteration -- worth ~1.2 MB
;;; and several ms per row, which is exactly the kind of noise that turns a benchmark into a
;;; story about the wrong thing.
(defmacro defcall (name src)
  `(let ((f (ceval ,src)))
     (defun ,name (x) (coalton:call-coalton-function f x))))

(defcall call-fib-ifix   "(coalton (fn (n) (fib-ifix n)))")
(defcall call-fib-i64    "(coalton (fn (n) (fib-i64 n)))")
(defcall call-fib-integer "(coalton (fn (n) (fib-integer n)))")
(defcall call-fib-f64    "(coalton (fn (n) (fib-f64 n)))")
(defcall call-fib-poly   "(coalton (fn (n) (fib-poly n)))")
(defcall call-fact       "(coalton (fn (n) (fact n)))")

;;; --- run --------------------------------------------------------------------

(format t "~&Coalton ~:[development~;RELEASE~] mode · SBCL ~A · ~A~%"
        (uiop:featurep :coalton-release) (lisp-implementation-version)
        (machine-type))
(format t "~&fib(~D) = ~:D calls of naive recursion; each row is the SAME algorithm.~%"
        *n* (- (* 2 9227465) 1))
(format t "~&Best of ~D runs after a warm-up call and a full GC.~%" *runs*)

(format t "~&~%FIXNUM-RANGE INTEGERS~%")
(bench "CL, (declare fixnum) (speed 3)(safety 0)" (lambda () (cl-fib-fixnum *n*)) :baseline t)
(bench "CL, undeclared, default policy" (lambda () (cl-fib-generic *n*)))
(bench "Coalton IFix" (lambda () (call-fib-ifix *n*)))
(bench "Coalton I64" (lambda () (call-fib-i64 *n*)))

(format t "~&~%ARBITRARY-PRECISION INTEGERS (the tower's own type)~%")
(bench "CL, undeclared, default policy" (lambda () (cl-fib-generic *n*)) :baseline t)
(bench "Coalton Integer" (lambda () (call-fib-integer *n*)))

(format t "~&~%DOUBLES -- watch the consing column, not the clock~%")
(bench "CL, argument type declared" (lambda () (cl-fib-double (float *n* 1d0))) :baseline t)
(bench "CL, argument AND return type declared"
       (lambda () (cl-fib-double/typed (float *n* 1d0))))
(bench "Coalton F64" (lambda () (call-fib-f64 (float *n* 1d0))))

(format t "~&~%BIGNUM MULTIPLY -- ~D! ~%" *fact-n*)
(bench "CL, (speed 3)(safety 0)" (lambda () (cl-fact *fact-n*)) :baseline t)
(bench "Coalton Integer" (lambda () (call-fact *fact-n*)))

(format t "~&~%NO TYPE ANNOTATION -- the cost of a runtime dictionary~%")
(bench "CL, (declare fixnum) (speed 3)(safety 0)" (lambda () (cl-fib-fixnum *n*)) :baseline t)
(bench "Coalton, inferred (Num :a, Eq :a) => :a -> :a" (lambda () (call-fib-poly *n*)))
(format t "~&~%  The only large ratio on this page, and it is typeclass dispatch, not~%")
(format t "~&  arithmetic: annotate the definition and it collapses to the rows above.~%")
