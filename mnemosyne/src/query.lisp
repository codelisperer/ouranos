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
;;;;
;;;; DIALECTS. :sqlite / :postgres emit "?" (CL-DBI binds them; verified on both). :xtdb
;;;; is the seam for XTDB 2 -- which is PG-wire but a DISTINCT dialect: **no DDL**
;;;; (schemaless -- no CREATE TABLE), **$N-style / different param handling**, and
;;;; **transaction gotchas** (see docs/xtdb-notes.md). Its temporal SELECT extensions
;;;; (FOR VALID_TIME AS OF ...) layer on later; the :xtdb placeholder path here is a
;;;; provisional seam, not yet verified end-to-end.

(in-package #:mnemosyne/query)

(defvar *dialect* :sqlite
  "The SQL dialect SQL compiles for: :sqlite | :postgres (both use \"?\") | :xtdb.

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

(defun %ident (x)
  "Render X (keyword/symbol/string) as a SQL identifier. Dotted keywords pass through
(e.g. :u.email -> \"u.email\"); \"*\" stays \"*\"."
  (typecase x
    (string x)
    (symbol (string-downcase (symbol-name x)))
    (t (princ-to-string x))))

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
    ((symbolp e) (%ident e))
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
      ((:like) (format nil "~A LIKE ~A" (e (first args)) (e (second args))))
      ((:is-null)     (format nil "~A IS NULL"     (e (first args))))
      ((:is-not-null) (format nil "~A IS NOT NULL" (e (first args))))
      ((:in)
       (let ((rhs (second args)))
         (if (%subquery-p rhs)                      ; col IN (SELECT ...)
             (format nil "~A IN ~A" (e (first args)) (e rhs))
             (format nil "~A IN (~{~A~^, ~})"       ; col IN (?, ?, ...)
                     (e (first args))
                     (mapcar (lambda (v) (%placeholder ctx v)) rhs)))))
      ((:between) (format nil "~A BETWEEN ~A AND ~A"
                          (e (first args)) (%placeholder ctx (second args))
                          (%placeholder ctx (third args))))
      ((:exists) (format nil "EXISTS ~A" (e (first args))))
      ((:distinct) (format nil "DISTINCT ~A" (e (first args))))
      ((:excluded) (format nil "EXCLUDED.~A" (%ident (first args))))
      ((:call) (format nil "~A(~{~A~^, ~})" (%ident (first args)) (mapcar #'e (rest args))))
      ((:raw) (first args))
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
                               (and (second spec)
                                    (string-upcase (%ident (second spec))))))
                      ((consp spec)
                       (format nil "~A ~A" (%ident (first spec))
                               (string-upcase (%ident (second spec)))))
                      (t (%ident spec))))
                  specs)))

(defun %source (ctx x)
  "A FROM/JOIN source: a table identifier or a parenthesized subquery."
  (if (%subquery-p x) (format nil "(~A)" (%select ctx x)) (%ident x)))

(defun %from-item (ctx f)
  "A FROM/JOIN item: a source, or (:as source alias) rendered \"source AS alias\"."
  (if (and (consp f) (eq (car f) :as))
      (format nil "~A AS ~A" (%source ctx (second f)) (%ident (third f)))
      (%source ctx f)))

(defun %select-item (ctx item)
  "A SELECT projection: a column, a function/operator expr, or (:as expr alias)."
  (cond ((and (consp item) (eq (car item) :as))
         (format nil "~A AS ~A" (%expr ctx (second item)) (%ident (third item))))
        ((consp item) (%expr ctx item))
        (t (%ident item))))

(defun %joins (ctx specs)
  "Compile an ordered list of JOIN specs (KIND SOURCE &optional ON-EXPR)."
  (with-output-to-string (o)
    (dolist (j specs)
      (destructuring-bind (kind source &optional on) j
        (format o " ~A JOIN ~A"
                (ecase kind (:inner "INNER") (:left "LEFT") (:right "RIGHT")
                            (:full "FULL") (:cross "CROSS"))
                (%from-item ctx source))
        (when on (format o " ON ~A" (%expr ctx on)))))))

(defun %returning (cols)
  (format nil " RETURNING ~{~A~^, ~}" (mapcar #'%ident cols)))

(defun %check-xtdb (ctx q)
  "Signal on DML constructs XTDB 2 does not support, before we emit invalid SQL. XTDB 2 is
PG-wire but a distinct dialect (see docs/xtdb-notes.md): its INSERT already upserts on _id,
so ON CONFLICT is meaningless; and its DML has no RETURNING (read the value back separately)."
  (when (%xtdb-p ctx)
    (when (getf q :on-conflict)
      (error "mnemosyne/query: ON CONFLICT is unsupported on XTDB 2 -- its INSERT already upserts on _id (a new temporal version). Drop :on-conflict for the :xtdb dialect."))
    (when (getf q :returning)
      (error "mnemosyne/query: RETURNING is unsupported on XTDB 2 DML -- read the value back with a separate query. Drop :returning for the :xtdb dialect."))))

(defun %select (ctx q)
  (with-output-to-string (s)
    (format s "SELECT ~{~A~^, ~}"
            (mapcar (lambda (it) (%select-item ctx it)) (or (getf q :select) '(:*))))
    (when (getf q :from) (format s " FROM ~{~A~^, ~}"
                                 (mapcar (lambda (f) (%from-item ctx f)) (getf q :from))))
    (when (getf q :join)     (write-string (%joins ctx (getf q :join)) s))
    (when (getf q :where)    (format s " WHERE ~A" (%expr ctx (getf q :where))))
    (when (getf q :group-by) (format s " GROUP BY ~{~A~^, ~}" (mapcar #'%ident (getf q :group-by))))
    (when (getf q :having)   (format s " HAVING ~A" (%expr ctx (getf q :having))))
    (when (getf q :order-by) (format s " ORDER BY ~A" (%order ctx (getf q :order-by))))
    (when (getf q :limit)    (format s " LIMIT ~A"  (%placeholder ctx (getf q :limit))))
    (when (getf q :offset)   (format s " OFFSET ~A" (%placeholder ctx (getf q :offset))))))

(defun %on-conflict (ctx q s)
  "Emit the ON CONFLICT (...) DO NOTHING|UPDATE tail of an upsert, if present."
  (let ((tgt (getf q :on-conflict)))
    (when tgt
      (format s " ON CONFLICT (~{~A~^, ~})" (mapcar #'%ident tgt))
      (cond ((getf q :do-nothing) (write-string " DO NOTHING" s))
            ((getf q :do-update)
             (format s " DO UPDATE SET ~{~A~^, ~}"
                     (loop for (k v) on (getf q :do-update) by #'cddr
                           collect (format nil "~A = ~A" (%ident k) (%expr ctx v)))))))))

(defun %insert (ctx q)
  (%check-xtdb ctx q)
  (let* ((rows (getf q :values))
         (cols (loop for (k) on (first rows) by #'cddr collect k)))
    (with-output-to-string (s)
      (format s "INSERT INTO ~A (~{~A~^, ~}) VALUES ~{~A~^, ~}"
              (%ident (getf q :insert-into)) (mapcar #'%ident cols)
              (mapcar (lambda (row)
                        (format nil "(~{~A~^, ~})"
                                (mapcar (lambda (c) (%placeholder ctx (getf row c))) cols)))
                      rows))
      (%on-conflict ctx q s)
      (when (getf q :returning) (write-string (%returning (getf q :returning)) s)))))

(defun %update (ctx q)
  (%check-xtdb ctx q)
  (with-output-to-string (s)
    (format s "UPDATE ~A SET ~{~A~^, ~}"
            (%ident (getf q :update))
            (loop for (k v) on (getf q :set) by #'cddr
                  collect (format nil "~A = ~A" (%ident k) (%placeholder ctx v))))
    (when (getf q :where) (format s " WHERE ~A" (%expr ctx (getf q :where))))
    (when (getf q :returning) (write-string (%returning (getf q :returning)) s))))

(defun %delete (ctx q)
  (%check-xtdb ctx q)
  (with-output-to-string (s)
    (format s "DELETE FROM ~A" (%ident (getf q :delete-from)))
    (when (getf q :where) (format s " WHERE ~A" (%expr ctx (getf q :where))))
    (when (getf q :returning) (write-string (%returning (getf q :returning)) s))))

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

(defun run (connection query &key (dialect *dialect*))
  "Compile QUERY and run it as a statement (insert/update/delete) on CONNECTION, returning
the affected-row count. For a RETURNING statement whose rows you want, use FETCH instead."
  (multiple-value-bind (s p) (sql query :dialect dialect)
    (apply #'mnemosyne/conn:exec connection s p)))
