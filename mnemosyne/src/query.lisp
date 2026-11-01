;;;; query.lisp --- HoneySQL-style data-driven SQL generation (CL shell).
;;;;
;;;; A query is Lisp *data* -- a plist of clauses whose predicate values are s-exprs --
;;;; compiled to a parameterized SQL string + an ordered param list (values never
;;;; interpolated; always bound as "?"). Data-oriented, so queries compose, are
;;;; inspectable, and stay injection-safe. Feeds mnemosyne/conn:exec / :query.
;;;;
;;;;   (sql '(:select (:id :email) :from (:users)
;;;;          :where (:and (:= :email "a@x") (:> :id 10)) :order-by ((:id :desc)) :limit 20))
;;;;   => "SELECT id, email FROM users WHERE (email = ? AND id > ?) ORDER BY id DESC LIMIT ?"
;;;;      ("a@x" 10 20)
;;;;
;;;; Convention (as in HoneySQL): a **keyword/symbol is an identifier** (column/table);
;;;; anything else is a **value** (bound as a param). Pass a keyword-valued literal as a
;;;; string. `(:raw "sql")` is the escape hatch.
;;;;
;;;; A string is also accepted as an identifier where only a name can stand: in FROM, a JOIN
;;;; source, an alias, INSERT INTO, UPDATE, DELETE FROM, RETURNING, GROUP BY and ORDER BY.
;;;; Identifiers are written into the SQL, not bound, so every one is checked (#860): letters,
;;;; digits and underscores, dot-separated, with * as the last part. An ORDER BY direction
;;;; must be :asc or :desc. Anything else signals INVALID-IDENTIFIER before any SQL exists.
;;;;
;;;; Beyond the flat case the same data grows to cover the SQL a real app writes:
;;;;
;;;;   JOINs        :join ((:inner (:as :orders :o) (:= :u.id :o.user_id)) ...)  ; ordered,
;;;;                kinds :inner|:left|:right|:full|:cross; source may be aliased or a subquery.
;;;;   Aggregates   (:count :*) (:sum :o.total) (:avg :x) ... and DISTINCT: (:count (:distinct :x)).
;;;;   Aliases      select items (:as EXPR :alias) render "EXPR AS alias".
;;;;   Subqueries   a nested (:select ...) is legal wherever an expression is -- in FROM
;;;;                ((:as (:select ...) :t)), in (:in col (:select ...)), or (:exists (:select ...)).
;;;;   RETURNING    :returning (:id :email) on insert/update/delete (PG/XTDB; SQLite >=3.35).
;;;;   Upsert       :on-conflict (:email) with :do-nothing t, or :do-update (:name (:excluded :name)).
;;;;   LIKE         (:like col pattern :escape "\\") renders col LIKE ? ESCAPE ?, both bound, and the
;;;;                same for :ilike. LIKE-CONTAINS builds a pattern from user text with its %, _
;;;;                and escape character taken literally (#862).
;;;;
;;;; DIALECTS. :sqlite / :postgres emit "?" (CL-DBI binds them; verified on both). :xtdb
;;;; is the seam for XTDB 2 -- which is PG-wire but a DISTINCT dialect: **no DDL**
;;;; (schemaless -- no CREATE TABLE), **$N-style / different param handling**, and
;;;; **transaction gotchas** (see docs/xtdb-notes.md). Its temporal SELECT extensions
;;;; (FOR VALID_TIME AS OF ...) layer on later; the :xtdb placeholder path here is a
;;;; provisional seam, not yet verified end-to-end.
;;;;
;;;; :jet is Microsoft Access SQL (Jet/ACE), for queries only (#1061): mnemosyne renders it and
;;;; has no backend that runs it. It differs from the others in seven places, each tested:
;;;;   * :limit renders as a prefix, SELECT TOP n, with n written into the SQL as a number,
;;;;     because Jet does not accept a parameter there. Jet's TOP also returns rows tied with
;;;;     the last one on the ORDER BY columns, so a query can return more than n rows.
;;;;   * Jet has no OFFSET, so :offset signals UNSUPPORTED-QUERY rather than being dropped.
;;;;   * Names render in brackets, [u].[email]; (:quoted "First Name") renders [First Name].
;;;;   * (:date y m d) and (:timestamp y m d h mi s) render as #yyyy-mm-dd# and
;;;;     #yyyy-mm-dd hh:nn:ss#, written into the SQL. Every other dialect binds them as strings.
;;;;   * Values bind as ? and the param list is in placeholder order, which is the order ADO
;;;;     binds them in, since it binds by position.
;;;;   * An aggregate in the SELECT list without an alias gets one, COUNT(*) AS [count], so
;;;;     the column can be read by name: Jet names it Expr1000 otherwise.
;;;;   * More than one join nests in parentheses, FROM ([a] INNER JOIN [b] ON ...) INNER JOIN
;;;;     [c] ON ..., and :full and :cross joins signal UNSUPPORTED-QUERY: Jet has neither.

(in-package #:mnemosyne/query)

(defvar *dialect* :sqlite
  "The SQL dialect SQL compiles for: :sqlite | :postgres (both use \"?\") | :xtdb | :jet
(Microsoft Access, queries only; see the header of this file).

A DESIGNATOR, not a vocabulary of its own (pre-publication issue 432, ADR-0003): a keyword, a string or a typed
MNEMOSYNE/FIELD:DIALECT all name the same thing, and SQL normalises whichever it is through
MNEMOSYNE/FIELD-SHELL:DIALECT-FOR before anything branches on it.")

(defstruct (ctx (:constructor make-ctx (dialect &optional inline)))
  ;; DIALECT is a TYPED MNEMOSYNE/FIELD:DIALECT, never a designator: it is normalised once
  ;; in SQL, so every branch below compares a checked value. A nullary Coalton constructor
  ;; is a singleton, so EQ against FLD:D-POSTGRES is exact -- the same comparison the old
  ;; code made against :POSTGRES, but against a value that cannot be a spelling nobody
  ;; recognised.
  dialect (params nil) (n 0) inline)

(defun %postgres-p (ctx) (eq (ctx-dialect ctx) fld:D-Postgres))
(defun %xtdb-p (ctx) (eq (ctx-dialect ctx) fld:D-Xtdb))
(defun %jet-p (ctx) (eq (ctx-dialect ctx) fld:D-Jet))

(defvar *bracket-identifiers* nil
  "True while SQL compiles for the Jet dialect, where %IDENT and %QUOTED write names in
brackets. Bound by SQL; a special rather than a CTX slot because %IDENT is called from places
that have no CTX.")

(define-condition unsupported-query (error)
  ((dialect :initarg :dialect :reader unsupported-query-dialect)
   (clause :initarg :clause :reader unsupported-query-clause)
   (detail :initarg :detail :initform nil :reader unsupported-query-detail))
  (:report (lambda (c s)
             (format s "mnemosyne/query: the ~A dialect has no ~A~@[ -- ~A~]"
                     (unsupported-query-dialect c) (unsupported-query-clause c)
                     (unsupported-query-detail c))))
  (:documentation "A query clause the target dialect cannot express, signalled when the query
is compiled rather than dropped from the SQL (#1061). Jet's missing OFFSET is the first."))
(defun %dialect-name (ctx) (fld:dialect-name (ctx-dialect ctx)))

(defun %sql-escape (s)
  "Escape a string literal for inline SQL by doubling single quotes."
  (with-output-to-string (o)
    (loop for c across s do (when (char= c #\') (write-char #\' o)) (write-char c o))))

(defun %literal (v)
  "Render V as an inline SQL literal (for :inline mode -- display/round-trip only, NOT for
execution: inlining values reopens the injection surface)."
  (cond ((null v) "NULL")
        ((numberp v) (princ-to-string v))
        ((stringp v) (format nil "'~A'" (%sql-escape v)))
        (t (format nil "'~A'" (%sql-escape (princ-to-string v))))))

(defun %placeholder (ctx value)
  "Bind VALUE as a param and return its placeholder -- or, in :inline mode, render it
inline (for round-trip / display; never execute inlined SQL with untrusted values)."
  (if (ctx-inline ctx)
      (%literal value)
      (progn
        (push value (ctx-params ctx))
        (incf (ctx-n ctx))
        (if (%xtdb-p ctx)
            (format nil "$~D" (ctx-n ctx))  ; provisional -- XTDB param handling is a seam
            "?"))))

(define-condition invalid-identifier (error)
  ((text :initarg :text :reader invalid-identifier-text)
   (expected :initarg :expected :reader invalid-identifier-expected)
   (clause :initarg :clause :initform nil :reader invalid-identifier-clause))
  (:report (lambda (c s)
             (format s "mnemosyne/query: ~S~@[ in ~(~A~)~] is not ~A. Identifiers are written into the SQL, not bound, so only safe names are accepted; write SQL text with (:raw \"...\") where it is meant, or a name that needs quoting with (:quoted \"...\")."
                     (invalid-identifier-text c) (invalid-identifier-clause c)
                     (invalid-identifier-expected c))))
  (:documentation "A table, column, alias or function name, or an ORDER BY direction, that
mnemosyne will not write into SQL (#860). Raised when the query is compiled, before any SQL
reaches a connection."))

(defun %identifier-part-p (part)
  "True when PART is an ASCII letter or underscore followed by ASCII letters, digits and
underscores."
  (and (plusp (length part))
       (let ((c (char part 0))) (or (char<= #\a (char-downcase c) #\z) (char= c #\_)))
       (every (lambda (c) (or (char<= #\a (char-downcase c) #\z) (char<= #\0 c #\9) (char= c #\_)))
              part)))

(defun %name-parts (name)
  "NAME split at each dot: \"u.email\" is (\"u\" \"email\")."
  (loop with start = 0
        for dot = (position #\. name :start start)
        collect (subseq name start dot)
        while dot do (setf start (1+ dot))))

(defun %safe-identifier-p (name)
  "True when NAME is one or more identifier parts separated by dots (u.email, public.users),
or ends in .* (u.*), or is * alone."
  (let ((parts (%name-parts name)))
    (loop for (part . more) on parts
          always (if more
                     (%identifier-part-p part)
                     (or (%identifier-part-p part) (string= part "*"))))))

(defun %jet-name-part-p (part)
  "True when PART can stand inside Jet's brackets: a non-empty string with no control
character, none of . ! ` [ ], and no leading space. Access refuses those in a name, and a
closing bracket cannot be escaped, so a name holding one could end the bracket early."
  (and (stringp part) (plusp (length part))
       (char/= (char part 0) #\Space)
       (notany (lambda (c) (or (< (char-code c) 32) (find c ".!`[]"))) part)))

(defun %bracketed (parts clause)
  "PARTS, one or more strings, as a Jet name in brackets: [Client Data].[First Name]."
  (unless (and parts (every #'%jet-name-part-p parts))
    (error 'invalid-identifier
           :text (princ-to-string parts) :clause clause
           :expected "a Jet name: no leading space, no control character, none of . ! ` [ ]"))
  (format nil "~{[~A]~^.~}" parts))

(defun %quoted (parts clause)
  "PARTS, one or more strings, as a double-quoted SQL identifier: \"schema\".\"MyTable\".
Each part is quoted and an embedded double quote is doubled, which is how Postgres, SQLite and
XTDB all read a quoted name. A part must be a non-empty string without a NUL (#860). Under the
Jet dialect the parts go in brackets instead; see %BRACKETED."
  (when *bracket-identifiers*
    (return-from %quoted (%bracketed parts clause)))
  (unless (and parts (every (lambda (p) (and (stringp p) (plusp (length p))
                                              (not (find (code-char 0) p))))
                            parts))
    (error 'invalid-identifier :text (princ-to-string parts) :clause clause
                               :expected "a (:quoted ...) name: one or more non-empty strings without a NUL"))
  (format nil "~{~A~^.~}"
          (mapcar (lambda (p)
                    (with-output-to-string (o)
                      (write-char #\" o)
                      (loop for c across p do (when (char= c #\") (write-char #\" o)) (write-char c o))
                      (write-char #\" o)))
                  parts)))

(defun %ident (x &optional clause)
  "Render X as a SQL identifier in CLAUSE (a keyword naming where it stands, for the error): a
keyword or symbol by its downcased name, a string as it is, or (:quoted \"part\" ...) as a
double-quoted name. Dotted names pass through (:u.email -> \"u.email\"), and \"*\" stays \"*\".
An integer renders as itself only where SQL gives it a meaning: a positive one in ORDER BY and
GROUP BY, a column position, and a non-negative one as a SELECT item, a constant such as the 1
in EXISTS (SELECT 1 ...). Anywhere else, and as a negative number or a float, it is refused.

THE NAME IS WRITTEN INTO THE SQL, NOT BOUND (#860), so it is checked: each dot-separated part
must be an ASCII letter or underscore followed by letters, digits and underscores, and the last
part may be *. Anything else signals INVALID-IDENTIFIER naming CLAUSE. Before #860 a string
went into the SQL as it was, so a caller that put request text in an identifier position had
SQL injection. A mixed-case or reserved name is written with (:quoted ...); SQL text is written
with (:raw \"...\"), the one way to do so, visible at the call site."
  (when (and (consp x) (eq (car x) :quoted))
    (return-from %ident (%quoted (rest x) clause)))
  (when (or (and (member clause '(:order-by :group-by)) (typep x '(integer 1)))
            (and (eq clause :select) (typep x '(integer 0))))
    (return-from %ident (princ-to-string x)))
  (let ((name (typecase x
                (string x)
                (symbol (string-downcase (symbol-name x)))
                (t (princ-to-string x)))))
    (unless (%safe-identifier-p name)
      (error 'invalid-identifier :text name :clause clause
                                 :expected "a safe SQL identifier (letters, digits and underscores, dot-separated)"))
    ;; Jet writes every name in brackets, except a function name in (:call ...), which is
    ;; not a name in the table sense, and *, which is not a name at all (#1061).
    (if (and *bracket-identifiers* (not (eq clause :call)))
        (format nil "~{~A~^.~}"
                (mapcar (lambda (part) (if (string= part "*") part (format nil "[~A]" part)))
                        (%name-parts name)))
        name)))

(defun %item (ctx x clause)
  "A name or an expression in CLAUSE: GROUP BY, ON CONFLICT and RETURNING take either. A list
other than (:quoted ...) is an expression, so (:raw \"...\"), a function call or an operator
work there; anything else is a name, checked by %IDENT."
  (if (and (consp x) (not (eq (car x) :quoted)))
      (%expr ctx x)
      (%ident x clause)))

(defun %direction (x)
  "ASC or DESC for X, which is :asc or :desc, or the string asc or desc in any case. Anything
else signals INVALID-IDENTIFIER: the direction is written into the SQL, not bound (#860)."
  (let ((name (and (or (stringp x) (symbolp x)) (string-downcase (string x)))))
    (cond ((equal name "asc") "ASC")
          ((equal name "desc") "DESC")
          (t (error 'invalid-identifier :text (if (stringp x) x (princ-to-string x)) :clause :order-by
                                        :expected "an ORDER BY direction (:asc or :desc)")))))

(defun %subquery-p (e)
  "T if E is a nested query plist (a SELECT) usable as a subquery / derived table."
  (and (consp e) (eq (car e) :select)))

(defun %expr (ctx e)
  "Compile expression E to SQL, registering any params in CTX. Keyword/symbol => column;
a nested (:select ...) => a parenthesized subquery; (op ...) => operator/function;
anything else => a bound value."
  (cond
    ((%subquery-p e) (format nil "(~A)" (%select ctx e)))
    ((and (consp e) (keywordp (car e))) (%op ctx (car e) (cdr e)))
    ((symbolp e) (%ident e :expression))
    (t (%placeholder ctx e))))

;; Function/aggregate operators rendered as NAME(arg, ...).
(defparameter +fn-ops+ '(:count :sum :avg :min :max :coalesce :lower :upper :length :abs :round))

(defparameter +vector-distance-ops+
  '((:<-> "<->" "L2 distance"              "vector_l2_ops")
    (:<=> "<=>" "cosine distance"          "vector_cosine_ops")
    (:<#> "<#>" "negative inner product"   "vector_ip_ops"))
  "pgvector's three distance operators: keyword, SQL spelling, what it measures, and the
operator class an index must be built with to serve it.

THE TABLE IS THE POINT, not the rendering. pgvector has three distance operators and AN
INDEX BUILT FOR ONE IS NOT USED BY A QUERY WRITTEN WITH ANOTHER. There is no error: the
query returns correct rows and Postgres falls back to a sequential scan. Right answer,
wrong cost, invisible until the table is large -- so the operator has to be able to say
which index would have served it.")

(defparameter *warn-unindexed-vector-distance* t
  "Warn when a distance operator is compiled, naming the operator class that serves it.

ON BY DEFAULT AND MUFFLED BY THE APP, rather than off by default and discovered late. The
query compiler cannot know which indexes exist -- it is handed a table name, not a schema --
so it cannot tell a served query from a sequential scan. What it can do is refuse to be
silent about a choice whose cost is invisible.

An application that has built the matching index turns this off once, where a reader can see
it was a decision:

    (let ((mnemosyne/query:*warn-unindexed-vector-distance* nil))
      ...)

AN APPLICATION THAT WOULD RATHER FAIL THAN SCAN promotes it, and the form is written here
because the muffling one above is otherwise the only one a reader finds, which teaches the
quieter option by omission:

    (handler-bind ((mnemosyne/query:unindexed-vector-distance
                     (lambda (c) (error \"unindexed vector distance: ~A\" c))))
      ...)

A STYLE-WARNING suits a REPL and a batch job, where somebody reads the output. In a server
process nothing surfaces it, and correct rows returned by a sequential scan are
indistinguishable from a working query until the table is large and the traffic is real. So
the default is the wrong one for that caller, and promoting it at the boundary is how they
get the other answer without changing it for everybody. Asked for by a consuming app that
reached exactly that position.

Warning rather than refusing is deliberate and is the difference from ADR-0001. There, a
backend could not store the column, so proceeding produced a wrong database. Here proceeding
produces a right answer slowly, and breaking a working query to prevent a performance
problem would be the worse trade.")

(define-condition unindexed-vector-distance (style-warning)
  ((operator :initarg :operator :reader unindexed-vector-distance-operator)
   (opclass  :initarg :opclass  :reader unindexed-vector-distance-opclass)
   (measures :initarg :measures :reader unindexed-vector-distance-measures))
  (:report
   (lambda (c s)
     (format s "mnemosyne/query: ~A (~A) is served only by an index built WITH ~A.~%If none exists, this query is correct and does a sequential scan. Create one:~%  (:create-index :name :idx_... :on :table :columns (:col) :using :hnsw :opclass :~A)~%Silence this once you have: bind MNEMOSYNE/QUERY:*WARN-UNINDEXED-VECTOR-DISTANCE* to NIL."
             (unindexed-vector-distance-operator c)
             (unindexed-vector-distance-measures c)
             (unindexed-vector-distance-opclass c)
             (string-downcase (unindexed-vector-distance-opclass c))))))

(defun vector-distance-opclass (op)
  "The operator class serving distance operator OP, or NIL if OP is not one."
  (fourth (assoc op +vector-distance-ops+)))

(defun %vector-distance (ctx op args)
  "Compile a pgvector distance operator. Postgres only."
  (destructuring-bind (key sql measures opclass) (assoc op +vector-distance-ops+)
    (declare (ignore key))
    ;; REFUSED OFF POSTGRES, and that is not the same decision as the warning above. On
    ;; SQLite the vector COLUMN does not exist -- field-type-sql returns Unsupported and
    ;; schema-ddl refuses it -- so a distance query there is not slow, it is meaningless.
    ;; Rendering it would produce SQL referring to a column the backend refused to create.
    (unless (%postgres-p ctx)
      (error "mnemosyne/query: ~A needs pgvector, and the ~A backend has no vector column type at all (see ADR-0001). This query cannot mean anything there."
             sql (%dialect-name ctx)))
    (when *warn-unindexed-vector-distance*
      (warn 'unindexed-vector-distance :operator sql :opclass opclass :measures measures))
    (format nil "~A ~A ~A" (%expr ctx (first args)) sql (%expr ctx (second args)))))

(defun %escape-char (escape)
  "ESCAPE as a character: a character, or a string of exactly one. It must not be % or _, which
would make the escape character itself a wildcard, nor a control character. Anything else
signals INVALID-IDENTIFIER (#862)."
  (let ((c (cond ((characterp escape) escape)
                 ((and (stringp escape) (= 1 (length escape))) (char escape 0)))))
    (unless (and c (graphic-char-p c) (not (member c '(#\% #\_))))
      (error 'invalid-identifier :text (princ-to-string escape) :clause :escape
                                 :expected "a LIKE escape character (exactly one character, not % or _)"))
    c))

(defun %escape-suffix (ctx escape)
  "\" ESCAPE ?\" with ESCAPE bound as a parameter, or \"\" when ESCAPE is NIL. Bound, like every
value, so no quoting rule applies to it; Postgres and SQLite both accept a parameter there."
  (if (null escape)
      ""
      (format nil " ESCAPE ~A" (%placeholder ctx (string (%escape-char escape))))))

(defun like-escape (text &key (escape #\\))
  "TEXT with ESCAPE, %, and _ each preceded by ESCAPE, so that a LIKE or ILIKE pattern built
from it matches those characters literally. Use it with the same :escape on the operator:

  (:like :name (like-contains q) :escape \"\\\\\")

ESCAPE is a character or a one-character string, the backslash by default, and is checked as
the operator checks it: % or _, more than one character, or a control character signals
INVALID-IDENTIFIER rather than producing a pattern that matches something else."
  (let ((e (%escape-char escape)))
    (with-output-to-string (out)
      (loop for c across text
            do (when (or (char= c e) (char= c #\%) (char= c #\_)) (write-char e out))
               (write-char c out)))))

(defun like-contains (text &key (escape #\\))
  "A LIKE pattern that matches TEXT anywhere, with TEXT's own %, _ and ESCAPE taken literally:
\"%\", (LIKE-ESCAPE TEXT), \"%\". Pair it with the same :escape on :like or :ilike, which is
what makes the escaping mean the same thing on SQLite, which has no default escape character,
and Postgres, whose default is the backslash (#862)."
  (concatenate 'string "%" (like-escape text :escape escape) "%"))

(defun %datetime (ctx op args)
  "Compile (:date y m d) or (:timestamp y m d h mi s). Under Jet, a #...# literal written into
the SQL; under every other dialect, the ISO text bound as a value, the form mnemosyne stores
dates and timestamps in.

WRITTEN INTO THE SQL ON JET, NOT BOUND (#1061). Jet reads #yyyy-mm-dd# the same way whatever
the machine's locale, and a date passed as text is converted by locale rules. Writing the
value into the SQL is safe because every part is checked to be an integer in range (the year
from 100 to 9999, the range Jet accepts), so
nothing but digits, dashes, colons and a space can reach the SQL."
  (destructuring-bind (year month day &optional (hour 0) (minute 0) (second 0)) args
    (flet ((in-range (x lo hi) (and (integerp x) (<= lo x hi))))
      (unless (and (in-range year 100 9999) (in-range month 1 12)
                   (in-range day 1 (%days-in-month year month))
                   (in-range hour 0 23) (in-range minute 0 59) (in-range second 0 59)
                   (or (eq op :timestamp) (= 3 (length args))))
        (error "mnemosyne/query: ~S is not a valid ~(~A~); every part must be an integer in range."
               (cons op args) op)))
    (let ((text (if (eq op :date)
                    (format nil "~4,'0D-~2,'0D-~2,'0D" year month day)
                    (format nil "~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D"
                            year month day hour minute second))))
      (if (%jet-p ctx)
          (format nil "#~A#" text)
          (%placeholder ctx text)))))

(defun %value (ctx v)
  "V bound as a param, or V compiled as a date when it is a (:date ...) or (:timestamp ...)
form. Used where a value is bound without going through %EXPR: the endpoints of :between, an
:in list, and the values of INSERT and UPDATE."
  (if (and (consp v) (member (car v) '(:date :timestamp)))
      (%datetime ctx (car v) (cdr v))
      (%placeholder ctx v)))

(defun %days-in-month (year month)
  "The number of days in MONTH of YEAR, in the Gregorian calendar; 31 when MONTH is out of
range, which the caller refuses separately."
  (case month
    ((4 6 9 11) 30)
    (2 (if (and (zerop (mod year 4)) (or (plusp (mod year 100)) (zerop (mod year 400)))) 29 28))
    (t 31)))

(defun %ilike (ctx args)
  "Compile a case-insensitive match. Postgres only (#138).

REFUSED OFF POSTGRES RATHER THAN RENDERED AS LIKE. SQLite's LIKE ignores case for ASCII
letters only, so rendering :ilike as LIKE there would match `Café' against `CAFÉ' on one
backend and not on the other, and a caller could not tell which rule it had. The same refusal
applies to XTDB. A caller that needs a case-insensitive match off Postgres asks for it
explicitly, for example with LOWER on both sides."
  (unless (%postgres-p ctx)
    (error "mnemosyne/query: :ilike renders as Postgres ILIKE, and the ~A backend has no operator with the same case rules. Use (:like (:lower col) (:lower pattern)) there, knowing which characters its LOWER folds."
           (%dialect-name ctx)))
  (destructuring-bind (subject pattern &key escape) args
    (format nil "~A ILIKE ~A~A" (%expr ctx subject) (%expr ctx pattern) (%escape-suffix ctx escape))))

(defun %op (ctx op args)
  "Compile an operator expression (OP . ARGS)."
  (flet ((e (x) (%expr ctx x)))
    (case op
      ((:=)  (format nil "~A = ~A"  (e (first args)) (e (second args))))
      ((:<> :!=) (format nil "~A <> ~A" (e (first args)) (e (second args))))
      ((:>)  (format nil "~A > ~A"  (e (first args)) (e (second args))))
      ((:<)  (format nil "~A < ~A"  (e (first args)) (e (second args))))
      ((:>=) (format nil "~A >= ~A" (e (first args)) (e (second args))))
      ((:<=) (format nil "~A <= ~A" (e (first args)) (e (second args))))
      ((:and) (format nil "(~{~A~^ AND ~})" (mapcar #'e args)))
      ((:or)  (format nil "(~{~A~^ OR ~})"  (mapcar #'e args)))
      ((:not) (format nil "NOT (~A)" (e (first args))))
      ((:like) (destructuring-bind (subject pattern &key escape) args
                 (format nil "~A LIKE ~A~A" (e subject) (e pattern) (%escape-suffix ctx escape))))
      ((:ilike) (%ilike ctx args))
      ((:is-null)     (format nil "~A IS NULL"     (e (first args))))
      ((:is-not-null) (format nil "~A IS NOT NULL" (e (first args))))
      ((:in)
       (let ((rhs (second args)))
         (if (%subquery-p rhs)                      ; col IN (SELECT ...)
             (format nil "~A IN ~A" (e (first args)) (e rhs))
             (format nil "~A IN (~{~A~^, ~})"       ; col IN (?, ?, ...)
                     (e (first args))
                     (mapcar (lambda (v) (%value ctx v)) rhs)))))
      ((:between) (format nil "~A BETWEEN ~A AND ~A"
                          (e (first args)) (%value ctx (second args))
                          (%value ctx (third args))))
      ((:exists) (format nil "EXISTS ~A" (e (first args))))
      ((:distinct) (format nil "DISTINCT ~A" (e (first args))))
      ((:excluded) (format nil "EXCLUDED.~A" (%ident (first args) :excluded)))
      ((:call) (format nil "~A(~{~A~^, ~})" (%ident (first args) :call) (mapcar #'e (rest args))))
      ((:quoted) (%quoted args :expression))
      ((:raw) (first args))
      ((:date :timestamp) (%datetime ctx op args))
      ((:<-> :<=> :<#>) (%vector-distance ctx op args))
      (t (if (member op +fn-ops+)
             (format nil "~A(~{~A~^, ~})" (symbol-name op) (mapcar #'e args))
             (error "mnemosyne/query: unknown operator ~S" op))))))

(defun %order (ctx specs)
  "ORDER BY specs: a column, (column :asc|:desc), or ((expression) [:asc|:desc]).

THE EXPRESSION FORM EXISTS FOR NEAREST-NEIGHBOUR SEARCH (pre-publication issue 258), which is the whole use of
a distance operator: `ORDER BY embedding <=> $1 LIMIT 10'. Without it the operators would
compile in a WHERE clause and be unreachable in the one place they are actually written.

The nesting is not decoration. `(:embedding :desc)' and `(:<=> :embedding v)' are both
lists starting with a keyword, and nothing distinguishes them by shape -- so an expression
is wrapped in its own list and recognised by its CAR BEING A CONS. Written flat first, and
`ORDER BY (:<=> :embedding v)' rendered as `ORDER BY <=> EMBEDDING': the operator was read
as the column and the column as the direction, silently, producing SQL that Postgres would
reject at a point far from the mistake.

CTX is threaded through because an expression may BIND VALUES -- a query vector is a
parameter, not something to interpolate. Before this, ORDER BY could not bind anything,
which was invisible while it only ever rendered identifiers."
  (format nil "~{~A~^, ~}"
          (mapcar (lambda (spec)
                    (cond
                      ((and (consp spec) (consp (first spec)))
                       (format nil "~A~@[ ~A~]"
                               (%expr ctx (first spec))
                               (and (second spec) (%direction (second spec)))))
                      ((consp spec)
                       (format nil "~A ~A" (%ident (first spec) :order-by) (%direction (second spec))))
                      (t (%ident spec :order-by))))
                  specs)))

(defun %source (ctx x)
  "A FROM/JOIN source: a table identifier or a parenthesized subquery."
  (if (%subquery-p x) (format nil "(~A)" (%select ctx x)) (%ident x :from)))

(defun %from-item (ctx f)
  "A FROM/JOIN item: a source, or (:as source alias) rendered \"source AS alias\"."
  (if (and (consp f) (eq (car f) :as))
      (format nil "~A AS ~A" (%source ctx (second f)) (%ident (third f) :as))
      (%source ctx f)))

(defun %select-item (ctx item)
  "A SELECT projection: a column, a function/operator expr, or (:as expr alias)."
  (cond ((and (consp item) (eq (car item) :as))
         (format nil "~A AS ~A" (%expr ctx (second item)) (%ident (third item) :as)))
        ((consp item) (%expr ctx item))
        (t (%ident item :select))))

(defun %joins (ctx specs)
  "Compile an ordered list of JOIN specs (KIND SOURCE &optional ON-EXPR), one string each."
  (mapcar (lambda (j)
            (destructuring-bind (kind source &optional on) j
              (when (and (%jet-p ctx) (member kind '(:full :cross)))
                (error 'unsupported-query :dialect "jet" :clause (format nil "~A JOIN" kind)))
              (with-output-to-string (o)
                (format o " ~A JOIN ~A"
                        (ecase kind (:inner "INNER") (:left "LEFT") (:right "RIGHT")
                                    (:full "FULL") (:cross "CROSS"))
                        (%from-item ctx source))
                (when on (format o " ON ~A" (%expr ctx on))))))
          specs))

(defun %from-and-joins (ctx q s)
  "Write the FROM list and the joins to S. Jet needs each join but the last in parentheses,
FROM ([a] INNER JOIN [b] ON ...) INNER JOIN [c] ON ..., and rejects the flat form."
  (let* ((from (mapcar (lambda (f) (%from-item ctx f)) (getf q :from)))
         (joins (%joins ctx (getf q :join)))
         (nest (and (%jet-p ctx) (rest joins))))
    (when (and nest (rest from))
      (error 'unsupported-query :dialect "jet" :clause "join after a list of FROM tables"
                                :detail "Jet nests joins in parentheses around one table"))
    (when from
      (format s " FROM ~A~{~A~^, ~}"
              (if nest (make-string (1- (length joins)) :initial-element #\() "") from))
    (format s (if nest "~{~A~^)~}" "~{~A~}") joins)))

(defun %returning (ctx cols)
  (format nil " RETURNING ~{~A~^, ~}" (mapcar (lambda (c) (%item ctx c :returning)) cols)))

(defun %check-xtdb (ctx q)
  "Signal on DML constructs XTDB 2 does not support, before we emit invalid SQL. XTDB 2 is
PG-wire but a distinct dialect (see docs/xtdb-notes.md): its INSERT already upserts on _id,
so ON CONFLICT is meaningless; and its DML has no RETURNING (read the value back separately)."
  (when (%xtdb-p ctx)
    (when (getf q :on-conflict)
      (error "mnemosyne/query: ON CONFLICT is unsupported on XTDB 2 -- its INSERT already upserts on _id (a new temporal version). Drop :on-conflict for the :xtdb dialect."))
    (when (getf q :returning)
      (error "mnemosyne/query: RETURNING is unsupported on XTDB 2 DML -- read the value back with a separate query. Drop :returning for the :xtdb dialect."))))

(defparameter +aggregate-ops+ '(:count :sum :avg :min :max)
  "The aggregates that Jet names Expr1000 and so on when they have no alias (#1061).")

(defun %aggregate-alias (item taken)
  "An alias for the unaliased aggregate ITEM that is not in TAKEN: the function's name, then
_ and the column's last part when the argument is a plain column. COUNT(*) is count and
SUM(o.total) is sum_total. A clash takes _2, _3 and so on."
  (let* ((arg (second item))
         (base (format nil "~(~A~)~@[_~A~]" (first item)
                       (and (or (symbolp arg) (stringp arg))
                            (let ((last (car (last (%name-parts (string-downcase (string arg)))))))
                              (and (%identifier-part-p last) last))))))
    (loop for n from 1
          for name = (if (= n 1) base (format nil "~A_~D" base n))
          unless (member name taken :test #'string-equal) return name)))

(defun %output-name (item)
  "The name the column for SELECT item ITEM is read back by, or NIL when Jet would make one
up: an alias, or the last part of a plain or quoted column name."
  (flet ((name-of (x)
           (cond ((and (consp x) (eq (car x) :quoted)) (car (last (rest x))))
                 ((or (symbolp x) (stringp x))
                  (let ((last (car (last (%name-parts (string x))))))
                    (and (string/= last "*") last))))))
    (if (and (consp item) (eq (car item) :as))
        (name-of (third item))
        (and (or (atom item) (eq (car item) :quoted)) (name-of item)))))

(defun %jet-select-items (ctx items)
  "ITEMS rendered for Jet, with an alias given to each aggregate that has none, so the column
can be read back by name (#128, row 8). The alias avoids every name already in the list."
  (let ((taken (remove nil (mapcar #'%output-name items))))
    (mapcar (lambda (it)
              (if (and (consp it) (member (car it) +aggregate-ops+))
                  (let ((alias (%aggregate-alias it taken)))
                    (push alias taken)
                    (format nil "~A AS ~A" (%expr ctx it) (%ident alias :as)))
                  (%select-item ctx it)))
            items)))

(defun %top (q)
  "The \"TOP n \" prefix for Jet's row limit, or \"\". N is written into the SQL, because Jet
does not take a parameter there, so it must be a positive integer."
  (let ((n (getf q :limit)))
    (cond ((null n) "")
          ((typep n '(integer 1)) (format nil "TOP ~D " n))
          (t (error "mnemosyne/query: :limit ~S must be a positive integer for TOP n on jet." n)))))

(defun %select (ctx q)
  (when (and (%jet-p ctx) (getf q :offset))
    (error 'unsupported-query :dialect "jet" :clause "OFFSET"
                              :detail "page with a WHERE on the last key seen and :limit instead"))
  (with-output-to-string (s)
    (let ((items (or (getf q :select) '(:*))))
      (if (%jet-p ctx)
          (format s "SELECT ~A~{~A~^, ~}" (%top q) (%jet-select-items ctx items))
          (format s "SELECT ~{~A~^, ~}" (mapcar (lambda (it) (%select-item ctx it)) items))))
    (%from-and-joins ctx q s)
    (when (getf q :where)    (format s " WHERE ~A" (%expr ctx (getf q :where))))
    (when (getf q :group-by) (format s " GROUP BY ~{~A~^, ~}" (mapcar (lambda (g) (%item ctx g :group-by)) (getf q :group-by))))
    (when (getf q :having)   (format s " HAVING ~A" (%expr ctx (getf q :having))))
    (when (getf q :order-by) (format s " ORDER BY ~A" (%order ctx (getf q :order-by))))
    (when (and (getf q :limit) (not (%jet-p ctx)))
      (format s " LIMIT ~A"  (%placeholder ctx (getf q :limit))))
    (when (getf q :offset)   (format s " OFFSET ~A" (%placeholder ctx (getf q :offset))))))

(defun %on-conflict (ctx q s)
  "Emit the ON CONFLICT (...) DO NOTHING|UPDATE tail of an upsert, if present."
  (let ((tgt (getf q :on-conflict)))
    (when tgt
      (format s " ON CONFLICT (~{~A~^, ~})" (mapcar (lambda (x) (%item ctx x :on-conflict)) tgt))
      (cond ((getf q :do-nothing) (write-string " DO NOTHING" s))
            ((getf q :do-update)
             (format s " DO UPDATE SET ~{~A~^, ~}"
                     (loop for (k v) on (getf q :do-update) by #'cddr
                           collect (format nil "~A = ~A" (%ident k :do-update) (%expr ctx v)))))))))

(defun %insert (ctx q)
  (%check-xtdb ctx q)
  (let* ((rows (getf q :values))
         (cols (loop for (k) on (first rows) by #'cddr collect k)))
    (with-output-to-string (s)
      (format s "INSERT INTO ~A (~{~A~^, ~}) VALUES ~{~A~^, ~}"
              (%ident (getf q :insert-into) :insert-into)
              (mapcar (lambda (c) (%ident c :insert-into)) cols)
              (mapcar (lambda (row)
                        (format nil "(~{~A~^, ~})"
                                (mapcar (lambda (c) (%value ctx (getf row c))) cols)))
                      rows))
      (%on-conflict ctx q s)
      (when (getf q :returning) (write-string (%returning ctx (getf q :returning)) s)))))

(defun %update (ctx q)
  (%check-xtdb ctx q)
  (with-output-to-string (s)
    (format s "UPDATE ~A SET ~{~A~^, ~}"
            (%ident (getf q :update) :update)
            (loop for (k v) on (getf q :set) by #'cddr
                  collect (format nil "~A = ~A" (%ident k :set) (%value ctx v))))
    (when (getf q :where) (format s " WHERE ~A" (%expr ctx (getf q :where))))
    (when (getf q :returning) (write-string (%returning ctx (getf q :returning)) s))))

(defun %delete (ctx q)
  (%check-xtdb ctx q)
  (with-output-to-string (s)
    (format s "DELETE FROM ~A" (%ident (getf q :delete-from) :delete-from))
    (when (getf q :where) (format s " WHERE ~A" (%expr ctx (getf q :where))))
    (when (getf q :returning) (write-string (%returning ctx (getf q :returning)) s))))

(defun %check-dialect (dialect)
  "Normalise DIALECT through the one tree-wide normaliser and return the typed value.

THIS FUNCTION USED TO BE THE SECOND VOCABULARY (pre-publication issue 432, ADR-0003). It held its own list of
keywords and refused anything else, including the string \"postgres\" -- which is what
MNEMOSYNE/DDL and MNEMOSYNE/SCHEMA take, so a caller holding one spelling was refused by the
module that wanted the other. Refusing was already better than what came before it: every
comparison here is against one dialect, so an unrecognised value took the non-Postgres
branch everywhere, and the vector-distance check then told a caller ON POSTGRES that \"the
postgres backend has no vector column type at all\".

Now there is one vocabulary and this is a call into it. The refusal it kept is the part
worth keeping -- ADR-0003's rule is that a module branching on a dialect refuses a value it
does not recognise rather than treating it as the other one."
  (fldsh:dialect-for dialect))

(defun sql (query &key (dialect *dialect*) inline)
  "Compile a QUERY plist to (VALUES sql-string params-list). The statement is chosen by
which clause is present: :select / :insert-into / :update / :delete-from. With :INLINE
non-NIL, values are rendered inline instead of bound (params is then NIL) -- for display
and round-tripping with PARSE, never for executing untrusted input.

DIALECT is a designator -- :postgres, \"postgres\" or a typed MNEMOSYNE/FIELD:DIALECT -- and
is normalised and checked once here: an unknown spelling used to take the SQLite branch
silently. See %CHECK-DIALECT."
  (let* ((ctx (make-ctx (%check-dialect dialect) inline))
         (*bracket-identifiers* (%jet-p ctx))
         (str (cond ((getf query :select)      (%select ctx query))
                    ((getf query :insert-into)  (%insert ctx query))
                    ((getf query :update)       (%update ctx query))
                    ((getf query :delete-from)  (%delete ctx query))
                    (t (error "mnemosyne/query: no recognized statement in ~S" query)))))
    (values str (nreverse (ctx-params ctx)))))

(defun fetch (connection query &key (dialect *dialect*))
  "Compile QUERY and run it through the row-returning path on CONNECTION; return rows
(list of plists). Use for SELECT -- and for any INSERT/UPDATE/DELETE ... RETURNING."
  (multiple-value-bind (s p) (sql query :dialect dialect)
    (apply #'mnemosyne/conn:query connection s p)))

(defun map-fetch (connection function query &key (dialect *dialect*))
  "FETCH, calling FUNCTION on each row as it is read instead of returning a list of them, through
MNEMOSYNE/CONN:MAP-QUERY. Returns the number of rows."
  (multiple-value-bind (s p) (sql query :dialect dialect)
    (apply #'mnemosyne/conn:map-query connection function s p)))

(defun run (connection query &key (dialect *dialect*))
  "Compile QUERY and run it as a statement (insert/update/delete) on CONNECTION, returning
the affected-row count. For a RETURNING statement whose rows you want, use FETCH instead."
  (multiple-value-bind (s p) (sql query :dialect dialect)
    (apply #'mnemosyne/conn:exec connection s p)))
