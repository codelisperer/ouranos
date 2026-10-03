;;;; oauth.lisp --- aion/oauth against an authorization server run in the test image (#527)
;;;;
;;;; One test server plays the protected resource, its metadata and the authorization server,
;;;; on 127.0.0.1. Each test sets it to behave correctly or to do one wrong thing, and checks
;;;; that the client refuses what it must. The authorization endpoint approves at once and
;;;; answers with a 302, so no browser is involved: the test reads the Location and passes its
;;;; parameters to FINISH-SIGN-IN, as an app's route would.

(cl:defpackage #:aion/oauth/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:oauth #:aion/oauth)
                    (#:http #:aion/http-client)
                    (#:th #:aion/test-http)
                    (#:secret #:aion/secret)
                    (#:jzon #:com.inuoe.jzon))
  (:export #:run-tests))

(cl:in-package #:aion/oauth/tests)

(def-suite oauth :description "aion/oauth: discovery, sign-in, refresh and disconnect.")
(in-suite oauth)

(defmacro net-test (name &body body)
  "A test that talks to the test authorization server. On Windows it is skipped, because
aion/oauth signs in only through FETCH-PUBLIC, which cannot pin a connection there (#295); the
Windows test below checks that it refuses."
  (let ((doc (and (stringp (first body)) (list (pop body)))))
    `(test ,name ,@doc
       #+os-windows (skip "aion/oauth needs a pinned connection, which Windows does not offer (#295)")
       #-os-windows (progn ,@body))))

(defun run-tests ()
  (let ((results (run 'oauth)))
    (explain! results)
    (unless (results-status results)
      (error "aion/oauth tests failed: ~{~A~^, ~}"
             (remove-duplicates
              (mapcar (lambda (r) (fiveam::name (fiveam::test-case r)))
                      (remove-if-not #'fiveam::test-failure-p results)))))))

;;; --- the test server -------------------------------------------------------------------

(defstruct (as (:constructor make-as (&key (prm-at :challenge) (issuer-path "") (s256 t)
                                         (registration t) cimd iss-supported (send-iss :right)
                                         scopes challenge-scope as-scopes (expires-in 3600)
                                         rotate prm-resource wrong-issuer bad-token-endpoint
                                         token-redirect-to)))
  "What the test authorization server does. PRM-AT is where the protected resource metadata is
served: :CHALLENGE (named in the 401), :PATH (the path-inserted well-known URL) or :ROOT."
  prm-at issuer-path s256 registration cimd iss-supported send-iss scopes challenge-scope
  as-scopes expires-in rotate prm-resource wrong-issuer bad-token-endpoint token-redirect-to
  (other-issuer nil)
  (base "") (codes (make-hash-table :test #'equal)) (access (make-hash-table :test #'equal))
  (refresh (make-hash-table :test #'equal)) (registrations 0) (token-requests 0)
  (refresh-requests 0) (revoked '()) (last-registration nil)
  (lock (sb-thread:make-mutex)))

(defun %obj (&rest kv)
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on kv by #'cddr do (setf (gethash k h) v))
    h))

(defun %json (stream status object &optional headers)
  (th:write-response stream status (append '(("Content-Type" . "application/json")) headers)
                     (jzon:stringify object)))

(defun %form (request)
  (quri:url-decode-params (th:request-body-string request)))

(defun %query (path)
  (let ((q (position #\? path)))
    (if q (quri:url-decode-params (subseq path (1+ q))) '())))

(defun %path-only (path) (subseq path 0 (or (position #\? path) (length path))))

(defun %issuer (as) (format nil "~A~A" (as-base as) (as-issuer-path as)))
(defun %resource (as) (format nil "~A/mcp" (as-base as)))

(defun %b64url-sha256 (s)
  (string-right-trim "=" (substitute #\_ #\/ (substitute #\- #\+ (cl-base64:usb8-array-to-base64-string
                                                                  (ironclad:digest-sequence :sha256 (sb-ext:string-to-octets s :external-format :ascii)))))))

(defun %new-token (as kind resource &optional (table (if (eq kind :access) (as-access as) (as-refresh as))))
  (let ((token (format nil "~(~A~)-~D" kind (random 1000000000))))
    (setf (gethash token table) resource)
    token))

(defun %issue (as stream resource scope)
  (%json stream 200 (%obj "access_token" (%new-token as :access resource)
                          "token_type" "Bearer"
                          "expires_in" (as-expires-in as)
                          "refresh_token" (%new-token as :refresh resource)
                          "scope" (or scope ""))))

(defun %serve (as)
  (lambda (request stream)
    (let* ((path (th:request-path request))
           (bare (%path-only path)))
      (sb-thread:with-mutex ((as-lock as))
        (cond
          ;; The protected resource.
          ((string= bare "/mcp")
           (let* ((auth (th:request-header request "Authorization"))
                  (token (and auth (> (length auth) 7) (subseq auth 7))))
             (if (and token (equal (gethash token (as-access as)) (%resource as)))
                 (%json stream 200 (%obj "ok" t))
                 (th:write-response
                  stream 401
                  (list (cons "WWW-Authenticate"
                              (format nil "Bearer error=\"invalid_token\"~@[, resource_metadata=\"~A\"~]~@[, scope=\"~A\"~]"
                                      (and (eq (as-prm-at as) :challenge)
                                           (format nil "~A/prm" (as-base as)))
                                      (as-challenge-scope as))))
                  ""))))
          ;; The protected resource metadata.
          ((or (and (eq (as-prm-at as) :challenge) (string= bare "/prm"))
               (and (eq (as-prm-at as) :path) (string= bare "/.well-known/oauth-protected-resource/mcp"))
               (and (eq (as-prm-at as) :root) (string= bare "/.well-known/oauth-protected-resource")))
           (%json stream 200 (%obj "resource" (or (as-prm-resource as) (%resource as))
                                   "authorization_servers" (vector (or (as-other-issuer as) (%issuer as)))
                                   "scopes_supported" (coerce (as-scopes as) 'vector))))
          ;; The authorization server metadata, at the path-inserted URL for an issuer with a path.
          ((string= bare (format nil "/.well-known/oauth-authorization-server~A" (as-issuer-path as)))
           (let ((base (as-base as)))
             (%json stream 200
                    (%obj "issuer" (if (as-wrong-issuer as) "https://honest.example" (%issuer as))
                          "authorization_endpoint" (format nil "~A/authorize" base)
                          "token_endpoint" (or (as-bad-token-endpoint as) (format nil "~A/token" base))
                          "registration_endpoint" (if (as-registration as) (format nil "~A/register" base) 'null)
                          "revocation_endpoint" (format nil "~A/revoke" base)
                          "code_challenge_methods_supported" (if (as-s256 as) (vector "S256") (vector "plain"))
                          "scopes_supported" (coerce (as-as-scopes as) 'vector)
                          "client_id_metadata_document_supported" (if (as-cimd as) t nil)
                          "authorization_response_iss_parameter_supported" (if (as-iss-supported as) t nil)))))
          ((string= bare "/register")
           (incf (as-registrations as))
           (setf (as-last-registration as) (jzon:parse (th:request-body-string request)))
           (%json stream 201 (%obj "client_id" "registered-client")))
          ((string= bare "/authorize")
           (let* ((q (%query path))
                  (code (format nil "code-~D" (random 1000000000))))
             (setf (gethash code (as-codes as))
                   (list :challenge (cdr (assoc "code_challenge" q :test #'string=))
                         :resource (cdr (assoc "resource" q :test #'string=))
                         :client (cdr (assoc "client_id" q :test #'string=))
                         :scope (cdr (assoc "scope" q :test #'string=))))
             (th:write-response
              stream 302
              (list (cons "Location"
                          (format nil "~A?~A" (cdr (assoc "redirect_uri" q :test #'string=))
                                  (quri:url-encode-params
                                   (append (list (cons "code" code)
                                                 (cons "state" (cdr (assoc "state" q :test #'string=))))
                                           (case (as-send-iss as)
                                             (:right (list (cons "iss" (%issuer as))))
                                             (:wrong (list (cons "iss" "https://evil.example")))))))))
              "")))
          ((string= bare "/token")
           (incf (as-token-requests as))
           (let* ((form (%form request))
                  (grant (cdr (assoc "grant_type" form :test #'string=))))
             (cond
               ((as-token-redirect-to as)
                (th:write-response stream 307 (list (cons "Location" (as-token-redirect-to as))) ""))
               ((equal grant "authorization_code")
                (let ((entry (gethash (cdr (assoc "code" form :test #'string=)) (as-codes as))))
                  (remhash (cdr (assoc "code" form :test #'string=)) (as-codes as))
                  (if (and entry
                           (equal (getf entry :challenge)
                                  (%b64url-sha256 (or (cdr (assoc "code_verifier" form :test #'string=)) "")))
                           (equal (getf entry :resource) (cdr (assoc "resource" form :test #'string=))))
                      (%issue as stream (getf entry :resource) (getf entry :scope))
                      (%json stream 400 (%obj "error" "invalid_grant")))))
               ((equal grant "refresh_token")
                (incf (as-refresh-requests as))
                (let* ((rt (cdr (assoc "refresh_token" form :test #'string=)))
                       (resource (gethash rt (as-refresh as))))
                  (sleep 0.05)   ; long enough for a second refresh to overlap a first
                  (cond ((or (null resource) (member rt (as-revoked as) :test #'string=))
                         (%json stream 400 (%obj "error" "invalid_grant")))
                        (t
                         (when (as-rotate as) (remhash rt (as-refresh as)))
                         (%json stream 200
                                (append-refresh as resource))))))
               (t (%json stream 400 (%obj "error" "unsupported_grant_type"))))))
          ((string= bare "/revoke")
           (push (cdr (assoc "token" (%form request) :test #'string=)) (as-revoked as))
           (th:write-response stream 200 '() ""))
          (t (th:write-response stream 404 '() "")))))))

(defun append-refresh (as resource)
  (%obj "access_token" (%new-token as :access resource)
        "token_type" "Bearer" "expires_in" (as-expires-in as)
        "refresh_token" (if (as-rotate as) (%new-token as :refresh resource) 'null)))

(defmacro with-as ((as &rest options) &body body)
  (let ((server (gensym)))
    `(let ((,as (make-as ,@options)))
       (th:with-server (,server (%serve ,as))
         (setf (as-base ,as) (format nil "http://127.0.0.1:~D" (th:server-port ,server)))
         ,@body))))

(defun %broker (&rest args)
  (apply #'oauth:make-broker :store (oauth:make-memory-store)
         :redirect-uri "http://127.0.0.1:1/callback"
         :address-policy (constantly :public)
         args))

(defun %challenge-of (as)
  "The WWW-Authenticate of an unauthenticated request to AS's resource."
  (let ((r (http:send-request (http:make-request :url (%resource as) :follow-redirects nil) '())))
    (http:header-value (http:response-headers r) "www-authenticate")))

(defun %approve (url)
  "Follow the authorization URL to its 302 and return the callback's parameters."
  (let* ((r (http:send-request (http:make-request :url url :follow-redirects nil) '()))
         (location (http:header-value (http:response-headers r) "location")))
    (%query location)))

(defun %sign-in (as broker &key (principal "u1") (connection "docs") scopes)
  (oauth:finish-sign-in broker principal
                        (%approve (oauth:start-sign-in broker principal connection (%resource as)
                                                       :challenge (%challenge-of as) :scopes scopes))))

(defun %call-resource (as token)
  (http:response-status
   (http:send-request (http:make-request :url (%resource as) :follow-redirects nil
                                         :headers (list (cons "Authorization" (format nil "Bearer ~A" token))))
                      '())))

;;; --- the whole path --------------------------------------------------------------------

(net-test from-the-first-401-to-a-call-that-succeeds
  "A 401, discovery, dynamic registration, sign-in, the code exchanged with the verifier and
the resource, and a call with the token."
  (with-as (as :scopes '("generate"))
    (let ((broker (%broker :application-type "native")))
      (is (equal (values "u1" "docs") (%sign-in as broker)))
      (is (= 1 (as-registrations as)))
      (is (equal "native" (gethash "application_type" (as-last-registration as))))
      (let ((token (oauth:access-token broker "u1" "docs" (%resource as))))
        (is (stringp token))
        (is (= 200 (%call-resource as token))))
      (let ((ts (oauth:get-token (oauth:broker-store broker) "u1" "docs")))
        (is (equal (%resource as) (oauth:token-set-resource ts)))
        (is (equal (as-base as) (oauth:token-set-issuer ts)))
        (is (search "#<" (princ-to-string (oauth:token-set-access ts)))
            "the stored access token is a secret, not a string")))))

;;; --- discovery -------------------------------------------------------------------------

(net-test the-metadata-is-found-where-the-specification-says
  (dolist (at '(:challenge :path :root))
    (with-as (as :prm-at at)
      (let ((m (oauth:discover (%broker) (%resource as)
                               :challenge (and (eq at :challenge) (%challenge-of as)))))
        (is (equal (as-base as) (oauth:metadata-issuer m)) "~A" at))))
  (with-as (as :issuer-path "/tenant1")
    (is (equal (format nil "~A/tenant1" (as-base as))
               (oauth:metadata-issuer (oauth:discover (%broker) (%resource as)
                                                      :challenge (%challenge-of as))))
        "an issuer with a path: the path goes after the well-known suffix")))

(net-test metadata-that-does-not-check-out-is-refused
  (with-as (as :prm-resource "https://other.example/mcp")
    (signals oauth:metadata-refused (oauth:discover (%broker) (%resource as) :challenge (%challenge-of as))))
  (with-as (as :wrong-issuer t)
    (signals oauth:metadata-refused (oauth:discover (%broker) (%resource as) :challenge (%challenge-of as))))
  (with-as (as :s256 nil)
    (signals oauth:metadata-refused (oauth:discover (%broker) (%resource as) :challenge (%challenge-of as)))))

(net-test a-url-from-a-server-must-be-https
  (with-as (as :bad-token-endpoint "http://evil.example/token")
    (signals oauth:url-refused (oauth:discover (%broker) (%resource as) :challenge (%challenge-of as))))
  (signals oauth:url-refused
    (oauth:discover (%broker) "https://127.0.0.1:1/mcp"
                    :challenge "Bearer resource_metadata=\"http://evil.example/prm\""))
  (with-as (as)
    (signals oauth:url-refused
      (oauth:discover (oauth:make-broker :store (oauth:make-memory-store) :redirect-uri "x")
                      (%resource as) :challenge (%challenge-of as)))
    "without the tests' address policy, 127.0.0.1 is refused as an internal address"))

;;; --- finishing a sign-in ---------------------------------------------------------------

(net-test a-sign-in-is-finished-only-by-its-user-once-and-from-its-issuer
  (with-as (as)
    (let* ((broker (%broker))
           (params (%approve (oauth:start-sign-in broker "u1" "docs" (%resource as)
                                                  :challenge (%challenge-of as)))))
      (signals oauth:wrong-user (oauth:finish-sign-in broker "u2" params))
      (is (= 0 (as-token-requests as)) "the code was not redeemed for the wrong user")
      (signals oauth:unknown-sign-in (oauth:finish-sign-in broker "u1" params))
      (is (= 0 (as-token-requests as)) "the refusal used up the state; the link cannot be completed")))
  (with-as (as)
    (let* ((broker (%broker))
           (params (%approve (oauth:start-sign-in broker "u1" "docs" (%resource as)
                                                  :challenge (%challenge-of as)))))
      (oauth:finish-sign-in broker "u1" params)
      (handler-case (progn (oauth:finish-sign-in broker "u1" params) (fail "state reused"))
        (oauth:unknown-sign-in (e)
          (is-true (search "another instance" (princ-to-string e)))))))
  (with-as (as :send-iss :wrong)
    (let ((broker (%broker)))
      (signals oauth:sign-in-failed (%sign-in as broker))
      (is (= 0 (as-token-requests as)) "a mismatched iss: the code was not redeemed")))
  (with-as (as :send-iss nil :iss-supported t)
    (signals oauth:sign-in-failed (%sign-in as (%broker))))
  (with-as (as :send-iss nil)
    (is (equal "u1" (%sign-in as (%broker))) "no iss, and none promised: accepted")))

(net-test the-client-id-comes-from-the-first-source-that-has-one
  (with-as (as :cimd t)
    (let ((broker (%broker :client-metadata-url "https://app.example/client.json")))
      (%sign-in as broker)
      (is (= 0 (as-registrations as)) "a client ID metadata document needs no registration")
      (is (equal "https://app.example/client.json"
                 (oauth:token-set-client-id (oauth:get-token (oauth:broker-store broker) "u1" "docs"))))))
  (with-as (as :cimd t)
    (let ((broker (%broker :client-metadata-url "https://app.example/client.json")))
      (setf (oauth::broker-pre-registered broker) (list (cons (as-base as) "by-hand")))
      (%sign-in as broker)
      (is (equal "by-hand" (oauth:token-set-client-id (oauth:get-token (oauth:broker-store broker) "u1" "docs"))))))
  (with-as (as :registration nil)
    (signals oauth:no-client (%sign-in as (%broker))))
  (with-as (as)
    (let ((broker (%broker)))
      (%sign-in as broker)
      (%sign-in as broker :principal "u2")
      (is (= 1 (as-registrations as)) "a registered client is kept, keyed by issuer"))))

(net-test the-scopes-requested-are-the-least-that-will-do
  (flet ((scope-of (url) (cdr (assoc "scope" (%query url) :test #'string=))))
    (with-as (as :scopes '("a" "b") :challenge-scope "a")
      (is (equal "a" (scope-of (oauth:start-sign-in (%broker) "u1" "docs" (%resource as)
                                                    :challenge (%challenge-of as))))))
    (with-as (as :scopes '("a" "b"))
      (is (equal "a b" (scope-of (oauth:start-sign-in (%broker) "u1" "docs" (%resource as)
                                                      :challenge (%challenge-of as)))))
      (is (equal "c" (scope-of (oauth:start-sign-in (%broker) "u1" "docs" (%resource as)
                                                    :challenge (%challenge-of as) :scopes '("c"))))))
    (with-as (as :scopes '("a") :as-scopes '("a" "offline_access"))
      (is (equal "a offline_access"
                 (scope-of (oauth:start-sign-in (%broker) "u1" "docs" (%resource as)
                                                :challenge (%challenge-of as))))))
    (with-as (as :challenge-scope "a")
      (let ((broker (%broker)))
        (%sign-in as broker)
        (setf (as-challenge-scope as) "b")
        (is (equal "a b" (scope-of (oauth:start-sign-in broker "u1" "docs" (%resource as)
                                                        :challenge (%challenge-of as))))
            "a step-up keeps the scopes granted before")))))

;;; --- tokens in use ---------------------------------------------------------------------

(net-test an-expired-token-is-refreshed-and-a-revoked-one-is-deleted
  (with-as (as :expires-in 0 :rotate t)
    (let* ((broker (%broker))
           (store (oauth:broker-store broker)))
      (%sign-in as broker)
      (let ((first-refresh (secret:reveal (oauth:token-set-refresh (oauth:get-token store "u1" "docs")))))
        (is (stringp (oauth:access-token broker "u1" "docs" (%resource as))))
        (is (= 1 (as-refresh-requests as)))
        (is (not (equal first-refresh
                        (secret:reveal (oauth:token-set-refresh (oauth:get-token store "u1" "docs")))))
            "the rotated refresh token was kept"))
      (push (secret:reveal (oauth:token-set-refresh (oauth:get-token store "u1" "docs"))) (as-revoked as))
      (is (null (oauth:access-token broker "u1" "docs" (%resource as))))
      (is (null (oauth:get-token store "u1" "docs")) "invalid_grant deletes the tokens"))))

(net-test two-refreshes-at-once-use-the-refresh-token-once
  "With rotation, a second refresh with the same refresh token is refused. Serialised, the
second caller finds the first one's new token and does not refresh at all."
  (with-as (as :expires-in 0 :rotate t)
    (let ((broker (%broker)))
      (%sign-in as broker)
      ;; The token from the sign-in has expired; the one a refresh issues will not have.
      (setf (as-expires-in as) 3600)
      (let* ((rejected (secret:reveal (oauth:token-set-access (oauth:get-token (oauth:broker-store broker) "u1" "docs"))))
             (threads (loop repeat 2
                            collect (sb-thread:make-thread
                                     (lambda () (oauth:refresh broker "u1" "docs" (%resource as)
                                                               :rejected rejected))))))
        (let ((tokens (aion/test-threads:join-all threads :timeout 20)))
          (is (every #'stringp tokens) "both callers got a token: ~S" tokens)
          (is (= 1 (as-refresh-requests as)))
          (is-true (oauth:get-token (oauth:broker-store broker) "u1" "docs")))))))

(net-test a-token-is-only-for-the-resource-it-was-issued-for
  (with-as (as)
    (let ((broker (%broker)))
      (%sign-in as broker)
      (is (stringp (oauth:access-token broker "u1" "docs" (%resource as))))
      (is (null (oauth:access-token broker "u1" "docs" (format nil "~A/other" (as-base as))))
          "the same connection name with another URL gets no token"))))

(net-test disconnecting-revokes-at-the-server-and-deletes
  (with-as (as)
    (let ((broker (%broker)))
      (%sign-in as broker)
      (let ((refresh (secret:reveal (oauth:token-set-refresh (oauth:get-token (oauth:broker-store broker) "u1" "docs")))))
        (oauth:disconnect broker "u1" "docs")
        (is (member refresh (as-revoked as) :test #'equal))
        (is (null (oauth:get-token (oauth:broker-store broker) "u1" "docs")))))))

(net-test a-token-endpoint-that-redirects-gets-no-code-forwarded
  (let ((hits 0))
    (th:with-server (target (lambda (r s) (declare (ignore r)) (incf hits)
                              (th:write-response s 200 '() "{}")))
      (with-as (as)
        (setf (as-token-redirect-to as) (th:server-url target "/token"))
        (signals oauth:oauth-error (%sign-in as (%broker)))
        (is (= 0 hits))))))

;;; --- pieces ----------------------------------------------------------------------------

(test challenges-and-canonical-uris-are-read-as-specified
  (is (equal '(("error" . "insufficient_scope") ("scope" . "files:write a")
               ("resource_metadata" . "https://x.example/prm"))
             (oauth:parse-challenge "Bearer error=\"insufficient_scope\", scope=\"files:write a\", resource_metadata=\"https://x.example/prm\"")))
  (is (equal '(("realm" . "x")) (oauth:parse-challenge "Bearer realm=x")))
  (is (null (oauth:parse-challenge "Basic realm=\"x\"")))
  (is (equal "https://mcp.example.com" (oauth:canonical-resource "HTTPS://MCP.Example.com/")))
  (is (equal "https://mcp.example.com/mcp" (oauth:canonical-resource "https://mcp.example.com:443/mcp#f")))
  (is (equal "https://mcp.example.com:8443/mcp" (oauth:canonical-resource "https://mcp.example.com:8443/mcp/"))))

(net-test a-token-is-withheld-when-the-resource-names-another-issuer
  "The protected resource's metadata is read again when its cache expires. When it no longer
names the authorization server that issued the token, the token is not sent."
  (with-as (as)
    (let ((cached (%broker))
          (fresh (%broker :metadata-lifetime 0)))
      (%sign-in as cached)
      (%sign-in as fresh)
      (is (stringp (oauth:access-token cached "u1" "docs" (%resource as))))
      (setf (as-other-issuer as) "https://other.example")
      (is (null (oauth:access-token fresh "u1" "docs" (%resource as)))
          "the metadata names another issuer")
      (is (stringp (oauth:access-token cached "u1" "docs" (%resource as)))
          "within its lifetime the cached metadata is used, with no request")
      (oauth:refresh cached "u1" "docs" (%resource as) :rejected "refused")
      (is (null (oauth:access-token cached "u1" "docs" (%resource as)))
          "a refused token makes the metadata be read again"))))

(test on-windows-sign-in-refuses-instead-of-connecting-unpinned
  "#295: a URL from a server is fetched only over a pinned connection, which Windows does not
offer, so discovery signals PINNED-CONNECT-UNSUPPORTED there and nothing is fetched."
  #-os-windows (skip "the pinned connection is available here")
  #+os-windows
  ;; A resolver that answers with a public address: FETCH-PUBLIC resolves and checks the host
  ;; before it tries to pin, and a made-up host would be refused as unresolvable first.
  (signals http:pinned-connect-unsupported
    (oauth:discover (%broker :resolve (lambda (host) (declare (ignore host))
                                        (list (http:parse-address "93.184.216.34"))))
                    "https://mcp.example/mcp"
                    :challenge "Bearer resource_metadata=\"https://mcp.example/prm\"")))
