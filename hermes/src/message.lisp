;;;; message.lisp --- the neutral messages + delivery result.
;;;;
;;;; A message is a plain value (EMAIL or SMS), vendor-independent. DELIVER (protocol.lisp)
;;;; dispatches on provider + message; the vendor wire format lives only in each backend.

(cl:in-package #:hermes)

(defstruct (email (:constructor make-email
                      (&key to from subject text html reply-to)))
  "A provider-neutral email. TO and FROM are address strings; TEXT is the plain body; HTML is
an optional rich body; REPLY-TO is optional."
  (to nil :type (or null string))
  (from nil :type (or null string))
  (subject "" :type string)
  (text "" :type string)
  (html nil :type (or null string))
  (reply-to nil :type (or null string)))

(defstruct (sms (:constructor make-sms (&key to from text)))
  "A provider-neutral SMS. TO/FROM are E.164 phone strings (FROM may come from the provider's
default); TEXT is the message body."
  (to nil :type (or null string))
  (from nil :type (or null string))
  (text "" :type string))

(defstruct (delivery-result (:constructor make-delivery-result
                                (&key provider id status raw)))
  "The neutral outcome of a successful DELIVER: which PROVIDER handled it, the provider's
message ID (for later status/webhook correlation), a normalized STATUS keyword, and the RAW
provider response for escape-hatch access."
  (provider nil :type (or null keyword))
  (id nil :type (or null string))
  (status nil :type (or null keyword))
  (raw nil))
