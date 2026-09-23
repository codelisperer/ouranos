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
                    (#:schema #:mnemosyne/schema))
  (:documentation
   "A mnemosyne-backed backend for hyperion/session's STORE protocol: durable, cross-process
    sessions. MAKE-DB-STORE over an open mnemosyne connection; :ensure t creates the table.")
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
  ((connection :initarg :connection :reader db-store-connection)
   (dialect    :initarg :dialect    :reader db-store-dialect :initform :sqlite)
   (table      :initarg :table      :reader db-store-table   :initform *table*)
   (lock :initform (bt:make-lock "hyperion-session-db") :reader db-store-lock))
  (:documentation
   "A durable session store over a mnemosyne connection. One connection guarded by a lock
    (a connection pool is a future refinement -- an Atropos-managed component)."))

(defun make-db-store (connection &key (dialect :sqlite) (table *table*) ensure)
  "A session store over an open mnemosyne CONNECTION (a CL-DBI connection from
mnemosyne/conn:connect). DIALECT is :sqlite or :postgres. With :ENSURE, create the table."
  (let ((store (make-instance 'db-store :connection connection :dialect dialect :table table)))
    (when ensure (ensure-schema store))
    store))

;;; --- schema / DDL ---------------------------------------------------------
(defun db-store-ddl (store)
  "The CREATE TABLE DDL for STORE's sessions table under its dialect."
  ;; The designator goes straight through (pre-publication issue 432, ADR-0003) -- see the note in auth-db.lisp.
  (schema:schema-ddl (schema:find-schema 'hyperion-session)
                     :dialect (db-store-dialect store)))

(defun ensure-schema (store)
  "Create the sessions table if absent. Returns STORE."
  (conn:exec (db-store-connection store) (db-store-ddl store))
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
  (bt:with-lock-held ((db-store-lock store))
    (let ((rows (q:fetch (db-store-connection store)
                         (list :select '(:id :data :created :accessed)
                               :from (list (db-store-table store))
                               :where (list := :id id))
                         :dialect (db-store-dialect store))))
      (when rows (%row->session (first rows))))))

(defmethod sess:store-add ((store db-store) session)
  (bt:with-lock-held ((db-store-lock store))
    ;; upsert on the primary key -- dogfoods mnemosyne/query ON CONFLICT.
    (q:run (db-store-connection store)
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
  (bt:with-lock-held ((db-store-lock store))
    (let ((n (q:run (db-store-connection store)
                    (list :delete-from (db-store-table store) :where (list := :id id))
                    :dialect (db-store-dialect store))))
      (and (integerp n) (plusp n)))))

(defmethod sess:store-count ((store db-store))
  (bt:with-lock-held ((db-store-lock store))
    (let ((rows (q:fetch (db-store-connection store)
                         (list :select '((:as (:count :*) :n))
                               :from (list (db-store-table store)))
                         :dialect (db-store-dialect store))))
      (%to-int (param:row-value (first rows) :n)))))

(defmethod sess:store-list ((store db-store))
  (bt:with-lock-held ((db-store-lock store))
    (mapcar #'%row->session
            (q:fetch (db-store-connection store)
                     (list :select '(:id :data :created :accessed)
                           :from (list (db-store-table store)))
                     :dialect (db-store-dialect store)))))
