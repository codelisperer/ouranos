;;;; timeouts.lisp --- a Postgres connect timeout and statement timeout (#959)
;;;;
;;;; The connect tests need no database. They point a Postgres backend at a local socket that
;;;; completes the TCP handshake and then never answers, which is what an overloaded server or a
;;;; proxy with nothing behind it looks like: cl-postgres sends its startup message and waits.
;;;; A "non-routable" address would test only the TCP part, and on some networks it fails at
;;;; once instead of hanging. The statement-timeout tests need the configured Postgres.

(in-package #:mnemosyne/tests)

(in-suite mnemosyne)

(defmacro with-silent-server ((port-var) &body body)
  "Run BODY with PORT-VAR bound to a port on 127.0.0.1 that accepts TCP connections and never
sends a byte."
  (let ((listener (gensym "LISTENER")))
    `(let ((,listener (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
       (unwind-protect
            (progn
              (setf (sb-bsd-sockets:sockopt-reuse-address ,listener) t)
              (sb-bsd-sockets:socket-bind ,listener #(127 0 0 1) 0)
              (sb-bsd-sockets:socket-listen ,listener 16)
              (let ((,port-var (nth-value 1 (sb-bsd-sockets:socket-name ,listener))))
                ,@body))
         (sb-bsd-sockets:socket-close ,listener)))))

(defun %connect-threads ()
  "The live threads CONNECT started to open a connection with a timeout."
  (remove-if-not (lambda (thread) (equal (sb-thread:thread-name thread) "mnemosyne-connect"))
                 (sb-thread:list-all-threads)))

(defun %silent-backend (port)
  (mnemosyne/backend:make-postgres "127.0.0.1" port "timeouts_db" "timeouts_user"
                                   "timeouts-password"))

(defun %elapsed-seconds (start)
  (/ (- (get-internal-real-time) start) internal-time-units-per-second))

(test a-postgres-connect-that-gets-no-answer-signals-db-connect-timeout-in-time
  (with-silent-server (port)
    (let* ((start (get-internal-real-time))
           (condition (handler-case
                          (progn (conn:connect (%silent-backend port) :connect-timeout 1) nil)
                        (error (e) e)))
           (elapsed (%elapsed-seconds start)))
      (is (typep condition 'conn:db-connect-timeout) "got ~S" condition)
      (is (typep condition 'conn:db-error) "it is a DB-ERROR, so existing handlers catch it")
      (is (<= 0.9 elapsed 5) "it waited about the timeout, not the operating system's limit: ~,2F s"
          elapsed)
      (loop repeat 50 while (%connect-threads) do (sleep 0.1))
      (is (null (%connect-threads))
          "the thread that was connecting is gone, while the server still holds the connection")
      (when (typep condition 'conn:db-connect-timeout)
        (is (equal "127.0.0.1" (conn:db-connect-timeout-host condition)))
        (is (eql port (conn:db-connect-timeout-port condition)))
        (is (eql 1 (conn:db-connect-timeout-seconds condition)))
        (let ((text (princ-to-string condition)))
          (is (search (format nil "127.0.0.1:~D" port) text) "the message names host:port: ~A" text)
          (is (null (search "timeouts-password" text)) "and not the password")
          (is (null (search "timeouts_user" text)) "nor the user")
          (is (null (search "timeouts_db" text)) "nor the database"))))))

(test a-postgres-connect-without-a-timeout-waits-for-the-server
  ;; The control for the test above: the silent server really does hold a connect that has no
  ;; limit, so the timeout, not the server, is what ended that one.
  (with-silent-server (port)
    (let* ((finished nil)
           (thread (sb-thread:make-thread
                    (lambda ()
                      (ignore-errors (conn:connect (%silent-backend port) :connect-timeout nil))
                      (setf finished t)))))
      (sleep 2)
      (is (not finished) "with no connect timeout, the connect was still waiting after 2 s")
      ;; Closing the listener does not end a connection it already accepted, so stop the thread.
      (sb-thread:terminate-thread thread)
      (ignore-errors (sb-thread:join-thread thread :default nil :timeout 5)))))

(test a-pooled-connect-that-times-out-gives-its-slot-back
  (with-silent-server (port)
    (let ((pool (conn:make-pool (%silent-backend port) :size 1 :connect-timeout 1
                                                       :checkout-timeout 30)))
      (unwind-protect
           (flet ((attempt ()
                    (let ((start (get-internal-real-time)))
                      (values (handler-case (conn:with-connection (c pool) c)
                                (error (e) e))
                              (%elapsed-seconds start)))))
             (multiple-value-bind (first elapsed) (attempt)
               (is (typep first 'conn:db-connect-timeout) "got ~S" first)
               (is (< elapsed 5) "in ~,2F s" elapsed))
             (is (= 0 (conn:pool-open-count pool)) "the slot is free once the condition arrives")
             ;; Size 1 and a 30 s checkout timeout: a slot still held would make this wait 30 s
             ;; and signal POOL-EXHAUSTED instead.
             (multiple-value-bind (second elapsed) (attempt)
               (is (typep second 'conn:db-connect-timeout) "the next checkout connects again: ~S"
                   second)
               (is (< elapsed 5) "without waiting for the first one's slot: ~,2F s" elapsed)))
        (conn:close-pool pool)))))

(test a-caller-unwound-while-connecting-stops-the-connect
  ;; An outer deadline unwinds the caller long before its own 30 s connect timeout. The connect
  ;; thread must not be left holding the silent server's connection.
  (with-silent-server (port)
    (let ((outcome (handler-case
                       (sb-sys:with-deadline (:seconds 1)
                         (conn:connect (%silent-backend port) :connect-timeout 30)
                         :connected)
                     (sb-sys:deadline-timeout () :outer-deadline)
                     (error (e) e))))
      (is (eq :outer-deadline outcome) "the outer deadline unwound the caller: ~S" outcome)
      (loop repeat 50 while (%connect-threads) do (sleep 0.1))
      (is (null (%connect-threads)) "and the thread that was connecting is gone"))))

(test a-connect-made-with-an-interrupt-deferred-still-stops-its-thread
  ;; #541, found by aion/dynamic's spawn-site sweep on #959's CI. A thread made while its creator
  ;; has an interrupt DEFERRED -- not merely inside SB-SYS:WITHOUT-INTERRUPTS, but with a signal
  ;; already waiting -- starts with the deferrable signals blocked and can never be interrupted.
  ;; TERMINATE-THREAD would then never reach CONNECT's thread, and a timed-out connect would hold
  ;; its socket for the life of the image. Measured on this machine: a plain thread, and one made
  ;; inside WITHOUT-INTERRUPTS with no signal waiting, both die; one made with an interrupt
  ;; deferred does not. CONNECT's thread calls UNBLOCK-INTERRUPTS first, so it does.
  (with-silent-server (port)
    (let ((me sb-thread:*current-thread*)
          (condition nil)
          (elapsed nil))
      (sb-sys:without-interrupts
        ;; Provoke the deferred interrupt: it arrives while this region is running, so SBCL
        ;; defers it and blocks the deferrable signals here until the region ends.
        (sb-thread:make-thread
         ;; THREAD-LIFETIME: this test's; it is not inheriting anything.
         ;; INTERRUPTS: it interrupts another thread and exits; nothing interrupts it.
         (lambda () (sleep 0.2) (ignore-errors (sb-thread:interrupt-thread me (lambda () nil)))))
        (sleep 1)
        (let ((start (get-internal-real-time)))
          (setf condition (handler-case
                              (progn (conn:connect (%silent-backend port) :connect-timeout 1) nil)
                            (error (e) e))
                elapsed (%elapsed-seconds start))))
      (is (typep condition 'conn:db-connect-timeout) "got ~S" condition)
      (is (<= 0.9 elapsed 5) "it timed out in ~,2F s" elapsed)
      (loop repeat 50 while (%connect-threads) do (sleep 0.1))
      (is (null (%connect-threads))
          "the connect thread is gone, so the stop reached a thread made with an interrupt deferred"))))

(test the-timeout-settings-are-checked
  (signals type-error (conn:connect (mnemosyne/backend:make-sqlite ":memory:") :connect-timeout 0))
  (signals type-error (conn:connect (mnemosyne/backend:make-sqlite ":memory:")
                                    :statement-timeout 1.5))
  (signals type-error (conn:make-pool (mnemosyne/backend:make-sqlite ":memory:")
                                      :connect-timeout -1))
  (signals type-error (conn:make-pool (mnemosyne/backend:make-sqlite ":memory:")
                                      :statement-timeout 0))
  ;; Postgres stores statement_timeout as a 32-bit integer of milliseconds.
  (signals type-error (conn:make-pool (mnemosyne/backend:make-sqlite ":memory:")
                                      :statement-timeout 2147483648))
  (let ((pool (conn:make-pool (mnemosyne/backend:make-sqlite ":memory:")
                              :statement-timeout 2147483647)))
    (is (conn:poolp pool) "the largest value Postgres accepts is accepted")
    (conn:close-pool pool)))

(defun %show-statement-timeout (c)
  (second (first (conn:query c "SHOW statement_timeout"))))

(test a-postgres-statement-past-its-timeout-signals-db-statement-timeout
  (with-each-pool-backend (backend)
    (when (%postgres-p)
      (let ((c (conn:connect backend :statement-timeout 300)))
        (unwind-protect
             (progn
               (is* (equal "300ms" (%show-statement-timeout c)) "CONNECT set the timeout")
               (let* ((start (get-internal-real-time))
                      (condition (handler-case (progn (conn:query c "SELECT pg_sleep(3)") nil)
                                   (error (e) e)))
                      (elapsed (%elapsed-seconds start)))
                 (is* (typep condition 'conn:db-statement-timeout) "got ~S" condition)
                 (is* (typep condition 'conn:db-error) "a DB-ERROR, so existing handlers catch it")
                 (is* (< elapsed 2) "the server cancelled it after about 0.3 s: ~,2F s" elapsed))
               (is* (equal '((:|one| 1)) (conn:query c "SELECT 1 AS one"))
                    "the connection is still usable afterwards"))
          (conn:disconnect c))))))

(test a-postgres-statement-within-its-timeout-is-not-cancelled
  ;; The control for the test above: the same statement shape completes when it fits.
  (with-each-pool-backend (backend)
    (when (%postgres-p)
      (let ((c (conn:connect backend :statement-timeout 2000)))
        (unwind-protect
             (is* (equal '((:|done| 1)) (conn:query c "SELECT 1 AS done FROM pg_sleep(0.1)"))
                  "a 0.1 s statement under a 2 s timeout returns")
          (conn:disconnect c))))))

(test a-postgres-statement-cancelled-for-another-reason-is-a-plain-db-error
  ;; SQLSTATE 57014 is any cancellation. pg_cancel_backend from a second connection must not be
  ;; reported as a timeout.
  (with-each-pool-backend (backend)
    (when (%postgres-p)
      (let ((victim (conn:connect backend :statement-timeout 30000))
            (other (conn:connect backend)))
        (unwind-protect
             (let* ((pid (second (first (conn:query victim "SELECT pg_backend_pid() AS pid"))))
                    (result nil)
                    (thread (sb-thread:make-thread
                             (lambda ()
                               (setf result (handler-case (progn (conn:query victim "SELECT pg_sleep(10)") :finished)
                                              (error (e) e)))))))
               (loop repeat 50
                     until (eql 1 (second (first (conn:query other "SELECT count(*)::int AS n FROM pg_stat_activity WHERE pid = ? AND state = 'active'" pid))))
                     do (sleep 0.1))
               (conn:query other "SELECT pg_cancel_backend(?) AS ok" pid)
               (sb-thread:join-thread thread :default nil :timeout 15)
               (is* (typep result 'conn:db-error) "the cancelled statement signalled: ~S" result)
               (is* (not (typep result 'conn:db-statement-timeout))
                    "and it is not reported as a statement timeout"))
          (conn:disconnect other)
          (conn:disconnect victim))))))

(test a-pool-sets-the-statement-timeout-again-after-each-reset
  ;; The pool's reset runs RESET ALL, which puts statement_timeout back to the server's default.
  (with-each-pool-backend (backend)
    (when (%postgres-p)
      (with-test-pool (pool backend :size 1 :statement-timeout 4321)
        (let ((first (conn:with-connection (c pool)
                       (is* (equal "4321ms" (%show-statement-timeout c))
                            "a new pooled connection has the pool's timeout")
                       (conn:exec c "SET statement_timeout = '9876ms'")
                       (is* (equal "9876ms" (%show-statement-timeout c))
                            "control: the borrower changed it inside the body")
                       c)))
          (conn:with-connection (c pool)
            (is* (eq first c) "control: the same connection was lent again, so it was reset")
            (is* (equal "4321ms" (%show-statement-timeout c))
                 "after the reset it has the pool's timeout, not the borrower's and not 0")))))))
