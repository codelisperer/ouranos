;;;; oauth.lisp --- hyperion/oauth: the routes an app mounts for aion/oauth sign-ins (#527)

(cl:defpackage #:hyperion/oauth
  (:use #:cl)
  (:local-nicknames (#:oauth #:aion/oauth)
                    (#:http #:hyperion/http))
  (:documentation
   "The two routes an app mounts for aion/oauth: the page the browser comes back to after a
    sign-in, and the app's client ID metadata document. Each is a Clack handler, a function of
    the request's env. Also FORWARDING-RESPONSE, the response an app gives to the request that
    starts a sign-in when that request is a form POST. aion/oauth itself needs no web server;
    this is the thin layer between.")
  (:export #:sign-in-return-handler #:client-metadata-handler #:forwarding-response))

(cl:in-package #:hyperion/oauth)

(defun %text (status text)
  (list status '(:content-type "text/plain; charset=utf-8") (list text)))

(defun sign-in-return-handler (broker &key principal-of on-success on-failure)
  "A Clack handler for BROKER's redirect URI. It passes the query parameters to
AION/OAUTH:FINISH-SIGN-IN, with the principal of the request's app session.

PRINCIPAL-OF is required: a function of the env that returns the principal of the signed-in
user, or NIL. FINISH-SIGN-IN refuses unless it is the principal that started the sign-in, so
one user cannot link their account on the service to another user's.

ON-SUCCESS is a function of (ENV PRINCIPAL CONNECTION) returning the Clack response, such as a
redirect back to the app's settings page; by default, a short page. ON-FAILURE is a function of
(ENV CONDITION) returning the response; by default a 400, or a 403 for WRONG-USER, whose text is
the condition's report. That report never contains a code, a token or a verifier."
  (check-type principal-of function)
  (lambda (env)
    (handler-case
        (multiple-value-bind (principal connection)
            (oauth:finish-sign-in broker (funcall principal-of env)
                                  (http:form-alist (or (getf env :query-string) "")))
          (if on-success
              (funcall on-success env principal connection)
              (%text 200 (format nil "Signed in to ~A. You can close this page." connection))))
      (oauth:oauth-error (e)
        (if on-failure
            (funcall on-failure env e)
            (%text (if (typep e 'oauth:wrong-user) 403 400) (princ-to-string e)))))))

(defun client-metadata-handler (broker)
  "A Clack handler that serves BROKER's client ID metadata document, for the route at the
broker's CLIENT-METADATA-URL."
  (lambda (env)
    (declare (ignore env))
    (list 200 '(:content-type "application/json")
          (list (oauth:client-metadata-document broker)))))

(defun %escape-attribute (string)
  "STRING with &, <, >, \" and ' replaced by character references, so that it can be written
inside a quoted HTML attribute or as text."
  (with-output-to-string (out)
    (loop for c across string
          do (case c
               (#\& (write-string "&amp;" out))
               (#\< (write-string "&lt;" out))
               (#\> (write-string "&gt;" out))
               (#\" (write-string "&quot;" out))
               (#\' (write-string "&#39;" out))
               (t (write-char c out))))))

(defun %http-url-p (url)
  (let ((colon (position #\: url)))
    (and colon
         (member (subseq url 0 colon) '("https" "http") :test #'string-equal)
         (eql (1+ colon) (search "//" url :start2 (1+ colon))))))

(defun forwarding-response (url &key (link-text "Continue to sign in"))
  "A Clack response that sends the browser on to URL: a 200 HTML page with a meta refresh to
URL and a visible link to it, for a browser that does not follow the refresh.

Use it to answer a form POST that starts a sign-in, in place of a 303 to the authorization
server. When the app's Content-Security-Policy has form-action 'self', the browser applies
that directive to the target of a redirect that follows a form submission as well, and blocks
a redirect to another host without showing anything on the page (#1181). A meta refresh is a
navigation, not a form submission, so form-action does not apply to it.

URL is normally what AION/OAUTH:START-SIGN-IN returned. It must be an http or https URL;
anything else signals an error, so a javascript: URL cannot reach the link. It is written
into the page with &, <, >, \" and ' escaped. LINK-TEXT is escaped the same way.

The response carries Cache-Control: no-store, because the page contains the authorization
URL with the sign-in's state and PKCE challenge, and Referrer-Policy: no-referrer, so the
browser does not send the address of the app's page to the authorization server.
HYPERION/SECURITY-HEADERS leaves both in place, because it never replaces a header the
response already has."
  (check-type url string)
  (check-type link-text string)
  (unless (%http-url-p url)
    (error "forwarding-response: ~S is not an http or https URL." url))
  (let ((href (%escape-attribute url))
        (text (%escape-attribute link-text)))
    (list 200
          '(:content-type "text/html; charset=utf-8"
            :cache-control "no-store"
            :referrer-policy "no-referrer")
          (list (with-output-to-string (out)
                  (format out "<!doctype html>~%<html><head><meta charset=\"utf-8\">~%")
                  (format out "<meta http-equiv=\"refresh\" content=\"0; url=~A\">~%" href)
                  (format out "<title>~A</title></head>~%" text)
                  (format out "<body><p><a href=\"~A\">~A</a></p></body></html>~%"
                          href text))))))
