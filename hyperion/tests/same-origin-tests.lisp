;;;; same-origin-tests.lisp --- hyperion/csrf:wrap-same-origin, the CSRF defence for an app
;;;; with no session, and hyperion/desktop installing it by default (#293).
;;;;
;;;; Every request is built by hand, as in csrf-tests.lisp: nothing here adds a Host, Origin
;;;; or Sec-Fetch-Site header unless the test names it. The first test checks that.
;;;;
;;;; The last group runs a real embedded desktop server (hyperion/desktop's %START-EMBEDDED,
;;;; which RUN-APP calls) and sends it raw requests over a socket. That is the only way to
;;;; show the default is installed where RUN-APP puts it, and that both headers arrive from a
;;;; real backend under the names the check reads.

(in-package #:hyperion/tests)

(in-suite csrf)

(defparameter *so-origin* "http://127.0.0.1:5000")
(defparameter *so-host* "127.0.0.1:5000")

(defun %so-env (&key (method :post) (path "/x") host origin site)
  "A request built by hand, carrying only the headers named."
  (let ((h (make-hash-table :test #'equal)))
    (when host (setf (gethash "host" h) host))
    (when origin (setf (gethash "origin" h) origin))
    (when site (setf (gethash "sec-fetch-site" h) site))
    (list :request-method method :path-info path :headers h)))

(defun %so-reason (thunk)
  "The reason THUNK's check refuses, or NIL if it passes."
  (handler-case (progn (funcall thunk) nil)
    (csrf:csrf-failure (c) (csrf:csrf-failure-reason c))))

(defun %so-host-reason (env)
  (%so-reason (lambda () (csrf:check-host env (list *so-host*)))))

(defun %so-origin-reason (env)
  (%so-reason (lambda () (csrf:check-same-origin env (list *so-origin*)))))

(defun %so-app (&optional exempt)
  "WRAP-SAME-ORIGIN around an app that records whether it ran, with EXEMPT as its exemption
list. Returns (values app ran-box)."
  (let* ((ran (list nil))
         (app (csrf:wrap-same-origin
               (lambda (env)
                 (declare (ignore env))
                 (setf (car ran) t)
                 (list 200 (list :content-type "text/plain") (list "ok")))
               :origins (list *so-origin*)
               :exempt exempt)))
    (values app ran)))

;;; --- the control ------------------------------------------------------------

(test a-hand-built-request-carries-no-host-origin-or-fetch-site
  (let ((env (%so-env)))
    (is (null (http:request-header env "host")))
    (is (null (http:request-header env "origin")))
    (is (null (http:request-header env "sec-fetch-site")))))

;;; --- Host -------------------------------------------------------------------

(test check-host-passes-the-bound-address-in-any-case
  (is (null (%so-host-reason (%so-env :host "127.0.0.1:5000"))))
  (is (null (%so-host-reason (%so-env :host "127.0.0.1:5000" :method :get)))))

(test check-host-refuses-a-rebinding-host-a-wrong-port-and-no-host
  (is (eq :host-mismatch (%so-host-reason (%so-env :host "attacker.example:5000"))))
  (is (eq :host-mismatch (%so-host-reason (%so-env :host "127.0.0.1:5001"))))
  (is (eq :host-mismatch (%so-host-reason (%so-env :host "localhost:5000")))
      "only the address the app is bound to, not another name for it")
  (is (eq :no-host (%so-host-reason (%so-env)))))

;;; --- Sec-Fetch-Site, then Origin ----------------------------------------------

(test check-same-origin-passes-same-origin-and-user-started-requests
  (is (null (%so-origin-reason (%so-env :site "same-origin"))))
  (is (null (%so-origin-reason (%so-env :site "none")))))

(test check-same-origin-refuses-cross-site-and-same-site
  (is (eq :cross-site (%so-origin-reason (%so-env :site "cross-site"))))
  (is (eq :cross-site (%so-origin-reason (%so-env :site "same-site")))
      "another server on 127.0.0.1 at another port is same-site, and must be refused"))

(test check-same-origin-reads-sec-fetch-site-before-origin
  ;; A cross-site request with an Origin that happens to match is still refused: the
  ;; header the browser uses to state the relationship wins.
  (is (eq :cross-site (%so-origin-reason (%so-env :site "cross-site" :origin *so-origin*)))))

(test without-sec-fetch-site-origin-must-be-the-apps-own
  (is (null (%so-origin-reason (%so-env :origin *so-origin*))))
  (is (null (%so-origin-reason (%so-env :origin "HTTP://127.0.0.1:5000"))))
  (is (eq :origin-mismatch (%so-origin-reason (%so-env :origin "https://attacker.example"))))
  (is (eq :origin-mismatch (%so-origin-reason (%so-env :origin "http://127.0.0.1:5001"))))
  (is (eq :origin-mismatch (%so-origin-reason (%so-env :origin "null")))
      "an opaque origin, e.g. a sandboxed iframe, is not the app")
  (is (eq :no-origin (%so-origin-reason (%so-env)))
      "with neither header there is nothing to say where it came from, so it is refused"))

;;; --- the middleware ---------------------------------------------------------

(test wrap-same-origin-refuses-a-cross-site-post-without-calling-the-app
  (%quietly
    (multiple-value-bind (app ran) (%so-app)
      (let ((resp (funcall app (%so-env :host *so-host* :site "cross-site"))))
        (is (= 403 (first resp)))
        (is (search "cross-site" (first (third resp))))
        (is (null (car ran)) "the app must not run for a refused request")))))

(test wrap-same-origin-passes-the-apps-own-posts-by-either-header
  (multiple-value-bind (app ran) (%so-app)
    (is (= 200 (first (funcall app (%so-env :host *so-host* :site "same-origin")))))
    (is (car ran)))
  (multiple-value-bind (app ran) (%so-app)
    (is (= 200 (first (funcall app (%so-env :host *so-host* :origin *so-origin*)))))
    (is (car ran))))

(test wrap-same-origin-refuses-a-rebinding-get
  (%quietly
    (multiple-value-bind (app ran) (%so-app)
      (let ((resp (funcall app (%so-env :method :get :host "attacker.example:5000"
                                        :site "same-origin"))))
        (is (= 403 (first resp)))
        (is (null (car ran)))))))

(test wrap-same-origin-does-not-check-the-origin-of-a-safe-method
  ;; A cross-site GET (a link to the app from elsewhere) is not refused: it cannot change
  ;; state, and the Host check has already run.
  (multiple-value-bind (app ran) (%so-app)
    (is (= 200 (first (funcall app (%so-env :method :get :host *so-host* :site "cross-site")))))
    (is (car ran))))

(test an-exemption-skips-the-origin-check-but-not-the-host-check
  (%quietly
    (multiple-value-bind (app ran) (%so-app (list "/hook"))
      (is (= 200 (first (funcall app (%so-env :path "/hook" :host *so-host* :site "cross-site")))))
      (is (car ran)))
    (multiple-value-bind (app ran) (%so-app (list "/hook"))
      (is (= 403 (first (funcall app (%so-env :path "/hook" :host "attacker.example:5000")))))
      (is (null (car ran))))))

(test wrap-same-origin-with-no-origins-is-refused-at-construction
  (signals error (csrf:wrap-same-origin (lambda (env) env) :origins nil)))

(test an-app-that-signals-csrf-failure-is-not-mistaken-for-a-refusal
  (let ((app (csrf:wrap-same-origin
              (lambda (env)
                (declare (ignore env))
                (error 'csrf:csrf-failure :reason :from-the-app))
              :origins (list *so-origin*))))
    (signals csrf:csrf-failure
      (funcall app (%so-env :host *so-host* :site "same-origin")))))

;;; --- default ports (review of #302) ------------------------------------------

(test normalise-origin-drops-a-default-port-and-keeps-any-other
  (is (string= "http://127.0.0.1" (csrf:normalise-origin "http://127.0.0.1:80")))
  (is (string= "http://127.0.0.1" (csrf:normalise-origin "HTTP://127.0.0.1:80/")))
  (is (string= "https://app.test" (csrf:normalise-origin "https://app.test:443")))
  (is (string= "http://127.0.0.1:443" (csrf:normalise-origin "http://127.0.0.1:443"))
      "443 is only the default for https")
  (is (string= "http://127.0.0.1:8080" (csrf:normalise-origin "http://127.0.0.1:8080"))))

(test an-app-on-port-80-accepts-its-own-requests-as-a-browser-sends-them
  ;; A browser sends Origin: http://127.0.0.1 for a page on port 80, and may send Host with
  ;; or without :80. Before the fix the configured "http://127.0.0.1:80" matched neither.
  (let ((app (csrf:wrap-same-origin (lambda (env) (declare (ignore env)) (list 200 nil nil))
                                    :origins (list "http://127.0.0.1:80"))))
    (is (= 200 (first (funcall app (%so-env :host "127.0.0.1" :origin "http://127.0.0.1")))))
    (is (= 200 (first (funcall app (%so-env :host "127.0.0.1:80" :origin "http://127.0.0.1")))))
    (%quietly
      (is (= 403 (first (funcall app (%so-env :host "127.0.0.1" :origin "http://127.0.0.1:8080"))))
          "another port is still another origin")
      (is (= 403 (first (funcall app (%so-env :host "attacker.example" :origin "http://127.0.0.1"))))))))

;;; --- hyperion/desktop installs it, on a real server --------------------------

(defun %so-raw-status (port method path headers)
  "Send METHOD PATH to 127.0.0.1:PORT over a real socket with exactly HEADERS (an alist of
name and value; Host included only if listed) and return the status code."
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp))
        (crlf (coerce '(#\Return #\Linefeed) 'string)))
    (unwind-protect
         (ports:with-deadline (10 (format nil "~A ~A on port ~D" method path port))
           (sb-bsd-sockets:socket-connect s #(127 0 0 1) port)
           (let ((st (sb-bsd-sockets:socket-make-stream s :input t :output t
                                                          :element-type 'character
                                                          :external-format :latin-1)))
             (write-string (format nil "~A ~A HTTP/1.0" method path) st)
             (write-string crlf st)
             (loop for (name . value) in headers
                   do (write-string (format nil "~A: ~A" name value) st)
                      (write-string crlf st))
             (write-string "Content-Length: 0" st)
             (write-string crlf st)
             (write-string crlf st)
             (finish-output st)
             (let ((line (read-line st nil "")))
               (parse-integer line :start (1+ (position #\Space line)) :junk-allowed t))))
      (ignore-errors (sb-bsd-sockets:socket-close s)))))

(defmacro %so-with-desktop ((port-var &optional (guard :same-origin)) &body body)
  `(multiple-value-bind (url handler)
       (hyperion/desktop::%start-embedded (%srv-ok-app) :auto :uv ,guard)
     (unwind-protect
          (let ((,port-var (parse-integer url :start (1+ (position #\: url :from-end t))
                                              :junk-allowed t)))
            ,@body)
       (ignore-errors (srv:stop handler)))))

(test a-desktop-app-refuses-cross-site-posts-and-rebinding-hosts-by-default
  (%quietly
    (%so-with-desktop (port)
      (let ((own (format nil "127.0.0.1:~D" port)))
        (is (= 200 (%so-raw-status port "GET" "/" `(("Host" . ,own))))
            "the webview's own first page load")
        (is (= 200 (%so-raw-status port "POST" "/x" `(("Host" . ,own)
                                                      ("Sec-Fetch-Site" . "same-origin")))))
        (is (= 200 (%so-raw-status port "POST" "/x" `(("Host" . ,own)
                                                      ("Origin" . ,(format nil "http://~A" own)))))
            "an older webview that sends Origin but not Sec-Fetch-Site")
        (is (= 403 (%so-raw-status port "POST" "/x" `(("Host" . ,own)
                                                      ("Sec-Fetch-Site" . "cross-site")))))
        (is (= 403 (%so-raw-status port "POST" "/x" `(("Host" . ,own)
                                                      ("Origin" . "https://attacker.example")))))
        (is (= 403 (%so-raw-status port "GET" "/" `(("Host" . ,(format nil "attacker.example:~D" port))
                                                    ("Sec-Fetch-Site" . "same-origin")))))))))

(test run-app-installs-the-guard-by-default
  ;; The review of #302: the tests above start the server through %START-EMBEDDED, so they
  ;; would still pass if RUN-APP stopped passing :REQUEST-GUARD or changed its default. This
  ;; goes through RUN-APP itself. ON-READY runs once the server listens and before any shell
  ;; starts; it sends its requests and then leaves RUN-APP with THROW, whose unwind stops the
  ;; server. The launcher must exist for RUN-APP's up-front check, and is never started.
  (%quietly
    (let ((results
            (catch 'run-app-done
              (hyperion/desktop:run-app
               (%srv-ok-app)
               :server :uv :shell :webview :launcher sb-ext:*runtime-pathname*
               :on-ready (lambda (url)
                           (let* ((port (parse-integer url :start (1+ (position #\: url :from-end t))
                                                           :junk-allowed t))
                                  (own (format nil "127.0.0.1:~D" port)))
                             (throw 'run-app-done
                               (list (%so-raw-status port "POST" "/x" `(("Host" . ,own)
                                                                        ("Sec-Fetch-Site" . "same-origin")))
                                     (%so-raw-status port "POST" "/x" `(("Host" . ,own)
                                                                        ("Sec-Fetch-Site" . "cross-site")))))))))))
      (is (equal '(200 403) results)
          "run-app must refuse a cross-site POST by default: own, cross-site = ~S" results))))

(test a-desktop-app-with-request-guard-none-installs-nothing
  ;; The control for the test above: the same cross-site POST that was refused there is
  ;; served here, so the refusal came from the guard and not from the server or the app.
  (%quietly
    (%so-with-desktop (port :none)
      (is (= 200 (%so-raw-status port "POST" "/x"
                                 `(("Host" . ,(format nil "127.0.0.1:~D" port))
                                   ("Sec-Fetch-Site" . "cross-site"))))))))

;;; --- the guard on dev:serve and server:start (#304) ------------------------------------
;;;
;;; #302 put the guard on RUN-APP only. An app's development server (dev:serve) and a
;;; headless server:start on 127.0.0.1 serve the same data to the same machine, and a
;;; DNS-rebinding page could read from and post to either. dev:serve now guards by default on
;;; loopback. server:start and serve-forever guard by default too since #1037; behind a
;;; same-machine reverse proxy, HYPERION_ORIGINS gives them the public origin.

(defmacro %so-with-start ((port-var &rest start-args) &body body)
  "BODY with PORT-VAR bound to a server START ran with START-ARGS on a free loopback port."
  (let ((handler (gensym "HANDLER")))
    `(let* ((,port-var (ports:candidate-port))
            (,handler (srv:start (%srv-ok-app) :server :uv :port ,port-var
                                               :host "127.0.0.1" ,@start-args)))
       (unwind-protect (progn ,@body)
         (ignore-errors (srv:stop ,handler))
         (ports:await-released ,port-var)))))

(defmacro %so-with-dev-serve ((port-var &rest serve-args) &body body)
  "BODY with PORT-VAR bound to a real dev:serve on a free loopback port, started with
SERVE-ARGS, and torn down afterwards."
  (let ((root (gensym "ROOT")) (thread (gensym "THREAD")))
    `(let* ((,root (%dev-serve-root))
            (,port-var (ports:candidate-port))
            (,thread (sb-thread:make-thread
                      (lambda ()
                        (let ((*standard-output* (make-broadcast-stream)))
                          (handler-case
                              (hyperion/dev:serve #'%srv-ok-app :paths (list ,root) :port ,port-var
                                                                 :host "127.0.0.1" :interval 0.2
                                                                 ,@serve-args)
                            (srv:port-in-use (c) c))))
                      :name "same-origin dev-serve")))
       (unwind-protect
            (progn (%srv-await (lambda () (ports:listening-p ,port-var)))
                   ,@body)
         (ignore-errors (hyperion/dev:unwatch))
         (ignore-errors (sb-thread:join-thread ,thread :timeout 10 :default nil))
         (ports:await-released ,port-var)
         (ignore-errors (aion/fs:delete-tree ,root :if-does-not-exist :ignore))))))

(defun %so-guarded-answers (port)
  "Statuses for the requests that tell a guarded server from an unguarded one, as a plist."
  (let ((ip (format nil "127.0.0.1:~D" port))
        (name (format nil "localhost:~D" port)))
    (list :own-get (%so-raw-status port "GET" "/" `(("Host" . ,ip)))
          :localhost-get (%so-raw-status port "GET" "/" `(("Host" . ,name)))
          :foreign-get (%so-raw-status port "GET" "/" `(("Host" . ,(format nil "attacker.example:~D" port))))
          :own-post (%so-raw-status port "POST" "/x" `(("Host" . ,ip) ("Sec-Fetch-Site" . "same-origin")))
          :cross-post (%so-raw-status port "POST" "/x" `(("Host" . ,ip) ("Sec-Fetch-Site" . "cross-site"))))))

(test dev-serve-on-loopback-guards-by-default
  (%quietly
    (%so-with-dev-serve (port)
      (let ((a (%so-guarded-answers port)))
        (is (= 200 (getf a :own-get)))
        (is (= 200 (getf a :localhost-get)) "a developer types localhost too")
        (is (= 403 (getf a :foreign-get)) "a rebinding page's Host is refused, GET included")
        (is (= 200 (getf a :own-post)))
        (is (= 403 (getf a :cross-post)) "a cross-site POST is refused")))))

(test dev-serve-with-request-guard-none-installs-nothing
  "The control for the test above: the same server with the guard off answers everything."
  (%quietly
    (%so-with-dev-serve (port :request-guard :none)
      (let ((a (%so-guarded-answers port)))
        (is (= 200 (getf a :foreign-get)))
        (is (= 200 (getf a :cross-post)))))))

(defmacro %so-with-origins-setting ((value) &body body)
  "BODY with HYPERION_ORIGINS set to VALUE, restored afterwards. NIL sets it to the empty
string, which ORIGINS-SETTING reads as unset; uiop cannot unset a variable on every OS."
  (let ((old (gensym "OLD")))
    `(let ((,old (uiop:getenv "HYPERION_ORIGINS")))
       (unwind-protect
            (progn (setf (uiop:getenv "HYPERION_ORIGINS") (or ,value ""))
                   ,@body)
         (setf (uiop:getenv "HYPERION_ORIGINS") (or ,old ""))))))

(test server-start-guards-by-default
  "#1037: START installs the same-origin guard unless told not to. Before, the default was :NONE,
and a web page the user visited could post to an app started with START."
  (%quietly
    (%so-with-origins-setting (nil)
      (%so-with-start (port)
        (let ((a (%so-guarded-answers port)))
          (is (= 200 (getf a :own-get)))
          (is (= 200 (getf a :localhost-get)))
          (is (= 403 (getf a :foreign-get)) "a rebinding page's Host is refused")
          (is (= 200 (getf a :own-post)) "a same-origin POST passes")
          (is (= 403 (getf a :cross-post)) "a cross-site POST is refused"))))))

(test server-start-with-request-guard-none-lets-a-cross-site-post-through
  "The control for the test above: :REQUEST-GUARD :NONE is still the way to turn it off."
  (%quietly
    (%so-with-start (port :request-guard :none)
      (let ((a (%so-guarded-answers port)))
        (is (= 200 (getf a :foreign-get)))
        (is (= 200 (getf a :cross-post)))))))

(test a-cross-origin-post-is-accepted-only-when-hyperion-origins-lists-it
  "A POST whose Origin is another site's is refused under the default guard, and accepted once
HYPERION_ORIGINS lists that origin. The Host is the server's own in both, so only the Origin
check decides."
  (flet ((post (port)
           (%so-raw-status port "POST" "/x" `(("Host" . ,(format nil "127.0.0.1:~D" port))
                                              ("Origin" . "https://app.example.test")))))
    (%quietly
      (%so-with-origins-setting (nil)
        (%so-with-start (port)
          (is (= 403 (post port)) "refused without the setting")))
      (%so-with-origins-setting ("https://app.example.test, https://other.example.test")
        (%so-with-start (port)
          (is (= 200 (post port)) "accepted when the setting lists it")
          (is (= 403 (%so-raw-status port "POST" "/x"
                                     `(("Host" . ,(format nil "127.0.0.1:~D" port))
                                       ("Origin" . "https://attacker.example.test"))))
                 "an origin the setting does not list is still refused"))))))

;;; A webhook sender, curl or an API client sends neither Origin nor Sec-Fetch-Site. The
;;; guard refuses such a POST, because it cannot tell it from a request whose browser left both
;;; out, so an app that takes them lists their paths in :REQUEST-GUARD-EXEMPT (#1037).

(defun %so-webhook-post (port path &optional (host (format nil "127.0.0.1:~D" port)))
  "The status for a POST to PATH carrying a Host and no Origin or Sec-Fetch-Site, as a webhook
sender sends it."
  (%so-raw-status port "POST" path `(("Host" . ,host) ("Content-Type" . "application/json"))))

(test a-webhook-post-with-no-origin-is-refused-by-default-and-accepted-on-an-exempt-path
  "A POST with no Origin and no Sec-Fetch-Site is refused under the default guard, and accepted
on a path listed in :REQUEST-GUARD-EXEMPT. A path that is not listed is still refused, so the
exemption covers only what it names; a function in the list is matched against the env."
  (%quietly
    (%so-with-origins-setting (nil)
      (%so-with-start (port)
        (is (= 403 (%so-webhook-post port "/webhooks/stripe")) "refused by default"))
      (%so-with-start (port :request-guard-exempt '("/webhooks/stripe"))
        (is (= 200 (%so-webhook-post port "/webhooks/stripe")) "accepted on the exempt path")
        (is (= 403 (%so-webhook-post port "/webhooks/stripe/other"))
            "a longer path is not the exempt one")
        (is (= 403 (%so-webhook-post port "/x")) "a path that is not listed is still refused"))
      (%so-with-start (port :request-guard-exempt
                            (list (lambda (env) (equal "/api/ingest" (getf env :path-info)))))
        (is (= 200 (%so-webhook-post port "/api/ingest")) "a function in the list matches")
        (is (= 403 (%so-webhook-post port "/x")))))))

(test an-exempt-path-still-has-its-host-checked
  "An exemption skips the Origin check only. A request to an exempt path whose Host is not the
server's is refused, so a DNS-rebinding page cannot use an exempt path to reach the server.
Control: the same request with the server's own Host is accepted."
  (%quietly
    (%so-with-origins-setting (nil)
      (%so-with-start (port :request-guard-exempt '("/webhooks/stripe"))
        (is (= 403 (%so-webhook-post port "/webhooks/stripe"
                                     (format nil "attacker.example.test:~D" port)))
            "a foreign Host is refused on the exempt path")
        (is (= 403 (%so-raw-status port "GET" "/webhooks/stripe"
                                   `(("Host" . ,(format nil "attacker.example.test:~D" port)))))
            "for a safe method too")
        (is (= 200 (%so-webhook-post port "/webhooks/stripe")) "control: own Host")))))

(test serve-forever-passes-request-guard-exempt-to-the-guard
  "SERVE-FOREVER takes :REQUEST-GUARD-EXEMPT as START does: the exempt path accepts a POST with
no Origin, and another path refuses it."
  (%quietly
    (%so-with-origins-setting (nil)
      (%srv-with-serving (session port :server :uv :signals nil
                                       :request-guard-exempt '("/webhooks/stripe"))
        (is (= 200 (%so-webhook-post port "/webhooks/stripe")))
        (is (= 403 (%so-webhook-post port "/x")))))))

(defmacro %so-captured-log ((stream) &body body)
  "Run BODY with the log at :INFO going to STREAM, then put back the appenders, level and
layout that were there."
  (let ((appenders (gensym)) (level (gensym)) (layout (gensym)))
    `(let ((,appenders (copy-list (log4cl:logger-appenders log4cl:*root-logger*)))
           (,level (log4cl:logger-log-level log4cl:*root-logger*))
           (,layout aion/log:*layout*))
       (unwind-protect
            (progn (aion/log:setup :env :dev :level :info :stream ,stream)
                   ,@body)
         (log4cl:remove-all-appenders log4cl:*root-logger*)
         (dolist (a ,appenders) (log4cl:add-appender log4cl:*root-logger* a))
         (log4cl:set-log-level log4cl:*root-logger* ,level)
         (setf aion/log:*layout* ,layout)))))

(defun %so-count-occurrences (needle haystack)
  (loop with start = 0
        for at = (search needle haystack :start2 start)
        while at count t do (setf start (1+ at))))

(test request-guard-exempt-is-logged-once-when-the-server-starts
  "An exempt path accepts a cross-site POST, so the list is logged once, naming the path, when
the server starts, and not again on each request to it. Control: with no exemptions nothing of
the kind is logged."
  (let ((with-exempt (make-string-output-stream))
        (without (make-string-output-stream)))
    (%so-with-origins-setting (nil)
      (%so-captured-log (with-exempt)
        (%so-with-start (port :request-guard-exempt '("/webhooks/stripe"))
          (%so-webhook-post port "/webhooks/stripe")
          (%so-webhook-post port "/webhooks/stripe")))
      (%so-captured-log (without)
        (%so-with-start (port)
          (%so-webhook-post port "/x"))))
    (let ((logged (get-output-stream-string with-exempt))
          (control (get-output-stream-string without)))
      (is (= 1 (%so-count-occurrences "exemptions configured" logged)) "~A" logged)
      (is-true (let ((line (find-if (lambda (l) (search "exemptions configured" l))
                                    (uiop:split-string logged :separator '(#\Newline)))))
                 (and line (search "/webhooks/stripe" line)))
               "the exemption line names the path")
      (is (= 0 (%so-count-occurrences "exemptions configured" control)) "~A" control))))

(test hyperion-origins-gives-the-public-host-behind-a-same-machine-proxy
  "Behind a proxy on the same machine the server binds 127.0.0.1 and receives the public Host.
Without the setting that Host is refused; with it, it is accepted."
  (let ((proxied '(("Host" . "app.example.test"))))
    (%quietly
      (%so-with-origins-setting (nil)
        (%so-with-start (port)
          (is (= 403 (%so-raw-status port "GET" "/" proxied)))))
      (%so-with-origins-setting ("https://app.example.test")
        (%so-with-start (port)
          (is (= 200 (%so-raw-status port "GET" "/" proxied))))))))

(test binding-every-interface-with-no-origins-refuses-to-start
  "Bound to every interface, the guard cannot work out the app's origins, so START refuses
before it binds, and the error says what to do. With HYPERION_ORIGINS set, the origins are the
setting's. The every-interface case is checked without binding 0.0.0.0, which on macOS can show
a firewall dialog."
  (%so-with-origins-setting (nil)
    (let ((e (handler-case (progn (srv:start (%srv-ok-app) :server :uv :host "0.0.0.0"
                                                           :port (ports:candidate-port)
                                                           :check-port nil)
                                  nil)
               (error (c) c))))
      (is (typep e 'error) "START refused")
      (let ((text (and e (princ-to-string e))))
        (is (search "HYPERION_ORIGINS" text) "~A" text)
        (is (search ":request-guard :none" text) "~A" text)
        (is (search ":same-origin" text) "~A" text))))
  (is (equal '("https://app.example.test")
             (srv::%request-guard-origins "0.0.0.0" 8080 '("https://app.example.test"))))
  (%so-with-origins-setting ("https://app.example.test")
    (is (equal '("https://app.example.test") (srv::%request-guard-origins "0.0.0.0" 8080)))
    (is (equal '("https://app.example.test" "http://127.0.0.1:8080" "http://localhost:8080")
               (srv::%request-guard-origins "127.0.0.1" 8080))
        "on loopback the setting adds to the derived origins")))

(test hyperion-origins-refuses-what-is-not-an-origin
  (is (null (srv::%parse-origin-setting nil)))
  (is (null (srv::%parse-origin-setting "  ")))
  (is (equal '("https://a.test" "http://b.test:8080")
             (srv::%parse-origin-setting "https://a.test,http://b.test:8080")))
  (dolist (bad '("a.test" "https://a.test/path" "ftp://a.test" "https://"))
    (signals error (srv::%parse-origin-setting bad))))

(test server-start-with-request-guard-same-origin-guards-like-run-app
  (%quietly
    (%so-with-start (port :request-guard :same-origin)
      (let ((a (%so-guarded-answers port)))
        (is (= 200 (getf a :own-get)))
        (is (= 200 (getf a :localhost-get)))
        (is (= 403 (getf a :foreign-get)))
        (is (= 200 (getf a :own-post)))
        (is (= 403 (getf a :cross-post)))))))

(test server-start-takes-the-origins-it-is-given
  (%quietly
    (%so-with-start (port :request-guard (list :same-origin "http://app.example.test:8443"))
      (is (= 200 (%so-raw-status port "GET" "/" '(("Host" . "app.example.test:8443")))))
      (is (= 403 (%so-raw-status port "GET" "/" `(("Host" . ,(format nil "127.0.0.1:~D" port)))))
          "only the origins given are the app's own"))))

(test the-request-guard-refuses-what-it-cannot-apply
  (signals error (srv::%request-guard-origins "0.0.0.0" 8080))
  (signals error (srv::%apply-request-guard (%srv-ok-app) :yes "127.0.0.1" 8080))
  (is (srv:loopback-host-p "localhost"))
  (is (srv:loopback-host-p "::1"))
  (is (not (srv:loopback-host-p "192.168.1.5"))))

;;; --- the readiness path is exempt from the guard (#304, with #397's readiness path) --------

(test serve-forever-exempts-the-readiness-path-from-the-request-guard
  "A platform's health checker sends no Origin and may use another Host; refusing it would take
a healthy instance out of rotation. Every other path stays guarded."
  (%quietly
    (%srv-with-serving (session port :server :uv :signals nil
                                     :request-guard :same-origin :readiness-path "/health")
      (let ((foreign `(("Host" . ,(format nil "health-checker.internal:~D" port)))))
        (is (= 200 (%so-raw-status port "GET" "/health" foreign))
            "a foreign Host reaches the readiness path")
        (is (= 200 (%so-raw-status port "POST" "/health" (cons '("Sec-Fetch-Site" . "cross-site") foreign)))
            "the Origin check is skipped there too")
        (is (= 403 (%so-raw-status port "GET" "/" foreign))
            "every other path is still guarded")
        (setf (srv::server-session-draining session) t)
        (is (= 503 (%so-raw-status port "GET" "/health" foreign))
            "while draining, the readiness path answers 503 to the same checker")
        (setf (srv::server-session-draining session) nil)))))

(test without-a-readiness-path-the-same-request-is-refused
  "The control for the test above: the same guard and the same request, with no readiness path."
  (%quietly
    (%srv-with-serving (session port :server :uv :signals nil :request-guard :same-origin)
      (is (= 403 (%so-raw-status port "GET" "/health"
                                 `(("Host" . ,(format nil "health-checker.internal:~D" port)))))))))
