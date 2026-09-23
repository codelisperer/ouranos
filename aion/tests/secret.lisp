;;;; tests/secret.lisp --- the opaque credential wrapper (#209).
;;;;
;;;; Every test here asserts BOTH directions, because a redaction test is unusually easy
;;;; to pass for the wrong reason: a wrapper that lost the value entirely, or one built
;;;; over an empty string, satisfies "the plaintext does not appear in the output"
;;;; perfectly. So each case that asserts absence is paired with a REVEAL asserting the
;;;; value is still there to have been leaked. Absence alone would be the same class of
;;;; non-evidence AGENTS.md keeps cataloguing.

(cl:defpackage #:aion/secret/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:s #:aion/secret))
  (:export #:run-tests))
(cl:in-package #:aion/secret/tests)

(def-suite secret :description "An opaque credential: printing redacts, REVEAL discloses.")
(defun run-tests () (run! 'secret))
(in-suite secret)

(defparameter +plaintext+ "pa$$w0rd-do-not-log-me"
  "A distinctive value: a substring search for it must find nothing in any printed form.")

(test reveal-returns-the-value
  "The control for every absence assertion below: the secret really does hold the
plaintext, so a printer that leaked it WOULD have something to leak."
  (is (string= +plaintext+ (s:reveal (s:make-secret +plaintext+)))))

(test prin1-redacts
  (let ((printed (format nil "~S" (s:make-secret +plaintext+))))
    (is (null (search +plaintext+ printed))
        "~~S printed the plaintext: ~S" printed)
    (is (search "REDACTED" printed))))

(test princ-redacts
  "~A too: PRINC binds *PRINT-ESCAPE* to NIL, and a printer that only handled the escaped
case would leak through every FORMAT ~~A and every string-building log line."
  (let ((printed (format nil "~A" (s:make-secret +plaintext+))))
    (is (null (search +plaintext+ printed))
        "~~A printed the plaintext: ~S" printed)
    (is (search "REDACTED" printed))))

(test nested-in-a-struct-redacts
  "The actual defect shape: SBCL prints a structure by printing its slots, so a credential
in a slot is rendered by anything that prints the ENCLOSING value -- a backtrace frame,
most damagingly. Holding a SECRET instead redacts without the outer struct knowing."
  (let ((printed (format nil "~S" (list :host "db.example.com" :port 25060
                                        :password (s:make-secret +plaintext+)))))
    (is (null (search +plaintext+ printed)))
    ;; The non-secret neighbours must still print: a redaction that ate the whole
    ;; structure would pass the assertion above and destroy the diagnostic.
    (is (search "db.example.com" printed))
    (is (search "25060" printed))))

(test the-printed-form-is-unreadable
  "PRINT-UNREADABLE-OBJECT, so a printed config cannot be pasted back into a REPL and
re-read -- the second reason the issue gave for this shape, independent of the value."
  (signals error
    (let ((*read-eval* nil))
      (read-from-string (format nil "~S" (s:make-secret +plaintext+))))))

(test secretp-discriminates
  (is-true (s:secretp (s:make-secret +plaintext+)))
  (is-false (s:secretp +plaintext+))
  (is-false (s:secretp nil)))

(test empty-secret-still-redacts
  "A boundary the audit cares about: an unset credential must not print as a bare empty
string that reads like `no password configured' when it is simply blank."
  (let ((printed (format nil "~S" (s:make-secret ""))))
    (is (search "REDACTED" printed))
    (is (string= "" (s:reveal (s:make-secret ""))))))
