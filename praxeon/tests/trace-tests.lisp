;;;; trace-tests.lisp --- praxeon/trace (#1225), with a stub provider and no network except a
;;;; stub collector on 127.0.0.1 that each export test starts and stops.

(cl:defpackage #:praxeon/trace/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:trace #:praxeon/trace)
                    (#:llm #:praxeon/llm)
                    (#:actor #:praxeon/actor)
                    (#:evt #:praxeon/event)
                    (#:th #:aion/test-http)
                    (#:jzon #:com.inuoe.jzon))
  (:export #:run-tests))

(cl:in-package #:praxeon/trace/tests)

(def-suite trace-suite :description "praxeon/trace: OpenTelemetry spans from a turn's events (#1225).")
(in-suite trace-suite)

(defun run-tests ()
  ;; Quiet, as every framework suite is (docs/logging.md); a test that reads the log raises it.
  (aion/log:level! :warn)
  (run! 'trace-suite))

;;; --- a stub provider -------------------------------------------------------------------------

(defclass stub-provider (llm:provider)
  ((script :initarg :script :accessor stub-script)
   (fail :initarg :fail :initform nil :reader stub-fail))
  (:documentation "Hands back queued completions in order, or signals when FAIL is true."))

(defmethod llm:complete ((p stub-provider) messages &key system tools max-tokens temperature
                                                         tool-choice)
  (declare (ignore messages system tools max-tokens temperature tool-choice))
  (when (stub-fail p) (error "the stub provider failed"))
  (or (pop (stub-script p)) (llm:make-completion :text "" :stop-reason :end)))

(defmethod llm:model-of ((p stub-provider)) "stub-model-1")

(defparameter +marker+ "ZEBRA-CONTENT-7731"
  "Put into every piece of content a test turn has: the tool arguments, the tool results, the
delegated task and the answer. A span that carries content carries this.")

(defun %args (&rest kv)
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on kv by #'cddr do (setf (gethash k h) v))
    h))

(defun %two-tool-agent (&key private)
  "An agent whose first step calls two means, add and lookup, and whose second answers. Every
piece of content in the turn holds +MARKER+."
  (let* ((calls (list (llm:make-tool-call :id "t1" :name "add"
                                          :arguments (%args "a" 2 "b" 3 "note" +marker+))
                      (llm:make-tool-call :id "t2" :name "lookup"
                                          :arguments (%args "q" +marker+))))
         (agent (actor:make-agent
                 :name "calculator" :private private
                 :provider (make-instance
                            'stub-provider
                            :script (list (llm:make-completion :tool-calls calls
                                                               :stop-reason :tool-use
                                                               :input-tokens 100
                                                               :output-tokens 20)
                                          (llm:make-completion
                                           :text (format nil "The sum is 5. ~A" +marker+)
                                           :stop-reason :end
                                           :input-tokens 140 :output-tokens 12
                                           :cache-read-tokens 64))))))
    (actor:register-means agent "add" "adds a and b"
                          (lambda (in)
                            (sleep 0.02)
                            (format nil "~A ~A" (+ (gethash "a" in) (gethash "b" in)) +marker+)))
    (actor:register-means agent "lookup" "looks q up"
                          (lambda (in) (declare (ignore in)) (format nil "found ~A" +marker+)))
    agent))

(defun %traced-turn (agent input &rest tracer-options)
  "Run one turn of AGENT under a fresh tracer with a memory exporter. Returns the answer and
the exported spans."
  (let* ((exporter (trace:make-memory-exporter))
         (tracer (apply #'trace:make-tracer :exporter exporter tracer-options))
         (answer (trace:with-tracing (tracer) (actor:run-turn agent input))))
    (values answer (trace:exported-spans exporter))))

(defun %named (spans operation)
  (remove-if-not (lambda (s) (equal operation (trace:span-attribute s trace:+operation-name+)))
                 spans))

(defun %content-in (spans)
  "Where content appears in SPANS: each content attribute present, and whether +MARKER+ occurs
anywhere in their OTLP JSON. NIL when there is none."
  (append (loop for s in spans
                append (loop for name in trace:+content-attributes+
                             when (trace:span-attribute s name)
                               collect (list (trace:span-name s) name)))
          (when (search +marker+ (trace:otlp-json spans))
            (list :marker-in-otlp-json))))

;;; --- the span tree ---------------------------------------------------------------------------

(test a-turn-with-two-tool-calls-makes-one-turn-span-two-chat-spans-and-two-tool-spans
  (multiple-value-bind (answer spans)
      (aion/log:with-context (:request-id "req-1225")
        (%traced-turn (%two-tool-agent) "add 2 and 3"))
    (is (search "The sum is 5." answer))
    (is (= 5 (length spans)) "spans: ~S" (mapcar #'trace:span-name spans))
    (let ((turns (%named spans "invoke_agent"))
          (chats (sort (copy-list (%named spans "chat")) #'<
                       :key (lambda (s) (trace:span-attribute s trace:+step+))))
          (tools (%named spans "execute_tool")))
      (is (= 1 (length turns)))
      (is (= 2 (length chats)))
      (is (= 2 (length tools)))
      (let ((turn (first turns)))
        ;; parentage: one trace, the turn at its root, everything else its child
        (is (null (trace:span-parent-id turn)))
        (is (every (lambda (s) (equal (trace:span-trace-id turn) (trace:span-trace-id s))) spans))
        (is (every (lambda (s) (equal (trace:span-span-id turn) (trace:span-parent-id s)))
                   (append chats tools)))
        (is (= 32 (length (trace:span-trace-id turn))))
        (is (every (lambda (s) (= 16 (length (trace:span-span-id s)))) spans))
        (is (= 5 (length (remove-duplicates (mapcar #'trace:span-span-id spans) :test #'equal))))
        ;; names and attributes
        (is (string= "invoke_agent calculator" (trace:span-name turn)))
        (is (equal "calculator" (trace:span-attribute turn trace:+agent-name+)))
        (is (equal "stub-model-1" (trace:span-attribute turn trace:+request-model+)))
        (is (equal "stub-provider" (trace:span-attribute turn trace:+provider-name+)))
        (is (equal "answered" (trace:span-attribute turn trace:+turn-outcome+)))
        (is (equal "req-1225" (trace:span-attribute turn (trace:correlation-attribute :request-id)))
            "the turn span records the aion/log correlation id")
        (is (eq :unset (trace:span-status turn))))
      (destructuring-bind (first-call second-call) chats
        (is (string= "chat stub-model-1" (trace:span-name first-call)))
        (is (eq :client (trace:span-kind first-call)))
        (is (equal "stub-model-1" (trace:span-attribute first-call trace:+request-model+)))
        (is (= 100 (trace:span-attribute first-call trace:+usage-input-tokens+)))
        (is (= 20 (trace:span-attribute first-call trace:+usage-output-tokens+)))
        (is (equal '("tool_calls") (trace:span-attribute first-call trace:+response-finish-reasons+)))
        (is (= 140 (trace:span-attribute second-call trace:+usage-input-tokens+)))
        (is (= 64 (trace:span-attribute second-call trace:+usage-cache-read-tokens+)))
        (is (equal '("stop") (trace:span-attribute second-call trace:+response-finish-reasons+))))
      (let ((add (find "add" tools :key (lambda (s) (trace:span-attribute s trace:+tool-name+))
                                   :test #'equal))
            (lookup (find "lookup" tools :key (lambda (s) (trace:span-attribute s trace:+tool-name+))
                                         :test #'equal)))
        (is (string= "execute_tool add" (trace:span-name add)))
        (is (equal "t1" (trace:span-attribute add trace:+tool-call-id+)))
        (is (equal "t2" (trace:span-attribute lookup trace:+tool-call-id+)))
        (is (equal "ok" (trace:span-attribute add trace:+tool-outcome+)))
        (is (integerp (trace:span-attribute add trace:+tool-duration-ms+)))
        (is (>= (trace:span-attribute add trace:+tool-duration-ms+) 15)
            "add sleeps 20 ms: ~S" (trace:span-attribute add trace:+tool-duration-ms+))
        (is (>= (trace:span-duration-ns add) 15000000)
            "the add span lasts at least the means' 20 ms: ~S ns" (trace:span-duration-ns add))
        ;; the calls come after the first model call and before the second
        (is (<= (trace:span-end (first chats)) (trace:span-start add)))
        (is (<= (trace:span-end lookup) (trace:span-start (second chats))))))
    ;; durations: every span ended, and none ends before it starts
    (is (every (lambda (s) (and (trace:span-end s) (>= (trace:span-duration-ns s) 0))) spans))))

(test a-sub-agent-s-turn-is-a-child-of-the-tool-call-that-delegated-to-it
  (let* ((sub (actor:make-agent
               :name "mathematician"
               :provider (make-instance 'stub-provider
                                        :script (list (llm:make-completion
                                                       :text "42" :stop-reason :end)))))
         (call (llm:make-tool-call :id "d1" :name "mathematician"
                                   :arguments (%args "task" "what is 6 times 7?")))
         (coordinator (actor:make-agent
                       :name "coordinator"
                       :provider (make-instance
                                  'stub-provider
                                  :script (list (llm:make-completion :tool-calls (list call)
                                                                     :stop-reason :tool-use)
                                                (llm:make-completion :text "It is 42."
                                                                     :stop-reason :end))))))
    (actor:register-agent-as-means coordinator sub)
    (multiple-value-bind (answer spans) (%traced-turn coordinator "delegate the math")
      (is (string= "It is 42." answer))
      (let* ((turns (%named spans "invoke_agent"))
             (outer (find "coordinator" turns :key (lambda (s) (trace:span-attribute s trace:+agent-name+))
                                              :test #'equal))
             (inner (find "mathematician" turns :key (lambda (s) (trace:span-attribute s trace:+agent-name+))
                                                :test #'equal))
             (tool (first (%named spans "execute_tool"))))
        (is (= 2 (length turns)))
        (is (= 1 (length (%named spans "execute_tool"))))
        (is (= 3 (length (%named spans "chat"))) "two coordinator steps and one sub-agent step")
        (is (null (trace:span-parent-id outer)))
        (is (equal (trace:span-span-id outer) (trace:span-parent-id tool)))
        (is (equal (trace:span-span-id tool) (trace:span-parent-id inner))
            "the sub-agent's turn is a child of the execute_tool span")
        (is (equal "mathematician" (trace:span-attribute tool trace:+delegate-agent+)))
        (is (equal (trace:span-trace-id outer) (trace:span-trace-id inner)))
        (let ((inner-chat (find (trace:span-span-id inner) (%named spans "chat")
                                :key #'trace:span-parent-id :test #'equal)))
          (is-true inner-chat "the sub-agent's model call is a child of its turn"))
        (is (<= (trace:span-start tool) (trace:span-start inner)))
        (is (<= (trace:span-end inner) (trace:span-end tool)))))))

;;; --- content ---------------------------------------------------------------------------------

(test spans-carry-no-content-by-default
  "No tool argument, tool result or answer: neither as an attribute nor anywhere in the OTLP
JSON. The control is the next test, which runs the same check where content is let through."
  (multiple-value-bind (answer spans) (%traced-turn (%two-tool-agent) "add 2 and 3")
    (is (search +marker+ answer) "the turn itself did see the content")
    (is (= 5 (length spans)))
    (is (null (%content-in spans)) "content found in the spans: ~S" (%content-in spans))))

(test control-the-content-check-sees-content-when-it-is-captured
  "The control for the test above: with :CAPTURE-CONTENT T the same check finds content, so a
check that passes there can see content when it is present."
  (multiple-value-bind (answer spans) (%traced-turn (%two-tool-agent) "add 2 and 3"
                                                    :capture-content t)
    (declare (ignore answer))
    (let ((found (%content-in spans)))
      (is (member :marker-in-otlp-json found))
      (is (find trace:+tool-call-arguments+ found :key #'second :test #'equal))
      (is (find trace:+tool-call-result+ found :key #'second :test #'equal))
      (is (find trace:+output-messages+ found :key #'second :test #'equal)))))

(test withhold-content-wins-over-capture-content
  "A private agent's turn binds EVT:*WITHHOLD-CONTENT*, and a tracer made to capture content
records none of it."
  (multiple-value-bind (answer spans) (%traced-turn (%two-tool-agent :private t) "add 2 and 3"
                                                    :capture-content t)
    (declare (ignore answer))
    (is (= 5 (length spans)))
    (is (null (%content-in spans)) "content found in the spans: ~S" (%content-in spans))))

;;; --- a turn that fails -----------------------------------------------------------------------

(test a-turn-that-signals-out-of-with-tracing-ends-its-span-as-failed
  (let* ((exporter (trace:make-memory-exporter))
         (tracer (trace:make-tracer :exporter exporter))
         (agent (actor:make-agent :name "broken"
                                  :provider (make-instance 'stub-provider :fail t))))
    (signals error (trace:with-tracing (tracer) (actor:run-turn agent "hello")))
    (let* ((spans (trace:exported-spans exporter))
           (turn (first (%named spans "invoke_agent"))))
      (is (= 1 (length (%named spans "invoke_agent"))))
      (is (equal "failed" (trace:span-attribute turn trace:+turn-outcome+)))
      (is (eq :error (trace:span-status turn)))
      (is (stringp (trace:span-attribute turn trace:+error-type+)))
      (is (every #'trace:span-end spans) "every span was ended"))))

;;; --- OTLP/HTTP export ------------------------------------------------------------------------

(defun %collector (requests &key (status 200) (delay 0))
  "A stub collector's handler: records each request's body in the list REQUESTS (a cons whose
car is the list), waits DELAY seconds, and answers STATUS."
  (lambda (request stream)
    (push request (car requests))
    (when (plusp delay) (sleep delay))
    (th:write-response stream status '(("Content-Type" . "application/json")) "{}")))

(defun %value (key-values key)
  "The AnyValue for KEY in an OTLP attribute vector, or NIL."
  (let ((kv (find key key-values :key (lambda (kv) (gethash "key" kv)) :test #'equal)))
    (and kv (gethash "value" kv))))

(test the-otlp-exporter-sends-a-batch-of-otlp-json-to-v1-traces
  (let ((requests (list '())))
    (th:with-server (server (%collector requests))
      (let* ((exporter (trace:make-otlp-exporter :endpoint (th:server-url server "/v1/traces")
                                                 :service-name "trace-test"
                                                 :headers '(("x-collector-key" . "k1"))))
             (tracer (trace:make-tracer :exporter exporter)))
        (unwind-protect
             (progn
               (trace:with-tracing (tracer) (actor:run-turn (%two-tool-agent) "add 2 and 3"))
               (is-true (trace:flush-exporter exporter :timeout 10)))
          (trace:shutdown-exporter exporter :timeout 5))
        (is (= 5 (trace:otlp-exporter-sent-spans exporter)))
        (is (= 0 (trace:otlp-exporter-failed-batches exporter)))))
    (let ((received (car requests)))
      (is (= 1 (length received)) "one batch for one turn: ~S" (length received))
      (let* ((request (first received))
             (body (jzon:parse (th:request-body-string request)))
             (resource-spans (gethash "resourceSpans" body))
             (rs (aref resource-spans 0))
             (scope-spans (aref (gethash "scopeSpans" rs) 0))
             (spans (gethash "spans" scope-spans)))
        (is (string= "POST" (th:request-method request)))
        (is (string= "/v1/traces" (th:request-path request)))
        (is (search "application/json" (th:request-header request "Content-Type")))
        (is (equal "k1" (th:request-header request "x-collector-key")))
        (is (= 1 (length resource-spans)))
        (is (equal "trace-test"
                   (gethash "stringValue"
                            (%value (gethash "attributes" (gethash "resource" rs)) "service.name"))))
        (is (equal "praxeon/trace" (gethash "name" (gethash "scope" scope-spans))))
        (is (= 5 (length spans)))
        (loop for span across spans
              do (is (= 32 (length (gethash "traceId" span))))
                 (is (= 16 (length (gethash "spanId" span))))
                 (is (every (lambda (c) (digit-char-p c 16)) (gethash "spanId" span)))
                 (is (stringp (gethash "startTimeUnixNano" span)))
                 (is (<= (parse-integer (gethash "startTimeUnixNano" span))
                         (parse-integer (gethash "endTimeUnixNano" span))))
                 (is (member (gethash "kind" span) '(1 3)))
                 (is (integerp (gethash "code" (gethash "status" span))))
                 (is (stringp (gethash "stringValue"
                                       (%value (gethash "attributes" span) trace:+operation-name+)))))
        (let ((roots (remove-if (lambda (s) (nth-value 1 (gethash "parentSpanId" s))) spans))
              (chat (find-if (lambda (s) (search "chat" (gethash "name" s))) spans)))
          (is (= 1 (length roots)) "only the turn span has no parentSpanId")
          (is (equal "100" (gethash "intValue" (%value (gethash "attributes" chat)
                                                       trace:+usage-input-tokens+))))
          (is (equal "chat" (gethash "stringValue" (%value (gethash "attributes" chat)
                                                           trace:+operation-name+))))
          (is (= 3 (gethash "kind" chat)) "a model call is a CLIENT span"))))))

(test an-export-failure-is-logged-with-a-count-and-neither-fails-nor-slows-the-turn
  "The collector waits two seconds and then answers 500. The turn returns its answer well
before the collector answers, and the failure is counted and logged with its count, with no
span content in the log line."
  (let ((requests (list '()))
        (out (make-string-output-stream)))
    (unwind-protect
         (th:with-server (server (%collector requests :status 500 :delay 2))
           (aion/log:setup :env :dev :level :warn :stream out)
           (let* ((exporter (trace:make-otlp-exporter :endpoint (th:server-url server "/v1/traces")
                                                      :interval 0.1))
                  (tracer (trace:make-tracer :exporter exporter))
                  (started (get-internal-real-time))
                  (answer (trace:with-tracing (tracer)
                            (actor:run-turn (%two-tool-agent) "add 2 and 3")))
                  (seconds (/ (- (get-internal-real-time) started)
                              internal-time-units-per-second)))
             (unwind-protect
                  (progn
                    (is (search "The sum is 5." answer) "the turn completed")
                    (is (< seconds 1) "the turn waited for the collector: ~,2F s" seconds)
                    (is-true (trace:flush-exporter exporter :timeout 30)))
               (trace:shutdown-exporter exporter :timeout 30))
             (is (= 1 (trace:otlp-exporter-failed-batches exporter)))
             (is (= 5 (trace:otlp-exporter-failed-spans exporter)))
             (is (= 0 (trace:otlp-exporter-sent-spans exporter)))
             (let ((lines (remove-if-not (lambda (l) (search "praxeon/trace: export failed" l))
                                         (uiop:split-string (get-output-stream-string out)
                                                            :separator '(#\Newline)))))
               (is (plusp (length lines)) "no log line for the failure")
               (is (every (lambda (l) (search "failed-batches=" l)) lines) "~S" lines)
               (is (every (lambda (l) (search "status=500" l)) lines) "~S" lines)
               (is (notany (lambda (l) (search +marker+ l)) lines) "~S" lines))))
      (aion/log:setup :env :dev :level :warn :stream *standard-output*))))

(test an-unreachable-collector-is-counted-as-a-failure
  (let* ((port (let ((server (th:start-server (lambda (r s) (declare (ignore r s))))))
                 (prog1 (th:server-port server) (th:stop-server server))))
         (exporter (trace:make-otlp-exporter
                    :endpoint (format nil "http://127.0.0.1:~D/v1/traces" port) :timeout 5))
         (tracer (trace:make-tracer :exporter exporter)))
    (unwind-protect
         (progn
           (is (search "The sum is 5."
                       (trace:with-tracing (tracer) (actor:run-turn (%two-tool-agent) "add"))))
           (is-true (trace:flush-exporter exporter :timeout 30)))
      (trace:shutdown-exporter exporter :timeout 10))
    (is (= 1 (trace:otlp-exporter-failed-batches exporter)))
    (is (= 0 (trace:otlp-exporter-sent-spans exporter)))))
