;;;; tests/secret-types.lisp --- SECRET as a Coalton field type (#209).
;;;;
;;;; This is the test that actually covers the reported defect. MNEMOSYNE/BACKEND:PG-CONFIG
;;;; is a Coalton DEFINE-TYPE, and Coalton generates a printer that renders every field --
;;;; so a String password field is printed in full inside any backtrace holding the config.
;;;;
;;;; It is ALSO the test for the thing that makes `repr :native' the right mechanism rather
;;;; than a PRINT-OBJECT on PG-CONFIG itself: Coalton promises nothing about a DEFINE-TYPE's
;;;; representation across compilation modes (coalton-patterns.md §7). PG-CONFIG is a
;;;; STANDARD-CLASS in development and a STRUCTURE-CLASS in release, and a multi-constructor
;;;; type is not even named the same way in the two modes. A specializer on it would compile
;;;; in development and be wrong in release -- invisibly, which is §7's whole warning. What
;;;; is asserted below holds in either mode because the redacting printer belongs to OUR
;;;; struct, not to Coalton's rendering of the type that holds it.

(cl:defpackage #:aion/secret/types/tests/fixtures
  (:use #:coalton #:coalton-prelude)
  (:local-nicknames (#:st #:aion/secret/types))
  (:export #:Probe-Config #:make-probe #:probe-password #:probe-password-plaintext))
(cl:in-package #:aion/secret/types/tests/fixtures)

(coalton-toplevel
  (define-type Probe-Config
    "Deliberately the same shape as the config that leaked: plain fields alongside a
credential, so the assertions can check that the neighbours still print and only the
credential does not."
    (Probe-Config String UFix st:Secret))

  (declare probe-password (Probe-Config -> st:Secret))
  (define (probe-password c) (match c ((Probe-Config _ _ p) p)))

  (declare make-probe (String * UFix * String -> Probe-Config))
  (define (make-probe host port password)
    (Probe-Config host port (st:make-secret password)))

  (declare probe-password-plaintext (Probe-Config -> String))
  (define (probe-password-plaintext c)
    "A monomorphic wrapper so the CL side can run the control assertion."
    (st:reveal (probe-password c))))

(cl:defpackage #:aion/secret/types/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:p #:aion/secret/types/tests/fixtures))
  (:export #:run-tests))
(cl:in-package #:aion/secret/types/tests)

(def-suite secret-types :description "A Coalton DEFINE-TYPE holding a credential.")
(defun run-tests () (run! 'secret-types))
(in-suite secret-types)

(defparameter +plaintext+ "pa$$w0rd-do-not-log-me")

(defun %probe ()
  "MAKE-PROBE is monomorphic, so it is an ordinary CL function -- no COALTON form, which
also means the plaintext can come from a CL variable rather than being inlined here."
  (p:make-probe "db.example.com" 25060 +plaintext+))

(test control-the-value-is-really-in-there
  "Without this, every assertion below could be passing because the field is empty."
  (is (string= +plaintext+ (p:probe-password-plaintext (%probe)))))

(test coalton-type-printing-redacts-the-credential
  (let ((printed (format nil "~S" (%probe))))
    (is (null (search +plaintext+ printed))
        "a Coalton DEFINE-TYPE printed its credential field: ~S" printed)
    ;; The neighbouring fields MUST still appear. That is the point of redacting the
    ;; credential rather than the config: a backtrace naming which host and port failed is
    ;; exactly what the operator reading the deploy log needs.
    (is (search "db.example.com" printed))
    (is (search "25060" printed))))

(test princ-of-the-coalton-type-redacts-too
  (let ((printed (format nil "~A" (%probe))))
    (is (null (search +plaintext+ printed)))
    (is (search "db.example.com" printed))))
