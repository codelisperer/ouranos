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
that gets changed apart, and the review of #1084 found that both copies had the same hole."
  (flet ((local-p (address)
           (member (address-category address) '(:loopback :private :link-local))))
    (or (string-equal host "localhost")
        (let ((literal (parse-address host)))
          (if literal
              (and (local-p literal) t)
              (let ((addresses (ignore-errors (resolve-host host))))
                (and addresses (every #'local-p addresses) t)))))))

(defun %check-api-base (base)
  "Signal CONFIGURATION-ERROR unless BASE is a URL this provider may send credentials to (#1077).

Every Twilio request carries the account SID and the auth token in an Authorization header, so
where the request goes is where those go. Checked when the provider is made rather than at the
first send, so the failure arrives where the configuration is. THE NAME IS RESOLVED AT THAT
MOMENT, once: a provider made while a name resolved locally is not re-checked if the name later
resolves elsewhere.

WHAT IS CHECKED, AND WHY EACH PART IS HERE RATHER THAN ONLY THE OBVIOUS ONE. The first version of
this check parsed the base with a parser of its own and judged the scheme and host it found. The
review of #1084 broke it with \"http://[::1]@evil.com/x\", where that parser returned the host
\"::1\" while quri -- which is what dexador parses with -- reads the host as evil.com and
\"[::1]\" as userinfo. The equivalent rule in HERMES/BLOB then turned out to have two further
holes of the same kind (#1089), and each one was a case the previous fix's docstring had quietly
assumed away. So:

  - the base is parsed with QURI, the parser that will parse the request;
  - the scheme must be http or https. Only refusing plaintext http is not enough: for
    \"evil.com://127.0.0.1\" quri reads the scheme \"evil.com\" and the host 127.0.0.1, which a
    check looking only for \"http\" lets through;
  - userinfo is refused outright, whatever the scheme and host. Twilio's API takes none, so
    there is nothing to weigh against refusing it, and its only effects here are to hide the
    real host from a reader and to defeat this check;
  - a query or a fragment is refused, because the request's path is appended to this value and
    would land inside them;
  - plaintext http is allowed only to a host this machine or network can reach by itself;
  - and finally the URL THE REQUEST IS ACTUALLY BUILT FROM is parsed, by calling
    %TWILIO-ENDPOINT, and its scheme and host must be the ones just approved. That last step is
    the one the hermes/blob holes would all have failed: there, the string checked and the string
    built were different, and every fix that did not compare them left another way through."
  (let* ((uri (handler-case (quri:uri base)
                (error (e)
                  (error 'configuration-error
                         :missing (format nil "a Twilio API-BASE that parses as a URL. ~S did not: ~A"
                                          base e)))))
         (scheme (quri:uri-scheme uri))
         (host (quri:uri-host uri)))
    (flet ((refuse (why)
             (error 'configuration-error
                    :missing (format nil "a Twilio API-BASE such as ~A. ~A"
                                     +twilio-api-base-default+ why))))
      (when (quri:uri-userinfo uri)
        ;; The base is NOT echoed here, unlike every other message in this function: the part
        ;; being complained about is a user name and password, and this text reaches a log or a
        ;; terminal. The host is what the operator needs in order to see what went wrong.
        (refuse (format nil "the value carries a user name or password before an \"@\", which Twilio's API does not use and which hides the host a request would go to. That host is ~S."
                        host)))
      (unless (and scheme (or (string-equal scheme "https") (string-equal scheme "http")))
        (refuse (format nil "~S has the scheme ~S. Only http and https are sent; another scheme means the host this check reads is not the host a request would reach."
                        base scheme)))
      (unless host
        (refuse (format nil "~S has no host." base)))
      (when (or (quri:uri-query uri) (quri:uri-fragment uri))
        (refuse (format nil "~S carries a query or a fragment. The rest of each request's path is appended to this value, so it would end up inside them."
                        base)))
      (when (and (string-equal scheme "http") (not (%local-host-p host)))
        (refuse (format nil "the host ~S would receive the account SID and auth token in the clear, because every request carries them in an Authorization header. Use https, or a host only this machine or this network can reach."
                        host)))
      ;; The string the request is built from, not the string that was configured.
      (let* ((built (handler-case (quri:uri (%twilio-endpoint base "ACprobe"))
                      (error () nil))))
        (unless (and built
                     (equal (quri:uri-host built) host)
                     (and (quri:uri-scheme built) (string-equal (quri:uri-scheme built) scheme)))
          (refuse (format nil "a request built from ~S would go to ~S over ~S, which is not the ~S over ~S this check approved."
                          base (and built (quri:uri-host built)) (and built (quri:uri-scheme built))
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
