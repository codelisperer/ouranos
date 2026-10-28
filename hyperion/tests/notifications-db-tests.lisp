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
