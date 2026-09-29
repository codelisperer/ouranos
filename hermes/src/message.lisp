;;;; message.lisp --- the neutral messages + delivery result.
;;;;
;;;; A message is a plain value (EMAIL or SMS), vendor-independent. DELIVER (protocol.lisp)
;;;; dispatches on provider + message; the vendor wire format lives only in each backend.

(cl:in-package #:hermes)

(defstruct (attachment (:constructor %make-attachment
                           (filename content-type content disposition content-id)))
  "A file sent with an EMAIL (#366). FILENAME is the name the recipient sees. CONTENT-TYPE is
the full media type, parameters included, for example \"text/calendar; charset=utf-8;
method=REQUEST\". CONTENT is a string, sent as UTF-8, or a vector of octets. DISPOSITION is
:ATTACHMENT, or :INLINE for a part the HTML body shows, which then needs CONTENT-ID, the name
the HTML refers to it by. Built with MAKE-ATTACHMENT, which checks each of them."
  filename content-type content disposition content-id)

(defun %header-safe-p (string)
  "True for a non-empty string with no control character, so it cannot end a header early."
  (and (stringp string) (plusp (length string))
       (notany (lambda (ch) (< (char-code ch) 32)) string)))

(defun make-attachment (&key filename content-type content (disposition :attachment) content-id)
  "An ATTACHMENT, checked: FILENAME and CONTENT-TYPE are non-empty strings with no control
characters, CONTENT is a string or an octet vector, DISPOSITION is :ATTACHMENT or :INLINE, and an
inline attachment has a CONTENT-ID. Signals INVALID-MESSAGE otherwise, before anything is sent."
  (flet ((bad (what) (error 'invalid-message :problem (format nil "it needs ~A" what))))
    (unless (%header-safe-p filename) (bad "an attachment's :filename (a non-empty string with no control characters)"))
    (unless (%header-safe-p content-type) (bad "an attachment's :content-type (for example \"text/calendar; method=REQUEST\")"))
    (unless (or (stringp content) (typep content '(vector (unsigned-byte 8))))
      (bad "an attachment's :content (a string or a vector of octets)"))
    (unless (member disposition '(:attachment :inline))
      (bad "an attachment's :disposition (:attachment or :inline)"))
    (when (and (eq disposition :inline) (not (%header-safe-p content-id)))
      (bad "an inline attachment's :content-id"))
    (%make-attachment filename content-type content disposition content-id)))

(defun attachment-octets (attachment)
  "ATTACHMENT's content as octets: a string's UTF-8 encoding, or the octets it was given."
  (let ((content (attachment-content attachment)))
    (if (stringp content)
        (sb-ext:string-to-octets content :external-format :utf-8)
        (coerce content '(simple-array (unsigned-byte 8) (*))))))

(defstruct (email (:constructor %make-email
                      (&key to from subject text html reply-to attachments)))
  "A provider-neutral email. TO and FROM are address strings; TEXT is the plain body; HTML is
an optional rich body; REPLY-TO is optional. ATTACHMENTS is a list of ATTACHMENTs (#366), empty
by default."
  (to nil :type (or null string))
  (from nil :type (or null string))
  (subject "" :type string)
  (text "" :type string)
  (html nil :type (or null string))
  (reply-to nil :type (or null string))
  (attachments '() :type list))

(defun make-email (&rest keys &key to from subject text html reply-to attachments)
  "A provider-neutral EMAIL. ATTACHMENTS, when given, is a list of values from MAKE-ATTACHMENT;
anything else in it signals INVALID-MESSAGE."
  (declare (ignore to from subject text html reply-to))
  (unless (and (listp attachments) (every #'attachment-p attachments))
    (error 'invalid-message :problem ":attachments must be a list of values from MAKE-ATTACHMENT"))
  (apply #'%make-email keys))

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
