;;;; entropy-tests.lisp --- nothing in hyperion mints a secret from cl:random (#95).
;;;;
;;;; The fix for #95 was swapping two call sites. This is the part that keeps them swapped.
;;;;
;;;; A comment already said the generator was predictable and should be replaced -- it sat
;;;; three lines above the defect for months and stopped nobody, because a note is not a
;;;; mechanism. The rule here is absolute and therefore needs no allowlist to drift: NOTHING
;;;; under hyperion/src calls cl:random or makes a random state, for any purpose. If a
;;;; genuinely non-security use ever needs one, this test failing is the conversation.
;;;;
;;;; Source-scanning is crude, and it is the right crudeness: it catches the copy-paste that
;;;; a type or an API cannot, which is exactly how the defect spread from session.lisp into
;;;; logging.lisp as a character-for-character duplicate.

(in-package #:hyperion/tests)

(def-suite entropy
  :description "No security-relevant value in hyperion comes from cl:random (#95)." :in hyperion)
(in-suite entropy)

(defun %hyperion-source-files ()
  "Every .lisp under hyperion/src/, by path -- the shipped framework, not its tests."
  (let ((root (merge-pathnames "src/" (asdf:system-source-directory :hyperion))))
    (directory (merge-pathnames "**/*.lisp" root))))

(defun %offending-lines (path patterns)
  "Lines of PATH containing any of PATTERNS, as (line-number . text). Comment lines are
included deliberately: a commented-out `(random ...)' is a template waiting to be
uncommented, which is the failure mode this guards."
  (with-open-file (in path :external-format :utf-8)
    (loop for line = (read-line in nil nil)
          for n from 1
          while line
          when (some (lambda (p) (search p line)) patterns)
            collect (cons n line))))

(test hyperion-source-mints-no-secret-from-cl-random
  (let ((files (%hyperion-source-files))
        (found '()))
    (is-true (> (length files) 10)
             "the scan must actually find the sources -- got ~D files, which suggests the ~
path is wrong and this test is vacuous" (length files))
    (dolist (f files)
      (let ((hits (%offending-lines f '("(random " "make-random-state" "*random-state*"))))
        (when hits (push (cons (file-namestring f) hits) found))))
    (is-false found
              "cl:random must not appear in hyperion/src -- SBCL's is MT19937, whose state ~
is recoverable from observed output, and a session id is observable by design (#95). ~
Found: ~S" found)))

;;; --- and the ids themselves ------------------------------------------------

(test session-ids-are-the-width-they-claim
  ;; The docstring used to promise "*ID-BITS* of entropy" over a generator that did not
  ;; provide it. The number is now pinned to the value rather than asserted in prose.
  (let ((id (hyperion/session::new-id)))
    (is (= (/ hyperion/session:*id-bits* 4) (length id))
        "a ~D-bit id must be ~D hex chars, got ~S"
        hyperion/session:*id-bits* (/ hyperion/session:*id-bits* 4) id)
    (is-true (every (lambda (c) (find c "0123456789abcdef")) id))))

(test session-ids-do-not-repeat
  (let ((ids (loop repeat 1000 collect (hyperion/session::new-id))))
    (is (= 1000 (length (remove-duplicates ids :test #'string=))))))

(test request-ids-do-not-repeat
  (let ((ids (loop repeat 1000 collect (hyperion/logging::new-request-id))))
    (is (= 1000 (length (remove-duplicates ids :test #'string=))))))
