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
                    (#:llm #:praxeon/llm))
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

(defun %call (app method path &key query json form)
  "Call APP, a Clack app, with a request for METHOD and PATH, and return (values STATUS HEADERS
BODY). QUERY is the query string. JSON or FORM, a string, is the body, sent as application/json
or as a urlencoded form."
  (let* ((headers (make-hash-table :test 'equal))
         (env (list :request-method method :path-info path :query-string query
                    :headers headers
                    :content-type (cond (json "application/json")
                                        (form "application/x-www-form-urlencoded")))))
    (when (or json form)
      (setf env (hyperion/http:cache-body-string env (or json form))))
    (destructuring-bind (status hdrs body) (funcall app env)
      (values status hdrs (format nil "~{~A~}" body)))))

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

(defun %cursor-in (html)
  "The index in HTML's px-cursor field, or NIL. Spinneret leaves an attribute value unquoted when
it can, so the value is read after `value=' with or without a quote."
  (let* ((at (search "px-cursor" html))
         (v (and at (search "value=" html :start2 at)))
         (start (and v (+ v 6))))
    (when (and start (< start (length html)) (char= (char html start) #\"))
      (incf start))
    (and start (parse-integer html :start start :junk-allowed t))))

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
    (web::%build-app nil "Guest" "Guest" #'identity nil nil nil nil nil nil nil nil)
    (is (eq :pretty out:*output-style*)
        "a :pretty host survives a non-dev agent surface, which the defect would set :compact"))
  (let ((out:*output-style* :compact))
    (web::%build-app nil "Guest" "Guest" #'identity nil nil t nil nil nil nil nil)
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
