;;;; tests/jet.lisp --- the Jet (Microsoft Access) dialect of mnemosyne/query (#1061).
;;;;
;;;; Rendering only: mnemosyne has no backend that runs Jet SQL, so every test here compiles a
;;;; query and reads the string and the param list. One test per difference listed in the
;;;; header of src/query.lisp, plus the DDL refusals.

(in-package #:mnemosyne/tests)

(in-suite mnemosyne)

(defun jet (q) (gen q :dialect :jet))

(test jet-is-a-dialect-under-every-spelling
  (dolist (d '(:jet "jet" "JET"))
    (is (eq fld:D-Jet (fldsh:dialect-for d))))
  (is (string= "jet" (fld:dialect-name fld:D-Jet))))

(test jet-writes-the-row-limit-as-a-top-prefix
  (is (equal (list "SELECT TOP 200 [a] FROM [t] ORDER BY [a] DESC" '())
             (jet '(:select (:a) :from (:t) :order-by ((:a :desc)) :limit 200))))
  (is (equal (list "SELECT [a] FROM [t] WHERE [a] IN (SELECT TOP 5 [b] FROM [u])" '())
             (jet '(:select (:a) :from (:t) :where (:in :a (:select (:b) :from (:u) :limit 5)))))
      "a subquery gets its own TOP")
  (dolist (bad '(0 -1 2.5 "10"))
    (signals error (jet `(:select (:a) :from (:t) :limit ,bad))))
  (is (equal (list "SELECT a FROM t LIMIT ?" '(200))
             (gen '(:select (:a) :from (:t) :limit 200) :dialect :sqlite))
      "the control: SQLite still binds a trailing LIMIT"))

(test jet-refuses-offset-when-the-query-is-compiled
  (dolist (q '((:select (:a) :from (:t) :limit 10 :offset 20)
               (:select (:a) :from (:t) :where (:exists (:select (:b) :from (:u) :offset 1)))))
    (handler-case (progn (jet q) (fail "~S must signal UNSUPPORTED-QUERY" q))
      (q:unsupported-query (c)
        (is (string= "jet" (q:unsupported-query-dialect c)))
        (is (string= "OFFSET" (q:unsupported-query-clause c)))
        (is (search "jet dialect has no OFFSET" (princ-to-string c))))))
  (is (search "OFFSET ?" (first (gen '(:select (:a) :from (:t) :offset 20) :dialect :sqlite)))
      "the control: SQLite still renders OFFSET"))

(test jet-writes-names-in-brackets
  (is (equal (list (concatenate 'string
                     "SELECT [First Name], [c].[email], [c].*, [o].[total] AS [amount]"
                     " FROM [Client Data] AS [c] INNER JOIN [orders] AS [o] ON [c].[id] = [o].[cid]"
                     " WHERE nz([o].[total], ?) > ?")
                   '(0 10))
             (jet '(:select ((:quoted "First Name") :c.email :c.* (:as :o.total :amount))
                    :from ((:as (:quoted "Client Data") :c))
                    :join ((:inner (:as :orders :o) (:= :c.id :o.cid)))
                    :where (:> (:call :nz :o.total 0) 10)))))
  (dolist (bad '("a]b" "a[b" "a.b" "a!b" "a`b" " lead" ""))
    (signals q:invalid-identifier (jet `(:select ((:quoted ,bad)) :from (:t)))))
  (signals q:invalid-identifier (jet '(:select (:a) :from ("t; DROP TABLE x")))
           "the #860 check still runs before the brackets go on")
  (is (equal (list "SELECT \"First Name\" FROM t" '())
             (gen '(:select ((:quoted "First Name")) :from (:t)) :dialect :sqlite))
      "the control: SQLite still double-quotes"))

(test jet-writes-dates-and-timestamps-as-hash-literals
  (is (equal (list "SELECT [a] FROM [t] WHERE ([d] >= #2026-09-14# AND [s] < #2026-09-14 08:05:03#)"
                   '())
             (jet '(:select (:a) :from (:t)
                    :where (:and (:>= :d (:date 2026 9 14))
                                 (:< :s (:timestamp 2026 9 14 8 5 3)))))))
  (is (equal (list "SELECT a FROM t WHERE (d >= ? AND s < ?)" '("2026-09-14" "2026-09-14 08:05:03"))
             (gen '(:select (:a) :from (:t)
                    :where (:and (:>= :d (:date 2026 9 14))
                                 (:< :s (:timestamp 2026 9 14 8 5 3))))
                  :dialect :sqlite))
      "the control: elsewhere the ISO text is bound")
  (dolist (bad '((:date 2026 2 29) (:date 2024 13 1) (:date 99 1 1) (:date 2026 9 14 1)
                 (:date "2026" 9 14) (:timestamp 2026 9 14 24 0 0) (:timestamp 2026 9 14 8 60 0)))
    (signals error (jet `(:select (:a) :from (:t) :where (:= :d ,bad)))))
  (is (search "#2024-02-29#" (first (jet '(:select (:a) :from (:t) :where (:= :d (:date 2024 2 29))))))
      "a leap day is accepted"))

(test jet-binds-values-as-question-marks-in-placeholder-order
  "ADO binds by position, so the param list must be in the order the ? marks appear."
  (destructuring-bind (sql params)
      (jet '(:select ((:as 7 :k) :a) :from ((:as :t :x))
             :join ((:left (:as :u :y) (:and (:= :x.id :y.tid) (:= :y.kind "x"))))
             :where (:and (:in :x.n (1 2 3)) (:like :x.name "a%"))
             :group-by (:a) :having (:> (:count :*) 10) :limit 3))
    (is (string= (concatenate 'string
                   "SELECT TOP 3 ? AS [k], [a] FROM [t] AS [x]"
                   " LEFT JOIN [u] AS [y] ON ([x].[id] = [y].[tid] AND [y].[kind] = ?)"
                   " WHERE ([x].[n] IN (?, ?, ?) AND [x].[name] LIKE ?)"
                   " GROUP BY [a] HAVING COUNT(*) > ?")
                 sql))
    (is (equal '(7 "x" 1 2 3 "a%" 10) params))
    (is (= (length params) (count #\? sql)))))

(test jet-gives-an-unaliased-aggregate-an-alias
  (is (equal (list (concatenate 'string
                     "SELECT COUNT(*) AS [count], SUM([o].[total]) AS [sum_total],"
                     " AVG([x]) AS [n], COUNT(*) AS [count_2], [k] FROM [o]")
                   '())
             (jet '(:select ((:count :*) (:sum :o.total) (:as (:avg :x) :n) (:count :*) :k)
                    :from (:o)))))
  (is (equal (list "SELECT MAX([x]) AS [max_x_2], [y] AS [max_x] FROM [t]" '())
             (jet '(:select ((:max :x) (:as :y :max_x)) :from (:t))))
      "an explicit alias later in the list is not reused")
  (is (equal (list "SELECT COUNT(*) FROM o" '())
             (gen '(:select ((:count :*)) :from (:o)) :dialect :sqlite))
      "the control: SQLite gets no alias"))

(test jet-has-no-ddl
  (signals ddl:unsupported-ddl
    (ddl:ddl '(:create-index :name :idx :on :t :columns (:a)) :dialect :jet))
  (signals ddl:unsupported-ddl
    (ddl:ddl-statements '(:alter-table :t (:add-column :a :string)) :dialect "jet"))
  (signals error (sch:schema-ddl (sch:find-schema 'test-user) :dialect :jet)))

(test jet-date-forms-work-wherever-a-value-is-bound
  "BETWEEN, an IN list, INSERT and UPDATE bind values without going through the expression
compiler, so each has to recognise the date forms itself (review of #1064)."
  (is (equal (list (concatenate 'string
                     "SELECT [a] FROM [t] WHERE ([d] BETWEEN #2026-09-01# AND #2026-09-30#"
                     " AND [s] IN (#2026-09-14 08:00:00#, ?))")
                   '("x"))
             (jet '(:select (:a) :from (:t)
                    :where (:and (:between :d (:date 2026 9 1) (:date 2026 9 30))
                                 (:in :s ((:timestamp 2026 9 14 8 0 0) "x")))))))
  (is (equal (list "INSERT INTO [t] ([d], [n]) VALUES (#2026-09-14#, ?)" '(1))
             (jet '(:insert-into :t :values ((:d (:date 2026 9 14) :n 1))))))
  (is (equal (list "UPDATE [t] SET [d] = #2026-09-14# WHERE [id] = ?" '(2))
             (jet '(:update :t :set (:d (:date 2026 9 14)) :where (:= :id 2)))))
  (is (equal (list "SELECT a FROM t WHERE d BETWEEN ? AND ?" '("2026-09-01" "2026-09-30"))
             (gen '(:select (:a) :from (:t) :where (:between :d (:date 2026 9 1) (:date 2026 9 30)))
                  :dialect :sqlite))
      "the control: SQLite binds the ISO text"))

(test jet-aggregate-aliases-avoid-the-names-of-other-columns
  (is (equal (list "SELECT [t].[count], COUNT(*) AS [count_2] FROM [t] GROUP BY [t].[count]" '())
             (jet '(:select (:t.count (:count :*)) :from (:t) :group-by (:t.count))))
      "a plain column named count is not given a twin")
  (is (equal (list (concatenate 'string
                     "SELECT [a] AS [Count], [Sum], COUNT(*) AS [count_2], SUM([x]) AS [sum_x]"
                     " FROM [t]")
                   '())
             (jet '(:select ((:as :a (:quoted "Count")) (:quoted "Sum") (:count :*) (:sum :x))
                    :from (:t))))
      "quoted names and quoted aliases are reserved, case-insensitively, and do not crash")
  (is (equal (list "SELECT [a] AS [Total Amount] FROM [t]" '())
             (jet '(:select ((:as :a (:quoted "Total Amount"))) :from (:t))))))

(test jet-nests-more-than-one-join-in-parentheses
  (is (equal (list (concatenate 'string
                     "SELECT [a].[x] FROM (([a] INNER JOIN [b] ON [a].[id] = [b].[aid])"
                     " LEFT JOIN [c] ON [b].[id] = ?) INNER JOIN [d] ON [d].[n] = ?")
                   '(1 2))
             (jet '(:select (:a.x) :from (:a)
                    :join ((:inner :b (:= :a.id :b.aid)) (:left :c (:= :b.id 1))
                           (:inner :d (:= :d.n 2)))))))
  (is (equal (list "SELECT [x] FROM [a] INNER JOIN [b] ON [a].[id] = [b].[aid]" '())
             (jet '(:select (:x) :from (:a) :join ((:inner :b (:= :a.id :b.aid))))))
      "one join needs no parentheses")
  (dolist (q '((:select (:x) :from (:a) :join ((:full :b (:= :a.id :b.id))))
               (:select (:x) :from (:a) :join ((:cross :b)))
               (:select (:x) :from (:a :e) :join ((:inner :b (:= :a.id :b.id))
                                                   (:inner :c (:= :b.id :c.id))))))
    (signals q:unsupported-query (jet q)))
  (is (equal (list "SELECT x FROM a INNER JOIN b ON a.id = b.aid INNER JOIN c ON b.id = c.bid" '())
             (gen '(:select (:x) :from (:a) :join ((:inner :b (:= :a.id :b.aid))
                                                    (:inner :c (:= :b.id :c.bid))))
                  :dialect :sqlite))
      "the control: SQLite stays flat"))
