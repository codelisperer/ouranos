;;;; session-db-tests.lisp --- integration tests for the mnemosyne-backed session store.
;;;;
;;;; Its own package + system (hyperion/session-db/tests) so the core Hyperion suite keeps
;;;; no database dependency. Runs against an in-memory SQLite (one connection, so state
;;;; persists across ops within a test).

(cl:defpackage #:hyperion/session-db/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:sess #:hyperion/session)
                    (#:sdb  #:hyperion/session-db)
                    (#:conn #:mnemosyne/conn)
                    (#:be   #:mnemosyne/backend))
  (:export #:run-tests))

(in-package #:hyperion/session-db/tests)

(def-suite session-db :description "mnemosyne-backed durable session store.")
(defun run-tests () (run! 'session-db))

(in-suite session-db)

(defmacro with-store ((var) &body body)
  "Bind VAR to a fresh in-memory-SQLite-backed store (table ensured); disconnect after."
  (let ((c (gensym)))
    `(let ((,c (conn:connect (be:make-sqlite ":memory:"))))
       (unwind-protect
            (let ((,var (sdb:make-db-store ,c :dialect :sqlite :ensure t)))
              ,@body)
         (conn:disconnect ,c)))))

(defun %sess (id &key (created 100) (accessed 200) data)
  (sess:restore-session id :created created :accessed accessed :data data))

(test add-and-ref-round-trips-data
  (with-store (s)
    (sess:store-add s (%sess "abc" :created 100 :accessed 200
                                   :data '((:user-id . 42) (:role . "admin"))))
    (let ((got (sess:store-ref s "abc")))
      (is (string= "abc" (sess:session-id got)))
      (is (eql 42 (sess:session-get got :user-id)))
      (is (string= "admin" (sess:session-get got :role)))
      (is (eql 100 (sess:session-created got)))
      (is (eql 200 (sess:session-accessed got))))))

(test ref-missing-is-nil
  (with-store (s) (is (null (sess:store-ref s "nope")))))

(test count-and-list
  (with-store (s)
    (sess:store-add s (%sess "a"))
    (sess:store-add s (%sess "b"))
    (is (= 2 (sess:store-count s)))
    (is (equal '("a" "b") (sort (mapcar #'sess:session-id (sess:store-list s)) #'string<)))))

(test add-upserts-on-id                  ; re-adding same id updates in place, not a duplicate
  (with-store (s)
    (sess:store-add s (%sess "abc" :accessed 200 :data '((:role . "admin"))))
    (sess:store-add s (%sess "abc" :accessed 999 :data '((:role . "owner"))))
    (is (= 1 (sess:store-count s)))
    (let ((got (sess:store-ref s "abc")))
      (is (string= "owner" (sess:session-get got :role)))
      (is (eql 999 (sess:session-accessed got))))))

(test del-returns-boolean-and-removes
  (with-store (s)
    (sess:store-add s (%sess "a"))
    (is (eq t (sess:store-del s "a")))
    (is (null (sess:store-del s "a")))     ; already gone
    (is (= 0 (sess:store-count s)))))

(test empty-data-bag-survives
  (with-store (s)
    (sess:store-add s (%sess "e" :data nil))
    (let ((got (sess:store-ref s "e")))
      (is (null (sess:session-keys got))))))
