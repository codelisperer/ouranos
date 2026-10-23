;;;; dev.lisp --- the dev/log transport: render a message instead of sending it.
;;;;
;;;; Local dev has no SMTP/SMS creds and must not hit real providers, but the account
;;;; lifecycle (welcome/verify/reset emails, SMS codes) still needs its *content* -- above all
;;;; the LINKS -- visible. DEV-TRANSPORT is both an email- and sms-provider that prints
;;;; recipient/subject/body to a stream and returns a :logged DELIVERY-RESULT. Selected by env
;;;; (HERMES_TRANSPORT=dev, or HERMES_EMAIL_IMPL=dev / HERMES_SMS_IMPL=dev) -- a hermes feature,
;;;; not app code.

(cl:in-package #:hermes)

(defclass dev-transport (email-provider sms-provider telegram-provider facebook-provider)
  ((stream :initarg :stream :initform *standard-output* :reader dev-stream)
   (last-email :initform nil :accessor dev-last-email)
   (last-telegram :initform nil :accessor dev-last-telegram)
   (last-facebook :initform nil :accessor dev-last-facebook))
  (:documentation "A transport that RENDERS a message to a stream instead of sending it.
DEV-LAST-EMAIL is the last EMAIL it was given, so a test can read what would have been sent,
its attachments included (#366). DEV-LAST-TELEGRAM is the last TELEGRAM-MESSAGE (#778), and
DEV-LAST-FACEBOOK the last FACEBOOK-POST (#822)."))

(defun make-dev-transport (&rest initargs &key stream)
  "A dev/log transport. STREAM defaults to *standard-output*."
  (declare (ignore stream))
  (apply #'make-instance 'dev-transport initargs))

(defvar *dev-counter* 0)
(defun %dev-id ()
  (format nil "dev-~D-~D" (get-universal-time) (incf *dev-counter*)))

(defun %dev-render (stream kind fields)
  "Print a labeled block of FIELDS (a plist of label -> value; blanks skipped)."
  (format stream "~&~%========== hermes:dev ~A (not sent) ==========~%" kind)
  (loop for (label value) on fields by #'cddr
        when (and value (or (not (stringp value)) (plusp (length value))))
          do (format stream "  ~12A ~A~%" label value))
  (format stream "==============================================~%")
  (finish-output stream))

(defmethod deliver ((p dev-transport) (m email))
  (setf (dev-last-email p) m)
  (%dev-render (dev-stream p) "EMAIL"
               (list "To:" (email-to m) "From:" (email-from m)
                     "Reply-To:" (email-reply-to m) "Subject:" (email-subject m)
                     "Body:" (email-text m)
                     ;; Names, types and sizes only; the content itself is not printed.
                     "Attachment:" (format nil "~{~A~^~%               ~}"
                                           (mapcar (lambda (a)
                                                     (format nil "~A (~A, ~D bytes)"
                                                             (attachment-filename a)
                                                             (attachment-content-type a)
                                                             (length (attachment-octets a))))
                                                   (email-attachments m)))))
  (make-delivery-result :provider :dev :id (%dev-id) :status :logged :raw m))

(defmethod deliver ((p dev-transport) (m sms))
  (%dev-render (dev-stream p) "SMS"
               (list "To:" (sms-to m) "From:" (sms-from m) "Body:" (sms-text m)))
  (make-delivery-result :provider :dev :id (%dev-id) :status :logged :raw m))

(defmethod deliver ((p dev-transport) (m telegram-message))
  (setf (dev-last-telegram p) m)
  (%dev-render (dev-stream p) "TELEGRAM"
               (list "Chat:" (telegram-message-chat m)
                     "Parse mode:" (telegram-message-parse-mode m)
                     "Preview:" (telegram-message-link-preview m)
                     "Photo:" (telegram-message-photo m)
                     (if (telegram-message-photo m) "Caption:" "Body:") (telegram-message-text m)))
  ;; The chat stands in for the chat id Telegram would return, so an edit or delete of this
  ;; result renders the same chat.
  (make-delivery-result :provider :dev :id (%dev-id) :status :logged
                        :destination (telegram-message-chat m) :raw m))

(defun %dev-telegram-ref (p result)
  "Check RESULT the way the Telegram backend would: UNSUPPORTED-MESSAGE for a result that is not
of a Telegram message (an email or SMS result, which the SendGrid and Twilio backends cannot
edit either), and INVALID-MESSAGE for one without a destination or id. A result from the real
Telegram backend is accepted too: its raw value is Telegram's Message object, not the
TELEGRAM-MESSAGE sent, so it is recognised by its provider."
  (unless (and (delivery-result-p result)
               (or (telegram-message-p (delivery-result-raw result))
                   (eq :telegram (delivery-result-provider result))))
    (error 'unsupported-message :provider (class-name (class-of p)) :message result))
  (unless (and (delivery-result-destination result) (delivery-result-id result))
    (error 'invalid-message
           :problem "it needs a DELIVERY-RESULT that carries a destination and an id")))

(defmethod edit-sent-message ((p dev-transport) result text &key parse-mode (link-preview :show) (part :text))
  (%dev-telegram-ref p result)
  (%check-edit text parse-mode link-preview part)
  (%dev-render (dev-stream p) "TELEGRAM EDIT"
               (list "Chat:" (delivery-result-destination result)
                     "Message:" (delivery-result-id result)
                     "Parse mode:" parse-mode
                     (if (eq part :caption) "Caption:" "Body:") text))
  ;; RAW stays the message that was sent, so the edited result can be edited or deleted too.
  (make-delivery-result :provider :dev :id (delivery-result-id result) :status :edited
                        :destination (delivery-result-destination result)
                        :raw (delivery-result-raw result)))

(defmethod delete-sent-message ((p dev-transport) result)
  (%dev-telegram-ref p result)
  (%dev-render (dev-stream p) "TELEGRAM DELETE"
               (list "Chat:" (delivery-result-destination result)
                     "Message:" (delivery-result-id result)))
  t)

(defmethod telegram-can-post ((p dev-transport) chat)
  (declare (ignore chat))
  :yes)

(defmethod telegram-added-chats ((p dev-transport) &key confirm)
  "The dev transport has no bot, so it was added to no chats."
  (declare (ignore confirm))
  '())

(defmethod deliver ((p dev-transport) (m facebook-post))
  (setf (dev-last-facebook p) m)
  (%dev-render (dev-stream p) "FACEBOOK POST"
               (list "Page:" (facebook-post-page m)
                     "Link:" (facebook-post-link m)
                     "Image:" (facebook-post-image-url m)
                     "Body:" (facebook-post-message m)))
  (make-delivery-result :provider :dev :id (%dev-id) :status :logged
                        :destination (facebook-post-page m) :raw m))

(defmethod facebook-page-health ((p dev-transport) page)
  "The dev transport posts nowhere, so every Page reads as connected."
  (values :connected (format nil "dev Page ~A" page)))

(register-impl :email "dev" (lambda () (make-dev-transport)))
(register-impl :sms   "dev" (lambda () (make-dev-transport)))
(register-impl :telegram "dev" (lambda () (make-dev-transport)))
(register-impl :facebook "dev" (lambda () (make-dev-transport)))
