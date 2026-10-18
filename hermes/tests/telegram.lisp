;;;; tests/telegram.lisp --- the Telegram Bot API backend (#778).
;;;;
;;;; The backend talks to a real HTTP server on 127.0.0.1 (aion/test-http) that answers the way
;;;; the Bot API does, so the request on the wire and the response parsing are both the real
;;;; code. The one exception is the transport failure whose text names the URL: no failure the
;;;; network stack produces here does that, so that test substitutes the round trip.

(cl:in-package #:hermes/tests)

(in-suite hermes)

(defparameter +bot-token+ "123456:TEST-token-must-not-leak"
  "A token shaped like a real one. Every test that can fail with a URL checks it is absent.")

(defun %bot-reply (stream status json)
  (aion/test-http:write-response stream status '(("Content-Type" . "application/json")) json))

(defun %bot-ok (result-json)
  (format nil "{\"ok\":true,\"result\":~A}" result-json))

(defun %bot-error (code description &optional parameters-json)
  (format nil "{\"ok\":false,\"error_code\":~D,\"description\":~S~@[,\"parameters\":~A~]}"
          code description parameters-json))

(defparameter +sent-message+
  "{\"message_id\":42,\"date\":1760000000,\"chat\":{\"id\":-1001234567890,\"type\":\"channel\",\"title\":\"News\"},\"text\":\"hi\"}")

(defmacro with-bot ((server provider handler) &body body)
  "Run BODY with SERVER answering every request with HANDLER, a function of (METHOD REQUEST
STREAM) where METHOD is the Bot API method from the path, and PROVIDER a Telegram provider
pointed at it."
  `(aion/test-http:with-server
       (,server (lambda (request stream)
                  (let* ((path (aion/test-http:request-path request))
                         (method (subseq path (1+ (position #\/ path :from-end t)))))
                    (funcall ,handler method request stream))))
     (let ((,provider (h:make-telegram :token +bot-token+
                                       :api-base (aion/test-http:server-url ,server ""))))
       ,@body)))

(defun %requests (server)
  "SERVER's requests, oldest first."
  (reverse (aion/test-http:server-requests server)))

(defun %request-json (request)
  (com.inuoe.jzon:parse (aion/test-http:request-body-string request)))

(defun %always (status json)
  (lambda (method request stream)
    (declare (ignore method request))
    (%bot-reply stream status json)))

(defun %no-token-p (text)
  (not (search +bot-token+ (princ-to-string text))))

;;; --- sending --------------------------------------------------------------

(test a-telegram-message-is-sent-with-sendmessage-and-its-options
  (with-bot (s p (%always 200 (%bot-ok +sent-message+)))
    (let* ((r (h:deliver p (h:make-telegram-message :chat "@news_channel" :text "*hi*"
                                                    :parse-mode :markdown-v2 :link-preview :hide)))
           (req (first (%requests s)))
           (json (%request-json req)))
      (is (equal "POST" (aion/test-http:request-method req)))
      (is (equal (format nil "/bot~A/sendMessage" +bot-token+) (aion/test-http:request-path req)))
      (is (equal "@news_channel" (gethash "chat_id" json)))
      (is (equal "*hi*" (gethash "text" json)))
      (is (equal "MarkdownV2" (gethash "parse_mode" json)))
      (is (eq t (gethash "is_disabled" (gethash "link_preview_options" json))))
      (is (eq :telegram (h:delivery-result-provider r)))
      (is (equal "42" (h:delivery-result-id r)))
      (is (eq :sent (h:delivery-result-status r)))
      (is (eql -1001234567890 (h:delivery-result-destination r))
          "the destination is the chat id Telegram answered with, not the @username sent"))))

(test a-plain-message-sends-no-parse-mode-and-no-preview-option
  (with-bot (s p (%always 200 (%bot-ok +sent-message+)))
    (h:deliver p (h:make-telegram-message :chat -1001234567890 :text "plain"))
    (let ((json (%request-json (first (%requests s)))))
      (is (eql -1001234567890 (gethash "chat_id" json)))
      (is (null (nth-value 1 (gethash "parse_mode" json))))
      (is (null (nth-value 1 (gethash "link_preview_options" json)))))))

(test a-photo-is-sent-with-sendphoto-and-the-text-as-its-caption
  (with-bot (s p (%always 200 (%bot-ok +sent-message+)))
    (h:deliver p (h:make-telegram-message :chat "@news_channel" :text "<b>New</b>"
                                          :parse-mode :html
                                          :photo "https://example.com/cover.jpg"))
    (let* ((req (first (%requests s)))
           (json (%request-json req)))
      (is (equal (format nil "/bot~A/sendPhoto" +bot-token+) (aion/test-http:request-path req)))
      (is (equal "https://example.com/cover.jpg" (gethash "photo" json)))
      (is (equal "<b>New</b>" (gethash "caption" json)))
      (is (equal "HTML" (gethash "parse_mode" json)))
      (is (null (nth-value 1 (gethash "text" json)))))))

(test a-telegram-message-is-checked-before-anything-is-sent
  (dolist (bad (list (list :chat "news" :text "x")             ; no @
                     (list :chat "@abcd" :text "x")            ; too short
                     (list :chat "@has space" :text "x")
                     (list :chat 1.5 :text "x")
                     (list :chat "@news_channel" :text "")     ; empty, and no photo
                     (list :chat "@news_channel" :text "x" :parse-mode :markdown)
                     (list :chat "@news_channel" :text "x" :link-preview nil)
                     (list :chat "@news_channel" :photo (format nil "a~%b"))))
    (signals h:invalid-message (apply #'h:make-telegram-message bad)))
  (is (h:telegram-message-p (h:make-telegram-message :chat "@news_channel" :photo "file-id")))
  (is (h:telegram-message-p (h:make-telegram-message :chat -100123 :text "x"))))

(test a-provider-without-a-token-refuses-before-any-request
  (with-bot (s p (%always 200 (%bot-ok +sent-message+)))
    (let ((tokenless (h:make-telegram :token nil :api-base (h:telegram-api-base p))))
      (handler-case (progn (h:deliver tokenless (h:make-telegram-message :chat -1 :text "x"))
                           (fail "should have signalled"))
        (h:configuration-error (c)
          (is (search "TELEGRAM_BOT_TOKEN" (h:configuration-error-missing c)))))
      (is (null (%requests s))))))

;;; --- failures -------------------------------------------------------------

(defun %refusal (status body)
  "The condition a send signals when the server answers STATUS with BODY."
  (with-bot (s p (%always status body))
    (declare (ignorable s))
    (handler-case (progn (h:deliver p (h:make-telegram-message :chat -1 :text "x")) nil)
      (h:delivery-failure (c) c))))

(test telegram-refusals-arrive-as-their-own-conditions
  (loop for (status description class) in
        '((403 "Forbidden: bot is not a member of the channel chat" h:telegram-chat-unreachable)
          (403 "Forbidden: bot was kicked from the group chat" h:telegram-chat-unreachable)
          (400 "Bad Request: chat not found" h:telegram-chat-unreachable)
          (400 "Bad Request: not enough rights to send text messages to the chat" h:telegram-not-permitted)
          (400 "Bad Request: need administrator rights in the channel chat" h:telegram-not-permitted)
          (400 "Bad Request: message text is empty" h:delivery-failure))
        do (let ((c (%refusal status (%bot-error status description))))
             (is (eq class (type-of c)) "~A ~S should be ~S, was ~S" status description class (type-of c))
             (is (eq :telegram (h:delivery-failure-provider c)))
             (is (eql status (h:delivery-failure-status c)))
             (is (equal description (h:delivery-failure-detail c))))))

(test a-flood-limit-arrives-with-retry-after-in-seconds
  (let ((c (%refusal 429 (%bot-error 429 "Too Many Requests: retry after 35" "{\"retry_after\":35}"))))
    (is (typep c 'h:delivery-rate-limited))
    (is (typep c 'h:delivery-failure) "existing DELIVERY-FAILURE handlers still receive it")
    (is (eql 35 (h:delivery-rate-limited-retry-after c))
        "a caller schedules its retry from a number of seconds")
    (is (search "35 seconds" (princ-to-string c))))
  (let ((c (%refusal 429 (%bot-error 429 "Too Many Requests"))))
    (is (typep c 'h:delivery-rate-limited))
    (is (null (h:delivery-rate-limited-retry-after c)))))

(test an-answer-that-is-not-ok-is-a-delivery-failure
  (let ((c (%refusal 200 "not json")))
    (is (eq 'h:delivery-failure (type-of c)))))

;;; --- the token stays out of conditions and logs ---------------------------

(defun %with-error-log (thunk)
  "Call THUNK with error logging captured; return the captured text."
  (let ((out (make-string-output-stream)))
    (unwind-protect
         (progn (aion/log:setup :env :dev :level :error :stream out)
                (funcall thunk))
      (aion/log:setup :env :dev :level :warn :stream *standard-output*))
    (get-output-stream-string out)))

(test the-token-is-removed-from-a-transport-failure-that-names-the-url
  ;; No transport failure the network stack produces here names the URL, so the round trip is
  ;; replaced by one that fails the way aion/http-client reports a transport failure, with an
  ;; underlying report that does.
  (let* ((hermes::*telegram-perform*
           (lambda (req)
             (error 'aion/http-client:http-error
                    :detail (format nil "transport error: cannot reach ~A"
                                    (aion/http-client:request-url req)))))
         (p (h:make-telegram :token +bot-token+))
         (c (handler-case (progn (h:deliver p (h:make-telegram-message :chat -1 :text "x")) nil)
              (h:delivery-failure (c) c))))
    (is (typep c 'h:delivery-failure))
    (is (search "<redacted>" (h:delivery-failure-detail c))
        "the URL is still there, with the token replaced")
    (is (%no-token-p (h:delivery-failure-detail c)))
    (is (%no-token-p c) "the condition's report")
    (with-env (("HERMES_TRANSPORT" nil) ("HERMES_TELEGRAM_IMPL" "telegram")
               ("TELEGRAM_BOT_TOKEN" "123456:TEST-token-must-not-leak"))
      (let ((log (%with-error-log
                  (lambda () (ignore-errors (h:send (h:make-telegram-message :chat -1 :text "x")))))))
        (is (search "delivery failed" log) "the failure was logged")
        (is (%no-token-p log))))))

(test the-token-is-removed-from-an-answer-too-large-to-read
  ;; aion/http-client's RESPONSE-TOO-LARGE names the URL, so the token reaches the condition
  ;; unless the backend removes it.
  (let ((big (make-string (+ hermes::+telegram-max-response-bytes+ 10) :initial-element #\a)))
    (with-bot (s p (%always 200 big))
      (declare (ignorable s))
      (let ((c (handler-case (progn (h:deliver p (h:make-telegram-message :chat -1 :text "x")) nil)
                 (h:delivery-failure (c) c))))
        (is (typep c 'h:delivery-failure))
        (is (search "<redacted>" (h:delivery-failure-detail c)))
        (is (%no-token-p c))))))

(test the-provider-holds-its-token-as-a-secret
  (let ((p (h:make-telegram :token +bot-token+)))
    (is (aion/secret:secretp (hermes::%telegram-token p)))
    (is (%no-token-p (format nil "~S ~A" p (hermes::%telegram-token p))))))

;;; --- edit, delete, can-post -----------------------------------------------

(test a-sent-message-is-edited-and-deleted-through-its-result
  (with-bot (s p (lambda (method request stream)
                   (declare (ignore request))
                   (%bot-reply stream 200 (if (equal method "deleteMessage")
                                              (%bot-ok "true")
                                              (%bot-ok +sent-message+)))))
    (let* ((sent (h:deliver p (h:make-telegram-message :chat "@news_channel" :text "hi")))
           (edited (h:edit-sent-message p sent "hi, edited" :parse-mode :html)))
      (h:edit-sent-message p sent "new caption" :part :caption)
      (is (eq t (h:delete-sent-message p sent)))
      (destructuring-bind (send edit caption delete) (%requests s)
        (declare (ignore send))
        (is (search "/editMessageText" (aion/test-http:request-path edit)))
        (let ((json (%request-json edit)))
          (is (eql -1001234567890 (gethash "chat_id" json)))
          (is (eql 42 (gethash "message_id" json)))
          (is (equal "hi, edited" (gethash "text" json)))
          (is (equal "HTML" (gethash "parse_mode" json))))
        (is (search "/editMessageCaption" (aion/test-http:request-path caption)))
        (let ((json (%request-json caption)))
          (is (equal "new caption" (gethash "caption" json)))
          (is (null (nth-value 1 (gethash "text" json)))))
        (is (search "/deleteMessage" (aion/test-http:request-path delete)))
        (let ((json (%request-json delete)))
          (is (eql -1001234567890 (gethash "chat_id" json)))
          (is (eql 42 (gethash "message_id" json)))))
      (is (eq :edited (h:delivery-result-status edited)))
      (is (equal "42" (h:delivery-result-id edited))))))

(test an-edit-without-a-destination-is-refused-before-any-request
  (with-bot (s p (%always 200 (%bot-ok +sent-message+)))
    (signals h:invalid-message
      (h:edit-sent-message p (h:make-delivery-result :provider :telegram :id "42") "x"))
    (signals h:invalid-message
      (h:delete-sent-message p (h:make-delivery-result :provider :telegram :destination -1)))
    (is (null (%requests s))))
  (signals h:unsupported-message
    (h:delete-sent-message (make-instance 'h:email-provider)
                           (h:make-delivery-result :id "1" :destination "x"))))

(defun %member (&rest kvs) (apply #'hermes::%obj kvs))

(test whether-the-bot-can-post-follows-the-chat-type-and-its-member-record
  (flet ((can (type member &optional (permissions (%member "can_send_messages" t)))
           (hermes::%can-post-from type permissions member)))
    (is (eq :yes (can "channel" (%member "status" "creator"))))
    (is (eq :yes (can "channel" (%member "status" "administrator" "can_post_messages" t))))
    (is (eq :not-permitted (can "channel" (%member "status" "administrator" "can_post_messages" nil))))
    (is (eq :not-permitted (can "channel" (%member "status" "member"))))
    (is (eq :not-member (can "channel" (%member "status" "left"))))
    (is (eq :not-member (can "supergroup" (%member "status" "kicked"))))
    (is (eq :yes (can "supergroup" (%member "status" "member"))))
    (is (eq :not-permitted (can "supergroup" (%member "status" "member")
                                (%member "can_send_messages" nil))))
    (is (eq :yes (can "group" (%member "status" "administrator"))))
    (is (eq :yes (can "supergroup" (%member "status" "restricted" "is_member" t "can_send_messages" t))))
    (is (eq :not-permitted (can "supergroup" (%member "status" "restricted" "is_member" t
                                                      "can_send_messages" nil))))
    (is (eq :not-member (can "supergroup" (%member "status" "restricted" "is_member" nil))))))

(test the-can-post-check-asks-telegram-about-the-bot-in-that-chat
  (with-bot (s p (lambda (method request stream)
                   (declare (ignore request))
                   (%bot-reply stream 200
                               (%bot-ok (cond ((equal method "getChat")
                                               "{\"id\":-1001234567890,\"type\":\"channel\"}")
                                              ((equal method "getMe")
                                               "{\"id\":777,\"is_bot\":true}")
                                              (t "{\"status\":\"administrator\",\"can_post_messages\":true}"))))))
    (is (eq :yes (h:telegram-can-post p "@news_channel")))
    (let ((member-request (third (%requests s))))
      (is (search "/getChatMember" (aion/test-http:request-path member-request)))
      (is (eql 777 (gethash "user_id" (%request-json member-request))))))
  (with-bot (s p (%always 400 (%bot-error 400 "Bad Request: chat not found")))
    (declare (ignorable s))
    (is (eq :not-member (h:telegram-can-post p "@news_channel")))))

;;; --- escaping -------------------------------------------------------------

(test markdown-v2-escaping-puts-a-backslash-before-every-special-character
  (let ((special "_*[]()~`>#+-=|{}.!\\"))
    (is (equal (with-output-to-string (o)
                 (loop for ch across special do (write-char #\\ o) (write-char ch o)))
               (h:escape-markdown-v2 special))))
  (is (equal "Hello world 42" (h:escape-markdown-v2 "Hello world 42")))
  (is (equal "v1\\.2 \\(beta\\)\\!" (h:escape-markdown-v2 "v1.2 (beta)!"))))

(test html-escaping-replaces-the-four-characters-telegram-parses
  (is (equal "a &lt;b&gt; &amp; &quot;c&quot;" (h:escape-telegram-html "a <b> & \"c\"")))
  (is (equal "plain" (h:escape-telegram-html "plain"))))

;;; --- dev transport and SEND -----------------------------------------------

(test the-dev-transport-renders-telegram-messages-and-never-needs-a-token
  (let* ((out (make-string-output-stream))
         (dev (h:make-dev-transport :stream out))
         (m (h:make-telegram-message :chat "@news_channel" :text "New post"))
         (r (h:deliver dev m)))
    (is (eq :dev (h:delivery-result-provider r)))
    (is (eq :logged (h:delivery-result-status r)))
    (is (eq m (h:dev-last-telegram dev)))
    (is (equal "@news_channel" (h:delivery-result-destination r)))
    (is (eq :edited (h:delivery-result-status (h:edit-sent-message dev r "Edited"))))
    (is (eq t (h:delete-sent-message dev r)))
    (is (eq :yes (h:telegram-can-post dev "@news_channel")))
    (let ((text (get-output-stream-string out)))
      (is (search "TELEGRAM (not sent)" text))
      (is (search "New post" text))
      (is (search "TELEGRAM EDIT" text))
      (is (search "TELEGRAM DELETE" text)))))

(test send-routes-a-telegram-message-and-logs-its-channel-without-its-text
  (with-env (("HERMES_TRANSPORT" "dev") ("TELEGRAM_BOT_TOKEN" nil))
    (is (typep (h:telegram-provider-from-env) 'h:dev-transport))
    (let ((out (make-string-output-stream)))
      (unwind-protect
           (progn (aion/log:setup :env :dev :level :debug :stream out)
                  ;; The dev transport renders to *standard-output*; keep it out of the run's output.
                  (let ((*standard-output* (make-broadcast-stream)))
                    (is (eq :dev (h:delivery-result-provider
                                  (h:send (h:make-telegram-message :chat "@news_channel"
                                                                   :text "secret-launch-text")))))))
        (aion/log:setup :env :dev :level :warn :stream *standard-output*))
      (let ((log (get-output-stream-string out)))
        (let ((sent (find-if (lambda (line) (search "hermes: sent" line))
                             (uiop:split-string log :separator (string #\Newline)))))
          (is (search "telegram" (string-downcase (or sent "")))
              "the line for the sent message names its channel"))
        (is (not (search "secret-launch-text" log)) "the text is not")
        (is (not (search "news_channel" log)) "nor the chat"))))
  (with-env (("HERMES_TRANSPORT" nil) ("HERMES_TELEGRAM_IMPL" nil))
    (is (typep (h:telegram-provider-from-env) 'h:telegram))))
