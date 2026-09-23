;;;; tests/interceptor.lisp --- the typed interceptor pipeline (#177).
;;;;
;;;; This code was written, exported, documented, and shipped inside a system reporting
;;;; green -- with NO TEST OF ANY KIND. 146 lines of short-circuiting control flow, and
;;;; nothing in any suite referenced `execute`, `Halt`, or `Proceed`. That is the adjacent
;;;; case to #116: not a suite that cannot run, but code that no suite covers, inside a
;;;; system whose green said nothing about it. It is about to carry budget enforcement for
;;;; a public agent endpoint (#172), so it gets covered before it carries anything.
;;;;
;;;; The properties worth pinning are the ones a chain can get subtly wrong and still
;;;; appear to work: that `leave` runs in REVERSE, that a `Halt` unwinds the stages that
;;;; already entered (and only those), and that `execute-effect` SKIPS the effect on a
;;;; short-circuit -- which is the whole point of a guard, and the property #172 depends
;;;; on for a refusal that actually refuses rather than being appended to a reply.
;;;;
;;;; Contexts here are String and Integer rather than a define-type: parametricity is
;;;; proven by `execute`'s type, not by an example, so the tests spend their effort on
;;;; control flow instead.

;;; --- Coalton-side fixtures, and monomorphic wrappers so CL can drive them --
;;;
;;; A typeclass-free monomorphic wrapper per behaviour, because that is how a Coalton
;;; function becomes callable from CL. `drive`/`drive-effect` take the CHAIN as a
;;; parameter so one wrapper serves every case below.

(cl:defpackage #:aion/interceptor/tests/fixtures
  (:use #:coalton #:coalton-prelude)
  (:local-nicknames (#:ic #:aion/interceptor))
  (:export #:trace-chain #:halt-chain #:fail-chain #:number-chain
           #:run-string #:run-integer #:run-effect
           #:outcome #:proceeded #:halted #:failed #:message-of))
(cl:in-package #:aion/interceptor/tests/fixtures)
(named-readtables:in-readtable coalton:coalton)

(coalton-toplevel

  ;; A stage that appends its mark on the way in and again on the way out, so the final
  ;; string IS the execution order -- enter marks in order, leave marks in reverse.
  (declare marker (String * String * String -> (ic:Interceptor String)))
  (define (marker n in out)
    (ic:Interceptor n
                    (fn (c) (ic:Proceed (<> c in)))
                    (fn (c) (ic:Proceed (<> c out)))))

  (declare trace-chain (List (ic:Interceptor String)))
  (define trace-chain
    (make-list (marker "a" "a>" "<a")
               (marker "b" "b>" "<b")
               (marker "c" "c>" "<c")))

  ;; Same, but the middle stage halts on entry: c must never enter, and only a and b
  ;; may unwind.
  (declare halt-chain (List (ic:Interceptor String)))
  (define halt-chain
    (make-list (marker "a" "a>" "<a")
               (ic:Interceptor "stop" (fn (c) (ic:Halt (<> c "STOP"))) ic:Proceed)
               (marker "c" "c>" "<c")))

  (declare fail-chain (List (ic:Interceptor String)))
  (define fail-chain
    (make-list (marker "a" "a>" "<a")
               (ic:Interceptor "boom" (fn (c) (ic:Failure "boom" c)) ic:Proceed)
               (marker "c" "c>" "<c")))

  (declare number-chain (List (ic:Interceptor Integer)))
  (define number-chain
    (make-list (ic:on-enter "add10" (fn (c) (ic:Proceed (+ c 10))))
               (ic:on-enter "cap" (fn (c) (if (> c 100) (ic:Halt c) (ic:Proceed c))))))

  ;;; --- monomorphic wrappers ------------------------------------------------

  (declare run-string ((List (ic:Interceptor String)) * String -> String))
  (define (run-string chain c) (ic:flow-context (ic:execute chain c)))

  (declare run-integer ((List (ic:Interceptor Integer)) * Integer -> Integer))
  (define (run-integer chain c) (ic:flow-context (ic:execute chain c)))

  ;; The effect is a PARAMETER, so the CL shell supplies it -- this is the seam that lets
  ;; an LLM call, a DB write or a network round-trip sit in a pure pipeline.
  (declare run-effect ((List (ic:Interceptor Integer)) * (Integer -> Integer) * Integer
                       -> Integer))
  (define (run-effect chain effect c)
    (ic:flow-context (ic:execute-effect chain effect c)))

  ;; Outcome as a String, so CL can assert on it without touching the ADT's representation.
  (declare outcome ((List (ic:Interceptor String)) * String -> String))
  (define (outcome chain c)
    (match (ic:execute chain c)
      ((ic:Proceed _) "proceed")
      ((ic:Halt _) "halt")
      ((ic:Failure _ _) "failure")))

  (declare message-of ((List (ic:Interceptor String)) * String -> String))
  (define (message-of chain c)
    (match (ic:execute chain c)
      ((ic:Failure m _) m)
      (_ ""))))


(cl:defpackage #:aion/interceptor/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:fx #:aion/interceptor/tests/fixtures))
  (:export #:run-tests))
(cl:in-package #:aion/interceptor/tests)

(def-suite interceptor :description "The typed interceptor pipeline.")
(defun run-tests () (run! 'interceptor))
(in-suite interceptor)

;;; --- the happy path --------------------------------------------------------

(test enter-runs-forward-and-leave-runs-in-reverse
  ;; The property most easily got backwards, and one that still "works" if you get it
  ;; wrong -- until a stage depends on an outer stage having already unwound.
  (is (string= "a>b>c><c<b<a" (fx:run-string fx:trace-chain ""))
      "enter in order, leave in REVERSE order")
  (is (string= "proceed" (fx:outcome fx:trace-chain ""))))

(test the-context-is-threaded-through-every-stage
  (is (= 15 (fx:run-integer fx:number-chain 5))))

;;; --- short-circuit ---------------------------------------------------------

(test halt-stops-entering-and-unwinds-only-what-entered
  ;; `c` must never enter, and must therefore never leave. A pipeline that unwound the
  ;; whole chain regardless would run cleanup for a stage that never set anything up.
  (let ((result (fx:run-string fx:halt-chain "")))
    (is (string= "a>STOP<a" result)
        "only the stages that entered may unwind; got ~S" result)
    (is (not (search "c>" result)) "the stage after the halt must not enter")
    (is (not (search "<c" result)) "and must not leave")))

(test halt-is-reported-as-halt-not-as-success
  ;; A caller has to be able to tell "refused" from "completed" -- #172 depends on this
  ;; to render a refusal rather than an empty reply.
  (is (string= "halt" (fx:outcome fx:halt-chain ""))))

(test failure-carries-its-message-and-the-context-at-the-point-of-failure
  (is (string= "failure" (fx:outcome fx:fail-chain "")))
  (is (string= "boom" (fx:message-of fx:fail-chain "")))
  (let ((result (fx:run-string fx:fail-chain "")))
    (is (string= "a>" (subseq result 0 2)) "context up to the failure is preserved")
    (is (not (search "c>" result)) "and nothing after it entered")))

;;; --- effects at the edge ---------------------------------------------------

(test the-effect-runs-between-enter-and-leave-and-is-supplied-by-cl
  ;; The seam that makes this usable from an effectful shell at all: the pipeline stays
  ;; pure and the one impure pivot is a parameter, here an ordinary CL closure.
  (is (= 1015 (fx:run-effect fx:number-chain (lambda (c) (+ c 1000)) 5))
      "enter (+10), then the CL-supplied effect (+1000)"))

(test a-halt-skips-the-effect-entirely
  ;; THE property #172 is built on. A guard that rejects a request must not spend the
  ;; expensive thing -- an LLM call, a payment, a send. If this ever regresses, a budget
  ;; refusal would still bill the caller.
  (let ((spent 0))
    ;; 200 -> add10 -> 210 -> cap halts. So the result is the ENTER work (210), with the
    ;; effect skipped -- not the input, and emphatically not 1210.
    (is (= 210 (fx:run-effect fx:number-chain
                              (lambda (c) (incf spent) (+ c 1000))
                              200))
        "the halted run must be the pure enter result, not the effect's")
    (is (zerop spent) "the effect must not have been performed at all")))

(test the-effect-is-performed-exactly-once-on-a-proceeding-run
  (let ((calls 0))
    (fx:run-effect fx:number-chain (lambda (c) (incf calls) c) 5)
    (is (= 1 calls))))

;;; --- degenerate cases ------------------------------------------------------

(test an-empty-chain-proceeds-and-changes-nothing
  ;; A Coalton List is an ordinary CL list, so the empty chain is NIL.
  (is (string= "x" (fx:run-string nil "x")) "an empty chain is the identity")
  (is (string= "proceed" (fx:outcome nil "x"))))
