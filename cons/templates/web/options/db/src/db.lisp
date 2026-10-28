;;;; db.lisp --- {{name}}'s database: one pool, shared by every store and every request.
;;;;
;;;; OPEN-DATABASE makes one mnemosyne pool from DATABASE_URL and gives that same pool to the
;;;; session store and the user store, and APP-WITH-DATABASE gives it to WRAP-CONNECTION, which
;;;; lends each request a connection of its own in *DB*. Never give two stores one connection
;;;; instead of the pool: each store locks only its own operations, so two request threads could
;;;; then send statements on that connection at the same moment.

(cl:in-package #:{{name}})

(defparameter +dialect+ {{db-dialect}}
  "The SQL dialect of this app's database, :sqlite or :postgres, chosen by `cons init --db`.")

(defparameter +default-database-url+ {{db-default-url}}
  "The database used when DATABASE_URL is not set, or NIL when it must be set.")

(defparameter *pool-size* 4
  "How many database connections the pool may open. At least the server's worker threads
(2 on :uv), so a request does not wait for another's connection.")

(defvar *db*)
(setf (documentation '*db* 'variable)
      "The connection lent to the running request by WRAP-CONNECTION. Unbound outside a request.")

(defvar *pool* nil "The one mnemosyne pool, or NIL when the database is not open.")
(defvar *sessions* nil "The session store, over *POOL*.")
(defvar *users* nil "The user store, over *POOL*.")

(defun database-url ()
  "DATABASE_URL, or +DEFAULT-DATABASE-URL+ when it is unset or empty. Signals when neither is
set."
  (let ((url (uiop:getenv "DATABASE_URL")))
    (cond ((and url (plusp (length url))) url)
          (+default-database-url+ +default-database-url+)
          (t (error (concatenate 'string
                                 "{{name}}: DATABASE_URL is not set. Set it in .env or the "
                                 "environment, for example "
                                 "DATABASE_URL=postgres://user@localhost:5432/{{name}}."))))))

(defun %ensure-sqlite-directory (url)
  "Make the directory a relative or absolute sqlite: URL's file is in, since SQLite creates the
file but not its directory."
  (let ((prefix (find-if (lambda (p) (uiop:string-prefix-p p url)) '("sqlite://" "sqlite3://"))))
    (when (and prefix (> (length url) (length prefix)))
      (ensure-directories-exist (subseq url (length prefix))))))

(defun open-database ()
  "Open the pool and both stores over it, creating their tables when they do not exist.
Signals when the database is already open. If a store cannot be made, the pool is closed, and
*POOL*, *SESSIONS* and *USERS* are all NIL again."
  (when *pool* (error "{{name}}: the database is already open. Call CLOSE-DATABASE first."))
  (let ((url (database-url))
        (made nil))
    (%ensure-sqlite-directory url)
    (setf *pool* (conn:make-pool (url:backend-from-url url) :size *pool-size*))
    ;; The pool is closed only when making the stores did not finish, as in START. A handler
    ;; on ERROR would run as soon as an error was signalled, before anything had decided to
    ;; unwind. A HANDLER-CASE inside a store constructor was never affected, because it handles
    ;; the error before an outer handler sees it. The case it broke is an error that reaches a
    ;; handler further out, which then declines it or resumes the constructor through a
    ;; restart: the pool was already closed under the constructor (#944).
    (unwind-protect
         (prog1 (setf *sessions* (session-db:make-db-store *pool* :dialect +dialect+ :ensure t)
                      *users* (auth:make-db-auth *pool* :dialect +dialect+ :ensure t))
           (setf made t))
      (unless made (close-database-during-cleanup)))))

(defun close-database ()
  "Close the pool, and with it every connection the stores and requests used. *POOL*,
*SESSIONS* and *USERS* are NIL afterwards even when closing the pool signals, so a later
OPEN-DATABASE is not refused (#1006)."
  (when *pool*
    (let ((pool *pool*))
      (unwind-protect (conn:close-pool pool)
        (setf *pool* nil *sessions* nil *users* nil)))))

(defun close-database-during-cleanup ()
  "CLOSE-DATABASE for cleanup code that runs while another error unwinds. A failure to close the
pool is logged with its condition type and nothing else, and does not replace the error that is
unwinding, which is the one the caller needs to see (#1006)."
  (handler-case (close-database)
    (error (e)
      (log:error "{{name}}: closing the database failed during cleanup" :condition (type-of e)))))

(defun app-with-database (app)
  "APP with a session from *SESSIONS*, inside a request that holds its own connection in *DB*.
The session is written back on that connection, before it goes back to the pool."
  (dbc:wrap-connection (session:wrap-session app *sessions*) *pool* '*db*))
