;;;; results-db-tests.lisp --- the database result store on SQLite and Postgres (#319).
;;;;
;;;; Every test runs on an in-memory SQLite database, and again on Postgres when
;;;; MNEMOSYNE_TEST_PG_URL is set. RUN-TESTS prints the Postgres coverage in the form
;;;; scripts/verify-tree.lisp reads, so a run without Postgres says so instead of reading as a
;;;; pass.

(cl:defpackage #:praxeon/results-db/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:rdb #:praxeon/results-db)
                    (#:res #:praxeon/results)
                    (#:actor #:praxeon/actor)
                    (#:llm #:praxeon/llm)
                    (#:conn #:mnemosyne/conn)
                    (#:be #:mnemosyne/backend)
                    (#:url #:mnemosyne/url))
  (:export #:run-tests))

(in-package #:praxeon/results-db/tests)

(def-suite results-db :description "Tool results kept in a database (#319).")
(def-suite results-db-postgres :description "The same checks on Postgres.")
(in-suite results-db)

(defun %pg-url () (uiop:getenv "MNEMOSYNE_TEST_PG_URL"))

(defun run-tests ()
  "Run the SQLite and Postgres suites and print the Postgres coverage in the form
scripts/verify-tree.lisp reads."
  (let* ((sqlite (run 'results-db))
         (postgres (run 'results-db-postgres))
         (all (append sqlite postgres)))
    (explain! all)
    (if (%pg-url)
        (format t "~&BACKEND-CHECKS postgres ~D~%"
                (count-if-not (lambda (r) (typep r 'fiveam::test-skipped)) postgres))
        (format t "~&BACKEND-CHECKS postgres SKIPPED (MNEMOSYNE_TEST_PG_URL is not set)~%"))
    (finish-output)
    (results-status all)))

(defun %table ()
  (format nil "praxeon_tool_results_~36R" (random (expt 2 40) (make-random-state t))))

(defun call-with-sqlite-store (function)
  (let ((c (conn:connect (be:make-sqlite ":memory:"))))
    (unwind-protect (funcall function (rdb:make-db-result-store c :ensure t))
      (conn:disconnect c))))

(defun call-with-postgres-store (function)
  (if (not (%pg-url))
      (skip "MNEMOSYNE_TEST_PG_URL is not set -- this says nothing about Postgres")
      (let ((c (conn:connect (url:backend-from-url (%pg-url))))
            (table (%table)))
        (unwind-protect (funcall function (rdb:make-db-result-store c :table table :ensure t))
          (ignore-errors (conn:exec c (format nil "DROP TABLE IF EXISTS ~A" table)))
          (conn:disconnect c)))))

(defmacro backend-test (name (store) &body body)
  "Define NAME/SQLITE in RESULTS-DB and NAME/POSTGRES in RESULTS-DB-POSTGRES, each running BODY
with STORE bound to a fresh store on that backend."
  (let ((doc (and (stringp (first body)) (rest body) (list (first body))))
        (body (if (and (stringp (first body)) (rest body)) (rest body) body)))
    `(progn
       (test (,(intern (format nil "~A/SQLITE" name)) :suite results-db)
         ,@doc (call-with-sqlite-store (lambda (,store) ,@body)))
       (test (,(intern (format nil "~A/POSTGRES" name)) :suite results-db-postgres)
         ,@doc (call-with-postgres-store (lambda (,store) ,@body))))))

(backend-test a-stored-result-reads-back-exactly (store)
  (progn
    (let* ((text (format nil "first line~%naïve café, ✓ and a tab:~Cend~%~A" #\Tab
                         (make-string 20000 :initial-element #\q)))
           (args (let ((h (make-hash-table :test 'equal))) (setf (gethash "url" h) "https://x") h))
           (handle (res:put-result store "conv-a" "fetch" args text))
           (record (res:find-result store "conv-a" handle)))
      (is (string= text (res:stored-result-text record)) "the text, byte for byte")
      (is (string= "fetch" (res:stored-result-name record)))
      (is (equal "https://x" (gethash "url" (res:stored-result-arguments record))))
      (is (null (res:find-result store "conv-b" handle)) "another conversation finds nothing"))))

(backend-test forgetting-a-conversation-erases-only-its-results (store)
  (progn
    (let ((a1 (res:put-result store "a" "t" nil "one"))
          (a2 (res:put-result store "a" "t" nil "two"))
          (b1 (res:put-result store "b" "t" nil "three")))
      (is (= 2 (res:forget-conversation-results store "a")))
      (is (null (res:find-result store "a" a1)))
      (is (null (res:find-result store "a" a2)))
      (is (res:find-result store "b" b1))
      (is (= 0 (res:forget-conversation-results store "a")) "forgetting again erases nothing"))))

(backend-test an-agent-reads-back-a-result-kept-in-the-database (store)
  (progn
    (let* ((agent (actor:make-agent))
           (text (format nil "~{row ~D~%~}" (loop for i from 1 to 50 collect i))))
      (actor:offload-tool-results agent store :conversation "db-conv")
      (let ((handle (res:put-result store "db-conv" "query" nil text)))
        (is (search (format nil "row 7~%row 8~%")
                    (actor:act agent "read-result"
                               (let ((h (make-hash-table :test 'equal)))
                                 (setf (gethash "handle" h) handle (gethash "first_line" h) 7
                                       (gethash "last_line" h) 8)
                                 h))))
        (is (= 1 (actor:forget-agent-results agent)))))))

(test a-store-over-a-pool-borrows-a-connection-for-each-operation
  (let* ((file (namestring (uiop:tmpize-pathname
                            (merge-pathnames (format nil "results-~36R.db" (random (expt 2 40) (make-random-state t)))
                                             (uiop:temporary-directory)))))
         (pool (conn:make-pool (be:make-sqlite file) :size 3)))
    (unwind-protect
         (let* ((store (rdb:make-db-result-store pool :ensure t))
                (handle (res:put-result store "p" "t" nil "pooled")))
           (is (string= "pooled" (res:stored-result-text (res:find-result store "p" handle))))
           (is (<= (conn:pool-open-count pool) 3)))
      (conn:close-pool pool)
      (ignore-errors (delete-file file)))))

(test a-table-name-that-is-not-an-identifier-is-refused
  (signals error (rdb:results-ddl :table "results; DROP TABLE x"))
  (signals error (rdb:make-db-result-store nil :table "")))
