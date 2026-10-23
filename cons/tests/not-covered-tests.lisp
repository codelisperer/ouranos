;;;; not-covered-tests.lisp --- the gate's NOT COVERED section says what the run skipped (#182)
;;;;
;;;; scripts/not-covered.lisp prints the section of the gate's output that tells a reader of
;;;; a passing run what that run did not test. Before #181 it printed "nothing declined" on a
;;;; run where a suite had skipped all of its Postgres checks. These tests hand the printer
;;;; the three combinations #182 names and read what it prints.
;;;;
;;;; The script is loaded by path, as verify-tree.lisp loads it; it belongs to no ASDF system.

(in-package #:cons/tests)

(def-suite not-covered
  :description "The gate's NOT COVERED section lists declined axes and excused backend skips: Postgres (#182) and the credential store (#357)." :in all)
(in-suite not-covered)

(defun %load-not-covered ()
  "Load scripts/not-covered.lisp -- the file scripts/verify-tree.lisp loads by path."
  (let ((path (merge-pathnames "scripts/not-covered.lisp"
                               (asdf:system-source-directory :cons))))
    (unless (probe-file path)
      ;; cons/ is a framework directory inside the monorepo; the script lives at the ROOT.
      (setf path (merge-pathnames "../scripts/not-covered.lisp"
                                  (asdf:system-source-directory :cons))))
    (is-true (probe-file path)
             "scripts/not-covered.lisp must exist -- verify-tree.lisp loads it by path, so a rename breaks the gate, not just this test. Looked at ~A" path)
    (when (probe-file path) (load path))
    path))

(defun %not-covered (declined excused tag)
  "What PRINT-NOT-COVERED prints for these inputs, as a string.

Called by name at RUNTIME: the package does not exist until the file is loaded, so a literal
symbol would be resolved by the READER and take the whole test system down on a tree where
the file moved. Same reasoning as %FR and %FO."
  (with-output-to-string (s)
    (funcall (read-from-string "ouranos-not-covered:print-not-covered")
             declined excused tag s)))

(defparameter +memory-db-skip+
  '("PRAXEON/MEMORY-DB/TESTS" "postgres" "Postgres unreachable: MNEMOSYNE_TEST_PG_URL is not set"
    "OURANOS_ALLOW_NO_PG")
  "An excused skip in the shape verify-tree.lisp records it: (suite backend reason variable).")

(defun %declined-axis (name printed)
  "An optional-axis entry in +OPTIONAL-AXES+'s shape, (name predicate disclose), whose
DISCLOSE records each call in PRINTED (a one-element list) and prints a line naming the axis."
  (list name
        (constantly nil)
        (lambda (n)
          (push n (car printed))
          (format t "  off     ~a axis~34tDISCLOSED BY THE AXIS~%" n))))

(test nothing-declined-and-no-postgres-skip-says-nothing-declined
  (%load-not-covered)
  (let ((out (%not-covered '() '() "base+uv+view")))
    (is (search "========== NOT COVERED ==========" out))
    (is (search "nothing declined -- every optional axis ran (base+uv+view)" out))
    (is (not (search "postgres in" out)))
    (is (not (search "but some backends did not" out)))))

(test an-excused-postgres-skip-is-listed-and-nothing-declined-is-not-printed
  "The #181 defect: no axis declined, but a suite skipped its Postgres checks."
  (%load-not-covered)
  (let ((out (%not-covered '() (list +memory-db-skip+) "base+uv+view")))
    (is (not (search "nothing declined" out))
        "the section said \"nothing declined\" while a suite had skipped Postgres:~%~A" out)
    (is (search "every optional axis ran (base+uv+view), but some backends did not:" out))
    (is (search "postgres in PRAXEON/MEMORY-DB/TESTS" out))
    (is (search "MNEMOSYNE_TEST_PG_URL is not set" out))
    (is (search "OURANOS_ALLOW_NO_PG excused it. Its postgres checks did not run and are NOT in the total below." out))))

(test a-declined-axis-and-an-excused-postgres-skip-are-both-listed
  (%load-not-covered)
  (let* ((printed (list '()))
         (out (%not-covered (list (%declined-axis "uv" printed))
                            (list +memory-db-skip+)
                            "base+view")))
    (is (equal '("uv") (car printed))
        "the declined axis's own DISCLOSE must be called once, with its name")
    (is (search "uv axis" out))
    (is (search "DISCLOSED BY THE AXIS" out))
    (is (search "postgres in PRAXEON/MEMORY-DB/TESTS" out))
    (is (not (search "nothing declined" out)))
    (is (not (search "every optional axis ran" out)))))

(test excused-skips-are-listed-in-the-order-given
  "verify-tree.lisp pushes each excused suite as it runs and passes the list reversed, so the
printer keeps the order it is given: the order the suites ran. The second entry is another
backend, the credential store (#357), which is listed by its own name."
  (%load-not-covered)
  (let* ((out (%not-covered '()
                            (list +memory-db-skip+
                                  '("HADES/CREDENTIALS/TESTS" "credential-store"
                                    "SKIPPED (OURANOS_TEST_REAL_CREDENTIAL_STORE is not set)"
                                    "OURANOS_ALLOW_NO_CREDENTIAL_STORE"))
                            "base+uv+view"))
         (memory-db (search "postgres in PRAXEON/MEMORY-DB/TESTS" out))
         (credentials (search "credential-store in HADES/CREDENTIALS/TESTS" out)))
    (is-true memory-db)
    (is-true credentials)
    (is (and memory-db credentials (< memory-db credentials)))))

;;; --- a suite that must report a backend and printed no line (#603's review) ------------------

(defparameter +required-reports+
  '((:hades/credentials/tests "credential-store" :hosts (:windows :darwin))
    (:praxeon/results-db/tests "postgres"))
  "A required-reports table shaped like verify-tree.lisp's +REQUIRED-BACKEND-REPORTS+.")

(defun %missing (suite host coverage)
  "What MISSING-BACKEND-REPORTS returns, called by name for the reason %NOT-COVERED gives."
  (funcall (read-from-string "ouranos-not-covered:missing-backend-reports")
           suite host coverage +required-reports+))

(test a-required-backend-line-that-is-missing-is-a-problem
  "In the fixture table, hades/credentials/tests must report the credential store on Windows and
macOS. With no line for it, as when the reader guard around the live suite or the system's test-op changes, there is
one problem naming the backend and the host; the gate prints it as a COVER failure."
  (%load-not-covered)
  (dolist (host '(:windows :darwin))
    (let ((problems (%missing :hades/credentials/tests host '())))
      (is (= 1 (length problems)) "~(~a~): ~S" host problems)
      (is (search "credential-store" (first problems)) "~S" problems)
      (is (search (string-downcase (symbol-name host)) (first problems)) "~S" problems))))

(test a-required-backend-line-is-not-required-on-other-hosts
  "A row with :HOSTS does not apply on a host it does not name. The fixture names Windows and
macOS, so a missing line on Linux is not a problem here; verify-tree.lisp's own table names
Linux too since #357's Secret Service backend."
  (%load-not-covered)
  (is (null (%missing :hades/credentials/tests :linux '()))))

(test a-required-backend-line-that-is-there-is-not-a-problem
  "A line that is present, SKIPPED or a count, is judged by +BACKEND-RULES+, not here."
  (%load-not-covered)
  (is (null (%missing :hades/credentials/tests :windows
                      '(("credential-store" . "SKIPPED (not set)")))))
  (is (null (%missing :hades/credentials/tests :darwin '(("credential-store" . "14"))))))

(test a-postgres-suite-must-report-postgres-on-every-host
  (%load-not-covered)
  (dolist (host '(:windows :darwin :linux))
    (is (= 1 (length (%missing :praxeon/results-db/tests host '()))) "~(~a~)" host))
  (is (null (%missing :praxeon/results-db/tests :linux '(("postgres" . "0"))))
      "a line that is there, even with zero checks, is the per-backend rules' to judge")
  (is (null (%missing :praxeon/translate/tests :linux '())) "a suite not in the table needs no line"))

;;; --- checks counted under no backend --------------------------------------------------

(defun %unattributed (coverage)
  (funcall (read-from-string "ouranos-not-covered:unattributed-backend-reports") coverage))

(test a-backend-checks-nil-line-is-a-problem
  "mnemosyne/tests printed BACKEND-CHECKS NIL 2: two checks counted with no backend bound.
They are evidence for no backend, so the gate fails on the line."
  (%load-not-covered)
  (let ((problems (%unattributed '(("NIL" . "2") ("sqlite" . "71")))))
    (is (= 1 (length problems)) "~S" problems)
    (is (search "NIL 2" (first problems)) "~S" problems)))

(test named-backends-are-not-unattributed
  (%load-not-covered)
  (is (null (%unattributed '(("sqlite" . "71") ("postgres" . "SKIPPED (not set)")
                             ("credential-store" . "18"))))))
