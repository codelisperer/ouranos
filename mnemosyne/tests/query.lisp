;;;; tests/query.lisp --- fiveam suite for mnemosyne/query (generation + round-trip).
;;;;
;;;; Two invariants under test:
;;;;   1. GENERATION -- a query plist compiles to the expected parameterized SQL + params.
;;;;   2. ROUND-TRIP -- (parse (sql q :inline t)) reproduces q, across the whole surface
;;;;      (joins, aliases, aggregates, subqueries, EXISTS, IN-subquery, RETURNING, upsert).
;;;; Plus the XTDB dialect guards (ON CONFLICT / RETURNING signal on :xtdb).

(defpackage #:mnemosyne/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:q #:mnemosyne/query)
                    (#:sch #:mnemosyne/schema)
                    (#:cs #:mnemosyne/changeset)
                    (#:ddl #:mnemosyne/ddl)
                    (#:intro #:mnemosyne/introspect)
                    (#:conn #:mnemosyne/conn)
                    (#:be #:mnemosyne/backend)
                    (#:fld #:mnemosyne/field)
                    (#:fldsh #:mnemosyne/field-shell)
                    (#:mig #:mnemosyne/migrate)
                    (#:der #:mnemosyne/derived))
  (:export #:run-tests))

(in-package #:mnemosyne/tests)

(def-suite mnemosyne :description "Mnemosyne query builder + parser.")
(in-suite mnemosyne)

;;; RUN-TESTS lives in tests/backends.lisp, next to the per-backend coverage banner it has
;;; to print after the suite finishes (pre-publication issue 176). The symbol is exported here because this file
;;; defines the package; where it is DEFINED is a separate question from where it is named.

;;; --- helpers --------------------------------------------------------------
(defun gen (q &rest args) (multiple-value-list (apply #'q:sql q args)))
(defun rt (q)
  "Round-trip a query plist through inline-SQL and back; T if it reproduces Q."
  (equal q (q:parse (q:sql q :dialect :postgres :inline t))))
(defun rt-sql (s)
  "Round-trip a SQL string through parse and back to inline SQL; T if it reproduces S."
  (string= s (q:sql (q:parse s) :dialect :postgres :inline t)))

;;; --- 1. generation --------------------------------------------------------
(test select-basic
  (is (equal (list "SELECT id, email FROM users WHERE (email = ? AND id > ?) ORDER BY id DESC LIMIT ?"
                   '("a@x" 10 20))
             (gen '(:select (:id :email) :from (:users)
                    :where (:and (:= :email "a@x") (:> :id 10))
                    :order-by ((:id :desc)) :limit 20)))))

(test select-star (is (equal (list "SELECT * FROM users" '()) (gen '(:select (:*) :from (:users))))))

(test join-generation
  (is (equal (list (concatenate 'string
                     "SELECT u.name, o.total FROM users AS u"
                     " INNER JOIN orders AS o ON u.id = o.user_id"
                     " LEFT JOIN payments AS p ON o.id = p.order_id"
                     " WHERE o.total > ?")
                   '(100))
             (gen '(:select (:u.name :o.total) :from ((:as :users :u))
                    :join ((:inner (:as :orders :o) (:= :u.id :o.user_id))
                           (:left  (:as :payments :p) (:= :o.id :p.order_id)))
                    :where (:> :o.total 100))))))

(test aggregate-generation
  (is (equal (list "SELECT COUNT(*) AS n, SUM(total) AS gross FROM orders GROUP BY user_id HAVING COUNT(*) > ?"
                   '(3))
             (gen '(:select ((:as (:count :*) :n) (:as (:sum :total) :gross)) :from (:orders)
                    :group-by (:user_id) :having (:> (:count :*) 3))))))

(test distinct-generation
  (is (equal (list "SELECT COUNT(DISTINCT country) AS c FROM users" '())
             (gen '(:select ((:as (:count (:distinct :country)) :c)) :from (:users))))))

(test subquery-in
  (is (equal (list "SELECT id FROM users WHERE id IN (SELECT user_id FROM admins)" '())
             (gen '(:select (:id) :from (:users)
                    :where (:in :id (:select (:user_id) :from (:admins))))))))

(test exists-generation
  ;; SELECT 1 is a literal projection (not a bound param) -- the classic EXISTS idiom.
  (is (equal (list "SELECT * FROM users AS u WHERE EXISTS (SELECT 1 FROM orders AS o WHERE o.user_id = u.id)"
                   '())
             (gen '(:select (:*) :from ((:as :users :u))
                    :where (:exists (:select (1) :from ((:as :orders :o))
                                     :where (:= :o.user_id :u.id))))))))

(test returning-generation
  (is (equal (list "INSERT INTO users (email) VALUES (?) RETURNING id, created_at" '("a@x"))
             (gen '(:insert-into :users :values ((:email "a@x")) :returning (:id :created_at))))))

(test upsert-do-update
  (is (equal (list "INSERT INTO users (email, name) VALUES (?, ?) ON CONFLICT (email) DO UPDATE SET name = EXCLUDED.name"
                   '("a@x" "A"))
             (gen '(:insert-into :users :values ((:email "a@x" :name "A"))
                    :on-conflict (:email) :do-update (:name (:excluded :name)))))))

(test upsert-do-nothing
  (is (equal (list "INSERT INTO users (email) VALUES (?) ON CONFLICT (email) DO NOTHING" '("a@x"))
             (gen '(:insert-into :users :values ((:email "a@x")) :on-conflict (:email) :do-nothing t)))))

;;; --- 2. round-trip (data -> SQL -> data) ----------------------------------
(test round-trip-data
  (dolist (q '((:select (:id :email) :from (:users)
                :where (:and (:= :email "a@x") (:> :id 10)) :order-by ((:id :desc)) :limit 20)
               (:select (:*) :from (:users))
               (:select (:u.name :o.total) :from ((:as :users :u))
                :join ((:inner (:as :orders :o) (:= :u.id :o.user_id))
                       (:left (:as :payments :p) (:= :o.id :p.order_id)))
                :where (:> :o.total 100))
               (:select ((:as (:count :*) :n) (:as (:sum :total) :gross)) :from (:orders)
                :group-by (:user_id) :having (:> (:count :*) 3))
               (:select ((:as (:count (:distinct :country)) :c)) :from (:users))
               (:select (:id) :from (:users) :where (:in :id (:select (:user_id) :from (:admins))))
               (:select (:t.x) :from ((:as (:select (:x) :from (:big)) :t)))
               (:insert-into :users :values ((:email "a@x")) :returning (:id))
               (:insert-into :users :values ((:email "a@x" :name "A"))
                :on-conflict (:email) :do-update (:name (:excluded :name)))
               (:insert-into :users :values ((:email "a@x")) :on-conflict (:email) :do-nothing t)
               (:update :users :set (:name "B") :where (:= :id 5) :returning (:id))
               (:delete-from :users :where (:= :id 5) :returning (:id))))
    (is (rt q) "round-trip failed for ~S -> ~S" q (q:parse (q:sql q :dialect :postgres :inline t)))))

;;; --- 3. round-trip (SQL -> data -> SQL) ------------------------------------
(test round-trip-sql
  (dolist (s '("SELECT * FROM users"
               "SELECT id, email FROM users WHERE email = 'a@x'"
               "SELECT u.name FROM users AS u INNER JOIN orders AS o ON u.id = o.user_id"
               "SELECT COUNT(*) AS n FROM orders GROUP BY user_id HAVING COUNT(*) > 3"
               "SELECT id FROM users WHERE id IN (SELECT user_id FROM admins)"
               "INSERT INTO users (email) VALUES ('a@x') ON CONFLICT (email) DO NOTHING"
               "UPDATE users SET name = 'B' WHERE id = 5 RETURNING id"))
    (is (rt-sql s) "SQL round-trip failed for ~S -> ~S" s (q:sql (q:parse s) :dialect :postgres :inline t))))

;;; --- 4. XTDB dialect guards ------------------------------------------------
(test xtdb-rejects-on-conflict
  (signals error
    (q:sql '(:insert-into :t :values ((:_id 1)) :on-conflict (:_id) :do-nothing t) :dialect :xtdb)))

(test xtdb-rejects-returning
  (signals error
    (q:sql '(:insert-into :t :values ((:_id 1)) :returning (:_id)) :dialect :xtdb)))

(test xtdb-allows-plain-insert
  (is (equal (list "INSERT INTO t (_id, name) VALUES ($1, $2)" '(1 "a"))
             (gen '(:insert-into :t :values ((:_id 1 :name "a"))) :dialect :xtdb))))

;;; --- pgvector distance operators (pre-publication issue 258) ------------------------------------
;;;
;;; pgvector has three distance operators and AN INDEX BUILT FOR ONE IS NOT USED BY A QUERY
;;; WRITTEN WITH ANOTHER. There is no error: the query returns correct rows and Postgres
;;; falls back to a sequential scan. Right answer, wrong cost, invisible until the table is
;;; large. That is why these compile with a warning rather than silently, and why the index
;;; DDL refuses to default an operator class.

(test the-three-distance-operators-render-with-their-sql-spelling
  (dolist (pair '((:<-> "<->") (:<=> "<=>") (:<#> "<#>")))
    (destructuring-bind (op sql) pair
      (let ((rendered (handler-bind ((q:unindexed-vector-distance #'muffle-warning))
                        (q:sql (list :select '(:id) :from '("docs")
                                     :where (list :< (list op :embedding "[1,2,3]") 0.5))
                               :dialect :postgres))))
        (is (search sql rendered) "~A should render as ~A, got: ~A" op sql rendered)))))

(test a-distance-in-order-by-binds-its-vector-rather-than-interpolating-it
  "THE SHAPE VECTOR SEARCH IS ACTUALLY WRITTEN IN -- `ORDER BY embedding <=> $1 LIMIT 10'.
The query vector is a value, so it binds like any other; interpolating it would put a
user-supplied string into SQL text."
  (multiple-value-bind (sql params)
      (handler-bind ((q:unindexed-vector-distance #'muffle-warning))
        (q:sql (list :select '(:id) :from '("docs")
                     :order-by (list (list (list :<=> :embedding "[1,2,3]")))
                     :limit 5)
               :dialect :postgres))
    (is (search "ORDER BY embedding <=> ?" sql) "got: ~A" sql)
    (is (equal '("[1,2,3]" 5) params) "the vector must be bound, got: ~S" params)))

(test an-ordinary-order-by-still-works-both-shapes
  "The control for the expression form above: adding it must not change what a column or a
(column :desc) pair renders to."
  (is (search "ORDER BY name" (q:sql '(:select (:id) :from ("t") :order-by (:name))
                                     :dialect :postgres)))
  (is (search "ORDER BY name DESC"
              (q:sql '(:select (:id) :from ("t") :order-by ((:name :desc)))
                     :dialect :postgres))))

(test a-distance-operator-is-refused-off-postgres
  "Not the same decision as the warning. On SQLite the vector COLUMN does not exist --
field-type-sql returns Unsupported and schema-ddl refuses it -- so a distance query there is
not slow, it is meaningless."
  (dolist (dialect '(:sqlite :xtdb))
    (signals error
      (q:sql (list :select '(:id) :from '("docs")
                   :order-by (list (list (list :<=> :embedding "[1,2,3]"))))
             :dialect dialect))))

(test ilike-renders-as-postgres-ilike-with-its-pattern-bound
  "#138: case-insensitive matching for exact retrieval. The pattern is a parameter, never
interpolated, and the SQL parses back to the same query."
  (is (equal (list "SELECT id FROM chunks WHERE text ILIKE ?" '("%clause%"))
             (gen '(:select (:id) :from (:chunks) :where (:ilike :text "%clause%"))
                  :dialect :postgres)))
  (is (rt '(:select (:id) :from (:chunks) :where (:ilike :text "%clause%")))))

(test ilike-is-refused-off-postgres
  "SQLite's LIKE folds ASCII case only, so rendering :ilike as LIKE there would apply a
different rule without saying so. Control: :like still renders on SQLite."
  (dolist (dialect '(:sqlite :xtdb))
    (signals error
      (q:sql '(:select (:id) :from (:chunks) :where (:ilike :text "%a%")) :dialect dialect)))
  (is (equal (list "SELECT id FROM chunks WHERE text LIKE ?" '("%a%"))
             (gen '(:select (:id) :from (:chunks) :where (:like :text "%a%")) :dialect :sqlite))))

(test compiling-a-distance-operator-warns-and-names-the-operator-class-that-serves-it
  "Warn, do not refuse: the query is correct and the cost is invisible. The compiler is
handed a table name rather than a schema, so it cannot know which indexes exist -- what it
can do is refuse to be silent."
  (let ((warned nil))
    (handler-bind ((q:unindexed-vector-distance
                     (lambda (c)
                       (setf warned c)
                       (muffle-warning c))))
      (q:sql (list :select '(:id) :from '("docs")
                   :order-by (list (list (list :<=> :embedding "[1,2,3]"))))
             :dialect :postgres))
    (is-true warned "compiling a distance operator must warn")
    (when warned
      (is (string= "<=>" (q:unindexed-vector-distance-operator warned)))
      (is (string= "vector_cosine_ops" (q:unindexed-vector-distance-opclass warned))
          "the warning must name the operator class that would serve this query"))))

(test each-operator-names-its-own-operator-class
  "The pairing is the whole point. Naming the wrong class would send a reader to build an
index that does not serve their query, which is the failure this warning exists for."
  (is (string= "vector_l2_ops" (q:vector-distance-opclass :<->)))
  (is (string= "vector_cosine_ops" (q:vector-distance-opclass :<=>)))
  (is (string= "vector_ip_ops" (q:vector-distance-opclass :<#>)))
  (is (null (q:vector-distance-opclass :=)) "a non-distance operator has no class"))

(test the-warning-can-be-silenced-by-an-app-that-has-built-the-index
  "On by default and muffled deliberately, rather than off by default and discovered late."
  (let ((q:*warn-unindexed-vector-distance* nil)
        (warned nil))
    (handler-bind ((q:unindexed-vector-distance (lambda (c) (setf warned c) (muffle-warning c))))
      (q:sql (list :select '(:id) :from '("docs")
                   :order-by (list (list (list :<-> :embedding "[1,2,3]"))))
             :dialect :postgres))
    (is (null warned) "binding the flag to NIL must silence it")))

;;; --- the dialect is a closed set here too (pre-publication issue 258, found by a wrong spelling) --

(test an-unknown-dialect-spelling-is-refused-rather-than-taking-the-sqlite-branch
  "Every comparison in mnemosyne/query is against ONE dialect, so a spelling it does not
recognise used to take the non-Postgres branch everywhere at once. The vector-distance check
then told a caller on Postgres that `the postgres backend has no vector column type at all'.
That is how this was found.

WHAT THIS TEST NO LONGER CLAIMS (pre-publication issue 432, ADR-0003). It used to assert that the STRING
spelling of postgres is refused here and that the message names KEYWORD as the spelling this
module wants. That was pre-publication PR 431's fix -- correct while there were two vocabularies, because
quietly normalising would have hidden the inconsistency instead of naming it. ADR-0003
removed the inconsistency itself: there is now one Dialect type and every module normalises
its own designators through MNEMOSYNE/FIELD-SHELL:DIALECT-FOR, so the string spelling names
a dialect this module knows and compiling it is correct. The claim in this test's NAME is
untouched -- an UNKNOWN spelling is still refused rather than silently meaning SQLite -- and
that is the property that prevents the recurrence."
  (dolist (bad '(:postgers "postgers" "postgresql" "" 42))
    (signals fldsh:unknown-dialect (q:sql '(:select (:id) :from ("t")) :dialect bad)))
  (handler-case (progn (q:sql '(:select (:id) :from ("t")) :dialect "postgers")
                       (fail "an unknown dialect must be refused"))
    (fldsh:unknown-dialect (e)
      (is (search "postgers" (princ-to-string e)) "the message shows what arrived")
      (dolist (n fldsh:+dialect-names+)
        (is (search n (princ-to-string e))
            "and names ~A, so the reader learns the whole closed set rather than one module's half of it" n))))
  (is-true (q:sql '(:select (:id) :from ("t")) :dialect :postgres)
           "the control: the keyword spelling still compiles")
  (is-true (q:sql '(:select (:id) :from ("t")) :dialect "postgres")
           "and so does the spelling ddl and schema take -- that is ADR-0003"))

;;; --- ADR-0003 / pre-publication issue 432: query speaks the tree's dialect vocabulary ------------

(test query-accepts-the-other-modules-spelling-and-agrees-with-its-own
  "\"postgres\" and :postgres compile to the SAME SQL.

THE ORIGINAL FINDING, from the other side. Every comparison in mnemosyne/query was
`(eq (ctx-dialect ctx) :postgres)', so the string \"postgres\" -- which is what
mnemosyne/ddl and mnemosyne/schema both take -- took the non-Postgres branch EVERYWHERE at
once. Asserting a refusal is not enough here: a module can refuse the other spelling and
still disagree with the module that uses it. Identical output is the property."
  (dolist (form '((:select (:id) :from ("t") :where (:= :a 1))
                  (:insert-into :t :values ((:a 1 :b "x")))
                  (:update :t :set (:a 1) :where (:= :id 2))
                  (:delete-from :t :where (:= :id 3))))
    (dolist (pair '(("postgres" . :postgres) ("sqlite" . :sqlite) ("xtdb" . :xtdb)))
      (let ((by-string  (gen form :dialect (car pair)))
            (by-keyword (gen form :dialect (cdr pair))))
        (is (equal by-string by-keyword)
            "~S must compile the same for ~S and ~S" form (car pair) (cdr pair))))))

(test a-distance-operator-is-not-refused-on-postgres-however-it-is-spelled
  "The exact wrong answer pre-publication issue 432 was filed for, as a test.

The vector-distance check told a caller who was ON POSTGRES that \"the postgres backend has
no vector column type at all\" -- because they held the string spelling. Not an error: a
wrong answer, delivered confidently, by a check whose logic was correct and whose input was
a spelling it did not recognise. Both directions: accepted on Postgres under either
spelling, still refused off Postgres under either."
  (let ((form (list :select '(:id) :from '("docs")
                    :order-by (list (list (list :<=> :embedding "[1,2,3]"))))))
    (let ((q:*warn-unindexed-vector-distance* nil))
      (dolist (d '(:postgres "postgres" "POSTGRES"))
        (is (search "<=>" (q:sql form :dialect d))
            "a distance query must compile on Postgres spelled ~S" d))
      (dolist (d '(:sqlite "sqlite" :xtdb "xtdb"))
        (signals error (q:sql form :dialect d))))))

(test query-refuses-a-spelling-it-does-not-recognise
  "ADR-0003's rule: refuse rather than treat as the other one. A typo is not SQLite."
  (dolist (bad '("postgers" "postgress" :postgers "" nil 42))
    (signals fldsh:unknown-dialect
      (q:sql '(:select (:id) :from ("t")) :dialect bad))))

(test the-xtdb-dml-guards-fire-under-either-spelling
  "ON CONFLICT / RETURNING are refused on XTDB whether it is spelled :xtdb or \"xtdb\".
A guard that only one of the two spellings can reach is not a guard."
  (dolist (d '(:xtdb "xtdb"))
    (signals error
      (q:sql '(:insert-into :t :values ((:_id 1)) :on-conflict (:_id) :do-nothing t) :dialect d))
    (signals error
      (q:sql '(:insert-into :t :values ((:_id 1)) :returning (:_id)) :dialect d))
    (is (search "INSERT INTO" (q:sql '(:insert-into :t :values ((:_id 1))) :dialect d)))))

;;; --- identifiers and directions are checked before they are written (#860) ----------
;;;
;;; An identifier or an ORDER BY direction is written into the SQL rather than bound, so
;;; text from a request in either place used to be SQL injection. These are the three forms
;;; measured on main 4336c6c, which rendered
;;;   ... ORDER BY name; DROP TABLE contacts; -- ASC
;;;   ... ORDER BY name ASC, (SELECT PASSWORD FROM USERS LIMIT 1)
;;;   SELECT id, password FROM contacts c JOIN users u ON true

(test the-measured-injections-are-refused
  (signals q:invalid-identifier
    (q:sql '(:select (:id) :from (:contacts) :order-by (("name; DROP TABLE contacts; --" :asc)))))
  (signals q:invalid-identifier
    (q:sql '(:select (:id) :from (:contacts)
             :order-by ((:name "asc, (SELECT password FROM users LIMIT 1)")))))
  (signals q:invalid-identifier
    (q:sql '(:select ("id, password") :from ("contacts c JOIN users u ON true"))))
  (signals q:invalid-identifier
    (q:sql '(:select (:id) :from ("contacts c JOIN users u ON true")))))

(test unsafe-names-are-refused-wherever-a-name-is-written
  (dolist (q '((:select (:id) :from ("contacts; drop table x"))
               (:select ((:as :id "x y")) :from (:t))
               (:select (:id) :from ((:as :t "t; --")))
               (:select (:id) :from (:t) :join ((:inner "u ON 1=1 --" (:= :t.id :u.id))))
               (:select (:id) :from (:t) :group-by ("a, b"))
               (:select (:id) :from (:t) :order-by ("1; drop"))
               (:select ((:call "lower(x)--" :y)) :from (:t))
               (:insert-into "t (a) VALUES (1); --" :values ((:a 1)))
               (:insert-into :t :values (("a) VALUES (1); --" 1)))
               (:update "t SET a = 1 --" :set (:a 2))
               (:delete-from "t; --")
               (:insert-into :t :values ((:a 1)) :returning ("a, (select 1)"))
               (:select (:id) :from (:t) :order-by (""))
               (:select (:id) :from (:t) :order-by ("1abc"))
               (:select (:id) :from (:t) :order-by ("a..b"))
               (:select (:id) :from (:t) :order-by ("caf\é"))))
    (signals q:invalid-identifier (q:sql q) "~S" q)))

(test a-direction-must-be-asc-or-desc
  (dolist (dir '(:up "sideways" "desc; drop table t" "ASC NULLS LAST" 1))
    (signals q:invalid-identifier (q:sql `(:select (:id) :from (:t) :order-by ((:id ,dir))))
      "~S" dir)
    (signals q:invalid-identifier
      (q:sql `(:select (:id) :from (:t) :order-by (((:lower :name) ,dir))))
      "expression form ~S" dir))
  (dolist (dir '(:asc :desc "asc" "DESC" "Desc"))
    (is (search (string-upcase (string dir))
                (q:sql `(:select (:id) :from (:t) :order-by ((:id ,dir))))))))

(test safe-names-still-render-as-before
  "The control: every form the tree uses still renders, unchanged."
  (is (string= "SELECT u.email, u.* FROM public.users AS u ORDER BY u.email DESC, 2 ASC, _id"
               (q:sql '(:select (:u.email "u.*") :from ((:as "public.users" :u))
                        :order-by ((:u.email :desc) (2 :asc) :_id)))))
  (is (string= "SELECT * FROM contacts" (q:sql '(:select (:*) :from ("contacts")))))
  (is (string= "SELECT LOWER(name) AS n FROM t GROUP BY Name_2"
               (q:sql '(:select ((:as (:lower :name) :n)) :from (:t) :group-by ("Name_2")))))
  (is (string= "SELECT count(*) AS n FROM t"
               (q:sql '(:select ((:as (:raw "count(*)") :n)) :from (:t))))
      "(:raw ...) is still the explicit way to write SQL text"))

(test a-refused-query-never-reaches-the-connection
  (let ((c (conn:connect (be:make-sqlite ":memory:"))))
    (unwind-protect
         (progn
           (conn:exec c "CREATE TABLE contacts (id INTEGER, name TEXT)")
           (signals q:invalid-identifier
             (q:fetch c '(:select (:id) :from (:contacts)
                          :order-by (("name; DROP TABLE contacts; --" :asc)))
                      :dialect :sqlite))
           (is (equal '(0) (mapcar #'second (conn:query c "SELECT count(*) FROM contacts")))
               "the table is still there"))
      (conn:disconnect c))))

(test the-condition-names-the-text-and-what-was-expected
  (let ((e (handler-case (q:sql '(:select (:id) :from ("a b"))) (q:invalid-identifier (e) e))))
    (is (equal "a b" (q:invalid-identifier-text e)))
    (is (search "identifier" (q:invalid-identifier-expected e)))
    (is (search "(:raw" (princ-to-string e)))))

;;; --- expressions where a name or an expression may stand, :quoted, and the clause (#860) ---

(test raw-and-expressions-work-in-group-by-on-conflict-and-returning
  (is (string= "SELECT count(*) FROM t GROUP BY date_trunc('day', at)"
               (q:sql '(:select ((:raw "count(*)")) :from (:t)
                        :group-by ((:raw "date_trunc('day', at)"))))))
  (is (string= "SELECT n FROM t GROUP BY LOWER(name)"
               (q:sql '(:select (:n) :from (:t) :group-by ((:lower :name))))))
  (is (string= "INSERT INTO t (email) VALUES (?) ON CONFLICT (lower(email)) DO NOTHING"
               (q:sql '(:insert-into :t :values ((:email "a@x"))
                        :on-conflict ((:raw "lower(email)")) :do-nothing t))))
  (is (string= "INSERT INTO t (a) VALUES (?) RETURNING id, now() AS at"
               (q:sql '(:insert-into :t :values ((:a 1)) :returning (:id (:raw "now() AS at")))))))

(test a-quoted-name-is-double-quoted-with-its-quotes-doubled
  (is (string= "SELECT \"Name\" FROM \"public\".\"MyTable\" ORDER BY \"Name\" DESC"
               (q:sql '(:select ((:quoted "Name")) :from ((:quoted "public" "MyTable"))
                        :order-by (((:quoted "Name") :desc))))))
  (is (string= "SELECT id FROM \"we\"\"ird\"" (q:sql '(:select (:id) :from ((:quoted "we\"ird"))))))
  (is (string= "SELECT id FROM \"order\" AS o" (q:sql '(:select (:id) :from ((:as (:quoted "order") :o))))))
  (dolist (bad '((:quoted) (:quoted "") (:quoted "a" 5)))
    (signals q:invalid-identifier (q:sql `(:select (:id) :from (,bad))) "~S" bad))
  (signals q:invalid-identifier
    (q:sql (list :select '(:id) :from (list (list :quoted (format nil "a~Cb" (code-char 0))))))))

(test names-quoted-by-hand-and-other-unsafe-names-are-refused
  (dolist (q '((:select (:id) :from ("\"MyTable\""))
               (:select (:id) :from ("a$b"))
               (:select (:|a b|) :from (:t))
               (:insert-into :t :values ((:a 1)) :on-conflict ("a) DO NOTHING; --") :do-nothing t)
               (:insert-into :t :values ((:a 1)) :on-conflict (:a) :do-update (("b = 1, c" 2)))
               (:insert-into :t :values ((:a 1)) :on-conflict (:a) :do-update (:b (:excluded "b; --")))))
    (signals q:invalid-identifier (q:sql q) "~S" q)))

(test an-integer-is-accepted-only-where-sql-gives-it-a-meaning
  "A positive ORDER BY or GROUP BY position, and a non-negative SELECT constant such as the 1 in
EXISTS (SELECT 1 ...)."
  (is (string= "SELECT a FROM t GROUP BY 1 ORDER BY 2 DESC, 1"
               (q:sql '(:select (:a) :from (:t) :group-by (1) :order-by ((2 :desc) 1)))))
  (is (string= "SELECT 1 FROM t" (q:sql '(:select (1) :from (:t)))))
  (dolist (pos '(0 -1 1.5))
    (signals q:invalid-identifier (q:sql `(:select (:a) :from (:t) :order-by (,pos))) "~S" pos)
    (signals q:invalid-identifier (q:sql `(:select (:a) :from (:t) :group-by (,pos))) "~S" pos))
  (dolist (q '((:select (-1) :from (:t)) (:select (:a) :from (1))
               (:insert-into :t :values ((:a 1)) :returning (1)) (:delete-from 1)))
    (signals q:invalid-identifier (q:sql q) "~S" q)))

(test the-condition-names-the-clause
  (flet ((clause-of (q) (handler-case (progn (q:sql q) :no-error)
                          (q:invalid-identifier (e) (q:invalid-identifier-clause e)))))
    (is (eq :order-by (clause-of '(:select (:id) :from (:t) :order-by ("a b")))))
    (is (eq :order-by (clause-of '(:select (:id) :from (:t) :order-by ((:id :up))))))
    (is (eq :from (clause-of '(:select (:id) :from ("a b")))))
    (is (eq :group-by (clause-of '(:select (:id) :from (:t) :group-by ("a b")))))
    (is (eq :returning (clause-of '(:delete-from :t :returning ("a b")))))
    (is (search "in order-by" (handler-case (q:sql '(:select (:id) :from (:t) :order-by ("a b")))
                                (q:invalid-identifier (e) (princ-to-string e)))))))

;;; --- LIKE with ESCAPE (#862) -------------------------------------------------------

(test like-and-ilike-render-an-escape-character
  (is (equal '("SELECT id FROM t WHERE name LIKE ? ESCAPE ?" ("%a\\%b%" "\\"))
             (gen '(:select (:id) :from (:t) :where (:like :name "%a\\%b%" :escape "\\")))))
  (is (equal '("SELECT id FROM t WHERE name ILIKE ? ESCAPE ?" ("%a!%%" "!"))
             (gen '(:select (:id) :from (:t) :where (:ilike :name "%a!%%" :escape #\!))
                  :dialect :postgres)))
  (is (equal '("SELECT id FROM t WHERE name LIKE ?" ("%a%"))
             (gen '(:select (:id) :from (:t) :where (:like :name "%a%"))))
      "control: without :escape, nothing is added"))

(test an-escape-that-is-not-one-safe-character-is-refused
  "% or _ as the escape would make the escape character a wildcard: like-contains of \"ab\"
with :escape #\\% gave \"%ab%\", which Postgres refuses and SQLite does not match."
  (dolist (escape (list "" "ab" "%" #\% "_" #\_ 5 (code-char 0) (string (code-char 7))))
    (signals q:invalid-identifier
      (q:sql `(:select (:id) :from (:t) :where (:like :name "%a%" :escape ,escape)))
      "~S" escape)
    (signals q:invalid-identifier (q:like-contains "ab" :escape escape) "like-contains ~S" escape))
  ;; Bound, so a quote or a non-ASCII escape character needs no quoting and is accepted.
  (dolist (escape (list "'" "é" #\!))
    (finishes (q:sql `(:select (:id) :from (:t) :where (:like :name "%a%" :escape ,escape))))))

(test like-with-escape-round-trips
  (is (rt '(:select (:id) :from (:t) :where (:like :name "%a\\%b%" :escape "\\"))))
  (is (rt '(:select (:id) :from (:t) :where (:and (:like :name "x%" :escape "!") (:= :id 1))))))

(test like-escape-and-like-contains-escape-the-wildcards-and-the-escape
  (is (string= "50\\%\\_off\\\\x" (q:like-escape "50%_off\\x")))
  (is (string= "%50!%!_off!!%" (q:like-contains "50%_off!" :escape #\!)))
  (is (string= "%plain%" (q:like-contains "plain")))
  (is (string= "%%" (q:like-contains ""))))
