;;;; tests/smoke.lisp --- an APPLICATION-shaped round trip, on every backend (pre-publication issue 176).
;;;;
;;;; Why this file exists, in one sentence: a per-value matrix cannot see a bug in the
;;;; MEANING of a value.
;;;;
;;;; The evidence is on pre-publication issue 176 itself. A 21-case truth table was run against real Postgres 17
;;;; and confirmed the write mapping perfectly -- and it could never have surfaced the defect
;;;; found minutes later, because that defect was not in the value:
;;;;
;;;;   (defun current-lineage-p (row)
;;;;     (null (getf row :valid-until)))    ; NULL means "still current"
;;;;
;;;; The column round-tripped exactly as designed. `:NULL` came back where a SQL NULL was
;;;; stored, which is correct behaviour by the mapping under test. But `(null :NULL)` is
;;;; false, so the predicate returned false for EVERY current row. A green matrix would have
;;;; signed off a build that inverted every is-it-set test in a consuming app -- and it would
;;;; have been green for a completely legitimate reason.
;;;;
;;;; So the shape here is deliberately NOT a matrix. It is a short sequence of the operations
;;;; an application actually performs, in the order it performs them, with the assertions
;;;; written the way application code asks the question -- `(null (getf row :field))` rather
;;;; than `(eq :null ...)`. The predicate step is the one that matters and is exactly the one
;;;; a value matrix omits.
;;;;
;;;; ROUND-TRIP ASSERTIONS, NOT WRITE ASSERTIONS. "The value stored correctly" and "the value
;;;; means the same thing when it is read back" are different claims. Only the second is what
;;;; an application depends on, and only the second is asserted below.

(cl:in-package #:mnemosyne/tests)

(in-suite mnemosyne)

(defun %smoke-table (conn)
  "A tiny bitemporal-ish table: the shape whose NULL means \"still current\".

DROP first -- see %FRESH-TABLE in tests/param.lisp for why a real server needs it and
`:memory:` does not."
  (mnemosyne/conn:exec conn "DROP TABLE IF EXISTS smoke_doc")
  (mnemosyne/conn:exec conn
    "CREATE TABLE smoke_doc (id integer primary key, title text, valid_until text, archived boolean)"))

(defun current-lineage-p (row)
  "The predicate from the pre-publication issue 176 comment, verbatim in spirit: NULL means still current.

Written the way application code writes it -- CL NULL-ness of the plist value -- because
that is the exact expression that inverted. A test that asked `(eq :null ...)` instead would
pass against the broken mapping, which is the whole lesson."
  (null (getf row :|valid_until|)))

(defun %row (conn id)
  ;; One line, no `~<newline>` continuation: on a CRLF checkout that becomes an illegal
  ;; `~<Return>` directive and fails at compile time (CLAUDE.md).
  (first (mnemosyne/conn:query
          conn
          (format nil "SELECT id, title, valid_until, archived FROM smoke_doc WHERE id = ~D" id))))

(test application-smoke-null-means-absent-end-to-end
  "Twelve operations in the order an application performs them, on every active backend."
  (with-each-backend (c)
    (%smoke-table c)

    ;; 1-2. insert one current row (valid_until NULL) and one superseded row.
    (mnemosyne/query:run c (list :insert-into "smoke_doc"
                                 :values (list (list :id 1 :title "current"
                                                     :valid_until nil :archived :false)
                                               (list :id 2 :title "superseded"
                                                     :valid_until "2026-01-01"
                                                     :archived :false)))
                         :dialect *current-dialect*)

    ;; 3. read the current row back.
    (let ((row (%row c 1)))
      (is* (string= "current" (getf row :|title|))
           "an ordinary text column must survive the round trip untouched")

      ;; 4. THE STEP A VALUE MATRIX OMITS -- branch on the value the way an app does.
      (is* (current-lineage-p row)
           "a NULL valid_until must read as CURRENT -- the predicate that silently inverted")

      ;; 5. and its negation must still work, or a predicate that always says T would pass.
      (is* (not (current-lineage-p (%row c 2)))
           "a row with a real valid_until must NOT read as current -- the control"))

    ;; 6. boolean false must not collapse into absence one layer up in Lisp.
    (is* (eql 0 (getf (%row c 1) :|archived|))
         "boolean false must read back as a value, not as NULL")

    ;; 7. SQL-side agreement: IS NULL must select exactly the current row.
    (let ((ids (mnemosyne/conn:query c "SELECT id FROM smoke_doc WHERE valid_until IS NULL")))
      (is* (= 1 (length ids))
           "WHERE ... IS NULL must match exactly the current row")
      (is* (eql 1 (getf (first ids) :|id|))))

    ;; 8. and the two directions must AGREE. This is the assertion that catches a mapping
    ;;    which is self-consistently wrong: SQL and Lisp can each be internally coherent
    ;;    while disagreeing about which rows are current.
    (let ((sql-current (length (mnemosyne/conn:query
                                c "SELECT id FROM smoke_doc WHERE valid_until IS NULL")))
          (lisp-current (length (remove-if-not
                                 #'current-lineage-p
                                 (mnemosyne/conn:query
                                  c "SELECT id, title, valid_until, archived FROM smoke_doc")))))
      (is* (= sql-current lisp-current)
           "SQL and Lisp must agree on how many rows are current (~D vs ~D)"
           sql-current lisp-current))

    ;; 9-10. supersede the current row, then re-read.
    (mnemosyne/conn:exec c "UPDATE smoke_doc SET valid_until = '2026-06-01' WHERE id = 1")
    (is* (not (current-lineage-p (%row c 1)))
         "after an UPDATE sets valid_until, the row must stop reading as current")

    ;; 11. write a NULL back over a set value -- the direction an app takes to re-open a row.
    (mnemosyne/query:run c (list :update "smoke_doc"
                                 :set (list :valid_until nil)
                                 :where (list := :id 1))
                         :dialect *current-dialect*)
    (is* (current-lineage-p (%row c 1))
         "writing NULL over a set value must restore absence, not store a literal")

    ;; 12. and SQL must agree about that too.
    (is* (= 1 (length (mnemosyne/conn:query
                       c "SELECT id FROM smoke_doc WHERE valid_until IS NULL")))
         "the re-opened row must be visible to IS NULL again")))
