;;;; oauth-tests.lisp --- hyperion/oauth's routes, against aion/oauth's test authorization server

(cl:defpackage #:hyperion/oauth/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:hoauth #:hyperion/oauth)
                    (#:oauth #:aion/oauth)
                    (#:at #:aion/oauth/tests)
                    (#:jzon #:com.inuoe.jzon))
  (:export #:run-tests))

(cl:in-package #:hyperion/oauth/tests)

(def-suite hyperion-oauth
  :description "hyperion/oauth: the sign-in return route, and the page that forwards to a sign-in.")
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

;;; FORWARDING-RESPONSE (#1181): the answer to a form POST that starts a sign-in, when the app's
;;; Content-Security-Policy has form-action 'self' and a 303 to the authorization server would
;;; be blocked by the browser.

(defun %header (response name)
  (getf (second response) name))

(defun %body (response)
  (first (third response)))

(test a-forwarding-response-is-a-page-that-refreshes-to-the-url-and-links-to-it
  "A 200 HTML page with a meta refresh to the URL and a link to it, sent with Cache-Control
no-store and Referrer-Policy no-referrer. Control: the URL here has no character that needs
escaping, so it must appear in the page exactly as given, which shows the searches below can
find a URL in the page."
  (let* ((url "https://as.example/authorize?client_id=c1")
         (response (hoauth:forwarding-response url))
         (body (%body response)))
    (is (= 200 (first response)))
    (is (equal "text/html; charset=utf-8" (%header response :content-type)))
    (is (equal "no-store" (%header response :cache-control)))
    (is (equal "no-referrer" (%header response :referrer-policy)))
    (is-true (search (format nil "<meta http-equiv=\"refresh\" content=\"0; url=~A\">" url) body)
             "the refresh names the URL: ~A" body)
    (is-true (search (format nil "<a href=\"~A\">Continue to sign in</a>" url) body)
             "the link names the URL: ~A" body)))

(test a-forwarding-response-escapes-the-url-and-the-link-text
  "An authorization URL's query has &, and a URL or a link text with \" < > or ' must not end
the attribute or add markup. Each is written as a character reference. Control: the same URL
is present in the page in its escaped form, so the absence of the raw form is not because the
URL is missing altogether."
  (let* ((url (concatenate 'string "https://as.example/authorize?state=s1&code_challenge=x"
                           "\"><script>alert(1)</script>'"))
         (escaped (concatenate 'string "https://as.example/authorize?state=s1&amp;code_challenge=x"
                               "&quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt;&#39;"))
         (body (%body (hoauth:forwarding-response url :link-text "<b>Go</b> & \"sign in\""))))
    (is (null (search "<script>" body)) "raw markup from the URL in: ~A" body)
    (is (null (search "state=s1&code_challenge" body)) "an unescaped & in: ~A" body)
    (is (null (search "<b>" body)) "raw markup from the link text in: ~A" body)
    (is-true (search (format nil "content=\"0; url=~A\"" escaped) body)
             "control: the escaped URL is in the refresh: ~A" body)
    (is-true (search (format nil "<a href=\"~A\">~A</a>"
                             escaped "&lt;b&gt;Go&lt;/b&gt; &amp; &quot;sign in&quot;")
                     body)
             "control: the escaped URL and text are in the link: ~A" body)))

(test a-forwarding-response-refuses-a-url-that-is-not-http
  "A javascript: or data: URL, or one with no scheme, is refused, so it cannot be written into
the link. Control: http and https URLs, in any letter case, are accepted."
  (dolist (url '("javascript:alert(1)" "JavaScript:alert(1)" "data:text/html,x"
                 "/relative/path" "https:no-slashes" ""))
    (signals error (hoauth:forwarding-response url)))
  (dolist (url '("https://as.example/a" "HTTPS://as.example/a" "http://127.0.0.1:8080/a"))
    (is (= 200 (first (hoauth:forwarding-response url))) "~A" url)))

(test the-security-headers-wrapper-keeps-the-forwarding-response-s-own-headers
  "Through HYPERION/SECURITY-HEADERS:WRAP-SECURITY-HEADERS, the page keeps Referrer-Policy
no-referrer, and still gets the wrapper's other headers. Control: a plain response through the
same wrapper gets the wrapper's default Referrer-Policy, so the wrapper did run and could have
replaced the header."
  (let ((forwarded (funcall (hyperion/security-headers:wrap-security-headers
                             (lambda (env)
                               (declare (ignore env))
                               (hoauth:forwarding-response "https://as.example/authorize")))
                            '()))
        (plain (funcall (hyperion/security-headers:wrap-security-headers
                         (lambda (env)
                           (declare (ignore env))
                           (list 303 '(:location "https://as.example/authorize") '(""))))
                        '())))
    (is (equal "no-referrer" (%header forwarded :referrer-policy)))
    (is (equal "no-store" (%header forwarded :cache-control)))
    (is-true (%header forwarded :content-security-policy))
    (is (equal "strict-origin-when-cross-origin" (%header plain :referrer-policy))
        "control: ~S" (second plain))))
