;;;; coalton-repl-tests.lisp --- the multi-line rule (cons/coalton-repl:input-complete-p).
;;;;
;;;; Its own package + suite, and its own test SYSTEM (cons/coalton-repl/tests): the core
;;;; cons suite depends on `cons` alone and stays Coalton-free, exactly as cons core does.
;;;;
;;;; What is worth testing here is the READER's judgement of "finished", because two front
;;;; ends bind to it -- the desktop app's input box (which mirrors it in JS) and any CLI
;;;; REPL cons grows. The cases below are the ones a paren-counter gets wrong.

(cl:defpackage #:cons/coalton-repl/tests
  (:use #:cl #:fiveam)
  (:documentation "Test suite for the headless Coalton REPL engine.")
  (:local-nicknames (#:repl #:cons/coalton-repl))
  (:export #:run-tests))
(in-package #:cons/coalton-repl/tests)

(def-suite coalton-repl :description "cons/coalton-repl engine tests.")
(in-suite coalton-repl)

(defun run-tests ()
  "Run the cons/coalton-repl suite; return T when every test passes."
  (fiveam:run! 'coalton-repl))

(test complete-forms-are-complete
  "A finished form submits -- one atom, one list, or trailing whitespace."
  (is-true (repl:input-complete-p "(+ 1 2)"))
  (is-true (repl:input-complete-p "42"))
  (is-true (repl:input-complete-p "(define (square x) (* x x))"))
  (is-true (repl:input-complete-p (format nil "(+ 1~%   2)")))
  (is-true (repl:input-complete-p (format nil "(+ 1 2)~%  "))))

(test unfinished-forms-keep-typing
  "An unclosed list, string, or block comment is the Enter-opens-a-line case."
  (is-false (repl:input-complete-p "(+ 1 2"))
  (is-false (repl:input-complete-p "(define (square x)"))
  (is-false (repl:input-complete-p (format nil "(define (f x)~%  (* x")))
  (is-false (repl:input-complete-p "(<> \"hello"))
  (is-false (repl:input-complete-p "#| open comment")))

(test parens-that-are-not-structure
  "Parens inside a string, a #\\char literal, or a ; comment are not structure --
this is where a naive counter reports the wrong answer."
  (is-true (repl:input-complete-p "(<> \"a)b\" \"c\")"))
  (is-false (repl:input-complete-p "(<> \"a(b\""))
  (is-true (repl:input-complete-p "#\\("))
  (is-true (repl:input-complete-p "(list #\\( #\\))"))
  (is-false (repl:input-complete-p (format nil "(list 1 ; a ) comment~%"))))

(test finished-but-wrong-is-complete
  "Text that can never read cleanly still SUBMITS -- eval-input reports the error.
Calling it incomplete would trap the user in a box that refuses to send."
  (is-true (repl:input-complete-p "(1 . . 2)"))
  (is-true (repl:input-complete-p ")"))
  (is-true (repl:input-complete-p "(+ 1 2))")))

(test completeness-reads-to-the-end-not-just-the-first-form
  "An input may hold SEVERAL forms. Stopping at the first would submit a `declare` the
moment its own paren closed, with the `define` under it still half-typed -- which is the
exact keystroke sequence that makes type annotations writable."
  (is-true (repl:input-complete-p
            (format nil "(declare f (Integer -> Integer))~%(define (f x) x)")))
  (is-false (repl:input-complete-p
             (format nil "(declare f (Integer -> Integer))~%(define (f x)")))
  (is-false (repl:input-complete-p (format nil "(+ 1 2)~%(* 3")))
  (is-true (repl:input-complete-p (format nil "(+ 1 2)~%(* 3 4)"))))

(test blank-is-complete
  "Nothing typed is not an unfinished form; the front end decides whether to send it."
  (is-true (repl:input-complete-p ""))
  (is-true (repl:input-complete-p (format nil "   ~%  ~A" #\Tab))))

(test probe-does-not-evaluate
  "#. must not fire while someone is still typing: *read-eval* is off for the probe.
The reader-error counts as complete, and eval-input reads it for real afterwards."
  (let ((fired nil))
    (declare (ignorable fired))
    (is-true (repl:input-complete-p "#.(error \"read-eval fired during the probe\")"))))

;;; --- evaluation: several forms per input ------------------------------------
;;;
;;; These actually compile Coalton, so they are slower than the reader tests above. They
;;; earn it: a `declare` reaching its `define` is the difference between the REPL's
;;; definitions being annotated or silently polymorphic (~47x on arithmetic-heavy code).

(defun %ev (session src)
  (repl:eval-input session src))

(test declare-reaches-its-define
  "The regression this exists to prevent: `declare` and `define` in ONE input compile in
one coalton-toplevel. Compiled separately, Coalton rejects the declare as an orphan."
  (let* ((s (repl:make-session "COALTON-REPL-TESTS-DECLARE"))
         (r (%ev s (format nil "(declare tw (Integer -> Integer))~%(define (tw x) (* 2 x))"))))
    (is (eq :definition (repl:result-kind r))
        "expected a definition, got ~A: ~A" (repl:result-kind r) (repl:result-message r))
    ;; declare + define name one thing, and it is reported once.
    (is (string-equal "TW" (repl:result-message r)))
    (let ((call (%ev s "(tw 21)")))
      (is (eq :value (repl:result-kind call)))
      (is (string= "42" (repl:result-value call))))))

(test several-forms-evaluate-in-order-and-the-last-value-wins
  "Definitions register, and the value reported is the last expression's -- the one the
reader is actually asking about."
  (let* ((s (repl:make-session "COALTON-REPL-TESTS-SEVERAL"))
         (r (%ev s (format nil "(define (inc x) (+ 1 x))~%(inc 1)~%(inc 41)"))))
    (is (eq :value (repl:result-kind r)))
    (is (string= "42" (repl:result-value r)))))

(test a-definition-only-input-reports-every-name
  (let* ((s (repl:make-session "COALTON-REPL-TESTS-NAMES"))
         (r (%ev s (format nil "(define one 1)~%(define two 2)"))))
    (is (eq :definition (repl:result-kind r)))
    (is (search "ONE" (string-upcase (repl:result-message r))))
    (is (search "TWO" (string-upcase (repl:result-message r))))))

(test a-broken-form-is-an-error-result-not-a-signal
  (let* ((s (repl:make-session "COALTON-REPL-TESTS-ERR"))
         (r (%ev s "(this-name-is-not-defined-anywhere 1)")))
    (is (eq :error (repl:result-kind r)))
    (is (plusp (length (repl:result-message r))))))

(test session-package-is-used-for-reading
  "Given a SESSION, symbols intern where eval-input would put them, not in *package*."
  (let* ((s (repl:make-session "COALTON-REPL-TESTS-SESSION"))
         (name (repl:session-package-name s)))
    (is-true (repl:input-complete-p "(a-symbol-only-this-test-mentions)" s))
    (is-true (find-symbol "A-SYMBOL-ONLY-THIS-TEST-MENTIONS" name))))
