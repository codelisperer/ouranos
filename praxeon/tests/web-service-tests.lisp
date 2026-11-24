;;;; web-service-tests.lisp --- the headless JSON surface, :surface and --service (#1338)
;;;;
;;;; A front end built elsewhere creates a conversation, sends a message and reads the turn's
;;;; items back as JSON, by polling and by a stream. The app is the echo app of web-tests.lisp,
;;;; whose turn answers "echo: MESSAGE" and fails for the message "fail".

(cl:in-package #:praxeon/web/tests)

(in-suite praxeon-web)

(defun %json-of (body)
  (com.inuoe.jzon:parse body))

(defun %create (app &key authorization)
  "POST /api/conversations. Returns (values STATUS ID CURSOR)."
  (multiple-value-bind (status headers body)
      (%call app :post "/api/conversations" :authorization authorization)
    (declare (ignore headers))
    (if (eql status 200)
        (let ((o (%json-of body)))
          (values status (gethash "id" o) (gethash "cursor" o)))
        (values status nil nil))))

(defun %send-to (app id text &key authorization)
  "POST a message to conversation ID. Returns (values STATUS BODY)."
  (multiple-value-bind (status headers body)
      (%call app :post (format nil "/api/conversations/~A/messages" id)
             :json (com.inuoe.jzon:stringify (let ((h (make-hash-table :test #'equal)))
                                                (setf (gethash "message" h) text)
                                                h))
             :authorization authorization)
    (declare (ignore headers))
    (values status body)))

(defun %poll-json (app id after &key authorization)
  "GET conversation ID's events from AFTER, the polling form. Returns (values STATUS OBJECT-or-BODY)."
  (multiple-value-bind (status headers body)
      (%call app :get (format nil "/api/conversations/~A/events" id)
             :query (format nil "after=~A" after) :authorization authorization)
    (declare (ignore headers))
    (values status (if (eql status 200) (%json-of body) body))))

(defun %kinds (update)
  "The \"kind\" of each item in UPDATE, a parsed poll or event object."
  (map 'list (lambda (item) (gethash "kind" item)) (gethash "items" update)))

(defun %turn-over-p (update)
  (find "turn-ended" (%kinds update) :test #'equal))

(defun %event-data (event)
  "The JSON object in EVENT, the text of one Server-Sent Event."
  (let ((at (search "data: " event)))
    (and at (%json-of (subseq event (+ at 6) (position #\Newline event :start at))))))

(test a-service-conversation-is-created-sent-to-and-read-back-by-polling
  (let ((app (%echo-app :surface :service)))
    (multiple-value-bind (status id cursor) (%create app)
      (is (eql 200 status))
      (is (stringp id))
      (is (eql 0 cursor) "a new conversation has no items: ~S" cursor)
      (multiple-value-bind (status body) (%send-to app id "hello")
        (is (eql 202 status) "~S" body)
        (is (eql 1 (gethash "cursor" (%json-of body))) "the cursor is just past the message: ~S" body))
      (let ((update (await (lambda ()
                             (let ((u (nth-value 1 (%poll-json app id 0))))
                               (and (%turn-over-p u) u))))))
        (is-true update "the turn never ended")
        (when update
          (is (equal '("user" "assistant" "turn-ended") (%kinds update)))
          (let ((items (gethash "items" update)))
            (is (equal "hello" (gethash "text" (aref items 0))))
            (is (equal "echo: hello" (gethash "text" (aref items 1))))
            (is (eql 1 (gethash "turn" (aref items 1))))
            (is (equal "ok" (gethash "outcome" (aref items 2)))))
          (is (eql 3 (gethash "cursor" update)))
          (is (eq nil (gethash "running" update)))
          (is (eq 'null (gethash "draft" update)) "~S" (gethash "draft" update))))
      ;; From the cursor the message answered with, the poll has only what came after it.
      (is (equal '("assistant" "turn-ended") (%kinds (nth-value 1 (%poll-json app id 1)))))
      (is (equal '() (%kinds (nth-value 1 (%poll-json app id 3)))))
      ;; An error is a turn-ended item with its message.
      (%send-to app id "fail")
      (let ((update (await (lambda ()
                             (let ((u (nth-value 1 (%poll-json app id 3))))
                               (and (%turn-over-p u) u))))))
        (is-true update)
        (when update
          (let ((ended (find "turn-ended" (gethash "items" update)
                             :key (lambda (i) (gethash "kind" i)) :test #'equal)))
            (is (equal "error" (gethash "outcome" ended)))
            (is (stringp (gethash "message" ended)))))))))

(test a-service-request-is-refused-when-it-is-wrong
  "Another conversation's id is 404; a bad cursor and an empty message are 400; a server that
polls answers the stream form with 400 and says to poll."
  (let ((app (%echo-app :surface :service)))
    (let ((id (nth-value 1 (%create app))))
      (is (eql 404 (%poll-json app "not-the-id" 0)))
      (is (eql 404 (%send-to app "not-the-id" "hello")))
      (is (eql 400 (%poll-json app id "x")))
      (is (eql 400 (%poll-json app id -1)))
      (is (eql 400 (%send-to app id "")))
      (multiple-value-bind (status headers body)
          (%call app :get (format nil "/api/conversations/~A/events" id))
        (declare (ignore headers))
        (is (eql 400 status))
        (is (search "after" body) "~S" body)))))

(test a-service-conversation-is-read-back-by-stream
  "The stream form from the start carries the items as JSON, each event's id its cursor. A client
that reconnects with Last-Event-ID gets only what came after it."
  (let ((app (%echo-app :surface :service :transport :sse)))
    (let ((id (nth-value 1 (%create app))))
      (%send-to app id "hello")
      (await (lambda () (%turn-over-p (nth-value 1 (%poll-json app id 0)))))
      (let* ((events (%read-stream (nth-value 2 (%call app :get
                                                        (format nil "/api/conversations/~A/events" id)))))
             (event (first events))
             (update (and event (%event-data event))))
        (is-true update "no event: ~S" events)
        (when update
          (is (equal '("user" "assistant" "turn-ended") (%kinds update)))
          (is (search "id: 3" event) "~S" event)))
      (let* ((event (first (%read-stream (nth-value 2 (%call app :get
                                                             (format nil "/api/conversations/~A/events" id)
                                                             :headers '(("last-event-id" . "2")))))))
             (update (and event (%event-data event))))
        (is (equal '("turn-ended") (%kinds update)) "~S" event)))))

(test the-ui-surface-has-no-service-routes-and-the-service-has-no-page
  "Under :UI, the default, the service's routes are 404. Under :SERVICE the page, the poll and the
assets are 404, and the blocking JSON POST /api/message still answers. :BOTH has both."
  (let ((ui (%echo-app)))
    (is (eql 404 (%create ui)))
    (is (eql 404 (%poll-json ui "x" 0)))
    (is (eql 200 (nth-value 0 (%call ui :get "/")))))
  (let ((service (%echo-app :surface :service)))
    (is (eql 404 (nth-value 0 (%call service :get "/"))))
    (is (eql 404 (nth-value 0 (%call service :get "/api/progress"))))
    (is (eql 404 (nth-value 0 (%call service :get "/assets/htmx.min.js"))))
    (multiple-value-bind (status headers body)
        (%call service :post "/api/message" :json "{\"message\":\"hi\"}"
                                            :headers '(("accept" . "application/json")))
      (declare (ignore headers))
      (is (eql 200 status))
      (is (equal "{\"reply\":\"echo: hi\"}" body))))
  (let ((both (%echo-app :surface :both)))
    (is (eql 200 (nth-value 0 (%call both :get "/"))))
    (is (eql 200 (%create both)))))

(test with-grants-the-service-needs-a-session
  "Each service route answers 401 without a session; with the session POST /embed/session opened,
the conversation is the principal's, as the page's is."
  (multiple-value-bind (priv pub) (aion/signature:generate-key-pair)
    (let* ((app (%grant-app pub :surface :service))
           (session (nth-value 1 (%open app (%grant-token priv))))
           (auth (format nil "Session ~A" session)))
      (is (eql 401 (%create app)))
      (multiple-value-bind (status id) (%create app :authorization auth)
        (is (eql 200 status))
        (is (eql 401 (%send-to app id "hello")))
        (is (eql 401 (%poll-json app id 0)))
        (is (eql 401 (nth-value 0 (%call app :get (format nil "/api/conversations/~A/events" id)
                                         :query "after=0"
                                         :authorization "Session not-a-session"))))
        (is (eql 202 (%send-to app id "hello" :authorization auth)))
        (is-true (await (lambda ()
                          (%turn-over-p (nth-value 1 (%poll-json app id 0 :authorization auth))))))))))

(test make-app-takes-a-surface-and-serve-forever-reads-it-from-the-command-line
  (signals error (%echo-app :surface :headless))
  (signals error (%echo-app :surface :service :embed-origins '("https://app.example.com")))
  (is (eq :ui (web:surface-from-arguments '())))
  (is (eq :ui (web:surface-from-arguments '("--server" "--port" "8080"))))
  (is (eq :service (web:surface-from-arguments '("--service"))))
  (is (eq :both (web:surface-from-arguments '("--service" "--server"))))
  (is (eq :ui (web:surface-from-arguments '("--services"))) "only the exact flag counts"))
