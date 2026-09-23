;;;; inbound.lisp --- inbound messages (receive), provider-neutral.
;;;;
;;;; Sending is only half of "the messenger". Apps (a CRM, etc.) also RECEIVE SMS, so the
;;;; receive machinery belongs here, not in an app. INBOUND-MESSAGE is the neutral event an
;;;; app SUBSCRIBEs to. TWILIO-WEBHOOK is the handler the app mounts on its own web route
;;;; (hyperion or otherwise): it VERIFY-TWILIO-SIGNATURE (HMAC-SHA1 over the URL + sorted
;;;; params -- forged/unsigned posts are rejected), parses the form POST into an
;;;; INBOUND-MESSAGE, and EMITs it to subscribers. Framework-neutral: the app hands the handler
;;;; the request URL, the POST params (an alist), and the X-Twilio-Signature header value.
;;;;
;;;; Ops (not code): a provisioned Twilio number pointed at the app's webhook URL, and -- for
;;;; real US traffic -- A2P 10DLC brand/campaign registration.

(cl:in-package #:hermes/inbound)

;;; --- the neutral inbound event --------------------------------------------

(defstruct (inbound-message (:constructor make-inbound-message
                                (&key from to body provider provider-id timestamp)))
  "A received message, provider-neutral. FROM/TO are E.164 phone strings; BODY is the text;
PROVIDER is a keyword (:twilio); PROVIDER-ID is the vendor message id; TIMESTAMP is CL
universal-time."
  (from nil :type (or null string))
  (to nil :type (or null string))
  (body "" :type string)
  (provider nil :type (or null keyword))
  (provider-id nil :type (or null string))
  (timestamp 0 :type unsigned-byte))

(define-condition signature-required (error)
  ((detail :initarg :detail :initform nil :reader signature-required-detail))
  (:report (lambda (c s) (format s "hermes/inbound: webhook signature verification failed~@[: ~A~]."
                                 (signature-required-detail c))))
  (:documentation "Signalled by a webhook handler when the request signature is missing or
does not verify -- the app should respond 403 and drop the request."))

;;; --- subscription ---------------------------------------------------------

(defvar *subscribers* '()
  "Functions of one INBOUND-MESSAGE, called by EMIT in subscription order.")

(defun subscribe (handler)
  "Register HANDLER (a function of one INBOUND-MESSAGE) to receive inbound events. Returns it."
  (pushnew handler *subscribers*)
  handler)

(defun unsubscribe (handler)
  "Remove HANDLER from the subscribers."
  (setf *subscribers* (remove handler *subscribers*)))

(defun emit (message)
  "Deliver MESSAGE to every subscriber (in order); return MESSAGE."
  (dolist (h (reverse *subscribers*) message) (funcall h message)))

;;; --- Twilio inbound webhook -----------------------------------------------

(defun %utf8 (string) (sb-ext:string-to-octets (or string "") :external-format :utf-8))

(defun %constant-time-string= (a b)
  "Length-independent, timing-safe string comparison."
  (and (stringp a) (stringp b)
       (let ((diff (logxor (length a) (length b))))
         (loop for i below (max (length a) (length b))
               do (setf diff (logior diff (logxor (char-code (if (< i (length a)) (char a i) #\Nul))
                                                   (char-code (if (< i (length b)) (char b i) #\Nul))))))
         (zerop diff))))

(defun %twilio-signature (url params auth-token)
  "Twilio's request signature: base64(HMAC-SHA1(auth-token, URL + each param's key+value in
key order)). PARAMS is an alist of (key . value) strings."
  (let ((data (with-output-to-string (s)
                (write-string url s)
                (dolist (kv (sort (copy-list params) #'string< :key #'car))
                  (write-string (car kv) s)
                  (write-string (or (cdr kv) "") s))))
        (mac (ironclad:make-hmac (%utf8 auth-token) :sha1)))
    (ironclad:update-hmac mac (%utf8 data))
    (b64:usb8-array-to-base64-string (ironclad:hmac-digest mac))))

(defun verify-twilio-signature (url params signature
                                &key (auth-token (uiop:getenv "TWILIO_AUTH_TOKEN")))
  "T if SIGNATURE (the X-Twilio-Signature header) matches Twilio's HMAC-SHA1 over URL followed
by each POST param's key+value in key order, keyed by AUTH-TOKEN, base64-encoded. PARAMS is an
alist of (key . value) strings. Timing-safe compare."
  (when (and auth-token signature (plusp (length auth-token)))
    (%constant-time-string= (%twilio-signature url params auth-token) signature)))

(defun %param (params name)
  (cdr (assoc name params :test #'string-equal)))

(defun %e164 (s)
  "Light E.164 normalization: a bare run of digits gets a leading +; anything else passes."
  (cond ((null s) nil)
        ((and (plusp (length s)) (char= (char s 0) #\+)) s)
        ((and (plusp (length s)) (every #'digit-char-p s)) (concatenate 'string "+" s))
        (t s)))

(defun parse-twilio-inbound (params)
  "Build a neutral INBOUND-MESSAGE from a Twilio inbound webhook's POST PARAMS (alist)."
  (make-inbound-message
   :from (%e164 (%param params "From"))
   :to (%e164 (%param params "To"))
   :body (or (%param params "Body") "")
   :provider :twilio
   :provider-id (or (%param params "MessageSid") (%param params "SmsSid"))
   :timestamp (get-universal-time)))

(defun twilio-webhook (url params signature
                       &key (auth-token (uiop:getenv "TWILIO_AUTH_TOKEN")) (emit t))
  "Handle a Twilio inbound webhook: verify SIGNATURE over URL + PARAMS (else signal
SIGNATURE-REQUIRED so the app responds 403), parse to an INBOUND-MESSAGE, EMIT it to
subscribers (unless :EMIT NIL), and return the message. URL is the exact public webhook URL
Twilio POSTed to; PARAMS the form alist; SIGNATURE the X-Twilio-Signature header."
  (unless (verify-twilio-signature url params signature :auth-token auth-token)
    (error 'signature-required :detail "missing or invalid X-Twilio-Signature"))
  (let ((message (parse-twilio-inbound params)))
    (when emit (emit message))
    message))

(defun %xml-escape (s)
  (with-output-to-string (o)
    (loop for c across (or s "") do
      (case c (#\& (write-string "&amp;" o)) (#\< (write-string "&lt;" o))
            (#\> (write-string "&gt;" o)) (#\" (write-string "&quot;" o))
            (t (write-char c o))))))

(defun twiml-message (text)
  "A TwiML document replying with a single Message TEXT (an app returns this as the webhook
response body, Content-Type application/xml, for an inline reply)."
  (format nil "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Response><Message>~A</Message></Response>"
          (%xml-escape text)))
