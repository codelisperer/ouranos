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
;;;; A backtrace is the other way out. A request middleware that logs an uncaught error with
;;;; AION/LOG:EXCEPTION prints the backtrace from a HANDLER-BIND, while every frame between the
;;;; signal and the handler is live and printed with its arguments. So no function here takes
;;;; the plain token as an argument and then signals, and every error raised while the request
;;;; is being made (when SEND-REQUEST's frames hold the request, and so the URL) is caught by
;;;; %TELEGRAM-CALL's HANDLER-CASE, which unwinds those frames before anything is signalled.
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

(defun %redact-one (text secret-text)
  "TEXT with every occurrence of SECRET-TEXT replaced by \"<redacted>\"."
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

(defun %percent-encode-colons (text)
  (with-output-to-string (out)
    (loop for ch across text
          do (if (char= ch #\:) (write-string "%3A" out) (write-char ch out)))))

(defun %lowercase-escapes (text)
  "TEXT with each \"%3A\" written \"%3a\"."
  (with-output-to-string (out)
    (loop with i = 0
          while (< i (length text))
          do (if (and (<= (+ i 3) (length text)) (string= "%3A" text :start2 i :end2 (+ i 3)))
                 (progn (write-string "%3a" out) (incf i 3))
                 (progn (write-char (char text i) out) (incf i))))))

(defun %redact (text token)
  "TEXT with TOKEN replaced by \"<redacted>\", as written and with its colon percent-encoded
(\"%3A\" or \"%3a\"), the form a URL in an error report may take. TEXT may be NIL."
  (let ((encoded (%percent-encode-colons token)))
    (%redact-one (%redact-one (%redact-one text token) encoded)
                 (%lowercase-escapes encoded))))

(defun %telegram-failure-class (status description)
  "The condition class for a refused Telegram call with HTTP STATUS and Telegram's DESCRIPTION.
Telegram answers 400 for an unknown chat, for missing rights, and for a malformed request
alike, so those are told apart by the description's text; a 400 not recognised here stays a
plain DELIVERY-FAILURE. A DESCRIPTION that is not a string is treated as absent."
  (let ((d (string-downcase (if (stringp description) description ""))))
    (flet ((has (s) (search s d)))
      (cond ((eql status 429) 'delivery-rate-limited)
            ((eql status 403) 'telegram-chat-unreachable)
            ((and (eql status 400) (has "chat not found")) 'telegram-chat-unreachable)
            ((and (eql status 400)
                  (or (has "not enough rights") (has "need administrator rights")
                      (has "have no rights") (has "chat_write_forbidden")
                      ;; CHAT_SEND_PLAIN_FORBIDDEN, CHAT_SEND_PHOTOS_FORBIDDEN and the other
                      ;; per-kind permissions a group can take away.
                      (and (has "chat_send_") (has "_forbidden"))))
             'telegram-not-permitted)
            (t 'delivery-failure)))))

(defun %parse-object (text)
  "TEXT parsed as a JSON object (a hash table), or NIL when it is not one."
  (let ((v (ignore-errors (jzon:parse text))))
    (and (hash-table-p v) v)))

(defun %telegram-refusal (status body redact)
  "The condition, not yet signalled, for a Telegram call refused with HTTP STATUS and response
BODY. REDACT is a function that removes the token from a string; it is a closure rather than the
token so that no frame printed in a backtrace shows the token. Telegram's description is the
detail, and the body when Telegram sent no description as a string; a group that became a
supergroup gives TELEGRAM-CHAT-MIGRATED with the new chat id."
  (let* ((json (%parse-object body))
         (description (let ((d (and json (gethash "description" json))))
                        (and (stringp d) d)))
         (parameters (and json (gethash "parameters" json)))
         (retry-after (and (hash-table-p parameters) (gethash "retry_after" parameters)))
         (migrate-to (and (hash-table-p parameters) (gethash "migrate_to_chat_id" parameters)))
         (detail (funcall redact (or description body))))
    (cond ((and (eql status 400) (integerp migrate-to))
           (make-condition 'telegram-chat-migrated :provider :telegram :status status
                                                   :detail detail :migrate-to-chat-id migrate-to))
          (t (let ((class (%telegram-failure-class status description)))
               (if (eq class 'delivery-rate-limited)
                   (make-condition class :provider :telegram :status status :detail detail
                                         :retry-after (and (integerp retry-after) retry-after))
                   (make-condition class :provider :telegram :status status :detail detail)))))))

(defun %telegram-call (p method params)
  "Call Bot API METHOD with PARAMS (a string-keyed hash table) and return the response's
\"result\". Signals CONFIGURATION-ERROR without a token, and on a refusal or a transport
failure the condition %TELEGRAM-REFUSAL chooses, with the token removed from its text. Every
error raised while the request is being made is caught here, so its frames are unwound before
anything is signalled (see this file's header)."
  (let* ((secret (%telegram-token p))
         (token (%require (if (secret:secretp secret) (secret:reveal secret) secret)
                          "TELEGRAM_BOT_TOKEN"))
         (req (make-request :method :post
                            :url (format nil "~A/bot~A/~A" (telegram-api-base p) token method)
                            :content (jzon:stringify params)
                            :max-body-bytes +telegram-max-response-bytes+))
         (redact (lambda (text) (%redact text token)))
         (resp (handler-case
                   (apply #'send-request req
                          (list (add-header "Content-Type" "application/json")
                                (ensure-2xx :telegram))
                          (when *telegram-perform* (list :perform *telegram-perform*)))
                 (http-error (c)
                   (error (if (http-error-status c)
                              (%telegram-refusal (http-error-status c) (http-error-body c) redact)
                              (make-condition 'delivery-failure
                                              :provider :telegram
                                              :detail (funcall redact
                                                               (or (http-error-detail c)
                                                                   (http-error-body c)))))))
                 ;; Anything else -- a defect in a stage, a network library's own condition --
                 ;; would otherwise reach an outer handler with the request's frames live. The
                 ;; report is printed under IGNORE-ERRORS: a report that fails to print would
                 ;; otherwise signal from here, unredacted, instead of the DELIVERY-FAILURE.
                 (cl:error (c)
                   (error 'delivery-failure
                          :provider :telegram
                          :detail (or (ignore-errors
                                       (funcall redact (format nil "~A: ~A" (type-of c) c)))
                                      (format nil "~A, whose report could not be printed"
                                              (type-of c)))))
                 ;; A serious condition that is not an error -- a timeout, a heap or stack
                 ;; exhaustion, an interrupt -- is not a delivery failure, so it is signalled
                 ;; again unchanged, but only after this HANDLER-CASE has unwound the request's
                 ;; frames: hyperion's dev server prints a backtrace for any SERIOUS-CONDITION.
                 ;; Signalled again with ERROR, an interrupt loses its CONTINUE restart.
                 (serious-condition (c)
                   (error c))))
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
    (%check-edit text parse-mode link-preview part)
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
  "Signals TELEGRAM-CHAT-MIGRATED for a group that became a supergroup, rather than answering:
the condition carries the new chat id, which the app needs to store in place of CHAT."
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
