;;;; logging-tests.lisp --- request logging: correlation ids and quiet paths.
;;;;
;;;; These assert on the actual emitted text, not on internal state: the bug that prompted
;;;; the quiet-path work was "the log is unusable", which is a statement about output. So
;;;; each test installs an appender over a string stream and reads what came out.
;;;;
;;;; Helpers are %LOG-prefixed: every *-tests.lisp shares the one HYPERION/TESTS package,
;;;; so a bare %ENV here would clobber session-tests.lisp's (it did, once).

(in-package #:hyperion/tests)

(def-suite logging :description "Request logging: request ids, quiet paths." :in hyperion)
(in-suite logging)

(defun %log-env (path &rest headers)
  "A minimal Clack env for PATH carrying HEADERS (name value ...)."
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on headers by #'cddr
          do (setf (gethash (string-downcase k) h) v))
    (list :request-method :get :path-info path :headers h)))

(defun %log-capture (level thunk)
  "Run THUNK with logging at LEVEL into a string stream; return everything logged.
Restores the quiet test default afterwards so one test cannot leak noise into the rest of
the suite."
  (let ((s (make-string-output-stream)))
    (unwind-protect
         (progn (aion/log:setup :env :dev :level level :stream s)
                (funcall thunk)
                (get-output-stream-string s))
      (aion/log:setup :env :dev :level :warn :stream *standard-output*))))

(defun %log-ok-app (&optional (status 200))
  (lambda (env) (declare (ignore env))
    (list status (list :content-type "text/plain") (list "ok"))))

(defmacro with-clean-quiet-paths (&body body)
  "Run BODY with a private *QUIET-PATHS*, so registering does not leak between tests."
  `(let ((hyperion/logging:*quiet-paths* '())) ,@body))

;;; --- request id ------------------------------------------------------------

(test mints-a-request-id-and-echoes-it
  (let* ((app (hyperion/logging:wrap (%log-ok-app)))
         (res (funcall app (%log-env "/hello"))))
    (is (= 200 (first res)))
    (is (stringp (getf (second res) :x-request-id)))))

(test adopts-an-upstream-request-id
  ;; Joining the edge's trace rather than starting a rival one is the whole point.
  (let* ((app (hyperion/logging:wrap (%log-ok-app)))
         (res (funcall app (%log-env "/hello" "X-Request-Id" "edge-42"))))
    (is (string= "edge-42" (getf (second res) :x-request-id)))))

(test the-request-id-appears-on-every-line-logged-during-the-request
  (let ((out (%log-capture
              :info
              (lambda ()
                (funcall (hyperion/logging:wrap
                          (lambda (env) (declare (ignore env))
                            (aion/log:info "app did something")     ; the app's own line
                            (list 200 '(:content-type "text/plain") (list "ok"))))
                         (%log-env "/hello" "X-Request-Id" "corr-7"))))))
    ;; both the app's line and the framework's completion line carry the id
    (is (= 2 (count "corr-7" (uiop:split-string (string-trim '(#\Newline) out)
                                                :separator '(#\Newline))
                    :test (lambda (needle line) (search needle line)))))))

;;; --- quiet paths -----------------------------------------------------------

(test a-normal-path-logs-at-info
  (with-clean-quiet-paths
    (let ((out (%log-capture :info (lambda ()
                                     (funcall (hyperion/logging:wrap (%log-ok-app))
                                              (%log-env "/hello"))))))
      (is (search "/hello" out)))))

(test a-quiet-path-emits-no-info-line
  (with-clean-quiet-paths
    (hyperion/logging:register-quiet-path "/api/ping")
    (let ((out (%log-capture :info (lambda ()
                                     (funcall (hyperion/logging:wrap (%log-ok-app))
                                              (%log-env "/api/ping"))))))
      (is (string= "" (string-trim '(#\Space #\Newline) out))))))

(test a-quiet-path-is-still-quiet-at-debug
  ;; The point of :trace rather than :debug -- a dev REPL runs AT :debug, which is exactly
  ;; the session where the flood was unusable, so demoting to :debug would fix nothing.
  (with-clean-quiet-paths
    (hyperion/logging:register-quiet-path "/api/ping")
    (let ((out (%log-capture :debug (lambda ()
                                      (funcall (hyperion/logging:wrap (%log-ok-app))
                                               (%log-env "/api/ping"))))))
      (is (string= "" (string-trim '(#\Space #\Newline) out))))))

(test a-quiet-path-is-still-visible-at-trace
  ;; Quiet means "only if you ask for everything", not "discarded".
  (with-clean-quiet-paths
    (hyperion/logging:register-quiet-path "/api/ping")
    (let ((out (%log-capture :trace (lambda ()
                                      (funcall (hyperion/logging:wrap (%log-ok-app))
                                               (%log-env "/api/ping"))))))
      (is (search "/api/ping" out)))))

(test quieting-never-suppresses-errors
  ;; A failing health check is precisely what you need to see.
  (with-clean-quiet-paths
    (hyperion/logging:register-quiet-path "/api/ping")
    (let ((out (%log-capture
                :info
                (lambda ()
                  (ignore-errors
                   (funcall (hyperion/logging:wrap
                             (lambda (env) (declare (ignore env)) (error "boom")))
                            (%log-env "/api/ping")))))))
      (is (search "request failed" out))
      ;; The condition's type, not its report: aion/log:exception no longer writes the report,
      ;; which can quote outside data (#1013).
      (is (search "SIMPLE-ERROR" out) "~A" out)
      (is (null (search "boom" out)) "~A" out))))

(test errors-are-re-signalled-not-swallowed
  ;; Observing a request must not change whether it failed -- Clack still decides the 500.
  (with-clean-quiet-paths
    (%log-capture :warn
                  (lambda ()
                    (signals cl:error
                      (funcall (hyperion/logging:wrap
                                (lambda (env) (declare (ignore env)) (error "boom")))
                               (%log-env "/hello")))))))

(test a-predicate-entry-works-not-just-a-string
  (with-clean-quiet-paths
    (hyperion/logging:register-quiet-path
     (lambda (path) (and (>= (length path) 8) (string= "/health/" (subseq path 0 8)))))
    (is (hyperion/logging:quiet-path-p "/health/live"))
    (is (not (hyperion/logging:quiet-path-p "/hello")))))

(test register-quiet-path-is-idempotent
  ;; wrap-dev registers on every build; repeated calls must not grow the list.
  (with-clean-quiet-paths
    (hyperion/logging:register-quiet-path "/api/ping")
    (hyperion/logging:register-quiet-path "/api/ping")
    (is (= 1 (length hyperion/logging:*quiet-paths*)))))

;;; --- the dev loop's own traffic -------------------------------------------

(test wrap-dev-registers-its-endpoints-as-quiet
  ;; The reported bug: hyperion's own poller flooding hyperion's own log, with no app-side
  ;; configuration available to stop it.
  (with-clean-quiet-paths
    (hyperion/dev:wrap-dev (%log-ok-app))
    (is (hyperion/logging:quiet-path-p "/api/reload-epoch"))
    (is (hyperion/logging:quiet-path-p "/api/dev-error"))
    (is (not (hyperion/logging:quiet-path-p "/")))))

(test the-dev-poller-produces-no-info-lines
  ;; End to end, at the level a dev REPL actually runs at.
  (with-clean-quiet-paths
    (let* ((app (hyperion/logging:wrap (hyperion/dev:wrap-dev (%log-ok-app))))
           (out (%log-capture :debug
                              (lambda ()
                                (funcall app (%log-env "/api/reload-epoch"))
                                (funcall app (%log-env "/api/dev-error"))))))
      (is (string= "" (string-trim '(#\Space #\Newline) out))))))

;;; --- the request start line logs the query's names, never its values (#1007) ---------

(defun %log-start-line (query)
  "What WRAP logs at DEBUG for a GET of /x with QUERY as its query string."
  (with-clean-quiet-paths
    (%log-capture :debug (lambda ()
                           (funcall (hyperion/logging:wrap (%log-ok-app))
                                    (list* :query-string query (%log-env "/x")))))))

(test the-start-line-logs-the-query-names-and-not-the-values
  ;; Not "abc", which the issue used: the line carries a random hex request id, and one run's id
  ;; (7e72abcfdde3187c) held "abc", so the check failed with the value nowhere in the line.
  (let ((out (%log-start-line "secret=hunter-two&page=2")))
    (is (search "request start" out) "~A" out)
    (is (search "secret" out) "the name: ~A" out)
    (is (search "page" out) "~A" out)
    (is (null (search "hunter" out)) "not the value: ~A" out)
    (is (null (search "query=" out)) "and no raw query field: ~A" out)))

(test query-keys-are-in-order-once-each-and-capped
  (is (equal '("page" "q") (hyperion/logging::%query-keys "page=1&q=x&page=2")))
  (multiple-value-bind (names bare) (hyperion/logging::%query-keys "flag&a+b=1&%C3%A9=2&=x&&")
    (is (equal '("a b" "é") names) "a part with no = is not named: ~S" names)
    (is (= 1 bare) "it is counted, and the empty parts are not: ~S" bare))
  (is (null (hyperion/logging::%query-keys "")))
  (is (null (hyperion/logging::%query-keys nil)))
  (let ((many (format nil "~{k~D=v~^&~}" (loop for i below 50 collect i))))
    (is (= 20 (length (hyperion/logging::%query-keys many))) "at most twenty names"))
  (let ((long (hyperion/logging::%query-keys (format nil "~A=1" (make-string 500 :initial-element #\n)))))
    (is (= 40 (length (first long))) "each cut to forty characters")))

(test a-query-part-with-no-equals-is-counted-and-never-named
  "The review of #1017: in /reset?<token>, the part with no = is usually a token, so the start
line counts it as bare-parts and does not name it. The control is the same text before an =,
where it is a name and is logged."
  (let ((out (%log-start-line "TOKENQWERTYZXCV&page=2")))
    (is (search "request start" out) "~A" out)
    (is (null (search "TOKENQWERTYZXCV" out)) "the bare part is not logged: ~A" out)
    (is (search "bare-parts" out) "it is counted: ~A" out)
    (is (search "page" out) "the other names still are: ~A" out))
  (let ((out (%log-start-line "TOKENQWERTYZXCV=1&page=2")))
    (is (search "TOKENQWERTYZXCV" out) "control: as a name it is logged: ~A" out)
    (is (null (search "bare-parts" out)) "and no bare part is counted: ~A" out))
  (is (equal '(nil 2) (multiple-value-list (hyperion/logging::%query-keys "AAAA&BBBB")))
      "two bare parts and no names"))

(test a-query-part-whose-value-is-empty-or-padding-is-counted-and-never-named
  "The second review of #1017: a base64 token ends in = padding, so it splits into a name and
a value of only =, and a token written as ?token= has an empty value. Both are counted as
bare-parts and not named. The control is a name with a real value, which is logged."
  (dolist (q '("dGhpcyBpcyBhIHNlY3JldCB0b2tlbg==" "abc123secret=" "QUJDREVGR0g="))
    (let ((out (%log-start-line q)))
      (is (search "bare-parts" out) "~S is counted: ~A" q out)
      (is (null (search (subseq q 0 (position #\= q)) out)) "~S is not named: ~A" q out)))
  (let ((out (%log-start-line "dGhpcyBpcyBhIHNlY3JldCB0b2tlbg=1")))
    (is (search "dGhpcyBpcyBhIHNlY3JldCB0b2tlbg" out)
        "control: with a real value the same text is a name, and is logged: ~A" out))
  (is (equal '(("page") 2)
             (multiple-value-list (hyperion/logging::%query-keys "x==&page=2&y=")))))

(test a-query-that-does-not-parse-is-logged-as-unparsed-with-no-text-from-it
  (dolist (q '("ab%zz=SECRETVALUE" "%E2%82=SECRETVALUE" "a%2=SECRETVALUE"))
    (is (eq :unparsed (hyperion/logging::%query-keys q)) "~S" q))
  (let ((out (%log-start-line "x%zz=SECRETVALUE")))
    (is (search "unparsed" out) "~A" out)
    (is (null (search "SECRETVALUE" out)) "~A" out)
    (is (null (search "x%zz" out)) "not even the name: ~A" out)))

;;; --- the path a log line records: the route's template, not a token in it (#1036) -----

(defparameter +log-marker+ "QZTOKENXQZWVKJMPQZ"
  "Stands for a token in a path. Upper case and with no hex digits after the first, so the
request id, which is hex, cannot hold it.")

(defun %log-routed (app path &key (method :get) query)
  "Everything WRAP logs at DEBUG for one request to APP, a Clack app, of PATH with QUERY. Errors
from APP are ignored after they are logged."
  (with-clean-quiet-paths
    (%log-capture :debug
                  (lambda ()
                    (ignore-errors
                     (funcall (hyperion/logging:wrap app)
                              (list* :request-method method
                                     :query-string query
                                     :request-uri (format nil "~A~@[?~A~]" path query)
                                     (cddr (%log-env path)))))))))

(test a-route-with-a-token-in-its-path-logs-the-template-not-the-token
  "The request log records the template of the route that answered, so a token in the path is
not written to the log. The query string is not logged either, on either line. Control: the same
route declared with :LOG-PATH :PATH logs the concrete path, so this test can see the marker when
it is there."
  (let* ((path (format nil "/reset/~A" +log-marker+))
         (query "t=QZQUERYVALUEQZ")
         (out (%log-routed (rt:to-app (rt:router (rt:route :get "/reset/:token" (%log-ok-app))))
                           path :query query)))
    (is (search "request start" out) "~A" out)
    (is (search "/reset/:token" out) "the template: ~A" out)
    (is (null (search +log-marker+ out)) "not the token: ~A" out)
    (is (null (search "QZQUERYVALUEQZ" out)) "not the query's value: ~A" out))
  (let* ((path (format nil "/reset/~A" +log-marker+))
         (out (%log-routed (rt:to-app (rt:router (rt:route :get "/reset/:token" (%log-ok-app)
                                                           :log-path :path)))
                           path :query "t=QZQUERYVALUEQZ")))
    (is (search +log-marker+ out) "control: with :log-path :path the path is logged: ~A" out)
    (is (null (search "/reset/:token" out)) "and not the template: ~A" out)
    (is (null (search "QZQUERYVALUEQZ" out)) "the query's value still is not: ~A" out)))

(test a-mounted-route-logs-the-template-with-the-mount-prefix
  (let ((out (%log-routed (rt:to-app
                           (rt:router
                            (rt:mount "/account"
                                      (rt:router (rt:route :post "/verify/:code" (%log-ok-app))))))
                          (format nil "/account/verify/~A" +log-marker+) :method :post)))
    (is (search "/account/verify/:code" out) "~A" out)
    (is (null (search +log-marker+ out)) "~A" out)))

(test a-failing-route-logs-its-template-on-the-failure-line
  (let ((out (%log-routed (rt:to-app (rt:router (rt:route :get "/invite/:token"
                                                          (lambda (env) (declare (ignore env))
                                                            (error "boom")))))
                          (format nil "/invite/~A" +log-marker+))))
    (is (search "request failed" out) "~A" out)
    (is (search "/invite/:token" out) "~A" out)
    (is (null (search +log-marker+ out)) "~A" out)))

(test an-unmatched-path-is-logged-cut-to-the-limit
  "A 404 has no template, so its path is logged, cut to +MAX-LOGGED-PATH-LENGTH+ characters. A
token in an unmatched path is still logged up to that length: this is the limit, and it is
known. Control: a short unmatched path is logged whole."
  (let* ((limit hyperion/logging:+max-logged-path-length+)
         (path (format nil "/reset/~A~A/extra" +log-marker+ +log-marker+))
         (out (%log-routed (rt:to-app (rt:router (rt:route :get "/reset/:token" (%log-ok-app))))
                           path)))
    (is (< limit (length path)) "the path is longer than the limit")
    (is (search "404" out) "a 404: ~A" out)
    (is (search (concatenate 'string (subseq path 0 limit) "...") out) "cut at ~D: ~A" limit out)
    (is (null (search (subseq path 0 (1+ limit)) out))
        "nothing past the first ~D characters: ~A" limit out))
  (let ((out (%log-routed (rt:to-app (rt:router)) "/favicon.ico")))
    (is (search "/favicon.ico" out) "control: ~A" out)
    (is (null (search "/favicon.ico..." out)) "not marked as cut: ~A" out)))

(test logged-path-outside-a-route-is-the-cut-path
  "The CSRF and rate-limit refusals log before any route is chosen, so they record the cut path."
  (let ((long (format nil "/a/~A~A" +log-marker+ +log-marker+)))
    (is (equal "/short" (hyperion/logging:logged-path (%log-env "/short"))))
    (is (= (+ 3 hyperion/logging:+max-logged-path-length+)
           (length (hyperion/logging:logged-path (%log-env long)))))))

(test a-route-refuses-an-unknown-log-path
  (signals rt:route-error (rt:route :get "/x" (%log-ok-app) :log-path :yes))
  (is (eq :template (rt:route-log-path (rt:route :get "/x" (%log-ok-app)))))
  (is (eq :path (rt:route-log-path (rt:route :get "/x" (%log-ok-app) :log-path :path)))))
