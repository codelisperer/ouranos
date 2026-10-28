;;;; sexp.lisp --- tests for aion/sexp (#972).
;;;;
;;;; Each attack the issue names is refused here as UNSAFE-DATA, and beside it the standard
;;;; reader, with *READ-EVAL* NIL as apps used it, is shown falling for the same input. That
;;;; control is what shows each case is the attack the issue describes. Then the limits, the
;;;; numbers, the symbol rule, and round trips through WRITE-DATA.

(defpackage #:aion/sexp/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:sexp #:aion/sexp))
  (:export #:run-tests))

(in-package #:aion/sexp/tests)

(def-suite sexp :description "aion/sexp: a safe reader and writer for s-expression data.")
(in-suite sexp)

(defun run-tests () (run! 'sexp))

(defun %reason (thunk)
  "The REASON of the UNSAFE-DATA THUNK signals, or :NONE when it returns. Any other condition
propagates, so a test that expects a reason fails on a FLOATING-POINT-OVERFLOW or a
STORAGE-CONDITION instead of passing."
  (handler-case (progn (funcall thunk) :none)
    (sexp:unsafe-data (c) (sexp:unsafe-data-reason c))))

(defmacro reason (form) `(%reason (lambda () ,form)))

(defun %cl-read (string)
  "STRING read the way apps read data before #972: CL:READ with only *READ-EVAL* NIL."
  (let ((*read-eval* nil) (*package* (find-package :aion/sexp/tests)))
    (read-from-string string)))

(defun %fresh-name (tag)
  (format nil "SEXP-972-~A-~36R" tag (random (expt 36 8) (make-random-state t))))

;;; --- the attacks the issue names --------------------------------------------------------

(defstruct sexp-972-victim a)

(test a-struct-is-not-constructed
  "#S(...) is refused. Control: the standard reader builds the struct."
  (is (eq :dispatch-macro (reason (sexp:read-data "#S(sexp-972-victim :a 1)"))))
  (is (typep (%cl-read "#S(sexp-972-victim :a 1)") 'sexp-972-victim)))

(test read-time-evaluation-is-refused
  (is (eq :dispatch-macro (reason (sexp:read-data "#.(+ 1 2)")))))

(test a-new-symbol-is-not-interned-anywhere
  "A symbol nobody allowed, a package-qualified one, and a new keyword are refused, and no
package grows. Control: the standard reader interns each of them."
  (let ((plain (%fresh-name "PLAIN"))
        (qualified (%fresh-name "QUALIFIED"))
        (keyword (%fresh-name "KW")))
    (is (eq :unknown-symbol (reason (sexp:read-data plain))))
    (is (eq :package-prefix (reason (sexp:read-data (format nil "cl-user::~A" qualified)))))
    (is (eq :package-prefix (reason (sexp:read-data (format nil "cl-user:~A" qualified)))))
    (is (eq :unknown-symbol (reason (sexp:read-data (format nil ":~A" keyword)))))
    (is (null (find-symbol plain :aion/sexp/tests)))
    (is (null (find-symbol qualified :cl-user)))
    (is (null (find-symbol keyword :keyword)) "the keyword was not interned")
    ;; Control.
    (%cl-read plain)
    (%cl-read (format nil "cl-user::~A" qualified))
    (%cl-read (format nil ":~A" keyword))
    (is-true (find-symbol plain :aion/sexp/tests))
    (is-true (find-symbol qualified :cl-user))
    (is-true (find-symbol keyword :keyword))))

(test a-huge-object-is-not-allocated-from-a-few-characters
  "#1000000(0) is refused. Control: the standard reader makes a vector of a million elements."
  (is (eq :dispatch-macro (reason (sexp:read-data "#1000000(0)"))))
  (is (= 1000000 (length (%cl-read "#1000000(0)")))))

(test deep-nesting-is-unsafe-data-and-never-a-storage-condition
  "A million nested lists. READ-DATA refuses them at the depth limit, as UNSAFE-DATA. Control:
the standard reader exhausts the control stack, a STORAGE-CONDITION."
  (let ((deep (concatenate 'string (make-string 1000000 :initial-element #\()
                           (make-string 1000000 :initial-element #\)))))
    (is (eq :too-deep (reason (sexp:read-data deep))))
    (is (eq :storage-condition
            (handler-case (progn (%cl-read deep) :read)
              (storage-condition () :storage-condition))))))

;;; --- the other forms that are not data ---------------------------------------------------

(test every-other-form-that-is-not-data-is-refused-with-its-reason
  (dolist (case '(("#+sbcl 1" :dispatch-macro) ("#-sbcl 1" :dispatch-macro)
                  ("#P\"/etc/passwd\"" :dispatch-macro) ("#2A((1))" :dispatch-macro)
                  ("#1=(a . #1#)" :dispatch-macro) ("#(1 2)" :dispatch-macro)
                  ("#\\a" :dispatch-macro) ("'x" :reader-macro) ("`(x)" :reader-macro)
                  ("(1 ,x)" :reader-macro) ("|foo|" :escaped-symbol) ("(1 \\a)" :escaped-symbol)
                  ("; a comment" :comment) ("(1 2" :end-of-input) (")" :syntax)
                  ("(1 . )" :syntax) ("( . 1)" :syntax) ("(1 . 2 3)" :syntax)
                  ("\"open" :end-of-input) ("\"\\n\"" :syntax) ("1 2" :syntax) ("" :end-of-input)))
    (destructuring-bind (input expected) case
      (is (eq expected (reason (sexp:read-data input))) "~S" input))))

;;; --- numbers -----------------------------------------------------------------------------

(test numbers-read-as-the-standard-reader-reads-them
  (dolist (case '(("0" 0) ("-42" -42) ("+7" 7) ("12345678901234567890" 12345678901234567890)
                  ("1." 1) ("3/4" 3/4) ("-6/8" -3/4) ("1.5" 1.5) ("-0.25" -0.25) (".5" 0.5)
                  ("1e3" 1000.0) ("1.5d0" 1.5d0) ("2.5D-3" 2.5d-3) ("1f0" 1.0)))
    (destructuring-bind (input expected) case
      (let ((got (sexp:read-data input)))
        (is (and (eql got expected)) "~S read as ~S, not ~S" input got expected)))))

(test a-number-out-of-range-is-unsafe-data-and-not-an-arithmetic-error
  "#972's review: an exponent past a float's range, and a ratio over zero, are UNSAFE-DATA, not
a FLOATING-POINT-OVERFLOW or DIVISION-BY-ZERO. %REASON lets any other condition through, so
either would fail this test."
  (is (eq :number-out-of-range (reason (sexp:read-data "1e999"))))
  (is (eq :number-out-of-range (reason (sexp:read-data "1d99999"))))
  (is (eq :number-out-of-range (reason (sexp:read-data "1e39"))) "past a single float's range")
  (is (eq :number-out-of-range (reason (sexp:read-data "1d999999999"))))
  (is (eq :division-by-zero (reason (sexp:read-data "1/0")))))

(test a-float-s-type-does-not-depend-on-the-caller-s-default-format
  "#972's review: with *READ-DEFAULT-FLOAT-FORMAT* set to DOUBLE-FLOAT by the caller, 1.5 still
reads as a single float, and a round trip keeps a single float single and a double double."
  (let ((*read-default-float-format* 'double-float))
    (is (typep (sexp:read-data "1.5") 'single-float))
    (is (typep (sexp:read-data "1.5e0") 'single-float))
    (is (typep (sexp:read-data "1.5d0") 'double-float))
    (let ((back (sexp:read-data (sexp:write-data-to-string (list 1.5 1.5d0 1.0e10 1.0d-300)))))
      (is (equal '(single-float double-float single-float double-float)
                 (mapcar (lambda (x) (type-of x)) back))
          "~S" back)
      (is (equal (list 1.5 1.5d0 1.0e10 1.0d-300) back)))))

;;; --- symbols -----------------------------------------------------------------------------

(test symbols-are-folded-to-upper-case-and-must-be-allowed
  "The case rule in READ-DATA's docstring: a token is folded to upper case, as the standard
reader folds it."
  (let ((allowed (list 'sexp-972-alpha)))
    (dolist (spelling '("sexp-972-alpha" "SEXP-972-ALPHA" "Sexp-972-Alpha"))
      (is (eq 'sexp-972-alpha (sexp:read-data spelling :symbols allowed)) "~S" spelling))
    (is (eq :unknown-symbol (reason (sexp:read-data "sexp-972-beta" :symbols allowed)))))
  (is (eq :test (sexp:read-data ":Test")) "an existing keyword, in any case")
  (is (null (sexp:read-data "nil")))
  (is (eq t (sexp:read-data "T")))
  (is (eq :unwritable (reason (sexp:write-data-to-string '|lower| :symbols '(|lower|))))
      "a symbol whose name would not read back as itself is not written"))

(test new-keywords-are-interned-only-when-asked
  (let ((name (%fresh-name "OPT")))
    (is (eq :unknown-symbol (reason (sexp:read-data (format nil ":~A" name)))))
    (is (null (find-symbol name :keyword)))
    (is (eq (sexp:read-data (format nil ":~A" name) :intern-keywords t)
            (find-symbol name :keyword)))))

;;; --- limits ------------------------------------------------------------------------------

(test each-limit-accepts-its-value-and-refuses-one-more
  (flet ((nested (n) (concatenate 'string (make-string n :initial-element #\()
                                  (make-string n :initial-element #\)))))
    (is (eq :none (reason (sexp:read-data (nested 5) :max-depth 5))))
    (is (eq :too-deep (reason (sexp:read-data (nested 6) :max-depth 5)))))
  ;; A list counts once and each atom once: (1 2 3) is four elements.
  (is (eq :none (reason (sexp:read-data "(1 2 3)" :max-elements 4))))
  (is (eq :too-many-elements (reason (sexp:read-data "(1 2 3 4)" :max-elements 4))))
  (is (eq :none (reason (sexp:read-data "\"abcd\"" :max-string-length 4))))
  (is (eq :string-too-long (reason (sexp:read-data "\"abcde\"" :max-string-length 4))))
  (is (eq :none (reason (sexp:read-data "1234" :max-number-digits 4))))
  (is (eq :number-too-long (reason (sexp:read-data "12345" :max-number-digits 4))))
  (is (eq :number-too-long (reason (sexp:read-data "1/12345" :max-number-digits 4))))
  (is (eq :none (reason (sexp:read-data "(1 2)" :max-input 5))))
  (is (eq :input-too-long (reason (sexp:read-data "(1 2 )" :max-input 5)))))

;;; --- reading from a stream ----------------------------------------------------------------

(test a-stream-is-left-just-after-the-datum
  (with-input-from-string (in "(1 2) rest")
    (multiple-value-bind (datum position) (sexp:read-data in)
      (is (equal '(1 2) datum))
      (is (= 5 position))
      (is (string= " rest" (read-line in))))))

;;; --- writing ------------------------------------------------------------------------------

(test data-round-trips-through-write-and-read
  (let ((symbols (list 'sexp-972-alpha)))
    (dolist (datum (list nil t 0 -12345678901234567890 3/4 1.5 -2.5d-7 "" "a \"quoted\" \\ string"
                         '(:name "Ada" :age 36 :tags ("x" "y"))
                         '((:a . 1) (:b . "two") (:c 3 4))
                         '(1 (2 (3 (4 nil)))) (list 'sexp-972-alpha :test)
                         '(1 . 2) '(1 2 . 3)))
      (let ((text (sexp:write-data-to-string datum :symbols symbols)))
        (is (equal datum (sexp:read-data text :symbols symbols)) "~S wrote ~S" datum text)))))

(test write-data-refuses-what-read-data-would-and-writes-nothing
  (dolist (datum (list (make-sexp-972-victim :a 1) (vector 1 2) 'sexp-972-not-allowed
                       sb-ext:double-float-positive-infinity
                       (let ((l (list 1 2))) (setf (cdr (last l)) l) l)
                       (make-string 10 :initial-element #\a)))
    (let ((out (make-string-output-stream)))
      (is (eq :unwritable (reason (sexp:write-data datum out :max-string-length 5))) "~S" (type-of datum))
      (is (string= "" (get-output-stream-string out)) "nothing was written"))))

;;; --- #972's review ---------------------------------------------------------------------------

(test a-flood-of-empty-lists-is-bounded-by-the-element-limit
  "Each list counts as an element. 400 000 () under the default limit of 100 000, and 1000 ()
under a limit of 10, are both refused; before, only atoms counted and both were read."
  (flet ((flood (n) (with-output-to-string (s)
                      (write-char #\( s) (dotimes (i n) (write-string "()" s)) (write-char #\) s))))
    (is (eq :too-many-elements (reason (sexp:read-data (flood 400000)))))
    (is (eq :too-many-elements (reason (sexp:read-data (flood 1000) :max-elements 10))))
    (is (eq :none (reason (sexp:read-data (flood 9) :max-elements 10))) "control: nine () and the list")))

(test write-data-refuses-a-symbol-that-would-read-back-as-something-else
  "A symbol named 1 or 1E5 would read back as a number, and one named T or NIL that is not CL's
would read back as CL's. Each is refused; a symbol whose name reads as itself is written."
  (dolist (name '("1" "1E5" "-2/3" ".5" "T" "NIL"))
    (let ((symbol (make-symbol name)))
      (is (eq :unwritable (reason (sexp:write-data-to-string symbol :symbols (list symbol))))
          "a symbol named ~S" name)))
  (let ((symbol (make-symbol "E5")))
    (is (eq symbol (sexp:read-data (sexp:write-data-to-string symbol :symbols (list symbol))
                                   :symbols (list symbol)))
        "control: E5 is a symbol, written and read back")))

(test write-data-counts-digits-and-elements-as-read-data-does
  "Digits are counted in base 10 whatever *PRINT-BASE* and *PRINT-RADIX* are, and a list of
60 000 atoms, which READ-DATA accepts, is written."
  (let ((*print-base* 16))
    (is (eq :unwritable (reason (sexp:write-data-to-string (expt 10 110))))
        "111 digits in base 10, though fewer in base 16"))
  (let ((*print-radix* t) (n (1- (expt 10 100))))
    (is (= n (sexp:read-data (sexp:write-data-to-string n))) "100 digits, written under *PRINT-RADIX* T"))
  (let ((long (make-list 60000 :initial-element 1)))
    (is (equal long (sexp:read-data (sexp:write-data-to-string long))))))

(test write-data-checks-symbol-name-length-and-clips-what-it-reports
  (let* ((name (make-string 100 :initial-element #\A))
         (keyword (intern name :keyword))
         (c (handler-case (progn (sexp:write-data-to-string keyword :max-string-length 50) nil)
              (sexp:unsafe-data (c) c))))
    (is (and c (eq :unwritable (sexp:unsafe-data-reason c))))
    (is (and c (<= (length (sexp:unsafe-data-detail c)) 80)) "~S" (and c (sexp:unsafe-data-detail c)))
    (unintern keyword :keyword)))

(test the-symbols-argument-must-be-a-list-of-symbols
  (dolist (call (list (lambda () (sexp:read-data "1" :symbols '(1)))
                      (lambda () (sexp:write-data-to-string 1 :symbols '(1)))))
    (let ((c (handler-case (progn (funcall call) nil) (error (c) c))))
      (is (and c (not (typep c 'type-error))) "~S" c)
      (is (and c (search ":SYMBOLS" (princ-to-string c))) "~A" c))))

(test only-ascii-digits-make-a-number-and-small-exponents-may-have-leading-zeros
  "A digit of another script is not a digit here; 1e-0000001 is 0.1; and 1e-50, too small for a
single float, reads as zero, as READ-DATA's docstring says."
  (is (eq :unknown-symbol (reason (sexp:read-data (string (code-char #x663))))))
  (is (eql 0.1 (sexp:read-data "1e-0000001")))
  (is (eql 0.0 (sexp:read-data "1e-50"))))
