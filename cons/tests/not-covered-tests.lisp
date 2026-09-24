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
  :description "The gate's NOT COVERED section lists declined axes and excused Postgres skips (#182)." :in all)
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
  '("PRAXEON/MEMORY-DB/TESTS" . "Postgres unreachable: MNEMOSYNE_TEST_PG_URL is not set")
  "An excused skip in the shape verify-tree.lisp records it: (suite . reason).")

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
    (is (not (search "but Postgres did not" out)))))

(test an-excused-postgres-skip-is-listed-and-nothing-declined-is-not-printed
  "The #181 defect: no axis declined, but a suite skipped its Postgres checks."
  (%load-not-covered)
  (let ((out (%not-covered '() (list +memory-db-skip+) "base+uv+view")))
    (is (not (search "nothing declined" out))
        "the section said \"nothing declined\" while a suite had skipped Postgres:~%~A" out)
    (is (search "every optional axis ran (base+uv+view), but Postgres did not:" out))
    (is (search "postgres in PRAXEON/MEMORY-DB/TESTS" out))
    (is (search "MNEMOSYNE_TEST_PG_URL is not set" out))
    (is (search "Its Postgres checks did not run and are NOT in the total below." out))))

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
printer keeps the order it is given: the order the suites ran."
  (%load-not-covered)
  (let* ((out (%not-covered '()
                            (list +memory-db-skip+
                                  '("MNEMOSYNE/TESTS" . "Postgres unreachable"))
                            "base+uv+view"))
         (memory-db (search "postgres in PRAXEON/MEMORY-DB/TESTS" out))
         (mnemosyne (search "postgres in MNEMOSYNE/TESTS" out)))
    (is-true memory-db)
    (is-true mnemosyne)
    (is (and memory-db mnemosyne (< memory-db mnemosyne)))))
