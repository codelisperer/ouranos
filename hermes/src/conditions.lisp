;;;; conditions.lisp --- hermes's failure protocol.
;;;;
;;;; House style: a root condition, specific subtypes carrying actionable detail, and -- for
;;;; a network edge -- a DELIVERY-FAILURE that surfaces the provider's own status + body, so a
;;;; 400 from SendGrid/Twilio explains itself instead of being opaque.

(cl:in-package #:hermes)

(define-condition hermes-error (error)
  ()
  (:documentation "Root of all hermes-signalled errors."))

(define-condition configuration-error (hermes-error)
  ((missing :initarg :missing :reader configuration-error-missing))
  (:report (lambda (c stream)
             (format stream "hermes is missing required configuration: ~A."
                     (configuration-error-missing c))))
  (:documentation "A provider is missing a required credential/setting (e.g. an API key or a
From address), usually because an environment variable is unset."))

(define-condition delivery-failure (hermes-error)
  ((provider :initarg :provider :initform nil :reader delivery-failure-provider)
   (status :initarg :status :initform nil :reader delivery-failure-status)
   (detail :initarg :detail :initform nil :reader delivery-failure-detail))
  (:report (lambda (c stream)
             (format stream "Delivery via ~A failed~@[ (HTTP ~A)~]~@[: ~A~]."
                     (delivery-failure-provider c)
                     (delivery-failure-status c)
                     (delivery-failure-detail c))))
  (:documentation "The provider rejected the message or the request could not be made. STATUS
is the HTTP status when there was a response; DETAIL is the provider's response body (where it
explains the failure) or a transport error."))

(define-condition unsupported-message (hermes-error)
  ((provider :initarg :provider :reader unsupported-message-provider)
   (message :initarg :message :reader unsupported-message-message))
  (:report (lambda (c stream)
             (format stream "Provider ~A cannot deliver a ~A."
                     (unsupported-message-provider c)
                     (type-of (unsupported-message-message c)))))
  (:documentation "Signalled when a provider is asked to deliver a message on a channel it
does not implement (e.g. an SMS to an email-only provider)."))

;;; --- the boundary with aion/http-client (#202) ----------------------------
;;;
;;; The HTTP client used to signal DELIVERY-FAILURE directly, which is exactly why it could
;;; not be reused: a general client has no business asserting that a *delivery* failed. It
;;; now signals AION/HTTP-CLIENT:HTTP-ERROR, and the meaning is restored here -- in the
;;; messaging framework, which is the only place "delivery" means anything.

(defmacro as-delivery (provider &body body)
  "Run BODY, translating an HTTP-ERROR into a DELIVERY-FAILURE attributed to PROVIDER.

Wraps a backend's whole outbound call rather than each stage, so a transport failure and a
rejected status arrive as the same kind of thing to a caller -- which is what DELIVER's
contract already promised."
  (let ((c (gensym)))
    `(handler-case (progn ,@body)
       (aion/http-client:http-error (,c)
         (error 'delivery-failure
                :provider ,provider
                :status (aion/http-client:http-error-status ,c)
                :detail (or (aion/http-client:http-error-detail ,c)
                            (aion/http-client:http-error-body ,c)))))))
