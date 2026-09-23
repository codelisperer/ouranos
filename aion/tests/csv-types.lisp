;;;; csv-types.lisp --- the typed CSV core: totality, the Dialect invariant, conformance.
;;;;
;;;; The conformance suite is the reason this file exists. A type that nothing executes is
;;;; a comment with syntax highlighting, and aion/csv deliberately does NOT depend on the
;;;; typed core (it is dependency-free so the portable backend loads on bare
;;;; SBCL/CCL/ECL/ABCL). What keeps the types honest instead is differential testing: the
;;;; same corpus goes through the Coalton reference parser -- built entirely from the typed
;;;; transition -- and through the shipping CL parser, and the two must agree exactly. If
;;;; someone edits the ECASE in parse.lisp and breaks a rule, this fails.
;;;;
;;;; Boundary rule (docs/coalton-patterns.md §7): nothing here constructs or inspects a
;;;; ParseState, Action, Step or Dialect. Everything crosses as String, Boolean, Integer or
;;;; List -- representations Coalton actually promises across compilation modes.

(cl:defpackage #:aion/csv/types/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:ty  #:aion/csv/types)
                    (#:csv #:aion/csv))
  (:export #:run-tests #:aion-csv-types))
(in-package #:aion/csv/types/tests)

(def-suite aion-csv-types
  :description "The typed CSV core: a total transition, a checked Dialect, and conformance
with the shipping parser.")
(in-suite aion-csv-types)

;;; --- totality --------------------------------------------------------------

(test the-transition-is-total-over-every-state-and-input-class
  ;; 4 states x 8 classes x seen? x skip-blank? = 128 cells, every one answered. The ECASE
  ;; in parse.lisp cannot state this property; here the compiler enforces it and this test
  ;; confirms it from the CL side as well.
  (let ((cells 0))
    (dolist (state ty:state-names)
      (dolist (class ty:class-names)
        (dolist (seen '(nil t))
          (dolist (skip-blank '(nil t))
            (let ((answer (ty:step-names state class seen skip-blank)))
              (incf cells)
              (is (= 2 (length answer))
                  "no transition for (~A, ~A, seen=~A, skip-blank=~A)" state class seen skip-blank)
              (is (member (first answer)
                          '("nothing" "add" "add-quote" "take-escaped" "emit-field"
                            "finish-row" "skip-line" "end-input" "fail")
                          :test #'string=))
              (is (member (second answer) ty:state-names :test #'string=)))))))
    (is (= 128 cells))))

(test an-unknown-state-or-class-yields-no-transition
  ;; The boundary is closed: a name that is not a state is not silently coerced into one.
  (is (null (ty:step-names "dancing" "quote" nil nil)))
  (is (null (ty:step-names "start" "semaphore" nil nil))))

(test the-load-bearing-cells-are-what-the-parser-needs
  ;; A handful of transitions spelled out, so a future edit that "simplifies" the table
  ;; has to change a test that says why the cell is what it is.
  (flet ((act (st cl &optional seen skip) (first (ty:step-names st cl seen skip))))
    ;; a quote at the start of a field opens a quoted field and is not itself data
    (is (string= "nothing" (act "start" "quote")))
    ;; ...but mid-field it is ordinary text (RFC 4180 gives it meaning only at field start)
    (is (string= "add" (act "unquoted" "quote")))
    ;; end of input inside a quoted field is the one malformed case
    (is (string= "fail" (act "quoted" "eof")))
    ;; a doubled quote is a literal quote, not the end of the field
    (is (string= "add-quote" (act "quote-end" "quote")))
    ;; end of input with nothing pending is exhaustion, not an empty row
    (is (string= "end-input" (act "start" "eof" nil)))
    ;; ...but with a record in progress it must still emit that record
    (is (string= "finish-row" (act "start" "eof" t)))
    ;; a newline on an untouched line is a record unless the dialect skips blanks
    (is (string= "finish-row" (act "start" "newline" nil nil)))
    (is (string= "nothing"    (act "start" "newline" nil t)))))

;;; --- the Dialect invariant -------------------------------------------------

(test a-delimiter-equal-to-its-quote-is-not-a-dialect
  ;; The CL DEFSTRUCT types every slot independently and relates none of them, so this
  ;; dialect is constructible today and simply misbehaves: the same byte would both end a
  ;; field and open a quoted one, and which happens depends on clause order.
  (is (not (ty:dialect-chars-ok? #\, #\,)))
  (is (not (ty:dialect-chars-ok? #\Tab #\Tab)))
  (is (ty:dialect-chars-ok? #\, #\"))
  (is (ty:dialect-chars-ok? #\Tab #\"))
  ;; and the CL struct really does accept the bad one -- this is the gap, stated as a test
  (is (csv:dialect-p (csv:make-dialect :delimiter #\, :quote #\,))))

;;; --- conformance: the typed reference vs the shipping parser ---------------

(defparameter *corpus*
  '(;; the ordinary shapes
    "a,b,c"
    "a,b,c
d,e,f"
    "a,b,c
"
    "one"
    ""
    ;; empty fields, in every position
    ",,"
    "a,,c"
    ",a"
    "a,"
    ;; quoting: the whole point of the machine
    "\"a\",\"b\""
    "\"x,y\",z"
    "\"line1
line2\",b"
    "\"a\"\"b\""
    "\"\""
    "\"\",\"\""
    ;; a quote that is only text
    "a\"b,c"
    ;; text after a closing quote -- both parsers are deliberately lenient here
    "\"ab\"cd,e"
    ;; CRLF, which must be ONE terminator and not produce a phantom empty row
    "a,b
c,d"
    ;; ragged rows are not an error in CSV
    "a,b,c
d"
    ;; a lone newline is an empty record when blank-skipping is off (the default)
    "
"
    "a

b")
  "Inputs chosen for the places the two implementations could disagree, not for coverage
of the happy path. Each was picked because some cell of the transition table decides it.")

(defun %cl-rows (text)
  "The shipping parser's rows, as lists of strings."
  (mapcar (lambda (row) (coerce row 'list)) (csv:parse-string text)))

(test the-typed-reference-and-the-shipping-parser-agree
  ;; Two independent implementations of the same specification. Neither is checking itself.
  (dolist (text *corpus*)
    (let ((typed (ty:parse-rfc4180-rows text))
          (shipped (%cl-rows text)))
      (is (equal shipped typed)
          "disagreement on ~S~%  shipping: ~S~%  typed:    ~S" text shipped typed))))

(test both-reject-an-unterminated-quoted-field
  ;; The one input the machine calls malformed, agreed on from both sides.
  (dolist (text '("\"abc" "a,\"bc" "\"a\"\"" "x,y
\"unterminated"))
    (is (not (ty:parse-rfc4180-ok? text)) "typed core accepted ~S" text)
    (signals csv:csv-parse-error (csv:parse-string text))))

(test the-typed-parser-handles-crlf-as-one-terminator
  ;; Called out separately because it is the divergence that differential testing found:
  ;; a naive transition finishes the row on the CR and then finishes another on the LF.
  (is (equal '(("a" "b") ("c" "d")) (ty:parse-rfc4180-rows (format nil "a,b~C~Cc,d" #\Return #\Newline))))
  (is (equal (%cl-rows (format nil "a,b~C~Cc,d" #\Return #\Newline))
             (ty:parse-rfc4180-rows (format nil "a,b~C~Cc,d" #\Return #\Newline)))))

(defun run-tests ()
  "Run the typed-CSV suite; return T on success (for `asdf:test-system`)."
  (run! 'aion-csv-types))
