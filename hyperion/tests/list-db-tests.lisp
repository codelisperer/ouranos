;;;; list-db-tests.lisp --- FETCH-PAGE on SQLite and Postgres (#488).
;;;;
;;;; Every test runs on an in-memory SQLite database, and again on Postgres when
;;;; MNEMOSYNE_TEST_PG_URL is set. RUN-TESTS prints the Postgres coverage in the form
;;;; scripts/verify-tree.lisp reads, so a run without Postgres says so instead of reading as a
;;;; pass.

(cl:defpackage #:hyperion/list-db/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:list #:hyperion/list)
                    (#:ldb #:hyperion/list-db)
                    (#:query #:mnemosyne/query)
                    (#:conn #:mnemosyne/conn)
                    (#:be #:mnemosyne/backend)
                    (#:url #:mnemosyne/url))
  (:export #:run-tests))

(in-package #:hyperion/list-db/tests)

(def-suite list-db :description "hyperion/list-db on SQLite.")
(def-suite list-db-postgres :description "The same checks on Postgres.")

(defun %pg-url () (uiop:getenv "MNEMOSYNE_TEST_PG_URL"))

(defun run-tests ()
  "Run the SQLite and Postgres suites and print the Postgres coverage in the form
scripts/verify-tree.lisp reads."
  (let* ((sqlite (run 'list-db))
         (postgres (run 'list-db-postgres))
         (all (append sqlite postgres)))
    (explain! all)
    (if (%pg-url)
        (format t "~&BACKEND-CHECKS postgres ~D~%"
                (count-if-not (lambda (r) (typep r 'fiveam::test-skipped)) postgres))
        (format t "~&BACKEND-CHECKS postgres SKIPPED (MNEMOSYNE_TEST_PG_URL is not set)~%"))
    (finish-output)
    (results-status all)))

;;; Seven contacts. Status has ties on purpose, so paging by status needs the tiebreak.
(defparameter *rows*
  '((:id 1 :name "Ada"   :status "open"   :created 10)
    (:id 2 :name "Bob"   :status "closed" :created 20)
    (:id 3 :name "Cy"    :status "open"   :created 30)
    (:id 4 :name "Dee"   :status "open"   :created 40)
    (:id 5 :name "Eve"   :status "closed" :created 50)
    (:id 6 :name "Fay"   :status "open"   :created 60)
    (:id 7 :name "Gus"   :status "open"   :created 70)))

(defparameter *spec*
  (list:make-list-spec
   :id "contacts"
   :sorts '((:name :column :name) (:added :column :created :direction :desc)
            (:status :column :status))
   :default-sort :added
   :tiebreak :id
   :filters '((:status :values ("open" "closed") :column :status) (:q :text t :max-length 20))
   :page-size 3 :page-sizes '(3 5)))

(defun %env (query) (list :path-info "/contacts" :query-string query))

(defun %state (query) (list:read-list-state *spec* (%env query)))

(defun %table ()
  (format nil "hyperion_list_test_~36R" (random (expt 2 40) (make-random-state t))))

(defun %fill (c table dialect)
  (conn:exec c (format nil "CREATE TABLE ~A (id INTEGER PRIMARY KEY, name TEXT, status TEXT, created INTEGER)" table))
  (query:run c (list :insert-into table :values *rows*) :dialect dialect))

(defun call-with-sqlite (function)
  (let ((c (conn:connect (be:make-sqlite ":memory:"))))
    (unwind-protect (progn (%fill c "contacts" :sqlite) (funcall function c "contacts" :sqlite))
      (conn:disconnect c))))

(defun call-with-postgres (function)
  (if (not (%pg-url))
      (skip "MNEMOSYNE_TEST_PG_URL is not set -- this says nothing about Postgres")
      (let ((c (conn:connect (url:backend-from-url (%pg-url))))
            (table (%table)))
        (unwind-protect (progn (%fill c table :postgres) (funcall function c table :postgres))
          (ignore-errors (conn:exec c (format nil "DROP TABLE IF EXISTS ~A" table)))
          (conn:disconnect c)))))

(defmacro backend-test (name (c table dialect) &body body)
  "Define NAME/SQLITE in LIST-DB and NAME/POSTGRES in LIST-DB-POSTGRES, each running BODY with C
a connection holding *ROWS* in TABLE, and DIALECT the backend's dialect."
  (let ((doc (and (stringp (first body)) (rest body) (list (first body))))
        (body (if (and (stringp (first body)) (rest body)) (rest body) body)))
    `(progn
       (test (,(intern (format nil "~A/SQLITE" name)) :suite list-db)
         ,@doc (call-with-sqlite (lambda (,c ,table ,dialect) ,@body)))
       (test (,(intern (format nil "~A/POSTGRES" name)) :suite list-db-postgres)
         ,@doc (call-with-postgres (lambda (,c ,table ,dialect) ,@body))))))

(defun %ids (rows)
  "The id of each row. Every test selects the id alone, and it is read by position because the
backends key a column differently (SQLite returns :|id|)."
  (mapcar #'second rows))

(backend-test a-page-holds-its-rows-in-order-with-the-total (c table dialect)
  (multiple-value-bind (rows total state)
      (ldb:fetch-page c (%state "page=2") :select '(:id) :from (list table) :dialect dialect)
    (is (= 7 total))
    (is (= 2 (list:list-state-page state)))
    ;; Default sort: :added, newest first.
    (is (equal '(4 3 2) (%ids rows)))))

(backend-test a-page-past-the-end-gives-the-last-page (c table dialect)
  (multiple-value-bind (rows total state)
      (ldb:fetch-page c (%state "page=9") :select '(:id) :from (list table) :dialect dialect)
    (is (= 7 total))
    (is (= 3 (list:list-state-page state)))
    (is (equal '(1) (%ids rows)))))

(backend-test paging-a-sort-with-ties-shows-every-row-once (c table dialect)
  "Five rows share status open. The tiebreak on id keeps one order across pages, so the three
pages together hold each row exactly once."
  (let ((ids (loop for page from 1 to 3
                   append (%ids (ldb:fetch-page c (%state (format nil "sort=status&page=~D" page))
                                                :select '(:id) :from (list table)
                                                :dialect dialect)))))
    (is (equal '(2 5 1 3 4 6 7) ids) "~S" ids)))

(backend-test a-filter-is-a-bound-value (c table dialect)
  (let ((state (%state "status=closed")))
    (multiple-value-bind (rows total)
        (ldb:fetch-page c state :select '(:id) :from (list table) :where (list:filter-where state)
                        :dialect dialect)
      (is (= 2 total))
      (is (equal '(5 2) (%ids rows)))))
  ;; A text filter the app turns into WHERE: SQL in it is matched as text, not run.
  (let ((state (%state "q=x%27%20OR%20%271%27%3D%271")))
    (is (equal "x' OR '1'='1" (list:filter-value state :q)))
    (multiple-value-bind (rows total)
        (ldb:fetch-page c state :select '(:id) :from (list table)
                        :where (list := :name (list:filter-value state :q)) :dialect dialect)
      (is (= 0 total))
      (is (null rows)))))

(backend-test an-empty-list-has-no-rows-and-page-one (c table dialect)
  (multiple-value-bind (rows total state)
      (ldb:fetch-page c (%state "page=4") :select '(:id) :from (list table)
                      :where '(:= :status "nobody") :dialect dialect)
    (is (= 0 total))
    (is (null rows))
    (is (= 1 (list:list-state-page state)))))
