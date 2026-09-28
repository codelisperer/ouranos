;;;; db-connection-tests.lisp --- WRAP-CONNECTION lends each request its own pooled connection (#325).
;;;;
;;;; Its own package and system (hyperion/db-connection/tests), so the core hyperion suite
;;;; keeps no database dependency. SQLite in memory: each connection is its own database,
;;;; which is enough here, because what is under test is which connection a request gets,
;;;; not what is in it. The pool's own behaviour is tested in mnemosyne/tests/pool.lisp.

(cl:defpackage #:hyperion/db-connection/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:dbc  #:hyperion/db-connection)
                    (#:conn #:mnemosyne/conn)
                    (#:be   #:mnemosyne/backend))
  (:export #:run-tests))

(in-package #:hyperion/db-connection/tests)

(def-suite db-connection :description "hyperion/db-connection: a pooled connection per request.")
(defun run-tests () (run! 'db-connection))

(in-suite db-connection)

(defvar *db*)

(defmacro with-pool ((var &rest options) &body body)
  `(let ((,var (conn:make-pool (be:make-sqlite ":memory:") ,@options)))
     (unwind-protect (progn ,@body)
       (conn:close-pool ,var))))

(defun %ok (&optional (body "ok")) (list 200 '(:content-type "text/plain") (list body)))

(test a-request-runs-with-the-variable-bound-to-a-pooled-connection
  (with-pool (pool :size 2)
    (let* ((seen nil)
           (app (dbc:wrap-connection
                 (lambda (env)
                   (declare (ignore env))
                   (push *db* seen)
                   (%ok (princ-to-string (second (first (conn:query *db* "SELECT 1 AS one"))))))
                 pool '*db*)))
      (is (equal '(200 (:content-type "text/plain") ("1")) (funcall app '())))
      (is (equal '("1") (third (funcall app '()))))
      (is (= 2 (length seen)))
      (is (eq (first seen) (second seen)) "sequential requests reuse the one idle connection")
      (is (= 1 (conn:pool-idle-count pool)) "and it is back in the pool after each")
      (is (not (boundp '*db*)) "the global value is untouched"))))

(test a-with-connection-inside-the-handler-gets-the-requests-connection
  (with-pool (pool :size 1 :checkout-timeout 1)
    (let* ((same nil)
           (app (dbc:wrap-connection
                 (lambda (env)
                   (declare (ignore env))
                   (conn:with-connection (c pool)
                     (setf same (eq c *db*)))
                   (%ok))
                 pool '*db*)))
      (is (= 200 (first (funcall app '()))))
      (is (eq t same) "a pool of one did not wait for itself"))))

(test concurrent-requests-get-different-connections
  (with-pool (pool :size 2 :checkout-timeout 10)
    (let* ((both-in (sb-thread:make-semaphore))
           (go-on (sb-thread:make-semaphore))
           (app (dbc:wrap-connection
                 (lambda (env)
                   (declare (ignore env))
                   (sb-thread:signal-semaphore both-in)
                   (sb-thread:wait-on-semaphore go-on :timeout 10)
                   (list 200 '() (list *db*)))
                 pool '*db*))
           ;; THREAD-LIFETIME: scoped -- both joined below.
           (threads (loop for i below 2
                          collect (sb-thread:make-thread (lambda () (funcall app '()))
                                                         :name (format nil "request-~D" i)))))
      ;; Both requests are inside the handler at the same moment before either may leave.
      (is (sb-thread:wait-on-semaphore both-in :n 2 :timeout 10))
      (sb-thread:signal-semaphore go-on 2)
      (let ((conns (mapcar (lambda (th) (first (third (aion/test-threads:join th :timeout 10))))
                           threads)))
        (is (every #'identity conns))
        (is (not (eq (first conns) (second conns)))
            "two requests in flight at once hold two different connections")
        (is (= 2 (conn:pool-idle-count pool)))))))

(test a-request-that-finds-no-free-connection-is-answered-503-without-running-the-handler
  (with-pool (pool :size 1 :checkout-timeout 0.2)
    (let* ((called 0)
           (app (dbc:wrap-connection (lambda (env) (declare (ignore env)) (incf called) (%ok))
                                     pool '*db*))
           (held (sb-thread:make-semaphore))
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
      (let ((response (funcall app '())))
        (is (= 503 (first response)))
        (is (equal "1" (getf (second response) :retry-after)))
        (is (= 0 called) "the handler never ran"))
      (sb-thread:signal-semaphore release)
      (aion/test-threads:join holder :timeout 10)
      (is (= 200 (first (funcall app '()))) "control: with the connection back, the request runs")
      (is (= 1 called)))))

(test pool-exhausted-from-another-pool-inside-the-handler-is-not-turned-into-a-503
  (with-pool (pool :size 1)
    (with-pool (other :size 1 :checkout-timeout 0.1)
      (let* ((held (sb-thread:make-semaphore))
             (release (sb-thread:make-semaphore))
             ;; THREAD-LIFETIME: scoped -- released and joined below.
             (holder (sb-thread:make-thread
                      (lambda ()
                        (conn:with-connection (c other)
                          (declare (ignore c))
                          (sb-thread:signal-semaphore held)
                          (sb-thread:wait-on-semaphore release :timeout 10)))
                      :name "other-holder"))
             (app (dbc:wrap-connection
                   (lambda (env)
                     (declare (ignore env))
                     (conn:with-connection (c other) (declare (ignore c)) (%ok)))
                   pool '*db*)))
        (sb-thread:wait-on-semaphore held)
        (is (typep (nth-value 1 (ignore-errors (funcall app '()))) 'conn:pool-exhausted)
            "the handler's own pool ran out, and the handler sees it")
        (sb-thread:signal-semaphore release)
        (aion/test-threads:join holder :timeout 10)))))

(test a-handler-that-signals-has-its-connection-closed
  (with-pool (pool :size 1)
    (let ((app (dbc:wrap-connection (lambda (env) (declare (ignore env)) (error "handler failed"))
                                    pool '*db*)))
      (is (typep (nth-value 1 (ignore-errors (funcall app '()))) 'simple-error)
          "the handler's error reaches the server unchanged")
      (is (= 0 (conn:pool-open-count pool)) "and the connection it held was closed, not returned"))))

(test the-variable-is-unbound-inside-a-streaming-body
  (with-pool (pool :size 1)
    (let* ((in-handler nil)
           (app (dbc:wrap-connection
                 (lambda (env)
                   (declare (ignore env))
                   (setf in-handler (boundp '*db*))
                   (list 200 '() (lambda (writer)
                                   (funcall writer (if (boundp '*db*) "bound" "unbound")))))
                 pool '*db*))
           (response (funcall app '()))
           (written '()))
      (is (eq t in-handler) "control: the handler itself ran with the variable bound")
      (is (functionp (third response)))
      (is (= 1 (conn:pool-idle-count pool)) "the connection went back when the handler returned")
      (let ((*db* :the-apps-global-connection))
        (funcall (third response) (lambda (chunk) (push chunk written))))
      (is (equal '("unbound") written)
          "the body does not see the app's global connection, or a connection already returned"))))

(test the-variable-must-be-a-symbol
  (with-pool (pool)
    (is (typep (nth-value 1 (ignore-errors (dbc:wrap-connection (lambda (env) env) pool nil)))
               'type-error))
    (is (typep (nth-value 1 (ignore-errors (dbc:wrap-connection (lambda (env) env) pool "*DB*")))
               'type-error))))

(test the-pool-must-be-a-pool-not-a-backend
  ;; WITH-CONNECTION accepts a backend too, so a backend here would silently open a
  ;; connection per request with no limit and no 503.
  (is (typep (nth-value 1 (ignore-errors (dbc:wrap-connection (lambda (env) env)
                                                              (be:make-sqlite ":memory:") '*db*)))
             'type-error)))
