;;;; notifications-db-tests.lisp --- hyperion/notifications-db on SQLite, and on Postgres when it is there (#792).

(cl:defpackage #:hyperion/notifications-db/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:n #:hyperion/notifications)
                    (#:ndb #:hyperion/notifications-db)
                    (#:conn #:mnemosyne/conn)
                    (#:be #:mnemosyne/backend)
                    (#:url #:mnemosyne/url))
  (:export #:run-tests))

(in-package #:hyperion/notifications-db/tests)

(def-suite notifications-db :description "hyperion/notifications-db on SQLite.")
(def-suite notifications-db-postgres :description "The same checks on Postgres.")
;; Plain TEST forms below belong to the SQLite suite. Without this they went to FiveAM's default
;; suite, which RUN-TESTS does not run, so they never ran in the gate.
(in-suite notifications-db)

(n:define-notification-kind :db-test-reply :default :in-app)
(n:define-notification-kind :db-test-alert :default :both)

(defun %pg-url () (uiop:getenv "MNEMOSYNE_TEST_PG_URL"))

(defun run-tests ()
  "Run the SQLite and Postgres suites and print the Postgres coverage in the form
scripts/verify-tree.lisp reads."
  (let* ((sqlite (run 'notifications-db))
         (postgres (run 'notifications-db-postgres))
         (all (append sqlite postgres)))
    (explain! all)
    (if (%pg-url)
        (format t "~&BACKEND-CHECKS postgres ~D~%"
                (count-if-not (lambda (r) (typep r 'fiveam::test-skipped)) postgres))
        (format t "~&BACKEND-CHECKS postgres SKIPPED (MNEMOSYNE_TEST_PG_URL is not set)~%"))
    (finish-output)
    (results-status all)))

(defun %suffix () (format nil "~36R" (random (expt 36 8) (make-random-state t))))

(defun call-with-sqlite (function)
  (let ((c (conn:connect (be:make-sqlite ":memory:"))))
    (unwind-protect (funcall function c "hyperion_notifications" "hyperion_notification_delivery")
      (conn:disconnect c))))

(defun call-with-postgres (function)
  (if (not (%pg-url))
      (skip "MNEMOSYNE_TEST_PG_URL is not set -- this says nothing about Postgres")
      (let* ((c (conn:connect (url:backend-from-url (%pg-url))))
             (suffix (string-downcase (%suffix)))
             (table (format nil "hn_~A" suffix))
             (delivery (format nil "hnd_~A" suffix)))
        (unwind-protect (funcall function c table delivery)
          (ignore-errors (conn:exec c (format nil "DROP TABLE IF EXISTS ~A" table)))
          (ignore-errors (conn:exec c (format nil "DROP TABLE IF EXISTS ~A" delivery)))
          (conn:disconnect c)))))

(defmacro backend-test (name (store c) &body body)
  "Define NAME/SQLITE and NAME/POSTGRES, each running BODY with STORE a notification store whose
tables were just made, over C."
  (let ((doc (and (stringp (first body)) (rest body) (list (first body))))
        (body (if (and (stringp (first body)) (rest body)) (rest body) body))
        (table (gensym)) (delivery (gensym)))
    `(progn
       (test (,(intern (format nil "~A/SQLITE" name)) :suite notifications-db)
         ,@doc
         (call-with-sqlite
          (lambda (,c ,table ,delivery)
            (let ((,store (ndb:make-db-notification-store ,c :table ,table :delivery-table ,delivery
                                                             :ensure t)))
              (declare (ignorable ,store))
              ,@body))))
       (test (,(intern (format nil "~A/POSTGRES" name)) :suite notifications-db-postgres)
         ,@doc
         (call-with-postgres
          (lambda (,c ,table ,delivery)
            (let ((,store (ndb:make-db-notification-store ,c :table ,table :delivery-table ,delivery
                                                             :ensure t)))
              (declare (ignorable ,store))
              ,@body)))))))

(defun %put (store recipient title &rest keys)
  (n:notification-put store (apply #'n:make-notification recipient :db-test-reply :title title keys)))

;;; --- the tables -------------------------------------------------------------------------

(test a-store-refuses-to-start-without-its-tables-and-names-the-migrations
  (call-with-sqlite
   (lambda (c table delivery)
     (declare (ignore table delivery))
     (let ((e (handler-case (progn (ndb:make-db-notification-store c) nil)
                (ndb:missing-notification-tables (e) e))))
       (is (typep e 'ndb:missing-notification-tables))
       (let ((report (and e (princ-to-string e))))
         (is (search "notifications-ddl" report) "~A" report)
         (is (search "notifications-unread-key-ddl" report) "~A" report)
         (is (search "delivery-ddl" report) "~A" report)))
     (is (typep (ndb:make-db-notification-store c :require-tables nil) 'ndb:db-notification-store)
         ":require-tables nil skips the check")))
  (signals error (ndb:notifications-ddl :table "x; drop table y")))

;;; --- the protocol -----------------------------------------------------------------------

(backend-test an-item-round-trips-with-its-title-key-body-and-link (s c)
  (let ((put (%put s "u1" '(:key :app/reply :args (:who "Ann")) :body "a body" :link "/t/1")))
    (let ((got (first (n:notification-list s "u1"))))
      (is (equal (n:notification-id put) (n:notification-id got)))
      (is (equal '(:key :app/reply :args (:who "Ann")) (n:notification-title got)))
      (is (equal "a body" (n:notification-body got)))
      (is (equal "/t/1" (n:notification-link got)))
      (is (eq :db-test-reply (n:notification-kind got)))
      (is (= 1 (n:notification-count got)))
      (is (null (n:notification-read-at got))))))

(backend-test a-notification-with-the-key-of-an-unread-item-collapses-into-it (s c)
  (let* ((first (%put s "u1" "one" :group-key "g"))
         (second (%put s "u1" "two" :group-key "g")))
    (is (equal (n:notification-id first) (n:notification-id second)))
    (is (= 2 (n:notification-count second)))
    (is (equal "two" (n:notification-title second)))
    (is (= 1 (n:unread-count s "u1")))
    (n:mark-read s "u1" (n:notification-id first))
    (let ((third (%put s "u1" "three" :group-key "g")))
      (is (not (equal (n:notification-id first) (n:notification-id third))))
      (is (= 1 (n:notification-count third))))
    (%put s "u1" "no key")
    (%put s "u1" "no key")
    (is (= 3 (n:unread-count s "u1")) "items without a key never collapse")))

(backend-test the-unread-key-index-allows-one-unread-item-per-key (s c)
  "What makes collapsing safe when two calls race: a second unread row with the same recipient
and key cannot be inserted, while a read one does not block a new one."
  (let ((first (%put s "u1" "one" :group-key "g")))
    (signals conn:db-error
      (ndb::%insert c s (n:make-notification "u1" :db-test-reply :title "dup" :group-key "g")))
    (n:mark-read s "u1" (n:notification-id first))
    (finishes (ndb::%insert c s (n:make-notification "u1" :db-test-reply :title "new" :group-key "g")))))

(backend-test an-unread-row-another-writer-inserted-is-collapsed-into (s c)
  "The row a concurrent call inserted is collapsed into, in the same statement that would have
inserted (one INSERT ... ON CONFLICT). The competing row is inserted directly here."
  (ndb::%insert c s (n:make-notification "u1" :db-test-reply :title "won" :group-key "g"))
  (let ((stored (%put s "u1" "second" :group-key "g")))
    (is (= 2 (n:notification-count stored)) "collapsed into the other writer's row")
    (is (equal "second" (n:notification-title stored)))
    (is (= 1 (n:unread-count s "u1")))))

(backend-test another-unique-violation-reaches-the-caller (s c)
  "Putting a notification again under an id already stored, after its row was read so there is
nothing unread to collapse into, breaks the primary key, and that error reaches the caller: the
ON CONFLICT clause names only the unread-key index. The hub's review of #1012."
  (let ((x (n:make-notification "u1" :db-test-reply :title "once" :group-key "g")))
    (n:notification-put s x)
    (n:mark-read s "u1" (n:notification-id x))
    (signals conn:db-error (n:notification-put s x))
    (is (= 0 (n:unread-count s "u1")) "nothing was added"))
  (let ((y (n:make-notification "u1" :db-test-reply :title "keyless")))
    (n:notification-put s y)
    (signals conn:db-error (n:notification-put s y) "a keyless one too, as the memory store does")))

(backend-test a-title-that-no-longer-reads-back-is-shown-as-its-text (s c)
  "The hub's review of #1012: a row is built as it is stored, not through MAKE-NOTIFICATION. A
title whose key's package is gone does not read back; it is shown as the stored text, and the
recipient's list still works."
  (%put s "u1" "fine")
  (conn:exec c (format nil "UPDATE ~A SET title = ? WHERE title = ?" (ndb::%table s))
             "(:KEY NO-SUCH-PACKAGE-1012::KEY :ARGS NIL)" (ndb::%print "fine"))
  (let ((items (n:notification-list s "u1")))
    (is (= 1 (length items)))
    (is (equal "(:KEY NO-SUCH-PACKAGE-1012::KEY :ARGS NIL)" (n:notification-title (first items)))
        "~S" (n:notification-title (first items)))))

(test a-database-error-other-than-the-conflict-is-not-swallowed
  "A trigger here refuses the insert with its own message; that error reaches the caller as it
is."
  (call-with-sqlite
   (lambda (c table delivery)
     (let ((s (ndb:make-db-notification-store c :table table :delivery-table delivery :ensure t)))
       (conn:exec c (format nil "CREATE TRIGGER refuse_insert BEFORE INSERT ON ~A BEGIN SELECT RAISE(ABORT, 'refused by the test'); END"
                            table))
       (let ((e (handler-case (progn (%put s "u1" "x" :group-key "g") nil)
                  (error (e) e))))
         (is (typep e 'conn:db-error) "got ~S" e)
         (is (search "refused by the test" (princ-to-string e)) "the insert's own error: ~A" e))))))

(test table-names-are-ascii-and-short-enough-for-their-index-names
  "The hub's review of #1012: Postgres cuts identifiers to 63 bytes, and uq_TABLE_unread_group
adds 16 to TABLE, so a table name is at most 47 characters. Non-ASCII letters are refused, since
Postgres folds their case by the server's locale."
  (flet ((refused (name)
           (signals error (ndb:notifications-ddl :table name))))
    (refused (make-string 48 :initial-element #\a))
    (refused (format nil "caf~C" (code-char #xe9)))
    (refused "1table")
    (refused "a-b")
    (refused ""))
  (is (stringp (ndb:notifications-ddl :table (make-string 47 :initial-element #\a))) "47 is allowed")
  (is (stringp (ndb:notifications-ddl :table "App_Notifications_2")) "letters, digits, underscores"))

(test (a-put-inside-an-app-transaction-waits-for-a-concurrent-unread-row
      :suite notifications-db-postgres)
  "The hub's review of #1012, on Postgres: another connection holds an uncommitted unread row
with the same key while the store, inside the app's own transaction, puts a notification. The
put waits for that transaction and then collapses into the row. Before, its insert was refused
with 23505, which aborted the app's transaction, and the retry failed with 25P02."
  (call-with-postgres
   (lambda (c table delivery)
     (let* ((s (ndb:make-db-notification-store c :table table :delivery-table delivery :ensure t))
            (other (conn:connect (url:backend-from-url (%pg-url))))
            (inserted (sb-thread:make-semaphore))
            (release (sb-thread:make-semaphore))
            (writer (sb-thread:make-thread
                     (lambda ()
                       (conn:with-transaction (other)
                         (ndb::%insert other s (n:make-notification "u1" :db-test-reply
                                                                         :title "other" :group-key "g"))
                         (sb-thread:signal-semaphore inserted)
                         (sb-thread:wait-on-semaphore release :timeout 30)))
                     :name "notifications-db test: the other writer")))
       (unwind-protect
            (progn
              (is-true (sb-thread:wait-on-semaphore inserted :timeout 30))
              ;; The other transaction commits half a second after the put has started waiting.
              (sb-thread:make-thread (lambda () (sleep 0.5) (sb-thread:signal-semaphore release))
                                     :name "notifications-db test: release")
              (let ((stored (conn:with-transaction (c) (%put s "u1" "mine" :group-key "g"))))
                (is (= 2 (n:notification-count stored)) "collapsed into the committed row")
                (is (equal "mine" (n:notification-title stored)))
                (is (= 1 (n:unread-count s "u1")))))
         (sb-thread:signal-semaphore release)
         (ignore-errors (sb-thread:join-thread writer :timeout 30))
         (conn:disconnect other))))))

(backend-test the-list-is-newest-first-and-pages (s c)
  (dotimes (i 5) (%put s "u1" (format nil "n~D" i)))
  (multiple-value-bind (page more) (n:notification-list s "u1" :limit 2)
    (is (equal '("n4" "n3") (mapcar #'n:notification-title page)))
    (is-true more)
    (is (equal '("n2" "n1")
               (mapcar #'n:notification-title
                       (n:notification-list s "u1" :limit 2
                                                   :before (n:notification-stamp (second page)))))))
  (n:mark-read s "u1" (n:notification-id (first (n:notification-list s "u1" :limit 1))))
  (is (= 4 (length (n:notification-list s "u1" :unread-only t)))))

(backend-test a-recipient-cannot-mark-another-recipients-item (s c)
  (let ((theirs (%put s "u2" "private")))
    (is (null (n:notification-list s "u1")))
    (is-false (n:mark-read s "u1" (n:notification-id theirs)))
    (is (= 1 (n:unread-count s "u2")))
    (is-true (n:mark-read s "u2" (n:notification-id theirs)))
    (is-false (n:mark-read s "u2" (n:notification-id theirs)))))

(backend-test mark-all-read-and-prune (s c)
  (dotimes (i 3) (%put s "u1" "x"))
  (is (= 3 (n:mark-all-read s "u1")))
  (%put s "u1" "unread")
  (let ((future (+ (get-universal-time) 10)))
    (is (= 3 (n:prune-notifications s :read-before future)))
    (is (= 1 (n:unread-count s "u1")))
    (is (= 1 (n:prune-notifications s :read-before future :unread-before future)))
    (is (= 0 (n:unread-count s "u1")))))

(backend-test delivery-choices-are-kept-per-recipient-and-kind (s c)
  (is (null (n:delivery-ref s "u1" :db-test-reply)))
  (n:delivery-set s "u1" :db-test-reply :email)
  (n:delivery-set s "u1" :db-test-reply :none)
  (is (eq :none (n:delivery-ref s "u1" :db-test-reply)) "the latest choice")
  (is (null (n:delivery-ref s "u2" :db-test-reply)) "and only for that recipient")
  (n:delivery-set s "u1" :db-test-reply nil)
  (is (null (n:delivery-ref s "u1" :db-test-reply)))
  (signals n:invalid-notification (n:delivery-set s "u1" :db-test-reply :sms))
  (let ((emails 0))
    (n:delivery-set s "u1" :db-test-alert :both)
    (is-true (n:notify s "u1" :db-test-alert :title "x" :email (lambda (r x) (declare (ignore r x))
                                                                 (incf emails))))
    (is (= 1 emails))))
