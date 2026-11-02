;;;; twilio.lisp --- the Twilio SMS backend (outbound).
;;;;
;;;; A different wire shape from SendGrid -- HTTP Basic auth (AccountSid:AuthToken) and a
;;;; form-urlencoded body -- which is the point of the neutral protocol: the caller says
;;;; (deliver provider (make-sms ...)) and never sees that email is Bearer+JSON while SMS is
;;;; Basic+form. Success is 201 with a JSON body carrying the message "sid" and "status". AWS
;;;; SNS will be a sibling sms-provider with the same method shape. (Inbound is in inbound.lisp.)

(cl:in-package #:hermes)

(defparameter +twilio-api-base-default+ "https://api.twilio.com/2010-04-01"
  "Where Twilio's Messages API lives. THE ONLY PLACE THIS URL IS WRITTEN in the tree, and not
only for tidiness: upstream.sexp tracks the Twilio API version by reading what follows the API
host in this file, up to the closing quote, and every occurrence must agree. A second copy of
the URL in a refusal message broke that check, because its text continued past the version --
and then a first attempt at this very docstring broke it again by quoting the marker it was
describing. Hence no URL here but the value itself (#1077).")

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
             :initform +twilio-api-base-default+
             :reader twilio-api-base)
   (api-base-approved-local
    :initform nil :reader twilio-api-base-approved-local
    :documentation
    "THE HOST of API-BASE, when the check that runs when this provider is initialized resolved it and
approved it as local, and NIL otherwise. A host rather than T, so that PROXY-ARGUMENTS can refuse
to apply it to a request for any other host (the review of #1134). It says that
provider is initialized, so a plaintext send is not handed to a proxy (#1091).

NO INITARG, deliberately. The value is a verdict this code reached, and a caller that could pass
it could assert that a public host had been approved and have the credentials sent straight to
it, bypassing an egress proxy. SHARED-INITIALIZE sets it on every initialization, beside the
check that produces it.")
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

(defun %check-api-base (base)
  "Signal CONFIGURATION-ERROR unless BASE is a URL a Twilio request may carry credentials to
(#1077). Checked when the provider is made, so the failure arrives where the configuration is.

THE REFUSALS ARE %CHECK-CREDENTIAL-URL's, shared with SendGrid since #1092 rather than written
here: the two copies of the locality half of this rule, in hermes core and hermes/blob, acquired
three different holes between them, each a case the other's fix had already closed. What stays
here is the one part that is Twilio's own.

THE URL A REQUEST IS ACTUALLY BUILT FROM is parsed, by calling %TWILIO-ENDPOINT, and its scheme
and host must be the ones just approved. hermes/blob's holes were all of this shape -- the string
checked and the string built were different -- and %TWILIO-ENDPOINT appends a path to BASE, so
the two are not the same string here either. No input is known to reach the refusal now that the
shared check rejects everything that could move the host, so it has no test: it is a guard
against a future change to %TWILIO-ENDPOINT rather than against any base."
  (multiple-value-bind (uri approved-local)
      (%check-credential-url base
                             :setting "Twilio API-BASE"
                             :example +twilio-api-base-default+
                             :credential "the account SID and auth token"
                             :appends-path t)
    (let* ((scheme (quri:uri-scheme uri))
           (host (quri:uri-host uri))
           (built (handler-case (quri:uri (%twilio-endpoint base "ACprobe"))
                    (error () nil))))
      (unless (and built
                   (equal (quri:uri-host built) host)
                   (and (quri:uri-scheme built) (string-equal (quri:uri-scheme built) scheme)))
        (error 'configuration-error
               :missing (format nil "a Twilio API-BASE such as ~A. A request built from this value would go to ~S over ~S, which is not the ~S over ~S this check approved."
                                +twilio-api-base-default+
                                (and built (quri:uri-host built))
                                (and built (quri:uri-scheme built))
                                host scheme))))
    ;; The verdict the check above already made: see TWILIO-API-BASE-APPROVED-LOCAL (#1091).
    approved-local))

(defmethod shared-initialize :around ((p twilio) slot-names &rest initargs
                                     &key &allow-other-keys)
  "Check the API base BEFORE the slot is assigned, on every initialization (#1129).

:AROUND AND NOT :AFTER, for the reason SENDGRID's method of the same name sets out at length: an
:AFTER method runs once the slots are assigned, so a refused REINITIALIZE-INSTANCE left the
refused URL in the slot and a caller that handled the refusal and carried on sent the account SID
and auth token there. Measured at 7ca13e23, where (reinitialize-instance p :api-base
\"http://evil.example/x\") was refused and TWILIO-API-BASE then read \"http://evil.example/x\".

#1104 moved this check from INITIALIZE-INSTANCE to SHARED-INITIALIZE so that
REINITIALIZE-INSTANCE could not skip it. That closed one door; this closes the one next to it,
where the check runs but the assignment has already happened."
  (declare (ignore slot-names))
  ;; CLEARED BEFORE ANYTHING IS ASSIGNED. If the check refuses, nothing below runs and the
  ;; provider keeps the URL and the verdict it already had; but if CALL-NEXT-METHOD itself fails
  ;; part-way, after the URL slot has been assigned, the old verdict must not be left standing
  ;; beside a URL it was not about. NIL is the safe value: it means the request is proxied
  ;; normally (the review of #1134).
  (setf (slot-value p 'api-base-approved-local) nil)
  (let* ((missing '#:missing)
         (supplied (getf initargs :api-base missing))
         (value (cond ((not (eq supplied missing)) supplied)
                      ((slot-boundp p 'api-base) (twilio-api-base p))
                      (t +twilio-api-base-default+)))
         (approved-local (%check-api-base value)))
    (prog1 (call-next-method)
      (setf (slot-value p 'api-base-approved-local) approved-local))))

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
                            :read-timeout (twilio-read-timeout p)
                            ;; A plaintext send to a host the check approved as local is not
                            ;; handed to a proxy (#1091).
                            :approved-local (twilio-api-base-approved-local p)))
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
