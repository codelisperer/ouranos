;;;; pool.lisp --- the connection pool lends one connection per thread and takes it back clean (#325)
;;;;
;;;; Run against every active backend. The Postgres-only checks are the ones #325 was ranked
;;;; for: a session-level advisory lock and a session setting must not reach the next
;;;; borrower. Each of those checks first confirms, from a second connection, that the state
;;;; really was held while the connection was lent, so a reset that did nothing cannot pass.

(in-package #:mnemosyne/tests)

(in-suite mnemosyne)

(defmacro with-each-pool-backend ((backend-var) &body body)
  "Run BODY once per active backend with BACKEND-VAR bound to it, then signal if a configured
Postgres was unreachable. The backend-level counterpart of WITH-EACH-BACKEND: a pool is made
from a backend, not from a connection."
  (let ((entry (gensym "ENTRY")))
    `(progn
       (dolist (,entry (active-backends))
         (let ((*current-backend* (car ,entry))
               (*current-dialect* (backend-dialect (car ,entry)))
               (,backend-var (cdr ,entry)))
           ,@body))
       (signal-unreachable-backend))))

(defmacro with-test-pool ((pool-var backend &rest options) &body body)
  `(let ((,pool-var (conn:make-pool ,backend ,@options)))
     (unwind-protect (progn ,@body)
       (conn:close-pool ,pool-var))))

(defun %postgres-p () (equal *current-backend* "postgres"))

(test a-pool-lends-the-same-connection-again-after-a-clean-exit
  (with-each-pool-backend (backend)
    (with-test-pool (pool backend :size 2)
      (let ((first (conn:with-connection (c pool) c))
            (second (conn:with-connection (c pool) c)))
        (is* (eq first second) "a connection returned cleanly is lent again")
        (is* (= 1 (conn:pool-open-count pool)) "and only one was ever opened")
        (is* (= 1 (conn:pool-idle-count pool)) "and it is idle between the two")))))

(test a-nested-checkout-on-the-same-thread-reuses-the-outer-connection
  ;; Size 1: a second checkout from inside the first would wait for itself.
  (with-each-pool-backend (backend)
    (with-test-pool (pool backend :size 1 :checkout-timeout 1)
      (conn:with-connection (outer pool)
        (conn:with-connection (inner pool)
          (is* (eq outer inner) "the inner body gets the outer body's connection")
          (is* (= 1 (conn:pool-open-count pool))))
        (is* (= 0 (conn:pool-idle-count pool))
             "the inner exit did not give the connection back while the outer body holds it")))))

(test a-body-that-signals-closes-its-connection-instead-of-returning-it
  (with-each-pool-backend (backend)
    (with-test-pool (pool backend :size 1)
      (let ((lent nil))
        (ignore-errors
         (conn:with-connection (c pool)
           (setf lent c)
           (error "the handler failed")))
        (is* (= 0 (conn:pool-open-count pool)) "the pool forgot the connection")
        (is* (= 0 (conn:pool-idle-count pool)))
        (conn:with-connection (c pool)
          (is* (not (eq c lent)) "the next borrower gets a new connection")
          (is* (equal '(1) (mapcar (lambda (row) (second row))
                                   (conn:query c "SELECT 1 AS one")))
               "and it works"))))))

(test an-open-transaction-is-rolled-back-before-the-connection-is-lent-again
  (with-each-pool-backend (backend)
    (with-test-pool (pool backend :size 1)
      (conn:with-connection (c pool)
        (conn:exec c "DROP TABLE IF EXISTS pool_txn_t")
        (conn:exec c "CREATE TABLE pool_txn_t (x INTEGER)"))
      (conn:with-connection (c pool)
        (conn:exec c "BEGIN")
        (conn:exec c "INSERT INTO pool_txn_t VALUES (1)")
        (is* (= 1 (length (conn:query c "SELECT x FROM pool_txn_t")))
             "the row is visible inside the transaction the body left open"))
      (conn:with-connection (c pool)
        (is* (null (conn:query c "SELECT x FROM pool_txn_t"))
             "the next borrower does not see the uncommitted row")
        (conn:exec c "INSERT INTO pool_txn_t VALUES (2)")
        (is* (= 1 (length (conn:query c "SELECT x FROM pool_txn_t")))
             "and is not inside a transaction it did not open")
        (conn:exec c "DROP TABLE pool_txn_t")))))

(test a-postgres-advisory-lock-does-not-go-back-to-the-pool
  ;; praxeon/retrieval's per-corpus lock is a session-level pg_advisory_lock (#325's hub
  ;; comment). The OTHER connection is the witness: it cannot take the lock while the pooled
  ;; connection holds it, and can once the pooled connection has been returned.
  (with-each-pool-backend (backend)
    (when (%postgres-p)
      (with-test-pool (pool backend :size 1)
        (let ((key 325325325)
              (other (conn:connect backend)))
          (flet ((other-can-take-it-p ()
                   ;; mnemosyne reads a boolean as 1 or 0 on every backend.
                   (let ((got (eql 1 (second (first (conn:query other "SELECT pg_try_advisory_lock(?) AS got" key))))))
                     (when got (conn:query other "SELECT pg_advisory_unlock(?)" key))
                     got)))
            (unwind-protect
                 (progn
                   (conn:with-connection (c pool)
                     (conn:query c "SELECT pg_advisory_lock(?)" key)
                     (is* (not (other-can-take-it-p))
                          "control: while lent, the pooled connection holds the lock"))
                   (is* (= 1 (conn:pool-idle-count pool)) "the connection went back to the pool")
                   (is* (other-can-take-it-p)
                        "once it is back in the pool, the lock is free"))
              (conn:disconnect other))))))))

(test a-postgres-session-setting-does-not-reach-the-next-borrower
  (with-each-pool-backend (backend)
    (when (%postgres-p)
      (with-test-pool (pool backend :size 1)
        (flet ((timeout (c) (second (first (conn:query c "SHOW statement_timeout")))))
          (let ((default (conn:with-connection (c pool) (timeout c))))
            (conn:with-connection (c pool)
              (conn:exec c "SET statement_timeout = '4321ms'")
              (is* (equal "4321ms" (timeout c)) "control: the setting took inside the body"))
            (conn:with-connection (c pool)
              (is* (equal default (timeout c)) "the next borrower sees the default again"))))))))

(test a-postgres-temporary-table-and-listen-do-not-reach-the-next-borrower
  ;; Two more kinds of session state RESET ALL alone would leave behind (review of #330).
  (with-each-pool-backend (backend)
    (when (%postgres-p)
      (with-test-pool (pool backend :size 1)
        (flet ((temp-table-p (c)
                 (second (first (conn:query c "SELECT to_regclass('pg_temp.pool_temp_t') IS NOT NULL AS present"))))
               (channels (c)
                 (mapcar #'second (conn:query c "SELECT pg_listening_channels() AS channel"))))
          (conn:with-connection (c pool)
            (conn:exec c "CREATE TEMPORARY TABLE pool_temp_t (x INTEGER)")
            (conn:exec c "LISTEN pool_channel")
            (is* (eql 1 (temp-table-p c)) "control: the temporary table exists in the body")
            (is* (equal '("pool_channel") (channels c)) "control: and the session listens"))
          (conn:with-connection (c pool)
            (is* (eql 0 (temp-table-p c)) "the next borrower has no temporary table")
            (is* (null (channels c)) "and listens on nothing")))))))

(test a-failed-postgres-transaction-does-not-poison-the-next-borrower
  ;; A statement that fails inside BEGIN leaves the session in an aborted transaction, where
  ;; every later statement fails until a ROLLBACK. The body catches the error itself and
  ;; exits normally, so this is the reset path, not the close path.
  (with-each-pool-backend (backend)
    (when (%postgres-p)
      (with-test-pool (pool backend :size 1)
        (let ((lent nil))
          (conn:with-connection (c pool)
            (setf lent c)
            (conn:exec c "BEGIN")
            (is* (typep (nth-value 1 (ignore-errors (conn:query c "SELECT no_such_column FROM pg_class")))
                        'conn:db-error))
            (is* (typep (nth-value 1 (ignore-errors (conn:query c "SELECT 1 AS one")))
                        'conn:db-error)
                 "control: the session is in an aborted transaction"))
          (conn:with-connection (c pool)
            (is* (eq c lent) "the same connection was lent again")
            (is* (equal '(1) (mapcar #'second (conn:query c "SELECT 1 AS one")))
                 "and it answers")))))))

(test a-checkout-waits-for-a-connection-to-come-back
  (with-each-pool-backend (backend)
    (with-test-pool (pool backend :size 1 :checkout-timeout 10)
      (let* ((held (sb-thread:make-semaphore))
             ;; THREAD-LIFETIME: scoped -- joined below.
             (holder (sb-thread:make-thread
                      (lambda ()
                        (conn:with-connection (c pool)
                          (sb-thread:signal-semaphore held)
                          (sleep 0.3)
                          c))
                      :name "pool-holder")))
        (sb-thread:wait-on-semaphore held)
        (let* ((start (get-internal-real-time))
               (mine (conn:with-connection (c pool) c))
               (theirs (aion/test-threads:join holder :timeout 10)))
          (is* (>= (%seconds-since start) 0.2) "the checkout waited for the holder")
          (is* (eq mine theirs) "and got the connection the holder gave back"))))))

(test a-checkout-that-waits-too-long-signals-pool-exhausted
  (with-each-pool-backend (backend)
    (with-test-pool (pool backend :size 1 :checkout-timeout 0.2)
      (let* ((held (sb-thread:make-semaphore))
             (release (sb-thread:make-semaphore))
             ;; THREAD-LIFETIME: scoped -- released and joined below.
             (holder (sb-thread:make-thread
                      (lambda ()
                        (conn:with-connection (c pool)
                          (declare (ignore c))
                          (sb-thread:signal-semaphore held)
                          (sb-thread:wait-on-semaphore release :timeout 10)))
                      :name "pool-holder")))
        (sb-thread:wait-on-semaphore held)
        (let ((start (get-internal-real-time))
              (outcome (handler-case (conn:with-connection (c pool) (declare (ignore c)) :lent)
                         (conn:pool-exhausted (e) e))))
          (is* (typep outcome 'conn:pool-exhausted))
          (is* (typep outcome 'conn:db-error) "it is a DB-ERROR, so existing handlers see it")
          (is* (>= (%seconds-since start) 0.15) "after waiting for the timeout"))
        (sb-thread:signal-semaphore release)
        (aion/test-threads:join holder :timeout 10)))))

(test many-threads-share-a-small-pool-without-exceeding-its-size
  (with-each-pool-backend (backend)
    (with-test-pool (pool backend :size 3 :checkout-timeout 30)
      (let* ((lock (sb-thread:make-mutex))
             (most-open 0)
             (failures 0)
             (done 0)
             (threads
               (loop for i below 8
                     ;; THREAD-LIFETIME: scoped -- every one is joined below.
                     collect (sb-thread:make-thread
                              (lambda ()
                                (loop repeat 20
                                      do (handler-case
                                             (conn:with-connection (c pool)
                                               (conn:query c "SELECT 1 AS one")
                                               (sb-thread:with-mutex (lock)
                                                 (setf most-open (max most-open (conn:pool-open-count pool)))
                                                 (incf done)))
                                           (error () (sb-thread:with-mutex (lock) (incf failures))))))
                              :name (format nil "pool-borrower-~D" i)))))
        (aion/test-threads:join-all threads :timeout 60)
        (is* (= 160 done) "every checkout ran its query")
        (is* (= 0 failures))
        (is* (<= most-open 3) "the pool never had more than SIZE open, saw ~D" most-open)
        (is* (= (conn:pool-open-count pool) (conn:pool-idle-count pool))
             "and every connection came back")))))

(test a-closed-pool-refuses-and-closes-what-comes-back
  (with-each-pool-backend (backend)
    (let* ((pool (conn:make-pool backend :size 2))
           (held (sb-thread:make-semaphore))
           (release (sb-thread:make-semaphore))
           ;; THREAD-LIFETIME: scoped -- released and joined below. It holds one connection
           ;; lent across CLOSE-POOL; a second checkout on this thread would reuse ours.
           (holder (sb-thread:make-thread
                    (lambda ()
                      (conn:with-connection (c pool)
                        (declare (ignore c))
                        (sb-thread:signal-semaphore held)
                        (sb-thread:wait-on-semaphore release :timeout 10)))
                    :name "pool-holder")))
      (sb-thread:wait-on-semaphore held)
      (conn:with-connection (c pool) c)
      (is* (and (= 2 (conn:pool-open-count pool)) (= 1 (conn:pool-idle-count pool)))
           "control: one connection lent, one idle")
      (conn:close-pool pool)
      (is* (and (= 1 (conn:pool-open-count pool)) (= 0 (conn:pool-idle-count pool)))
           "the idle connection closed; the lent one is still open")
      (sb-thread:signal-semaphore release)
      (aion/test-threads:join holder :timeout 10)
      (is* (= 0 (conn:pool-open-count pool)) "the lent connection closed when it came back")
      (is* (typep (handler-case (conn:with-connection (c pool) (declare (ignore c)) :lent)
                    (conn:pool-closed (e) e))
                  'conn:pool-closed))
      (conn:close-pool pool)
      (is* (= 0 (conn:pool-open-count pool)) "CLOSE-POOL a second time is allowed and changes nothing"))))

(test an-idle-connection-the-server-closed-is-replaced-before-it-is-lent
  ;; The server ends the pooled connection's session while it is idle, as a managed Postgres
  ;; does after an idle timeout. With IDLE-CHECK 0 every checkout pings first.
  (with-each-pool-backend (backend)
    (when (%postgres-p)
      (flet ((kill-idle (pool)
               (let ((pid (conn:with-connection (c pool)
                            (second (first (conn:query c "SELECT pg_backend_pid() AS pid")))))
                     (other (conn:connect backend)))
                 (unwind-protect
                      (conn:query other "SELECT pg_terminate_backend(?)" pid)
                   (conn:disconnect other))
                 (sleep 0.2))))
        (with-test-pool (pool backend :size 1 :idle-check nil)
          (kill-idle pool)
          (is* (typep (nth-value 1 (ignore-errors
                                    (conn:with-connection (c pool) (conn:query c "SELECT 1 AS one"))))
                      'conn:db-error)
               "control: without the idle check the dead connection is lent and fails"))
        (with-test-pool (pool backend :size 1 :idle-check 0)
          (kill-idle pool)
          (is* (equal '(1) (conn:with-connection (c pool)
                             (mapcar #'second (conn:query c "SELECT 1 AS one"))))
               "with it, the dead connection is replaced and the query answers")
          (is* (= 1 (conn:pool-open-count pool))))))))

(test with-connection-still-opens-and-closes-a-connection-for-a-backend
  (with-each-pool-backend (backend)
    (let ((lent nil))
      (conn:with-connection (c backend)
        (setf lent c)
        (is* (equal '(1) (mapcar #'second (conn:query c "SELECT 1 AS one")))))
      (is* (typep (nth-value 1 (ignore-errors (conn:query lent "SELECT 1 AS one"))) 'conn:db-error)
           "the connection was closed on exit"))))

(test a-pool-does-no-io-until-a-connection-is-needed
  ;; A SQLite path whose parent is a regular file cannot be opened, whoever runs the test.
  ;; MAKE-POOL succeeds, the first checkout signals, and the failed connect gives its slot
  ;; back instead of using it up.
  (let* ((file (%busy-db-path))
         (pool (progn (with-open-file (s file :direction :output :if-exists :supersede)
                        (write-string "not a directory" s))
                      (conn:make-pool (be:make-sqlite (format nil "~A/x.db" (namestring file)))
                                      :size 1))))
    (unwind-protect
         (progn
           (is (= 0 (conn:pool-open-count pool)))
           (is (typep (nth-value 1 (ignore-errors (conn:with-connection (c pool) c)))
                      'conn:db-error))
           (is (= 0 (conn:pool-open-count pool)) "the slot of the failed connect was given back"))
      (conn:close-pool pool)
      (ignore-errors (delete-file file)))))
