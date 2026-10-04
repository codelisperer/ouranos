;;;; oauth-tests.lisp --- hyperion/oauth's routes, against aion/oauth's test authorization server

(cl:defpackage #:hyperion/oauth/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:hoauth #:hyperion/oauth)
                    (#:oauth #:aion/oauth)
                    (#:at #:aion/oauth/tests)
                    (#:jzon #:com.inuoe.jzon))
  (:export #:run-tests))

(cl:in-package #:hyperion/oauth/tests)

(def-suite hyperion-oauth :description "hyperion/oauth: the sign-in return route.")
(in-suite hyperion-oauth)

(defun run-tests ()
  (let ((results (run 'hyperion-oauth)))
    (explain! results)
    (unless (results-status results)
      (error "hyperion/oauth tests failed: ~{~A~^, ~}"
             (remove-duplicates
              (mapcar (lambda (r) (fiveam::name (fiveam::test-case r)))
                      (remove-if-not #'fiveam::test-failure-p results)))))))

(defun %env-for (url session-principal)
  "A Clack env for the browser's return to URL, in a session whose principal is
SESSION-PRINCIPAL."
  (list :query-string (subseq url (1+ (position #\? url))) :session session-principal))

(defun %return-url (as broker principal)
  "Start a sign-in for PRINCIPAL and follow the authorization endpoint's redirect."
  (let ((params (at::%approve (oauth:start-sign-in broker principal "docs" (at::%resource as)
                                                   :challenge (at::%challenge-of as)))))
    (format nil "http://127.0.0.1:1/callback?~A" (quri:url-encode-params params))))

(test the-return-route-finishes-a-sign-in-for-the-session-that-started-it
  #+os-windows (skip "aion/oauth needs a pinned connection, which Windows does not offer (#295)")
  #-os-windows
  (at::with-as (as)
    (let* ((broker (at::%broker))
           (handler (hoauth:sign-in-return-handler
                     broker :principal-of (lambda (env) (getf env :session)))))
      (let ((response (funcall handler (%env-for (%return-url as broker "u1") "u1"))))
        (is (= 200 (first response)))
        (is-true (oauth:get-token (oauth:broker-store broker) "u1" "docs")))
      (let ((response (funcall handler (%env-for (%return-url as broker "u2") "someone-else"))))
        (is (= 403 (first response)))
        (is (null (oauth:get-token (oauth:broker-store broker) "u2" "docs"))))
      (let ((response (funcall handler (%env-for "http://127.0.0.1:1/callback?state=nope&code=x" "u1"))))
        (is (= 400 (first response)))
        (is-true (search "another instance" (first (third response))))))))

(test the-client-metadata-document-names-itself
  (let* ((broker (oauth:make-broker :store (oauth:make-memory-store)
                                    :redirect-uri "https://app.example/oauth/return"
                                    :client-metadata-url "https://app.example/oauth/client.json"
                                    :client-name "Example"))
         (doc (jzon:parse (first (third (funcall (hoauth:client-metadata-handler broker) '()))))))
    (is (equal "https://app.example/oauth/client.json" (gethash "client_id" doc)))
    (is (equalp #("https://app.example/oauth/return") (gethash "redirect_uris" doc)))
    (is (equal "none" (gethash "token_endpoint_auth_method" doc)))))
