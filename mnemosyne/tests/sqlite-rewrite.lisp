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

(test a-rewrite-that-fails-part-way-leaves-the-table-as-it-was
  "An error from the function after some rows were rewritten rolls the whole run back: every value
is text again, so a store whose readers accept the old form still opens, and the next run starts
again."
  (%call-with-rewrite-db (%rewrite-rows 6)
    (lambda (c)
      (let ((calls 0))
        (signals error
          (mig:rewrite-sqlite-text-values c "rw_t" "k" "v"
                                          (lambda (text)
                                            (when (> (incf calls) 3) (error "stopped part-way"))
                                            (%octets-of text))
                                          :batch-size 2))
        (is (= 4 calls) "three rows were rewritten before the error"))
      (is (every (lambda (ty) (string= ty "text")) (%typeofs c)) "rolled back: ~S" (%typeofs c))
      (is (equal '(6 0) (multiple-value-list
                         (mig:rewrite-sqlite-text-values c "rw_t" "k" "v" (lambda (text) (%octets-of text)))))))))
