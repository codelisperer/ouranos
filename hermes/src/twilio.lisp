;;;; twilio.lisp --- the Twilio SMS backend (outbound).
;;;;
;;;; A different wire shape from SendGrid -- HTTP Basic auth (AccountSid:AuthToken) and a
;;;; form-urlencoded body -- which is the point of the neutral protocol: the caller says
;;;; (deliver provider (make-sms ...)) and never sees that email is Bearer+JSON while SMS is
;;;; Basic+form. Success is 201 with a JSON body carrying the message "sid" and "status". AWS
;;;; SNS will be a sibling sms-provider with the same method shape. (Inbound is in inbound.lisp.)

(cl:in-package #:hermes)

(defclass twilio (sms-provider)
  ((account-sid :initarg :account-sid
                :initform (uiop:getenv "TWILIO_ACCOUNT_SID")
                :reader twilio-account-sid)
   (auth-token :initarg :auth-token
               :initform (uiop:getenv "TWILIO_AUTH_TOKEN")
               :reader twilio-auth-token)
   (from :initarg :from
         :initform (uiop:getenv "TWILIO_FROM")
         :reader twilio-from)
   (api-base :initarg :api-base
             :initform "https://api.twilio.com/2010-04-01"
             :reader twilio-api-base)
   (connect-timeout :initarg :connect-timeout
                    :initform *send-connect-timeout*
                    :reader twilio-connect-timeout)
   (read-timeout :initarg :read-timeout
                 :initform *send-read-timeout*
                 :reader twilio-read-timeout))
  (:documentation "The Twilio Messages API as an sms-provider. ACCOUNT-SID, AUTH-TOKEN and the
default FROM number come from $TWILIO_ACCOUNT_SID / $TWILIO_AUTH_TOKEN / $TWILIO_FROM.
CONNECT-TIMEOUT and READ-TIMEOUT are seconds and default from *SEND-CONNECT-TIMEOUT* and
*SEND-READ-TIMEOUT* (#1077). NIL FOR EITHER DOES NOT WAIT FOREVER: AION/HTTP-CLIENT passes a
timeout to dexador only when one is set, so NIL leaves dexador's own default of ten seconds in
force. There is no way from here to ask for an unlimited wait.

API-BASE is where the Messages API lives, and exists so a test or a local mock can be pointed
at. UNLIKE THE OTHER SLOTS IT HAS NO ENVIRONMENT DEFAULT, deliberately: every request carries
the account SID and auth token in an Authorization header, so a base read from the environment
would let a mistake in deployment configuration send Twilio credentials to another host, over
plain HTTP if the value said so. Setting it is something an app has to write in code."))

(defun make-twilio (&rest initargs &key account-sid auth-token from connect-timeout read-timeout
                                         api-base)
  "A Twilio provider. Credentials and default FROM default from the environment, and the two
timeouts from *SEND-CONNECT-TIMEOUT* and *SEND-READ-TIMEOUT* (#1077)."
  (declare (ignore account-sid auth-token from connect-timeout read-timeout api-base))
  (apply #'make-instance 'twilio initargs))

(defun %basic-auth (user pass)
  "An HTTP Basic Authorization header value for USER:PASS."
  (format nil "Basic ~A"
          (b64:string-to-base64-string (format nil "~A:~A" user pass))))

(defun %base-scheme-and-host (base)
  "BASE's scheme and its host without a port: \"http://127.0.0.1:9000/x\" gives \"http\" and
\"127.0.0.1\"; \"https://[::1]/x\" gives \"https\" and \"::1\". A base with no scheme gives NIL for
the scheme, and the whole authority for the host."
  (let* ((mark (search "://" base))
         (scheme (and mark (subseq base 0 mark)))
         (rest (if mark (subseq base (+ mark 3)) base))
         (authority (subseq rest 0 (position #\/ rest))))
    (values scheme
            (cond ((and (plusp (length authority)) (char= #\[ (char authority 0)))
                   (let ((close (position #\] authority)))
                     (if close (subseq authority 1 close) authority)))
                  (t (let ((colon (position #\: authority :from-end t)))
                       (if (and colon
                                (plusp (length (subseq authority (1+ colon))))
                                (every #'digit-char-p (subseq authority (1+ colon)))
                                ;; One colon only: more than one means a bare IPv6 address.
                                (not (find #\: authority :end colon)))
                           (subseq authority 0 colon)
                           authority)))))))

(defun %local-host-p (host)
  "Whether HOST names something only this machine or this network can reach, so sending it
requests in plaintext does not put them on the public internet.

\"localhost\" counts. An IP address is classified by AION/HTTP-CLIENT:ADDRESS-CATEGORY and counts
when it is loopback, private or link-local. Any other name is resolved, and counts only when it
resolves and every address it resolves to is one of those. A name that does not resolve does not
count: a host that cannot be reached is not a host known to be local.

This is the same rule as HERMES/BLOB's %LOCAL-ENDPOINT-P, written again rather than shared,
because hermes/blob is an aux system that deliberately does not depend on hermes core and the
two cannot see each other. Both call the same AION/HTTP-CLIENT primitives. Moving the rule into
aion/http-client, where those primitives live and which both systems already depend on, is
#1082 -- two copies of a rule about sending credentials in the clear is exactly the kind of pair
that gets changed apart."
  (flet ((local-p (address)
           (member (address-category address) '(:loopback :private :link-local))))
    (or (string-equal host "localhost")
        (let ((literal (parse-address host)))
          (if literal
              (and (local-p literal) t)
              (let ((addresses (ignore-errors (resolve-host host))))
                (and addresses (every #'local-p addresses) t)))))))

(defun %check-api-base (base)
  "Signal CONFIGURATION-ERROR when BASE is plaintext http to a host that is not local (#1077).

Every Twilio request carries the account SID and the auth token in an Authorization header, so
an http base sends them in the clear. A mistyped or misconfigured base is the case this catches,
and it is checked when the provider is made rather than at the first send, so the failure
arrives where the configuration is."
  (multiple-value-bind (scheme host) (%base-scheme-and-host base)
    (when (and scheme (string-equal scheme "http") (not (%local-host-p host)))
      (error 'configuration-error
             :missing (format nil "a Twilio API-BASE that is not plaintext http to a remote host. ~A would send the account SID and auth token in the clear, because every request carries them in an Authorization header. Use https, or a host only this machine or this network can reach" base)))))

(defmethod initialize-instance :after ((p twilio) &key)
  (%check-api-base (twilio-api-base p)))

(defun %twilio-endpoint (base sid)
  (format nil "~A/Accounts/~A/Messages.json" base sid))

(defun %twilio-status (s)
  "Normalize Twilio's status string to a keyword (neutral STATUS)."
  (cond ((null s) :unknown)
        ((member s '("queued" "accepted") :test #'string=) :queued)
        ((member s '("sending" "sent") :test #'string=) :sent)
        ((string= s "delivered") :delivered)
        ((member s '("failed" "undelivered") :test #'string=) :failed)
        (t :unknown)))

(defmethod deliver ((p twilio) (m sms))
  (let* ((sid (%require (twilio-account-sid p) "TWILIO_ACCOUNT_SID"))
         (token (%require (twilio-auth-token p) "TWILIO_AUTH_TOKEN"))
         (from (%require (or (sms-from m) (twilio-from p)) "TWILIO_FROM or sms FROM"))
         (req (make-request :method :post
                            :url (%twilio-endpoint (twilio-api-base p) sid)
                            ;; alist content -> dexador form-urlencodes it
                            :content (list (cons "To" (sms-to m))
                                           (cons "From" from)
                                           (cons "Body" (sms-text m)))
                            :connect-timeout (twilio-connect-timeout p)
                            :read-timeout (twilio-read-timeout p)))
         (resp (as-delivery :twilio
                 (send-request
                  req
                  (list (add-header "Authorization" (%basic-auth sid token))
                        (ensure-2xx :twilio)))))
         (json (jzon:parse (response-body resp))))
    (make-delivery-result
     :provider :twilio
     :id (gethash "sid" json)
     :status (%twilio-status (gethash "status" json))
     :raw resp)))

(register-impl :sms "twilio" (lambda () (make-twilio)))
