;;;; sqlite-busy.lisp --- a second SQLite writer waits for the lock instead of failing (#223)
;;;;
;;;; SQLite's own busy timeout is zero, and mnemosyne used to leave it there, so a second
;;;; connection writing to a file while another held the write lock failed with "database is
;;;; locked" at once. CONNECT now sets *SQLITE-BUSY-TIMEOUT-MS*. These hold a real write lock
;;;; on one connection (BEGIN IMMEDIATE) and write from another, so the result does not depend
;;;; on two threads happening to collide.

(in-package #:mnemosyne/tests)

(in-suite mnemosyne)

(defun %busy-db-path ()
  (merge-pathnames (format nil "mnemosyne-busy-~36R.sqlite" (random (expt 2 40) (make-random-state t)))
                   (uiop:temporary-directory)))

(defun %call-with-held-write-lock (function)
  "Open a fresh SQLite file on two connections, A and B, with *SQLITE-BUSY-TIMEOUT-MS* as the
caller has bound it. A holds the write lock (BEGIN IMMEDIATE plus an insert). Call FUNCTION with
A and B, then close both and delete the file."
  (let* ((path (%busy-db-path))
         (a (conn:connect (be:make-sqlite (namestring path))))
         (b (conn:connect (be:make-sqlite (namestring path)))))
    (unwind-protect
         (progn
           (conn:exec a "CREATE TABLE busy_t (x INTEGER)")
           (conn:exec a "BEGIN IMMEDIATE")
           (conn:exec a "INSERT INTO busy_t VALUES (1)")
           (funcall function a b))
      (ignore-errors (conn:exec a "COMMIT"))
      (conn:disconnect a)
      (conn:disconnect b)
      (ignore-errors (delete-file path)))))

(defun %seconds-since (start)
  (/ (- (get-internal-real-time) start) internal-time-units-per-second))

(test a-second-writer-waits-for-the-lock-and-then-succeeds
  (let ((conn:*sqlite-busy-timeout-ms* 5000))
    (%call-with-held-write-lock
     (lambda (a b)
       (let* ((start (get-internal-real-time))
              (outcome nil)
              ;; THREAD-LIFETIME: scoped -- joined below, before the connections close.
              (writer (sb-thread:make-thread
                       (lambda ()
                         (setf outcome
                               (handler-case (progn (conn:exec b "INSERT INTO busy_t VALUES (2)")
                                                    :written)
                                 (error (e) (princ-to-string e)))))
                       :name "second-writer")))
         (sleep 0.3)
         (conn:exec a "COMMIT")
         (sb-thread:join-thread writer :timeout 10 :default nil)
         (is (eq :written outcome) "the second writer should wait and then write, got ~S" outcome)
         (is (>= (%seconds-since start) 0.25) "and it did wait for the first to commit")
         (is (= 2 (length (conn:query a "SELECT x FROM busy_t")))))))))

(test without-a-busy-timeout-a-second-writer-fails-at-once
  ;; The control, and the behaviour before #223: with the timeout off, the same write fails
  ;; immediately rather than waiting.
  (let ((conn:*sqlite-busy-timeout-ms* nil))
    (%call-with-held-write-lock
     (lambda (a b)
       (declare (ignore a))
       (let* ((start (get-internal-real-time))
              (err (handler-case (progn (conn:exec b "INSERT INTO busy_t VALUES (2)") nil)
                     (conn:db-error (e) e))))
         (is (typep err 'conn:db-error) "the write should fail without a timeout, got ~S" err)
         (is (search "locked" (princ-to-string err) :test #'char-equal)
             "as \"database is locked\": ~A" err)
         (is (< (%seconds-since start) 0.25) "and fail at once, without waiting"))))))
