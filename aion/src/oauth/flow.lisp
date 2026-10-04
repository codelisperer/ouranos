;;;; flow.lisp --- discovery, registration, sign-in, refresh and disconnect

(cl:in-package #:aion/oauth)

;;; --- conditions ------------------------------------------------------------------------

(define-condition oauth-error (error)
  ((detail :initarg :detail :initform nil :reader oauth-error-detail))
  (:report (lambda (c s) (format s "aion/oauth: ~A" (oauth-error-detail c))))
  (:documentation "The root of aion/oauth's errors. DETAIL never holds a token, a code or a
verifier."))

(define-condition url-refused (oauth-error) ()
  (:documentation "A URL a server supplied is not https, and not http on a loopback address."))

(define-condition metadata-refused (oauth-error) ()
  (:documentation "No metadata document could be found, or the one found did not check out:
a protected resource whose `resource' is not the server's URI, an authorization server whose
`issuer' is not the issuer it was fetched for, or one that does not offer PKCE with S256."))

(define-condition no-client (oauth-error) ()
  (:documentation "The authorization server offers no way for this app to get a client id:
none was pre-registered for it, it does not take client ID metadata documents or the app
publishes none, and it offers no dynamic registration."))

(define-condition unknown-sign-in (oauth-error) ()
  (:documentation "FINISH-SIGN-IN got a `state' that is not waiting here. Either the sign-in
expired or was already finished, or it was started on another instance of the app, which
needs a store the instances share."))

(define-condition wrong-user (oauth-error) ()
  (:documentation "The browser came back in a session whose principal is not the one that
started the sign-in. The code is not redeemed, so one user cannot link their account on the
service to another user."))

(define-condition sign-in-failed (oauth-error)
  ((code :initarg :code :initform nil :reader sign-in-failed-code))
  (:documentation "The sign-in did not produce tokens. CODE is the OAuth error code when the
server gave one that can be trusted; a response whose `iss' did not match gives none."))

(define-condition refresh-failed (oauth-error) ()
  (:documentation "A refresh could not reach the authorization server, or got an answer that
was not a token. The stored tokens are kept, because the failure may be temporary. A refresh
the server refused with `invalid_grant', `invalid_client' or `unauthorized_client' is not
this: those tokens are deleted, and ACCESS-TOKEN returns NIL."))

;;; --- the broker ------------------------------------------------------------------------

(defstruct (broker (:constructor make-broker
                       (&key store redirect-uri (client-name "aion/oauth client")
                             (application-type "web") client-metadata-url pre-registered
                             (timeout 30) (sign-in-lifetime 600) (metadata-lifetime 3600)
                             (metadata-grace 60)
                             (address-policy #'http:address-category)
                             (resolve #'http:resolve-host))))
  "What an app's sign-ins share.

STORE implements the store protocol. REDIRECT-URI is where the browser comes back, the app's
route for FINISH-SIGN-IN. CLIENT-NAME is what an authorization server shows the user.
APPLICATION-TYPE is sent with a dynamic registration: \"web\" for an app served from a host,
\"native\" for a desktop app or a localhost redirect. CLIENT-METADATA-URL is the https URL
where the app publishes its client ID metadata document (CLIENT-METADATA-DOCUMENT), or NIL.
PRE-REGISTERED is an alist of (ISSUER . CLIENT-ID) for clients registered by hand. TIMEOUT
bounds each request, in seconds, and SIGN-IN-LIFETIME how long a started sign-in waits.
ADDRESS-POLICY and RESOLVE are passed to FETCH-PUBLIC; tests use them to allow 127.0.0.1.

METADATA-LIFETIME is how many seconds the protected-resource metadata a token was issued under
is kept before ACCESS-TOKEN fetches it again to check that the resource still names the same
authorization server. It is also fetched again after the server refuses a token, and after a
sign-in. When that fetch fails, the expired answer is used for METADATA-GRACE seconds more,
and never renewed; after that ACCESS-TOKEN signals OAUTH-ERROR until a fetch succeeds."
  store redirect-uri client-name application-type client-metadata-url pre-registered
  timeout sign-in-lifetime metadata-lifetime metadata-grace address-policy resolve
  (metadata-cache (make-hash-table :test #'equal))
  (metadata-lock (sb-thread:make-mutex :name "aion/oauth metadata cache")))

;;; --- URLs ------------------------------------------------------------------------------

(defun %loopback-host-p (host)
  (member host '("127.0.0.1" "localhost" "::1" "[::1]") :test #'string-equal))

(defun %default-port-p (scheme port)
  (or (null port)
      (and (string-equal scheme "https") (= port 443))
      (and (string-equal scheme "http") (= port 80))))

(defun canonical-resource (url)
  "URL as the canonical URI of a resource (RFC 8707, and the MCP specification): the scheme
and host lower-cased, the default port and any fragment dropped, and no trailing slash on the
path."
  (let* ((uri (quri:uri url))
         (scheme (string-downcase (or (quri:uri-scheme uri) "")))
         (host (string-downcase (or (quri:uri-host uri) "")))
         (port (quri:uri-port uri))
         (path (string-right-trim "/" (or (quri:uri-path uri) "")))
         (query (quri:uri-query uri)))
    (format nil "~A://~A~:[:~D~;~*~]~A~@[?~A~]"
            scheme host (%default-port-p scheme port) port path query)))

(defun %check-url (url what)
  "Signal URL-REFUSED unless URL is https, or http on a loopback host. WHAT names it."
  (let* ((uri (and (stringp url) (ignore-errors (quri:uri url))))
         (scheme (and uri (quri:uri-scheme uri)))
         (host (and uri (quri:uri-host uri))))
    (unless (and host (or (string-equal scheme "https")
                          (and (string-equal scheme "http") (%loopback-host-p host))))
      (error 'url-refused :detail (format nil "the ~A is not an https URL" what)))
    url))

(defun %fetch (broker method url &key content headers)
  "One request to URL, a URL from a server, through FETCH-PUBLIC: the address is checked and
the connection pinned to it, and no redirect is followed, so a code, a refresh token or client
metadata is never sent anywhere else.

On Windows FETCH-PUBLIC cannot pin a connection, and this signals PINNED-CONNECT-UNSUPPORTED,
as #295 decided for every URL a server or a user supplies: there is no fallback that connects
without the check. Sign-in is therefore not available on Windows until aion/http-client can
pin a connection there."
  (handler-case
      (http:fetch-public url :method method :headers headers :content content
                             :max-redirects 0 :max-body-bytes (* 1024 1024)
                             :connect-timeout (broker-timeout broker)
                             :read-timeout (broker-timeout broker)
                             :address-policy (broker-address-policy broker)
                             :resolve (broker-resolve broker))
    (http:pinned-connect-unsupported (e) (error e))
    (http:too-many-redirects ()
      (error 'oauth-error :detail (format nil "~A answered with a redirect, which is not followed"
                                          (%host-of url))))
    (http:fetch-refused (e)
      (error 'url-refused :detail (format nil "~A was refused: ~(~A~)" (http:fetch-refused-host e)
                                          (http:fetch-refused-reason e))))
    (http:http-error ()
      (error 'oauth-error :detail (format nil "a request to ~A failed" (%host-of url))))))

(defun %host-of (url) (or (ignore-errors (quri:uri-host (quri:uri url))) "?"))

(defun %json-object (response)
  (and (= 200 (http:response-status response))
       (let ((v (ignore-errors (jzon:parse (http:response-body response)))))
         (and (hash-table-p v) v))))

(defun %get-json (broker url)
  (%json-object (%fetch broker :get url :headers '(("Accept" . "application/json")))))

(defun %strings (value)
  (and (vectorp value) (not (stringp value))
       (remove-if-not #'stringp (coerce value 'list))))

;;; --- WWW-Authenticate ------------------------------------------------------------------

(defun parse-challenge (header)
  "The parameters of the Bearer challenge in HEADER, a WWW-Authenticate value, as an alist of
lower-cased names to values, or NIL."
  (when (stringp header)
    (let ((start (search "bearer" header :test #'char-equal)))
      (when start
        (let ((i (+ start 6)) (n (length header)) (params '()))
          (loop
            (loop while (and (< i n) (member (char header i) '(#\Space #\Tab #\,))) do (incf i))
            (when (>= i n) (return))
            (let ((eq (position #\= header :start i)))
              (unless eq (return))
              (let ((name (string-downcase (string-trim " " (subseq header i eq))))
                    (value nil))
                (when (find #\Space name) (return))   ; the next scheme's name
                (setf i (1+ eq))
                (if (and (< i n) (char= #\" (char header i)))
                    (let ((out (make-string-output-stream)))
                      (incf i)
                      (loop while (and (< i n) (char/= #\" (char header i)))
                            do (when (and (char= #\\ (char header i)) (< (1+ i) n)) (incf i))
                               (write-char (char header i) out)
                               (incf i))
                      (incf i)
                      (setf value (get-output-stream-string out)))
                    (let ((end (or (position #\, header :start i) n)))
                      (setf value (string-trim " " (subseq header i end)) i end)))
                (push (cons name value) params))))
          (nreverse params))))))

;;; --- discovery -------------------------------------------------------------------------

(defstruct metadata
  "What discovery found and checked. RESOURCE is the canonical URI, ISSUER the authorization
server chosen. SCOPES is the protected resource's scopes_supported; CHALLENGE-SCOPE the 401's
scope parameter. AS-SCOPES is the authorization server's scopes_supported."
  resource issuer authorization-endpoint token-endpoint registration-endpoint
  revocation-endpoint scopes as-scopes challenge-scope cimd-p iss-required metadata-url)

(defun %well-known (url suffix)
  "The well-known URL for SUFFIX at URL's origin, with URL's path inserted after it when there
is one (RFC 8414 section 3.1, RFC 9728 section 3.1)."
  (let* ((uri (quri:uri url))
         (path (string-right-trim "/" (or (quri:uri-path uri) "")))
         (port (quri:uri-port uri))
         (scheme (quri:uri-scheme uri)))
    (format nil "~A://~A~:[:~D~;~*~]/.well-known/~A~A"
            scheme (quri:uri-host uri) (%default-port-p scheme port) port suffix path)))

(defun %resource-metadata (broker resource challenge)
  (let* ((from-challenge (cdr (assoc "resource_metadata" challenge :test #'string=)))
         (candidates (if from-challenge
                         (list from-challenge)
                         (remove-duplicates
                          (list (%well-known resource "oauth-protected-resource")
                                (%well-known (canonical-resource
                                              (let ((u (quri:uri resource)))
                                                (format nil "~A://~A~@[:~D~]"
                                                        (quri:uri-scheme u) (quri:uri-host u)
                                                        (quri:uri-port u))))
                                             "oauth-protected-resource"))
                          :test #'string= :from-end t))))
    (dolist (url candidates
                 (error 'metadata-refused :detail "no protected resource metadata was found"))
      (%check-url url "protected resource metadata URL")
      (let ((doc (%get-json broker url)))
        (when doc
          (let ((claimed (gethash "resource" doc)))
            (unless (and (stringp claimed) (string= (canonical-resource claimed) resource))
              (error 'metadata-refused
                     :detail "the protected resource metadata names a different resource"))
            (return (values doc url))))))))

(defun %as-metadata-urls (issuer)
  (let* ((uri (quri:uri issuer))
         (path (string-right-trim "/" (or (quri:uri-path uri) ""))))
    (if (plusp (length path))
        (list (%well-known issuer "oauth-authorization-server")
              (%well-known issuer "openid-configuration")
              (format nil "~A/.well-known/openid-configuration" (string-right-trim "/" issuer)))
        (list (%well-known issuer "oauth-authorization-server")
              (%well-known issuer "openid-configuration")))))

(defun %as-metadata (broker issuer)
  "ISSUER's metadata, checked: its `issuer' is identical to ISSUER, and it offers S256."
  (%check-url issuer "authorization server")
  (dolist (url (%as-metadata-urls issuer) nil)
    (let ((doc (%get-json broker url)))
      (when doc
        (unless (equal (gethash "issuer" doc) issuer)
          (error 'metadata-refused
                 :detail "the authorization server metadata names a different issuer"))
        (unless (member "S256" (%strings (gethash "code_challenge_methods_supported" doc))
                        :test #'string=)
          (error 'metadata-refused :detail "the authorization server does not offer PKCE with S256"))
        (return doc)))))

(defun discover (broker resource-url &key challenge expected-issuer)
  "Find and check the authorization server for the protected resource at RESOURCE-URL.
CHALLENGE is the WWW-Authenticate value of the 401 that started this, or NIL. EXPECTED-ISSUER,
when given, is the only issuer accepted. Returns a METADATA."
  (%check-url resource-url "protected resource")
  (let* ((resource (canonical-resource resource-url))
         (params (parse-challenge challenge))
         (prm-url nil)
         (prm (multiple-value-bind (doc url) (%resource-metadata broker resource params)
                (setf prm-url url)
                doc))
         (issuers (%strings (gethash "authorization_servers" prm)))
         (issuers (if expected-issuer
                      (remove expected-issuer issuers :test-not #'string=)
                      issuers)))
    (dolist (issuer issuers
                    (error 'metadata-refused :detail "no authorization server checked out"))
      (let ((doc (ignore-errors (%as-metadata broker issuer))))
        (when doc
          (flet ((endpoint (name &optional required)
                   (let ((url (gethash name doc)))
                     (cond ((stringp url) (%check-url url name))
                           (required (error 'metadata-refused
                                            :detail (format nil "the metadata has no ~A" name)))))))
            (return
              (make-metadata
               :resource resource :issuer issuer :metadata-url prm-url
               :authorization-endpoint (endpoint "authorization_endpoint" t)
               :token-endpoint (endpoint "token_endpoint" t)
               :registration-endpoint (endpoint "registration_endpoint")
               :revocation-endpoint (endpoint "revocation_endpoint")
               :scopes (%strings (gethash "scopes_supported" prm))
               :as-scopes (%strings (gethash "scopes_supported" doc))
               :challenge-scope (cdr (assoc "scope" params :test #'string=))
               :cimd-p (eq t (gethash "client_id_metadata_document_supported" doc))
               :iss-required (eq t (gethash "authorization_response_iss_parameter_supported"
                                            doc))))))))))

;;; --- the client id ---------------------------------------------------------------------

(defun %object (&rest kv)
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on kv by #'cddr do (setf (gethash k h) v))
    h))

(defun client-metadata-document (broker)
  "The JSON of this app's client ID metadata document, to publish at the broker's
CLIENT-METADATA-URL. Its client_id is that URL, as the specification requires."
  (jzon:stringify
   (%object "client_id" (broker-client-metadata-url broker)
            "client_name" (broker-client-name broker)
            "redirect_uris" (vector (broker-redirect-uri broker))
            "grant_types" (vector "authorization_code" "refresh_token")
            "response_types" (vector "code")
            "token_endpoint_auth_method" "none"
            "application_type" (broker-application-type broker))))

(defun %client-metadata-url-p (url)
  "Whether URL can identify a client ID metadata document: an https URL with a path."
  (let ((uri (and (stringp url) (ignore-errors (quri:uri url)))))
    (and uri (string-equal "https" (quri:uri-scheme uri))
         (let ((path (quri:uri-path uri))) (and path (> (length path) 1))))))

(defun %client-id (broker metadata)
  "The client id to use with METADATA's issuer, in the specification's order: pre-registered,
a client ID metadata document, one registered earlier, then a dynamic registration."
  (let ((issuer (metadata-issuer metadata))
        (store (broker-store broker))
        (redirect (broker-redirect-uri broker)))
    (or (cdr (assoc issuer (broker-pre-registered broker) :test #'string=))
        (and (metadata-cimd-p metadata) (%client-metadata-url-p (broker-client-metadata-url broker))
             (broker-client-metadata-url broker))
        (get-client store issuer redirect)
        (let ((endpoint (metadata-registration-endpoint metadata)))
          (unless endpoint
            (error 'no-client :detail (format nil "no way to get a client id from ~A" issuer)))
          (let* ((response (%fetch broker :post endpoint
                                   :headers '(("Content-Type" . "application/json")
                                              ("Accept" . "application/json"))
                                   :content (jzon:stringify
                                             (%object "client_name" (broker-client-name broker)
                                                      "redirect_uris" (vector redirect)
                                                      "grant_types" (vector "authorization_code"
                                                                            "refresh_token")
                                                      "response_types" (vector "code")
                                                      "token_endpoint_auth_method" "none"
                                                      "application_type"
                                                      (broker-application-type broker)))))
                 (doc (and (<= 200 (http:response-status response) 299)
                           (ignore-errors (jzon:parse (http:response-body response)))))
                 (id (and (hash-table-p doc) (gethash "client_id" doc))))
            (unless (stringp id)
              (error 'no-client :detail (format nil "registration with ~A failed (status ~D)"
                                                issuer (http:response-status response))))
            (put-client store issuer redirect id)
            (log:info "aion/oauth: client registered" :issuer issuer)
            id)))))

;;; --- PKCE and state --------------------------------------------------------------------

(defun %base64url (octets)
  (string-right-trim "=" (substitute #\_ #\/ (substitute #\- #\+ (cl-base64:usb8-array-to-base64-string octets)))))

(defun %random-token () (%base64url (rnd:random-octets 32)))

(defun %challenge (verifier)
  (%base64url (ironclad:digest-sequence :sha256 (sb-ext:string-to-octets verifier :external-format :ascii))))

(defun %scope-list (string)
  (and (stringp string) (remove "" (uiop:split-string string :separator " ") :test #'string=)))

;;; --- sign-in ---------------------------------------------------------------------------

(defun start-sign-in (broker principal connection resource-url &key challenge scopes
                                                                     expected-issuer)
  "Begin a sign-in for PRINCIPAL to CONNECTION (a name), whose server is at RESOURCE-URL.
Returns the URL to send PRINCIPAL's browser to, and the list of scopes it requests, so the
app can show them first. An app calls this from an action the user took, never from a turn.

CHALLENGE is the WWW-Authenticate value that showed a sign-in is needed, if there was one.
SCOPES, when given, are the scopes this connection needs. Otherwise the challenge's scope is
used, then the protected resource's scopes_supported. The scopes of an earlier sign-in to the
same connection are kept, so a step-up for more scope does not lose what was granted."
  (unless principal
    (error 'wrong-user :detail "a sign-in needs the principal of a signed-in user"))
  (let* ((metadata (discover broker resource-url :challenge challenge
                                                  :expected-issuer expected-issuer))
         (client-id (%client-id broker metadata))
         (earlier (let ((ts (get-token (broker-store broker) principal connection)))
                    (and ts (%scope-list (token-set-scope ts)))))
         (wanted (or scopes (%scope-list (metadata-challenge-scope metadata))
                     (metadata-scopes metadata)))
         (wanted (remove-duplicates (append earlier wanted) :test #'string= :from-end t))
         (wanted (if (and (member "offline_access" (metadata-as-scopes metadata) :test #'string=)
                          (not (member "offline_access" wanted :test #'string=)))
                     (append wanted (list "offline_access"))
                     wanted))
         (state (%random-token))
         (verifier (%random-token)))
    (put-pending (broker-store broker) state
                 (make-pending :principal principal :connection connection
                                :resource (metadata-resource metadata)
                                :issuer (metadata-issuer metadata)
                                :client-id client-id
                                :verifier (secret:make-secret verifier)
                                :token-endpoint (metadata-token-endpoint metadata)
                                :revocation-endpoint (metadata-revocation-endpoint metadata)
                                :iss-required (metadata-iss-required metadata)
                                :scope (format nil "~{~A~^ ~}" wanted)
                                :metadata-url (metadata-metadata-url metadata)
                                :expires-at (+ (get-universal-time)
                                               (broker-sign-in-lifetime broker))))
    (log:info "aion/oauth: sign-in started" :connection connection :issuer (metadata-issuer metadata))
    (values (format nil "~A~:[?~;&~]~A" (metadata-authorization-endpoint metadata)
                    (find #\? (metadata-authorization-endpoint metadata))
                    (quri:url-encode-params
                     (append (list (cons "response_type" "code")
                                   (cons "client_id" client-id)
                                   (cons "redirect_uri" (broker-redirect-uri broker)))
                             (when wanted (list (cons "scope" (format nil "~{~A~^ ~}" wanted))))
                             (list (cons "state" state)
                                   (cons "code_challenge" (%challenge verifier))
                                   (cons "code_challenge_method" "S256")
                                   (cons "resource" (metadata-resource metadata))))))
            wanted)))

(defun %param (parameters name)
  (cdr (assoc name parameters :test #'string=)))

(defun %token-set-from (response pending &optional old)
  "A TOKEN-SET from a token endpoint's RESPONSE. OLD is the set being refreshed: its refresh
token is kept when the server did not rotate it."
  (let* ((doc (and (= 200 (http:response-status response))
                   (ignore-errors (jzon:parse (http:response-body response)))))
         (access (and (hash-table-p doc) (gethash "access_token" doc)))
         (type (and (hash-table-p doc) (gethash "token_type" doc))))
    ;; A token this client cannot send as Bearer, such as a DPoP one, would only fail later.
    (unless (and (stringp access) (plusp (length access))
                 (stringp type) (string-equal type "Bearer"))
      (return-from %token-set-from nil))
    (let ((refresh (gethash "refresh_token" doc))
          (expires-in (gethash "expires_in" doc)))
      (make-token-set
       :access (secret:make-secret access)
       :refresh (cond ((stringp refresh) (secret:make-secret refresh))
                      (old (token-set-refresh old)))
       :expires-at (and (integerp expires-in) (+ (get-universal-time) expires-in))
       :scope (let ((s (gethash "scope" doc)))
                (if (stringp s) s (if old (token-set-scope old) (pending-scope pending))))
       :resource (if old (token-set-resource old) (pending-resource pending))
       :issuer (if old (token-set-issuer old) (pending-issuer pending))
       :client-id (if old (token-set-client-id old) (pending-client-id pending))
       :token-endpoint (if old (token-set-token-endpoint old) (pending-token-endpoint pending))
       :revocation-endpoint (if old (token-set-revocation-endpoint old)
                                (pending-revocation-endpoint pending))
       :metadata-url (if old (token-set-metadata-url old) (pending-metadata-url pending))))))

(defun %error-code-of (response)
  (let ((doc (ignore-errors (jzon:parse (http:response-body response)))))
    (and (hash-table-p doc) (let ((e (gethash "error" doc))) (and (stringp e) e)))))

(defun finish-sign-in (broker principal parameters)
  "Finish a sign-in from PARAMETERS, the query parameters the browser came back with, as an
alist of strings. PRINCIPAL is the principal of the app session the browser came back in; it
must be the one that started the sign-in. Returns the principal and the connection's name.

Checked before the code is redeemed: the `state' is waiting here and has not expired
(UNKNOWN-SIGN-IN); the principal matches (WRONG-USER); and `iss', when present or required, is
the issuer recorded when the sign-in started (RFC 9207). On an `iss' mismatch the response's
error fields are not used. Then the code is exchanged, with the PKCE verifier and `resource',
and the tokens are stored."
  (let ((pending (let ((state (%param parameters "state")))
                   (and (stringp state) (take-pending (broker-store broker) state)))))
    (when (or (null pending) (< (pending-expires-at pending) (get-universal-time)))
      (error 'unknown-sign-in
             :detail "this sign-in is not waiting here: it expired, it was already finished, or it was started on another instance of the app, which needs a store the instances share"))
    (unless (and principal (equal principal (pending-principal pending)))
      (error 'wrong-user :detail "the sign-in came back in another user's session, or in none"))
    (let ((iss (%param parameters "iss")))
      (when (if iss
                (not (string= iss (pending-issuer pending)))
                (pending-iss-required pending))
        (error 'sign-in-failed :detail "the authorization response's iss is not the expected issuer")))
    (let ((error-code (%param parameters "error")))
      (when error-code
        (error 'sign-in-failed :code error-code
                               :detail (format nil "the authorization server answered ~A" error-code))))
    (let ((code (%param parameters "code")))
      (unless (stringp code)
        (error 'sign-in-failed :detail "the authorization response has no code"))
      (let* ((response (%fetch broker :post (pending-token-endpoint pending)
                               :headers '(("Accept" . "application/json"))
                               :content (list (cons "grant_type" "authorization_code")
                                              (cons "code" code)
                                              (cons "redirect_uri" (broker-redirect-uri broker))
                                              (cons "client_id" (pending-client-id pending))
                                              (cons "code_verifier"
                                                    (secret:reveal (pending-verifier pending)))
                                              (cons "resource" (pending-resource pending)))))
             (token-set (%token-set-from response pending)))
        (unless token-set
          (error 'sign-in-failed :code (%error-code-of response)
                                 :detail (format nil "the token endpoint answered ~D"
                                                 (http:response-status response))))
        ;; Under the refresh lock, so a refresh of the old tokens still running cannot overwrite
        ;; or delete the new ones afterwards.
        (call-with-refresh-lock (broker-store broker) (list principal (pending-connection pending))
                                (lambda ()
                                  (put-token (broker-store broker) principal
                                             (pending-connection pending) token-set)))
        (%forget-metadata broker token-set)
        (log:info "aion/oauth: sign-in finished" :connection (pending-connection pending))
        (values principal (pending-connection pending))))))

;;; --- tokens in use ---------------------------------------------------------------------

(defparameter *expiry-margin* 30
  "Seconds before its expiry at which an access token is refreshed rather than sent.")

(defun %usable (token-set resource)
  "TOKEN-SET's access token when it was issued for RESOURCE and has not expired."
  (and token-set
       (equal (token-set-resource token-set) resource)
       (let ((at (token-set-expires-at token-set)))
         (or (null at) (> at (+ (get-universal-time) *expiry-margin*))))
       (secret:reveal (token-set-access token-set))))

(defun refresh (broker principal connection resource-url &key rejected)
  "Refresh PRINCIPAL's tokens for CONNECTION and return the new access token, or NIL when there
is nothing to refresh with or the server refused (invalid_grant, invalid_client or
unauthorized_client, after which the tokens are deleted; after invalid_client the registered
client is forgotten too, so the next sign-in registers a new one). REJECTED is an access token
the resource server just refused: a token other than it, stored by a refresh that ran while
this one waited for the lock, is returned without another refresh. Refreshes of one token run
one at a time (CALL-WITH-REFRESH-LOCK). Signals REFRESH-FAILED when the server could not be
reached, or gave any other answer that was not a token."
  (let ((store (broker-store broker))
        (resource (canonical-resource resource-url)))
    (when rejected (%forget-metadata broker (get-token store principal connection)))
    (call-with-refresh-lock
     store (list principal connection)
     (lambda ()
       (let ((current (get-token store principal connection)))
         (cond
           ((or (null current) (not (equal (token-set-resource current) resource))) nil)
           ((let ((usable (%usable current resource)))
              (and usable (not (equal usable rejected))))
            (secret:reveal (token-set-access current)))
           ((null (token-set-refresh current)) nil)
           (t
            (let ((response
                    (handler-case
                        (%fetch broker :post (token-set-token-endpoint current)
                                :headers '(("Accept" . "application/json"))
                                :content (list (cons "grant_type" "refresh_token")
                                               (cons "refresh_token"
                                                     (secret:reveal (token-set-refresh current)))
                                               (cons "client_id" (token-set-client-id current))
                                               (cons "resource" resource)))
                      (http:pinned-connect-unsupported (e) (error e))
                      (oauth-error ()
                        (error 'refresh-failed :detail "the token endpoint could not be reached")))))
              (let ((renewed (%token-set-from response nil current)))
                (cond (renewed
                       (put-token store principal connection renewed)
                       (log:info "aion/oauth: tokens refreshed" :connection connection)
                       (secret:reveal (token-set-access renewed)))
                      ;; The grant is spent, or the client is no longer accepted: these tokens
                      ;; will never refresh, so they are deleted and the next call asks the user
                      ;; to sign in. A client the server no longer knows is forgotten as well,
                      ;; or every later sign-in would reuse it and fail.
                      ((member (%error-code-of response)
                               '("invalid_grant" "invalid_client" "unauthorized_client")
                               :test #'equal)
                       (when (equal "invalid_client" (%error-code-of response))
                         (delete-client store (token-set-issuer current) (broker-redirect-uri broker)))
                       (delete-token store principal connection)
                       (log:info "aion/oauth: refresh refused, tokens deleted" :connection connection)
                       nil)
                      (t (error 'refresh-failed
                                :detail (format nil "the token endpoint answered ~D"
                                                (http:response-status response))))))))))))))

(defun %fetch-issuers (broker token-set)
  "The issuers TOKEN-SET's protected-resource metadata names now, and T; or NIL and NIL when the
metadata could not be read. Only a 200 with a JSON object body is an answer. A document that
names another resource is an answer too: it names no issuer for this one."
  (let ((url (token-set-metadata-url token-set)))
    (handler-case
        (progn
          (%check-url url "protected resource metadata URL")
          (let ((doc (%get-json broker url)))
            (if doc
                (values (and (equal (canonical-resource (or (gethash "resource" doc) ""))
                                    (token-set-resource token-set))
                             (%strings (gethash "authorization_servers" doc)))
                        t)
                (values nil nil))))
      (http:pinned-connect-unsupported (e) (error e))
      (oauth-error () (values nil nil)))))

;; The answer depends on the token set's resource as well as on the document: a document that
;; names another resource names no issuer for this one. So the key holds both, and an answer
;; read for one resource is never used for another that shares the metadata URL.
(defun %metadata-key (token-set)
  (list (token-set-metadata-url token-set) (token-set-resource token-set)))

(defun %current-issuers (broker token-set)
  "The authorization servers TOKEN-SET's resource names now, from its protected-resource
metadata. An answer is kept for the broker's METADATA-LIFETIME. When a fetch fails, an expired
answer is used for METADATA-GRACE seconds after it expired and is not renewed; past that, or
with no answer at all, this signals OAUTH-ERROR, which fails the call rather than asking the
user to sign in again."
  (let* ((key (%metadata-key token-set))
         (cache (broker-metadata-cache broker))
         (now (get-universal-time))
         (cached (sb-thread:with-mutex ((broker-metadata-lock broker)) (gethash key cache))))
    (if (and cached (> (cdr cached) now))
        (car cached)
        (multiple-value-bind (issuers ok) (%fetch-issuers broker token-set)
          (cond (ok
                 (sb-thread:with-mutex ((broker-metadata-lock broker))
                   (setf (gethash key cache) (cons issuers (+ now (broker-metadata-lifetime broker)))))
                 issuers)
                ((and cached (> (+ (cdr cached) (broker-metadata-grace broker)) now))
                 (car cached))
                (t (error 'oauth-error :detail "the protected resource metadata could not be read")))))))

(defun %forget-metadata (broker token-set)
  (when (and token-set (token-set-metadata-url token-set))
    (sb-thread:with-mutex ((broker-metadata-lock broker))
      (remhash (%metadata-key token-set) (broker-metadata-cache broker)))))

(defun access-token (broker principal connection resource-url)
  "PRINCIPAL's access token for CONNECTION, refreshed first when it has expired, or NIL when
there is none. A token is returned only for the resource it was issued for, and only while that
resource's protected-resource metadata still names the authorization server that issued it, so
a connection whose URL or authorization server changed gets NIL, and its user signs in again.
The metadata is kept for the broker's METADATA-LIFETIME, so this costs a request only when the
cache has expired or the server has refused a token."
  (%check-url resource-url "protected resource")
  (let* ((resource (canonical-resource resource-url))
         (current (get-token (broker-store broker) principal connection)))
    (cond ((null current) nil)
          ((not (equal (token-set-resource current) resource)) nil)
          ((not (member (token-set-issuer current) (%current-issuers broker current)
                        :test #'equal))
           nil)
          ((%usable current resource))
          (t (refresh broker principal connection resource-url)))))

(defun disconnect (broker principal connection)
  "Revoke PRINCIPAL's tokens for CONNECTION at the authorization server when it offers a
revocation endpoint (RFC 7009), and delete them either way. A revocation that fails, or that the
server refuses, is logged and does not stop the deletion. Runs under the refresh lock, so a
refresh still running cannot store rotated tokens after the disconnect."
  (let ((store (broker-store broker)))
    (call-with-refresh-lock
     store (list principal connection)
     (lambda ()
       (let ((current (get-token store principal connection)))
         (when current
           (let ((endpoint (token-set-revocation-endpoint current))
                 (token (or (token-set-refresh current) (token-set-access current))))
             (when endpoint
               (handler-case
                   (let ((response (%fetch broker :post endpoint
                                           :content (list (cons "token" (secret:reveal token))
                                                          (cons "token_type_hint"
                                                                (if (token-set-refresh current)
                                                                    "refresh_token"
                                                                    "access_token"))
                                                          (cons "client_id"
                                                                (token-set-client-id current))))))
                     (unless (<= 200 (http:response-status response) 299)
                       (log:warn "aion/oauth: revocation refused" :connection connection
                                                                  :status (http:response-status response))))
                 ;; Including PINNED-CONNECT-UNSUPPORTED on Windows: the tokens are deleted.
                 (error () (log:warn "aion/oauth: revocation failed" :connection connection)))))
           (delete-token store principal connection)))))
    t))
