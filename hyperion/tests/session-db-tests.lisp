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

;;; --- a handler's changes are written back (#230) ----------------------------------------
;;;
;;; The DB store hands out a fresh session from every STORE-REF, so until #230 every change a
;;; handler made to its session -- data, sign-in, sign-out, the CSRF token -- was lost on the
;;; next request. Each test below runs through WRAP-SESSION on BOTH stores; the memory store,
;;; which always worked because it shares one object, is the control.

(defclass old-protocol-store ()
  ((table :initform (make-hash-table :test 'equal) :reader ops-table))
  (:documentation "A store written before STORE-SAVE existed: it defines only the old
methods, and copies on the way in and out the way a database-backed store does."))

(defun %ops-copy (s)
  (sess:restore-session (sess:session-id s) :created (sess:session-created s)
                        :accessed (sess:session-accessed s) :data (sess:session-alist s)))
(defmethod sess:store-ref ((s old-protocol-store) id)
  (let ((v (gethash id (ops-table s)))) (and v (%ops-copy v))))
(defmethod sess:store-add ((s old-protocol-store) session)
  (setf (gethash (sess:session-id session) (ops-table s)) (%ops-copy session)) session)
(defmethod sess:store-del ((s old-protocol-store) id) (remhash id (ops-table s)))
(defmethod sess:store-count ((s old-protocol-store)) (hash-table-count (ops-table s)))
(defmethod sess:store-list ((s old-protocol-store))
  (loop for v being the hash-values of (ops-table s) collect (%ops-copy v)))

(defun %call-with-each-store (function)
  "Call FUNCTION with a label and a fresh store: memory, DB (in-memory SQLite), and a store
that defines only the old protocol methods."
  (funcall function :memory (sess:make-memory-store))
  (with-store (s) (funcall function :db s))
  (funcall function :old-protocol (make-instance 'old-protocol-store)))

(defun %cookie-of (res)
  (let ((sc (getf (second res) :set-cookie)))
    (and sc (subseq sc (1+ (position #\= sc)) (position #\; sc)))))

(defun %req (path id &key (method :get) headers)
  (list :request-method method :path-info path :content-length 0
        :headers (let ((ht (make-hash-table :test 'equal)))
                   (when id (setf (gethash "cookie" ht) (format nil "hyperion-session=~a" id)))
                   (loop for (k v) on headers by #'cddr do (setf (gethash k ht) v))
                   ht)))

(defun %body (res) (first (third res)))

(test a-change-a-handler-makes-is-still-there-on-the-next-request
  (%call-with-each-store
   (lambda (kind store)
     (let* ((h (sess:wrap-session
                (lambda (env)
                  (let ((s (sess:request-session env)))
                    (sess:session-set s :n (1+ (or (sess:session-get s :n) 0)))
                    (list 200 nil (list (princ-to-string (sess:session-get s :n))))))
                store))
            (r1 (funcall h (%req "/" nil)))
            (id (%cookie-of r1)))
       (is (equal "2" (%body (funcall h (%req "/" id)))) "~a: second request sees the first's write" kind)
       (is (eql 2 (sess:session-get (sess:store-ref store id) :n)) "~a: and the store holds it" kind)))))

(defun %sign-in-out-app (store how)
  (lambda (env)
    (let ((s (sess:request-session env)) (path (getf env :path-info)))
      (cond ((string= path "/in") (sess:sign-in! store env :user-id 42) (list 200 nil (list "in")))
            ((string= path "/out")
             (ecase how
               (:session-del (sess:session-del s :user-id))
               (:reset-session (sess:reset-session s))
               (:kill-session (sess:kill-session store s)))
             (list 200 nil (list "out")))
            (t (list 200 nil (list (princ-to-string (sess:session-get s :user-id)))))))))

(test sign-in-and-every-sign-out-are-kept-by-the-store
  (dolist (how '(:session-del :reset-session :kill-session))
    (%call-with-each-store
     (lambda (kind store)
       (let* ((h (sess:wrap-session (%sign-in-out-app store how) store))
              (id0 (%cookie-of (funcall h (%req "/" nil))))
              (id (or (%cookie-of (funcall h (%req "/in" id0))) id0)))
         (is (equal "42" (%body (funcall h (%req "/who" id))))
             "~a: SIGN-IN! is kept (sign-out by ~a to follow)" kind how)
         (funcall h (%req "/out" id))
         ;; Computed first: FIVEAM's IS evaluates each argument of its form, so an OR inside
         ;; it would not short-circuit.
         (let* ((after (sess:store-ref store id))
                (user (and after (sess:session-get after :user-id))))
           (is (null user)
               "~a: after sign-out by ~a the store no longer names a user, got ~s" kind how user)))))))

(test a-killed-session-is-not-restored-by-the-write-back
  ;; STORE-SAVE must never insert: a handler that kills its session and then changed it
  ;; (a sign-out that also clears a key) must not have it brought back.
  (%call-with-each-store
   (lambda (kind store)
     (let* ((h (sess:wrap-session
                (lambda (env)
                  (let ((s (sess:request-session env)))
                    (when (string= (getf env :path-info) "/out")
                      (sess:kill-session store s)
                      (sess:session-set s :after-kill t))
                    (list 200 nil (list "ok"))))
                store))
            (id (%cookie-of (funcall h (%req "/" nil)))))
       (funcall h (%req "/out" id))
       (is (null (sess:store-ref store id)) "~a: the killed session stays gone" kind)))))

(test the-csrf-token-a-page-was-given-is-accepted-on-post
  (%call-with-each-store
   (lambda (kind store)
     (let* ((h (sess:wrap-session
                (hyperion/csrf:wrap-csrf
                 (lambda (env)
                   (list 200 nil (list (if (eq (getf env :request-method) :get)
                                           (hyperion/csrf:ensure-token (sess:request-session env))
                                           "posted")))))
                store))
            (r1 (funcall h (%req "/form" nil)))
            (id (%cookie-of r1))
            (r2 (funcall h (%req "/submit" id :method :post :headers (list "x-csrf-token" (%body r1))))))
       (is (= 200 (first r2)) "~a: POST with the page's token, got ~a" kind (first r2))))))

(test accessed-is-written-back-at-most-once-per-interval
  ;; A request that changes nothing but ACCESSED is written only when ACCESSED is at least
  ;; *ACCESSED-SAVE-INTERVAL* past what the store holds.
  (with-store (store)
    (let* ((h (sess:wrap-session (lambda (env) (declare (ignore env)) (list 200 nil (list "r"))) store))
           (id (%cookie-of (funcall h (%req "/" nil))))
           (stored (sess:session-accessed (sess:store-ref store id))))
      (sleep 1.1)
      (let ((sess:*accessed-save-interval* 3600))
        (funcall h (%req "/" id))
        (is (= stored (sess:session-accessed (sess:store-ref store id)))
            "inside the interval, an ACCESSED-only change is not written"))
      (let ((sess:*accessed-save-interval* 0))
        (funcall h (%req "/" id))
        (is (> (sess:session-accessed (sess:store-ref store id)) stored)
            "past the interval, it is")))))

(test a-sign-out-by-changing-the-session-is-kept-after-a-sign-in-that-rotated
  ;; The sign-in here is written by ROTATE-SESSION itself (set, then rotate), so it was kept
  ;; even before #230; the sign-out, a change to the session, was not. This isolates the
  ;; sign-out: the other test's SIGN-IN! failed first on the DB store, which hid it.
  (dolist (how '(:session-del :reset-session))
    (%call-with-each-store
     (lambda (kind store)
       (let* ((h (sess:wrap-session
                  (lambda (env)
                    (let ((s (sess:request-session env)) (path (getf env :path-info)))
                      (cond ((string= path "/in")
                             (sess:session-set s :user-id 42)
                             (sess:rotate-session store s)
                             (list 200 nil (list "in")))
                            ((string= path "/out")
                             (ecase how
                               (:session-del (sess:session-del s :user-id))
                               (:reset-session (sess:reset-session s)))
                             (list 200 nil (list "out")))
                            (t (list 200 nil (list (princ-to-string (sess:session-get s :user-id))))))))
                  store))
              (id0 (%cookie-of (funcall h (%req "/" nil))))
              (id (or (%cookie-of (funcall h (%req "/in" id0))) id0)))
         (is (equal "42" (%body (funcall h (%req "/who" id)))) "~a: signed in" kind)
         (funcall h (%req "/out" id))
         (is (equal "NIL" (%body (funcall h (%req "/who" id))))
             "~a: signed out by ~a on the next request" kind how))))))

;;; --- server-side expiry (#121) ---------------------------------------------------------
;;;
;;; Time is controlled by writing CREATED and ACCESSED on a stored session, never by sleeping.
;;; Each test runs on the memory store, the DB store, and a store defining only the old
;;; protocol, which exercises the default STORE-SWEEP.

(defun %age (store id &key accessed-ago created-ago)
  "Set session ID's ACCESSED and/or CREATED in STORE to that many seconds ago."
  (let ((s (sess:store-ref store id)) (now (get-universal-time)))
    (when accessed-ago (setf (sess:session-accessed s) (- now accessed-ago)))
    (when created-ago (setf (sess:session-created s) (- now created-ago)))
    (sess:store-add store s)))

(defun %echo-id-app ()
  (lambda (env) (list 200 nil (list (sess:session-id (sess:request-session env))))))

(test an-expired-session-is-refused-even-when-no-sweep-has-run
  ;; Where correctness lives: with sweeping off, a request presenting an expired session must
  ;; get a NEW session, and the old one must be gone.
  (dolist (limit '(:idle :absolute))
    (%call-with-each-store
     (lambda (kind store)
       (let* ((sess:*session-sweep-interval* nil)
              (h (sess:wrap-session (%echo-id-app) store))
              (old (%cookie-of (funcall h (%req "/" nil)))))
         (ecase limit
           (:idle (%age store old :accessed-ago (1+ sess:*session-idle-timeout*)))
           (:absolute (%age store old :created-ago (1+ sess:*session-absolute-timeout*)
                                      :accessed-ago 0)))
         (let* ((r (funcall h (%req "/" old)))
                (new (%cookie-of r)))
           (is-true new "~a/~a: a new session is minted" kind limit)
           (is (and new (not (equal new old))) "~a/~a: under a different id" kind limit)
           (is (equal new (%body r)) "~a/~a: and it is the one the handler got" kind limit)
           (is (null (sess:store-ref store old)) "~a/~a: the expired one is deleted" kind limit)))))))

(test a-session-inside-both-limits-is-kept
  ;; The control for the test above.
  (%call-with-each-store
   (lambda (kind store)
     (let* ((sess:*session-sweep-interval* nil)
            (h (sess:wrap-session (%echo-id-app) store))
            (id (%cookie-of (funcall h (%req "/" nil)))))
       (%age store id :accessed-ago (- sess:*session-idle-timeout* 60)
                      :created-ago (- sess:*session-absolute-timeout* 60))
       (let ((r (funcall h (%req "/" id))))
         (is (null (%cookie-of r)) "~a: no new session" kind)
         (is (equal id (%body r)) "~a: the same session" kind))))))

(test a-sweep-removes-expired-sessions-and-keeps-the-rest
  (%call-with-each-store
   (lambda (kind store)
     (let* ((sess:*session-sweep-interval* nil)
            (h (sess:wrap-session (%echo-id-app) store))
            (idle (%cookie-of (funcall h (%req "/" nil))))
            (old (%cookie-of (funcall h (%req "/" nil))))
            (fresh (%cookie-of (funcall h (%req "/" nil)))))
       (%age store idle :accessed-ago (1+ sess:*session-idle-timeout*))
       (%age store old :created-ago (1+ sess:*session-absolute-timeout*) :accessed-ago 0)
       (is (= 2 (sess:sweep-sessions store)) "~a: two removed" kind)
       (is (null (sess:store-ref store idle)) "~a: idle one gone" kind)
       (is (null (sess:store-ref store old)) "~a: too-old one gone" kind)
       (is-true (sess:store-ref store fresh) "~a: fresh one kept" kind)))))

(test wrap-session-sweeps-when-due-and-not-before
  ;; A sweep that is never called and one that reaps nothing look the same at the exit code,
  ;; so this checks the call: an expired session held by NO request is removed only by a sweep.
  (%call-with-each-store
   (lambda (kind store)
     (let* ((sess:*session-sweep-interval* 3600)
            (h (sess:wrap-session (%echo-id-app) store))
            (idle (%cookie-of (funcall h (%req "/" nil)))))   ; first request sweeps (nothing due)
       (%age store idle :accessed-ago (1+ sess:*session-idle-timeout*))
       (funcall h (%req "/" nil))
       (is-true (sess:store-ref store idle) "~a: inside the interval, no sweep" kind)
       (let ((sess:*session-sweep-interval* 0))
         (funcall h (%req "/" nil)))
       (is (null (sess:store-ref store idle)) "~a: once due, the sweep removes it" kind)))))

(test sign-in-starts-a-new-absolute-window-and-a-plain-rotation-does-not
  (%call-with-each-store
   (lambda (kind store)
     (let* ((sess:*session-sweep-interval* nil)
            (h (sess:wrap-session
                (lambda (env)
                  (let ((s (sess:request-session env)) (path (getf env :path-info)))
                    (cond ((string= path "/sign-in") (sess:sign-in! store env :user-id 1))
                          ((string= path "/rotate") (sess:rotate-session store s))
                          ((string= path "/step-up") (sess:rotate-session store s :reset-created t)))
                    (list 200 nil (list (sess:session-id s)))))
                store))
            (day 86400))
       (dolist (case '(("/sign-in" t) ("/rotate" nil) ("/step-up" t)))
         (destructuring-bind (path resets) case
           (let ((id (%cookie-of (funcall h (%req "/" nil)))))
             (%age store id :created-ago day :accessed-ago 0)
             (let* ((new (%body (funcall h (%req path id))))
                    (age (- (get-universal-time) (sess:session-created (sess:store-ref store new)))))
               (if resets
                   (is (< age 60) "~a: ~a starts a new absolute window (age ~a)" kind path age)
                   (is (>= age day) "~a: ~a keeps the absolute window (age ~a)" kind path age))))))))))

(test a-nil-timeout-disables-that-limit
  (%call-with-each-store
   (lambda (kind store)
     (let* ((sess:*session-sweep-interval* nil)
            (sess:*session-idle-timeout* nil)
            (sess:*session-absolute-timeout* nil)
            (h (sess:wrap-session (%echo-id-app) store))
            (id (%cookie-of (funcall h (%req "/" nil)))))
       (%age store id :accessed-ago (* 400 86400) :created-ago (* 400 86400))
       (is (equal id (%body (funcall h (%req "/" id)))) "~a: kept with both limits off" kind)
       (is (zerop (sess:sweep-sessions store)) "~a: and not swept" kind)))))

(defclass stampless-store (old-protocol-store) ()
  (:documentation "A hand-written store that restores sessions WITHOUT their timestamps --
the mistake RESTORE-SESSION's docstring warns about."))
(defmethod sess:store-ref ((s stampless-store) id)
  (let ((v (gethash id (ops-table s))))
    (and v (sess:restore-session (sess:session-id v) :data (sess:session-alist v)))))

(test a-store-that-drops-the-timestamps-has-every-session-refused
  ;; The trap, shown rather than described: CREATED and ACCESSED default to 0, so every
  ;; session such a store returns reads as last used in 1900 and is refused. The fix is to
  ;; persist and pass both; until then an app can set both timeouts to NIL.
  (let* ((store (make-instance 'stampless-store))
         (sess:*session-sweep-interval* nil)
         (h (sess:wrap-session (%echo-id-app) store))
         (id (%cookie-of (funcall h (%req "/" nil)))))
    (let ((again (%cookie-of (funcall h (%req "/" id)))))
      (is (and again (not (equal again id)))
          "the session came back without timestamps and was refused as expired"))
    ;; A fresh session, because the refusal above deleted the first one.
    (let* ((sess:*session-idle-timeout* nil)
           (sess:*session-absolute-timeout* nil)
           (fresh (%cookie-of (funcall h (%req "/" nil))))
           (kept (funcall h (%req "/" fresh))))
      (is (null (%cookie-of kept)) "with both limits off, it is kept")
      (is (equal fresh (%body kept))))))
