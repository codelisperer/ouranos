;;;; notifications-tests.lisp --- in-app notifications on the memory store (#792).

(defpackage #:hyperion/notifications/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:n #:hyperion/notifications)
                    (#:router #:hyperion/router)
                    (#:spin #:spinneret))
  (:export #:run-tests #:notifications))

(in-package #:hyperion/notifications/tests)

(def-suite notifications :description "hyperion/notifications: the store, notify, the components and routes (#792).")
(in-suite notifications)

(n:define-notification-kind :test-reply :default :in-app :label "Replies")
(n:define-notification-kind :test-digest :default :email)
(n:define-notification-kind :test-alert :default :both)

(defun %html (thunk)
  (let ((*print-pretty* nil))
    (spin:with-html-string (funcall thunk))))

(defun %put (store recipient title &rest keys &key (kind :test-reply) &allow-other-keys)
  (remf keys :kind)
  (n:notification-put store (apply #'n:make-notification recipient kind :title title keys)))

;;; --- the record ---------------------------------------------------------------------------

(test a-notification-link-must-be-a-path-on-this-site
  (dolist (link '("/" "/tickets/42" "/a?b=c#d"))
    (is (equal link (n:notification-link (n:make-notification "u1" :test-reply :title "t" :link link)))
        "~S is accepted" link))
  (dolist (link (list "//elsewhere.test/x" "https://elsewhere.test/" "javascript:alert(1)"
                      "tickets/42" "/\\elsewhere.test" "/a\\b" (format nil "/a~Cb" #\Newline) ""))
    (signals n:invalid-notification (n:make-notification "u1" :test-reply :title "t" :link link))))

(test a-notification-is-checked-when-it-is-made
  (signals n:invalid-notification (n:make-notification "" :test-reply :title "t"))
  (signals n:invalid-notification (n:make-notification "u1" "reply" :title "t"))
  (signals n:invalid-notification (n:make-notification "u1" :test-reply :title nil))
  (signals n:invalid-notification (n:make-notification "u1" :test-reply :title '(:key :x :args (:a))))
  (signals n:invalid-notification (n:make-notification "u1" :test-reply :title "t" :body 3))
  (signals n:invalid-notification (n:make-notification "u1" :test-reply :title "t" :group-key ""))
  (let ((x (n:make-notification "u1" :test-reply :title '(:key :app/reply :args (:who "Ann"))
                                                 :body "b" :group-key "g")))
    (is (= 1 (n:notification-count x)))
    (is (null (n:notification-read-at x)))
    (is (= 36 (length (n:notification-id x))) "a UUID")))

;;; --- the store ----------------------------------------------------------------------------

(test a-notification-with-the-key-of-an-unread-item-collapses-into-it
  (let* ((s (n:make-memory-notification-store))
         (first (%put s "u1" "one reply" :group-key "ticket-42" :link "/t/42")))
    (let ((second (%put s "u1" "two replies" :group-key "ticket-42" :link "/t/42#r2")))
      (is (equal (n:notification-id first) (n:notification-id second)) "it keeps its id")
      (is (= 2 (n:notification-count second)))
      (is (equal "two replies" (n:notification-title second)) "and takes the new text")
      (is (equal "/t/42#r2" (n:notification-link second)) "and the new link")
      (is (> (n:notification-stamp second) (n:notification-stamp first)) "and the new time"))
    (is (= 1 (length (n:notification-list s "u1"))))
    (is (= 1 (n:unread-count s "u1")) "a collapsed item counts once")
    (n:mark-read s "u1" (n:notification-id first))
    (let ((third (%put s "u1" "a new reply" :group-key "ticket-42")))
      (is (not (equal (n:notification-id first) (n:notification-id third)))
          "once read, the next one with the key is a new item")
      (is (= 1 (n:notification-count third))))
    (%put s "u2" "other user" :group-key "ticket-42")
    (is (= 1 (n:unread-count s "u2")) "a key collapses only within one recipient")))

(test a-notification-without-a-key-never-collapses
  (let ((s (n:make-memory-notification-store)))
    (%put s "u1" "a")
    (%put s "u1" "a")
    (is (= 2 (n:unread-count s "u1")))))

(test the-list-is-newest-first-and-pages
  (let ((s (n:make-memory-notification-store)))
    (dotimes (i 5) (%put s "u1" (format nil "n~D" i)))
    (multiple-value-bind (page more) (n:notification-list s "u1" :limit 2)
      (is (equal '("n4" "n3") (mapcar #'n:notification-title page)))
      (is-true more)
      (multiple-value-bind (next more2)
          (n:notification-list s "u1" :limit 2 :before (n:notification-stamp (second page)))
        (is (equal '("n2" "n1") (mapcar #'n:notification-title next)))
        (is-true more2))
      (multiple-value-bind (last more3) (n:notification-list s "u1" :limit 10)
        (is (= 5 (length last)))
        (is-false more3)))
    (n:mark-read s "u1" (n:notification-id (first (n:notification-list s "u1" :limit 1))))
    (is (equal '("n3" "n2" "n1" "n0")
               (mapcar #'n:notification-title (n:notification-list s "u1" :unread-only t))))))

(test a-recipient-cannot-read-or-mark-another-recipients-item
  (let* ((s (n:make-memory-notification-store))
         (theirs (%put s "u2" "private")))
    (is (null (n:notification-list s "u1")))
    (is-false (n:mark-read s "u1" (n:notification-id theirs)) "u1 marking u2's id does nothing")
    (is (= 1 (n:unread-count s "u2")) "and u2's item is still unread")
    (is-true (n:mark-read s "u2" (n:notification-id theirs)))
    (is-false (n:mark-read s "u2" (n:notification-id theirs)) "already read")))

(test mark-all-read-and-prune
  (let ((s (n:make-memory-notification-store)))
    (dotimes (i 3) (%put s "u1" "x"))
    (is (= 3 (n:mark-all-read s "u1")))
    (is (= 0 (n:mark-all-read s "u1")))
    (%put s "u1" "unread")
    (let ((future (+ (get-universal-time) 10)))
      (is (= 0 (n:prune-notifications s :read-before (- (get-universal-time) 10)))
          "nothing was read that long ago")
      (is (= 3 (n:prune-notifications s :read-before future)) "the three read ones")
      (is (= 1 (n:unread-count s "u1")) "unread items stay without UNREAD-BEFORE")
      (is (= 1 (n:prune-notifications s :read-before future :unread-before future))))))

;;; --- delivery -----------------------------------------------------------------------------

(defun %notify-with-delivery (delivery &key (kind :test-reply) choose)
  "Notify u1 once with KIND, after recording DELIVERY as u1's choice when CHOOSE. Returns
(values STORED EMAILS STORE)."
  (let ((s (n:make-memory-notification-store)) (emails '()))
    (when choose (n:delivery-set s "u1" kind delivery))
    (let ((stored (n:notify s "u1" kind :title "hello"
                                        :email (lambda (recipient x) (push (list recipient x) emails)))))
      (values stored emails s))))

(test each-delivery-goes-where-it-says
  (flet ((where (delivery)
           (multiple-value-bind (stored emails s) (%notify-with-delivery delivery :choose t)
             (list (and stored t) (length emails) (n:unread-count s "u1")))))
    (is (equal '(t 0 1) (where :in-app)))
    (is (equal '(nil 1 0) (where :email)))
    (is (equal '(t 1 1) (where :both)))
    (is (equal '(nil 0 0) (where :none)))))

(test without-a-choice-the-kinds-default-applies
  (multiple-value-bind (stored emails) (%notify-with-delivery nil :kind :test-digest)
    (is (null stored)) (is (= 1 (length emails))))
  (multiple-value-bind (stored emails) (%notify-with-delivery nil :kind :test-alert)
    (is-true stored) (is (= 1 (length emails))))
  (let ((s (n:make-memory-notification-store)))
    (n:delivery-set s "u1" :test-digest :none)
    (is (eq :none (n:delivery-ref s "u1" :test-digest)))
    (n:delivery-set s "u1" :test-digest nil)
    (is (null (n:delivery-ref s "u1" :test-digest)) "NIL forgets the choice")))

(test an-unknown-kind-or-delivery-is-refused
  (let ((s (n:make-memory-notification-store)))
    (signals n:unknown-notification-kind (n:notify s "u1" :test-misspelt :title "x"))
    (signals n:unknown-notification-kind (n:delivery-set s "u1" :test-misspelt :in-app))
    (signals n:invalid-notification (n:delivery-set s "u1" :test-reply :sms))
    (signals n:invalid-notification (n:define-notification-kind :test-bad :default :sms))))

(test a-failed-email-keeps-the-in-app-item
  (let ((s (n:make-memory-notification-store)) (signalled nil))
    (n:delivery-set s "u1" :test-alert :both)
    (let ((stored (handler-bind ((n:notification-email-failed
                                   (lambda (c)
                                     (setf signalled (n:notification-email-failed-kind c))
                                     (invoke-restart 'continue))))
                    (n:notify s "u1" :test-alert :title "x"
                                                 :email (lambda (r x) (declare (ignore r x))
                                                          (error "the mail server is down"))))))
      (is (eq :test-alert signalled) "the failure is signalled")
      (is-true stored "and NOTIFY returns the stored item after CONTINUE")
      (is (= 1 (n:unread-count s "u1")) "which is in the list")))
  (let ((s (n:make-memory-notification-store)))
    (signals n:notification-email-failed
      (n:notify s "u1" :test-digest :title "x" :email nil))))

;;; --- the components -----------------------------------------------------------------------

(test the-bell-names-the-count-in-a-status-region-and-polls-with-it
  (let ((html (%html (lambda () (n:notification-bell 3 :prefix "/notes" :poll-seconds 30)))))
    (is (search "aria-label=\"3 unread notifications\"" html) "~A" html)
    (is (search "role=status aria-live=polite>3 unread notifications<" html) "~A" html)
    (is (search "hx-get=\"/notes/count?seen=3\"" html) "~A" html)
    (is (search "hx-trigger=\"every 30s\"" html) "~A" html)
    (is (search "hx-swap=none" html) "the poll swaps only out of band: ~A" html)
    (is (null (search "load" html)) "and never triggers on load: ~A" html))
  (is (search "1 unread notification\""
              (%html (lambda () (n:notification-bell 1)))) "one, singular")
  (dolist (bad '(0 -1 1.5 "60s" 86401))
    (signals n:invalid-notification (%html (lambda () (n:notification-bell 0 :poll-seconds bad))))))

(test the-panel-lists-items-with-their-buttons-and-escapes-their-text
  (let* ((s (n:make-memory-notification-store))
         (a (%put s "u1" "<b>bold</b>" :link "/t/1" :body "body & more"))
         (b (%put s "u1" "grouped" :group-key "g")))
    (%put s "u1" "grouped again" :group-key "g")
    (n:mark-read s "u1" (n:notification-id a))
    (let ((html (%html (lambda () (n:notification-panel (n:notification-list s "u1") :more t
                                                                                     :prefix "/notes")))))
      (is (search "&lt;b&gt;bold&lt;/b&gt;" html) "the title is escaped: ~A" html)
      (is (search "body &amp; more" html) "~A" html)
      (is (search "href=\"/t/1\"" html) "~A" html)
      (is (search "2 times" html) "a collapsed item says how many: ~A" html)
      (is (search (format nil "&quot;id&quot;: &quot;~A&quot;" (n:notification-id b)) html)
          "the unread item has its mark-read button: ~A" html)
      (is (null (search (n:notification-id a) html)) "the read one has none")
      (is (search "hx-post=\"/notes/read-all\"" html) "~A" html)
      (is (search "hx-get=\"/notes/list?before=" html) "Older, when there is more: ~A" html))
    (is (search "You have no notifications." (%html (lambda () (n:notification-panel '())))))))

(test a-translation-key-is-shown-in-the-viewers-locale-or-as-its-name
  (let ((s (n:make-memory-notification-store)))
    (%put s "u1" '(:key :app/reply :args (:who "Ann")))
    (let ((html (%html (lambda () (n:notification-panel (n:notification-list s "u1") :source nil)))))
      (is (search "app/reply" html) "a key with no source shows as its name: ~A" html))))

;;; --- the routes ---------------------------------------------------------------------------

(defun %env (method path &key query body)
  (let ((octets (and body (sb-ext:string-to-octets body :external-format :utf-8))))
    (list* :request-method method :path-info path :query-string query
           :headers (make-hash-table :test #'equal)
           (and octets (list :raw-body (flexi-streams:make-in-memory-input-stream octets)
                             :content-length (length octets)
                             :content-type "application/x-www-form-urlencoded")))))

(defun %call (store who method path &rest keys)
  (let ((r (n:notification-router store :recipient-fn (lambda (env) (declare (ignore env)) who)
                                        :prefix "/notes")))
    (router:dispatch r (apply #'%env method path keys))))

(defun %body (response) (or (first (third response)) ""))

(test the-routes-answer-only-a-signed-in-recipient
  (let ((s (n:make-memory-notification-store)))
    (dolist (call '((:get "/count") (:get "/list") (:post "/read-all") (:get "/delivery")))
      (is (eql 401 (first (%call s nil (first call) (second call)))) "~S without a recipient" call))
    (signals n:invalid-notification (n:notification-router s))))

(test the-count-route-answers-204-until-the-count-changes
  (let ((s (n:make-memory-notification-store)))
    (%put s "u1" "a")
    (is (eql 204 (first (%call s "u1" :get "/count" :query "seen=1"))))
    (let ((r (%call s "u1" :get "/count" :query "seen=0")))
      (is (eql 200 (first r)))
      (is (search "hx-swap-oob=innerHTML>1<" (%body r)) "the count: ~A" (%body r))
      (is (search "1 unread notification<" (%body r)) "the status sentence: ~A" (%body r))
      (is (search "seen=1" (%body r)) "and a poller that now carries 1: ~A" (%body r)))
    (is (eql 200 (first (%call s "u1" :get "/count" :query "seen=x"))) "a bad seen is not equal")))

(test mark-read-through-the-route-changes-only-the-recipients-item
  (let* ((s (n:make-memory-notification-store))
         (theirs (%put s "u2" "u2's"))
         (mine (%put s "u1" "u1's")))
    (%call s "u1" :post "/read" :body (format nil "id=~A" (n:notification-id theirs)))
    (is (= 1 (n:unread-count s "u2")) "u1 posting u2's id changes nothing")
    (let ((r (%call s "u1" :post "/read" :body (format nil "id=~A" (n:notification-id mine)))))
      (is (= 0 (n:unread-count s "u1")))
      (is (search "hx-swap-oob=innerHTML>0<" (%body r)) "the bell is updated too: ~A" (%body r)))
    (%put s "u1" "again")
    (%call s "u1" :post "/read-all")
    (is (= 0 (n:unread-count s "u1")))))

(test the-delivery-route-reads-only-declared-kinds-and-deliveries
  (let ((s (n:make-memory-notification-store)))
    (let ((r (%call s "u1" :post "/delivery"
                    :body "kind-test-reply=email&kind-test-digest=sms&kind-test-unknown=none")))
      (is (eql 200 (first r)))
      (is (search "Saved." (%body r))))
    (is (eq :email (n:delivery-ref s "u1" :test-reply)))
    (is (null (n:delivery-ref s "u1" :test-digest)) "an unknown delivery is ignored")
    (is (search "selected" (%body (%call s "u1" :get "/delivery"))))))

(test the-prune-job-returns-its-count-for-the-run-log
  (let ((s (n:make-memory-notification-store)))
    (%put s "u1" "x")
    (n:mark-all-read s "u1")
    (is (equal '(:deleted 0) (funcall (n:prune-notifications-job s :read-days 1) nil)))
    (signals n:invalid-notification (n:prune-notifications-job s :read-days 0))))

(defun run-tests ()
  (let ((results (run 'notifications)))
    (explain! results)
    (unless (results-status results)
      (error "hyperion/notifications tests failed"))))
