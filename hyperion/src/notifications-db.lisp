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
;;;; COLLAPSING IS SAFE UNDER CONCURRENCY. NOTIFICATION-PUT with a group key is one statement:
;;;; INSERT ... ON CONFLICT (recipient, group_key) WHERE read_at IS NULL AND group_key IS NOT NULL
;;;; DO UPDATE ... RETURNING. The partial unique index NOTIFICATIONS-UNREAD-KEY-DDL makes, over
;;;; unread rows, is the conflict target, which Postgres 9.5+ and SQLite 3.24+ infer from that
;;;; clause, and RETURNING (Postgres, SQLite 3.35+) gives back the row stored or collapsed into.
;;;; So no state can come between finding the unread item and writing it. The hub's review of
;;;; #1012 found what the earlier update, then insert, then update again could do: a mark-all-read
;;;; or a prune between the refused insert and the second update lost the notification, and on
;;;; Postgres the refused insert's 23505 aborted a transaction the app had the connection in. A
;;;; call that meets another call's uncommitted unread row waits for that transaction, then
;;;; collapses into the row when it commits, or inserts when it rolls back.
;;;;
;;;; A notification whose id is already stored is refused with the database's error, from the
;;;; primary key, whether or not it has a group key, unless it collapses into an unread item.
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

(defparameter +max-table-length+ 47
  "The longest table name: Postgres cuts an identifier to 63 bytes, and the longest name made
from it, uq_TABLE_unread_group, adds 16, so a longer TABLE would give an index whose stored name
is not the one the migration's DROP INDEX names (the hub's review of #1012).")

(defun %check-table (table)
  "TABLE, when it is a table name: ASCII letters, digits and underscores, not starting with a
digit, at most +MAX-TABLE-LENGTH+ characters. It is written into SQL, so anything else is refused
rather than quoted. ASCII only, because Postgres folds a non-ASCII letter's case by the server's
locale, so the stored name of an index made from it could differ from the name written here."
  (flet ((ascii-letter-p (ch) (or (char<= #\a ch #\z) (char<= #\A ch #\Z) (char= ch #\_))))
    (unless (and (stringp table) (<= 1 (length table) +max-table-length+)
                 (ascii-letter-p (char table 0))
                 (every (lambda (ch) (or (ascii-letter-p ch) (char<= #\0 ch #\9))) table))
      (error "hyperion/notifications-db: ~S is not a table name (1 to ~D ASCII letters, digits and underscores, not starting with a digit)"
             table +max-table-length+)))
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
which names the migrations to add, when they cannot.

The store needs Postgres 9.5 or later, or SQLite 3.35 or later: NOTIFICATION-PUT is one INSERT
... ON CONFLICT ... RETURNING (this file's header). An older SQLite refuses RETURNING when the
first notification is put, with a MNEMOSYNE/CONN:DB-ERROR for a syntax error at RETURNING. The
SQLite a desktop bundle carries is pinned in sqlite.pin (docs/dependencies.md);
elsewhere it is the system's copy, which mnemosyne/sqlite-library:loaded-library names."
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

(defun %read-text (string)
  "A stored title or body read back: a string or (:KEY KEY :ARGS PLIST), as stored. When it does
not read back as one, for example a key whose package is gone, the stored text itself, so that
one item cannot keep a recipient's list from being shown (the hub's review of #1012)."
  (when string
    (let ((x (%read string)))
      (if (n::%text-or-key-p x) x string))))

(defun %int (v)
  (cond ((integerp v) v)
        ((stringp v) (parse-integer v :junk-allowed t))
        (t nil)))

(defun %kind-name (kind) (string-downcase (symbol-name kind)))

(defparameter +columns+
  "id, recipient, kind, title, body, link, group_key, count, stamp, created_at, read_at")

(defun %row->notification (row)
  "The notification ROW holds, built directly rather than through MAKE-NOTIFICATION, which would
check it again and make a new id for each row only to replace it: what the store holds is shown
as it is (the hub's review of #1012)."
  (flet ((v (k) (param:row-value row k)))
    (n::%make-notification :id (v :id) :recipient (v :recipient)
                           :kind (intern (string-upcase (v :kind)) '#:keyword)
                           :title (%read-text (v :title)) :body (%read-text (v :body))
                           :link (v :link) :group-key (v :group_key)
                           :count (%int (v :count)) :stamp (%int (v :stamp))
                           :created-at (%int (v :created_at)) :read-at (%int (v :read_at)))))

(defun %insert (c store x &key collapse)
  "Insert X and return the rows RETURNING gives: the one row stored. With COLLAPSE, an unread row
with X's recipient and group key takes X's kind, title, body, link, stamp and created-at and
counts one more instead, in the same statement, and that row is returned (this file's header)."
  (conn:query c (format nil "INSERT INTO ~A (~A) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)~@[ ON CONFLICT (recipient, group_key) WHERE read_at IS NULL AND group_key IS NOT NULL DO UPDATE SET kind = excluded.kind, title = excluded.title, body = excluded.body, link = excluded.link, stamp = excluded.stamp, created_at = excluded.created_at, count = ~A.count + 1~] RETURNING ~A"
                        (%table store) +columns+ (and collapse (%table store)) +columns+)
              (n:notification-id x) (n:notification-recipient x)
              (%kind-name (n:notification-kind x)) (%print (n:notification-title x))
              (and (n:notification-body x) (%print (n:notification-body x)))
              (n:notification-link x) (n:notification-group-key x)
              (n:notification-count x) (n:notification-stamp x)
              (n:notification-created-at x) nil))

;;; --- the protocol -----------------------------------------------------------------------

(defmethod n:notification-put ((store db-notification-store) (x n:notification))
  ;; One statement each way, which returns the row it stored or collapsed into. See this file's
  ;; header for why the keyed one is a single INSERT ... ON CONFLICT.
  (with-connection (c store)
    (%row->notification (first (if (n:notification-group-key x)
                                   (%insert c store x :collapse t)
                                   (%insert c store x))))))

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
  ;; One statement either way, so no reader sees the choice missing between two of them (review
  ;; of #1012). The upsert is the same text on SQLite (3.24 and later) and Postgres.
  (with-connection (c store)
    (if delivery
        (conn:exec c (format nil "INSERT INTO ~A (recipient, kind, delivery) VALUES (?, ?, ?) ON CONFLICT (recipient, kind) DO UPDATE SET delivery = excluded.delivery"
                             (%delivery-table store))
                   recipient (%kind-name kind) (%kind-name delivery))
        (conn:exec c (format nil "DELETE FROM ~A WHERE recipient = ? AND kind = ?" (%delivery-table store))
                   recipient (%kind-name kind))))
  delivery)
