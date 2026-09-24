;;;; security-headers-tests.lisp --- default security headers, and every way to change them (#119)
;;;;
;;;; The failure mode for this category is silent absence: a header that quietly stops being
;;;; sent. So these assert the headers on the response itself, first through the wrapper and
;;;; then over a real socket through HYPERION/SERVER:START, where an application sees them.

(in-package #:hyperion/tests)

(def-suite security-headers :description "Default security headers (#119)." :in hyperion)
(in-suite security-headers)

(defun %sh-app (&optional headers (body (list "ok")))
  "An app returning HEADERS on a 200."
  (lambda (env) (declare (ignore env)) (list 200 (copy-list headers) body)))

(defun %sh-headers (app)
  (second (funcall app '(:request-method :get :path-info "/"))))

(defun %sh-count (headers key)
  "How many times KEY appears in the HEADERS plist, compared without regard to case."
  (loop for (k nil) on headers by #'cddr count (string-equal (string k) (string key))))

(test the-defaults-are-added-to-every-response
  (let ((h (%sh-headers (hyperion/security-headers:wrap-security-headers
                         (%sh-app '(:content-type "text/html"))))))
    (is (equal "nosniff" (getf h :x-content-type-options)))
    (is (equal "DENY" (getf h :x-frame-options)))
    (is (equal "strict-origin-when-cross-origin" (getf h :referrer-policy)))
    (is (search "frame-ancestors 'none'" (or (getf h :content-security-policy) "")))
    (is (not (search "script-src" (or (getf h :content-security-policy) "")))
        "no script-src by default: every page in the tree inlines its script")
    (is (null (getf h :strict-transport-security)) "HSTS is opt-in")
    (is (equal "text/html" (getf h :content-type)) "the app's own headers are kept")))

(test a-header-the-app-sets-is-never-replaced
  ;; One route may loosen or tighten a header without the wrapper knowing about it, and a
  ;; header spelled with a string key still counts.
  (let ((h (%sh-headers (hyperion/security-headers:wrap-security-headers
                         (%sh-app (list :content-security-policy "default-src 'self'"
                                        "X-Frame-Options" "SAMEORIGIN"))))))
    (is (equal "default-src 'self'" (getf h :content-security-policy)))
    (is (= 1 (%sh-count h :content-security-policy)) "not sent twice")
    (is (= 1 (%sh-count h :x-frame-options)) "a string-keyed header is respected")
    (is (equal "nosniff" (getf h :x-content-type-options)) "the others still arrive")))

(test each-header-can-be-replaced-or-turned-off
  (let ((h (%sh-headers (hyperion/security-headers:wrap-security-headers
                         (%sh-app)
                         :frame-options nil
                         :referrer-policy "no-referrer"
                         :content-security-policy "default-src 'self'"))))
    (is (zerop (%sh-count h :x-frame-options)) "NIL omits the header")
    (is (equal "no-referrer" (getf h :referrer-policy)))
    (is (equal "default-src 'self'" (getf h :content-security-policy))))
  ;; ...and through the special variables, read when the wrapper is made.
  (let ((h (let ((hyperion/security-headers:*content-type-options* nil))
             (%sh-headers (hyperion/security-headers:wrap-security-headers (%sh-app))))))
    (is (zerop (%sh-count h :x-content-type-options)))))

(test hsts-is-sent-only-when-asked-and-preload-only-when-asked-for-too
  (is (equal "max-age=31536000; includeSubDomains" (hyperion/security-headers:hsts-value)))
  (is (search "preload" (hyperion/security-headers:hsts-value :preload t)))
  (let ((h (%sh-headers (hyperion/security-headers:wrap-security-headers
                         (%sh-app) :hsts (hyperion/security-headers:hsts-value :max-age 600)))))
    (is (equal "max-age=600; includeSubDomains" (getf h :strict-transport-security)))))

(test a-streamed-response-gets-them-and-any-other-shape-passes-through
  (let* ((stream-body (lambda (write) (funcall write "x")))
         (res (funcall (hyperion/security-headers:wrap-security-headers
                        (%sh-app nil stream-body))
                       nil)))
    (is (equal "nosniff" (getf (second res) :x-content-type-options)))
    (is (eq stream-body (third res)) "the body is untouched"))
  (let ((odd (lambda (responder) responder)))
    (is (eq odd (funcall (hyperion/security-headers:wrap-security-headers
                          (lambda (env) (declare (ignore env)) odd))
                         nil)))))

(test start-sends-them-over-http-by-default-and-not-when-told-not-to
  ;; What an application actually receives. Both directions through START, on a real socket.
  (flet ((served (&rest start-args)
           (let* ((port nil)
                  (h (ports:call-with-port
                      (lambda (p)
                        (prog1 (apply #'srv:start (%srv-ok-app) :port p :server :hunchentoot
                                      :log nil start-args)
                          (setf port p))))))
             (unwind-protect (%srv-http-get port "/")
               (srv:stop h)))))
    (let ((on (served)))
      (is (search "X-Content-Type-Options: nosniff" on :test #'char-equal))
      (is (search "X-Frame-Options: DENY" on :test #'char-equal))
      (is (search "Content-Security-Policy: frame-ancestors 'none'" on :test #'char-equal)))
    (let ((off (served :security-headers nil)))
      (is (not (search "X-Frame-Options" off :test #'char-equal)))
      (is (not (search "Content-Security-Policy" off :test #'char-equal))))
    (let ((custom (served :security-headers '(:frame-options "SAMEORIGIN"))))
      (is (search "X-Frame-Options: SAMEORIGIN" custom :test #'char-equal)))))
