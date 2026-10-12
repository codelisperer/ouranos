;;;; session-db.lisp --- a mnemosyne-backed session store (Hyperion aux system).
;;;;
;;;; The DB implementation of hyperion/session's STORE protocol: sessions survive a server
;;;; restart (unlike MEMORY-STORE) and can be shared across processes. Lives in its own ASDF
;;;; system (hyperion/session-db) so hyperion core keeps no database dependency -- this aux
;;;; system depends on mnemosyne (a normal leftward dep: mnemosyne is left of hyperion in the
;;;; DAG). It dogfoods the mnemosyne query builder: upsert (ON CONFLICT) for STORE-ADD and a
;;;; COUNT(*) aggregate for STORE-COUNT.
;;;;
;;;; The data bag is serialised as a readable s-expression (an alist). Session values must be
;;;; READ-safe printable -- strings, numbers, keywords, and lists of them (the usual session
;;;; contents: user id, roles, csrf token, flash). Reads bind *read-eval* nil.

(cl:defpackage #:hyperion/session-db
  (:use #:cl)
  (:local-nicknames (#:bt #:bordeaux-threads)
                    (#:sess #:hyperion/session)
                    (#:param #:mnemosyne/param)
                    (#:q #:mnemosyne/query)
                    (#:conn #:mnemosyne/conn)
                    (#:schema #:mnemosyne/schema)
                    (#:log #:aion/log))
  (:documentation
   "A mnemosyne-backed backend for hyperion/session's STORE protocol: durable, cross-process
    sessions. MAKE-DB-STORE over a mnemosyne pool, or over an open mnemosyne connection;
    :ensure t creates the table.")
  (:export #:db-store #:make-db-store #:db-store-ddl #:ensure-schema #:*table*))

(in-package #:hyperion/session-db)

(defvar *table* "hyperion_sessions"
  "Default table name for the session store.")

;; A schema for the sessions table -- the single source of truth for its DDL.
(schema:defschema hyperion-session (:table "hyperion_sessions")
  (:id       :string  :primary t)
  (:data     :text)
  (:created  :integer)
  (:accessed :integer))

(defclass db-store ()
  ((source     :initarg :source     :accessor db-store-source)
   (backend    :initarg :backend    :reader db-store-backend :initform nil)
   (dialect    :initarg :dialect    :reader db-store-dialect :initform :sqlite)
   (table      :initarg :table      :reader db-store-table   :initform *table*)
   (lock :initform (bt:make-recursive-lock "hyperion-session-db") :reader db-store-lock))
  (:documentation
   "A durable session store over a mnemosyne pool or one mnemosyne connection. See
CALL-WITH-STORE-CONNECTION for how each operation gets its connection, and what happens when
Postgres has ended it."))

(defun make-db-store (source &key (dialect :sqlite) (table *table*) ensure backend)
  "A session store over SOURCE: a mnemosyne pool (MNEMOSYNE/CONN:MAKE-POOL), or an open mnemosyne
connection (MNEMOSYNE/CONN:CONNECT). DIALECT is :sqlite or :postgres. With :ENSURE, create the
table.

A POOL IS WHAT AN APP ON POSTGRES SHOULD PASS (#636), usually the pool it gives
HYPERION/DB-CONNECTION:WRAP-CONNECTION. Each operation then borrows a connection, which inside a
request is the request's own, and an operation that finds its connection ended by Postgres is
run once more on a fresh one.

OVER ONE CONNECTION, every operation takes turns on it under the store's lock. Pass BACKEND, the
backend that connection was opened from, so the store can open a new connection when Postgres
ends that one; without it, a lost connection fails every later operation until the process
restarts, as before #636."
  ;; THE NAME IS CHECKED HERE, NOT ONLY WHEN DDL IS MADE (Copilot's review of #652): with :ENSURE
  ;; NIL, an app's own migrations path, every operation still writes the name into SQL.
  (%check-table table)
  (let ((store (make-instance 'db-store :source source :backend backend
                                       :dialect dialect :table table)))
    (when ensure (ensure-schema store))
    store))

;;; --- one connection per operation, and one retry when Postgres ended it (#636) -------------
;;;
;;; Managed Postgres ends client connections during maintenance or a restart (SQLSTATE 57P01).
;;; The store used to keep one connection for the life of the process, and after that every
;;; operation failed with "Connection to database server lost": a signed-in request got a 500
;;; on every visit while requests without a session cookie, and so a health check, worked.
;;;
;;; Now an operation that fails with a DB-ERROR, on a connection that afterwards reads as closed
;;; (MNEMOSYNE/CONN:CONNECTION-OPEN-P), runs once more on a new connection. A statement that
;;; fails on a working connection is not retried. Over a pool the retry opens one connection
;;; from the pool's backend for itself and closes it afterwards, rather than borrowing again: a
;;; restart ends every connection in the pool, so the next idle one is likely dead too. Over one
;;; connection with a BACKEND, the store replaces its connection. One retry, never a loop: when
;;; the second attempt fails too, its error is signalled.
;;;
;;; Every operation here is safe to run twice: a read, an upsert, and UPDATEs and DELETEs. Only
;;; their results can be wrong, and only when the first attempt committed and the connection
;;; then failed before its reply arrived. That needs a network failure in that window: a
;;; statement Postgres's own 57P01 interrupts is aborted, and one sent to a connection already
;;; ended never runs. In that window the retry of STORE-DEL, STORE-SAVE or STORE-TOUCH reports
;;; the row as gone, and STORE-SWEEP counts only what it removed itself (Copilot's review of
;;; #639). Not retrying them would leave a signed-in request failing after a restart, because
;;; WRAP-SESSION writes the session back on a pool connection the restart also ended.

(defun %lost-p (condition connection)
  (and (typep condition 'conn:db-error) (not (conn:connection-open-p connection))))

(defgeneric %reconnect (store)
  (:documentation "Open a new connection from STORE's backend, install it as STORE's connection
and return it. Called with the store's lock held. A generic so a test can count the calls.")
  (:method ((store db-store))
    (let ((fresh (conn:connect (db-store-backend store))))
      (setf (db-store-source store) fresh)
      fresh)))

(defun call-with-store-connection (store function)
  "Call FUNCTION with a connection for one operation of STORE; see the section above."
  (let ((source (db-store-source store)))
    (flet ((attempt (connection)
             (handler-case (values (funcall function connection) t)
               (error (e)
                 (if (%lost-p e connection)
                     (values e nil)
                     (error e))))))
      (if (conn:poolp source)
          (multiple-value-bind (result ok) (conn:with-connection (c source) (attempt c))
            (if ok
                result
                (progn (log:warn "session store connection lost, retrying on a new one"
                                 :condition (string-downcase (princ-to-string (type-of result))))
                       (conn:with-connection (c (conn:pool-backend source)) (funcall function c)))))
          (bt:with-recursive-lock-held ((db-store-lock store))
            ;; READ AGAIN UNDER THE LOCK (Copilot's review of #639). A thread that waited for the
            ;; lock while another reconnected must use that new connection, not the dead one it
            ;; saw before; otherwise it reconnects again and the other's connection is left open.
            (let ((connection (db-store-source store)))
              (multiple-value-bind (result ok) (attempt connection)
                (cond (ok result)
                      ((null (db-store-backend store)) (error result))
                      (t (log:warn "session store connection lost, reconnecting"
                                   :condition (string-downcase (princ-to-string (type-of result))))
                         (ignore-errors (conn:disconnect connection))
                         (funcall function (%reconnect store)))))))))))

(defmacro with-store-connection ((var store) &body body)
  "Run BODY with VAR bound to a connection for one operation of STORE (#636)."
  `(call-with-store-connection ,store (lambda (,var) ,@body)))

;;; --- schema / DDL ---------------------------------------------------------
(defun %check-table (table)
  "TABLE, when it is a table name: letters, digits and underscores, not starting with a digit.
DB-STORE-DDL writes it into SQL, so anything else is refused rather than quoted."
  (unless (and (stringp table) (plusp (length table))
               (not (digit-char-p (char table 0)))
               (every (lambda (ch) (or (alphanumericp ch) (char= ch #\_))) table))
    (error "hyperion/session-db: ~S is not a table name (letters, digits and underscores)" table))
  table)

(defun db-store-ddl (store)
  "The CREATE TABLE DDL for STORE's sessions table under its dialect, named as the store's :TABLE
says (#638). The registered schema declares hyperion_sessions; it is copied with the store's
table name, not changed, as hyperion/auth-db does for its tables (#378). Before #638 this created
hyperion_sessions whatever :TABLE said, and the store's first operation then failed on a table
that did not exist."
  ;; The designator goes straight through (pre-publication issue 432, ADR-0003) -- see the note in auth-db.lisp.
  (let ((schema (copy-structure (schema:find-schema 'hyperion-session))))
    (setf (schema:schema-table schema) (%check-table (db-store-table store)))
    (schema:schema-ddl schema :dialect (db-store-dialect store))))

(defun ensure-schema (store)
  "Create the sessions table if absent. Returns STORE."
  (with-store-connection (c store) (conn:exec c (db-store-ddl store)))
  store)

;;; --- (de)serialising the data bag -----------------------------------------
(defun %serialize (session)
  (with-standard-io-syntax
    (let ((*package* (find-package '#:keyword)))
      (prin1-to-string (sess:session-alist session)))))

(defun %deserialize (string)
  (when (and (stringp string) (plusp (length string)))
    (with-standard-io-syntax
      (let ((*read-eval* nil) (*package* (find-package '#:keyword)))
        (handler-case (read-from-string string) (error () nil))))))

;;; The local case-insensitive reader that used to live here is now
;;; MNEMOSYNE/PARAM:ROW-VALUE (pre-publication issue 489). One behaviour change comes with it, deliberately: a
;;; key that matches nothing now SIGNALS instead of returning NIL. Every key below is a
;;; column this store's own schema declares, or an alias it wrote itself, so a miss means
;;; the table is not the one this store made -- which is worth a condition rather than a
;;; session that silently restores with an empty id.

(defun %to-int (v)
  (cond ((integerp v) v)
        ((stringp v) (or (ignore-errors (parse-integer v :junk-allowed t)) 0))
        (t 0)))

(defun %row->session (row)
  (sess:restore-session (princ-to-string (param:row-value row :id))
                        :created (%to-int (param:row-value row :created))
                        :accessed (%to-int (param:row-value row :accessed))
                        :data (%deserialize (param:row-value row :data))))

;;; --- the STORE protocol ---------------------------------------------------
(defmethod sess:store-ref ((store db-store) id)
  (with-store-connection (c store)
    (let ((rows (q:fetch c
                         (list :select '(:id :data :created :accessed)
                               :from (list (db-store-table store))
                               :where (list := :id id))
                         :dialect (db-store-dialect store))))
      (when rows (%row->session (first rows))))))

(defmethod sess:store-add ((store db-store) session)
  (with-store-connection (c store)
    ;; upsert on the primary key -- dogfoods mnemosyne/query ON CONFLICT.
    (q:run c
           (list :insert-into (db-store-table store)
                 :values (list (list :id (sess:session-id session)
                                     :data (%serialize session)
                                     :created (sess:session-created session)
                                     :accessed (sess:session-accessed session)))
                 :on-conflict '(:id)
                 :do-update (list :data     '(:excluded :data)
                                  :created  '(:excluded :created)
                                  :accessed '(:excluded :accessed)))
           :dialect (db-store-dialect store)))
  session)

(defmethod sess:store-del ((store db-store) id)
  (with-store-connection (c store)
    (let ((n (q:run c
                    (list :delete-from (db-store-table store) :where (list := :id id))
                    :dialect (db-store-dialect store))))
      (and (integerp n) (plusp n)))))

(defmethod sess:store-save ((store db-store) session)
  ;; An UPDATE, never an upsert (#230): a session the handler removed must stay removed, so
  ;; this writes only to a row that is still there, and reports whether it was.
  (with-store-connection (c store)
    (let ((n (q:run c
                    (list :update (db-store-table store)
                          :set (list :data (%serialize session)
                                     :accessed (sess:session-accessed session))
                          :where (list := :id (sess:session-id session)))
                    :dialect (db-store-dialect store))))
      (and (integerp n) (plusp n)))))

(defmethod sess:store-touch ((store db-store) id accessed)
  ;; One column (#243): a whole-session write here would put this request's copy of the data
  ;; bag over a change another request saved in the meantime. An UPDATE, so a removed session
  ;; stays removed.
  (with-store-connection (c store)
    (let ((n (q:run c
                    (list :update (db-store-table store)
                          :set (list :accessed accessed)
                          :where (list := :id id))
                    :dialect (db-store-dialect store))))
      (and (integerp n) (plusp n)))))

(defmethod sess:store-sweep ((store db-store) now)
  ;; One DELETE, loading no sessions (#121). The same limits as SESS:SESSION-EXPIRED-P: idle
  ;; is measured from `accessed', absolute from `created', and a NIL timeout adds no clause.
  (let* ((idle sess:*session-idle-timeout*)
         (absolute sess:*session-absolute-timeout*)
         (clauses (remove nil (list (and idle (list :< :accessed (- now idle)))
                                    (and absolute (list :< :created (- now absolute)))))))
    (if (null clauses)
        0
        (with-store-connection (c store)
          (let ((n (q:run c
                          (list :delete-from (db-store-table store)
                                :where (if (rest clauses) (cons :or clauses) (first clauses)))
                          :dialect (db-store-dialect store))))
            (if (integerp n) n 0))))))

(defmethod sess:store-count ((store db-store))
  (with-store-connection (c store)
    (let ((rows (q:fetch c
                         (list :select '((:as (:count :*) :n))
                               :from (list (db-store-table store)))
                         :dialect (db-store-dialect store))))
      (%to-int (param:row-value (first rows) :n)))))

(defmethod sess:store-list ((store db-store))
  (with-store-connection (c store)
    (mapcar #'%row->session
            (q:fetch c
                     (list :select '(:id :data :created :accessed)
                           :from (list (db-store-table store)))
                     :dialect (db-store-dialect store)))))
