;;;; results-db.lisp --- tool results kept in a database through mnemosyne (#319).
;;;;
;;;; The same protocol as praxeon/results's memory store, for an app that keeps its
;;;; conversations: a result outlives the process, and FORGET-CONVERSATION-RESULTS erases a
;;;; conversation's results from the database. An aux system, like praxeon/memory-db, so that
;;;; praxeon's core keeps no datastore of its own. Postgres and SQLite, with plain SQL both run.
;;;;
;;;; THE STORE TAKES A CONNECTION OR A POOL, and gets its connection per operation the way
;;;; hyperion/auth-db does since #371: over one connection every operation holds the store's
;;;; lock, since one connection cannot run two statements at once; over a mnemosyne pool each
;;;; operation borrows a connection for its own extent.

(cl:defpackage #:praxeon/results-db
  (:use #:cl)
  (:local-nicknames (#:res #:praxeon/results)
                    (#:conn #:mnemosyne/conn)
                    (#:param #:mnemosyne/param)
                    (#:jzon #:com.inuoe.jzon)
                    (#:bt #:bordeaux-threads))
  (:documentation
   "A PRAXEON/RESULTS:RESULT-STORE in a database through mnemosyne (#319). MAKE-DB-RESULT-STORE
    over a connection or a pool; :ENSURE creates the table.")
  (:export #:db-result-store #:make-db-result-store #:ensure-schema #:results-ddl #:*table*))

(in-package #:praxeon/results-db)

(defvar *table* "praxeon_tool_results" "Default table name for stored tool results.")

(defclass db-result-store (res:result-store)
  ((source :initarg :source :reader store-source)
   (table :initarg :table :reader store-table)
   (lock :initform (bt:make-recursive-lock "praxeon-results-db") :reader store-lock))
  (:documentation "Tool results in TABLE, over a mnemosyne connection or pool (SOURCE)."))

(defun call-with-connection (store function)
  "Call FUNCTION with a connection for one operation of STORE: the store's connection under its
lock, or one borrowed from its pool."
  (let ((source (store-source store)))
    (if (conn:poolp source)
        (conn:with-connection (c source) (funcall function c))
        (bt:with-recursive-lock-held ((store-lock store)) (funcall function source)))))

(defmacro with-connection ((var store) &body body)
  `(call-with-connection ,store (lambda (,var) ,@body)))

(defun %check-table-name (table)
  (unless (and (stringp table) (plusp (length table))
               (every (lambda (ch) (or (alphanumericp ch) (char= ch #\_))) table))
    (error "praxeon/results-db: a table name is letters, digits and underscores, not ~S" table))
  table)

(defun results-ddl (&key (table *table*))
  "The CREATE TABLE statement for TABLE, the same on Postgres and SQLite, for an app that folds
it into its own migrations instead of calling ENSURE-SCHEMA."
  (format nil "CREATE TABLE IF NOT EXISTS ~A (conversation TEXT NOT NULL, handle TEXT NOT NULL, name TEXT, arguments TEXT, text TEXT NOT NULL, created_at BIGINT NOT NULL, PRIMARY KEY (conversation, handle))"
          (%check-table-name table)))

(defun ensure-schema (store)
  "Create STORE's table when it is absent. Returns STORE."
  (with-connection (c store)
    (conn:exec c (results-ddl :table (store-table store))))
  store)

(defun make-db-result-store (source &key (table *table*) ensure)
  "A result store in TABLE over SOURCE, a mnemosyne connection or pool. With ENSURE, creates the
table."
  (let ((store (make-instance 'db-result-store :source source
                                               :table (%check-table-name table))))
    (when ensure (ensure-schema store))
    store))

(defun %arguments-json (arguments)
  (and arguments (handler-case (jzon:stringify arguments) (error () (princ-to-string arguments)))))

(defmethod res:put-result ((store db-result-store) conversation name arguments text)
  (unless (and (stringp conversation) (plusp (length conversation)))
    (error "praxeon/results-db: a conversation must be a non-empty string, not ~S" conversation))
  (check-type text string)
  (let ((handle (res:new-handle)))
    (with-connection (c store)
      (conn:exec c (format nil "INSERT INTO ~A (conversation, handle, name, arguments, text, created_at) VALUES (?, ?, ?, ?, ?, ?)"
                           (store-table store))
                 conversation handle name (%arguments-json arguments) text (get-universal-time)))
    handle))

(defmethod res:find-result ((store db-result-store) conversation handle)
  (let ((row (first (with-connection (c store)
                      (conn:query c (format nil "SELECT name, arguments, text, created_at FROM ~A WHERE conversation = ? AND handle = ?"
                                            (store-table store))
                                  conversation handle)))))
    (when row
      (res:make-stored-result
       :handle handle :conversation conversation
       :name (param:row-value row :name)
       :arguments (let ((json (param:row-value row :arguments)))
                    (and (stringp json) (ignore-errors (jzon:parse json))))
       :text (param:row-value row :text)
       :created-at (param:row-value row :created_at)))))

(defmethod res:forget-conversation-results ((store db-result-store) conversation)
  (with-connection (c store)
    (let ((n (param:row-value
              (first (conn:query c (format nil "SELECT count(*) AS n FROM ~A WHERE conversation = ?"
                                           (store-table store))
                                 conversation))
              :n)))
      (conn:exec c (format nil "DELETE FROM ~A WHERE conversation = ?" (store-table store))
                 conversation)
      n)))
