;;;; sendgrid.lisp --- the SendGrid (Twilio SendGrid) email backend.
;;;;
;;;; Maps a neutral EMAIL to the SendGrid v3 mail/send JSON and posts it with a Bearer key.
;;;; Success is 202 with an empty body and an X-Message-Id header (the id we return). All
;;;; SendGrid-specific shape lives here; the DELIVER protocol and the caller stay neutral. AWS
;;;; SES will be a sibling email-provider with the same method shape.

(cl:in-package #:hermes)

(defclass sendgrid (email-provider)
  ((api-key :initarg :api-key
            :initform (uiop:getenv "SENDGRID_API_KEY")
            :reader sendgrid-api-key)
   (endpoint :initarg :endpoint
             :initform "https://api.sendgrid.com/v3/mail/send"
             :reader sendgrid-endpoint))
  (:documentation "The SendGrid v3 mail/send API as an email-provider. API-KEY defaults to
$SENDGRID_API_KEY."))

(defun make-sendgrid (&rest initargs &key api-key endpoint)
  "A SendGrid provider. API-KEY/ENDPOINT default from the environment."
  (declare (ignore api-key endpoint))
  (apply #'make-instance 'sendgrid initargs))

(defun %obj (&rest kvs)
  "A jzon object (string-keyed hash-table) from KVS, a flat key/value plist."
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on kvs by #'cddr do (setf (gethash k h) v))
    h))

(defun %sendgrid-content (m)
  "The SendGrid content array: plain first (required), then html when present."
  (apply #'vector
         (%obj "type" "text/plain" "value" (email-text m))
         (when (email-html m)
           (list (%obj "type" "text/html" "value" (email-html m))))))

(defun %sendgrid-body (m)
  "The SendGrid v3 mail/send request body for the neutral email M."
  (let ((body (%obj "personalizations"
                    (vector (%obj "to" (vector (%obj "email" (email-to m)))))
                    "from" (%obj "email" (email-from m))
                    "subject" (email-subject m)
                    "content" (%sendgrid-content m))))
    (when (email-reply-to m)
      (setf (gethash "reply_to" body) (%obj "email" (email-reply-to m))))
    body))

(defmethod deliver ((p sendgrid) (m email))
  (let* ((key (%require (sendgrid-api-key p) "SENDGRID_API_KEY"))
         (req (make-request :method :post
                            :url (sendgrid-endpoint p)
                            :content (jzon:stringify (%sendgrid-body m))))
         (resp (as-delivery :sendgrid
                 (send-request
                  req
                  (list (add-header "Authorization" (format nil "Bearer ~A" key))
                        (add-header "Content-Type" "application/json")
                        (ensure-2xx :sendgrid))))))
    (make-delivery-result
     :provider :sendgrid
     :id (header-value (response-headers resp) "x-message-id")
     :status :accepted
     :raw resp)))

(register-impl :email "sendgrid" (lambda () (make-sendgrid)))
