;;;; jobs-tests.lisp --- the database job store on SQLite and Postgres (#689).
;;;;
;;;; Every test runs on an in-memory SQLite database, and again on Postgres when
;;;; MNEMOSYNE_TEST_PG_URL is set. The store is held to aion/schedule's own store checks, the
;;;; same ones the in-memory store passes. RUN-TESTS prints the Postgres coverage in the form
;;;; scripts/verify-tree.lisp reads, so a run without Postgres says so instead of reading as a
;;;; pass.

(cl:defpackage #:mnemosyne/jobs/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:jobs #:mnemosyne/jobs)
                    (#:s #:aion/schedule)
                    (#:checks #:aion/schedule/store-checks)
                    (#:conn #:mnemosyne/conn)
                    (#:be #:mnemosyne/backend)
                    (#:url #:mnemosyne/url))
  (:export #:run-tests))

(in-package #:mnemosyne/jobs/tests)

(def-suite jobs :description "aion/schedule's job store in a database (#689).")
(def-suite jobs-postgres :description "The same checks on Postgres.")
(in-suite jobs)

(defun %pg-url () (uiop:getenv "MNEMOSYNE_TEST_PG_URL"))

(defun run-tests ()
  "Run the SQLite and Postgres suites and print the Postgres coverage in the form
scripts/verify-tree.lisp reads."
  (let* ((sqlite (run 'jobs))
         (postgres (run 'jobs-postgres))
         (all (append sqlite postgres)))
    (explain! all)
    (if (%pg-url)
        (format t "~&BACKEND-CHECKS postgres ~D~%"
                (count-if-not (lambda (r) (typep r 'fiveam::test-skipped)) postgres))
        (format t "~&BACKEND-CHECKS postgres SKIPPED (MNEMOSYNE_TEST_PG_URL is not set)~%"))
    (finish-output)
    (results-status all)))

(defun %suffix () (format nil "~36R" (random (expt 2 40) (make-random-state t))))

(defun call-with-sqlite (function)
  "Call FUNCTION with a function that makes a fresh store, each on its own in-memory database."
  (let ((connections '()))
    (unwind-protect
         (funcall function (lambda (&rest keys)
                             (let ((c (conn:connect (be:make-sqlite ":memory:"))))
                               (push c connections)
                               (apply #'jobs:make-db-job-store c keys))))
      (mapc #'conn:disconnect connections))))

(defun call-with-postgres (function)
  "As CALL-WITH-SQLITE, each store in freshly named tables, which are dropped afterwards."
  (if (not (%pg-url))
      (skip "MNEMOSYNE_TEST_PG_URL is not set -- this says nothing about Postgres")
      (let ((c (conn:connect (url:backend-from-url (%pg-url))))
            (tables '()))
        (unwind-protect
             (funcall function
                      (lambda (&rest keys)
                        (let ((jobs-table (format nil "aion_jobs_~A" (%suffix)))
                              (runs-table (format nil "aion_job_runs_~A" (%suffix))))
                          (push jobs-table tables)
                          (push runs-table tables)
                          (apply #'jobs:make-db-job-store c :jobs-table jobs-table
                                                            :runs-table runs-table keys))))
          (dolist (table tables)
            (ignore-errors (conn:exec c (format nil "DROP TABLE IF EXISTS ~A" table))))
          (conn:disconnect c)))))

(defmacro backend-test (name (make-store) &body body)
  "Define NAME/SQLITE in JOBS and NAME/POSTGRES in JOBS-POSTGRES, each running BODY with
MAKE-STORE bound to a function that makes a fresh store on that backend; it takes
MAKE-DB-JOB-STORE's keys."
  `(progn
     (test (,(intern (format nil "~A/SQLITE" name)) :suite jobs)
       (call-with-sqlite (lambda (,make-store) ,@body)))
     (test (,(intern (format nil "~A/POSTGRES" name)) :suite jobs-postgres)
       (call-with-postgres (lambda (,make-store) ,@body)))))

(backend-test the-database-store-keeps-the-store-contract (make-store)
  (checks:check-store (lambda () (funcall make-store :ensure t))))

(backend-test a-store-without-its-tables-refuses-to-start (make-store)
  (signals jobs:missing-job-tables (funcall make-store))
  (let ((store (funcall make-store :ensure t)))
    (is-true store "with :ENSURE it creates them")
    (jobs:ensure-schema store)
    (is (null (s:store-jobs store)) "and creating them twice is harmless")))

(backend-test two-schedulers-ticking-in-turn-on-one-database-run-a-slot-once (make-store)
  (let* ((store (funcall make-store :ensure t))
         (clock (s:make-manual-clock 3990000000))
         (n (list 0))
         (f (lambda (ctx) (declare (ignore ctx)) (incf (car n)) '(:items 2)))
         (a (s:make-scheduler store :clock clock :dispatch :inline))
         (b (s:make-scheduler store :clock clock :dispatch :inline)))
    (unwind-protect
         (progn
           (s:define-job a "nightly" f :schedule '(:every 60))
           (s:define-job b "nightly" f :schedule '(:every 60))
           (s:clock-advance clock 60)
           (s:tick a)
           (s:tick b)
           (is (= 1 (car n)))
           (let ((run (first (s:store-runs store "nightly"))))
             (is (eq :completed (s:job-run-outcome run)))
             (is (eq :schedule (s:job-run-trigger run)))
             (is (equal '(:items 2) (s:job-run-counts run)))))
      (s:stop a :timeout 5)
      (s:stop b :timeout 5))))

(backend-test a-row-that-cannot-be-read-costs-only-its-own-job (make-store)
  (let* ((store (funcall make-store :ensure t))
         (clock (s:make-manual-clock 3990000000))
         (n (list 0))
         (a (s:make-scheduler store :clock clock :dispatch :inline)))
    (unwind-protect
         (progn
           (s:define-job a "nightly" (lambda (ctx) (declare (ignore ctx)) (incf (car n)) nil)
                         :schedule '(:every 60))
           ;; Arguments naming a package this image does not have, as after a redeploy that
           ;; removed it.
           (conn:exec (jobs::store-source store)
                      (format nil "INSERT INTO ~A (job_key, function_name, schedule, args, next_due, updated_at) VALUES (?, ?, ?, ?, ?, ?)"
                              (jobs::jobs-table store))
                      "gone" "nightly" "(:EVERY 60)" "(NO-SUCH-PACKAGE-689::X)"
                      3990000000 3990000000)
           (let ((bad (find "gone" (s:store-jobs store) :key #'s:stored-job-key :test #'equal)))
             (is-true bad "STORE-JOBS still returns every row")
             (is (stringp (s:stored-job-unreadable bad)) "with the unreadable one marked"))
           (s:clock-advance clock 60)
           (is (= 1 (length (s:tick a))) "and a tick runs the readable job")
           (is (= 1 (car n)))
           (is (null (s:store-runs store "gone"))))
      (s:stop a :timeout 5))))

(test the-table-names-are-checked
  (signals error (jobs:jobs-ddl :jobs-table "jobs; DROP TABLE x"))
  (is (= 3 (length (jobs:jobs-ddl)))))
