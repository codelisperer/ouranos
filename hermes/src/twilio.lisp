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
  "Signal CONFIGURATION-ERROR unless BASE is a URL this provider may send credentials to (#1077).

Every Twilio request carries the account SID and the auth token in an Authorization header, so
where the request goes is where those go. Checked when the provider is made rather than at the
first send, so the failure arrives where the configuration is. THE NAME IS RESOLVED AT THAT
MOMENT, once: a provider made while a name resolved locally is not re-checked if the name later
resolves elsewhere.

NO REFUSAL HERE EVER ECHOES THE BASE, OR QURI'S ERROR TEXT. The base may contain a password --
that is one of the things being refused -- and these reports reach logs and terminals. The first
version printed the base with ~S in every branch, and the parse-failure branch also appended
quri's error, which quotes the URI again, so a base of
\"https://AC1:PASSWORD@api.example.com/...\" put the password in the report twice (the review of
#1084). Each refusal names the setting and the specific problem, and the host when one was read.

WHAT IS CHECKED, AND WHY EACH PART IS HERE RATHER THAN ONLY THE OBVIOUS ONE. The first version
parsed the base with a parser of its own and judged what it found; the review of #1084 broke it
with \"http://[::1]@evil.com/x\", where that parser returned the host \"::1\" while quri -- which
is what dexador parses with -- reads the host as evil.com and \"[::1]\" as userinfo. The
equivalent rule in HERMES/BLOB then turned out to have two further holes of the same kind
(#1089), each a case the previous fix had quietly assumed away. So:

  - the base is parsed with QURI, the parser that will parse the request;
  - the scheme must be http or https. Refusing only plaintext http is not enough: for
    \"evil.com://127.0.0.1\" quri reads the scheme \"evil.com\" and the host 127.0.0.1, which a
    check looking only for \"http\" lets through;
  - userinfo is refused outright, whatever the scheme and host;
  - a query or a fragment is refused, because the request's path is appended to this value and
    would land inside them;
  - the locality rule itself is AION/HTTP-CLIENT:LOCAL-HOST-P, not a copy written here. It used
    to be a copy, and so did hermes/blob's, and the two acquired different holes (#1082);
  - a bracketed IPv6 host is refused, because such a base cannot send: usocket:socket-connect
    answers NS-HOST-NOT-FOUND-ERROR for \"[::1]\" while \"::1\" resolves. An earlier test of mine
    asserted that such a base was accepted, which was a claim about a configuration that could
    never have delivered a message;
  - an IPv4 host with a leading zero in an octet is not local, so plaintext to it is refused by
    the rule below rather than by a check of its own: AION/HTTP-CLIENT:LOCAL-HOST-P owns that,
    since PARSE-ADDRESS and the system resolver can read such a spelling differently (#1082);
  - plaintext http is allowed only to a host this machine or network can reach by itself;
  - and finally the URL THE REQUEST IS ACTUALLY BUILT FROM is parsed, by calling
    %TWILIO-ENDPOINT, and its scheme and host must be the ones just approved. No input is known
    to reach that branch now that the checks above refuse everything that could change the host
    -- appending a path cannot -- so it is a guard against a future change to %TWILIO-ENDPOINT
    rather than against any base. It is kept for that reason and has no test, because there is
    nothing left to feed it."
  (let* ((uri (handler-case (quri:uri base)
                (error ()
                  (error 'configuration-error
                         :missing "a Twilio API-BASE that parses as a URL. The value given does not, and it is not repeated here because it may contain a password"))))
         (scheme (quri:uri-scheme uri))
         (host (quri:uri-host uri)))
    (flet ((refuse (why)
             (error 'configuration-error
                    :missing (format nil "a Twilio API-BASE such as ~A. ~A"
                                     +twilio-api-base-default+ why))))
      (when (quri:uri-userinfo uri)
        (refuse (format nil "The value carries a user name or password before an \"@\", which Twilio's API does not use and which hides the host a request would reach. That host is ~S." host)))
      (unless (and scheme (or (string-equal scheme "https") (string-equal scheme "http")))
        (refuse (format nil "The scheme is ~S. Only http and https are sent, and another scheme means the host this check reads is not the host a request would reach." scheme)))
      (unless host
        (refuse "The value has no host."))
      (when (or (quri:uri-query uri) (quri:uri-fragment uri))
        (refuse "The value carries a query or a fragment, and the rest of each request's path is appended to it, so the path would end up inside them."))
      (when (and (plusp (length host)) (char= #\[ (char host 0)))
        (refuse (format nil "The host ~S is a bracketed IPv6 address, which cannot be connected to: it is looked up as a name and no such name exists. Write the address without brackets, or use a name." host)))
      (when (and (string-equal scheme "http") (not (local-host-p host)))
        (refuse (format nil "The host ~S would receive the account SID and auth token in the clear, because every request carries them in an Authorization header. Use https, or a host only this machine or this network can reach." host)))
      (let ((built (handler-case (quri:uri (%twilio-endpoint base "ACprobe"))
                     (error () nil))))
        (unless (and built
                     (equal (quri:uri-host built) host)
                     (and (quri:uri-scheme built) (string-equal (quri:uri-scheme built) scheme)))
          (refuse (format nil "A request built from this value would go to ~S over ~S, which is not the ~S over ~S this check approved."
                          (and built (quri:uri-host built)) (and built (quri:uri-scheme built))
                          host scheme)))))))

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
