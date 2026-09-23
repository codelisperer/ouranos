;;;; param.lisp --- what a bound value MEANS, and how each backend must be told it (pre-publication issue 165).
;;;;
;;;; Common Lisp NIL is false, the empty list, and "no value", all at once. SQL needs those
;;;; to be different things. Every driver resolves that ambiguity for itself, and they do not
;;;; agree -- so the same query plist wrote different data depending on which engine was
;;;; underneath, which is exactly what a neutral data protocol exists to absorb.
;;;;
;;;; MEASURED, not assumed. What each value did BEFORE this module existed:
;;;;
;;;;   value     SQLite (measured here)        Postgres (cl-postgres/sql-string.lisp)
;;;;   NIL       SQL NULL                      the literal "false"      <- the bug
;;;;   T         ERROR                         "true"
;;;;   :null     ERROR                         "NULL"
;;;;   :true     ERROR                         ERROR
;;;;   :false    ERROR                         ERROR
;;;;
;;;; Two things in that table decided the design.
;;;;
;;;; SQLITE WAS ALREADY RIGHT. It stores NIL as SQL NULL and `WHERE x IS NULL` matches. So
;;;; this is not two backends wrong in different ways -- it is Postgres disagreeing with the
;;;; backend everyone develops on. Making NIL mean NULL therefore does not change what
;;;; existing app code means; it ends a disagreement.
;;;;
;;;; NO SENTINEL SURVIVES THE DRIVER. A keyword errors on both -- SQLite refuses a
;;;; non-scalar bind value, Postgres refuses an unknown literal. So :TRUE and :FALSE are
;;;; MNEMOSYNE'S vocabulary, translated here, and never the driver's. That is why this is a
;;;; boundary in both directions rather than a patch to the Postgres path.
;;;;
;;;; THE VOCABULARY, and it is deliberately three values rather than two:
;;;;
;;;;   NIL / :NULL   SQL NULL -- no value
;;;;   :TRUE / T     boolean true
;;;;   :FALSE        boolean false
;;;;
;;;; :TRUE is not invented here. `mnemosyne/changeset::%to-bool` has always mapped
;;;; `(member raw '(t :true))` to 1, so the cast layer already spelled it that way; this
;;;; extends that convention rather than adding a second one for the same fact.
;;;;
;;;; WHAT IS DELIBERATELY *NOT* TRANSLATED. Postgres coerces a bound `0` into a boolean
;;;; column to false rather than erroring, and SQLite stores 0 as its own false. It is
;;;; tempting to fold 0/1 into the boolean vocabulary for tidiness. This does not, and the
;;;; reason is a hard limit rather than a preference: THIS LAYER CANNOT SEE THE COLUMN TYPE.
;;;; A bound 0 is indistinguishable from a genuine integer zero going into an integer
;;;; column, and silently rewriting one of those would be a new instance of exactly the bug
;;;; this module exists to remove -- a value quietly becoming something the caller did not
;;;; write. Integers pass through untouched; :TRUE and :FALSE are the spellings mnemosyne
;;;; guarantees, and 0/1 remain whatever the engine makes of them.
;;;;
;;;; THE ONE BREAKING CHANGE, stated plainly because it is silent: on Postgres a BOOLEAN
;;;; column written with NIL used to store false, and now stores NULL. Such call sites must
;;;; say :FALSE. Nothing detects this for you -- see docs/migrations.md.

(in-package #:mnemosyne/param)

(defun null-value-p (value)
  "True when VALUE means SQL NULL: NIL, or the explicit :NULL.

Both spellings exist on purpose. NIL is what a Lisp programmer writes without thinking and
is what SQLite already meant; :NULL is for call sites that would rather be unmistakable,
and for code that wants to read the same as the SQL it produces."
  (or (null value) (eq value :null)))

(defun true-value-p (value)
  "True when VALUE means boolean TRUE. T is accepted alongside :TRUE because the changeset
layer has always taken both."
  (or (eq value t) (eq value :true)))

(defun false-value-p (value)
  "True when VALUE means boolean FALSE. Note that NIL is NOT false here -- it is NULL. That
is the whole point of the split, and the one thing about this module worth remembering."
  (eq value :false))

(defun to-driver (value driver)
  "VALUE as DRIVER must be told it. DRIVER is a CL-DBI driver type (:POSTGRES, :SQLITE3).

Postgres takes :NULL for SQL NULL and renders T/NIL as true/false, so the booleans map onto
what cl-postgres already does correctly -- NIL meaning false was never the wrong mapping, it
was the wrong OVERLOADING, and once NULL has its own spelling NIL is free to keep meaning
false where a boolean is genuinely wanted.

SQLite stores booleans as integers and already treats NIL as NULL, so the booleans become
1/0 and NULL is left alone. Mapping T to 1 fixes a second, unreported bug on the way past:
T errored on SQLite before this and works on Postgres, so a portable query could not write
boolean true at all.

An unrecognised driver is treated like SQLite -- scalars only -- which is the conservative
choice: it cannot invent a literal the driver will reject."
  (if (eq driver :postgres)
      (cond ((null-value-p value)  :null)
            ((true-value-p value)  t)
            ((false-value-p value) nil)   ; cl-postgres renders NIL as "false" -- correct here
            (t value))
      (cond ((null-value-p value)  nil)   ; SQLite already stores NIL as SQL NULL
            ((true-value-p value)  1)
            ((false-value-p value) 0)
            (t value))))

(defun to-driver-params (params driver)
  "NORMALIZE every element of PARAMS. Returns a fresh list; PARAMS is not modified."
  (mapcar (lambda (v) (to-driver v driver)) params))

;;; --- the read direction ----------------------------------------------------
;;;
;;; Fixing writes alone left the mirror-image defect, and it was the more dangerous half. A
;;; NULL column read back as the keyword :NULL on Postgres and NIL on SQLite -- so an app
;;; that could finally WRITE a portable NULL still could not READ one. `:NULL` is truthy and
;;; `NIL` is not, so every `(when (getf row :field) ...)` inverted, and a consuming app hit
;;; exactly that:
;;;
;;;     (defun current-lineage-p (row) (null (row-value row :valid_until)))
;;;
;;; That line is written with ROW-VALUE and an underscore; the original said `(getf row
;;; :valid-until)' and BOTH halves of that would fail today (pre-publication issue 489). GETF misses because the
;;; driver interns keys lowercase, and `:valid-until' would miss again on the hyphen, which
;;; is not folded and cannot be -- a hyphenated column cannot be declared through mnemosyne
;;; at all. Corrected here rather than left, because a reader copying the idiom from a block
;;; ABOUT careful reading gets NIL from a column that has a value, and then the opposite of
;;; the behaviour this block is teaching: a key miss gives NIL, so `(null NIL)' is true and
;;; every row looks current, where the defect described below makes every row look stale.
;;;
;;; The original example is a documentation inaccuracy rather than a second code defect --
;;; the real code almost certainly read the underscored name and the prose rendered it in
;;; idiomatic Lisp.
;;;
;;; returned false for every current row, so "you already have one, update it" found nothing
;;; and inserted a duplicate. That is `WHERE ... IS NULL` silently ceasing to match -- the
;;; original bug, relocated one layer up into Lisp. It surfaced loudly only because a partial
;;; unique index happened to stand behind that predicate; most such predicates have nothing
;;; behind them, so the realistic failure mode is silence.
;;;
;;; WHY THE READ PATH MAY NORMALISE WHERE THE WRITE PATH MAY NOT. On write this layer sees a
;;; bare value and cannot know the column type, which is why a bound 0 is left alone. On READ
;;; the driver has already decoded each value BY ITS COLUMN OID, so a T or NIL arriving from
;;; Postgres is known to be a boolean. The asymmetry is real and it is the driver's doing,
;;; not an inconsistency here.
;;;
;;; THE TARGET IS SQLITE'S EXISTING SHAPE -- NULL as NIL, booleans as 1/0 -- because it is the
;;; only shape reachable on BOTH backends. SQLite has no boolean type and `cl-dbi`'s sqlite3
;;; driver exposes column NAMES only (`statement-column-names`), so a boolean column's 1
;;; cannot be told from an integer column's 1 there and cannot be rewritten to T without
;;; guessing. Postgres booleans CAN be moved to 1/0, so 1/0 is uniform and T/:FALSE would
;;; have been Postgres-only -- reintroducing cross-backend disagreement, which is the defect
;;; class this whole module exists to remove.
;;;
;;; The cost, stated because it is a genuine trap: 0 IS TRUTHY IN CL, so `(when (getf row
;;; :flag) ...)` runs for a false flag. That cost is unavoidable on SQLite regardless of what
;;; is chosen here, so it is not something this choice trades away -- but it is worth knowing
;;; before writing a predicate over a boolean column.
;;;
;;; NIL -> 0 IS SAFE ONLY BECAUSE NIL CANNOT MEAN ANYTHING ELSE HERE. In cl-postgres the only
;;; interpreter yielding NIL is the boolean one (`interpret.lisp`, oid:+bool+ -> `(if (zerop
;;; value) nil t)`); SQL NULL is :NULL, and an empty array is `(make-array 0)` rather than NIL
;;; -- a choice their source comments on explicitly. If that ever changes, this mapping is
;;; where it breaks, and the test named after it is what should catch it.

(defun from-driver (value driver)
  "VALUE as read from DRIVER, in mnemosyne's own vocabulary: SQL NULL is NIL, booleans are
1/0, on every backend.

SQLite already produces exactly this, so its values pass through untouched -- which is also
why no existing SQLite reader changes."
  (if (eq driver :postgres)
      (cond ((eq value :null) nil)   ; SQL NULL -- the keyword is cl-postgres', not ours
            ((eq value t) 1)         ; boolean true
            ((null value) 0)         ; boolean false; see the header on why this is safe
            (t value))
      value))

(defun from-driver-row (row driver)
  "A result ROW (a plist of column-keyword -> value) with its values in mnemosyne's
vocabulary. Keys are untouched; only values are translated."
  (if (eq driver :postgres)
      (loop for (k v) on row by #'cddr
            collect k collect (from-driver v driver))
      row))

;;; --- reading a column out of a row -----------------------------------------
;;;
;;; `FROM-DRIVER-ROW' says it plainly: "Keys are untouched; only values are translated."
;;; That is the right division of labour and it leaves a hazard nobody owned (pre-publication issue 489).
;;;
;;; THE DRIVER INTERNS COLUMN KEYS LOWERCASE. A row arrives as `(:|content| "...")', so
;;; `(getf row :content)' looks up `:|CONTENT|', misses, and returns the default. Nothing
;;; errors. An absent column, a NULL column and a legitimately empty string are then the
;;; same answer, which is why the defect this function exists to remove passed every count
;;; assertion in praxeon/memory-db and was caught only by asserting on round-tripped
;;; CONTENT.
;;;
;;; A MISS SIGNALS, and that is the part that generalises. Case is one spelling hazard;
;;; there will be others. A reader that refuses to answer about a column it cannot find is
;;; loud for all of them, including the ones nobody has thought of.
;;;
;;; KEYS ARE SQL SPELLINGS. Case is folded; nothing else is. A hyphen is NOT folded to an
;;; underscore, because MNEMOSYNE/DDL's `%ident' does not quote identifiers -- a keyword
;;; becomes a bare word -- so `:valid-until' would be emitted as `valid-until', which
;;; Postgres reads as a subtraction. A hyphenated column cannot be DECLARED through
;;; mnemosyne, so folding hyphens here would give callers a read vocabulary with no write
;;; counterpart: two vocabularies for one thing, which is the defect ADR-0003 has just
;;; finished removing from the dialect.
;;;
;;; POSITIONAL READERS ARE NOT OBSOLETED BY THIS, and two in this tree must not be converted
;;; to it -- see MNEMOSYNE/MIGRATE:%COL1 and MNEMOSYNE/INTROSPECT:%ROW-VALUES, each of which
;;; says at its definition why it stays positional. Where a caller does not need a column BY
;;; NAME, not naming it is stronger than naming it carefully.

(define-condition unknown-column (error)
  ((key :initarg :key :reader unknown-column-key)
   (available :initarg :available :initform nil :reader unknown-column-available))
  (:report
   (lambda (c s)
     (format s "mnemosyne: no column ~S in this row.~%~%" (unknown-column-key c))
     (format s "Columns present: ~{~S~^, ~}~%" (or (unknown-column-available c) '(none)))
     (format s "Keys are SQL spellings and only CASE is folded. A Lisp hyphen is not an underscore: `:valid-until' does not find `valid_until', and it never could, because mnemosyne emits identifiers unquoted so a hyphenated column cannot be declared either (pre-publication issue 489).~%")
     (format s "This signals rather than returning NIL because an absent column, a NULL column and an empty string are otherwise the same answer.")))
  (:documentation "Signalled when a row has no column under the requested key."))

(defun row-keys (row)
  "The column keys present in ROW, in order."
  (loop for (k) on row by #'cddr collect k))

(defun row-value (row key &key (if-missing :signal))
  "The value of column KEY in ROW. Signals UNKNOWN-COLUMN when there is no such column.

KEY is matched case-insensitively and exactly otherwise -- see the note above. IF-MISSING
other than :SIGNAL is returned instead of signalling, for the caller who genuinely expects a
column to be absent; state the reason where you pass it, because the default is what makes
every other spelling hazard loud."
  (let ((wanted (symbol-name key)))
    (loop for (k v) on row by #'cddr
          when (and (symbolp k) (string-equal (symbol-name k) wanted))
            do (return-from row-value v)))
  (if (eq if-missing :signal)
      (error 'unknown-column :key key :available (row-keys row))
      if-missing))

(defun from-driver-rows (rows driver)
  "FROM-DRIVER-ROW over a result set. Returns ROWS unchanged for a driver that needs no
translation, so the common SQLite path allocates nothing."
  (if (eq driver :postgres)
      (mapcar (lambda (row) (from-driver-row row driver)) rows)
      rows))
