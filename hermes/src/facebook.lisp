;;;; facebook.lisp --- the Facebook Page backend, through the Graph API (#822).
;;;;
;;;; Posts a FACEBOOK-POST to a Page the app's admins manage, answers whether a Page is still
;;;; connected, and runs the one-time connect flow that turns an admin's Facebook Login into a
;;;; Page access token.
;;;;
;;;; WHAT META ALLOWS, from Meta's own docs on developers.facebook.com (checked 2026-10-23; dates
;;;; in this file are UTC, YYYY-MM-DD):
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
;;;; SECRETS. The app secret and every token are held as AION/SECRET:SECRET. A post sends its
;;;; token in the POST body and a read in an Authorization header; the connect flow's code
;;;; exchanges and debug_token carry secrets in the query string, as Meta documents them. Secrets
;;;; reach %FACEBOOK-CALL only as SECRETs, so no frame a logged backtrace prints holds one in
;;;; plain text. Every failure from %FACEBOOK-CALL has each secret replaced by "<redacted>"
;;;; before it is signalled, and every error raised while the request is made is caught there,
;;;; so its frames (which hold the URL) are unwound before anything is signalled: the same
;;;; discipline as telegram.lisp. Nothing here logs a token, a URL or a message's text.

(cl:in-package #:hermes)

(defparameter +facebook-graph-api-version+ "v26.0"
  "The Graph API version every request names (the latest version Meta's reference showed on
2026-10-23). Meta supports a version for about two years; the \"Facebook Graph API\" entry in
upstream.sexp reads this.")

(defparameter +facebook-connect-scopes+
  '("pages_show_list" "pages_read_engagement" "pages_manage_posts")
  "The permissions the connect flow asks for: the three Meta's Page Feed reference lists for
publishing.")

(defparameter +facebook-required-scopes+ '("pages_manage_posts")
  "The scopes a Page token needs for what hermes/facebook does with it, which
FACEBOOK-PAGE-HEALTH checks (#978). hermes posts to /{page}/feed and /{page}/photos, which need
pages_manage_posts, and reads /me's id and name, which needs no scope.

Meta's Page Feed and Page Photos references list pages_read_engagement and pages_show_list for
publishing too. They are left out here because no call hermes makes with the Page token uses
them: hermes reads no engagement data, and lists Pages only in the connect flow, on the admin's
user token (+FACEBOOK-CONNECT-SCOPES+ asks for all three there). If Meta refuses a post for
want of one of them, the refusal is FACEBOOK-NOT-PERMITTED, and the scope belongs here.")

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
          ;; Meta documents no code or subcode for a link it could not fetch (searched on
          ;; developers.facebook.com, 2026-10-23), so its message is the only signal: a code
          ;; 100 that mentions the link, on a post that has one. Anything else stays a plain
          ;; DELIVERY-FAILURE with Facebook's text.
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

(defparameter +facebook-connect-timeout+ 10 "Seconds to wait for a connection to the Graph API.")
(defparameter +facebook-read-timeout+ 30
  "Seconds to wait for the Graph API's answer. A post whose answer times out may still have been
made: check the Page before posting again.")

(defun %plain (value)
  "VALUE as the text sent: a SECRET revealed, anything else printed."
  (if (secret:secretp value) (secret:reveal value) (princ-to-string value)))

(defun %multipart (fields file boundary)
  "A multipart/form-data body (RFC 7578) of FIELDS, an alist of strings, and FILE, a list (NAME
FILENAME CONTENT-TYPE OCTETS), separated by BOUNDARY, as octets."
  (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (flet ((emit (text)
             (loop for b across (sb-ext:string-to-octets text :external-format :utf-8)
                   do (vector-push-extend b out))))
      (loop for (name . value) in fields
            do (emit (format nil "--~A~C~CContent-Disposition: form-data; name=\"~A\"~C~C~C~C~A~C~C"
                             boundary #\Return #\Newline name #\Return #\Newline #\Return #\Newline
                             value #\Return #\Newline)))
      (destructuring-bind (name filename content-type octets) file
        (emit (format nil "--~A~C~CContent-Disposition: form-data; name=\"~A\"; filename=\"~A\"~C~CContent-Type: ~A~C~C~C~C"
                      boundary #\Return #\Newline name filename #\Return #\Newline content-type
                      #\Return #\Newline #\Return #\Newline))
        (loop for b across octets do (vector-push-extend b out))
        (emit (format nil "~C~C--~A--~C~C" #\Return #\Newline boundary #\Return #\Newline))))
    (coerce out '(simple-array (unsigned-byte 8) (*)))))

(defun %facebook-call (p method path params &key secrets token link-post file)
  "Call the Graph API: METHOD (:get or :post) on PATH (below the version) with PARAMS, an alist
whose values are strings or AION/SECRET:SECRETs. TOKEN, a SECRET, is the access token: in the
form body of a POST, in an Authorization header for a GET, with appsecret_proof when the app
secret is known. SECRETS lists other SECRETs to remove from any failure's text. FILE, for a
POST, is a list (NAME FILENAME CONTENT-TYPE OCTETS) uploaded with the form as
multipart/form-data, the token and every other field going in the same body. Returns the
answer's JSON object. On a refusal or a transport failure, signals the condition
%FACEBOOK-REFUSAL chooses, with every secret removed from its text.

No argument of this function is a secret in plain text: a refusal is signalled from this frame,
and a handler that logs a backtrace before unwinding prints each frame's arguments. Secrets are
revealed only into this function's local variables, which a backtrace does not print, and every
error raised while the request is made is caught here, so the frames that hold the request are
unwound first (see this file's header)."
  (let* ((app-secret (%reveal (%facebook-app-secret p)))
         (token-text (%reveal token))
         (sent (append (when (and token-text (eq method :post))
                         (list (cons "access_token" token-text)))
                       (when (and token-text app-secret)
                         (list (cons "appsecret_proof" (%appsecret-proof app-secret token-text))))
                       (loop for (k . v) in params collect (cons k (%plain v)))))
         (hidden (remove nil (list* app-secret token-text
                                    (mapcar #'%reveal
                                            (append secrets
                                                    (remove-if-not #'secret:secretp
                                                                   (mapcar #'cdr params)))))))
         (redact (lambda (text) (%redact-all text hidden)))
         (url (format nil "~A/~A/~A" (facebook-graph-base p) +facebook-graph-api-version+ path))
         (req (if (eq method :get)
                  (make-request :method :get :url (format nil "~A?~A" url (%query sent))
                                :headers (when token-text
                                           (list (cons "Authorization"
                                                       (format nil "OAuth ~A" token-text))))
                                :connect-timeout +facebook-connect-timeout+
                                :read-timeout +facebook-read-timeout+
                                :max-body-bytes +facebook-max-response-bytes+)
                  (let ((boundary (and file (format nil "hermes-~A" (aion/random:random-hex 128)))))
                    (make-request :method :post :url url
                                  :content (if file (%multipart sent file boundary) sent)
                                  :headers (when file
                                             (list (cons "Content-Type"
                                                         (format nil "multipart/form-data; boundary=~A"
                                                                 boundary))))
                                  :connect-timeout +facebook-connect-timeout+
                                  :read-timeout +facebook-read-timeout+
                                  :max-body-bytes +facebook-max-response-bytes+))))
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

(defun %check-page-id (page)
  "PAGE as an id string, or INVALID-MESSAGE when it is not a Page id. The id goes into a Graph
path and an environment variable's name, so nothing else may reach them."
  (unless (%facebook-page-id-p page)
    (error 'invalid-message
           :problem "it needs a Facebook Page id (a positive integer or a string of digits)"))
  (princ-to-string page))

(defun %page-token (p page)
  "The Page token for PAGE, a Page id, as a SECRET, or CONFIGURATION-ERROR naming where it was
looked for. Signals INVALID-MESSAGE when PAGE is not a Page id."
  (let* ((page (%check-page-id page))
         (found (funcall (%facebook-page-tokens p) page))
         (token (cond ((secret:secretp found) found)
                      ((and (stringp found) (plusp (length found))) (secret:make-secret found)))))
    (or token
        (error 'configuration-error
               :missing (format nil "a Page access token for Facebook Page ~A (~A, or :page-tokens)"
                                page (format nil "FACEBOOK_PAGE_TOKEN_~A" page))))))

(defun %caption (message link)
  "A photo's caption: MESSAGE, then LINK on its own line."
  (format nil "~@[~A~]~:[~;~%~]~@[~A~]" message (and message link) link))

(defun %photo-extension (type)
  "A file name extension for the media TYPE, for the multipart part's filename."
  (let ((slash (position #\/ type)))
    (if (and slash (string= "jpeg" (subseq type (1+ slash)))) "jpg" (subseq type (1+ (or slash -1))))))

(defmethod deliver ((p facebook) (m facebook-post))
  (let* ((page (facebook-post-page m))
         (token (%page-token p page))
         (link (facebook-post-link m))
         (message (facebook-post-message m))
         (json (cond
                 ((facebook-post-image-url m)
                  (%facebook-call p :post (format nil "~A/photos" page)
                                  (list (cons "url" (facebook-post-image-url m))
                                        (cons "caption" (%caption message link)))
                                  :token token))
                 ;; The same endpoint, with the photo uploaded as multipart/form-data, as Meta's
                 ;; Page Photos reference says: "Attach the photo as multipart/form-data". The
                 ;; field is named source, the name it says has "historically" been used (#978).
                 ((facebook-post-image-octets m)
                  (%facebook-call p :post (format nil "~A/photos" page)
                                  (list (cons "caption" (%caption message link)))
                                  :token token
                                  :file (list "source"
                                              (format nil "photo.~A" (%photo-extension
                                                                      (facebook-post-image-type m)))
                                              (facebook-post-image-type m)
                                              (facebook-post-image-octets m))))
                 (t
                  (%facebook-call p :post (format nil "~A/feed" page)
                                  (append (when message (list (cons "message" message)))
                                          (when link (list (cons "link" link))))
                                  :token token :link-post (and link t)))))
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

;;; --- the token, and the Page's health --------------------------------------------------

(defstruct (facebook-token-info (:constructor %make-facebook-token-info
                                    (valid-p scopes expires-at data-access-expires-at page-id app-id)))
  "What debug_token says about a Page token (#978).

  VALID-P                 whether Facebook says the token still works.
  SCOPES                  the scopes granted to it, as a list of strings.
  EXPIRES-AT              when the token expires, as a universal time, or :NEVER.
  DATA-ACCESS-EXPIRES-AT  when the app's access to data through the token expires, as a
                          universal time, or NIL when Facebook gave none. It applies to a token
                          that never expires too, so an admin screen shows both.
  PAGE-ID                 the Page the token is for (debug_token's profile_id), or NIL.
  APP-ID                  the app the token was issued to, or NIL.

:NEVER is read from an expires_at of 0 or an absent expires_at. Meta's debug_token reference
does not say what 0 means; Page tokens taken with a long-lived user token, which Meta's
Facebook Login guide says \"do[es] not have an expiration date\", are observed to come back
with 0. That reading is observed behaviour, not documented."
  valid-p scopes expires-at data-access-expires-at page-id app-id)

(defconstant +unix-epoch+ (encode-universal-time 0 0 0 1 1 1970 0)
  "The universal time of 1970-01-01T00:00:00Z, which Graph's unixtime fields count from.")

(defun %token-info-from-json (json)
  "The FACEBOOK-TOKEN-INFO in a debug_token answer JSON (a parsed object), or NIL when it has no
data object."
  (let ((data (and (hash-table-p json) (gethash "data" json))))
    (when (hash-table-p data)
      (flet ((text (key) (let ((v (gethash key data))) (and (stringp v) v)))
             (time-of (key) (let ((v (gethash key data)))
                              (and (integerp v) (plusp v) (+ +unix-epoch+ v)))))
        (%make-facebook-token-info
         (eq t (gethash "is_valid" data))
         (let ((scopes (gethash "scopes" data)))
           (and (vectorp scopes) (remove-if-not #'stringp (coerce scopes 'list))))
         (or (time-of "expires_at") :never)
         (time-of "data_access_expires_at")
         (text "profile_id")
         (text "app_id"))))))

(defmethod facebook-token-info ((p facebook) page)
  (let* ((page (%check-page-id page))
         (token (%page-token p page))
         (app-id (facebook-app-id p))
         (app-secret (%facebook-app-secret p)))
    (unless (and app-id (%reveal app-secret))
      (error 'configuration-error
             :missing "the Meta app's id and secret (FACEBOOK_APP_ID and FACEBOOK_APP_SECRET), which debug_token needs"))
    ;; The app token is built as a SECRET, never as text.
    (let* ((app-token (secret:make-secret (format nil "~A|~A" app-id (%reveal app-secret))))
           (json (%facebook-call p :get "debug_token" (list (cons "input_token" token))
                                 :token app-token)))
      (or (%token-info-from-json json)
          (error 'delivery-failure :provider :facebook
                                   :detail "the Graph API's answer to debug_token carried no data")))))

(defmethod facebook-page-health ((p facebook) page)
  (let ((page (%check-page-id page)))
    (handler-case (%page-token p page)
      (configuration-error () (return-from facebook-page-health :not-connected)))
    (handler-case
        ;; A Page token's /me is its own Page. Reading PAGE itself would succeed for any public
        ;; Page, whichever Page the token belongs to, so the token's Page is compared with PAGE.
        (let* ((me (%facebook-call p :get "me" (list (cons "fields" "id,name"))
                                   :token (%page-token p page)))
               (name (let ((n (gethash "name" me))) (and (stringp n) n))))
          (cond ((not (equal page (gethash "id" me))) (values :wrong-page name))
                ((and (facebook-app-id p) (%reveal (%facebook-app-secret p)))
                 ;; With the app's credentials, ask Facebook what the token may do: a Page token
                 ;; that reads its Page but lacks a scope hermes needs cannot post, and only
                 ;; debug_token says so.
                 (let* ((info (facebook-token-info p page))
                        (missing (remove-if (lambda (scope)
                                              (member scope (facebook-token-info-scopes info)
                                                      :test #'string=))
                                            +facebook-required-scopes+)))
                   (cond ((not (facebook-token-info-valid-p info)) (values :reconnect name))
                         ((not (equal page (facebook-token-info-page-id info)))
                          (values :wrong-page name))
                         (missing (values :missing-permission name missing))
                         (t (values :connected name)))))
                (t (values :connected name))))
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
  (unless (%http-url-p redirect-uri)
    (error 'invalid-message :problem "it needs the :redirect-uri FACEBOOK-CONNECT-URL was given"))
  (%require (%reveal (%facebook-app-secret provider)) "FACEBOOK_APP_SECRET")
  ;; Every secret travels as a SECRET: the app secret, the code, and each user token, which is
  ;; made a SECRET as soon as it arrives. %FACEBOOK-CALL reveals them only into its locals.
  (let* ((app-id (%require (facebook-app-id provider) "FACEBOOK_APP_ID"))
         (app-secret (%facebook-app-secret provider))
         (code (secret:make-secret code))
         (short (or (%connect-step
                     (lambda ()
                       (%token-from (%facebook-call provider :get "oauth/access_token"
                                                    (list (cons "client_id" app-id)
                                                          (cons "redirect_uri" redirect-uri)
                                                          (cons "client_secret" app-secret)
                                                          (cons "code" code))))))
                    (error 'facebook-connect-refused :reason :code-rejected
                                                     :detail "Facebook returned no access token")))
         (long (%connect-step
                (lambda ()
                  (%token-from (%facebook-call provider :get "oauth/access_token"
                                               (list (cons "grant_type" "fb_exchange_token")
                                                     (cons "client_id" app-id)
                                                     (cons "client_secret" app-secret)
                                                     (cons "fb_exchange_token" short))))))))
    (unless long
      (error 'facebook-connect-refused :reason :code-rejected
                                       :detail "Facebook returned no long-lived token"))
    (let ((pages (%managed-pages provider long)))
      (log:info "hermes: facebook pages listed for connecting" :pages (length pages))
      pages)))

(defun %token-from (json)
  "JSON's access_token as a SECRET, or NIL."
  (let ((token (gethash "access_token" json)))
    (and (stringp token) (plusp (length token)) (secret:make-secret token))))

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
