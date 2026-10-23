;;;; tests/facebook.lisp --- the Facebook Page backend (#822).
;;;;
;;;; The backend talks to a real HTTP server on 127.0.0.1 (aion/test-http) that answers the way
;;;; the Graph API does, so the request on the wire and the parsing of the answer are both the
;;;; real code. A live test against a real Page runs only with HERMES_FACEBOOK_LIVE=1.

(cl:in-package #:hermes/tests)

(in-suite hermes)

(defparameter +page-token+ "EAAPageTokenMustNotLeak123"
  "A Page token. Every test that can fail with a URL or a body checks it is absent.")
(defparameter +app-secret+ "app-secret-must-not-leak-456")
(defparameter +page-id+ "1234567890")

(defun %fb-reply (stream status json &optional headers)
  (aion/test-http:write-response stream status
                                 (cons '("Content-Type" . "application/json") headers)
                                 json))

(defun %fb-error (code message &optional subcode)
  (format nil "{\"error\":{\"message\":~S,\"type\":\"OAuthException\",\"code\":~D~@[,\"error_subcode\":~D~],\"fbtrace_id\":\"Abc\"}}"
          message code subcode))

(defun %split-path (path)
  "PATH split at \"?\": (values the path, the query as an alist)."
  (let ((q (position #\? path)))
    (values (subseq path 0 q)
            (and q (%decode-params (subseq path (1+ q)))))))

(defun %percent-decode (text)
  (let ((octets (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (loop with i = 0
          while (< i (length text))
          do (let ((ch (char text i)))
               (cond ((and (char= ch #\%) (<= (+ i 3) (length text)))
                      (vector-push-extend (parse-integer text :start (1+ i) :end (+ i 3) :radix 16) octets)
                      (incf i 3))
                     ((char= ch #\+) (vector-push-extend 32 octets) (incf i))
                     (t (vector-push-extend (char-code ch) octets) (incf i)))))
    (sb-ext:octets-to-string (coerce octets '(vector (unsigned-byte 8))) :external-format :utf-8)))

(defun %decode-params (text)
  "A query string or form body as an alist."
  (loop for pair in (uiop:split-string text :separator "&")
        for eq = (position #\= pair)
        when (plusp (length pair))
          collect (cons (%percent-decode (subseq pair 0 eq))
                        (if eq (%percent-decode (subseq pair (1+ eq))) ""))))

(defun %param (alist name) (cdr (assoc name alist :test #'string=)))

(defun %fb-request (request)
  "REQUEST as (values method path params), PARAMS from the query or the form body."
  (multiple-value-bind (path query) (%split-path (aion/test-http:request-path request))
    (values (aion/test-http:request-method request) path
            (if (string= "POST" (aion/test-http:request-method request))
                (%decode-params (aion/test-http:request-body-string request))
                query))))

(defmacro with-graph ((server provider handler &rest provider-args) &body body)
  "Run BODY with SERVER answering every Graph request with HANDLER, a function of (METHOD PATH
PARAMS STREAM), and PROVIDER a Facebook provider pointed at it. PROVIDER-ARGS are added to
MAKE-FACEBOOK's, before the defaults."
  `(aion/test-http:with-server
       (,server (lambda (request stream)
                  (multiple-value-bind (method path params) (%fb-request request)
                    (funcall ,handler method path params stream))))
     (let ((,server ,server)
           (,provider (h:make-facebook ,@provider-args
                                       :app-id "111" :app-secret +app-secret+
                                       :page-tokens (list (cons +page-id+ +page-token+))
                                       :graph-base (aion/test-http:server-url ,server "")
                                       :dialog-base "https://www.facebook.example")))
       (declare (ignorable ,server))
       ,@body)))

(defun %fb-always (status json &optional headers)
  (lambda (method path params stream)
    (declare (ignore method path params))
    (%fb-reply stream status json headers)))

(defun %no-secret-p (text)
  "True when TEXT shows neither the Page token nor the app secret, as written or encoded."
  (let ((s (princ-to-string text)))
    (notany (lambda (secret) (search secret s)) (list +page-token+ +app-secret+))))

(defun %fb-requests (server)
  (mapcar (lambda (r) (multiple-value-list (%fb-request r)))
          (reverse (aion/test-http:server-requests server))))

;;; --- the post ------------------------------------------------------------------

(test facebook-post-goes-to-the-page-feed-with-the-token-in-the-body
  (with-graph (server fb (%fb-always 200 "{\"id\":\"1234567890_987\"}"))
    (is (string= "1234567890_987" (h:post-to-page +page-id+ "https://example.com/a" :message "New post"
                                                  :provider fb)))
    (destructuring-bind ((method path params)) (%fb-requests server)
      (is (string= "POST" method))
      (is (string= "/v26.0/1234567890/feed" path) "~A" path)
      (is (string= "New post" (%param params "message")))
      (is (string= "https://example.com/a" (%param params "link")))
      (is (string= +page-token+ (%param params "access_token")) "the token is in the body")
      (is (= 64 (length (%param params "appsecret_proof"))) "signed with appsecret_proof"))
    (is (notany (lambda (head) (search +page-token+ head)) (aion/test-http:server-heads server))
        "and not in the request line or a header")))

(test facebook-post-with-an-image-goes-to-photos-with-a-caption
  (with-graph (server fb (%fb-always 200 "{\"id\":\"555\",\"post_id\":\"1234567890_555\"}"))
    (let ((result (h:deliver fb (h:make-facebook-post :page +page-id+ :link "https://example.com/a"
                                                       :message "Look" :image-url "https://example.com/i.jpg"))))
      (is (string= "1234567890_555" (h:delivery-result-id result)) "the post id, not the photo id")
      (is (eq :facebook (h:delivery-result-provider result)))
      (is (string= +page-id+ (h:delivery-result-destination result))))
    (destructuring-bind ((method path params)) (%fb-requests server)
      (declare (ignore method))
      (is (string= "/v26.0/1234567890/photos" path))
      (is (string= "https://example.com/i.jpg" (%param params "url")))
      (is (string= (format nil "Look~%https://example.com/a") (%param params "caption"))))))

(test facebook-page-token-is-looked-up-per-page
  (with-graph (server fb (%fb-always 200 "{\"id\":\"x_1\"}")
                      :page-tokens (list (cons "111" "token-one") (cons "222" "token-two")))
    (h:post-to-page "111" nil :message "a" :provider fb)
    (h:post-to-page 222 nil :message "b" :provider fb)
    (is (equal '("token-one" "token-two")
               (mapcar (lambda (r) (%param (third r) "access_token")) (%fb-requests server))))
    (let ((c (handler-case (progn (h:post-to-page "333" nil :message "c" :provider fb) nil)
               (h:configuration-error (c) c))))
      (is (typep c 'h:configuration-error))
      (is (search "333" (h:configuration-error-missing c)) "it names the Page with no token"))
    (is (= 2 (length (%fb-requests server))) "nothing was sent for the Page with no token")))

(test facebook-page-token-defaults-to-the-environment
  (with-env (("FACEBOOK_PAGE_TOKEN_777" "env-token-777") ("FACEBOOK_PAGE_TOKEN" "env-token-any"))
    (aion/test-http:with-server
        (server (lambda (request stream) (declare (ignore request)) (%fb-reply stream 200 "{\"id\":\"x\"}")))
      (let ((fb (h:make-facebook :app-id "111" :app-secret nil
                                 :graph-base (aion/test-http:server-url server ""))))
        (h:post-to-page "777" nil :message "a" :provider fb)
        (h:post-to-page "888" nil :message "b" :provider fb)
        (is (equal '("env-token-777" "env-token-any")
                   (mapcar (lambda (r) (%param (third r) "access_token")) (%fb-requests server))))
        (is (null (%param (third (first (%fb-requests server))) "appsecret_proof"))
            "no proof without an app secret")))))

(test facebook-post-checks-its-arguments-and-refuses-groups
  (signals h:facebook-groups-unsupported (h:make-facebook-post :page "https://www.facebook.com/groups/123/" :message "x"))
  (signals h:facebook-groups-unsupported (h:make-facebook-post :page "group:123" :message "x"))
  (signals h:invalid-message (h:make-facebook-post :page "my-page" :message "x"))
  (signals h:invalid-message (h:make-facebook-post :page +page-id+))
  (signals h:invalid-message (h:make-facebook-post :page +page-id+ :link "ftp://example.com/a"))
  (signals h:invalid-message (h:make-facebook-post :page +page-id+ :link "https://example.com/a b"))
  (signals h:invalid-message (h:make-facebook-post :page +page-id+ :message "x" :image-url "not a url"))
  (is (h:facebook-post-p (h:make-facebook-post :page 1234567890 :link "https://example.com/a"))
      "the control: an integer Page id and a link alone are a post")
  (is (string= "1234567890" (h:facebook-post-page (h:make-facebook-post :page 1234567890 :message "x")))))

;;; --- failures ------------------------------------------------------------------------

(defun %fb-refusal (status json &key headers (link "https://example.com/a"))
  "The condition a post refused with STATUS and JSON signals."
  (with-graph (server fb (%fb-always status json headers))
    (handler-case (progn (h:post-to-page +page-id+ link :message "m" :provider fb) nil)
      (h:delivery-failure (c) c))))

(test facebook-graph-errors-become-typed-conditions
  (flet ((class-of-refusal (status json &rest args)
           (type-of (apply #'%fb-refusal status json args))))
    (is (eq 'h:facebook-reconnect-required (class-of-refusal 400 (%fb-error 190 "Error validating access token"))))
    (is (eq 'h:facebook-reconnect-required (class-of-refusal 400 (%fb-error 190 "expired" 463))))
    (is (eq 'h:facebook-reconnect-required (class-of-refusal 400 (%fb-error 102 "Session key invalid"))))
    (is (eq 'h:facebook-reconnect-required (class-of-refusal 400 (%fb-error 100 "no role on the Page" 492)))
        "subcode 492: the admin no longer has a role on the Page")
    (is (eq 'h:facebook-not-permitted (class-of-refusal 403 (%fb-error 200 "Permissions error"))))
    (is (eq 'h:facebook-not-permitted (class-of-refusal 403 (%fb-error 10 "Permission denied"))))
    (is (eq 'h:facebook-page-not-found (class-of-refusal 400 (%fb-error 100 "Object does not exist" 33))))
    (is (eq 'h:facebook-page-not-found (class-of-refusal 404 (%fb-error 803 "Some of the aliases you requested do not exist"))))
    (is (eq 'h:facebook-link-not-public (class-of-refusal 400 (%fb-error 100 "The link could not be fetched"))))
    (is (eq 'h:delivery-failure (class-of-refusal 400 (%fb-error 100 "The link could not be fetched") :link nil))
        "the control: the same error on a post without a link is not about a link")
    (is (eq 'h:delivery-failure (class-of-refusal 500 (%fb-error 1 "An unknown error occurred")))
        "an unknown code stays a plain DELIVERY-FAILURE")
    (dolist (code '(4 17 32 613 80001))
      (is (eq 'h:delivery-rate-limited (class-of-refusal 400 (%fb-error code "Too many calls"))) "code ~D" code))))

(test facebook-rate-limit-reads-the-wait-from-the-business-use-case-header
  (let ((c (%fb-refusal 400 (%fb-error 80001 "There have been too many calls to this Page account")
                        :headers '(("X-Business-Use-Case-Usage" . "{\"1234567890\":[{\"type\":\"pages\",\"call_count\":100,\"estimated_time_to_regain_access\":3},{\"type\":\"pages\",\"estimated_time_to_regain_access\":1}]}")))))
    (is (typep c 'h:delivery-rate-limited))
    (is (eql 180 (h:delivery-rate-limited-retry-after c)) "the largest wait, 3 minutes, in seconds"))
  (let ((c (%fb-refusal 400 (%fb-error 4 "Application request limit reached"))))
    (is (null (h:delivery-rate-limited-retry-after c)) "no header, no wait")))

(test facebook-failures-never-show-a-secret
  (let ((c (%fb-refusal 400 (%fb-error 190 (format nil "token ~A and secret ~A are bad" +page-token+ +app-secret+)))))
    (is (typep c 'h:facebook-reconnect-required))
    (is (%no-secret-p (h:delivery-failure-detail c)) "~A" (h:delivery-failure-detail c))
    (is (%no-secret-p (princ-to-string c)))
    (is (search "Graph error 190" (h:delivery-failure-detail c)) "the code is in the detail"))
  (let ((hermes::*facebook-perform*
          (lambda (req) (error "connection reset while talking to ~A with ~A"
                               (aion/http-client:request-url req) (aion/http-client:request-content req)))))
    (let ((c (%fb-refusal 200 "{}")))
      (is (typep c 'h:delivery-failure))
      (is (%no-secret-p (h:delivery-failure-detail c)) "~A" (h:delivery-failure-detail c)))))

;;; --- health ------------------------------------------------------------------------------

(defparameter +debug-ok+
  "{\"data\":{\"is_valid\":true,\"profile_id\":\"1234567890\",\"scopes\":[\"pages_show_list\",\"pages_read_engagement\",\"pages_manage_posts\"]}}")

(defun %health-handler (&key (me-status 200) (me-json "{\"id\":\"1234567890\",\"name\":\"My Page\"}")
                             (debug-status 200) (debug-json +debug-ok+))
  (lambda (method path params stream)
    (declare (ignore method params))
    (if (search "debug_token" path)
        (%fb-reply stream debug-status debug-json)
        (%fb-reply stream me-status me-json))))

(test facebook-page-health-answers-for-an-admin-screen
  (flet ((health (handler &rest args)
           (with-graph (server fb handler)
             (multiple-value-list (h:facebook-page-health fb (or (getf args :page) +page-id+))))))
    (is (equal '(:connected "My Page") (health (%health-handler))))
    (is (eq :reconnect (first (health (%health-handler :debug-json "{\"data\":{\"is_valid\":false}}")))))
    (is (eq :reconnect (first (health (%health-handler :debug-json "{\"data\":{\"is_valid\":true,\"profile_id\":\"1234567890\",\"scopes\":[\"pages_show_list\"]}}"))))
        "a token without pages_manage_posts cannot post")
    (is (eq :reconnect (first (health (%health-handler :me-status 400 :me-json (%fb-error 190 "expired"))))))
    (is (eq :not-permitted (first (health (%health-handler :me-status 403 :me-json (%fb-error 10 "denied"))))))
    (is (eq :not-found (first (health (%health-handler :me-status 400 :me-json (%fb-error 100 "missing" 33))))))
    (is (eq :not-connected (first (health (%health-handler) :page "999"))) "no token is stored for that Page")))

(test facebook-page-health-catches-a-token-for-another-page
  "Reading a public Page works with any Page's token, so the check compares the token's own Page
(its /me, and debug_token's profile_id) with the Page asked about."
  (flet ((health (handler)
           (with-graph (server fb handler)
             (first (multiple-value-list (h:facebook-page-health fb +page-id+))))))
    (is (eq :wrong-page (health (%health-handler :me-json "{\"id\":\"999\",\"name\":\"Another Page\"}"))))
    (is (eq :wrong-page (health (%health-handler :debug-json "{\"data\":{\"is_valid\":true,\"profile_id\":\"999\",\"scopes\":[\"pages_manage_posts\"]}}"))))
    (is (eq :connected (health (%health-handler))) "the control: the token's Page is this Page"))
  (aion/test-http:with-server
      (server (lambda (request stream) (declare (ignore request))
                (%fb-reply stream 200 "{\"id\":\"999\",\"name\":\"Another Page\"}")))
    (let ((fb (h:make-facebook :app-id nil :app-secret nil
                               :page-tokens (list (cons +page-id+ +page-token+))
                               :graph-base (aion/test-http:server-url server ""))))
      (is (eq :wrong-page (h:facebook-page-health fb +page-id+)) "without app credentials too"))))

(test facebook-page-health-refuses-what-is-not-a-page-id
  (with-graph (server fb (%health-handler))
    (dolist (bad '("me/accounts" "123?fields=access_token" "../x" "" "12 34"))
      (signals h:invalid-message (h:facebook-page-health fb bad)))
    (is (null (%fb-requests server)) "nothing was sent")))

(test facebook-page-health-sends-tokens-in-headers-not-urls
  (with-graph (server fb (%health-handler))
    (h:facebook-page-health fb +page-id+)
    (let ((raw (reverse (aion/test-http:server-requests server))))
      (destructuring-bind ((m1 p1 q1) (m2 p2 q2)) (%fb-requests server)
        (declare (ignore m1 m2))
        (is (string= "/v26.0/me" p1))
        (is (null (%param q1 "access_token")) "the Page token is not in the query")
        (is (string= (format nil "OAuth ~A" +page-token+) (aion/test-http:request-header (first raw) "Authorization")))
        (is (string= "/v26.0/debug_token" p2))
        (is (string= +page-token+ (%param q2 "input_token")) "debug_token takes the token it inspects as a parameter")
        (is (null (%param q2 "access_token")))
        (is (string= (format nil "OAuth 111|~A" +app-secret+) (aion/test-http:request-header (second raw) "Authorization"))))
      (is (notany (lambda (r) (search +app-secret+ (aion/test-http:request-path r))) raw)
          "the app secret is in no request line"))))

(defun %secrets-in (text)
  "Which of the test secrets TEXT shows."
  (remove-if-not (lambda (s) (search s text)) (list +page-token+ +app-secret+ "the-code" "short-user-token" "long-user-token")))

(test facebook-health-failures-log-no-secret-in-a-backtrace
  "A refusal is signalled from %FACEBOOK-CALL's frame, and a request middleware logs the backtrace
before unwinding, printing each frame's arguments. Neither the Page token nor the app secret may
appear: they reach that frame only as SECRETs. Each answer here is one the health check does not
turn into a status, so it is signalled through the handler."
  (dolist (answer (list (list 500 "not json at all") (list 400 (%fb-error 4 "Application request limit reached"))
                        (list 502 (%fb-error 1 "An unknown error occurred"))))
    (with-graph (server fb (%health-handler :debug-status (first answer) :debug-json (second answer)))
      (let ((log (%logged-exception (lambda () (h:facebook-page-health fb +page-id+)))))
        (is (search "Backtrace" log) "a backtrace was logged for ~S: ~A" (first answer) (subseq log 0 (min 200 (length log))))
        (is (null (%secrets-in log)) "~S: ~S in the log" (first answer) (%secrets-in log))))))

(test facebook-connect-failures-log-no-secret-in-a-backtrace
  "The same for the connect flow, whose second exchange carries the app secret and the short user
token. %CONNECT-STEP's own handler unwinds %FACEBOOK-CALL's frame before an outer handler sees the
condition, so this held before the secrets travelled as SECRETs too; it records that it holds."
  (flet ((handler (status json)
           (let ((connect (%connect-handler)))
             (lambda (method path params stream)
               (if (and (search "oauth/access_token" path) (%param params "fb_exchange_token"))
                   (%fb-reply stream status json)
                   (funcall connect method path params stream))))))
    (dolist (answer (list (list 500 "not json") (list 400 (%fb-error 4 "Application request limit reached"))))
      (with-graph (server fb (handler (first answer) (second answer)))
        (let* ((state (h:facebook-connect-state))
               (log (%logged-exception
                     (lambda () (h:facebook-connect-pages fb :code "the-code" :state state :expected-state state
                                                             :redirect-uri "https://app.example.com/cb")))))
          (is (search "Backtrace" log) "a backtrace was logged for ~S" (first answer))
          (is (subsetp (%secrets-in log) '("the-code") :test #'string=)
              "~S: ~S in the log; only the caller's own code argument may show" (first answer) (%secrets-in log)))))))

(test facebook-rate-limit-survives-a-malformed-business-use-case-header
  (dolist (header '("not json" "{\"1234\":5}" "{\"1234\":[{\"estimated_time_to_regain_access\":\"soon\"}]}" "[]"))
    (let ((c (%fb-refusal 400 (%fb-error 80001 "Too many calls") :headers (list (cons "X-Business-Use-Case-Usage" header)))))
      (is (typep c 'h:delivery-rate-limited) "~S" header)
      (is (null (h:delivery-rate-limited-retry-after c)) "~S gives no wait" header))))

;;; --- connecting ---------------------------------------------------------------------------

(test facebook-connect-url-carries-the-state-and-no-secret
  (with-graph (server fb (%fb-always 200 "{}"))
    (let* ((state (h:facebook-connect-state))
           (url (h:facebook-connect-url fb :redirect-uri "https://app.example.com/facebook/callback?x=1"
                                           :state state)))
      (is (= 64 (length state)) "256 bits in hex")
      (is (string/= state (h:facebook-connect-state)) "a new state each time")
      (is (eql 0 (search "https://www.facebook.example/v26.0/dialog/oauth?" url)) "~A" url)
      (multiple-value-bind (path query) (%split-path url)
        (declare (ignore path))
        (is (string= "111" (%param query "client_id")))
        (is (string= "https://app.example.com/facebook/callback?x=1" (%param query "redirect_uri")))
        (is (string= state (%param query "state")))
        (is (string= "code" (%param query "response_type")))
        (is (string= "pages_show_list,pages_read_engagement,pages_manage_posts" (%param query "scope"))))
      (is (%no-secret-p url)))
    (signals h:invalid-message (h:facebook-connect-url fb :redirect-uri "https://app.example.com/cb" :state "short"))
    (signals h:invalid-message (h:facebook-connect-url fb :redirect-uri "/cb" :state (h:facebook-connect-state)))))

(defun %connect-handler (&key (code-status 200) (code-json "{\"access_token\":\"short-user-token\",\"token_type\":\"bearer\"}"))
  (lambda (method path params stream)
    (declare (ignore method))
    (cond ((and (search "oauth/access_token" path) (%param params "code"))
           (%fb-reply stream code-status code-json))
          ((search "oauth/access_token" path)
           (%fb-reply stream 200 "{\"access_token\":\"long-user-token\",\"token_type\":\"bearer\",\"expires_in\":5183944}"))
          ((and (search "me/accounts" path) (null (%param params "after")))
           (%fb-reply stream 200 "{\"data\":[{\"id\":\"111\",\"name\":\"First\",\"access_token\":\"page-token-1\",\"tasks\":[\"ANALYZE\",\"CREATE_CONTENT\"]}],\"paging\":{\"cursors\":{\"before\":\"a\",\"after\":\"c1\"},\"next\":\"https://graph.example/next\"}}"))
          ((search "me/accounts" path)
           (%fb-reply stream 200 "{\"data\":[{\"id\":\"222\",\"name\":\"Second\",\"access_token\":\"page-token-2\",\"tasks\":[\"ANALYZE\"]}],\"paging\":{\"cursors\":{\"before\":\"c1\",\"after\":\"c2\"}}}"))
          (t (%fb-reply stream 404 (%fb-error 803 "unexpected"))))))

(test facebook-connect-pages-exchanges-server-side-and-lists-the-pages
  (with-graph (server fb (%connect-handler))
    (let* ((state (h:facebook-connect-state))
           (pages (h:facebook-connect-pages fb :code "the-code" :state state :expected-state state
                                               :redirect-uri "https://app.example.com/cb")))
      (is (equal '("111" "222") (mapcar #'h:facebook-page-id pages)) "both pages of the paged list")
      (is (equal '("First" "Second") (mapcar #'h:facebook-page-name pages)))
      (is (every (lambda (p) (aion/secret:secretp (h:facebook-page-token p))) pages) "tokens are secrets")
      (is (string= "page-token-1" (aion/secret:reveal (h:facebook-page-token (first pages)))))
      (is (equal '(t nil) (mapcar #'h:facebook-page-can-post-p pages)) "CREATE_CONTENT decides")
      (is (not (search "page-token-1" (princ-to-string pages))) "a printed Page shows no token")
      (destructuring-bind ((m1 p1 q1) (m2 p2 q2) (m3 p3 q3) (m4 p4 q4)) (%fb-requests server)
        (declare (ignore m1 m2 m3 m4 p4))
        (is (string= "/v26.0/oauth/access_token" p1))
        (is (equal '("111" "https://app.example.com/cb" "the-code")
                   (list (%param q1 "client_id") (%param q1 "redirect_uri") (%param q1 "code"))))
        (is (string= +app-secret+ (%param q1 "client_secret")) "the secret goes only to Facebook, server-side")
        (is (string= "/v26.0/oauth/access_token" p2))
        (is (equal '("fb_exchange_token" "short-user-token") (list (%param q2 "grant_type") (%param q2 "fb_exchange_token"))))
        (is (string= "/v26.0/me/accounts" p3))
        (is (null (%param q3 "access_token")) "the user token is not in the query")
        (is (string= "OAuth long-user-token"
                     (aion/test-http:request-header (third (reverse (aion/test-http:server-requests server)))
                                                    "Authorization"))
            "the Pages are listed with the long-lived token")
        (is (string= "c1" (%param q4 "after")) "and the next page is asked for by its cursor")))))

(test facebook-connect-pages-needs-the-redirect-uri
  (with-graph (server fb (%connect-handler))
    (let ((state (h:facebook-connect-state)))
      (signals h:invalid-message (h:facebook-connect-pages fb :code "c" :state state :expected-state state))
      (signals h:invalid-message (h:facebook-connect-pages fb :code "c" :state state :expected-state state
                                                              :redirect-uri "/cb"))
      (is (null (%fb-requests server)) "nothing was sent"))))

(test facebook-connect-pages-checks-the-state-before-any-request
  (with-graph (server fb (%connect-handler))
    (let ((state (h:facebook-connect-state)))
      (flet ((reason (&rest args)
               (handler-case (progn (apply #'h:facebook-connect-pages fb :redirect-uri "https://app.example.com/cb" args) nil)
                 (h:facebook-connect-refused (c) (h:facebook-connect-refused-reason c)))))
        (is (eq :state-mismatch (reason :code "c" :state state :expected-state (h:facebook-connect-state))))
        (is (eq :state-mismatch (reason :code "c" :state state :expected-state nil)) "no state in the session")
        (is (eq :state-mismatch (reason :code "c" :state nil :expected-state state)))
        (is (eq :state-mismatch (reason :code "c" :state (subseq state 0 63) :expected-state state)))
        (is (null (%fb-requests server)) "none of those sent anything")
        (is (eq :denied (reason :state state :expected-state state :error "access_denied")))
        (is (null (%fb-requests server)) "nor did a denied callback")))))

(test facebook-connect-pages-reports-a-rejected-code-without-secrets
  (with-graph (server fb (%connect-handler :code-status 400
                                           :code-json (%fb-error 100 (format nil "This authorization code has been used: the-code ~A" +app-secret+) 36009)))
    (let* ((state (h:facebook-connect-state))
           (c (handler-case (progn (h:facebook-connect-pages fb :code "the-code" :state state :expected-state state
                                                                :redirect-uri "https://app.example.com/cb")
                                   nil)
                (h:facebook-connect-refused (c) c))))
      (is (eq :code-rejected (and c (h:facebook-connect-refused-reason c))))
      (is (and c (%no-secret-p (h:facebook-connect-refused-detail c))) "~A" (and c (h:facebook-connect-refused-detail c)))
      (is (and c (not (search "the-code" (h:facebook-connect-refused-detail c)))) "nor the code"))))

;;; --- the dev transport and selection -------------------------------------------------------

(test facebook-dev-transport-renders-instead-of-posting
  (let* ((out (make-string-output-stream))
         (dev (h:make-dev-transport :stream out))
         (post (h:make-facebook-post :page +page-id+ :link "https://example.com/a" :message "Hello"))
         (result (h:deliver dev post)))
    (is (eq :logged (h:delivery-result-status result)))
    (is (eq post (h:dev-last-facebook dev)))
    (is (string= +page-id+ (h:delivery-result-destination result)))
    (is (search "FACEBOOK POST (not sent)" (get-output-stream-string out)))
    (is (eq :connected (h:facebook-page-health dev +page-id+)))))

(test facebook-send-uses-the-provider-hermes-facebook-impl-names
  (with-env (("HERMES_TRANSPORT" nil) ("HERMES_FACEBOOK_IMPL" "dev"))
    (let ((*standard-output* (make-broadcast-stream)))
      (is (eq :dev (h:delivery-result-provider (h:send (h:make-facebook-post :page +page-id+ :message "x")))))
      (is (typep (h:facebook-provider-from-env) 'h:dev-transport)))))

;;; --- live, only on request -----------------------------------------------------------------

(test facebook-live-post-to-a-test-page
  "Posts to a real test Page, only with HERMES_FACEBOOK_LIVE=1, FACEBOOK_TEST_PAGE_ID and its
FACEBOOK_PAGE_TOKEN_<id> (and FACEBOOK_APP_ID / FACEBOOK_APP_SECRET for the health check)."
  (let ((page (uiop:getenv "FACEBOOK_TEST_PAGE_ID")))
    (if (not (and (equal "1" (uiop:getenv "HERMES_FACEBOOK_LIVE")) page))
        (skip "live Facebook test not requested (HERMES_FACEBOOK_LIVE=1 and FACEBOOK_TEST_PAGE_ID)")
        (let ((fb (h:make-facebook)))
          (is (eq :connected (h:facebook-page-health fb page)))
          (is (stringp (h:post-to-page page nil :message "hermes live test (#822)" :provider fb)))))))
