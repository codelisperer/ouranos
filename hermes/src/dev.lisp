;;;; dev.lisp --- the dev/log transport: render a message instead of sending it.
;;;;
;;;; Local dev has no SMTP/SMS creds and must not hit real providers, but the account
;;;; lifecycle (welcome/verify/reset emails, SMS codes) still needs its *content* -- above all
;;;; the LINKS -- visible. DEV-TRANSPORT is both an email- and sms-provider that prints
;;;; recipient/subject/body to a stream and returns a :logged DELIVERY-RESULT. Selected by env
;;;; (HERMES_TRANSPORT=dev, or HERMES_EMAIL_IMPL=dev / HERMES_SMS_IMPL=dev) -- a hermes feature,
;;;; not app code.

(cl:in-package #:hermes)

(defclass dev-transport (email-provider sms-provider)
  ((stream :initarg :stream :initform *standard-output* :reader dev-stream))
  (:documentation "A transport that RENDERS a message to a stream instead of sending it."))

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
  (%dev-render (dev-stream p) "EMAIL"
               (list "To:" (email-to m) "From:" (email-from m)
                     "Reply-To:" (email-reply-to m) "Subject:" (email-subject m)
                     "Body:" (email-text m)))
  (make-delivery-result :provider :dev :id (%dev-id) :status :logged :raw m))

(defmethod deliver ((p dev-transport) (m sms))
  (%dev-render (dev-stream p) "SMS"
               (list "To:" (sms-to m) "From:" (sms-from m) "Body:" (sms-text m)))
  (make-delivery-result :provider :dev :id (%dev-id) :status :logged :raw m))

(register-impl :email "dev" (lambda () (make-dev-transport)))
(register-impl :sms   "dev" (lambda () (make-dev-transport)))
