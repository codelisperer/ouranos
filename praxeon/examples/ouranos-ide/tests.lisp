;;;; tests.lisp --- the Ouranos IDE example, driven through its routes (#1218).
;;;;
;;;; No window and no browser are opened. Most tests call the Clack application directly, with
;;;; the request body already cached. Two start a real server on 127.0.0.1 and stop it: one
;;;; makes requests with dexador, and the other reads GET /events over a socket of its own.
;;;; The agent uses the stub provider throughout, so no model is called and no key is read.

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

(test the-clock-shows-the-time-it-reads-and-has-a-one-second-refresh-interval
  (%with-ide (app desktop)
    (let ((ide::*now* (lambda () (encode-universal-time 59 58 23 31 12 2026 0))))
      (let ((body (%get app "/window/clock/body")))
        (is (search "23:58:59" body))
        (is (search "2026-12-31 UTC" body))))
    (is (= 1 (ui:window-refresh (ui:find-window desktop "clock")))
        "the desktop's timer pushes the body every second; the page does not ask")
    (is (null (search "every 1s" (%get app "/window/clock"))))))

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

;;; --- the push feed, over HTTP ------------------------------------------------------------

(defun render-note (window)
  (format nil "<p>note ~A</p>" (ui:window-datum window :text "empty")))

(defun %desktop-threads (desktop)
  "The names of the live threads named for DESKTOP."
  (let ((title (ui:desktop-title desktop)))
    (loop for thread in (sb-thread:list-all-threads)
          for name = (sb-thread:thread-name thread)
          when (and name (search "desktop-ui" name) (search title name)) collect name)))

(defun %read-events (port)
  "Send GET /events to the server on PORT over a socket of its own and read the answer on a
thread. Returns three values: a function of no arguments that returns the text read so far,
with `<end>' added once the server has ended the stream; the reading thread; and the socket."
  (let* ((socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp))
         (lock (sb-thread:make-mutex :name "ouranos-ide test events"))
         (read-so-far (make-string-output-stream))
         (stream nil))
    (sb-bsd-sockets:socket-connect socket #(127 0 0 1) port)
    (setf stream (sb-bsd-sockets:socket-make-stream socket :input t :output t
                                                           :external-format :utf-8
                                                           :buffering :none))
    (format stream "GET /events HTTP/1.1~C~CHost: 127.0.0.1:~D~C~CAccept: text/event-stream~C~C~C~C"
            #\Return #\Newline port #\Return #\Newline #\Return #\Newline #\Return #\Newline)
    (finish-output stream)
    (values
     (lambda ()
       (sb-thread:with-mutex (lock)
         (let ((text (get-output-stream-string read-so-far)))
           (write-string text read-so-far)
           text)))
     (sb-thread:make-thread
      (lambda ()
        (ignore-errors
         (loop for line = (read-line stream nil)
               while line
               do (sb-thread:with-mutex (lock)
                    (write-line (string-right-trim '(#\Return) line) read-so-far))))
        (sb-thread:with-mutex (lock) (write-string "<end>" read-so-far))
        :returned)
      :name "ouranos-ide test events reader")
     socket)))

(defun %await (text needle &key (start 0) (timeout 10))
  "Wait until NEEDLE appears in what the function TEXT returns, at or after START. Returns
its position, or NIL after TIMEOUT seconds."
  (let ((deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
    (loop
      (let ((found (search needle (funcall text) :start2 start)))
        (when found (return found)))
      (when (> (get-internal-real-time) deadline) (return nil))
      (sleep 0.02))))

(test the-page-of-the-ide-has-no-polling-attribute
  (%with-ide (app desktop)
    (let ((page (%get app "/")))
      (is (search "data-window=clock" (remove #\" page)))
      (is (null (search "hx-trigger=every" (remove #\" page))))
      (is (null (search "every 1s" page)) "the clock and the inspector do not ask each second")
      (is (null (search "every 5s" page)) "the chart does not ask every five")
      (is (search "EventSource" page) "the page opens the event stream instead"))
    (is (null (search "every" (%get app "/window/clock"))))
    (is (null (search "every" (%get app "/window/inspector"))))
    (is (= 1 (getf (ui:inspect-window (ui:find-window desktop "clock")) :refresh))
        "the clock still has its interval, which the server's timer uses")))

(test start-does-not-log-a-request-that-succeeds
  ;; HYPERION/LOGGING:WRAP logs a successful request at :info unless the path is a quiet one,
  ;; and then at :trace. So the question is whether the path is quiet while the app runs.
  (let* ((quiet-inside :not-called)
         (app (lambda (env)
                (setf quiet-inside (hyperion/logging:quiet-path-p (getf env :path-info)))
                (list 200 '() '("ok"))))
         (env (list :request-method :get :path-info "/window/clock/body")))
    (let ((response (funcall (ide::%logged-quietly app) env)))
      (is (= 200 (first response)))
      (is (getf (second response) :x-request-id) "the request still gets its id"))
    (is (eq t (and quiet-inside t)) "under START's wrapper every path is a quiet one")
    (funcall app env)
    (is (null quiet-inside) "and without the wrapper this path is not, so it would be logged")
    (is (null (hyperion/logging:quiet-path-p "/window/clock/body"))
        "the wrapper changed nothing for other apps in the image")))

(test the-event-stream-pushes-changes-over-http-and-stop-ends-the-timer-and-the-streams
  (%with-ide (app desktop)
    (let* ((ide:*desktop* desktop)
           (port nil)
           (text nil) (reader nil) (socket nil))
      (unwind-protect
           (progn
             (ports:call-with-port
              (lambda (candidate) (setf port candidate) (ide:start :port candidate)))
             (is (null (%desktop-threads desktop)) "no page is connected, so no timer thread")
             (multiple-value-setq (text reader socket) (%read-events port))
             (is (%await text "text/event-stream") "the answer is an event stream")
             (is (%await text ": connected"))
             (sleep 0.3)
             (is (equal '("desktop-ui timer: Ouranos IDE") (%desktop-threads desktop))
                 "one timer thread while a page is connected")
             ;; A window opened from the REPL, with a page connected.
             (let ((mark (length (funcall text)))
                   (note nil))
               (setf note (ui:open-window desktop "note" :title "Note" :render 'render-note
                                                         :x 30 :y 40))
               (is (%await text "data: window note 360x240 left:30px;top:40px" :start mark)
                   "the page is told about the window without a reload")
               (is (%await text "data: html win-note-body" :start mark))
               (is (%await text "data: <p>note empty</p>" :start mark))
               ;; A change made outside a request, as a job would make it.
               (setf mark (length (funcall text)))
               (setf (ui:window-datum note :text) "from a job")
               (ui:window-changed note)
               (is (%await text "data: <p>note from a job</p>" :start mark)
                   "window-changed pushes the new body")
               ;; A close posted by a page.
               (setf mark (length (funcall text)))
               (let ((base (format nil "http://127.0.0.1:~D" port)))
                 (dex:post (format nil "~A/window/note/event" base) :keep-alive nil
                           :headers `(("Origin" . ,base)) :content '(("type" . "close"))))
               (is (%await text "data: remove note" :start mark) "a close removes the window")
               ;; The clock's refresh interval, with no request and no call.
               (setf mark (length (funcall text)))
               (let ((first (%await text "data: html win-clock-body" :start mark)))
                 (is-true first "the timer pushes the clock's body")
                 (is (%await text "data: html win-clock-body" :start (if first (1+ first) mark))
                     "and pushes it again a second later"))))
        (ide:stop)
        (when port
          (is (ports:await-released port) "the port is released"))
        (is (null (%desktop-threads desktop)) "no thread named for the desktop is left")
        (is (zerop (ui:desktop-subscribers desktop)) "no stream is being written")
        (when reader
          (is (eq :returned (sb-thread:join-thread reader :default :still-reading :timeout 5))
              "the server ended the page's stream")
          (is (search "<end>" (funcall text)))
          (when (sb-thread:thread-alive-p reader) (sb-thread:terminate-thread reader)))
        (when socket (ignore-errors (sb-bsd-sockets:socket-close socket)))))))
