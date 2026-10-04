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
  (other-issuer nil) (slow-prm nil) (slow-prm-requests 0) (prm-status nil) (token-type "Bearer") (refresh-error nil)
  (revoke-status 200) (refresh-clients (make-hash-table :test #'equal))
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

(defun substitute-string (string old new)
  (let ((at (search old string)))
    (if at (concatenate 'string (subseq string 0 at) new (subseq string (+ at (length old)))) string)))

(defun %issuer (as) (format nil "~A~A" (as-base as) (as-issuer-path as)))
(defun %resource (as) (format nil "~A/mcp" (as-base as)))

(defun %b64url-sha256 (s)
  (string-right-trim "=" (substitute #\_ #\/ (substitute #\- #\+ (cl-base64:usb8-array-to-base64-string
                                                                  (ironclad:digest-sequence :sha256 (sb-ext:string-to-octets s :external-format :ascii)))))))

(defun %new-token (as kind resource &optional (table (if (eq kind :access) (as-access as) (as-refresh as))))
  (let ((token (format nil "~(~A~)-~D" kind (random 1000000000))))
    (setf (gethash token table) resource)
    token))

(defun %issue (as stream resource scope client)
  (let ((rt (%new-token as :refresh resource)))
    (setf (gethash rt (as-refresh-clients as)) client)
    (%json stream 200 (%obj "access_token" (%new-token as :access resource)
                            "token_type" (as-token-type as)
                            "expires_in" (as-expires-in as)
                            "refresh_token" rt
                            "scope" (or scope "")))))

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
          ((and (as-slow-prm as) (string= bare "/prm"))
           ;; A body that arrives one byte every 0.3 s: no single read waits long enough for a
           ;; read timeout, but the whole reply takes 6 s.
           (incf (as-slow-prm-requests as))
           (th:write-head stream 200 '(("Content-Type" . "application/json") ("Content-Length" . "20")))
           (dotimes (i 20) (sleep 0.3) (write-byte 32 stream) (finish-output stream)))
          ((and (as-prm-status as) (string= bare "/prm"))
           (th:write-response stream (as-prm-status as) '() "not now"))
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
           (%json stream 201 (%obj "client_id" (format nil "registered-client-~D" (as-registrations as)))))
          ((string= bare "/authorize")
           (let* ((q (%query path))
                  (code (format nil "code-~D" (random 1000000000))))
             ;; A code is issued only for PKCE with S256, as a real server that requires it does.
             (when (equal "S256" (cdr (assoc "code_challenge_method" q :test #'string=)))
               (setf (gethash code (as-codes as))
                     (list :challenge (cdr (assoc "code_challenge" q :test #'string=))
                           :resource (cdr (assoc "resource" q :test #'string=))
                           :client (cdr (assoc "client_id" q :test #'string=))
                           :redirect (cdr (assoc "redirect_uri" q :test #'string=))
                           :scope (cdr (assoc "scope" q :test #'string=)))))
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
                           (equal (getf entry :resource) (cdr (assoc "resource" form :test #'string=)))
                           (equal (getf entry :client) (cdr (assoc "client_id" form :test #'string=)))
                           (equal (getf entry :redirect) (cdr (assoc "redirect_uri" form :test #'string=))))
                      (%issue as stream (getf entry :resource) (getf entry :scope)
                              (getf entry :client))
                      (%json stream 400 (%obj "error" "invalid_grant")))))
               ((equal grant "refresh_token")
                (incf (as-refresh-requests as))
                (let* ((rt (cdr (assoc "refresh_token" form :test #'string=)))
                       (resource (gethash rt (as-refresh as))))
                  (sleep 0.05)   ; long enough for a second refresh to overlap a first
                  (cond ((as-refresh-error as)
                         (%json stream 400 (%obj "error" (as-refresh-error as))))
                        ((or (null resource) (member rt (as-revoked as) :test #'string=)
                             (not (equal resource (cdr (assoc "resource" form :test #'string=))))
                             (not (equal (gethash rt (as-refresh-clients as))
                                         (cdr (assoc "client_id" form :test #'string=)))))
                         (%json stream 400 (%obj "error" "invalid_grant")))
                        (t
                         (when (as-rotate as) (remhash rt (as-refresh as)))
                         (%json stream 200
                                (append-refresh as resource (gethash rt (as-refresh-clients as))))))))
               (t (%json stream 400 (%obj "error" "unsupported_grant_type"))))))
          ((string= bare "/revoke")
           (when (= 200 (as-revoke-status as))
             (push (cdr (assoc "token" (%form request) :test #'string=)) (as-revoked as)))
           (th:write-response stream (as-revoke-status as) '() ""))
          (t (th:write-response stream 404 '() "")))))))

(defun append-refresh (as resource client)
  (%obj "access_token" (%new-token as :access resource)
        "token_type" (as-token-type as) "expires_in" (as-expires-in as)
        "refresh_token" (if (as-rotate as)
                            (let ((rt (%new-token as :refresh resource)))
                              (setf (gethash rt (as-refresh-clients as)) client)
                              rt)
                            'null)))

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

;;; --- the review of #539 ----------------------------------------------------------------

;;; A store written as an app would write one: in its own package, through exported symbols
;;; only, keeping every record as strings, as a database row would.

(cl:defpackage #:aion/oauth/tests/string-store
  (:use #:cl)
  (:local-nicknames (#:oauth #:aion/oauth) (#:secret #:aion/secret))
  (:export #:string-store))

(cl:in-package #:aion/oauth/tests/string-store)

(defclass string-store (oauth:store)
  ((rows :initform (make-hash-table :test #'equal) :reader rows))
  (:documentation "Keeps each record as an alist of strings, rebuilt on every read."))

(defun %s (x) (cond ((null x) "") ((stringp x) x) (t (princ-to-string x))))
(defun %n (s) (if (string= s "") nil (parse-integer s)))
(defun %o (s) (if (string= s "") nil s))
(defun %get (row key) (cdr (assoc key row :test #'string=)))

(defun %token-row (ts)
  (list (cons "access" (secret:reveal (oauth:token-set-access ts)))
        (cons "refresh" (if (oauth:token-set-refresh ts) (secret:reveal (oauth:token-set-refresh ts)) ""))
        (cons "expires-at" (%s (oauth:token-set-expires-at ts)))
        (cons "scope" (%s (oauth:token-set-scope ts)))
        (cons "resource" (%s (oauth:token-set-resource ts)))
        (cons "issuer" (%s (oauth:token-set-issuer ts)))
        (cons "client-id" (%s (oauth:token-set-client-id ts)))
        (cons "token-endpoint" (%s (oauth:token-set-token-endpoint ts)))
        (cons "revocation-endpoint" (%s (oauth:token-set-revocation-endpoint ts)))
        (cons "metadata-url" (%s (oauth:token-set-metadata-url ts)))))

(defun %token-from (row)
  (oauth:make-token-set
   :access (secret:make-secret (%get row "access"))
   :refresh (and (%o (%get row "refresh")) (secret:make-secret (%get row "refresh")))
   :expires-at (%n (%get row "expires-at"))
   :scope (%o (%get row "scope")) :resource (%o (%get row "resource"))
   :issuer (%o (%get row "issuer")) :client-id (%o (%get row "client-id"))
   :token-endpoint (%o (%get row "token-endpoint"))
   :revocation-endpoint (%o (%get row "revocation-endpoint"))
   :metadata-url (%o (%get row "metadata-url"))))

(defun %pending-row (p)
  (list (cons "principal" (%s (oauth:pending-principal p)))
        (cons "connection" (%s (oauth:pending-connection p)))
        (cons "resource" (%s (oauth:pending-resource p)))
        (cons "issuer" (%s (oauth:pending-issuer p)))
        (cons "client-id" (%s (oauth:pending-client-id p)))
        (cons "verifier" (secret:reveal (oauth:pending-verifier p)))
        (cons "token-endpoint" (%s (oauth:pending-token-endpoint p)))
        (cons "revocation-endpoint" (%s (oauth:pending-revocation-endpoint p)))
        (cons "iss-required" (if (oauth:pending-iss-required p) "t" ""))
        (cons "scope" (%s (oauth:pending-scope p)))
        (cons "expires-at" (%s (oauth:pending-expires-at p)))
        (cons "metadata-url" (%s (oauth:pending-metadata-url p)))))

(defun %pending-from (row)
  (oauth:make-pending
   :principal (%get row "principal") :connection (%get row "connection")
   :resource (%o (%get row "resource")) :issuer (%o (%get row "issuer"))
   :client-id (%o (%get row "client-id"))
   :verifier (secret:make-secret (%get row "verifier"))
   :token-endpoint (%o (%get row "token-endpoint"))
   :revocation-endpoint (%o (%get row "revocation-endpoint"))
   :iss-required (string= "t" (%get row "iss-required"))
   :scope (%o (%get row "scope")) :expires-at (%n (%get row "expires-at"))
   :metadata-url (%o (%get row "metadata-url"))))

(defmethod oauth:get-token ((s string-store) principal connection)
  (let ((row (gethash (list :token principal connection) (rows s)))) (and row (%token-from row))))
(defmethod oauth:put-token ((s string-store) principal connection token-set)
  (setf (gethash (list :token principal connection) (rows s)) (%token-row token-set)))
(defmethod oauth:delete-token ((s string-store) principal connection)
  (remhash (list :token principal connection) (rows s)))
(defmethod oauth:get-client ((s string-store) issuer redirect-uri)
  (gethash (list :client issuer redirect-uri) (rows s)))
(defmethod oauth:put-client ((s string-store) issuer redirect-uri client-id)
  (setf (gethash (list :client issuer redirect-uri) (rows s)) client-id))
(defmethod oauth:delete-client ((s string-store) issuer redirect-uri client-id)
  (when (equal client-id (gethash (list :client issuer redirect-uri) (rows s)))
    (remhash (list :client issuer redirect-uri) (rows s))))
(defmethod oauth:put-pending ((s string-store) state pending)
  (setf (gethash (list :pending state) (rows s)) (%pending-row pending)))
(defmethod oauth:take-pending ((s string-store) state)
  (let ((row (gethash (list :pending state) (rows s))))
    (remhash (list :pending state) (rows s))
    (and row (%pending-from row))))

(cl:in-package #:aion/oauth/tests)

(net-test a-store-of-strings-written-with-exported-symbols-works-throughout
  "Sign-in, the issuer check, a refresh and a disconnect, through a store that keeps every
record as strings and uses only aion/oauth's exported symbols."
  (with-as (as :expires-in 0 :rotate t)
    (let ((broker (%broker :store (make-instance 'aion/oauth/tests/string-store:string-store))))
      (is (equal "u1" (%sign-in as broker)))
      (setf (as-expires-in as) 3600)
      (let ((token (oauth:access-token broker "u1" "docs" (%resource as))))
        (is (stringp token))
        (is (= 1 (as-refresh-requests as)) "the expired token was refreshed")
        (is (= 200 (%call-resource as token))))
      (oauth:disconnect broker "u1" "docs")
      (is (null (oauth:get-token (oauth:broker-store broker) "u1" "docs")))
      (is (= 1 (length (as-revoked as)))))))

(net-test an-unreadable-metadata-answer-is-not-cached-as-an-answer
  "A 404 or a 503 from the protected resource's metadata fails the check for that call; once the
metadata answers again, the token is returned with no new sign-in."
  (dolist (status '(404 503))
    (with-as (as)
      (let ((broker (%broker :metadata-grace 0)))
        (%sign-in as broker)
        (setf (as-prm-status as) status)
        (signals oauth:oauth-error (oauth:access-token broker "u1" "docs" (%resource as)))
        (setf (as-prm-status as) nil)
        (is (stringp (oauth:access-token broker "u1" "docs" (%resource as))) "status ~D" status)))))

(net-test an-expired-answer-is-not-renewed-by-a-failed-fetch
  "Once the cached answer has expired and its grace has passed, a failed fetch withholds the
token instead of extending the old answer."
  (with-as (as)
    (let ((broker (%broker :metadata-lifetime 1 :metadata-grace 0)))
      (%sign-in as broker)
      (is (stringp (oauth:access-token broker "u1" "docs" (%resource as))))
      (sleep 2)
      (setf (as-prm-status as) 503)
      (signals oauth:oauth-error (oauth:access-token broker "u1" "docs" (%resource as)))
      (signals oauth:oauth-error (oauth:access-token broker "u1" "docs" (%resource as))))))

(net-test a-sign-in-needs-a-principal-at-both-ends
  (with-as (as)
    (let ((broker (%broker)))
      (signals oauth:wrong-user
        (oauth:start-sign-in broker nil "docs" (%resource as) :challenge (%challenge-of as)))
      (let ((params (%approve (oauth:start-sign-in broker "u1" "docs" (%resource as)
                                                   :challenge (%challenge-of as)))))
        (signals oauth:wrong-user (oauth:finish-sign-in broker nil params))
        (signals oauth:unknown-sign-in (oauth:finish-sign-in broker "u1" params))
        (is (= 0 (as-token-requests as))))
      ;; A sign-in recorded for no principal, as a store could hold, is not finished by a return
      ;; with no session principal either.
      (oauth:put-pending (oauth:broker-store broker) "no-one"
                         (oauth:make-pending :principal nil :connection "docs"
                                             :expires-at (+ (get-universal-time) 600)))
      (signals oauth:wrong-user
        (oauth:finish-sign-in broker nil (list (cons "state" "no-one") (cons "code" "c"))))
      (is (= 0 (as-token-requests as))))))

(net-test tokens-that-are-not-bearer-tokens-are-refused
  (with-as (as)
    (setf (as-token-type as) "DPoP")
    (signals oauth:sign-in-failed (%sign-in as (%broker)))))

(net-test a-resource-on-plain-http-gets-no-token
  (signals oauth:url-refused
    (oauth:discover (%broker) "http://192.0.2.1/mcp"
                    :challenge "Bearer resource_metadata=\"https://192.0.2.1/prm\""))
  (signals oauth:url-refused (oauth:access-token (%broker) "u1" "docs" "http://192.0.2.1/mcp")))

(net-test a-refresh-refused-for-the-client-deletes-the-tokens
  "invalid_client and unauthorized_client delete the tokens. After invalid_client the registered
client is forgotten too, so the next sign-in registers a new one."
  (dolist (code '("invalid_client" "unauthorized_client"))
    (with-as (as :expires-in 0)
      (let ((broker (%broker)))
        (%sign-in as broker)
        (setf (as-refresh-error as) code)
        (is (null (oauth:access-token broker "u1" "docs" (%resource as))) "~A" code)
        (is (null (oauth:get-token (oauth:broker-store broker) "u1" "docs")) "~A" code)
        (setf (as-refresh-error as) nil)
        (%sign-in as broker)
        (is (= (if (equal code "invalid_client") 2 1) (as-registrations as))
            "~A: the client is registered again only after invalid_client" code))))
  ;; A second user's old tokens, issued to the first client, do not make the broker forget a
  ;; client registered after it.
  (with-as (as :expires-in 0)
    (let ((broker (%broker)))
      (%sign-in as broker :principal "u1")
      (%sign-in as broker :principal "u2")
      (setf (as-refresh-error as) "invalid_client")
      (oauth:access-token broker "u1" "docs" (%resource as))
      (setf (as-refresh-error as) nil)
      (%sign-in as broker :principal "u3")
      (is (= 2 (as-registrations as)) "u3's sign-in registered a new client")
      (setf (as-refresh-error as) "invalid_client")
      (oauth:access-token broker "u2" "docs" (%resource as))
      (setf (as-refresh-error as) nil)
      (%sign-in as broker :principal "u4")
      (is (= 2 (as-registrations as))
          "u2's old tokens did not make the broker forget the client registered for u3"))))

(net-test a-token-type-is-compared-without-regard-to-case
  (with-as (as)
    (setf (as-token-type as) "bearer")
    (is (equal "u1" (%sign-in as (%broker))))))

(test memory-store-drops-expired-sign-ins-when-it-stores-a-new-one
  (let ((store (oauth:make-memory-store)))
    (oauth:put-pending store "old" (oauth:make-pending :principal "u1" :connection "docs"
                                                       :expires-at (- (get-universal-time) 10)))
    (oauth:put-pending store "new" (oauth:make-pending :principal "u1" :connection "docs"
                                                       :expires-at (+ (get-universal-time) 600)))
    (is (null (oauth:take-pending store "old")))
    (is-true (oauth:take-pending store "new"))))

(net-test an-expired-answer-is-used-for-its-grace-and-not-renewed
  "With a lifetime of 1 s and a grace of 4 s, a failed fetch inside the grace still gives the
token, and does not move the answer's expiry: 5 s after the fill, past the first expiry and its
grace, the token is withheld. A failed fetch that renewed the answer would still give it then."
  (with-as (as)
    (let ((broker (%broker :metadata-lifetime 1 :metadata-grace 4)))
      (%sign-in as broker)
      (is (stringp (oauth:access-token broker "u1" "docs" (%resource as))))
      (sleep 2)
      (setf (as-prm-status as) 503)
      (is (stringp (oauth:access-token broker "u1" "docs" (%resource as)))
          "inside the grace, the expired answer is used")
      (sleep 3)
      (signals oauth:oauth-error (oauth:access-token broker "u1" "docs" (%resource as))))))

(net-test a-sign-in-drops-the-cached-metadata
  "A sign-in drops the answer cached for its metadata URL and resource. With the metadata failing
after a second sign-in, the next call fails instead of using the answer cached before that
sign-in."
  (with-as (as)
    (let ((broker (%broker :metadata-grace 0)))
      (%sign-in as broker)
      (is (stringp (oauth:access-token broker "u1" "docs" (%resource as))))
      (%sign-in as broker)
      (setf (as-prm-status as) 503)
      (signals oauth:oauth-error (oauth:access-token broker "u1" "docs" (%resource as))))))

(net-test the-issuer-cache-answers-for-the-token-sets-resource
  "Two token sets share a metadata URL but name different resources: R, which the metadata
names, and S, which it does not. The answer read for one is not used for the other, whichever
is checked first."
  (dolist (r-first '(t nil))
    (with-as (as)
      (let* ((broker (%broker))
             (store (oauth:broker-store broker))
             (s (format nil "~A/other" (as-base as))))
        (%sign-in as broker)
        (let ((ts (copy-structure (oauth:get-token store "u1" "docs"))))
          (setf (oauth:token-set-resource ts) (oauth:canonical-resource s))
          (oauth:put-token store "u1" "docs2" ts))
        (flet ((for-r () (oauth:access-token broker "u1" "docs" (%resource as)))
               (for-s () (oauth:access-token broker "u1" "docs2" s)))
          (if r-first
              (progn (is (stringp (for-r)))
                     (is (null (for-s)) "the answer cached for R is not used for S"))
              (progn (is (null (for-s)))
                     (is (stringp (for-r)) "the answer cached for S is not used for R"))))))))

(net-test an-expired-sign-in-cannot-be-finished
  (with-as (as)
    (let ((broker (%broker :sign-in-lifetime -1)))
      (signals oauth:unknown-sign-in (%sign-in as broker))
      (is (= 0 (as-token-requests as))))))

(net-test a-client-metadata-url-that-is-not-https-is-not-used
  (with-as (as :cimd t)
    (let ((broker (%broker :client-metadata-url "http://app.example/client.json")))
      (%sign-in as broker)
      (is (= 1 (as-registrations as)) "registered dynamically instead"))))

(net-test a-refused-revocation-still-deletes-the-tokens
  (with-as (as)
    (let ((broker (%broker)))
      (%sign-in as broker)
      (setf (as-revoke-status as) 500)
      (oauth:disconnect broker "u1" "docs")
      (is (null (oauth:get-token (oauth:broker-store broker) "u1" "docs"))))))


;;; --- Copilot's review of train 24 (#544) ------------------------------------------------

(net-test a-fetch-overtaken-by-a-forget-does-not-store-its-old-answer
  "A fetch of the metadata starts, and is held after it has read the old issuer list. Meanwhile a
refused token forgets the entry, and a new fetch caches the list naming another issuer. The first
fetch, released, must not store its old list over the new one."
  (with-as (as)
    (let* ((broker (%broker :metadata-grace 0))
           (arrived (sb-thread:make-semaphore)) (release (sb-thread:make-semaphore))
           (armed (list t)))
      (%sign-in as broker)
      (setf aion/oauth::*%after-issuer-fetch*
            (lambda () (when (sb-ext:compare-and-swap (car armed) t nil)
                         (sb-thread:signal-semaphore arrived)
                         (sb-thread:wait-on-semaphore release :timeout 10))))
      (unwind-protect
           (let ((first (sb-thread:make-thread
                         (lambda () (oauth:access-token broker "u1" "docs" (%resource as))))))
             (is-true (sb-thread:wait-on-semaphore arrived :timeout 10))
             (setf (as-other-issuer as) "https://other.example")
             (oauth:refresh broker "u1" "docs" (%resource as) :rejected "refused")
             (is (null (oauth:access-token broker "u1" "docs" (%resource as)))
                 "the new list names another issuer")
             (sb-thread:signal-semaphore release)
             (aion/test-threads:join first)
             (is (null (oauth:access-token broker "u1" "docs" (%resource as)))
                 "the overtaken fetch did not store the old list"))
        (setf aion/oauth::*%after-issuer-fetch* nil)))))

(net-test a-request-that-streams-past-its-deadline-is-given-up
  "The metadata arrives one byte at a time, so no read times out, but the whole reply takes six
seconds. With a timeout of 1 s, the request is given up within about two."
  (with-as (as)
    (setf (as-slow-prm as) t)
    (let ((started (get-internal-real-time)))
      (signals oauth:oauth-error
        (oauth:discover (%broker :timeout 1) (%resource as) :challenge (%challenge-of as)))
      (is (< (/ (- (get-internal-real-time) started) internal-time-units-per-second) 4)))))

(net-test a-host-with-too-many-given-up-requests-is-refused-without-sending
  "A request given up at its deadline keeps running. Once *MAX-ABANDONED-REQUESTS* of them are
running for one host, the next request to that host is refused at once and not sent, and a
request to another host still runs."
  (let ((oauth::*max-abandoned-requests* 1)
        (broker (%broker :timeout 1
                         :resolve (lambda (host) (declare (ignore host)) (http:resolve-host "127.0.0.1")))))
    (with-as (slow)
      (setf (as-slow-prm slow) t)
      (with-as (fast)
        ;; The second server is reached as localhost, which is another host to the broker.
        ;; The slow server holds its lock while it streams, so its challenge is read beforehand.
        (let ((challenge (%challenge-of fast))
              (slow-challenge (%challenge-of slow)))
          (setf (as-base fast) (substitute-string (as-base fast) "127.0.0.1" "localhost"))
          (setf challenge (substitute-string challenge "127.0.0.1" "localhost"))
          (signals oauth:oauth-error
            (oauth:discover broker (%resource slow) :challenge slow-challenge))
          (is (= 1 (as-slow-prm-requests slow)))
          (let ((started (get-internal-real-time)))
            (handler-case (progn (oauth:discover broker (%resource slow) :challenge slow-challenge)
                                 (fail "a request was made"))
              (oauth:oauth-error (e)
                (is-true (search "still running" (princ-to-string e)))))
            (is (< (/ (- (get-internal-real-time) started) internal-time-units-per-second) 1/2)
                "refused at once"))
          (is (= 1 (as-slow-prm-requests slow)) "the refused request was not sent")
          (is-true (oauth:discover broker (%resource fast) :challenge challenge)
                   "another host is not affected"))))))
