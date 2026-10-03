;;;; oauth.lisp --- hyperion/oauth: the routes an app mounts for aion/oauth sign-ins (#527)

(cl:defpackage #:hyperion/oauth
  (:use #:cl)
  (:local-nicknames (#:oauth #:aion/oauth)
                    (#:http #:hyperion/http))
  (:documentation
   "The two routes an app mounts for aion/oauth: the page the browser comes back to after a
    sign-in, and the app's client ID metadata document. Each is a Clack handler, a function of
    the request's env. aion/oauth itself needs no web server; this is the thin layer between.")
  (:export #:sign-in-return-handler #:client-metadata-handler))

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
