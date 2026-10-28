;;;; stream-tests.lisp --- streaming a completion and cancelling it (#984)
;;;;
;;;; Each stub provider is a server on 127.0.0.1 that answers one model reply two ways: as the
;;;; whole JSON when the request does not ask for a stream, and as Server-Sent Events when it
;;;; does. A streamed completion has to equal the whole one, field by field, so the tests compare
;;;; the two rather than a streamed completion with values written out here.

(cl:in-package #:praxeon/tests)

(def-suite llm-stream :description "praxeon/llm: streaming a completion, and cancelling it (#984)."
  :in praxeon)
(in-suite llm-stream)

(defun %sse (stream events)
  "Write EVENTS, a list of (EVENT-NAME-OR-NIL . DATA-STRING), to STREAM as Server-Sent Events."
  (dolist (e events)
    (write-sequence (sb-ext:string-to-octets
                     (format nil "~@[event: ~A~%~]data: ~A~%~%" (car e) (cdr e))
                     :external-format :utf-8)
                    stream)
    (finish-output stream)))

(defun %wants-stream-p (request)
  (let ((body (jzon:parse (aion/test-http:request-body-string request))))
    (and (hash-table-p body) (eq t (gethash "stream" body)))))

(defun %usage-asked-p (request)
  "Whether REQUEST asks an OpenAI-compatible server for the usage chunk."
  (let* ((body (jzon:parse (aion/test-http:request-body-string request)))
         (options (gethash "stream_options" body)))
    (and (hash-table-p options) (eq t (gethash "include_usage" options)))))

(defun %provider-server (whole events &key (status 200))
  "A handler answering a streamed request with EVENTS and any other with WHOLE, a JSON string.
Like an OpenAI-compatible server, it leaves out a chunk with an empty choices list, the usage
chunk, unless the request asked for it. Each request's body is kept, newest first, in the
returned second value's car."
  (let ((seen (list '())))
    (values
     (lambda (request stream)
       (push (aion/test-http:request-body-string request) (car seen))
       (if (%wants-stream-p request)
           (progn
             (aion/test-http:write-head stream status '(("Content-Type" . "text/event-stream")
                                                        ("Connection" . "close")))
             (%sse stream (if (%usage-asked-p request)
                              events
                              (remove-if (lambda (e) (search "\"choices\":[]" (cdr e))) events))))
           (aion/test-http:write-response stream status '(("Content-Type" . "application/json"))
                                          whole)))
     seen)))

;;; --- Anthropic ------------------------------------------------------------------------------

(defparameter +anthropic-whole+
  "{\"type\":\"message\",\"role\":\"assistant\",\"stop_reason\":\"tool_use\",
    \"content\":[{\"type\":\"text\",\"text\":\"Let me look that up — één moment.\"},
                 {\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"lookup\",
                  \"input\":{\"q\":\"weather\",\"n\":3}}],
    \"usage\":{\"input_tokens\":120,\"output_tokens\":42,
               \"cache_read_input_tokens\":100,\"cache_creation_input_tokens\":0}}")

(defparameter +anthropic-events+
  '(("message_start" . "{\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":120,\"output_tokens\":1,\"cache_read_input_tokens\":100,\"cache_creation_input_tokens\":0}}}")
    ("content_block_start" . "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}")
    ("ping" . "{\"type\":\"ping\"}")
    ("content_block_delta" . "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Let me look \"}}")
    ("content_block_delta" . "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"that up — één moment.\"}}")
    ("content_block_stop" . "{\"type\":\"content_block_stop\",\"index\":0}")
    ("content_block_start" . "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"lookup\",\"input\":{}}}")
    ("content_block_delta" . "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"q\\\": \\\"wea\"}}")
    ("content_block_delta" . "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"ther\\\", \\\"n\\\": 3}\"}}")
    ("content_block_stop" . "{\"type\":\"content_block_stop\",\"index\":1}")
    ("message_delta" . "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":42}}")
    ("message_stop" . "{\"type\":\"message_stop\"}")))

(defun %streaming-anthropic (server)
  (make-instance 'llm:anthropic :api-key "test-key" :model "m"
                                :endpoint (aion/test-http:server-url server "/v1/messages")))

(defun %stream-fields (c)
  (list (llm:completion-text c)
        (mapcar (lambda (tc) (list (llm:tool-call-id tc) (llm:tool-call-name tc)
                                   (jzon:stringify (llm:tool-call-arguments tc))))
                (llm:completion-tool-calls c))
        (llm:completion-stop-reason c)
        (llm:completion-input-tokens c) (llm:completion-output-tokens c)
        (llm:completion-cache-read-tokens c) (llm:completion-cache-write-tokens c)))

(defun %streamed-and-whole (provider-at whole events)
  "Complete once without streaming and once with *ON-TEXT* bound, against a server answering
WHOLE and EVENTS. Returns the two completions, the pieces *ON-TEXT* received in order, and the
two request bodies, the plain one first."
  (multiple-value-bind (handler seen) (%provider-server whole events)
    (aion/test-http:with-server (s handler)
      (let* ((p (funcall provider-at s))
             (messages (list (llm:msg "user" "hi")))
             (plain (llm:complete p messages))
             (pieces '())
             (streamed (let ((llm:*on-text* (lambda (piece) (push piece pieces))))
                         (llm:complete p messages))))
        (values plain streamed (reverse pieces) (reverse (car seen)))))))

(test an-anthropic-streamed-completion-equals-the-whole-one
  "With *ON-TEXT* bound the request asks for a stream; the completion put together from the
events has the same text, tool call, stop reason and four token counts as the whole reply, and
*ON-TEXT* got the text in its pieces, in order. Without it the request is the one sent before."
  (multiple-value-bind (plain streamed pieces bodies)
      (%streamed-and-whole #'%streaming-anthropic +anthropic-whole+ +anthropic-events+)
    (is (equal (%stream-fields plain) (%stream-fields streamed)))
    (is (equal '("Let me look " "that up — één moment.") pieces))
    (is (eq :tool-use (llm:completion-stop-reason streamed)))
    (is (null (search "\"stream\"" (first bodies))) "the plain request does not mention a stream")
    (is (search "\"stream\":true" (second bodies)))))

(test an-anthropic-error-event-is-a-failed-request
  "An error event after the stream began signals PROVIDER-REQUEST-FAILED with the error's type."
  (multiple-value-bind (handler)
      (%provider-server "{}" '(("message_start" . "{\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":5}}}")
                               ("error" . "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}")))
    (aion/test-http:with-server (s handler)
      (let ((c (handler-case (let ((llm:*on-text* (lambda (x) x)))
                               (llm:complete (%streaming-anthropic s) (list (llm:msg "user" "hi"))))
                 (cnd:provider-request-failed (c) c))))
        (is (typep c 'cnd:provider-request-failed))
        (is (equal "overloaded_error" (and c (cnd:provider-request-failed-error-type c))))))))

(test a-streamed-request-refused-with-a-status-is-a-failed-request-with-its-body
  "A 429 to a streamed request signals PROVIDER-REQUEST-FAILED with the status and the body."
  (let ((body "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow\"}}"))
    (aion/test-http:with-server
        (s (lambda (request stream)
             (declare (ignore request))
             (aion/test-http:write-response stream 429 '() body)))
      (let ((c (handler-case (let ((llm:*on-text* (lambda (x) x)))
                               (llm:complete (%streaming-anthropic s) (list (llm:msg "user" "hi"))))
                 (cnd:provider-request-failed (c) c))))
        (is (eql 429 (and c (cnd:provider-request-failed-status c))))
        (is (equal "rate_limit_error" (and c (cnd:provider-request-failed-error-type c))))
        (is (equal body (and c (cnd:provider-request-failed-body c))))))))

;;; --- OpenAI-compatible ----------------------------------------------------------------------

(defparameter +openai-whole+
  "{\"choices\":[{\"index\":0,\"finish_reason\":\"tool_calls\",
     \"message\":{\"role\":\"assistant\",\"content\":\"Checking — één.\",
       \"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",
                        \"function\":{\"name\":\"lookup\",\"arguments\":\"{\\\"q\\\":\\\"weather\\\"}\"}},
                       {\"id\":\"call_2\",\"type\":\"function\",
                        \"function\":{\"name\":\"clock\",\"arguments\":\"{}\"}}]}}],
    \"usage\":{\"prompt_tokens\":90,\"completion_tokens\":17,
               \"prompt_tokens_details\":{\"cached_tokens\":64}}}")

(defparameter +openai-events+
  '((nil . "{\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Checking \"}}]}")
    (nil . "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"— één.\"}}]}")
    (nil . "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"\"}}]}}]}")
    (nil . "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"q\\\":\\\"wea\"}}]}}]}")
    (nil . "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"call_2\",\"type\":\"function\",\"function\":{\"name\":\"clock\",\"arguments\":\"{}\"}}]}}]}")
    (nil . "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"ther\\\"}\"}}]}}]}")
    (nil . "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}")
    (nil . "{\"choices\":[],\"usage\":{\"prompt_tokens\":90,\"completion_tokens\":17,\"prompt_tokens_details\":{\"cached_tokens\":64}}}")
    (nil . "[DONE]")))

(defun %streaming-openai (server)
  (make-instance 'llm:openai-compatible :base-url (aion/test-http:server-url server "/v1")
                                        :model "m" :api-key "test-key"))

(test an-openai-streamed-completion-equals-the-whole-one
  "The chunks, with two tool calls interleaved by index and the usage in a chunk of its own, make
the same completion as the whole reply. The streamed request asks for the usage chunk."
  (multiple-value-bind (plain streamed pieces bodies)
      (%streamed-and-whole #'%streaming-openai +openai-whole+ +openai-events+)
    (is (equal (%stream-fields plain) (%stream-fields streamed)))
    (is (equal '("Checking " "— één.") pieces))
    (is (= 2 (length (llm:completion-tool-calls streamed))))
    (is (null (search "\"stream\"" (first bodies))))
    (is (search "\"stream\":true" (second bodies)))
    (is (search "\"include_usage\":true" (second bodies)))))

;;; --- cancelling -----------------------------------------------------------------------------

(defun %stalling-server (events closed-at)
  "A handler that sends EVENTS as a stream and then nothing, as a provider does while the model
works, for at most 10 seconds. A thread of its own reads the connection and stores the time in
CLOSED-AT's car when the client closes it."
  (lambda (request stream)
    (declare (ignore request))
    (ignore-errors
     (aion/test-http:write-head stream 200 '(("Content-Type" . "text/event-stream")
                                             ("Connection" . "close")))
     (%sse stream events)
     (let* ((ending (list nil))
            ;; THREAD-LIFETIME: blocks reading the connection until the client closes it, or until
            ;; this handler closes it below; the JOIN waits for it.
            (watcher (sb-thread:make-thread
                      (lambda ()
                        (ignore-errors (read-byte stream nil nil))
                        (unless (car ending) (setf (car closed-at) (get-internal-real-time))))
                      :name "stub provider close watcher")))
       (loop repeat 100 until (car closed-at) do (sleep 0.1))
       (setf (car ending) t)
       (unless (car closed-at) (ignore-errors (close stream :abort t)))
       (aion/test-threads:join watcher :timeout 15)))))

(defun %utf8-length (string) (length (sb-ext:string-to-octets string :external-format :utf-8)))

(defun %cancel-after (provider-at events &key (when-text t))
  "Complete against a server that sends EVENTS and then stalls, with *CANCEL* bound, and cancel
from another thread: once *ON-TEXT* has had a piece when WHEN-TEXT, or after half a second.
Returns the COMPLETION-CANCELLED (or whatever ended the call), the seconds between the cancel and
the server seeing the connection close (NIL if it did not), and the text *ON-TEXT* received."
  (let ((closed-at (list nil))
        (cancel (aion/http-client:make-request-cancel))
        (got (make-string-output-stream))
        (first-text (list nil))
        (cancelled-at (list nil)))
    (aion/test-http:with-server (s (%stalling-server events closed-at))
      (let* ((p (funcall provider-at s))
             ;; THREAD-LIFETIME: waits for the first piece of text (or half a second), cancels,
             ;; and ends. The JOIN below waits for it.
             (canceller (sb-thread:make-thread
                         (lambda ()
                           (loop repeat 50 until (or (not when-text) (car first-text))
                                 do (sleep 0.1))
                           (sleep 0.5)
                           (setf (car cancelled-at) (get-internal-real-time))
                           (aion/http-client:cancel-request cancel))
                         :name "test canceller"))
             (outcome (handler-case
                          (let ((llm:*cancel* cancel)
                                (llm:*on-text* (lambda (piece)
                                                 (write-string piece got)
                                                 (setf (car first-text) t))))
                            (llm:complete p (list (llm:msg "user" "hi"))))
                        (error (c) c))))
        (aion/test-threads:join canceller :timeout 15)
        (loop repeat 30 until (car closed-at) do (sleep 0.1))
        (values outcome
                (and (car closed-at)
                     (/ (- (car closed-at) (car cancelled-at)) internal-time-units-per-second))
                (get-output-stream-string got))))))

(test cancelling-an-anthropic-stream-closes-the-connection-and-reports-what-arrived
  "A cancel while the provider is quiet ends COMPLETE with COMPLETION-CANCELLED, and the server
sees the connection close within two seconds. The condition has the input and cache counts from
message_start, no output count (message_start's 1 is not a final count), the text that arrived,
and an estimate of at least the octets of that text and the tool call's name and arguments."
  (let ((events (subseq +anthropic-events+ 0 8)))   ; up to the first piece of the tool's input
    (multiple-value-bind (c seconds text) (%cancel-after #'%streaming-anthropic events)
      (is (typep c 'cnd:completion-cancelled) "ended with ~A" c)
      (is-true seconds "the server saw the connection close")
      (when seconds (is (< seconds 2) "within two seconds of the cancel, not ~,1F" seconds))
      (when (typep c 'cnd:completion-cancelled)
        (is (eql 120 (cnd:completion-cancelled-input-tokens c)))
        (is (eql 100 (cnd:completion-cancelled-cache-read-tokens c)))
        (is (eql 0 (cnd:completion-cancelled-cache-write-tokens c)))
        (is (null (cnd:completion-cancelled-output-tokens c)))
        (is (equal "Let me look that up — één moment." (cnd:completion-cancelled-text c)))
        (is (equal text (cnd:completion-cancelled-text c)))
        (is (>= (cnd:completion-cancelled-estimated-output c)
                (+ (%utf8-length "Let me look that up — één moment.") (%utf8-length "lookup")
                   (%utf8-length "{\"q\": \"wea"))))))))

(test cancelling-an-openai-stream-before-its-usage-reports-no-counts
  "An OpenAI-compatible server sends its counts at the end, so a cancel before then reports none,
and the estimate covers the text and the tool call's name and arguments that arrived."
  (let ((events (subseq +openai-events+ 0 4)))
    (multiple-value-bind (c seconds) (%cancel-after #'%streaming-openai events)
      (is (typep c 'cnd:completion-cancelled) "ended with ~A" c)
      (is-true seconds "the server saw the connection close")
      (when (typep c 'cnd:completion-cancelled)
        (is (null (cnd:completion-cancelled-input-tokens c)))
        (is (null (cnd:completion-cancelled-output-tokens c)))
        (is (>= (cnd:completion-cancelled-estimated-output c)
                (+ (%utf8-length "Checking — één.") (%utf8-length "lookup") (%utf8-length "{\"q\":\"wea"))))))))

(test output-that-is-not-text-is-counted-for-a-cancel
  "With no text at all, only a tool call's input arriving, a cancel's estimate still counts it,
although *ON-TEXT* received nothing."
  (let ((events (list (first +anthropic-events+) (seventh +anthropic-events+)
                      (eighth +anthropic-events+))))
    (multiple-value-bind (c seconds text) (%cancel-after #'%streaming-anthropic events :when-text nil)
      (is (typep c 'cnd:completion-cancelled) "ended with ~A" c)
      (is-true seconds)
      (is (equal "" text))
      (when (typep c 'cnd:completion-cancelled)
        (is (>= (cnd:completion-cancelled-estimated-output c)
                (+ (%utf8-length "lookup") (%utf8-length "{\"q\": \"wea"))))))))

;;; --- a turn -----------------------------------------------------------------------------------

(defparameter +anthropic-answer-events+
  '(("message_start" . "{\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":30,\"output_tokens\":1}}}")
    ("content_block_start" . "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}")
    ("content_block_delta" . "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Two \"}}")
    ("content_block_delta" . "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"and two \"}}")
    ("content_block_delta" . "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"is four.\"}}")
    ("message_delta" . "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":6}}")
    ("message_stop" . "{\"type\":\"message_stop\"}")))

(defun %events-of-type (events type)
  (remove type events :key #'evt:event-type :test-not #'eq))

(test a-turn-with-an-observer-emits-the-text-as-it-arrives
  "While an observer is bound, each piece of the model's text is a :TEXT-DELTA event of the step,
before the :ANSWER, and the pieces joined are the answer."
  (multiple-value-bind (handler) (%provider-server "{}" +anthropic-answer-events+)
    (aion/test-http:with-server (s handler)
      (let* ((events '())
             (ag (actor:make-agent :provider (%streaming-anthropic s)))
             (answer (evt:with-observer ((lambda (e) (push e events)))
                       (actor:run-turn ag "what is two and two?")))
             (events (reverse events))
             (deltas (%events-of-type events :text-delta)))
        (is (equal "Two and two is four." answer))
        (is (equal '("Two " "and two " "is four.") (mapcar (lambda (e) (evt:event-get e :text)) deltas)))
        (is (every (lambda (e) (eql 0 (evt:event-get e :step))) deltas))
        (is (< (position :text-delta events :key #'evt:event-type)
               (position :answer events :key #'evt:event-type)))))))

(test cancelling-a-turn-during-a-model-call-ends-it-and-charges-what-was-spent
  "CANCEL-TURN while the provider is quiet closes its connection; RUN-TURN returns NIL and
:CANCELLED after a :USAGE event with :CANCELLED T, no output count and an estimate of at least the
text that arrived, and a :TURN-ENDED event. The partial text is not in the history. Charging the
:USAGE event moves the ledger by the reported input and the estimated output, and the usage line
marks the output as estimated."
  (let ((closed-at (list nil))
        (events '())
        (cancel (actor:make-turn-cancel))
        (cancelled-at (list nil)))
    (aion/test-http:with-server (s (%stalling-server (subseq +anthropic-answer-events+ 0 4) closed-at))
      (let* ((ag (actor:make-agent :provider (%streaming-anthropic s)))
             ;; THREAD-LIFETIME: waits for the first :TEXT-DELTA (at most 5 seconds), cancels the
             ;; turn and ends. The JOIN below waits for it.
             (canceller (sb-thread:make-thread
                         (lambda ()
                           (loop repeat 50 until (find :text-delta events :key #'evt:event-type)
                                 do (sleep 0.1))
                           (sleep 0.5)
                           (setf (car cancelled-at) (get-internal-real-time))
                           (actor:cancel-turn cancel))
                         :name "test turn canceller"))
             (values (multiple-value-list
                      (evt:with-observer ((lambda (e) (push e events)))
                        (actor:run-turn ag "what is two and two?" :cancel cancel)))))
        (aion/test-threads:join canceller :timeout 15)
        (loop repeat 30 until (car closed-at) do (sleep 0.1))
        (is (equal '(nil :cancelled) values))
        (is-true (car closed-at) "the provider saw its connection close")
        (when (car closed-at)
          (is (< (/ (- (car closed-at) (car cancelled-at)) internal-time-units-per-second) 2)))
        (is (actor:turn-cancelled-p cancel))
        (let* ((events (reverse events))
               (usage (first (%events-of-type events :usage)))
               (ended (first (%events-of-type events :turn-ended))))
          (is-true usage "a :usage event")
          (when usage
            (is (eq t (evt:event-get usage :cancelled)))
            (is (eql 30 (evt:event-get usage :input)))
            (is (null (evt:event-get usage :output)))
            (is (integerp (evt:event-get usage :estimated-input)))
            (is (>= (evt:event-get usage :estimated-output) (%utf8-length "Two and two "))))
          (is (eq :cancelled (and ended (evt:event-get ended :reason))))
          (is (< (position :usage events :key #'evt:event-type)
                 (position :turn-ended events :key #'evt:event-type)))
          (is (null (%events-of-type events :answer)))
          (is (= 1 (length (actor:agent-history ag))) "only the user's message is in the history")
          (when usage
            (let* ((ledger (%ledger :token-cap 100000 :call-cap 10))
                   (before (ceiling:ledger-tokens ledger))
                   (line (ceiling:record-usage-event ledger usage :model "m")))
              (is (= (ceiling:chargeable-tokens :input 30
                                                :output (evt:event-get usage :estimated-output))
                     (- (ceiling:ledger-tokens ledger) before)))
              (is (plusp (- (ceiling:ledger-tokens ledger) before (ceiling:chargeable-tokens :input 30)))
                  "the estimate was charged")
              (is (null (getf line :output)) "the line keeps the reported output, none")
              (is (eq t (getf line :estimated)))
              (is (eql (evt:event-get usage :estimated-output) (getf line :estimated-output)))
              (is (null (getf line :estimated-input)) "a reported input is not replaced"))))))))

(test cancelling-a-turn-during-a-tool-call-lets-the-tool-finish-and-stops-before-the-next-call
  "A cancel while a tool runs does not interrupt it: its result is recorded, and the turn ends
before asking the model again, with a :TURN-ENDED event and no :USAGE event for a stopped call."
  (let* ((cancel (actor:make-turn-cancel))
         (call (llm:make-tool-call :id "t1" :name "slow" :arguments (%args)))
         (provider (make-instance 'recording
                                  :script (list (llm:make-completion :tool-calls (list call)
                                                                     :stop-reason :tool-use)
                                                (llm:make-completion :text "never" :stop-reason :end))))
         (ag (actor:make-agent :provider provider))
         (finished (list nil))
         (events '()))
    (actor:register-means ag "slow" "cancels the turn, then finishes"
                          (lambda (in) (declare (ignore in))
                            (actor:cancel-turn cancel)
                            (sleep 0.2)
                            (setf (car finished) t)
                            "done"))
    (let ((values (multiple-value-list
                   (evt:with-observer ((lambda (e) (push e events)))
                     (actor:run-turn ag "go" :cancel cancel)))))
      (is (equal '(nil :cancelled) values))
      (is-true (car finished) "the tool ran to its end")
      (is (= 1 (length (recording-requests provider))) "the model was asked once")
      (is (= 3 (length (actor:agent-history ag))) "user, the tool call, and its result")
      (let ((ended (first (%events-of-type events :turn-ended))))
        (is (eql 1 (and ended (evt:event-get ended :step)))))
      (is (null (%events-of-type events :usage))))))

(test a-turn-whose-handle-is-already-cancelled-asks-the-model-nothing
  "A turn started with a cancelled handle ends before its first model call."
  (let* ((cancel (actor:make-turn-cancel))
         (provider (make-instance 'recording :script '()))
         (ag (actor:make-agent :provider provider)))
    (actor:cancel-turn cancel)
    (is (equal '(nil :cancelled) (multiple-value-list (actor:run-turn ag "go" :cancel cancel))))
    (is (zerop (length (recording-requests provider))))))
