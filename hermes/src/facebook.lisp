;;;; facebook.lisp --- the Facebook Page backend, through the Graph API (#822).
;;;;
;;;; Posts a FACEBOOK-POST to a Page the app's admins manage, answers whether a Page is still
;;;; connected, and runs the one-time connect flow that turns an admin's Facebook Login into a
;;;; Page access token.
;;;;
;;;; WHAT META ALLOWS, from Meta's own docs on developers.facebook.com (checked 2026-10-23):
;;;;   - Publishing is POST /{page-id}/feed with message and/or link, or /{page-id}/photos, with
;;;;     a Page access token carrying pages_manage_posts, pages_read_engagement and
;;;;     pages_show_list, from someone who can do the CREATE_CONTENT task on the Page
;;;;     (Graph API reference, Page Feed). "If the viewer or app cannot see the url of link, the
;;;;     post will fail."
;;;;   - "Permissions with Standard Access can only be requested from app users who have a role
;;;;     on the requesting app", and every Business app has Standard Access to every permission.
;;;;     So an admin with a role on the app can connect their own Page without App Review.
;;;;     Anyone else needs Advanced Access: App Review per permission, and Business Verification
;;;;     (Graph API overview, Access Levels).
;;;;   - A long-lived user token "generally lasts about 60 days"; a Page token taken with it
;;;;     "do[es] not have an expiration date" but can be invalidated. The exchange includes the
;;;;     app secret: "Make this call from your server, not a client" (Facebook Login guide,
;;;;     Get Long-Lived Tokens).
;;;;   - Graph API v19.0 deprecated publish_to_groups and the Groups API, and they were "removed
;;;;     April 22, 2024" for every version, so Groups are refused before anything is sent.
;;;;   - Rate limits: 4 (app), 17 (user), 32 (Pages call with a User token), 613 (custom), and
;;;;     80001 for a Page token, which is what posting uses. No error carries a wait; the
;;;;     X-Business-Use-Case-Usage header's estimated_time_to_regain_access, in minutes, does.
;;;;
;;;; SECRETS. The app secret and every token are held as AION/SECRET:SECRET. A Page token goes in
;;;; the POST body of a post, never the URL; the connect flow's GETs carry the app secret and a
;;;; user token in the query string, as Meta documents them, so every failure from %FACEBOOK-CALL
;;;; has each secret replaced by "<redacted>" before it is signalled, and every error raised
;;;; while the request is made is caught there, so its frames (which hold the URL) are unwound
;;;; before anything is signalled -- the same discipline as telegram.lisp. Nothing here logs a
;;;; token, a URL or a message's text.

(cl:in-package #:hermes)

(defparameter +facebook-graph-api-version+ "v26.0"
  "The Graph API version every request names (the latest version Meta's reference showed on
2026-10-23). Meta supports a version for about two years; the \"Facebook Graph API\" entry in
upstream.sexp reads this.")

(defparameter +facebook-connect-scopes+
  '("pages_show_list" "pages_read_engagement" "pages_manage_posts")
  "The permissions the connect flow asks for: the three Meta's Page Feed reference lists for
publishing.")

(defclass facebook (facebook-provider)
  ((app-id :initarg :app-id :initform (uiop:getenv "FACEBOOK_APP_ID") :reader facebook-app-id)
   (app-secret :initarg :app-secret :initform (uiop:getenv "FACEBOOK_APP_SECRET")
               :reader %facebook-app-secret)
   (page-tokens :initarg :page-tokens :initform #'%env-page-token :reader %facebook-page-tokens)
   (graph-base :initarg :graph-base :initform "https://graph.facebook.com"
               :reader facebook-graph-base)
   (dialog-base :initarg :dialog-base :initform "https://www.facebook.com"
                :reader facebook-dialog-base))
  (:documentation "The Graph API as a facebook-provider. APP-ID and APP-SECRET are the Meta
app's, defaulting to $FACEBOOK_APP_ID and $FACEBOOK_APP_SECRET; the secret is needed for the
connect flow and the health check, and when present signs every call with appsecret_proof.
PAGE-TOKENS finds the Page access token for a Page id: a function of the id returning a string,
an AION/SECRET:SECRET or NIL, or an alist of (page-id . token). It defaults to
$FACEBOOK_PAGE_TOKEN_<page-id>, then $FACEBOOK_PAGE_TOKEN. GRAPH-BASE and DIALOG-BASE are the
servers, for a test."))

(defun %env-page-token (page-id)
  "The Page token for PAGE-ID from the environment: FACEBOOK_PAGE_TOKEN_<PAGE-ID>, else
FACEBOOK_PAGE_TOKEN, else NIL."
  (flet ((env (name) (let ((v (uiop:getenv name))) (and v (plusp (length v)) v))))
    (or (env (format nil "FACEBOOK_PAGE_TOKEN_~A" page-id))
        (env "FACEBOOK_PAGE_TOKEN"))))

(defmethod initialize-instance :after ((p facebook) &key)
  (let ((secret (slot-value p 'app-secret))
        (tokens (slot-value p 'page-tokens)))
    (when (and (stringp secret) (plusp (length secret)))
      (setf (slot-value p 'app-secret) (secret:make-secret secret)))
    (when (and (stringp secret) (zerop (length secret)))
      (setf (slot-value p 'app-secret) nil))
    (when (listp tokens)
      ;; An alist becomes a lookup, and each token a SECRET, so the provider prints without them.
      (let ((table (loop for (id . token) in tokens
                         collect (cons (princ-to-string id)
                                       (if (secret:secretp token)
                                           token
                                           (secret:make-secret token))))))
        (setf (slot-value p 'page-tokens)
              (lambda (page-id) (cdr (assoc page-id table :test #'string=))))))))

(defun make-facebook (&rest initargs &key app-id app-secret page-tokens graph-base dialog-base)
  "A Facebook Page provider. APP-ID and APP-SECRET default to $FACEBOOK_APP_ID and
$FACEBOOK_APP_SECRET; PAGE-TOKENS, a function of a Page id or an alist, to the environment."
  (declare (ignore app-id app-secret page-tokens graph-base dialog-base))
  (apply #'make-instance 'facebook initargs))

(defvar *facebook-perform* nil
  "When non-NIL, the function SEND-REQUEST calls instead of the HTTP round trip, for the test of
a transport failure whose text names the URL. NIL makes the real call.")

(defparameter +facebook-max-response-bytes+ (* 1024 1024)
  "The most of a response body the backend reads. The Graph API's answers here are a few
kilobytes.")

;;; --- encoding ----------------------------------------------------------------

(defun %form-encode (text)
  "TEXT percent-encoded as UTF-8, everything but RFC 3986's unreserved characters."
  (with-output-to-string (out)
    (loop for byte across (sb-ext:string-to-octets text :external-format :utf-8)
          for ch = (code-char byte)
          do (if (or (char<= #\A ch #\Z) (char<= #\a ch #\z) (char<= #\0 ch #\9) (find ch "-_.~"))
                 (write-char ch out)
                 (format out "%~2,'0X" byte)))))

(defun %query (params)
  "PARAMS, an alist of (name . value), as a query string."
  (format nil "~{~A~^&~}"
          (loop for (k . v) in params
                collect (format nil "~A=~A" (%form-encode k) (%form-encode (princ-to-string v))))))

(defun %reveal (value)
  "The plain string of VALUE, a SECRET or a string, or NIL."
  (cond ((secret:secretp value) (secret:reveal value))
        ((and (stringp value) (plusp (length value))) value)))

(defun %appsecret-proof (app-secret token)
  "Meta's appsecret_proof for TOKEN: the HMAC-SHA256 of the token keyed by the app secret, in hex."
  (let ((hmac (ironclad:make-hmac (sb-ext:string-to-octets app-secret :external-format :utf-8)
                                  :sha256)))
    (ironclad:update-hmac hmac (sb-ext:string-to-octets token :external-format :utf-8))
    (ironclad:byte-array-to-hex-string (ironclad:hmac-digest hmac))))

(defun %redact-all (text secrets)
  "TEXT with each of SECRETS, as written and percent-encoded, replaced by \"<redacted>\"."
  (let ((out text))
    (dolist (s secrets out)
      (when (and (stringp s) (plusp (length s)))
        (setf out (%redact-one (%redact-one out s) (%form-encode s)))))))

;;; --- refusals ---------------------------------------------------------------------

(defun %graph-error (body)
  "The \"error\" object of a Graph API answer BODY, or NIL."
  (let ((json (%parse-object body)))
    (and json (let ((e (gethash "error" json))) (and (hash-table-p e) e)))))

(defparameter +facebook-reconnect-subcodes+ '(458 459 460 463 464 467 492)
  "Graph error subcodes that mean the token no longer works for this Page, from Meta's
error-handling guide: the user logged out of the app, must fix their account, changed their
password, the token expired or was revoked, or (492) no longer has a role on the Page.")

(defun %facebook-failure-class (code subcode message link-post)
  "The condition class for a Graph error with CODE, SUBCODE and MESSAGE. LINK-POST is true when
the call was a post with a link."
  (let ((m (string-downcase (if (stringp message) message ""))))
    (cond ((member code '(4 17 32 613 80001)) 'delivery-rate-limited)
          ((or (eql code 190) (eql code 102) (member subcode +facebook-reconnect-subcodes+))
           'facebook-reconnect-required)
          ((or (eql code 10) (and (integerp code) (<= 200 code 299))) 'facebook-not-permitted)
          ((or (eql code 803) (and (eql code 100) (eql subcode 33))) 'facebook-page-not-found)
          ((and link-post (eql code 100) (or (search "link" m) (search "url" m)))
           'facebook-link-not-public)
          (t 'delivery-failure))))

(defun %facebook-retry-after (headers)
  "Seconds to wait from a rate-limited answer's HEADERS: the largest
estimated_time_to_regain_access (minutes) in X-Business-Use-Case-Usage, else a Retry-After
header in seconds, else NIL."
  (flet ((wait-of (entry)
           (let ((v (and (hash-table-p entry) (gethash "estimated_time_to_regain_access" entry))))
             (if (integerp v) v 0))))
    (let* ((buc (%parse-object (or (header-value headers "x-business-use-case-usage") "")))
           (minutes (and buc
                         (loop for entries being the hash-values of buc
                               when (vectorp entries)
                                 maximize (reduce #'max (map 'list #'wait-of entries)
                                                  :initial-value 0)))))
      (cond ((and (integerp minutes) (plusp minutes)) (* 60 minutes))
            (t (let ((ra (ignore-errors (parse-integer (header-value headers "retry-after")))))
                 (and (integerp ra) (plusp ra) ra)))))))

(defun %facebook-refusal (status body headers redact link-post)
  "The condition, not yet signalled, for a Graph call refused with HTTP STATUS, BODY and
HEADERS. REDACT removes every secret from a string (a closure, so no frame holds a secret).
The detail is Facebook's message with its code and subcode."
  (let* ((e (%graph-error body))
         (code (and e (gethash "code" e)))
         (subcode (and e (gethash "error_subcode" e)))
         (message (and e (let ((m (gethash "message" e))) (and (stringp m) m))))
         (detail (funcall redact (if e
                                     (format nil "~@[~A ~](Graph error ~A~@[, subcode ~A~])"
                                             message code subcode)
                                     body)))
         (class (%facebook-failure-class code subcode message link-post)))
    (if (eq class 'delivery-rate-limited)
        (make-condition class :provider :facebook :status status :detail detail
                              :retry-after (%facebook-retry-after headers))
        (make-condition class :provider :facebook :status status :detail detail))))

;;; --- one Graph call -----------------------------------------------------------

(defun %facebook-call (p method path params &key secrets token link-post (base :graph))
  "Call the Graph API: METHOD (:get or :post) on PATH (below the version) with PARAMS, an alist.
TOKEN, a SECRET or string, is sent as access_token, with appsecret_proof when the app secret is
known. SECRETS lists other plain strings to remove from any failure's text. Returns the answer's
JSON object. On a refusal or a transport failure, signals the condition %FACEBOOK-REFUSAL
chooses, with every secret removed from its text; every error raised while the request is made
is caught here, so its frames are unwound first (see this file's header)."
  (let* ((app-secret (%reveal (%facebook-app-secret p)))
         (token-text (%reveal token))
         (all (append (when token-text
                        (list (cons "access_token" token-text)))
                      (when (and token-text app-secret)
                        (list (cons "appsecret_proof" (%appsecret-proof app-secret token-text))))
                      params))
         (hidden (remove nil (list* app-secret token-text secrets)))
         (redact (lambda (text) (%redact-all text hidden)))
         (url (format nil "~A/~A/~A" (ecase base (:graph (facebook-graph-base p)))
                      +facebook-graph-api-version+ path))
         (req (if (eq method :get)
                  (make-request :method :get :url (format nil "~A?~A" url (%query all))
                                :max-body-bytes +facebook-max-response-bytes+)
                  (make-request :method :post :url url
                                :content (loop for (k . v) in all
                                               collect (cons k (princ-to-string v)))
                                :max-body-bytes +facebook-max-response-bytes+)))
         (resp (handler-case
                   (apply #'send-request req '()
                          (when *facebook-perform* (list :perform *facebook-perform*)))
                 (http-error (c)
                   (error 'delivery-failure
                          :provider :facebook :status (http-error-status c)
                          :detail (funcall redact (or (http-error-detail c) (http-error-body c)))))
                 ;; As in telegram.lisp: anything else is reported, redacted, after this
                 ;; HANDLER-CASE has unwound the frames that hold the request.
                 (cl:error (c)
                   (error 'delivery-failure
                          :provider :facebook
                          :detail (or (ignore-errors
                                       (funcall redact (format nil "~A: ~A" (type-of c) c)))
                                      (format nil "~A, whose report could not be printed"
                                              (type-of c)))))
                 (serious-condition (c)
                   (error c)))))
    (unless (<= 200 (response-status resp) 299)
      (error (%facebook-refusal (response-status resp) (response-body resp) (response-headers resp)
                                redact link-post)))
    (or (%parse-object (response-body resp))
        (error 'delivery-failure :provider :facebook :status (response-status resp)
                                 :detail "the Graph API's answer was not a JSON object"))))

;;; --- posting -----------------------------------------------------------------------

(defun %page-token (p page)
  "The Page token for PAGE (an id string) as a SECRET, or CONFIGURATION-ERROR naming where it was
looked for."
  (let* ((found (funcall (%facebook-page-tokens p) page))
         (token (cond ((secret:secretp found) found)
                      ((and (stringp found) (plusp (length found))) (secret:make-secret found)))))
    (or token
        (error 'configuration-error
               :missing (format nil "a Page access token for Facebook Page ~A (~A, or :page-tokens)"
                                page (format nil "FACEBOOK_PAGE_TOKEN_~A" page))))))

(defun %caption (message link)
  "A photo's caption: MESSAGE, then LINK on its own line."
  (format nil "~@[~A~]~:[~;~%~]~@[~A~]" message (and message link) link))

(defmethod deliver ((p facebook) (m facebook-post))
  (let* ((page (facebook-post-page m))
         (token (%page-token p page))
         (link (facebook-post-link m))
         (message (facebook-post-message m))
         (json (if (facebook-post-image-url m)
                   (%facebook-call p :post (format nil "~A/photos" page)
                                   (list (cons "url" (facebook-post-image-url m))
                                         (cons "caption" (%caption message link)))
                                   :token token)
                   (%facebook-call p :post (format nil "~A/feed" page)
                                   (append (when message (list (cons "message" message)))
                                           (when link (list (cons "link" link))))
                                   :token token :link-post (and link t))))
         (id (or (gethash "post_id" json) (gethash "id" json))))
    (unless (stringp id)
      (error 'delivery-failure :provider :facebook
                               :detail "the Graph API's answer to a post carried no post id"))
    (make-delivery-result :provider :facebook :id id :status :sent :destination page :raw json)))

(defun post-to-page (page link &key message image-url (provider (facebook-provider-from-env)))
  "Post LINK, with MESSAGE and IMAGE-URL when given, to the Facebook Page PAGE, as the Page, and
return the new post's id (#822). PROVIDER defaults to the one HERMES_FACEBOOK_IMPL names. LINK
may be NIL when MESSAGE is given. Signals as MAKE-FACEBOOK-POST and DELIVER do."
  (delivery-result-id
   (deliver provider (make-facebook-post :page page :link link :message message
                                         :image-url image-url))))

;;; --- health ----------------------------------------------------------------------------

(defmethod facebook-page-health ((p facebook) page)
  (let* ((page (princ-to-string page))
         (token (handler-case (%page-token p page)
                  (configuration-error () (return-from facebook-page-health :not-connected)))))
    (handler-case
        (let* ((info (%facebook-call p :get page (list (cons "fields" "id,name")) :token token))
               (name (let ((n (gethash "name" info))) (and (stringp n) n)))
               (app-id (facebook-app-id p))
               (app-secret (%reveal (%facebook-app-secret p))))
          ;; With the app's credentials, ask Facebook what the token may do: a Page token that
          ;; reads the Page but lacks pages_manage_posts cannot post, and only debug_token says so.
          (if (and app-id app-secret)
              (let* ((debug (%facebook-call p :get "debug_token"
                                            (list (cons "input_token" (%reveal token))
                                                  (cons "access_token"
                                                        (format nil "~A|~A" app-id app-secret)))
                                            :secrets (list (%reveal token))))
                     (data (gethash "data" debug))
                     (scopes (and (hash-table-p data) (gethash "scopes" data))))
                (cond ((not (and (hash-table-p data) (eq t (gethash "is_valid" data))))
                       (values :reconnect name))
                      ((not (and (vectorp scopes) (find "pages_manage_posts" scopes :test #'equal)))
                       (values :reconnect name))
                      (t (values :connected name))))
              (values :connected name)))
      (facebook-reconnect-required () :reconnect)
      (facebook-not-permitted () :not-permitted)
      (facebook-page-not-found () :not-found))))

;;; --- connecting a Page once -----------------------------------------------------------
;;;
;;; 1. The app makes a state with FACEBOOK-CONNECT-STATE and keeps it in the admin's session.
;;; 2. It redirects the admin to FACEBOOK-CONNECT-URL, which carries the state and an exact
;;;    redirect URI, and no secret.
;;; 3. Facebook redirects back with code and state (or error). The app passes both, with the
;;;    state from the session, to FACEBOOK-CONNECT-PAGES, and deletes the session's state, so a
;;;    callback cannot be replayed. Facebook also accepts a code only once.
;;; 4. FACEBOOK-CONNECT-PAGES checks the state in constant time, exchanges the code for a user
;;;    token and that for a long-lived one, server-side with the app secret, and lists the Pages
;;;    the admin manages with their Page tokens. The user tokens are dropped when it returns.
;;; 5. The app stores the chosen Page's token, keyed by the Page id, in its secret store, and
;;;    gives the provider a :page-tokens lookup that reads it.

(defstruct (facebook-page (:constructor %make-facebook-page (id name token tasks)))
  "A Page the connecting admin manages (#822). ID and NAME are the Page's. TOKEN is its Page
access token, an AION/SECRET:SECRET: store it, keyed by ID, in the app's secret store. TASKS are
the admin's tasks on the Page, such as \"CREATE_CONTENT\"; FACEBOOK-PAGE-CAN-POST-P says whether
they include posting."
  id name token tasks)

(defun facebook-page-can-post-p (page)
  "True when the admin's tasks on PAGE include CREATE_CONTENT, which posting needs."
  (and (member "CREATE_CONTENT" (facebook-page-tasks page) :test #'equal) t))

(defun facebook-connect-state ()
  "A new, unguessable state for one connect attempt: 256 random bits, in hex. Keep it in the
admin's session, and pass it to FACEBOOK-CONNECT-URL and then to FACEBOOK-CONNECT-PAGES."
  (aion/random:random-hex 256))

(defun %facebook-state= (a b)
  "True when strings A and B are equal, in a time that does not depend on where they differ."
  (and (stringp a) (stringp b)
       (let ((diff (logxor (length a) (length b))))
         (loop for i below (max (length a) (length b))
               do (setf diff (logior diff
                                     (logxor (if (< i (length a)) (char-code (char a i)) 0)
                                             (if (< i (length b)) (char-code (char b i)) 0)))))
         (zerop diff))))

(defun %require-state (state what)
  (unless (and (stringp state) (>= (length state) 32))
    (error 'invalid-message
           :problem (format nil "it needs ~A of at least 32 characters, from FACEBOOK-CONNECT-STATE"
                            what))))

(defun facebook-connect-url (provider &key redirect-uri state)
  "The Facebook Login URL to send a connecting admin to (#822). REDIRECT-URI is the app's
callback, exactly as registered in the Meta app's Valid OAuth Redirect URIs; STATE is from
FACEBOOK-CONNECT-STATE. The URL carries the app id and no secret."
  (let ((app-id (%require (facebook-app-id provider) "FACEBOOK_APP_ID")))
    (unless (%http-url-p redirect-uri)
      (error 'invalid-message :problem "it needs a :redirect-uri that is an http or https URL"))
    (%require-state state "a :state")
    (format nil "~A/~A/dialog/oauth?~A" (facebook-dialog-base provider) +facebook-graph-api-version+
            (%query (list (cons "client_id" app-id)
                          (cons "redirect_uri" redirect-uri)
                          (cons "state" state)
                          (cons "response_type" "code")
                          (cons "scope" (format nil "~{~A~^,~}" +facebook-connect-scopes+)))))))

(defun %connect-step (fn)
  "Call FN, turning a refusal of the code exchange into FACEBOOK-CONNECT-REFUSED :CODE-REJECTED."
  (handler-case (funcall fn)
    (delivery-rate-limited (c) (error c))
    (delivery-failure (c)
      (error 'facebook-connect-refused
             :reason :code-rejected :detail (delivery-failure-detail c)))))

(defun facebook-connect-pages (provider &key code state expected-state redirect-uri
                                              ((:error refusal)))
  "Finish connecting: the Pages the admin manages, as a list of FACEBOOK-PAGE (#822). CODE, STATE
and ERROR are the callback's query parameters; EXPECTED-STATE is the state kept in the admin's
session; REDIRECT-URI is the same one FACEBOOK-CONNECT-URL was given. Signals
FACEBOOK-CONNECT-REFUSED with :STATE-MISMATCH when the states differ (checked first, in constant
time), :DENIED when Facebook returned ERROR instead of a code, and :CODE-REJECTED when Facebook
refuses the code. The user tokens are never returned or kept."
  (unless (and (stringp state) (stringp expected-state) (plusp (length expected-state))
               (%facebook-state= state expected-state))
    (error 'facebook-connect-refused :reason :state-mismatch))
  (when (or refusal (not (stringp code)) (zerop (length code)))
    (error 'facebook-connect-refused
           :reason :denied
           :detail (and (stringp refusal) (subseq refusal 0 (min 200 (length refusal))))))
  (let* ((app-id (%require (facebook-app-id provider) "FACEBOOK_APP_ID"))
         (app-secret (%require (%reveal (%facebook-app-secret provider)) "FACEBOOK_APP_SECRET"))
         (short (%connect-step
                 (lambda ()
                   (gethash "access_token"
                            (%facebook-call provider :get "oauth/access_token"
                                            (list (cons "client_id" app-id)
                                                  (cons "redirect_uri" redirect-uri)
                                                  (cons "client_secret" app-secret)
                                                  (cons "code" code))
                                            :secrets (list code))))))
         (long (%connect-step
                (lambda ()
                  (gethash "access_token"
                           (%facebook-call provider :get "oauth/access_token"
                                           (list (cons "grant_type" "fb_exchange_token")
                                                 (cons "client_id" app-id)
                                                 (cons "client_secret" app-secret)
                                                 (cons "fb_exchange_token" short))
                                           :secrets (list short)))))))
    (unless (and (stringp long) (plusp (length long)))
      (error 'facebook-connect-refused :reason :code-rejected
                                       :detail "Facebook returned no long-lived token"))
    (let ((pages (%managed-pages provider (secret:make-secret long))))
      (log:info "hermes: facebook pages listed for connecting" :pages (length pages))
      pages)))

(defun %managed-pages (provider user-token)
  "Every Page the holder of USER-TOKEN manages, following the paging cursor, as FACEBOOK-PAGEs."
  (let ((pages '()) (after nil))
    (loop
      (let* ((json (%facebook-call provider :get "me/accounts"
                                   (append (list (cons "fields" "id,name,access_token,tasks")
                                                 (cons "limit" "100"))
                                           (when after (list (cons "after" after))))
                                   :token user-token))
             (data (gethash "data" json))
             (paging (gethash "paging" json))
             (cursors (and (hash-table-p paging) (gethash "cursors" paging)))
             (next-after (and (hash-table-p cursors) (gethash "after" cursors))))
        (when (vectorp data)
          (loop for page across data
                when (and (hash-table-p page) (stringp (gethash "id" page))
                          (stringp (gethash "access_token" page)))
                  do (push (%make-facebook-page
                            (gethash "id" page)
                            (let ((n (gethash "name" page))) (and (stringp n) n))
                            (secret:make-secret (gethash "access_token" page))
                            (let ((tasks (gethash "tasks" page)))
                              (and (vectorp tasks) (remove-if-not #'stringp (coerce tasks 'list)))))
                           pages)))
        ;; A next link is present only while there are more Pages.
        (if (and (hash-table-p paging) (gethash "next" paging) (stringp next-after)
                 (not (equal next-after after)))
            (setf after next-after)
            (return (nreverse pages)))))))

(register-impl :facebook "facebook" (lambda () (make-facebook)))
