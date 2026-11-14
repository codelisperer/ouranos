;;;; tests.lisp --- the Ouranos IDE example, driven through its routes (#1218).
;;;;
;;;; No window and no browser are opened. Most tests call the Clack application directly, with
;;;; the request body already cached. The last one starts a real server on 127.0.0.1, makes
;;;; requests with dexador, and stops the server. The agent uses the stub provider throughout,
;;;; so no model is called and no key is read.

(cl:defpackage #:praxeon/examples/ouranos-ide/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:ide #:praxeon/examples/ouranos-ide)
                    (#:ui #:hyperion/desktop-ui)
                    (#:http #:hyperion/http)
                    (#:srv #:hyperion/server)
                    (#:ports #:hyperion/test-ports)
                    (#:repl #:cons/coalton-repl))
  (:export #:run-tests))

(cl:in-package #:praxeon/examples/ouranos-ide/tests)

(def-suite ouranos-ide :description "The Ouranos IDE proof of concept (#1218).")
(in-suite ouranos-ide)

(defun run-tests () (run! 'ouranos-ide))

(defmacro %with-ide ((app desktop) &body body)
  "BODY with DESKTOP bound to a new desktop holding the five windows and APP to its
application. The REPL session is new, and the database file is deleted afterwards. SETF and
not LET for the session, because cons/coalton-repl evaluates on a thread of its own."
  (let ((old (gensym "OLD")))
    `(let* ((,old ide::*session*)
            (,desktop (ui:make-desktop :title "Ouranos IDE"))
            (,app nil))
       (declare (ignorable ,desktop ,app))
       (setf ide::*session* (repl:make-session))
       (unwind-protect
            (progn (ide:build-desktop :desktop ,desktop)
                   (setf ,app (ide:make-app ,desktop))
                   ,@body)
         (ide::delete-database)
         (ignore-errors (delete-package (repl:session-package-name ide::*session*)))
         (setf ide::*session* ,old)))))

(defun %get (app path)
  (let ((response (funcall app (list :request-method :get :path-info path))))
    (values (apply #'concatenate 'string (third response)) (first response))))

(defun %post (app path &rest fields)
  "The body and status of POST PATH with the form FIELDS (name value ...), url-encoded."
  (let* ((body (format nil "~{~A=~A~^&~}" (mapcar #'quri:url-encode fields)))
         (response (funcall app (http:cache-body-string
                                 (list :request-method :post :path-info path) body))))
    (values (apply #'concatenate 'string (third response)) (first response))))

;;; --- the page ----------------------------------------------------------------------------

(test the-page-shows-the-five-windows
  (%with-ide (app desktop)
    (multiple-value-bind (body status) (%get app "/")
      (is (= 200 status))
      (dolist (id '("repl" "clock" "chart" "agent" "inspector"))
        (is (search (format nil "data-window=~A" id) (remove #\" body)) "window ~A is missing" id))
      (is (search "ide-clock" body) "the IDE's own styles are on the page"))
    (is (equal '("repl" "clock" "chart" "agent" "inspector")
               (getf (ui:inspect-desktop desktop) :windows)))))

;;; --- the REPL window ---------------------------------------------------------------------

(test a-coalton-definition-persists-to-the-next-input
  (%with-ide (app desktop)
    (let ((defined (%post app "/window/repl/action/eval"
                          "language" "coalton" "input" "(define (triple x) (* 3 x))")))
      (is (search "defined" defined) "answered: ~A" defined))
    (let ((value (%post app "/window/repl/action/eval" "language" "coalton" "input" "(triple 14)")))
      (is (search "42" value) "answered: ~A" value))
    (let ((transcript (mapcar #'ide:inspect-repl-entry
                              (ui:window-datum (ui:find-window desktop "repl") :transcript))))
      (is (equal '(:definition :value) (mapcar (lambda (e) (getf e :kind)) transcript)))
      (is (equal "42" (getf (second transcript) :value))))
    (is (search "(triple 14)" (%get app "/window/repl/body"))
        "the body rendered later holds the transcript")))

(test a-coalton-type-error-is-shown-and-the-repl-goes-on
  (%with-ide (app desktop)
    (is (search "ou-error" (%post app "/window/repl/action/eval"
                                  "language" "coalton" "input" "(+ 1 \"two\")")))
    (is (search "3" (%post app "/window/repl/action/eval" "language" "coalton" "input" "(+ 1 2)")))))

(test an-input-that-would-end-the-process-is-refused-in-both-languages
  (%with-ide (app desktop)
    (dolist (language '("coalton" "lisp"))
      (let ((body (%post app "/window/repl/action/eval" "language" language "input" "(sb-ext:exit)")))
        (is (search "was not evaluated" body) "~A answered: ~A" language body)))))

(test redefining-a-window-from-the-repl-changes-its-next-body
  "The claim of the proof of concept: a DEFUN sent to the REPL window, over the same routes
the page uses, changes what another window shows, with no restart and no change to the window."
  (%with-ide (app desktop)
    (let ((original (fdefinition 'ide:render-clock))
          (ide::*now* (lambda () (encode-universal-time 5 4 3 2 1 2027 0))))
      (unwind-protect
           (progn
             (is (search "03:04:05" (%get app "/window/clock/body")))
             (let ((answer (%post app "/window/repl/action/eval" "language" "lisp" "input"
                                  "(defun render-clock (window) (declare (ignore window)) \"<p>the clock was redefined</p>\")")))
               (is (search "RENDER-CLOCK" answer) "answered: ~A" answer))
             (is (string= "<p>the clock was redefined</p>" (%get app "/window/clock/body")))
             (is (search "the clock was redefined" (%get app "/")) "and on the whole page")
             (is (search "RENDER-CLOCK"
                         (getf (ui:inspect-window (ui:find-window desktop "clock")) :render))
                 "the window's record still names the same symbol"))
        (setf (fdefinition 'ide:render-clock) original))
      (is (search "03:04:05" (%get app "/window/clock/body")) "restored for the other tests"))))

(test a-window-can-be-added-from-the-repl
  (%with-ide (app desktop)
    (let ((ide:*desktop* desktop))
      (%post app "/window/repl/action/eval" "language" "lisp" "input"
             "(defun render-note (window) (declare (ignore window)) \"<p>a new window</p>\") (ui:open-window *desktop* \"note\" :title \"Note\" :render 'render-note)"))
    (is (string= "<p>a new window</p>" (%get app "/window/note/body")))
    (is (= 6 (length (ui:desktop-windows desktop))))))

;;; --- the clock ---------------------------------------------------------------------------

(test the-clock-shows-the-time-it-reads-and-asks-again-each-second
  (%with-ide (app desktop)
    (let ((ide::*now* (lambda () (encode-universal-time 59 58 23 31 12 2026 0))))
      (let ((body (%get app "/window/clock/body")))
        (is (search "23:58:59" body))
        (is (search "2026-12-31 UTC" body))))
    (is (search "every 1s" (%get app "/window/clock")))))

;;; --- the chart ---------------------------------------------------------------------------

(test the-chart-is-drawn-from-the-rows-sqlite-returns
  (%with-ide (app desktop)
    (is (equal '(("aion" . 4) ("cons" . 4) ("mnemosyne" . 9) ("elenchon" . 8)
                 ("hyperion" . 8) ("praxeon" . 7))
               (ide:chart-rows)))
    (is (probe-file ide::*database-path*) "the rows came from a file on disk")
    (let ((body (%get app "/window/chart/body")))
      (is (search "<svg" body))
      (is (= 6 (count-if (lambda (i) (string= "<rect" body :start2 i :end2 (+ i 5)))
                         (loop for i from 0 to (- (length body) 5) collect i)))
          "one bar per row")
      (is (search "mnemosyne" body))
      (is (search "width=\"180\"" body) "the longest name, nine letters, has the full width")
      (is (search "width=\"80\"" body) "a four-letter name has four ninths of it"))))

(test the-chart-follows-the-database
  "A row inserted after the first render is in the next one, so the chart reads the database
on every render and holds no copy."
  (%with-ide (app desktop)
    (is (null (search "hermes" (%get app "/window/chart/body"))))
    (mnemosyne/conn:with-connection (c (ide::%backend))
      (mnemosyne/query:run c '(:insert-into "frameworks"
                               :values ((:position 7 :name "hermes" :letters 6)))
                           :dialect :sqlite))
    (is (search "hermes" (%get app "/window/chart/body")))))

;;; --- the agent ---------------------------------------------------------------------------

(test the-agent-answers-from-the-stub-provider
  (%with-ide (app desktop)
    (multiple-value-bind (body status)
        (%post app "/window/agent/action/say" "text" "which windows are open?")
      (is (= 200 status))
      (is (search "which windows are open?" body) "the user's bubble")
      (is (search "stub provider" body) "the agent's bubble: ~A" body)
      (is (search "inspector" body) "the stub names the windows shown"))
    (is (typep (actor-provider) 'ide:stub-provider))
    (is (= 2 (length (ui:window-datum (ui:find-window desktop "agent") :transcript))))
    (is (search "which windows are open?" (%get app "/window/agent/body"))
        "the body rendered later holds the conversation")
    (is (= 2 (length (praxeon/actor:agent-history ide::*agent*)))
        "the turn went through praxeon's loop, which recorded both messages")))

(defun actor-provider () (praxeon/actor:agent-provider ide::*agent*))

(test the-agent-has-a-means-that-reads-the-desktop
  (%with-ide (app desktop)
    (ui:dispatch-event desktop "chart" hyperion/desktop-ui/state:close-event)
    (let ((answer (praxeon/actor:act ide::*agent* "list_windows" (make-hash-table :test 'equal))))
      (is (search "Windows: repl, clock, chart, agent, inspector." answer))
      (is (search "Shown: repl, clock, agent, inspector." answer)))))

;;; --- the inspector -----------------------------------------------------------------------

(test the-inspector-shows-a-window-s-record-and-its-data-without-the-objects-in-it
  (%with-ide (app desktop)
    (%post app "/window/clock/event" "type" "move" "x" "333" "y" "44")
    (let ((body (%post app "/window/inspector/action/select" "target" "clock")))
      (is (search "333" body))
      (is (search "RENDER-CLOCK" body)))
    (%post app "/window/repl/action/eval" "language" "coalton" "input" "(+ 1 2)")
    (let ((body (%post app "/window/inspector/action/select" "target" "repl")))
      (is (search "REPL-ENTRY" body) "a transcript entry is shown by its type")
      (is (null (search "(+ 1 2)" body)) "and not by its contents"))))

;;; --- over HTTP ---------------------------------------------------------------------------

(defun %status (thunk)
  "The status THUNK's request ended with, whether dexador returned or signalled."
  (handler-case (nth-value 1 (funcall thunk))
    (dex:http-request-failed (e) (dex:response-status e))))

(test the-ide-serves-over-http-on-loopback-and-refuses-a-post-from-another-origin
  (%with-ide (app desktop)
    (let* ((port nil)
           (handler (ports:call-with-port
                     (lambda (candidate)
                       (setf port candidate)
                       (srv:start app :server :hunchentoot :port candidate :host "127.0.0.1"
                                      :request-guard :same-origin :log nil))))
           (base (format nil "http://127.0.0.1:~D" port)))
      (unwind-protect
           (progn
             (multiple-value-bind (body status) (dex:get (format nil "~A/" base) :keep-alive nil)
               (is (= 200 status))
               (is (search "Ouranos IDE" body)))
             (is (search "ide-clock" (dex:get (format nil "~A/window/clock/body" base) :keep-alive nil)))
             (is (search "htmx" (dex:get (format nil "~A/" base) :keep-alive nil)) "the page loads htmx")
             (is (search "42"
                         (dex:post (format nil "~A/window/repl/action/eval" base) :keep-alive nil
                                   :headers `(("Origin" . ,base))
                                   :content '(("language" . "coalton") ("input" . "(* 6 7)"))))
                 "a POST from the page's own origin is evaluated")
             (is (= 403 (%status
                         (lambda ()
                           (dex:post (format nil "~A/window/repl/action/eval" base) :keep-alive nil
                                     :headers '(("Origin" . "http://example.test"))
                                     :content '(("language" . "lisp") ("input" . "(+ 1 2)"))))))
                 "a POST from another origin is refused")
             (is (= 403 (%status
                         (lambda ()
                           (dex:post (format nil "~A/window/repl/action/eval" base) :keep-alive nil
                                     :content '(("language" . "lisp") ("input" . "(+ 1 2)"))))))
                 "and so is a POST that names no origin"))
        (srv:stop handler)
        (is (ports:await-released port) "the server stopped")))))
