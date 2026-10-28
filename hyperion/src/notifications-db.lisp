;;;; notifications-db.lisp --- a mnemosyne store for hyperion/notifications (#792).
;;;;
;;;; The database implementation of hyperion/notifications' store protocol, in its own system so
;;;; hyperion/notifications keeps no database dependency (mnemosyne is to hyperion's left in the
;;;; DAG). Two tables, created by the app's own migrations from the DDL exported here, as
;;;; docs/migrations.md section 5 asks of an aux system; MAKE-DB-NOTIFICATION-STORE checks they
;;;; exist and names the migrations when they do not.
;;;;
;;;; The SQL is written out, with ? placeholders, as mnemosyne/jobs writes it: NOTIFICATION-PUT
;;;; needs "count = count + 1", which the query builder's SET does not express, and the unread
;;;; index is a partial unique index, which no schema form declares.
;;;;
;;;; COLLAPSING IS SAFE UNDER CONCURRENCY. NOTIFICATION-PUT with a group key first updates the
;;;; recipient's unread item with that key, and inserts only when there is none. Two calls at
;;;; once could both find none; the unique index on (recipient, group_key) over unread rows lets
;;;; only one insert succeed, and the other then updates the row the first one made.
;;;;
;;;; A title or body is stored as its printed form, a string or (:KEY KEY :ARGS PLIST), and read
;;;; back with *READ-EVAL* NIL in the keyword package, as hyperion/session-db stores a session.

(cl:defpackage #:hyperion/notifications-db
  (:use #:cl)
  (:local-nicknames (#:bt #:bordeaux-threads)
                    (#:n #:hyperion/notifications)
                    (#:param #:mnemosyne/param)
                    (#:conn #:mnemosyne/conn)
                    (#:log #:aion/log))
  (:documentation
   "A mnemosyne-backed store for hyperion/notifications: MAKE-DB-NOTIFICATION-STORE over a
    mnemosyne pool or one connection. The tables come from the app's migrations, made from
    NOTIFICATIONS-DDL, NOTIFICATIONS-INDEX-DDL, NOTIFICATIONS-UNREAD-KEY-DDL and DELIVERY-DDL.")
  (:export #:db-notification-store #:make-db-notification-store
           #:notifications-ddl #:notifications-index-ddl #:notifications-unread-key-ddl
           #:delivery-ddl #:ensure-tables
           #:missing-notification-tables #:missing-notification-tables-cause
           #:*notifications-table* #:*delivery-table*))

(in-package #:hyperion/notifications-db)

(defvar *notifications-table* "hyperion_notifications")
(defvar *delivery-table* "hyperion_notification_delivery")

(defun %check-table (table)
  "TABLE, when it is a table name: letters, digits and underscores, not starting with a digit.
It is written into SQL, so anything else is refused rather than quoted."
  (unless (and (stringp table) (plusp (length table))
               (not (digit-char-p (char table 0)))
               (every (lambda (ch) (or (alphanumericp ch) (char= ch #\_))) table))
    (error "hyperion/notifications-db: ~S is not a table name (letters, digits and underscores)"
           table))
  table)

;;; --- DDL, for the app's migrations ------------------------------------------------------
;;;
;;; TEXT and BIGINT are the same words in SQLite and Postgres, so the DDL has no dialect.

(defun notifications-ddl (&key (table *notifications-table*))
  "CREATE TABLE for the notifications."
  (format nil "CREATE TABLE IF NOT EXISTS ~A (id TEXT PRIMARY KEY, recipient TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, body TEXT, link TEXT, group_key TEXT, count BIGINT NOT NULL, stamp BIGINT NOT NULL, created_at BIGINT NOT NULL, read_at BIGINT)"
          (%check-table table)))

(defun notifications-index-ddl (&key (table *notifications-table*))
  "The index the list and the unread count read through: a recipient's items by stamp."
  (format nil "CREATE INDEX IF NOT EXISTS idx_~A_recipient_stamp ON ~A (recipient, stamp)"
          (%check-table table) table))

(defun notifications-unread-key-ddl (&key (table *notifications-table*))
  "The partial unique index that allows one unread item per recipient and group key, which is
what makes collapsing safe under concurrency (see this file's header)."
  (format nil "CREATE UNIQUE INDEX IF NOT EXISTS uq_~A_unread_group ON ~A (recipient, group_key) WHERE read_at IS NULL AND group_key IS NOT NULL"
          (%check-table table) table))

(defun delivery-ddl (&key (table *delivery-table*))
  "CREATE TABLE for each recipient's delivery choice per kind."
  (format nil "CREATE TABLE IF NOT EXISTS ~A (recipient TEXT NOT NULL, kind TEXT NOT NULL, delivery TEXT NOT NULL, PRIMARY KEY (recipient, kind))"
          (%check-table table)))

;;; --- the store --------------------------------------------------------------------------

(defclass db-notification-store ()
  ((source :initarg :source :accessor %source)
   (backend :initarg :backend :initform nil :reader %backend)
   (table :initarg :table :reader %table)
   (delivery-table :initarg :delivery-table :reader %delivery-table)
   (lock :initform (bt:make-recursive-lock "hyperion/notifications-db") :reader %lock))
  (:documentation "A notification store over a mnemosyne pool or one mnemosyne connection."))

(define-condition missing-notification-tables (error)
  ((table :initarg :table :reader %missing-table)
   (delivery-table :initarg :delivery-table :reader %missing-delivery-table)
   (cause :initarg :cause :initform nil :reader missing-notification-tables-cause))
  (:report
   (lambda (c s)
     (format s "hyperion/notifications-db: the notification tables ~A and ~A could not be read (~A).~%"
             (%missing-table c) (%missing-delivery-table c) (missing-notification-tables-cause c))
     (format s "~%Add migrations to your timeline that create them:~%~%")
     (format s "  (be:make-migration \"<your-id>_hyperion_notifications\" \"notifications\"~%")
     (format s "                     (notifications-db:notifications-ddl) \"DROP TABLE ~A\")~%" (%missing-table c))
     (format s "  (be:make-migration \"<your-id>_hyperion_notifications_index\" \"notifications index\"~%")
     (format s "                     (notifications-db:notifications-index-ddl) \"DROP INDEX idx_~A_recipient_stamp\")~%" (%missing-table c))
     (format s "  (be:make-migration \"<your-id>_hyperion_notifications_unread_key\" \"one unread item per group key\"~%")
     (format s "                     (notifications-db:notifications-unread-key-ddl) \"DROP INDEX uq_~A_unread_group\")~%" (%missing-table c))
     (format s "  (be:make-migration \"<your-id>_hyperion_notification_delivery\" \"delivery choices\"~%")
     (format s "                     (notifications-db:delivery-ddl) \"DROP TABLE ~A\")~%" (%missing-delivery-table c))
     (format s "~%See docs/migrations.md, section 5.~%")))
  (:documentation "Signalled by MAKE-DB-NOTIFICATION-STORE when its tables cannot be read. CAUSE
is the database's own error. The report names the migrations that create them."))

;;; One connection per operation, and one retry when Postgres ended it, as hyperion/session-db
;;; does (#636); see the section there for why each operation here is safe to run twice. The
;;; one that is not quite: NOTIFICATION-PUT retried after a commit whose reply was lost collapses
;;; the same notification twice, so COUNT can be one too high. That needs a network failure in a
;;; narrow window, and a count one too high is the cost.

(defun %lost-p (condition connection)
  (and (typep condition 'conn:db-error) (not (conn:connection-open-p connection))))

(defun %call-with-connection (store function)
  (let ((source (%source store)))
    (flet ((attempt (connection)
             (handler-case (values (funcall function connection) t)
               (error (e)
                 (if (%lost-p e connection) (values e nil) (error e))))))
      (if (conn:poolp source)
          (multiple-value-bind (result ok) (conn:with-connection (c source) (attempt c))
            (if ok
                result
                (progn (log:warn "notification store connection lost, retrying on a new one")
                       (conn:with-connection (c (conn:pool-backend source)) (funcall function c)))))
          (bt:with-recursive-lock-held ((%lock store))
            (let ((connection (%source store)))
              (multiple-value-bind (result ok) (attempt connection)
                (cond (ok result)
                      ((null (%backend store)) (error result))
                      (t (log:warn "notification store connection lost, reconnecting")
                         (ignore-errors (conn:disconnect connection))
                         (let ((fresh (conn:connect (%backend store))))
                           (setf (%source store) fresh)
                           (funcall function fresh)))))))))))

(defmacro with-connection ((var store) &body body)
  `(%call-with-connection ,store (lambda (,var) ,@body)))

(defun ensure-tables (store)
  "Create STORE's tables and indexes if absent: for tests and quick starts. An app creates them
in its migrations (MISSING-NOTIFICATION-TABLES). Returns STORE."
  (with-connection (c store)
    (conn:exec c (notifications-ddl :table (%table store)))
    (conn:exec c (notifications-index-ddl :table (%table store)))
    (conn:exec c (notifications-unread-key-ddl :table (%table store)))
    (conn:exec c (delivery-ddl :table (%delivery-table store))))
  store)

(defun %check-tables (store)
  (handler-case
      (with-connection (c store)
        (conn:query c (format nil "SELECT id FROM ~A WHERE 1 = 0" (%table store)))
        (conn:query c (format nil "SELECT recipient FROM ~A WHERE 1 = 0" (%delivery-table store))))
    (error (e)
      (error 'missing-notification-tables :table (%table store)
                                          :delivery-table (%delivery-table store) :cause e))))

(defun make-db-notification-store (source &key (table *notifications-table*)
                                               (delivery-table *delivery-table*)
                                               backend ensure (require-tables t))
  "A notification store over SOURCE, a mnemosyne pool (preferred, as for hyperion/session-db) or
one open mnemosyne connection; BACKEND lets the store reconnect when Postgres ends that
connection. TABLE and DELIVERY-TABLE name the tables. With ENSURE, create them; otherwise, with
REQUIRE-TABLES (the default), check they can be read and signal MISSING-NOTIFICATION-TABLES,
which names the migrations to add, when they cannot."
  (let ((store (make-instance 'db-notification-store
                              :source source :backend backend
                              :table (%check-table table)
                              :delivery-table (%check-table delivery-table))))
    (cond (ensure (ensure-tables store))
          (require-tables (%check-tables store)))
    store))

;;; --- rows -------------------------------------------------------------------------------

(defun %print (x)
  (with-standard-io-syntax
    (let ((*package* (find-package '#:keyword)))
      (prin1-to-string x))))

(defun %read (string)
  (when (and (stringp string) (plusp (length string)))
    (with-standard-io-syntax
      (let ((*read-eval* nil) (*package* (find-package '#:keyword)))
        (handler-case (read-from-string string) (error () nil))))))

(defun %int (v)
  (cond ((integerp v) v)
        ((stringp v) (parse-integer v :junk-allowed t))
        (t nil)))

(defun %kind-name (kind) (string-downcase (symbol-name kind)))

(defparameter +columns+
  "id, recipient, kind, title, body, link, group_key, count, stamp, created_at, read_at")

(defun %row->notification (row)
  (flet ((v (k) (param:row-value row k)))
    (let ((x (n:make-notification (v :recipient)
                                  (intern (string-upcase (v :kind)) '#:keyword)
                                  :title (%read (v :title)) :body (%read (v :body))
                                  :link (v :link) :group-key (v :group_key))))
      (setf (n:notification-id x) (v :id)
            (n:notification-count x) (%int (v :count))
            (n:notification-stamp x) (%int (v :stamp))
            (n:notification-created-at x) (%int (v :created_at))
            (n:notification-read-at x) (%int (v :read_at)))
      x)))

(defun %select-by-id (c store recipient id)
  (first (conn:query c (format nil "SELECT ~A FROM ~A WHERE recipient = ? AND id = ?"
                               +columns+ (%table store))
                     recipient id)))

(defun %collapse (c store x)
  "Update RECIPIENT's unread item with X's group key from X. The number of rows changed."
  (conn:exec c (format nil "UPDATE ~A SET kind = ?, title = ?, body = ?, link = ?, stamp = ?, created_at = ?, count = count + 1 WHERE recipient = ? AND group_key = ? AND read_at IS NULL"
                       (%table store))
             (%kind-name (n:notification-kind x)) (%print (n:notification-title x))
             (and (n:notification-body x) (%print (n:notification-body x)))
             (n:notification-link x) (n:notification-stamp x) (n:notification-created-at x)
             (n:notification-recipient x) (n:notification-group-key x)))

(defun %insert (c store x)
  (conn:exec c (format nil "INSERT INTO ~A (~A) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                       (%table store) +columns+)
             (n:notification-id x) (n:notification-recipient x)
             (%kind-name (n:notification-kind x)) (%print (n:notification-title x))
             (and (n:notification-body x) (%print (n:notification-body x)))
             (n:notification-link x) (n:notification-group-key x)
             (n:notification-count x) (n:notification-stamp x)
             (n:notification-created-at x) nil))

(defun %unread-by-key (c store recipient key)
  (first (conn:query c (format nil "SELECT ~A FROM ~A WHERE recipient = ? AND group_key = ? AND read_at IS NULL"
                               +columns+ (%table store))
                     recipient key)))

;;; --- the protocol -----------------------------------------------------------------------

(defmethod n:notification-put ((store db-notification-store) (x n:notification))
  (with-connection (c store)
    (let ((recipient (n:notification-recipient x)) (key (n:notification-group-key x)))
      (flet ((stored () (%row->notification
                         (if key
                             (%unread-by-key c store recipient key)
                             (%select-by-id c store recipient (n:notification-id x))))))
        (cond ((null key) (%insert c store x) (stored))
              ((plusp (or (%int (%collapse c store x)) 0)) (stored))
              ;; None to collapse into: insert. When a concurrent call inserted first, the
              ;; unread-key index refuses this one, and the row it made is collapsed into.
              ((handler-case (progn (%insert c store x) t)
                 (conn:db-error () nil))
               (stored))
              (t (%collapse c store x) (stored)))))))

(defmethod n:notification-list ((store db-notification-store) recipient
                                &key unread-only (limit 20) before)
  (let ((rows (with-connection (c store)
                (apply #'conn:query c
                       (format nil "SELECT ~A FROM ~A WHERE recipient = ?~:[~; AND read_at IS NULL~]~:[~; AND stamp < ?~] ORDER BY stamp DESC LIMIT ?"
                               +columns+ (%table store) unread-only before)
                       recipient (append (and before (list before)) (list (1+ limit)))))))
    (values (mapcar #'%row->notification (subseq rows 0 (min limit (length rows))))
            (> (length rows) limit))))

(defmethod n:unread-count ((store db-notification-store) recipient)
  (with-connection (c store)
    (%int (param:row-value (first (conn:query c (format nil "SELECT COUNT(*) AS n FROM ~A WHERE recipient = ? AND read_at IS NULL"
                                                         (%table store))
                                              recipient))
                           :n))))

(defmethod n:mark-read ((store db-notification-store) recipient id)
  (with-connection (c store)
    (plusp (or (%int (conn:exec c (format nil "UPDATE ~A SET read_at = ? WHERE recipient = ? AND id = ? AND read_at IS NULL"
                                          (%table store))
                                (get-universal-time) recipient id))
               0))))

(defmethod n:mark-all-read ((store db-notification-store) recipient)
  (with-connection (c store)
    (or (%int (conn:exec c (format nil "UPDATE ~A SET read_at = ? WHERE recipient = ? AND read_at IS NULL"
                                   (%table store))
                         (get-universal-time) recipient))
        0)))

(defmethod n:prune-notifications ((store db-notification-store) &key read-before unread-before)
  (with-connection (c store)
    (+ (if read-before
           (or (%int (conn:exec c (format nil "DELETE FROM ~A WHERE read_at IS NOT NULL AND read_at < ?"
                                          (%table store))
                                read-before))
               0)
           0)
       (if unread-before
           (or (%int (conn:exec c (format nil "DELETE FROM ~A WHERE read_at IS NULL AND created_at < ?"
                                          (%table store))
                                unread-before))
               0)
           0))))

(defmethod n:delivery-ref ((store db-notification-store) recipient kind)
  (let ((row (with-connection (c store)
               (first (conn:query c (format nil "SELECT delivery FROM ~A WHERE recipient = ? AND kind = ?"
                                            (%delivery-table store))
                                  recipient (%kind-name kind))))))
    (and row (find (param:row-value row :delivery) n:+deliveries+
                   :test #'string-equal :key #'symbol-name))))

(defmethod n:delivery-set ((store db-notification-store) recipient kind delivery)
  ;; The same check as the memory store: a declared kind, and one of the four deliveries or NIL.
  (n::%check-delivery-choice kind delivery)
  (with-connection (c store)
    (conn:exec c (format nil "DELETE FROM ~A WHERE recipient = ? AND kind = ?" (%delivery-table store))
               recipient (%kind-name kind))
    (when delivery
      (conn:exec c (format nil "INSERT INTO ~A (recipient, kind, delivery) VALUES (?, ?, ?)"
                           (%delivery-table store))
                 recipient (%kind-name kind) (%kind-name delivery))))
  delivery)
