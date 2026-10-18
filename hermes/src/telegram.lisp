;;;; telegram.lisp --- the Telegram Bot API backend (#778).
;;;;
;;;; Sends a TELEGRAM-MESSAGE to a group or channel with sendMessage or sendPhoto, edits and
;;;; deletes it by the chat id and message id its DELIVERY-RESULT carries, and answers whether
;;;; the bot can post to a chat. Requests are JSON POSTs to https://api.telegram.org/bot<token>/
;;;; <method>; every response, success or failure, is a JSON object with "ok", and a failure
;;;; carries "error_code", "description" and sometimes "parameters".
;;;;
;;;; THE TOKEN IS IN THE URL PATH, which is the one thing about this API that needs care here.
;;;; Nothing in hermes or aion/http-client logs a URL, but a condition's text can carry one:
;;;; aion/http-client's RESPONSE-TOO-LARGE names the URL, and a transport failure's detail is
;;;; the report of whatever the network library signalled. Every failure from %TELEGRAM-CALL
;;;; therefore has the token replaced by "<redacted>" before it is signalled, and the token
;;;; itself is held as an AION/SECRET:SECRET, so the provider prints without it.
;;;;
;;;; Telegram's version is not in the URL, so +TELEGRAM-BOT-API-VERSION+ records the Bot API
;;;; version this was written against; the "Telegram Bot API" entry in upstream.sexp reads it.

(cl:in-package #:hermes)

(defparameter +telegram-bot-api-version+ "10.3"
  "The Bot API version this backend was written and checked against (Bot API 10.3,
2026-08-24). Telegram does not version its URLs and serves every bot the current version, so
nothing sends this; it is the record of which changelog entries were read.")

(defclass telegram (telegram-provider)
  ((token :initarg :token
          :initform (uiop:getenv "TELEGRAM_BOT_TOKEN")
          :reader %telegram-token)
   (api-base :initarg :api-base
             :initform "https://api.telegram.org"
             :reader telegram-api-base))
  (:documentation "The Telegram Bot API as a telegram-provider. TOKEN is the bot's token, a
string or an AION/SECRET:SECRET, and defaults to $TELEGRAM_BOT_TOKEN; it is kept as a SECRET.
API-BASE is the server, for a local Bot API server or a test."))

(defmethod initialize-instance :after ((p telegram) &key)
  (let ((token (slot-value p 'token)))
    (when (and (stringp token) (plusp (length token)))
      (setf (slot-value p 'token) (secret:make-secret token)))))

(defun make-telegram (&rest initargs &key token api-base)
  "A Telegram provider. TOKEN defaults to $TELEGRAM_BOT_TOKEN."
  (declare (ignore token api-base))
  (apply #'make-instance 'telegram initargs))

(defvar *telegram-perform* nil
  "When non-NIL, the function SEND-REQUEST calls instead of the HTTP round trip, for the test of
a transport failure whose text names the URL. NIL makes the real call.")

(defparameter +telegram-max-response-bytes+ (* 1024 1024)
  "The most of a response body the backend reads. Telegram's answers to these methods are a
few kilobytes; a longer body signals RESPONSE-TOO-LARGE, which arrives as DELIVERY-FAILURE.")

(defun %redact (text secret-text)
  "TEXT with every occurrence of SECRET-TEXT replaced by \"<redacted>\". TEXT may be NIL."
  (if (and (stringp text) (plusp (length secret-text)))
      (with-output-to-string (out)
        (loop with start = 0
              for hit = (search secret-text text :start2 start)
              do (write-string text out :start start :end (or hit (length text)))
                 (if hit
                     (progn (write-string "<redacted>" out)
                            (setf start (+ hit (length secret-text))))
                     (loop-finish))))
      text))

(defun %telegram-failure-class (status description)
  "The condition class for a refused Telegram call with HTTP STATUS and Telegram's DESCRIPTION.
Telegram answers 400 for an unknown chat, for missing rights, and for a malformed request
alike, so those are told apart by the description's text; a 400 not recognised here stays a
plain DELIVERY-FAILURE."
  (let ((d (string-downcase (or description ""))))
    (flet ((has (s) (search s d)))
      (cond ((eql status 429) 'delivery-rate-limited)
            ((eql status 403) 'telegram-chat-unreachable)
            ((and (eql status 400) (has "chat not found")) 'telegram-chat-unreachable)
            ((and (eql status 400)
                  (or (has "not enough rights") (has "need administrator rights")
                      (has "have no rights") (has "chat_write_forbidden")))
             'telegram-not-permitted)
            (t 'delivery-failure)))))

(defun %parse-object (text)
  "TEXT parsed as a JSON object (a hash table), or NIL when it is not one."
  (let ((v (ignore-errors (jzon:parse text))))
    (and (hash-table-p v) v)))

(defun %telegram-refusal (status body token)
  "Signal the condition for a Telegram call refused with HTTP STATUS and response BODY."
  (let* ((json (%parse-object body))
         (description (and json (gethash "description" json)))
         (parameters (and json (gethash "parameters" json)))
         (retry-after (and (hash-table-p parameters) (gethash "retry_after" parameters)))
         (class (%telegram-failure-class status description))
         (detail (%redact (or description body) token)))
    (if (eq class 'delivery-rate-limited)
        (error class :provider :telegram :status status :detail detail
                     :retry-after (and (integerp retry-after) retry-after))
        (error class :provider :telegram :status status :detail detail))))

(defun %telegram-call (p method params)
  "Call Bot API METHOD with PARAMS (a string-keyed hash table) and return the response's
\"result\". Signals CONFIGURATION-ERROR without a token, and on a refusal or a transport
failure the condition %TELEGRAM-REFUSAL chooses, with the token removed from its text."
  (let* ((secret (%telegram-token p))
         (token (%require (if (secret:secretp secret) (secret:reveal secret) secret)
                          "TELEGRAM_BOT_TOKEN"))
         (req (make-request :method :post
                            :url (format nil "~A/bot~A/~A" (telegram-api-base p) token method)
                            :content (jzon:stringify params)
                            :max-body-bytes +telegram-max-response-bytes+))
         (resp (handler-case
                   (apply #'send-request req
                          (list (add-header "Content-Type" "application/json")
                                (ensure-2xx :telegram))
                          (when *telegram-perform* (list :perform *telegram-perform*)))
                 (http-error (c)
                   (if (http-error-status c)
                       (%telegram-refusal (http-error-status c) (http-error-body c) token)
                       (error 'delivery-failure
                              :provider :telegram
                              :detail (%redact (or (http-error-detail c) (http-error-body c))
                                               token))))))
         (json (%parse-object (response-body resp))))
    (unless (and json (eq t (gethash "ok" json)))
      (error 'delivery-failure :provider :telegram :status (response-status resp)
                               :detail "Telegram's answer was not a JSON object with \"ok\": true"))
    (gethash "result" json)))

(defun %parse-mode-name (mode)
  (ecase mode ((nil) nil) (:html "HTML") (:markdown-v2 "MarkdownV2")))

(defun %telegram-text-params (chat text parse-mode link-preview photo)
  "The parameters of sendMessage, or of sendPhoto when PHOTO is given."
  (let ((params (%obj "chat_id" chat)))
    (if photo
        (progn (setf (gethash "photo" params) photo)
               (when (plusp (length text)) (setf (gethash "caption" params) text)))
        (progn (setf (gethash "text" params) text)
               (when (eq link-preview :hide)
                 (setf (gethash "link_preview_options" params) (%obj "is_disabled" t)))))
    (when parse-mode (setf (gethash "parse_mode" params) (%parse-mode-name parse-mode)))
    params))

(defun %telegram-result (message status raw)
  "A DELIVERY-RESULT for MESSAGE, a Telegram Message object."
  (let ((chat (gethash "chat" message)))
    (make-delivery-result :provider :telegram
                          :id (princ-to-string (gethash "message_id" message))
                          :status status
                          :destination (and (hash-table-p chat) (gethash "id" chat))
                          :raw raw)))

(defmethod deliver ((p telegram) (m telegram-message))
  (let ((message (%telegram-call p (if (telegram-message-photo m) "sendPhoto" "sendMessage")
                                 (%telegram-text-params (telegram-message-chat m)
                                                        (telegram-message-text m)
                                                        (telegram-message-parse-mode m)
                                                        (telegram-message-link-preview m)
                                                        (telegram-message-photo m)))))
    (%telegram-result message :sent message)))

(defun %sent-message-ref (result)
  "RESULT's destination and its id as an integer, or INVALID-MESSAGE when either is missing."
  (let ((destination (and (delivery-result-p result) (delivery-result-destination result)))
        (id (and (delivery-result-p result) (delivery-result-id result)
                 (ignore-errors (parse-integer (delivery-result-id result))))))
    (unless (and destination id)
      (error 'invalid-message
             :problem "it needs a DELIVERY-RESULT that carries a destination and a numeric id"))
    (values destination id)))

(defmethod edit-sent-message ((p telegram) result text &key parse-mode (link-preview :show) (part :text))
  (multiple-value-bind (chat id) (%sent-message-ref result)
    (unless (member part '(:text :caption))
      (error 'invalid-message :problem "it needs a :part of :TEXT or :CAPTION"))
    (let ((params (%telegram-text-params chat text parse-mode link-preview nil)))
      (setf (gethash "message_id" params) id)
      (when (eq part :caption)
        (remhash "text" params)
        (remhash "link_preview_options" params)
        (setf (gethash "caption" params) text))
      (let ((message (%telegram-call p (if (eq part :caption) "editMessageCaption" "editMessageText")
                                     params)))
        ;; Telegram answers with the edited Message, or with true for an inline message,
        ;; which this backend never sends; fall back to RESULT's own reference.
        (if (hash-table-p message)
            (%telegram-result message :edited message)
            (make-delivery-result :provider :telegram :id (delivery-result-id result)
                                  :status :edited :destination chat :raw message))))))

(defmethod delete-sent-message ((p telegram) result)
  (multiple-value-bind (chat id) (%sent-message-ref result)
    (%telegram-call p "deleteMessage" (%obj "chat_id" chat "message_id" id))
    t))

(defun %can-post-from (chat-type chat-permissions member)
  "Whether a bot whose chat member record is MEMBER can post to a chat of CHAT-TYPE (\"channel\",
\"group\", \"supergroup\") whose default member permissions are CHAT-PERMISSIONS: :YES,
:NOT-MEMBER or :NOT-PERMITTED. In a channel only the creator and administrators with
can_post_messages may post; in a group, administrators may, and members may unless the group's
permissions or the bot's own restriction take can_send_messages away."
  (flet ((field (table key) (and (hash-table-p table) (gethash key table))))
    (let ((status (field member "status")))
      (cond ((member status '("left" "kicked") :test #'equal) :not-member)
            ((equal status "creator") :yes)
            ((equal chat-type "channel")
             (if (and (equal status "administrator") (eq t (field member "can_post_messages")))
                 :yes
                 :not-permitted))
            ((equal status "administrator") :yes)
            ((equal status "member")
             (if (eq nil (field chat-permissions "can_send_messages")) :not-permitted :yes))
            ((equal status "restricted")
             (cond ((not (eq t (field member "is_member"))) :not-member)
                   ((eq t (field member "can_send_messages")) :yes)
                   (t :not-permitted)))
            (t :not-permitted)))))

(defmethod telegram-can-post ((p telegram) chat)
  (unless (%telegram-chat-p chat)
    (error 'invalid-message :problem "it needs a Telegram chat (an integer chat id or \"@username\")"))
  (handler-case
      (let* ((info (%telegram-call p "getChat" (%obj "chat_id" chat)))
             (bot (%telegram-call p "getMe" (%obj)))
             (member (%telegram-call p "getChatMember"
                                     (%obj "chat_id" chat "user_id" (gethash "id" bot)))))
        (%can-post-from (gethash "type" info)
                        ;; A missing permissions object reads as no restriction.
                        (or (gethash "permissions" info) (%obj "can_send_messages" t))
                        member))
    (telegram-chat-unreachable () :not-member)))

(register-impl :telegram "telegram" (lambda () (make-telegram)))
