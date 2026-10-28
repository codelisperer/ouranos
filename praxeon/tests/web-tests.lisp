;;;; web-tests.lisp --- praxeon/web's own suite.
;;;;
;;;; WHY THIS FILE EXISTS AT ALL, which is the finding behind pre-publication issue 151.
;;;;
;;;; `praxeon/web' exports a surface and NOTHING LOADED IT. `praxeon/tests' depends on
;;;; "praxeon" and "praxeon/web-search"; the two existing tests that mention praxeon/web
;;;; (pre-publication issue 139/pre-publication issue 218's backend-declaration pair) read its .asd with `asdf:find-system' rather
;;;; than loading the system -- which is why they pass without a handler in the image, and
;;;; why nobody noticed there was no suite underneath them.
;;;;
;;;; That absence is the reason elise's hand-rolled `(loop (sleep 3600))' survived. A layer
;;;; no suite loads cannot report that its consumers are working around it, and review does
;;;; not see absences.
;;;;
;;;; SEPARATE SYSTEM, NOT AN EXTRA FILE IN `praxeon/tests', because driving a real server
;;;; needs a real Clack handler, and WHICH HANDLER IS THE APPLICATION'S CHOICE (pre-publication issue 139,
;;;; ADR-0011, applied to praxeon/web by pre-publication issue 218). `praxeon/web' must keep declaring none. A
;;;; test system is an application for this purpose, so it declares hunchentoot -- the
;;;; backend that answers SIGTERM -- exactly as `praxeon/elise' does, and the core suite
;;;; stays free of an HTTP server it has no use for.

(cl:defpackage #:praxeon/web/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:web #:praxeon/web)
                    (#:srv #:hyperion/server)
                    (#:out #:hyperion/output)
                    (#:actor #:praxeon/actor)
                    (#:llm #:praxeon/llm)
                    (#:ceiling #:praxeon/ceiling))
  (:export #:praxeon-web))

(cl:in-package #:praxeon/web/tests)

(def-suite praxeon-web :description "praxeon/web: the blocking entry, and the surface.")
(in-suite praxeon-web)

;;; --- helpers ---------------------------------------------------------------
;;;
;;; The same shape as hyperion/tests/server-tests.lisp's. Deliberately not shared: that file
;;; belongs to another system's test suite, and reaching into it would make this system's
;;; suite depend on hyperion's being loaded.

(defun free-port ()
  "An unused TCP port, obtained by binding one and letting go."
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (progn (setf (sb-bsd-sockets:sockopt-reuse-address s) t)
                (sb-bsd-sockets:socket-bind s #(127 0 0 1) 0)
                (nth-value 1 (sb-bsd-sockets:socket-name s)))
      (ignore-errors (sb-bsd-sockets:socket-close s)))))

(defun listening-p (port)
  "True if something accepts a TCP connection on PORT right now."
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (handler-case (progn (sb-bsd-sockets:socket-connect s #(127 0 0 1) port) t)
           (error () nil))
      (ignore-errors (sb-bsd-sockets:socket-close s)))))

(defun await (predicate &key (timeout 10) (interval 0.02))
  "Poll PREDICATE until true or TIMEOUT seconds elapse. Returns what it last saw."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop for v = (funcall predicate)
          when v return v
          when (> (get-internal-real-time) deadline) return nil
          do (sleep interval))))

(defun quiet-agent ()
  "An agent that never reaches a model. These tests are about the ENTRY POINT -- whether it
blocks, serves and stops -- so a turn that called out would only add a network dependency to
a question that has nothing to do with the network."
  (actor:make-agent :name "web-suite"))

;;; --- the blocking entry ----------------------------------------------------

(test serve-forever-blocks-serves-and-stops-on-request
  ;; The claim pre-publication issue 151 turns on. `praxeon/web:serve-forever' must actually BLOCK (so it is a
  ;; usable `main'), actually SERVE (so it is not just sleeping), and RETURN when asked (so
  ;; the hand-roll it replaces is not needed). All three, because the hand-rolled version
  ;; satisfied the first two and failed only the third.
  (let* ((port (free-port))
         (session nil)
         (ready (sb-thread:make-semaphore :name "px-web-ready"))
         (returned nil)
         (banner (make-string-output-stream))
         (thread (sb-thread:make-thread
                  (lambda ()
                    (let ((*standard-output* banner))
                      (web:serve-forever
                       :agent (quiet-agent) :agent-name "Test Agent"
                       :port port :log nil
                       :on-ready (lambda (s)
                                   (setf session s)
                                   (sb-thread:signal-semaphore ready)))
                      ;; Reached only if it RETURNED rather than being killed.
                      (setf returned t)))
                  :name "praxeon-web-test-server")))
    (unwind-protect
         (progn
           (is (sb-thread:wait-on-semaphore ready :timeout 10)
               "praxeon/web:serve-forever never became ready")
           (is (srv:server-session-p session)
               "on-ready did not receive a server session")
           ;; Poll: on-ready fires when START returns, i.e. when the handler exists. Clack
           ;; runs the backend on its own thread, so the socket can be a moment behind.
           (is (await (lambda () (listening-p port)))
               "nothing was accepting connections on the port it said it was serving")
           ;; IT WAS STILL BLOCKED. Without this the test would pass against a function
           ;; that started a server and returned immediately -- which is `start', not
           ;; `serve-forever', and is the whole difference between them.
           (is-false returned "serve-forever returned while it was supposed to be blocking")
           (web:request-shutdown session)
           (is (await (lambda () (not (listening-p port))))
               "the port was not released after request-shutdown")
           (sb-thread:join-thread thread :timeout 10)
           (is-true returned "serve-forever did not return after request-shutdown"))
      (when session (ignore-errors (web:request-shutdown session)))
      (ignore-errors (sb-thread:join-thread thread :timeout 10)))
    ;; The banner is the operator's only signal that the app came up, and :name defaults to
    ;; AGENT-NAME rather than to Praxeon -- an app called Elise should not announce itself
    ;; as something else.
    (let ((text (get-output-stream-string banner)))
      (is (search "Test Agent" text)
          "the banner did not carry the agent's name: ~S" text)
      (is (search (princ-to-string port) text)
          "the banner did not name the port actually bound: ~S" text))))

;;; --- the surface -----------------------------------------------------------

(test the-blocking-entry-and-its-stop-are-both-exported
  ;; A blocking entry without the thing that stops it is half a surface: an app that has
  ;; SERVE-FOREVER and not REQUEST-SHUTDOWN still has to reach past praxeon/web into
  ;; hyperion/server, which is the reaching this was added to remove.
  (dolist (name '("SERVE-FOREVER" "REQUEST-SHUTDOWN" "START" "STOP" "MAKE-APP"))
    (multiple-value-bind (symbol status) (find-symbol name (find-package "PRAXEON/WEB"))
      (is (eq status :external)
          "praxeon/web does not export ~A (status ~S)" name status)
      (is-true (fboundp symbol) "praxeon/web:~A is exported but not fbound" name))))

;;; --- calling the app as a server would ----------------------------------------
;;;
;;; The surface tests below call the Clack app with an env they build, rather than over a
;;; socket: the property under test is what the app answers, and a server would add a port and
;;; a thread to every one of them.

(defun %call (app method path &key query json form authorization headers)
  "Call APP, a Clack app, with a request for METHOD and PATH, and return (values STATUS HEADERS
BODY). QUERY is the query string. JSON or FORM, a string, is the body, sent as application/json
or as a urlencoded form. AUTHORIZATION is the Authorization header's value, and HEADERS an alist
of other request headers by lowercase name. A streamed BODY, a function of a writer, is returned
as it is."
  (let* ((headers (let ((h (make-hash-table :test 'equal)))
                    (when authorization (setf (gethash "authorization" h) authorization))
                    (loop for (name . value) in headers do (setf (gethash name h) value))
                    h))
         (env (list :request-method method :path-info path :query-string query
                    :headers headers
                    :content-type (cond (json "application/json")
                                        (form "application/x-www-form-urlencoded")))))
    (when (or json form)
      (setf env (hyperion/http:cache-body-string env (or json form))))
    (destructuring-bind (status hdrs body) (funcall app env)
      (values status hdrs (if (functionp body) body (format nil "~{~A~}" body))))))

(defun %echo-app (&rest keys)
  "An app whose turn answers \"echo: MESSAGE\" and fails for the message \"fail\". KEYS go to
MAKE-APP."
  (apply #'web:make-app
         :agent-name "Echo"
         :responder (lambda (agent message locale)
                      (declare (ignore agent locale))
                      (if (string= message "fail")
                          (error "the responder failed")
                          (format nil "echo: ~A" message)))
         keys))

(defun %say (app text &key query)
  "Send TEXT through APP's JSON path, which runs the turn before it answers. Returns the status."
  (values (%call app :post "/api/message" :query query
                 :json (format nil "{\"message\":\"~A\"}" text))))

(defun %poll (app after &key query)
  "The body of a poll of APP from cursor AFTER (none when NIL). QUERY is added to the query
string."
  (nth-value 2 (%call app :get "/api/progress"
                      :query (format nil "~@[after=~D~]~:[~;&~]~@[~A~]"
                                     after (and after query) query))))

(defun %sends-the-cursor-p (html)
  "Whether HTML has an hx-include of #px-cursor, quoted or not."
  (let ((at (search "hx-include=" html)))
    (and at
         (let ((v (+ at (length "hx-include="))))
           (when (and (< v (length html)) (char= (char html v) #\")) (incf v))
           (eql v (search "#px-cursor" html :start2 v))))))

(defun %cursor-value-in (html)
  "The value of HTML's px-cursor field, \"EPOCH:INDEX\", or NIL. Spinneret leaves an attribute
value unquoted when it can, so the value is read after `value=' with or without a quote."
  (let* ((at (search "px-cursor" html))
         (v (and at (search "value=" html :start2 at)))
         (start (and v (+ v 6))))
    (when (and start (< start (length html)) (char= (char html start) #\"))
      (incf start))
    (and start (subseq html start (position-if (lambda (c) (find c "\" >")) html :start start)))))

(defun %cursor-in (html)
  "The index in HTML's px-cursor field, or NIL."
  (let* ((value (%cursor-value-in html))
         (colon (and value (position #\: value))))
    (and value (parse-integer value :start (if colon (1+ colon) 0) :junk-allowed t))))

(defun %epoch-in (html)
  "The epoch in HTML's px-cursor field, or NIL."
  (let* ((value (%cursor-value-in html))
         (colon (and value (position #\: value))))
    (and colon (subseq value 0 colon))))

;;; --------------------------------------------------------------------------
;;; The output style is the app's, not the image's (pre-publication issue 469)
;;; --------------------------------------------------------------------------

(in-suite praxeon-web)

(defun %bubble-from-turn (style)
  "Run one turn through an app rendering in STYLE and return the poll that shows its reply.

Since #67 the turn publishes items and the poll renders them, on the request thread, inside the
app's own dispatcher. So this goes through the app: that dispatcher is where the style is bound,
and calling the renderer directly would test a binding the test made itself."
  (let* ((app (%echo-app :dev (eq style :pretty)))
         (poll (progn (%say app "hi") (%poll app 0)))
         (start (search "<article class=\"message px-assistant\"" poll))
         (end (and start (search "</article>" poll :start2 start))))
    ;; Only the reply's bubble: the rest of the poll is fragments joined end to end, which are
    ;; adjacent in either style.
    (if end (subseq poll start (+ end (length "</article>"))) "")))

(test starting-the-surface-does-not-change-the-image-s-output-style
  "pre-publication issue 469. praxeon/web can be started as a SECOND server inside a host app's image, so it must
not publish its own rendering choice to the global every Spinneret renderer in that image
reads. Before the fix `%build-app' did `(setf out:*output-style* ...)' and the host's
rendering changed for the rest of the process."
  ;; `%build-app', NOT `make-app'. The assignment lived in the former, which is what `start'
  ;; and `serve-forever' call; `make-app' never had it. The first version of this test called
  ;; `make-app' and passed with the defect fully restored -- a test that could not fail,
  ;; written for the fix, and found only by running the control.
  ;; EACH CASE PICKS AN IMAGE STYLE THE DEFECT WOULD OVERWRITE. Asserting :pretty survives a
  ;; :dev build is worthless -- the defect writes :pretty there, so that assertion passes with
  ;; the bug fully present. Measured: under the reverted fix this test failed `f.\', one of two.
  ;; So the non-dev case runs against a :pretty image and the dev case against a :compact one.
  (let ((out:*output-style* :pretty))
    (web::%build-app nil "Guest" "Guest" #'identity nil nil nil nil nil nil nil nil nil nil nil nil :poll)
    (is (eq :pretty out:*output-style*)
        "a :pretty host survives a non-dev agent surface, which the defect would set :compact"))
  (let ((out:*output-style* :compact))
    (web::%build-app nil "Guest" "Guest" #'identity nil nil t nil nil nil nil nil nil nil nil nil :poll)
    (is (eq :compact out:*output-style*)
        "and a :compact host survives a :dev one, which the defect would set :pretty")))

(test the-poll-renders-the-reply-in-the-app-s-style
  "The reply is rendered by the poll that reads it, inside the app's WITH-OUTPUT-STYLE. Before
#67 it was rendered on the turn thread, which that binding does not reach, and pre-publication
issue 469 carried the style to the turn thread for that reason. A reply rendered in the wrong
style shows only in the poller, only for the assistant, and as whitespace rather than as an
error."
  (let ((out:*output-style* :compact))   ; the image says compact; the app will say otherwise
    (let ((pretty (%bubble-from-turn :pretty))
          (compact (%bubble-from-turn :compact)))
      (is (string/= pretty compact)
          "the two styles must actually differ, or neither assertion below means anything")
      ;; ELEMENT ADJACENCY, not newline presence. The first version of this asserted that a
      ;; compact bubble had no newline and failed: the markdown body emits one of its own,
      ;; independent of Spinneret. Newlines were a proxy for the property; `><' between two
      ;; tags is the property -- compact puts elements adjacent, pretty separates them.
      (is (search "><div" compact)
          "a :compact app renders the reply's elements adjacent: ~S" compact)
      (is (not (search "><div" pretty))
          "and a :pretty app separates them, so the first is not merely always-true: ~S" pretty))))

;;; --------------------------------------------------------------------------
;;; The token counter counts all four token counts (part of #161)
;;; --------------------------------------------------------------------------
;;;
;;; Driven through a real turn: `%run-turn-async' installs the counter as the turn's observer,
;;; the default responder runs `actor:run-turn', and a provider answers with a completion that
;;; carries the counts. So the numbers reach the counter by the same route as in the app.

(defclass counted-provider (llm:provider)
  ((completion :initarg :completion :reader counted-provider-completion))
  (:documentation "A provider that answers with a completion the test built, counts and all."))

(defmethod llm:complete ((p counted-provider) messages
                         &key system tools max-tokens temperature tool-choice)
  (declare (ignore messages system tools max-tokens temperature tool-choice))
  (counted-provider-completion p))

(defun %tokens-after-turn (completion)
  "Run one web turn whose provider answers with COMPLETION. Return the conversation's total
and this turn's count, as the page would show them."
  (let ((conv (web::make-conversation
               :agent (actor:make-agent
                       :name "counted"
                       :provider (make-instance 'counted-provider :completion completion)))))
    ;; Bounded, with no :default, so a hung turn signals JOIN-THREAD-ERROR and fails the
    ;; test that ran it by name, instead of hanging the whole gate (the bound #177 uses).
    (sb-thread:join-thread (web::%run-turn-async conv "hi" nil) :timeout 20)
    (values (web::%get-tokens conv) (web::%get-turn-tokens conv))))

(test the-counter-includes-cache-tokens
  "A turn that reported 100 input, 20 output, 900 cache-read and 7 cache-write tokens processed
1027 tokens. Before this change the counter showed 120, so a turn served mostly from the cache
looked nearly free."
  (multiple-value-bind (total turn)
      (%tokens-after-turn (llm:make-completion :text "ok" :stop-reason :end
                                               :input-tokens 100 :output-tokens 20
                                               :cache-read-tokens 900 :cache-write-tokens 7))
    (is (= 1027 total) "the conversation total counted ~D tokens, not 1027" total)
    (is (= 1027 turn) "this turn counted ~D tokens, not 1027" turn)))

(test a-turn-reporting-only-cache-tokens-is-counted
  "A completion that reports only cache counts emits a :usage event since #179. The counter
used to add nothing for it, so the page showed no count at all."
  (is (= 512 (%tokens-after-turn (llm:make-completion :text "ok" :stop-reason :end
                                                      :cache-read-tokens 512)))))

(test a-turn-without-cache-tokens-counts-as-before
  "The control: with no cache counts reported, the counter is input plus output, as it was."
  (is (= 120 (%tokens-after-turn (llm:make-completion :text "ok" :stop-reason :end
                                                      :input-tokens 100 :output-tokens 20)))))

;;; --------------------------------------------------------------------------
;;; A javascript: link in a chat message does not become an href (#66)
;;; --------------------------------------------------------------------------
;;;
;;; The bubbles put the rendered Markdown into the page raw, so this is where a script URL
;;; would reach a viewer. hyperion/tests covers the renderer itself; this asserts it where the
;;; chat uses it, for both the user's bubble and the model's.

(test a-javascript-link-in-a-chat-message-is-not-an-href
  (dolist (html (list (web::%user-bubble "look [here](javascript:alert(1)) and [there](https://example.com)")
                      (web::%assistant-bubble "Model" "look [here](javascript:alert(1)) and [there](https://example.com)")))
    (is (null (search "href=\"javascript" html)) "a javascript: href reached the bubble: ~S" html)
    (is (null (search "javascript:" html)) "the script URL must not appear at all: ~S" html)
    (is (search "href=\"https://example.com\"" html)
        "the ordinary link beside it must still render, or the test proves nothing: ~S" html)))

;;; --------------------------------------------------------------------------
;;; A web turn logs with the request's context (#160)
;;; --------------------------------------------------------------------------
;;;
;;; `%run-turn-async' runs the turn on its own thread, and a LET binding does not cross a
;;; thread, so without `aion/dynamic:inheriting' every line the turn logs would lack the
;;; request id -- with nothing reporting the absence. This drives a real turn whose provider
;;; fails, so the line under test is the one an operator most needs to trace: "llm request
;;; failed", logged by LLM:COMPLETE's :around on the TURN thread.

(defclass %failing-provider (llm:provider) ()
  (:documentation "A provider whose every request fails, so the turn logs the failure."))

(defmethod llm:complete ((p %failing-provider) messages
                         &key system tools max-tokens temperature tool-choice)
  (declare (ignore messages system tools max-tokens temperature tool-choice))
  (error "the provider is unavailable"))

(defun %logged-lines-containing (text output)
  (remove-if-not (lambda (line) (search text line))
                 (uiop:split-string output :separator '(#\Newline))))

(test a-web-turn-logs-with-the-request-s-context
  (let ((out (make-string-output-stream))
        (conv (web::make-conversation
               :agent (actor:make-agent :name "failing"
                                        :provider (make-instance '%failing-provider)))))
    (unwind-protect
         (progn
           (aion/log:setup :env :dev :level :warn :stream out)
           (aion/log:with-context (:request-id "req-160" :conversation "conv-160")
             (aion/test-threads:join (web::%run-turn-async conv "hi" nil)))
           (let ((lines (%logged-lines-containing "llm request failed"
                                                  (get-output-stream-string out))))
             (is (= 1 (length lines))
                 "the turn thread should log the provider failure once, got ~S" lines)
             (is (every (lambda (l) (search "request-id=req-160" l)) lines)
                 "the turn thread's line must carry the request id: ~S" lines)
             (is (every (lambda (l) (search "conversation=conv-160" l)) lines)
                 "and the rest of the request's context: ~S" lines)))
      (aion/log:setup :env :dev :level :warn :stream *standard-output*))))

;;; --------------------------------------------------------------------------
;;; The transcript channel and the conversation key (#67)
;;; --------------------------------------------------------------------------
;;;
;;; Each conversation publishes its transcript to a hyperion/channel, and each page reads it
;;; from its own cursor. These tests drive the app's routes. The JSON path runs the turn before
;;; it answers, so a poll right after it sees the whole turn without waiting on a thread.

(test two-readers-of-one-conversation-both-see-every-item
  "The progress poll used to drain a mailbox, so of two tabs on one conversation, whichever polled
first took the bubble and the other never showed it. Two polls from the same cursor now return
the same items."
  (let ((app (%echo-app)))
    (%say app "hello")
    (let ((first (%poll app 0))
          (second (%poll app 0)))
      (is (search "echo: hello" first) "the first reader did not get the reply: ~S" first)
      (is (search "echo: hello" second) "the second reader did not get the reply: ~S" second)
      (is (search "hello</p>" second)
          "the second reader did not get the user's message: ~S" second))))

(test a-poll-moves-the-cursor-past-what-it-returned
  "A poll's response sets the page's cursor past the items it returned, so the next poll returns
only what was published after them."
  (let ((app (%echo-app)))
    (%say app "one")
    (let* ((first (%poll app 0))
           (next (%cursor-in first)))
      ;; One turn is three items: the message, the reply and the end of the turn.
      (is (eql 3 next) "after one turn the cursor should be 3, not ~S" next)
      (let ((again (%poll app next)))
        (is (null (search "echo:" again)) "a poll at the cursor repeated the reply: ~S" again)
        (is (eql 3 (%cursor-in again)) "and left the cursor where it was: ~S" again))
      (%say app "two")
      (let ((after (%poll app next)))
        (is (search "echo: two" after) "the next turn's reply is missing: ~S" after)
        (is (null (search "echo: one" after)) "the earlier reply was repeated: ~S" after)
        (is (eql 6 (%cursor-in after)) "the cursor should now be 6: ~S" after)))))

(test a-poll-without-a-cursor-returns-no-items-and-sets-one
  "A page loaded before the cursor existed polls with no `after'. It gets no items, so its
transcript is not repeated, and a cursor at the newest item, so it carries on from there."
  (let ((app (%echo-app)))
    (%say app "hello")
    (let ((body (%poll app nil)))
      (is (null (search "echo: hello" body)) "items were returned without a cursor: ~S" body)
      (is (eql 3 (%cursor-in body)) "the cursor should be set to 3: ~S" body))))

(test every-turn-ends-with-one-turn-ended-item
  "Each turn publishes exactly one :TURN-ENDED item after its reply, :OK when the responder
returned and :ERROR, with the error's text, when it signalled. The error shows in the agent's
bubble, as before."
  (let ((conv (web::make-conversation
               :agent-name "Echo"
               :responder (lambda (agent message locale)
                            (declare (ignore agent locale))
                            (if (string= message "fail")
                                (error "the responder failed")
                                (format nil "echo: ~A" message))))))
    (is (equal '("echo: hi" nil) (multiple-value-list (web::%turn conv "hi" nil)))
        "a turn that returned gives its reply and no error")
    (multiple-value-bind (reply e) (web::%turn conv "fail" nil)
      (is (null reply) "a turn that failed gives no reply")
      (is (typep e 'error) "and gives the error: ~S" e))
    (let ((items (web::%items-since conv 0)))
      (is (equal '(:user :assistant :turn-ended :user :turn-ended)
                 (mapcar (lambda (i) (getf i :kind)) items))
          "the items were ~S" items)
      (is (equal '(:ok :error)
                 (loop for i in items
                       when (eq (getf i :kind) :turn-ended) collect (getf i :outcome)))
          "the outcomes were wrong: ~S" items)
      (is (search "the responder failed" (web::%items-html conv items))
          "the error is not in the agent's bubble"))))

(test the-json-path-answers-500-for-a-turn-that-failed
  (let ((app (%echo-app)))
    (is (eql 200 (%say app "hello")))
    (is (eql 500 (%say app "fail")))))

(test the-page-shows-the-transcript-and-a-cursor-past-it
  "GET / renders the transcript and the cursor from one read of the channel, so a poll from that
cursor does not repeat what the page shows."
  (let ((app (%echo-app)))
    (%say app "hello")
    (let ((page (nth-value 2 (%call app :get "/"))))
      (is (search "echo: hello" page) "the page does not show the reply: ~S" page)
      (is (eql 3 (%cursor-in page)) "the page's cursor should be 3")
      (is-true (%sends-the-cursor-p page) "the poll does not send the cursor")
      (is (null (search "echo: hello" (%poll app (%cursor-in page))))
          "a poll from the page's cursor repeated the reply"))))

(test an-agent-s-earlier-history-is-shown
  "An agent that arrives with a history starts its conversation's transcript with it, without the
tool calls, so the page shows it as it did before the channel."
  (let* ((agent (actor:make-agent
                 :name "restored"
                 :history (list (llm:msg "user" "earlier question")
                                (llm:msg "assistant" "earlier answer"))))
         (app (web:make-app :agent agent :agent-name "Restored"))
         (page (nth-value 2 (%call app :get "/"))))
    (is (search "earlier question" page) "the user's earlier message is missing")
    (is (search "earlier answer" page) "the earlier reply is missing")
    (is (eql 2 (%cursor-in page)) "the cursor should be past the two earlier items")))

(test an-htmx-message-is-published-and-asks-the-page-to-poll
  "POST /api/message from the page returns nothing to swap and an HX-Trigger of px-poll. The
user's message is already in the channel when it answers, so that poll shows it."
  (let ((app (%echo-app)))
    (multiple-value-bind (status headers body)
        (%call app :post "/api/message" :form "message=hey")
      (is (eql 200 status))
      (is (equal "px-poll" (getf headers :hx-trigger)) "no HX-Trigger: ~S" headers)
      (is (string= "" body) "the POST returned something to swap: ~S" body))
    (is (search "hey</p>" (%poll app 0)) "the user's message was not published")
    (is (await (lambda () (search "echo: hey" (%poll app 0))))
        "the reply from the background turn never arrived")))

(defun %keyed-app (made)
  "An echo app with one conversation per `who' query parameter. MADE is a one-element list whose
car counts the agents made."
  (%echo-app :conversation-key (lambda (env) (hyperion/http:query-param env "who"))
             :make-agent (lambda (key)
                           (incf (car made))
                           (actor:make-agent :name key))))

(test each-key-has-its-own-conversation
  "With :CONVERSATION-KEY, requests with one key share a conversation and requests with another
key do not see it. One agent is made per key."
  (let* ((made (list 0))
         (app (%keyed-app made)))
    (%say app "from-a" :query "who=a")
    (%say app "from-b" :query "who=b")
    (let ((a (%poll app 0 :query "who=a"))
          (b (%poll app 0 :query "who=b")))
      (is (search "echo: from-a" a) "a's conversation is missing its reply: ~S" a)
      (is (null (search "from-b" a)) "a sees b's conversation: ~S" a)
      (is (search "echo: from-b" b) "b's conversation is missing its reply: ~S" b)
      (is (null (search "from-a" b)) "b sees a's conversation: ~S" b))
    (%say app "again" :query "who=a")
    (is (search "echo: again" (%poll app 3 :query "who=a"))
        "a second request with key a did not reach a's conversation")
    (is (= 2 (car made)) "one agent per key should have been made, not ~D" (car made))))

(test a-request-without-a-key-is-refused
  (let ((app (%keyed-app (list 0))))
    (is (eql 403 (nth-value 0 (%call app :get "/"))))
    (is (eql 403 (nth-value 0 (%call app :get "/api/progress" :query "after=0"))))
    (is (eql 403 (%say app "hello")))))

(test make-app-refuses-a-key-it-cannot-serve
  "An agent holds one conversation's history, so :CONVERSATION-KEY needs :MAKE-AGENT, and neither
goes with a single :AGENT."
  (signals error (web:make-app :conversation-key (lambda (env) (declare (ignore env)) "k")))
  (signals error (web:make-app :make-agent (lambda (k) (actor:make-agent :name k))))
  (signals error (web:make-app :agent (actor:make-agent :name "one")
                               :conversation-key (lambda (env) (declare (ignore env)) "k")
                               :make-agent (lambda (k) (actor:make-agent :name k)))))

;;; --------------------------------------------------------------------------
;;; Signed grants open sessions (#67 step two)
;;; --------------------------------------------------------------------------
;;;
;;; A service made with :GRANT-VERIFIER takes a grant at POST /embed/session and answers a
;;; session id, and every other route needs that id in `Authorization: Session <id>'. These
;;; tests mint real Ed25519 grants with `aion/signature'; none of them uses a verifier that
;;; accepts everything, because a test whose verifier always says yes cannot see a forgery.

(defun %grant-token (private-key &key (principal "p1") (audience "svc") (expires-in 120)
                                      (capabilities '("search")))
  (let ((o (make-hash-table :test 'equal)))
    (setf (gethash "principal" o) principal
          (gethash "group" o) "g1"
          (gethash "capabilities" o) (coerce capabilities 'vector)
          (gethash "token_cap" o) 1000
          (gethash "call_cap" o) 10
          (gethash "expires_at" o) (+ (get-universal-time) expires-in)
          (gethash "audience" o) audience)
    (ceiling:encode-grant-token (com.inuoe.jzon:stringify o) private-key)))

(defun %grant-app (public-key &rest keys &key (made (list nil)) &allow-other-keys)
  "An echo app that takes grants for audience \"svc\". MADE is a one-element list; the car
collects (principal . grant) for each agent made."
  (remf keys :made)
  (apply #'%echo-app
         :grant-verifier (ceiling:make-ed25519-verifier public-key)
         :audience "svc"
         :make-agent (lambda (principal grant)
                       (push (cons principal grant) (car made))
                       (actor:make-agent :name principal))
         keys))

(defun %open (app token)
  "POST TOKEN to APP's /embed/session. Returns (values STATUS SESSION-ID-or-NIL BODY)."
  (multiple-value-bind (status headers body)
      (%call app :post "/embed/session" :authorization (format nil "Grant ~A" token))
    (declare (ignore headers))
    (values status
            (and (eql status 200) (gethash "session" (com.inuoe.jzon:parse body)))
            body)))

(test a-grant-opens-a-session-that-reaches-the-principal-s-conversation
  (multiple-value-bind (priv pub) (aion/signature:generate-key-pair)
    (let* ((made (list nil))
           (app (%grant-app pub :made made)))
      (multiple-value-bind (status session) (%open app (%grant-token priv))
        (is (eql 200 status))
        (is (and (stringp session) (= 64 (length session)))
            "the session id should be 256 bits as hex: ~S" session)
        (let ((auth (format nil "Session ~A" session)))
          (is (eql 200 (nth-value 0 (%call app :post "/api/message" :authorization auth
                                           :json "{\"message\":\"hi\"}"))))
          (is (search "echo: hi" (nth-value 2 (%call app :get "/api/progress" :query "after=0"
                                                     :authorization auth)))
              "the session's conversation does not show the turn")
          (is (equal '("p1") (mapcar #'car (car made))) "one agent, for the grant's principal")
          (is (equal '("search") (ceiling:grant-capabilities (cdr (first (car made)))))
              "the agent was made with the grant, so its means can follow the capabilities"))))))

(test a-route-without-an-open-session-is-refused-401
  (multiple-value-bind (priv pub) (aion/signature:generate-key-pair)
    (declare (ignore priv))
    (let ((app (%grant-app pub)))
      (is (eql 401 (nth-value 0 (%call app :get "/"))) "no Authorization header")
      (is (eql 401 (nth-value 0 (%call app :get "/api/progress" :query "after=0"
                                       :authorization "Session not-a-session"))))
      (is (eql 401 (nth-value 0 (%call app :post "/api/message" :json "{\"message\":\"hi\"}"
                                       :authorization "Bearer x")))
          "a header with another scheme"))))

(test a-grant-that-does-not-verify-opens-no-session
  "Each case names why it was refused, in the 401's body."
  (multiple-value-bind (priv pub) (aion/signature:generate-key-pair)
    (let ((app (%grant-app pub))
          (other (aion/signature:generate-key-pair)))
      (flet ((refused (token reason)
               (multiple-value-bind (status session body) (%open app token)
                 (is (eql 401 status) "~A: status ~S" reason status)
                 (is (null session) "~A: a session was opened" reason)
                 (is (search reason body) "~A: the body was ~S" reason body))))
        (refused (%grant-token other) "signature does not verify")
        (refused (%grant-token priv :expires-in -10) "expired")
        (refused (%grant-token priv :audience "another-service") "audience")
        (refused (%grant-token priv :principal "") "no principal")
        (refused "not a token" "base64url")))))

(test two-principals-have-two-conversations
  (multiple-value-bind (priv pub) (aion/signature:generate-key-pair)
    (let* ((app (%grant-app pub))
           (a (format nil "Session ~A" (nth-value 1 (%open app (%grant-token priv :principal "a")))))
           (b (format nil "Session ~A" (nth-value 1 (%open app (%grant-token priv :principal "b")))))
           (a2 (format nil "Session ~A" (nth-value 1 (%open app (%grant-token priv :principal "a"))))))
      (%call app :post "/api/message" :authorization a :json "{\"message\":\"from-a\"}")
      (let ((seen-by-b (nth-value 2 (%call app :get "/api/progress" :query "after=0" :authorization b)))
            (seen-by-a2 (nth-value 2 (%call app :get "/api/progress" :query "after=0" :authorization a2))))
        (is (null (search "from-a" seen-by-b)) "b sees a's conversation: ~S" seen-by-b)
        (is (search "echo: from-a" seen-by-a2)
            "a second session for principal a does not reach a's conversation")))))

(test the-session-route-exists-only-on-a-service-that-takes-grants
  (multiple-value-bind (priv pub) (aion/signature:generate-key-pair)
    (declare (ignore pub))
    (is (eql 404 (nth-value 0 (%open (%echo-app) (%grant-token priv)))))))

(test make-app-refuses-grants-without-an-audience
  "A verifier given no audience accepts a grant minted for any service, so the service has to be
told its own name."
  (multiple-value-bind (priv pub) (aion/signature:generate-key-pair)
    (declare (ignore priv))
    (let ((verifier (ceiling:make-ed25519-verifier pub))
          (make (lambda (p g) (declare (ignore g)) (actor:make-agent :name p))))
      (signals error (web:make-app :grant-verifier verifier :make-agent make))
      (signals error (web:make-app :grant-verifier verifier :make-agent make :audience ""))
      (signals error (web:make-app :grant-verifier verifier :audience "svc"
                                   :agent (actor:make-agent :name "one")))
      (finishes (web:make-app :grant-verifier verifier :make-agent make :audience "svc")))))

(test a-session-ends-when-idle-or-too-old
  (let* ((now 1000)
         (table (praxeon/web-session:make-session-table :idle-seconds 60 :max-seconds 300
                                                         :clock (lambda () now)))
         (id (praxeon/web-session:open-session table :grant)))
    (setf now 1059)
    (is (eq :grant (praxeon/web-session:session-grant table id)) "59 seconds idle is not 60")
    (setf now 1118)
    (is (eq :grant (praxeon/web-session:session-grant table id)) "and using it reset the idle time")
    (setf now 1178)
    (is (null (praxeon/web-session:session-grant table id)) "60 seconds idle ends it")
    (is (zerop (praxeon/web-session:session-count table)) "an ended session is removed")
    (let ((old (praxeon/web-session:open-session table :grant)))
      (loop repeat 5 do (incf now 59) (praxeon/web-session:session-grant table old))
      (is (eq :grant (praxeon/web-session:session-grant table old)) "295 seconds in, still open")
      (incf now 10)
      (is (null (praxeon/web-session:session-grant table old))
          "past the maximum lifetime it ends, however recently it was used"))))

;;; --- making a key's agent, turn ids, and expiry (#67 step two) ----------------

(defun %counting-make-agent (made &key gate)
  "A MAKE-AGENT that counts in MADE, a hash table guarded by its own synchronization, the agents
made for each key. With GATE, a semaphore, the agent for key a is made only once it is signalled."
  (lambda (key)
    (incf (gethash key made 0))
    (when (and gate (equal key "a"))
      (sb-thread:wait-on-semaphore gate :timeout 10))
    (actor:make-agent :name key)))

(defun %slow-keyed-app (made gate)
  "An echo app with one conversation per `who' key, whose agent for key a is made only after GATE
is signalled. MADE counts the agents made for each key."
  (%echo-app :conversation-key (lambda (env) (hyperion/http:query-param env "who"))
             :make-agent (%counting-make-agent made :gate gate)))

(defun %made-for (made key) (gethash key made 0))

(test two-first-requests-with-one-key-make-one-agent
  "Two requests with a new key that arrive while its agent is being made share the conversation
that agent starts: one agent is made, not two with one of them lost."
  (let* ((made (make-hash-table :test 'equal :synchronized t))
         (gate (sb-thread:make-semaphore))
         (app (%slow-keyed-app made gate))
         (get-a (lambda () (nth-value 0 (%call app :get "/" :query "who=a"))))
         ;; THREAD-LIFETIME: joined below -- each is one request, ended by signalling GATE.
         (first (sb-thread:make-thread get-a :name "px-web-test-first")))
    (is-true (await (lambda () (= 1 (%made-for made "a")))) "the first request never made a's agent")
    ;; THREAD-LIFETIME: joined below, as the first.
    (let ((second (sb-thread:make-thread get-a :name "px-web-test-second")))
      (sleep 0.2)
      (sb-thread:signal-semaphore gate 2)
      (is (eql 200 (sb-thread:join-thread first :default nil :timeout 10)))
      (is (eql 200 (sb-thread:join-thread second :default nil :timeout 10))))
    (is (= 1 (%made-for made "a")) "~D agents were made for key a" (%made-for made "a"))
    (%say app "hello" :query "who=a")
    (is (search "echo: hello" (%poll app 0 :query "who=a"))
        "the key's conversation does not work after it was made")))

(test a-slow-first-request-holds-up-only-its-own-key
  "While key a's agent is being made, a request with key b is answered: making an agent does not
hold the lock every key's requests go through."
  (let* ((made (make-hash-table :test 'equal :synchronized t))
         (gate (sb-thread:make-semaphore))
         (app (%slow-keyed-app made gate))
         ;; THREAD-LIFETIME: joined below; it ends when GATE is signalled.
         (slow (sb-thread:make-thread
                (lambda () (nth-value 0 (%call app :get "/" :query "who=a")))
                :name "px-web-test-slow")))
    (unwind-protect
         (progn
           (is-true (await (lambda () (= 1 (%made-for made "a")))) "a's agent was never started")
           ;; THREAD-LIFETIME: joined below with a timeout; it ends by itself unless it is blocked.
           (let ((other (sb-thread:make-thread
                         (lambda () (nth-value 0 (%call app :get "/" :query "who=b")))
                         :name "px-web-test-other")))
             (is (eql 200 (sb-thread:join-thread other :default nil :timeout 3))
                 "key b waited for key a's agent to be made")))
      (sb-thread:signal-semaphore gate)
      (sb-thread:join-thread slow :default nil :timeout 10))))

(test every-item-carries-the-turn-it-belongs-to
  "Each transcript item names its turn, numbered from 1 in each conversation, so a reader can tell
which turn a :TURN-ENDED item ends. A conversation that starts with an agent's history numbers its
first new turn after the history's."
  (let ((conv (web::make-conversation
               :agent-name "Echo"
               :responder (lambda (agent message locale)
                            (declare (ignore agent locale))
                            (format nil "echo: ~A" message)))))
    (web::%turn conv "one" nil)
    (web::%turn conv "two" nil)
    (is (equal '(1 1 1 2 2 2) (mapcar (lambda (i) (getf i :turn)) (web::%items-since conv 0)))
        "the turns were ~S" (web::%items-since conv 0)))
  (let* ((agent (actor:make-agent
                 :name "restored"
                 :history (list (llm:msg "user" "earlier question")
                                (llm:msg "assistant" "earlier answer"))))
         (conv (web::%new-conversation nil agent "Restored"
                                       (lambda (agent message locale)
                                         (declare (ignore agent locale))
                                         (format nil "echo: ~A" message)))))
    (web::%turn conv "next" nil)
    (is (equal '(1 1 2 2 2)
               (mapcar (lambda (i) (getf i :turn)) (web::%items-since conv 0)))
        "the turns were ~S" (web::%items-since conv 0))))

(test the-htmx-path-gives-the-message-and-the-turn-one-id
  "The message %RUN-TURN-ASYNC publishes on the request thread and the items its turn thread
publishes carry the same turn id."
  (let ((conv (web::make-conversation
               :agent-name "Echo"
               :responder (lambda (agent message locale)
                            (declare (ignore agent locale))
                            (format nil "echo: ~A" message)))))
    (sb-thread:join-thread (web::%run-turn-async conv "first" nil) :default nil :timeout 10)
    (sb-thread:join-thread (web::%run-turn-async conv "second" nil) :default nil :timeout 10)
    (let ((items (web::%items-since conv 0)))
      (is (equal '((:user 1) (:assistant 1) (:turn-ended 1) (:user 2) (:assistant 2) (:turn-ended 2))
                 (mapcar (lambda (i) (list (getf i :kind) (getf i :turn))) items))
          "the items were ~S" items))))

(defun %expiring-app (made clock &key gate entered turn-thread (transport :poll))
  "An app with one conversation per `who' key and conversations that expire after 1800 idle
seconds by CLOCK. The message \"slow\" signals ENTERED and then waits for GATE, both
semaphores, before it is answered. TURN-THREAD, a cons, gets the slow turn's thread in its car.
TRANSPORT goes to MAKE-APP."
  (web:make-app
   :agent-name "Echo"
   :responder (lambda (agent message locale)
                (declare (ignore agent locale))
                (when (and gate (string= message "slow"))
                  (when turn-thread (setf (car turn-thread) sb-thread:*current-thread*))
                  (sb-thread:signal-semaphore entered)
                  (sb-thread:wait-on-semaphore gate :timeout 10))
                (format nil "echo: ~A" message))
   :conversation-key (lambda (env) (hyperion/http:query-param env "who"))
   :make-agent (%counting-make-agent made)
   :conversation-idle-seconds 1800
   :transport transport
   :clock clock))

(test an-idle-conversation-is-dropped-and-the-next-request-starts-a-new-one
  "A key's conversation that no request has reached for the idle limit is dropped when another
key's conversation is made, and the key's next request makes a new agent with an empty
transcript. One reached within the limit is kept."
  (let* ((now 1000)
         (made (make-hash-table :test 'equal :synchronized t))
         (app (%expiring-app made (lambda () now))))
    (%say app "hello" :query "who=a")
    (setf now 2799)
    (%call app :get "/" :query "who=b")
    (is (search "echo: hello" (%poll app 0 :query "who=a"))
        "a conversation 1799 seconds idle was dropped")
    (is (= 1 (%made-for made "a")))
    ;; The poll above reached a's conversation at 2799, so its idle time starts again there.
    (setf now 4598)
    (%call app :get "/" :query "who=c")
    (is (search "echo: hello" (%poll app 0 :query "who=a"))
        "a request did not count as using the conversation")
    (setf now 6398)
    (%call app :get "/" :query "who=d")
    (let ((after (%poll app 0 :query "who=a")))
      (is (null (search "echo: hello" after)) "the idle conversation was kept: ~S" after))
    (is (= 2 (%made-for made "a")) "a new agent should have been made for key a")))

(test a-conversation-with-a-running-turn-is-not-dropped
  "A turn can run longer than the idle limit, and the conversation it runs in is kept until it
ends."
  (let* ((now 0)
         (made (make-hash-table :test 'equal :synchronized t))
         (gate (sb-thread:make-semaphore))
         (entered (sb-thread:make-semaphore))
         (app (%expiring-app made (lambda () now) :gate gate :entered entered)))
    (unwind-protect
         (progn
           (%call app :post "/api/message" :query "who=a" :form "message=slow")
           (is-true (sb-thread:wait-on-semaphore entered :timeout 10) "the turn never started")
           (setf now 2000)
           (%call app :get "/" :query "who=b")
           (sb-thread:signal-semaphore gate)
           (is-true (await (lambda () (search "echo: slow" (%poll app 0 :query "who=a"))))
                    "the running turn's conversation was dropped")
           (is (= 1 (%made-for made "a")) "a second agent was made for key a"))
      (sb-thread:signal-semaphore gate))))

(test the-reply-to-a-turn-that-ran-past-the-idle-limit-is-kept
  "A turn that runs past the idle limit with no request reaching its conversation meanwhile, and
ends before the next one, leaves its conversation and reply in place: the idle time counts from
when the turn ended."
  (let* ((now 0)
         (made (make-hash-table :test 'equal :synchronized t))
         (gate (sb-thread:make-semaphore))
         (entered (sb-thread:make-semaphore))
         (turn (list nil))
         (app (%expiring-app made (lambda () now) :gate gate :entered entered :turn-thread turn)))
    (unwind-protect
         (progn
           (%call app :post "/api/message" :query "who=a" :form "message=slow")
           (is-true (sb-thread:wait-on-semaphore entered :timeout 10) "the turn never started")
           (setf now 2000)
           (sb-thread:signal-semaphore gate)
           ;; Joined, so the turn has let go of its lock before the next request looks.
           (sb-thread:join-thread (car turn) :timeout 10 :default nil)
           (is (search "echo: slow" (%poll app 0 :query "who=a"))
               "the reply to the turn was dropped with its conversation")
           (is (= 1 (%made-for made "a")) "a second agent was made for key a"))
      (sb-thread:signal-semaphore gate))))

(test make-app-refuses-an-idle-limit-that-is-not-a-number-of-seconds
  (dolist (bad '(0 -5 1.5 "1800" nil))
    (signals error (web:make-app :conversation-key (lambda (env) (declare (ignore env)) "k")
                                 :make-agent (lambda (k) (actor:make-agent :name k))
                                 :conversation-idle-seconds bad))))

;;; --- #1011's review: a replaced conversation, sweeping, a changed grant ---------------

(defun %poll-cursor (app cursor &key query)
  "The body of a poll of APP that sends CURSOR, a cursor value as the page holds it."
  (nth-value 2 (%call app :get "/api/progress"
                      :query (format nil "after=~A~@[&~A~]" cursor query))))

(test a-page-whose-conversation-was-replaced-shows-the-new-one
  "A page open on a conversation that expired holds a cursor into the old transcript. Its next poll
replaces the transcript with the new conversation's, under a notice, instead of reading the new
transcript from the old index and showing nothing."
  (let* ((now 1000)
         (made (make-hash-table :test 'equal :synchronized t))
         (app (%expiring-app made (lambda () now))))
    (dotimes (i 4) (%say app (format nil "old ~D" i) :query "who=a"))
    (let ((old (%cursor-value-in (nth-value 2 (%call app :get "/" :query "who=a")))))
      (is (eql 12 (%cursor-in (format nil "px-cursor value=~A>" old))) "four turns, three items each")
      (setf now 2800)
      (%say app "new" :query "who=a")
      (let ((reply (%poll-cursor app old :query "who=a")))
        (is (search "innerHTML:#chat" reply) "the transcript is not replaced: ~S" reply)
        (is (search "This is a new conversation" reply))
        (is (search "echo: new" reply) "the new conversation's turn is not shown")
        (is (null (search "old 0" reply)) "the old transcript is shown again")
        (is (and (%epoch-in reply) (string/= (%epoch-in reply) (%epoch-in (format nil "px-cursor value=~A>" old))))
            "the cursor sent back still has the old epoch")
        (is (eql 3 (%cursor-in reply)))
        (let ((next (%poll-cursor app (%cursor-value-in reply) :query "who=a")))
          (is (null (search "innerHTML:#chat" next)) "a poll with the new cursor is reset again"))))))

(test a-returning-key-after-the-idle-limit-gets-a-new-conversation
  "The key's own request finds its conversation stale, even when the sweep ran too recently to run
again: here 10 seconds before, when the conversation had been idle for 1790."
  (let* ((now 1000)
         (made (make-hash-table :test 'equal :synchronized t))
         (app (%expiring-app made (lambda () now))))
    (%say app "hello" :query "who=a")
    (setf now 2790)
    (%call app :get "/" :query "who=b")
    (setf now 2800)
    (is (null (search "echo: hello" (%poll app 0 :query "who=a"))) "1800 seconds idle is stale")
    (is (= 2 (%made-for made "a")))))

(test stale-conversations-are-swept-on-any-request
  "A conversation whose key never returns is removed by a later request with another key that the
table already holds."
  (let ((now 1000)
        (made (make-hash-table :test 'equal :synchronized t)))
    (multiple-value-bind (app count) (%expiring-app made (lambda () now))
      (%say app "a" :query "who=a")
      (%say app "b" :query "who=b")
      (is (= 2 (funcall count)))
      (setf now 2700)
      (%poll app 0 :query "who=b")
      (is (= 2 (funcall count)) "a, 1700 seconds idle, is not stale yet")
      (setf now 2800)
      (%poll app 0 :query "who=b")
      (is (= 1 (funcall count)) "a, 1800 seconds idle, was not swept")
      (is (= 1 (%made-for made "b")) "b was in use and should have been kept"))))

(test a-session-with-a-smaller-grant-runs-its-next-turn-without-the-lost-capability
  "Two sessions of one principal, opened with different grants. Each turn runs on an agent made
from the grant of the session that sent it, and the conversation goes on across the change."
  (multiple-value-bind (priv pub) (aion/signature:generate-key-pair)
    (let* ((made (list nil))
           (app (web:make-app
                 :grant-verifier (ceiling:make-ed25519-verifier pub) :audience "svc"
                 :make-agent (lambda (principal grant)
                               (declare (ignore principal))
                               (push (ceiling:grant-capabilities grant) (car made))
                               (actor:make-agent
                                :name (format nil "~{~A~^+~}" (ceiling:grant-capabilities grant))))
                 :responder (lambda (agent message locale)
                              (declare (ignore locale))
                              (push message (actor:agent-history agent))
                              (format nil "~A-ran-as-~A-with-~D-in-history" message
                                      (actor:agent-name agent)
                                      (length (actor:agent-history agent))))))
           (wide (nth-value 1 (%open app (%grant-token priv :capabilities '("search" "write")))))
           (narrow (nth-value 1 (%open app (%grant-token priv :capabilities '("search"))))))
      (flet ((say (session text)
               (nth-value 2 (%call app :post "/api/message"
                                   :authorization (format nil "Session ~A" session)
                                   :json (format nil "{\"message\":\"~A\"}" text)))))
        (is (search "one-ran-as-search+write-with-1-in-history" (say wide "one")))
        (is (search "two-ran-as-search-with-2-in-history" (say narrow "two"))
            "the narrower grant did not take effect, or the history was not carried")
        (is (search "three-ran-as-search-with-3-in-history" (say narrow "three")))
        (is (= 2 (length (car made))) "a grant with the same terms made another agent")
        (let ((all (nth-value 2 (%call app :get "/api/progress" :query "after=0"
                                       :authorization (format nil "Session ~A" narrow)))))
          (is (search "one-ran-as-search+write" all) "the transcript did not go on"))))))

(test the-dev-routes-exist-only-in-a-dev-app
  (let ((prod (%echo-app))
        (dev (%echo-app :dev t)))
    (is (eql 404 (nth-value 0 (%call prod :get "/api/dev-error"))))
    (is (eql 404 (nth-value 0 (%call prod :get "/api/reload-epoch"))))
    (is (eql 200 (nth-value 0 (%call dev :get "/api/dev-error"))))
    (is (eql 200 (nth-value 0 (%call dev :get "/api/reload-epoch"))))))

(test a-signed-grant-of-the-wrong-shape-is-refused-401
  (multiple-value-bind (priv pub) (aion/signature:generate-key-pair)
    (let ((app (%grant-app pub)))
      (is (eql 401 (nth-value 0 (%open app (ceiling:encode-grant-token "[1,2]" priv)))))
      (is (eql 401 (nth-value 0 (%open app (ceiling:encode-grant-token
                                            "{\"principal\":5,\"audience\":\"svc\"}" priv))))))))

;;; --------------------------------------------------------------------------
;;; The page's updates as a stream (#67 step three)
;;; --------------------------------------------------------------------------
;;;
;;; With :TRANSPORT :SSE, GET /api/events answers a streamed body, a function of a writer. These
;;; tests call that function with a writer that keeps what it is given, and end the stream by
;;; signalling from the writer, which is what a server's writer does when the browser has gone.

(define-condition %stream-stopped (error) ()
  (:documentation "Signalled by %READ-STREAM's writer to end a stream the test has read enough of."))

(defun %read-stream (body &key (events 1) on-event (seconds 5))
  "Run BODY, a stream body, until it has written EVENTS events, ending it then, or until it ends by
itself, or until it has run SECONDS. ON-EVENT is called with each event's text, before the next.
Returns (values EVENT-TEXTS HOW): HOW is :READ when the test ended the stream, :ENDED when the
stream ended by itself, and :TIMEOUT. A comment line is not an event."
  (let ((got '())
        (deadline (+ (get-universal-time) seconds)))
    (handler-case
        (progn
          (funcall body
                   (lambda (chunk)
                     (unless (eql 0 (search ": " chunk))
                       (push chunk got)
                       (when on-event (funcall on-event chunk))
                       (when (>= (length got) events) (error '%stream-stopped)))
                     (when (>= (get-universal-time) deadline) (error '%stream-stopped))))
          (values (reverse got) :ended))
      (%stream-stopped ()
        (values (reverse got) (if (>= (length got) events) :read :timeout))))))

(defun %event-id (event)
  "The value of EVENT's id field, or NIL."
  (let ((at (search (format nil "~%id: ") (format nil "~%~A" event))))
    (and at (subseq event (+ at 4) (position #\Newline event :start (+ at 4))))))

(defun %stream-of (app &key query headers authorization)
  "GET APP's /api/events. Returns (values STATUS HEADERS BODY)."
  (%call app :get "/api/events" :query query :headers headers :authorization authorization))

(defun %page-epoch (app &key query authorization)
  (%epoch-in (nth-value 2 (%call app :get "/" :query query :authorization authorization))))

(test a-polling-app-has-no-stream
  (multiple-value-bind (priv pub) (aion/signature:generate-key-pair)
    (declare (ignore priv))
    (let ((app (%echo-app)))
      (is (eql 404 (nth-value 0 (%stream-of app :query "after=0"))))
      (is (null (search "px-events" (nth-value 2 (%call app :get "/")))))
      (is (search "/api/progress" (nth-value 2 (%call app :get "/")))))
    (is (eql 404 (nth-value 0 (%call (%grant-app pub) :post "/embed/stream-ticket"))))))

(test a-streaming-page-reads-the-stream-and-does-not-poll
  (let ((page (nth-value 2 (%call (%echo-app :transport :sse) :get "/"))))
    (is (search "px-events" page))
    (is (search "/api/events" page))
    (is (null (search "/api/progress" page)) "the page still polls")
    (is (search "new EventSource(" page) "the page has no stream client")
    (is (search "px-cursor" page) "the stream client has no cursor to start from")))

(test the-stream-sends-what-a-poll-would-with-the-cursor-as-the-event-id
  (let ((app (%echo-app :transport :sse)))
    (%say app "hi")
    (let ((epoch (%page-epoch app)))
      (multiple-value-bind (status headers body)
          (%stream-of app :query (format nil "after=~A:0" epoch))
        (is (eql 200 status))
        (is (search "text/event-stream" (getf headers :content-type)))
        (let ((event (first (%read-stream body))))
          (is (search "hi</p>" event) "the user's message is missing: ~S" event)
          (is (search "echo: hi" event) "the reply is missing: ~S" event)
          (is (equal (format nil "~A:3" epoch) (%event-id event))
              "a message, a reply and a turn-ended item make the cursor 3: ~S" event)
          (is (search "id=status" event) "the status line is not in the event"))))))

(test the-stream-sends-each-new-item-once
  (let* ((app (%echo-app :transport :sse))
         (epoch (%page-epoch app)))
    (%say app "first")
    (multiple-value-bind (events how)
        (%read-stream (nth-value 2 (%stream-of app :query (format nil "after=~A:0" epoch)))
                      :events 2
                      :on-event (lambda (e)
                                  (when (search "echo: first" e) (%say app "second"))))
      (is (eq :read how) "the second event never came")
      (is (search "echo: second" (second events)) "~S" (second events))
      (is (null (search "echo: first" (second events))) "an item was sent twice")
      (is (equal (format nil "~A:6" epoch) (%event-id (second events)))))))

(test a-reconnecting-browser-resumes-from-its-last-event-id
  "A browser that reconnects by itself sends Last-Event-ID, and keeps the URL it first opened, so
the header wins over `after'."
  (let* ((app (%echo-app :transport :sse))
         (epoch (%page-epoch app)))
    (%say app "before")
    (let ((event (first (%read-stream
                         (nth-value 2 (%stream-of app
                                                  :query (format nil "after=~A:0" epoch)
                                                  :headers (list (cons "last-event-id"
                                                                       (format nil "~A:3" epoch)))))))))
      (is (null (search "before" event)) "items before Last-Event-ID were sent again: ~S" event)
      (is (equal (format nil "~A:3" epoch) (%event-id event))))))

(test a-stream-from-another-conversation-gets-this-one-from-the-start
  (let ((app (%echo-app :transport :sse)))
    (%say app "now")
    (let ((event (first (%read-stream
                         (nth-value 2 (%stream-of app :headers '(("last-event-id" . "0123abcd:9"))))))))
      (is (search "innerHTML:#chat" event) "the transcript was not replaced: ~S" event)
      (is (search "echo: now" event))
      (is (search "not used for a while" event) "the notice is missing"))))

(test a-conversation-being-streamed-is-not-dropped-and-the-stream-ending-counts-as-use
  "No request reaches a conversation while its page reads a stream, and the conversation is kept.
When the stream ends, that counts as a request, so a page that opens a new stream at once finds
the same conversation."
  (let* ((now 1000)
         (made (make-hash-table :test 'equal :synchronized t))
         (app (%expiring-app made (lambda () now) :transport :sse)))
    (%say app "hello" :query "who=a")
    ;; While the stream is open, an hour passes and a request with another key sweeps. Then the
    ;; stream ends, at 4600.
    (%read-stream (nth-value 2 (%stream-of app :query "who=a&after=0"))
                  :on-event (lambda (e)
                              (declare (ignore e))
                              (setf now 4600)
                              (%call app :get "/" :query "who=b")))
    (is (= 1 (%made-for made "a")) "the streamed conversation was dropped")
    (setf now 6300)
    (is (search "echo: hello" (%poll app 0 :query "who=a"))
        "the stream's end did not count as using the conversation")
    (is (= 1 (%made-for made "a")))))

;;; --- streams with grants: tickets ----------------------------------------------------

(defun %ticket (app session)
  "POST APP's /embed/stream-ticket with SESSION. Returns (values STATUS TICKET-or-NIL)."
  (multiple-value-bind (status headers body)
      (%call app :post "/embed/stream-ticket"
                 :authorization (and session (format nil "Session ~A" session)))
    (declare (ignore headers))
    (values status (and (eql status 200) (gethash "ticket" (com.inuoe.jzon:parse body))))))

(test a-stream-ticket-needs-an-open-session
  (multiple-value-bind (priv pub) (aion/signature:generate-key-pair)
    (let* ((app (%grant-app pub :transport :sse))
           (session (nth-value 1 (%open app (%grant-token priv)))))
      (is (eql 401 (%ticket app nil)))
      (is (eql 401 (%ticket app "no-such-session")))
      (multiple-value-bind (status ticket) (%ticket app session)
        (is (eql 200 status))
        (is (and (stringp ticket) (= 64 (length ticket))) "a ticket is 256 bits as hex: ~S" ticket)))))

(test a-ticket-opens-one-stream-and-only-one
  (multiple-value-bind (priv pub) (aion/signature:generate-key-pair)
    (let* ((app (%grant-app pub :transport :sse))
           (session (nth-value 1 (%open app (%grant-token priv))))
           (ticket (nth-value 1 (%ticket app session))))
      (%call app :post "/api/message" :authorization (format nil "Session ~A" session)
                                      :json "{\"message\":\"hi\"}")
      (is (eql 401 (nth-value 0 (%stream-of app :query "after=0"))) "a stream without a ticket")
      (is (eql 401 (nth-value 0 (%stream-of app :query "after=0"
                                                :authorization (format nil "Session ~A" session))))
          "the session header opened a stream; only a ticket should")
      (multiple-value-bind (status headers body)
          (%stream-of app :query (format nil "after=0&ticket=~A" ticket))
        (declare (ignore headers))
        (is (eql 200 status))
        (is (search "echo: hi" (first (%read-stream body))) "the stream is not the principal's"))
      (is (eql 401 (nth-value 0 (%stream-of app :query (format nil "after=0&ticket=~A" ticket))))
          "a ticket opened a second stream"))))

(test a-stream-ends-when-its-session-does
  (multiple-value-bind (priv pub) (aion/signature:generate-key-pair)
    (let* ((sessions (praxeon/web-session:make-session-table))
           (app (%grant-app pub :transport :sse :sessions sessions))
           (session (nth-value 1 (%open app (%grant-token priv))))
           (ticket (nth-value 1 (%ticket app session)))
           (web::*stream-check-seconds* 0))
      (multiple-value-bind (events how)
          (%read-stream (nth-value 2 (%stream-of app :query (format nil "ticket=~A" ticket)))
                        :events 2
                        :on-event (lambda (e)
                                    (declare (ignore e))
                                    (praxeon/web-session:close-session sessions session)))
        (is (eq :ended how) "the stream did not end with its session: ~S" how)
        (is (= 1 (length events)))))))

(test an-open-stream-does-not-keep-its-session-from-going-idle
  "A page left open holds its stream, and the stream checks its session on a timer. The check
must not count as a use, or the session, and the server thread holding the stream, would last
until the session's maximum age. Once the first event is read, each reading of the clock moves
it 10 seconds, so the idle limit of 60 seconds passes within a few checks."
  (multiple-value-bind (priv pub) (aion/signature:generate-key-pair)
    (let* ((now 1000)
           (ticking nil)
           (sessions (praxeon/web-session:make-session-table
                      :idle-seconds 60 :clock (lambda () (if ticking (incf now 10) now))))
           (app (%grant-app pub :transport :sse :sessions sessions))
           (session (nth-value 1 (%open app (%grant-token priv))))
           (ticket (nth-value 1 (%ticket app session)))
           (web::*stream-check-seconds* 0)
           ;; A comment on every pass, so %READ-STREAM can stop the stream if it does not end.
           (hyperion/sse:*keep-alive-seconds* 0))
      (multiple-value-bind (events how)
          (%read-stream (nth-value 2 (%stream-of app :query (format nil "ticket=~A" ticket)))
                        :events 2 :seconds 3
                        :on-event (lambda (e) (declare (ignore e)) (setf ticking t)))
        (is (eq :ended how) "the stream kept its idle session open: ~S" how)
        (is (= 1 (length events)))
        (is (null (praxeon/web-session:session-grant sessions session))
            "the session is still open")))))

(test a-ticket-is-spent-by-use-by-time-and-by-its-session-ending
  (let* ((now 1000)
         (table (praxeon/web-session:make-session-table :ticket-seconds 30
                                                        :clock (lambda () now)))
         (id (praxeon/web-session:open-session table :grant)))
    (is (null (praxeon/web-session:issue-ticket table "no-such-session")))
    (let ((ticket (praxeon/web-session:issue-ticket table id)))
      (is (equal id (praxeon/web-session:redeem-ticket table ticket)))
      (is (null (praxeon/web-session:redeem-ticket table ticket)) "a ticket was used twice"))
    (let ((ticket (praxeon/web-session:issue-ticket table id)))
      (incf now 29)
      (is (equal id (praxeon/web-session:redeem-ticket table ticket)) "29 seconds is within 30"))
    (let ((ticket (praxeon/web-session:issue-ticket table id)))
      (incf now 30)
      (is (null (praxeon/web-session:redeem-ticket table ticket)) "a ticket outlived 30 seconds"))
    (let ((ticket (praxeon/web-session:issue-ticket table id)))
      (praxeon/web-session:close-session table id)
      (is (null (praxeon/web-session:redeem-ticket table ticket))
          "a ticket opened a stream for a closed session"))))

;;; --- which transport START serves -----------------------------------------------------

(test start-streams-only-where-the-server-can-hold-a-stream
  (is (eq :sse (web::%resolve-transport :auto :hunchentoot)))
  (is (eq :poll (web::%resolve-transport :auto :woo)))
  (is (eq :poll (web::%resolve-transport :auto :uv)) ":uv has two workers by default")
  (is (eq :sse (web::%resolve-transport :sse :uv)))
  (is (eq :poll (web::%resolve-transport :poll :hunchentoot)))
  (signals error (web::%resolve-transport :sse :woo))
  (signals error (web::%resolve-transport :websocket :hunchentoot))
  (signals error (web:make-app :agent (quiet-agent) :transport :auto)))

(defun %worker-threads (client-port)
  "The live threads Hunchentoot runs the connection from CLIENT-PORT on. It names each one after
the client's address and port."
  (remove-if-not (lambda (th)
                   (search (format nil "worker-127.0.0.1:~D" client-port) (sb-thread:thread-name th)))
                 (sb-thread:list-all-threads)))

(test hunchentoot-delivers-each-event-while-the-stream-is-open
  "The first event reaches the browser while the stream is still open: Hunchentoot sends the
response chunked, and a backend that held the chunks until the body ended would show a page that
never updates. Ending the session then ends the stream, and the thread the server ran it on."
  (multiple-value-bind (priv pub) (aion/signature:generate-key-pair)
    (let* ((sessions (praxeon/web-session:make-session-table))
           (app (%grant-app pub :transport :sse :sessions sessions))
           (session (nth-value 1 (%open app (%grant-token priv))))
           (ticket (nth-value 1 (%ticket app session)))
           (port (free-port))
           (handler (srv:start app :server :hunchentoot :port port :log nil))
           (s (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
      (unwind-protect
           (progn
             (is-true (await (lambda () (listening-p port))) "the server did not come up")
             (sb-bsd-sockets:socket-connect s #(127 0 0 1) port)
             (let ((st (sb-bsd-sockets:socket-make-stream s :input t :output t
                                                            :element-type 'character
                                                            :external-format :utf-8))
                   (text ""))
               (format st "GET /api/events?ticket=~A HTTP/1.1~C~CHost: 127.0.0.1~C~CConnection: close~C~C~C~C"
                       ticket #\Return #\Linefeed #\Return #\Linefeed #\Return #\Linefeed
                       #\Return #\Linefeed)
               (finish-output st)
               (handler-case
                   (sb-sys:with-deadline (:seconds 10)
                     ;; Read until the first event's id line and the blank line after it.
                     (loop for c = (read-char st nil nil)
                           while c
                           do (setf text (concatenate 'string text (string c)))
                              (let ((id (search "id: " text)))
                                (when (and id (search (format nil "~%~%") text :start2 id))
                                  (return)))))
                 (sb-sys:deadline-timeout () nil))
               (is (search "text/event-stream" text) "~S" text)
               (is (search "id: " text) "no event arrived while the stream was open: ~S" text))
             (let ((client (nth-value 1 (sb-bsd-sockets:socket-name s))))
               (is-true (%worker-threads client) "no thread was serving the stream")
               (praxeon/web-session:close-session sessions session)
               (is-true (await (lambda () (null (%worker-threads client)))
                             :timeout (+ 5 web::*stream-check-seconds*))
                        "the stream went on after its session ended")))
        (ignore-errors (sb-bsd-sockets:socket-close s))
        (ignore-errors (srv:stop handler))))))
