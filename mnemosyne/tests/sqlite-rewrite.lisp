;;;; sqlite-rewrite.lisp --- tests for MAP-QUERY and REWRITE-SQLITE-TEXT-VALUES (#425).

(in-package #:mnemosyne/tests)

(in-suite mnemosyne)

(defun %call-with-rewrite-db (rows function)
  "Open a fresh SQLite file with a table rw_t (k TEXT PRIMARY KEY, v TEXT) holding ROWS, a list
of (key . value), call FUNCTION with the connection, then close it and delete the file."
  (let* ((path (merge-pathnames (format nil "mnemosyne-rewrite-~36R.sqlite"
                                        (random (expt 2 40) (make-random-state t)))
                                (uiop:temporary-directory)))
         (c (conn:connect (be:make-sqlite (namestring path)))))
    (unwind-protect
         (progn
           (conn:exec c "CREATE TABLE rw_t (k TEXT PRIMARY KEY, v TEXT)")
           (dolist (row rows)
             (conn:exec c "INSERT INTO rw_t (k, v) VALUES (?, ?)" (car row) (cdr row)))
           (funcall function c))
      (conn:disconnect c)
      (ignore-errors (delete-file path)))))

(defun %rewrite-rows (n)
  (loop for i below n collect (cons (format nil "k~2,'0D" i) (format nil "~D" i))))

(defun %typeofs (c)
  (mapcar (lambda (row) (getf row :|t|))
          (conn:query c "SELECT typeof(v) AS t FROM rw_t ORDER BY k")))

(defun %octets-of (text)
  (map '(simple-array (unsigned-byte 8) (*)) #'char-code text))

(test map-query-calls-the-function-on-every-row-in-order
  "MAP-QUERY gives FUNCTION the rows QUERY would return, in the same order, and returns how many."
  (%call-with-rewrite-db (%rewrite-rows 7)
    (lambda (c)
      (let ((seen '()))
        (is (= 7 (conn:map-query c (lambda (row) (push row seen)) "SELECT k, v FROM rw_t ORDER BY k")))
        (is (equal (conn:query c "SELECT k, v FROM rw_t ORDER BY k") (nreverse seen))))
      (is (= 0 (conn:map-query c (lambda (row) (declare (ignore row)) (error "not called"))
                               "SELECT k FROM rw_t WHERE k = ?" "absent"))
          "no rows, no call"))))

(test map-fetch-runs-a-query-as-data
  (%call-with-rewrite-db (%rewrite-rows 3)
    (lambda (c)
      (let ((keys '()))
        (is (= 2 (q:map-fetch c (lambda (row) (push (getf row :|k|) keys))
                              '(:select (:k) :from (:rw_t) :where (:> :k "k00") :order-by (:k))
                              :dialect :sqlite)))
        (is (equal '("k01" "k02") (nreverse keys)))))))

(test rewrite-sqlite-text-values-rewrites-only-text-and-pages-through-the-table
  "Ten text rows with a batch size of 3: every row the function converts becomes a BLOB, a row it
returns NIL for is left as text, and the counts say so. A second run has nothing to do."
  (%call-with-rewrite-db (%rewrite-rows 10)
    (lambda (c)
      (multiple-value-bind (rewritten left)
          (mig:rewrite-sqlite-text-values c "rw_t" "k" "v"
                                          (lambda (text) (unless (string= text "4") (%octets-of text)))
                                          :batch-size 3)
        (is (= 9 rewritten))
        (is (= 1 left)))
      (is (equal '("blob" "blob" "blob" "blob" "text" "blob" "blob" "blob" "blob" "blob") (%typeofs c)))
      (is (equalp (%octets-of "7") (getf (first (conn:query c "SELECT v FROM rw_t WHERE k = 'k07'")) :|v|)))
      (multiple-value-bind (rewritten left)
          (mig:rewrite-sqlite-text-values c "rw_t" "k" "v" (lambda (text) (%octets-of text)) :batch-size 3)
        (is (= 1 rewritten) "only the row left as text is read again")
        (is (= 0 left)))
      (is (equal '(0 0) (multiple-value-list
                         (mig:rewrite-sqlite-text-values c "rw_t" "k" "v" (lambda (text) (%octets-of text)))))
          "a third run finds nothing to do"))))

(test map-query-reads-rows-as-it-goes-on-sqlite
  "MAP-QUERY calls FUNCTION on a row before it reads the next, on SQLite (#425's review). Each row's
V2 comes from a correlated subquery on rw_side, which SQLite evaluates as it steps to that row.
The function, on the first row, changes rw_side on the same connection. Read as it goes, every
later row shows the change. Read all at once before the first call, as cl-dbi's SQLite driver does
unless the query is prepared with :STORE NIL, none would."
  (%call-with-rewrite-db (%rewrite-rows 5)
    (lambda (c)
      (conn:exec c "CREATE TABLE rw_side (k TEXT PRIMARY KEY, v TEXT)")
      (conn:exec c "INSERT INTO rw_side (k, v) SELECT k, 'before' FROM rw_t")
      (let ((seen '()))
        (conn:map-query c (lambda (row)
                            (when (null seen) (conn:exec c "UPDATE rw_side SET v = 'after'"))
                            (push (getf row :|v2|) seen))
                        "SELECT k, (SELECT v FROM rw_side WHERE rw_side.k = rw_t.k) AS v2 FROM rw_t ORDER BY k")
        (let ((got (reverse seen)))
          (is (equal '("before" "after" "after" "after" "after") got)
              "rows read after the first call must see its change: ~S" got))))))

(test a-rewrite-that-fails-part-way-keeps-the-batches-before-it
  "Each batch is its own transaction (#425's review). An error from the function in the second
batch rolls that batch back and keeps the first: the table is then partly BLOB and partly text,
which a store's readers accept, and the next run rewrites only what is still text."
  (%call-with-rewrite-db (%rewrite-rows 6)
    (lambda (c)
      (let ((calls 0))
        (signals error
          (mig:rewrite-sqlite-text-values c "rw_t" "k" "v"
                                          (lambda (text)
                                            (when (> (incf calls) 3) (error "stopped part-way"))
                                            (%octets-of text))
                                          :batch-size 2))
        (is (= 4 calls) "the error came on the second row of the second batch"))
      (is (equal '("blob" "blob" "text" "text" "text" "text") (%typeofs c))
          "the first batch is kept and the second rolled back: ~S" (%typeofs c))
      (is (equal '(4 0) (multiple-value-list
                         (mig:rewrite-sqlite-text-values c "rw_t" "k" "v" (lambda (text) (%octets-of text)))))))))

(test a-rewrite-with-nothing-to-do-takes-no-write-lock
  "With no TEXT value left, the rewrite returns 0 and 0 after one SELECT, without beginning a
transaction. Shown by running it while another connection holds SQLite's write lock with a busy
timeout of 0: taking the lock would fail at once with BUSY. The control: with one TEXT value left,
the same call fails."
  (let* ((path (merge-pathnames (format nil "mnemosyne-rewrite-lock-~36R.sqlite"
                                        (random (expt 2 40) (make-random-state t)))
                                (uiop:temporary-directory)))
         (conn:*sqlite-busy-timeout-ms* 0)
         (a (conn:connect (be:make-sqlite (namestring path))))
         (b (conn:connect (be:make-sqlite (namestring path)))))
    (unwind-protect
         (progn
           (conn:exec a "CREATE TABLE rw_t (k TEXT PRIMARY KEY, v TEXT)")
           (conn:exec a "INSERT INTO rw_t (k, v) VALUES ('k00', x'01')")
           (conn:exec a "CREATE TABLE lock_t (x INTEGER)")
           (conn:exec a "BEGIN IMMEDIATE")
           (conn:exec a "INSERT INTO lock_t VALUES (1)")
           (is (equal '(0 0) (multiple-value-list
                              (mig:rewrite-sqlite-text-values b "rw_t" "k" "v" (lambda (text) (%octets-of text))))))
           (conn:exec a "COMMIT")
           (conn:exec a "INSERT INTO rw_t (k, v) VALUES ('k01', 'text')")
           (conn:exec a "BEGIN IMMEDIATE")
           (conn:exec a "INSERT INTO lock_t VALUES (2)")
           (signals error
             (mig:rewrite-sqlite-text-values b "rw_t" "k" "v" (lambda (text) (%octets-of text)))))
      (ignore-errors (conn:exec a "COMMIT"))
      (conn:disconnect a)
      (conn:disconnect b)
      (ignore-errors (delete-file path)))))
