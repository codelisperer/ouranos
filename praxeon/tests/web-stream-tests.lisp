;;;; web-stream-tests.lisp --- the reply as the model writes it, and the Stop button (#1339)
;;;;
;;;; The provider here is a stub Anthropic server on 127.0.0.1 that streams part of a reply and
;;;; then waits, as a provider does while the model works, until the test lets it finish or the
;;;; client closes the connection. So a test can look at the page while the turn is in the middle
;;;; of a model call: what the draft shows, whether the Stop button is shown, and what stopping
;;;; the turn does to the provider's connection.

(cl:in-package #:praxeon/web/tests)

(in-suite praxeon-web)

(defun %sse-events (stream events)
  "Write EVENTS, a list of (EVENT-NAME . DATA-STRING), to STREAM as Server-Sent Events."
  (dolist (e events)
    (write-sequence (sb-ext:string-to-octets (format nil "event: ~A~%data: ~A~%~%" (car e) (cdr e))
                                             :external-format :utf-8)
                    stream)
    (finish-output stream)))

(defun %delta (text)
  (cons "content_block_delta"
        (format nil "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"~A\"}}"
                text)))

(defparameter +before-the-wait+
  (list (cons "message_start" "{\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":30,\"output_tokens\":1}}}")
        (cons "content_block_start" "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}")
        (%delta "Two ")
        (%delta "and two "))
  "What the stub streams before it waits: the start of the reply, \"Two and two \".")

(defparameter +after-the-wait+
  (list (%delta "is four.")
        (cons "message_delta" "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":6}}")
        (cons "message_stop" "{\"type\":\"message_stop\"}"))
  "What it streams once it is let go: the rest of the reply, \"is four.\", and the end.")

(defun %waiting-provider-server (release closed-at)
  "A handler that streams +BEFORE-THE-WAIT+, then waits until RELEASE's car is true, and then
streams +AFTER-THE-WAIT+. A thread of its own reads the connection while it waits, and stores the
time in CLOSED-AT's car if the client closes it first. It waits at most 10 seconds."
  (lambda (request stream)
    (declare (ignore request))
    (ignore-errors
     (aion/test-http:write-head stream 200 '(("Content-Type" . "text/event-stream")
                                             ("Connection" . "close")))
     (%sse-events stream +before-the-wait+)
     (let* ((ending (list nil))
            ;; INTERRUPTS: a test fixture's thread, made by the stub server's handler and not by a
            ;; framework; it blocks reading the connection until the client closes it or the
            ;; handler ends, and the JOIN below waits for it.
            (watcher (sb-thread:make-thread
                      (lambda ()
                        (ignore-errors (read-byte stream nil nil))
                        (unless (car ending) (setf (car closed-at) (get-internal-real-time))))
                      :name "stub provider close watcher")))
       (loop repeat 100 until (or (car release) (car closed-at)) do (sleep 0.1))
       (setf (car ending) t)
       (if (and (car release) (not (car closed-at)))
           (%sse-events stream +after-the-wait+)
           (ignore-errors (close stream :abort t)))
       (finish-output stream)
       (ignore-errors (close stream :abort t))
       (aion/test-threads:join watcher :timeout 15)))))

(defun %stub-agent (server)
  (actor:make-agent :name "stub"
                    :provider (make-instance 'llm:anthropic
                                             :api-key "test-key" :model "m"
                                             :endpoint (aion/test-http:server-url server "/v1/messages"))))

(defun %send (app text)
  "Send TEXT as the page does, through the htmx path, which starts the turn and returns at once."
  (values (%call app :post "/api/message" :form (format nil "message=~A" text))))

(defun %draft-in (html)
  "The part of an update HTML that is the #px-draft element it appends: from its class to the
cursor field that follows it. The out-of-band element that deletes the old draft has no class."
  (let ((at (or (search "class=px-draft" html) (search "class=\"px-draft\"" html))))
    (and at (subseq html at (or (search "px-cursor" html :start2 at) (length html))))))

(defun %stop-tag (html)
  "The opening tag of the Stop button in HTML, or NIL."
  (let* ((id (or (search "id=px-stop" html) (search "id=\"px-stop\"" html)))
         (open (and id (position #\< html :end id :from-end t))))
    (and open (subseq html open (1+ (position #\> html :start id))))))

(defun %stop-shown-p (html)
  (let ((tag (%stop-tag html)))
    (and tag (not (search "hidden" tag)))))

(defun %positions-of (needle haystack)
  "Every position of NEEDLE in HAYSTACK."
  (loop with start = 0
        for at = (search needle haystack :start2 start)
        while at collect at do (setf start (1+ at))))

(defun %items-of (app-conv)
  (web::%items-since app-conv 0))

(defun %poll-update (app)
  "A poll of APP from the start of its transcript."
  (%poll app 0))

(test the-reply-is-shown-while-the-model-writes-it-and-then-replaced
  "With the default responder, a poll during the model call shows the text streamed so far in the
agent's bubble, as #px-draft after the items, and shows the Stop button. When the turn ends, the
reply is an item, the draft is empty and the Stop button is hidden. The same holds through the
stream (:TRANSPORT :SSE): an event carries the draft before an event carries the reply."
  (dolist (transport '(:poll :sse))
    (let ((release (list nil)) (closed-at (list nil)))
      (aion/test-http:with-server (s (%waiting-provider-server release closed-at))
        (let ((app (web:make-app :agent (%stub-agent s) :agent-name "Stub" :transport transport)))
          (is (eql 200 (%send app "what is two and two?")))
          (let ((during (await (lambda ()
                                 (let ((html (%poll-update app)))
                                   (and (search "and two" (or (%draft-in html) "")) html))))))
            (is-true during "~A: the draft never showed the text streamed so far" transport)
            (when during
              (is (search "px-assistant" (%draft-in during)) "~A: the draft is not in the agent's bubble"
                  transport)
              (is (null (search "is four" during)) "~A: text the provider had not sent" transport)
              (is-true (%stop-shown-p during) "~A: no Stop button while the turn runs: ~S"
                       transport (%stop-tag during))
              (is (search "hx-swap-oob=delete" (remove #\" during))
                  "~A: the update does not delete the old draft first" transport)))
          (when (eq transport :sse)
            ;; The stream from the start: its first event is sent at once and has the draft.
            (let ((event (first (%read-stream (nth-value 2 (%stream-of app :query
                                                                       (format nil "after=~A:0"
                                                                               (%page-epoch app))))))))
              (is (search "and two" (or (%draft-in (or event "")) ""))
                  "the stream's event has no draft: ~S" event)))
          (setf (car release) t)
          (let ((after (await (lambda ()
                                (let ((html (%poll-update app)))
                                  (and (search "Two and two is four." html)
                                       (not (%stop-shown-p html))
                                       html))))))
            (is-true after "~A: the reply never arrived, or the Stop button stayed" transport)
            (when after
              (is (null (search "px-assistant" (or (%draft-in after) "")))
                  "~A: the draft is still shown after the reply: ~S" transport (%draft-in after))
              (is (= 1 (length (%positions-of "Two and two is four." after)))
                  "~A: the reply is shown more than once" transport)))
          (is (null (car closed-at)) "~A: the provider's connection was closed early" transport))))))

(test stopping-a-turn-closes-the-provider-s-connection-and-ends-it-as-stopped
  "POST /api/cancel during the model call closes the stub provider's connection within two
seconds, and the turn ends with a :TURN-ENDED item whose outcome is :CANCELLED and no reply item.
The page shows \"Stopped.\" and hides the Stop button. This holds for the default responder and for
a custom one that calls RUN-TURN, which is stopped through `praxeon/actor:*turn-cancel*'.
Control: POST /api/cancel with no turn running cancels nothing, and a JSON client is told so."
  (dolist (responder (list nil (lambda (agent message locale)
                                 (declare (ignore locale))
                                 (actor:run-turn agent message))))
    (let ((release (list nil)) (closed-at (list nil)) (cancelled-at nil))
      (aion/test-http:with-server (s (%waiting-provider-server release closed-at))
        (let* ((app (apply #'web:make-app :agent (%stub-agent s) :agent-name "Stub"
                           :stream-text t (and responder (list :responder responder))))
               (name (if responder "custom" "default")))
          (%send app "what is two and two?")
          (is-true (await (lambda () (search "and two" (or (%draft-in (%poll-update app)) ""))))
                   "~A: the model call never started" name)
          (setf cancelled-at (get-internal-real-time))
          (multiple-value-bind (status headers) (%call app :post "/api/cancel")
            (is (eql 200 status))
            (is (equal "px-poll" (getf headers :hx-trigger)) "~A: ~S" name headers))
          (let ((ended (await (lambda ()
                                (let ((html (%poll-update app)))
                                  (and (search "Stopped." html) html))))))
            (is-true ended "~A: the page never showed the turn as stopped" name)
            (when ended
              (is-false (%stop-shown-p ended) "~A: the Stop button is still shown" name)
              (is (null (search "is four" ended)) "~A" name)
              (is (null (search "px-assistant" (or (%draft-in ended) "")))
                  "~A: the draft is still shown" name)))
          (await (lambda () (car closed-at)) :timeout 3)
          (is-true (car closed-at) "~A: the provider never saw its connection close" name)
          (when (car closed-at)
            (is (< (/ (- (car closed-at) cancelled-at) internal-time-units-per-second) 2) "~A" name))
          (multiple-value-bind (status headers body)
              (%call app :post "/api/cancel" :headers '(("accept" . "application/json")))
            (declare (ignore headers))
            (is (eql 200 status))
            (is (equal "{\"cancelled\":false}" body) "control, ~A: ~S" name body)))))))

(test a-stopped-turn-publishes-no-reply-and-ends-cancelled
  "The items of a stopped turn: the user's message and a :TURN-ENDED item with :CANCELLED, and no
:ASSISTANT item, and %TURN returns within seconds of the cancel. Control: the next turn, not
stopped, publishes its reply and ends :OK."
  (let ((release (list nil)) (closed-at (list nil)))
    (aion/test-http:with-server (s (%waiting-provider-server release closed-at))
      (let* ((agent (%stub-agent s))
             (conv (web::%new-conversation nil agent "Stub" #'web::%default-responder :stream-text t))
             ;; INTERRUPTS: a test thread, not one a framework makes; it runs one turn and the
             ;; JOIN below waits for it.
             (thread (sb-thread:make-thread (lambda () (multiple-value-list (web::%turn conv "q1" nil)))
                                            :name "test turn")))
        (await (lambda () (web::%draft-and-running conv)))
        (let ((cancelled-at (get-internal-real-time)))
          (is-true (web::%cancel-running conv) "a turn was running")
          (is (equal '(nil nil :cancelled) (aion/test-threads:join thread :timeout 15)))
          ;; Within seconds, so it was the cancel that ended the call: the stub gives up and
          ;; closes the connection by itself only after 10 seconds.
          (is (< (/ (- (get-internal-real-time) cancelled-at) internal-time-units-per-second) 3)
              "the turn took ~,1F seconds to end after the cancel"
              (/ (- (get-internal-real-time) cancelled-at) internal-time-units-per-second)))
        (setf (car release) t)))
    (let ((release (list t)) (closed-at (list nil)))
      (aion/test-http:with-server (s (%waiting-provider-server release closed-at))
        (let ((conv (web::%new-conversation nil (%stub-agent s) "Stub" #'web::%default-responder)))
          (is (equal '("Two and two is four." nil) (multiple-value-list (web::%turn conv "q2" nil))))
          (is (equal '((:user nil) (:assistant nil) (:turn-ended :ok))
                     (mapcar (lambda (i) (list (getf i :kind) (getf i :outcome))) (%items-of conv)))
              "control: ~S" (%items-of conv)))))
    (let ((release (list nil)) (closed-at (list nil)))
      (aion/test-http:with-server (s (%waiting-provider-server release closed-at))
        (let* ((conv (web::%new-conversation nil (%stub-agent s) "Stub" #'web::%default-responder
                                             :stream-text t))
               ;; INTERRUPTS: as above.
               (thread (sb-thread:make-thread (lambda () (web::%turn conv "q1" nil))
                                              :name "test turn")))
          (await (lambda () (web::%draft-and-running conv)))
          (web::%cancel-running conv)
          (aion/test-threads:join thread :timeout 15)
          (is (equal '((:user nil) (:turn-ended :cancelled))
                     (mapcar (lambda (i) (list (getf i :kind) (getf i :outcome))) (%items-of conv)))
              "~S" (%items-of conv)))))))

(test a-custom-responder-shows-no-draft-unless-the-app-asks
  ":STREAM-TEXT :AUTO, the default, shows the draft for the default responder only, because a
custom responder can change the reply after the model wrote it. With a custom responder the draft
stays empty while the model writes; with :STREAM-TEXT T it shows. The reply arrives either way."
  (dolist (case '((:auto nil) (t t)))
    (destructuring-bind (stream-text shown) case
      (let ((release (list nil)) (closed-at (list nil)))
        (aion/test-http:with-server (s (%waiting-provider-server release closed-at))
          (let ((app (web:make-app :agent (%stub-agent s) :agent-name "Stub"
                                   :stream-text stream-text
                                   :responder (lambda (agent message locale)
                                                (declare (ignore locale))
                                                (string-upcase (actor:run-turn agent message))))))
            (%send app "what is two and two?")
            ;; The Stop button shows once the turn holds the lock; the model call is under way
            ;; once the provider has sent its first pieces, which takes a moment more.
            (is-true (await (lambda () (%stop-shown-p (%poll-update app)))))
            (sleep 0.5)
            (is (eq shown (and (search "and two" (or (%draft-in (%poll-update app)) "")) t))
                ":stream-text ~S" stream-text)
            (setf (car release) t)
            (is-true (await (lambda () (search "TWO AND TWO IS FOUR." (%poll-update app))))
                     ":stream-text ~S: the responder's reply" stream-text)))))))

(test the-stop-button-is-in-the-composer-hidden-until-a-turn-runs
  "The full page and the embed panel both have the Stop button, hidden; the panel's is disabled
until it has a session, and its script enables it with the composer. A poll with no turn running
keeps it hidden. A composer made without :CANCEL-ACTION has none, as before."
  (let* ((app (%echo-app))
         (page (nth-value 2 (%call app :get "/"))))
    (is-true (%stop-tag page) "the page has no Stop button")
    (is-false (%stop-shown-p page) "the Stop button shows with no turn running")
    (is (search "/api/cancel" (%stop-tag page)))
    (is-false (%stop-shown-p (%poll app 0))))
  (let ((panel (nth-value 2 (%call (%embed-app) :get "/embed/panel"))))
    (is-true (%stop-tag panel) "the embed panel has no Stop button")
    (is (search "disabled" (or (%stop-tag panel) "")) "~S" (%stop-tag panel))
    (is (search "px-stop" (praxeon/chat-ui:embed-panel-js))
        "the panel's script does not enable the Stop button"))
  (is (null (%stop-tag (praxeon/chat-ui:composer))) "a composer without :cancel-action"))

(test the-cancel-route-takes-the-same-session-as-the-message-route
  "With grants, POST /api/cancel without an open session is refused 401, like POST /api/message."
  (multiple-value-bind (priv pub) (aion/signature:generate-key-pair)
    (declare (ignore priv))
    (let ((app (%grant-app pub)))
      (is (eql 401 (nth-value 0 (%call app :post "/api/cancel"))))
      (is (eql 401 (nth-value 0 (%call app :post "/api/cancel" :authorization "Session nope")))))))

(test start-and-serve-forever-run-a-turn-with-their-default-responder
  "START without :RESPONDER serves an app whose turns run. Before #1339 its default responder was
RUN-TURN, called with the locale as a third argument, and every turn ended in \"odd number of
&KEY arguments\". The JSON path runs the turn before it answers, so its reply is the check. The
stub provider streams, so the default responder's draft is exercised too. SERVE-FOREVER's
default is the same function, read from its lambda list."
  (let ((release (list t)) (closed-at (list nil))
        (port (free-port)))
    (aion/test-http:with-server (s (%waiting-provider-server release closed-at))
      (let ((handler (web:start :agent (%stub-agent s) :server :hunchentoot :port port
                                :transport :poll)))
        (unwind-protect
             (let ((r (aion/http-client:send-request
                       (aion/http-client:make-request
                        :method :post :url (format nil "http://127.0.0.1:~D/api/message" port)
                        ;; The Origin is the server's own, as a browser sends it, which the
                        ;; server's CSRF check requires of a POST.
                        :headers `(("Content-Type" . "application/json")
                                   ("Accept" . "application/json")
                                   ("Origin" . ,(format nil "http://127.0.0.1:~D" port)))
                        :content "{\"message\":\"what is two and two?\"}"
                        :read-timeout 15 :follow-redirects nil)
                       '())))
               (is (eql 200 (aion/http-client:response-status r)))
               (is (equal "{\"reply\":\"Two and two is four.\"}"
                          (aion/http-client:response-body r))))
          (web:stop handler)))))
  (require :sb-introspect)
  (let ((lambda-list (uiop:symbol-call :sb-introspect :function-lambda-list #'web:serve-forever)))
    (is (equal '(function web::%default-responder)
               (second (find 'web::responder lambda-list
                             :key (lambda (x) (and (consp x) (first x))))))
        "~S" lambda-list)))

(test make-app-refuses-a-stream-text-it-does-not-know
  (signals error (%echo-app :stream-text :yes)))
