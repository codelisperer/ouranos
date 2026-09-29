;;;; db-connection.lisp --- a Ring middleware that lends each request a pooled connection (#325).
;;;;
;;;; An app written against one global mnemosyne connection, such as `(defvar *db* ...)' used
;;;; from every handler, is safe only while its server runs one request at a time. Once the
;;;; server runs handlers on several threads (hyperion/server:start :workers, #324), two
;;;; requests would send statements over that one connection at once. WRAP-CONNECTION binds
;;;; the app's own variable, for the extent of each request, to a connection taken from a
;;;; mnemosyne pool, so the app's data layer keeps reading the same variable and does not
;;;; change.
;;;;
;;;; Its own system, as hyperion/session-db is, so hyperion core keeps no database
;;;; dependency. mnemosyne is to the left of hyperion in the DAG, so the dependency is allowed.

(cl:defpackage #:hyperion/db-connection
  (:use #:cl)
  (:local-nicknames (#:conn #:mnemosyne/conn)
                    (#:log #:aion/log))
  (:documentation
   "WRAP-CONNECTION: a Ring middleware that binds an app's connection variable to a
    connection from a mnemosyne pool for the extent of each request.")
  (:export #:wrap-connection #:*busy-response*))

(in-package #:hyperion/db-connection)

(defparameter *busy-response*
  (list 503 (list :content-type "text/plain; charset=utf-8" :retry-after "1")
        (list "Server busy"))
  "What WRAP-CONNECTION answers when no pooled connection became free within the pool's
checkout timeout. The same answer hyperion/server-uv gives when its worker pool is full: the
server is over capacity now, and the client may retry.")

(defun %streaming-body-p (response)
  (and (consp response) (functionp (third response))))

(defun %without-variable (response variable)
  "RESPONSE with its streaming body wrapped so that VARIABLE is unbound while the body runs.

A streaming body runs after the handler has returned, so after the request's connection has
gone back to the pool; it may be running on another thread by then. Without this, VARIABLE
inside the body would have its global value, which in an app written against one global
connection is that shared connection, and the body would use it with nothing to say so.
Unbound, the first use signals UNBOUND-VARIABLE naming the variable."
  (destructuring-bind (status headers body) response
    (list status headers
          (lambda (writer)
            (progv (list variable) '()
              (funcall body writer))))))

(defun wrap-connection (app pool variable)
  "APP wrapped so that each request runs with VARIABLE, a special variable naming the app's
database connection, bound to a connection lent by POOL (a mnemosyne/conn POOL).

  (defvar *db*)
  (hyperion/server:start
   (wrap-connection app (mnemosyne/conn:make-pool backend :size 8) '*db*)
   :workers 8)

The connection goes back to the pool when APP returns. The pool rolls back a transaction the
handler left open and, on Postgres, resets session settings and releases advisory locks before
lending it again; a handler that signals has its connection closed instead. See
MNEMOSYNE/CONN:CALL-WITH-CONNECTION.

A WITH-CONNECTION on the same POOL inside the handler gets the same connection, so code that
takes a connection from the pool itself also works under this middleware.

A STREAMING BODY (a function as the response's third element) runs after the connection has
gone back, and VARIABLE is unbound inside it. Take a connection in the body with
MNEMOSYNE/CONN:WITH-CONNECTION if it needs one. It is not lent one automatically because a
long-lived stream, such as server-sent events, would hold a pooled connection for its whole
life, and a few of them would leave none for ordinary requests.

When no connection becomes free within the pool's checkout timeout, the request is answered
with *BUSY-RESPONSE* and APP is not called. Give the pool at least as many connections as the
server has worker threads, or requests will wait for each other's connections."
  (check-type variable (and symbol (not null)))
  ;; A pool, not a backend. WITH-CONNECTION accepts either, and a backend here would open and
  ;; close a connection for every request with no limit, no timeout and no 503.
  (check-type pool conn:pool)
  (lambda (env)
    (let ((entered nil))
      (block request
        ;; Only the checkout made HERE is answered with 503, and it is the only one that can
        ;; signal before ENTERED is set. The same condition from inside APP, from a second
        ;; pool the handler uses, is left to the handler: a 503 would hide which pool ran
        ;; out. HANDLER-BIND rather than HANDLER-CASE so that condition is declined without
        ;; unwinding the handler's stack first.
        (handler-bind ((conn:pool-exhausted
                         (lambda (e)
                           (declare (ignore e))
                           (unless entered
                             (log:warn "hyperion/db-connection: no pooled connection became free"
                                       :pool-size (conn:pool-size pool))
                             (return-from request *busy-response*)))))
          (conn:with-connection (c pool)
            (setf entered t)
            (let ((response (progv (list variable) (list c)
                              (funcall app env))))
              (if (%streaming-body-p response)
                  (%without-variable response variable)
                  response))))))))
