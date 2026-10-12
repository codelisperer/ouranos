;;;; mcp-tests.lisp --- praxeon/mcp against MCP servers of both eras, run in the test image (#527)
;;;;
;;;; The server below is a handler on aion/test-http, on 127.0.0.1, so nothing here uses the
;;;; network. Each test configures it to speak the current revision (2026-07-28) or a legacy
;;;; one, and to misbehave in the ways the client must survive. It checks the headers a
;;;; current-revision request must carry, as a real server does, so a client that left one out
;;;; fails here too.

(cl:defpackage #:praxeon/mcp/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:mcp #:praxeon/mcp)
                    (#:th #:aion/test-http)
                    (#:jzon #:com.inuoe.jzon)
                    (#:actor #:praxeon/actor)
                    (#:llm #:praxeon/llm)
                    (#:cnd #:praxeon/conditions)
                    (#:evt #:praxeon/event))
  (:export #:run-tests))

(cl:in-package #:praxeon/mcp/tests)

(def-suite mcp :description "praxeon/mcp: both protocol eras, tools, and granting them.")
(in-suite mcp)

(defun run-tests ()
  (let ((results (run 'mcp)))
    (explain! results)
    ;; The failed tests' names go in the error, because the gate shows only the last lines of
    ;; a failed suite's output.
    (unless (results-status results)
      (error "praxeon/mcp tests failed: ~{~A~^; ~}"
             (mapcar (lambda (r)
                       (let ((reason (substitute #\Space #\Newline
                                                 (princ-to-string (fiveam::reason r)))))
                         (format nil "~A: ~A" (fiveam::name (fiveam::test-case r))
                                 (subseq reason 0 (min 200 (length reason))))))
                     (remove-if-not #'fiveam::test-failure-p results))))))

;;; --- the test server -------------------------------------------------------------------

(defstruct (fake (:constructor make-fake
                     (&key (era :modern) (reply :json) (page-size 100) tools
                           require-token (legacy-version "2025-11-25")
                           (task-script '(:completed)) (task-ttl-ms 'null))))
  "What the test server does. ERA is :MODERN, :LEGACY or :DUAL. REPLY is :JSON or :SSE (an
event stream with a notification before the reply). TOOLS is a list of (NAME . PLIST): the
plist's :SCHEMA is the inputSchema, and :DO is :ECHO, :FAIL, :SLOW, :STATUS-500, :INPUT or
:STRUCTURED. REQUIRE-TOKEN is NIL or the bearer token every request must carry."
  era reply page-size tools require-token legacy-version
  (reject-headers nil)
  (fail-next nil) (endless nil) (initialize-status nil) (bad-tools nil)
  ;; Part 4: lists of JSON objects for resources/list, resources/templates/list and
  ;; prompts/list; CONTENTS maps a URI to its contents vector; PROMPT-MESSAGES maps a prompt's
  ;; name to its messages vector. BAD-PAGE makes every listing's page member a string.
  (resources '()) (templates '()) (contents '()) (prompts '()) (prompt-messages '())
  (bad-page nil) (prompt-arguments nil)
  (sessions '()) (end-session nil) (calls 0) (initializes 0)
  ;; Tasks (#532): each new task gets a copy of TASK-SCRIPT, the statuses its polls answer in
  ;; order, the last repeated. TASKS maps a task id to what is left of its script.
  (task-script '(:completed)) (task-poll-ms 1000) (task-ttl-ms 'null)
  ;; An HTTP status every tasks/get is answered with instead of the task, or NIL.
  (get-status nil)
  ;; A bearer token tasks/cancel must carry, or NIL; any other gets a 401, as a sign-in (#587).
  (cancel-token nil)
  (tasks (make-hash-table :test #'equal)) (task-count 0) (cancels '())
  ;; Each tasks/update the client sent (#563), as (taskId . inputResponses), newest first.
  (updates '())
  (lock (sb-thread:make-mutex)))

(defun %obj (&rest kv)
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on kv by #'cddr do (setf (gethash k h) v))
    h))

(defun %reply (stream fake status message &key headers)
  (when (and (eq (fake-reply fake) :sse-capitals) (= status 200))
    (th:write-response stream 200 (append '(("Content-Type" . "Text/Event-Stream")) headers)
                       (format nil "data: ~A~C~C~C~C" (jzon:stringify message)
                               #\Return #\Newline #\Return #\Newline))
    (return-from %reply))
  (when (and (eq (fake-reply fake) :sse-left-open) (= status 200))
    ;; The reply, then nothing: the stream is not ended, as a server that keeps it open would.
    (th:write-head stream 200 (append '(("Content-Type" . "text/event-stream")) headers))
    (write-sequence (sb-ext:string-to-octets (format nil "data: ~A~C~C~C~C" (jzon:stringify message)
                                                     #\Return #\Newline #\Return #\Newline)
                                             :external-format :utf-8)
                    stream)
    (finish-output stream)
    (sleep 3)
    (return-from %reply))
  (if (and (eq (fake-reply fake) :sse) (= status 200))
      (th:write-response stream 200 (append '(("Content-Type" . "text/event-stream")) headers)
                         (format nil ": a comment~C~Cdata: ~A~C~C~Cdata: ~A~C~C~C"
                                 #\Return #\Newline
                                 (jzon:stringify (%obj "jsonrpc" "2.0"
                                                       "method" "notifications/progress"
                                                       "params" (%obj "progress" 1)))
                                 #\Return #\Newline #\Newline
                                 (jzon:stringify message) #\Return #\Newline #\Newline))
      (th:write-response stream status (append '(("Content-Type" . "application/json")) headers)
                         (jzon:stringify message))))

(defun %error-message (id code text)
  (%obj "jsonrpc" "2.0" "id" (or id 'null) "error" (%obj "code" code "message" text)))

(defun %tool-json (name plist)
  (%obj "name" name "description" (format nil "the ~A tool" name)
        "inputSchema" (if (member :schema plist) (getf plist :schema) (%obj "type" "object"))))

(defun %declares-tasks-p (params)
  "Whether PARAMS's _meta declares the Tasks extension."
  (let ((caps (gethash "io.modelcontextprotocol/clientCapabilities" (or (gethash "_meta" params) (%obj)))))
    (and (hash-table-p caps) (hash-table-p (gethash "extensions" caps))
         (nth-value 1 (gethash "io.modelcontextprotocol/tasks" (gethash "extensions" caps))))))

(defun %task-object (fake id status &rest more)
  (apply #'%obj "taskId" id "status" status
         "createdAt" "2026-10-11T00:00:00Z" "lastUpdatedAt" "2026-10-11T00:00:00Z"
         "ttlMs" (fake-task-ttl-ms fake) "pollIntervalMs" (fake-task-poll-ms fake)
         more))

(defun %create-task (fake)
  (let ((id (sb-thread:with-mutex ((fake-lock fake))
              (let ((id (format nil "task-~D" (incf (fake-task-count fake)))))
                (setf (gethash id (fake-tasks fake)) (copy-list (fake-task-script fake)))
                id))))
    (let ((h (%task-object fake id "working")))
      (setf (gethash "resultType" h) "task")
      h)))

(defun %task-poll (fake id)
  "What tasks/get answers for ID: the next status in its script."
  (let ((step (sb-thread:with-mutex ((fake-lock fake))
                (multiple-value-bind (script present) (gethash id (fake-tasks fake))
                  (cond ((not present) :gone)
                        ((cdr script) (pop (gethash id (fake-tasks fake))))
                        (t (car script)))))))
    (flet ((done (h) (setf (gethash "resultType" h) "complete") h))
      ;; (:ELICIT (key mode) ...): input_required with an elicitation/create per (key mode),
      ;; MODE :FORM, :URL, or :SAMPLING for a sampling request under that key (#563).
      (when (and (consp step) (eq (first step) :elicit))
        (let ((requests (%obj)))
          (loop for (key mode) in (rest step)
                do (setf (gethash key requests)
                         (ecase mode
                           (:form (%obj "method" "elicitation/create"
                                        "params" (%obj "mode" "form"
                                                       "message" (format nil "Your name, for ~A?" key)
                                                       "requestedSchema"
                                                       (%obj "type" "object"
                                                             "properties" (%obj "name" (%obj "type" "string"))))))
                           (:url (%obj "method" "elicitation/create"
                                       "params" (%obj "mode" "url" "message" "Sign the form"
                                                      "url" "https://example.org/form")))
                           (:sampling (%obj "method" "sampling/createMessage"
                                            "params" (%obj "maxTokens" 10)))
                           ;; Malformed: the field the mode requires is missing.
                           (:form-bare (%obj "method" "elicitation/create"
                                             "params" (%obj "mode" "form" "message" "No schema")))
                           (:url-bare (%obj "method" "elicitation/create"
                                            "params" (%obj "mode" "url" "message" "No URL"))))))
          (return-from %task-poll
            (done (%task-object fake id "input_required" "inputRequests" requests)))))
      (ecase step
        (:gone (remhash id (fake-tasks fake)) (list :error -32602 "Task not found"))
        (:working (done (%task-object fake id "working")))
        (:completed (done (%task-object fake id "completed"
                                        "result" (%obj "content" (vector (%obj "type" "text" "text" "finished work"))))))
        (:error-result (done (%task-object fake id "completed"
                                           "result" (%obj "content" (vector (%obj "type" "text" "text" "bad input"))
                                                          "isError" t))))
        (:failed (done (%task-object fake id "failed" "error" (%obj "code" -32603 "message" "boom"))))
        (:cancelled (done (%task-object fake id "cancelled")))
        (:input (done (%task-object fake id "input_required"
                                    "inputRequests" (%obj "q" (%obj "method" "sampling/createMessage"
                                                                    "params" (%obj "maxTokens" 10))
                                                          "r" (%obj "method" "made/up" "params" (%obj))))))))))

(defun %result (fake method params)
  "The result for METHOD, or (:ERROR code text), or (:STATUS n)."
  (cond
    ((string= method "tasks/get")
     (if (fake-get-status fake)
         (list :status (fake-get-status fake))
         (%task-poll fake (gethash "taskId" params))))
    ((string= method "tasks/update")
     (sb-thread:with-mutex ((fake-lock fake))
       (push (cons (gethash "taskId" params) (gethash "inputResponses" params))
             (fake-updates fake)))
     (%obj "resultType" "complete"))
    ((string= method "tasks/cancel")
     (sb-thread:with-mutex ((fake-lock fake))
       (push (gethash "taskId" params) (fake-cancels fake))
       (remhash (gethash "taskId" params) (fake-tasks fake)))
     (%obj "resultType" "complete"))
    ((string= method "tools/list")
     (let* ((all (fake-tools fake))
            (start (let ((c (gethash "cursor" params))) (if (stringp c) (parse-integer c) 0)))
            (end (min (length all) (+ start (fake-page-size fake))))
            (page (subseq all start end)))
       (case (fake-bad-tools fake)
         (:missing (return-from %result (%obj "nextCursor" 'null)))
         (:string (return-from %result (%obj "tools" "not a list" "nextCursor" 'null))))
       (%obj "tools" (map 'vector (lambda (e) (%tool-json (car e) (cdr e))) page)
             "nextCursor" (cond ((fake-endless fake) "0")
                                ((< end (length all)) (princ-to-string end))
                                (t 'null)))))
    ((string= method "tools/call")
     (sb-thread:with-mutex ((fake-lock fake)) (incf (fake-calls fake)))
     (let* ((name (gethash "name" params))
            (entry (cdr (assoc name (fake-tools fake) :test #'equal)))
            (args (gethash "arguments" params)))
       (case (getf entry :do :echo)
         (:echo (%obj "content" (vector (%obj "type" "text"
                                              "text" (format nil "echo ~A" (jzon:stringify args))))))
         (:fail (%obj "content" (vector (%obj "type" "text" "text" "no such city"))
                      "isError" t))
         (:structured (%obj "content" #() "structuredContent" (%obj "n" 3)))
         (:null-result :null-result)
         (:bad-image (%obj "content" (vector (%obj "type" "image" "data" 42 "mimeType" "image/png"))))
         (:status-409 (list :status 409))
         (:keepalive :keepalive)
         (:slow (sleep 3) (%obj "content" #()))
         (:status-500 (list :status 500))
         (:input (%obj "resultType" "input_required" "inputRequests" (%obj)))
         ;; A compliant server makes a task only for a client that declared the extension, and
         ;; otherwise answers -32021 (Missing Required Client Capability).
         (:task (if (%declares-tasks-p params)
                    (%create-task fake)
                    (list :error -32021 "Missing required client capability")))
         (:rogue-task (%create-task fake))
         (:slow-task (sleep 2) (%create-task fake))
         ;; A task missing the fields in :DROP, with the fields in :SET replaced.
         (:bad-task (let ((h (%create-task fake)))
                      (dolist (k (getf entry :drop)) (remhash k h))
                      (loop for (k v) on (getf entry :set) by #'cddr do (setf (gethash k h) v))
                      h))
         (t (list :error -32602 "unknown tool")))))
    ((member method '("resources/list" "resources/templates/list" "prompts/list") :test #'string=)
     (let* ((member (cond ((string= method "resources/list") "resources")
                          ((string= method "prompts/list") "prompts")
                          (t "resourceTemplates")))
            (all (cond ((string= method "resources/list") (fake-resources fake))
                       ((string= method "prompts/list") (fake-prompts fake))
                       (t (fake-templates fake))))
            (start (let ((c (gethash "cursor" params))) (if (stringp c) (parse-integer c) 0)))
            (end (min (length all) (+ start (fake-page-size fake)))))
       (%obj member (if (fake-bad-page fake) "not a list" (coerce (subseq all start end) 'vector))
             "nextCursor" (if (< end (length all)) (princ-to-string end) 'null))))
    ((string= method "resources/read")
     (let ((uri (gethash "uri" params)))
       (cond ((equal uri "file:///missing") (list :error -32602 "Resource not found"))
             ((equal uri "file:///old-missing") (list :error -32002 "Resource not found"))
             ((equal uri "file:///ask") (%obj "resultType" "input_required" "inputRequests" (%obj)))
             ((equal uri "file:///no-contents") (%obj "resultType" "complete"))
             (t (%obj "contents" (or (cdr (assoc uri (fake-contents fake) :test #'equal)) #()))))))
    ((string= method "prompts/get")
     (setf (fake-prompt-arguments fake) (gethash "arguments" params))
     (let ((messages (cdr (assoc (gethash "name" params) (fake-prompt-messages fake) :test #'equal))))
       (if messages
           (%obj "description" "a prompt" "messages" messages)
           (list :error -32602 "unknown prompt"))))
    (t (list :error -32601 "Method not found"))))

(defun %modern-headers-ok-p (request message)
  "Whether REQUEST carries the headers the 2026-07-28 revision requires, matching MESSAGE."
  (let* ((params (gethash "params" message))
         (meta (and (hash-table-p params) (gethash "_meta" params)))
         (method (gethash "method" message)))
    (and (hash-table-p meta)
         (equal (th:request-header request "MCP-Protocol-Version")
                (gethash "io.modelcontextprotocol/protocolVersion" meta))
         (equal (th:request-header request "Mcp-Method") method)
         (or (not (member method '("tools/call" "resources/read" "prompts/get") :test #'equal))
             (equal (th:request-header request "Mcp-Name")
                    (or (gethash "name" params) (gethash "uri" params))))
         ;; The Tasks extension routes tasks/* by the task id in Mcp-Name.
         (or (not (member method '("tasks/get" "tasks/update" "tasks/cancel") :test #'equal))
             (equal (th:request-header request "Mcp-Name") (gethash "taskId" params))))))

(defun %serve (fake)
  (lambda (request stream)
    (let* ((message (ignore-errors (jzon:parse (th:request-body-string request))))
           (id (and (hash-table-p message) (gethash "id" message)))
           (method (and (hash-table-p message) (gethash "method" message)))
           (params (or (and (hash-table-p message) (gethash "params" message)) (%obj)))
           (auth (th:request-header request "Authorization")))
      (flet ((answer (result)
               (cond ((eq result :null-result)
                      (%reply stream fake 200 (%obj "jsonrpc" "2.0" "id" id "result" 'null)))
                     ((eq result :keepalive)
                      ;; An event stream that sends a comment every half second for 5 seconds,
                      ;; then the reply: a read timeout never fires on it.
                      (th:write-head stream 200 '(("Content-Type" . "text/event-stream")))
                      (dotimes (i 10)
                        (write-sequence (sb-ext:string-to-octets (format nil ": keep-alive~C~C" #\Return #\Newline)
                                                                 :external-format :utf-8)
                                        stream)
                        (finish-output stream)
                        (sleep 0.5))
                      (write-sequence (sb-ext:string-to-octets
                                       (format nil "data: ~A~C~C~C~C"
                                               (jzon:stringify (%obj "jsonrpc" "2.0" "id" id
                                                                     "result" (%obj "content" #())))
                                               #\Return #\Newline #\Return #\Newline)
                                       :external-format :utf-8)
                                      stream)
                      (finish-output stream))
                     ((and (consp result) (eq (first result) :status))
                      (th:write-response stream (second result) '() "server error"))
                     ((consp result)
                      (%reply stream fake 200 (%error-message id (second result) (third result))))
                     (t (%reply stream fake 200 (%obj "jsonrpc" "2.0" "id" id "result" result))))))
        (cond
          ((fake-fail-next fake)
           ;; One answer that is not the server's, as a proxy or a deploy can give.
           (setf (fake-fail-next fake) nil)
           (th:write-response stream 404 '(("Content-Type" . "text/html")) "<html>not here</html>"))
          ((or (and (fake-require-token fake)
                    (not (equal auth (format nil "Bearer ~A" (fake-require-token fake)))))
               (and (fake-cancel-token fake) (equal method "tasks/cancel")
                    (not (equal auth (format nil "Bearer ~A" (fake-cancel-token fake))))))
           (th:write-response stream 401
                              '(("WWW-Authenticate" . "Bearer resource_metadata=\"http://127.0.0.1/.well-known/oauth-protected-resource\""))
                              ""))
          ;; The current revision: _meta on every request, no handshake.
          ((and (member (fake-era fake) '(:modern :dual)) (hash-table-p (gethash "_meta" params)))
           (if (and (%modern-headers-ok-p request message)
                    (not (and (fake-reject-headers fake) (equal method "tools/call"))))
               (answer (%result fake method params))
               (%reply stream fake 400 (%error-message id -32020 "Header mismatch"))))
          ;; A modern-only server sent a legacy request.
          ((eq (fake-era fake) :modern)
           (th:write-response stream 400 '(("Content-Type" . "application/json"))
                              (jzon:stringify (%error-message id -32022 "Unsupported protocol version"))))
          ;; The legacy revisions.
          ((and (equal method "initialize") (fake-initialize-status fake))
           (th:write-response stream (fake-initialize-status fake) '() "unavailable"))
          ((equal method "initialize")
           (let ((session (format nil "s~D" (incf (fake-initializes fake)))))
             (push session (fake-sessions fake))
             (%reply stream fake 200
                     (%obj "jsonrpc" "2.0" "id" id
                           "result" (%obj "protocolVersion" (fake-legacy-version fake)
                                          "capabilities" (%obj "tools" (%obj))
                                          "serverInfo" (%obj "name" "fake" "version" "1")))
                     :headers (list (cons "Mcp-Session-Id" session)))))
          ((equal method "notifications/initialized")
           (th:write-response stream 202 '() ""))
          (t
           (let ((session (th:request-header request "Mcp-Session-Id")))
             (cond ((not (member session (fake-sessions fake) :test #'equal))
                    ;; What a legacy server answers to a request without a session.
                    (th:write-response stream 400 '(("Content-Type" . "application/json"))
                                       (jzon:stringify (%error-message nil -32000 "Bad Request: No valid session ID provided"))))
                   ((fake-end-session fake)
                    (setf (fake-end-session fake) nil
                          (fake-sessions fake) (remove session (fake-sessions fake) :test #'equal))
                    (th:write-response stream 404 '() ""))
                   (t (answer (%result fake method params)))))))))))

(defmacro with-fake ((client fake &rest connection-args) &body body)
  "Run BODY with CLIENT talking to a test server configured by FAKE."
  (let ((server (gensym "SERVER")))
    `(th:with-server (,server (%serve ,fake))
       (let ((,client (mcp:make-client
                       (mcp:make-connection :name "docs" :url (th:server-url ,server "/mcp")
                                            ,@connection-args))))
         (flet ((requests () (reverse (th:server-requests ,server))))
           (declare (ignorable #'requests))
           ,@body)))))

(defun %methods (requests)
  (mapcar (lambda (r) (gethash "method" (jzon:parse (th:request-body-string r)))) requests))

(defun %tools (&rest names)
  (mapcar (lambda (n) (if (consp n) n (list n))) names))

;;; --- both eras -------------------------------------------------------------------------

(test a-current-revision-server-is-spoken-to-without-a-handshake
  "Every request carries _meta and the headers, tools/list follows nextCursor, and nothing
sends initialize."
  (let ((fake (make-fake :era :modern :page-size 2 :tools (%tools "a" "b" "c"))))
    (with-fake (client fake)
      (is (equal '("a" "b" "c") (mapcar #'mcp:tool-name (mcp:list-tools client))))
      (is (eq :modern (mcp:client-era client)))
      (is (equal '("tools/list" "tools/list") (%methods (requests))) "two pages, no initialize")
      (is (every (lambda (r) (equal "2026-07-28" (th:request-header r "MCP-Protocol-Version")))
                 (requests))))))

(test a-legacy-server-gets-initialize-and-its-session
  "The current-revision probe gets a legacy 400; the client sends initialize, then the request
with the session id and the version header."
  (let ((fake (make-fake :era :legacy :tools (%tools "a"))))
    (with-fake (client fake)
      (is (equal '("a") (mapcar #'mcp:tool-name (mcp:list-tools client))))
      (is (eq :legacy (mcp:client-era client)))
      (is (equal "2025-11-25" (mcp:client-protocol-version client)))
      (is (equal '("tools/list" "initialize" "notifications/initialized" "tools/list")
                 (%methods (requests))))
      (let ((last (car (last (requests)))))
        (is (equal "s1" (th:request-header last "Mcp-Session-Id")))
        (is (equal "2025-11-25" (th:request-header last "MCP-Protocol-Version"))))
      ;; The era is remembered: no second probe.
      (mcp:list-tools client)
      (is (equal "tools/list" (car (last (%methods (requests))))))
      (is (= 5 (length (requests)))))))

(test a-reply-sent-as-an-event-stream-is-read-in-both-eras
  (dolist (era '(:modern :legacy))
    (let ((fake (make-fake :era era :reply :sse :tools (%tools "a"))))
      (with-fake (client fake)
        (is (equal '("a") (mapcar #'mcp:tool-name (mcp:list-tools client))) "~A" era)
        (is (equal "echo {\"q\":1}"
                   (mcp:call-tool client (first (mcp:list-tools client)) (%obj "q" 1))))))))

(test an-ended-legacy-session-is-opened-again-once
  (let ((fake (make-fake :era :legacy :tools (%tools "a"))))
    (with-fake (client fake)
      (mcp:list-tools client)
      (setf (fake-end-session fake) t)
      (is (equal '("a") (mapcar #'mcp:tool-name (mcp:list-tools client))))
      (is (= 2 (fake-initializes fake))))))

(test the-era-is-found-again-when-the-server-changes
  "A client that remembered one era and gets the other's answer finds out again, once."
  (let ((fake (make-fake :era :modern :tools (%tools "a"))))
    (with-fake (client fake)
      (mcp:list-tools client)
      (is (eq :modern (mcp:client-era client)))
      (setf (fake-era fake) :legacy)
      (is (equal '("a") (mapcar #'mcp:tool-name (mcp:list-tools client))))
      (is (eq :legacy (mcp:client-era client)))
      (setf (fake-era fake) :modern)
      (is (equal '("a") (mapcar #'mcp:tool-name (mcp:list-tools client))))
      (is (eq :modern (mcp:client-era client))))))

;;; --- tool calls ------------------------------------------------------------------------

(defun %call (client name &optional (arguments (%obj)))
  (mcp:call-tool client (find name (mcp:list-tools client) :key #'mcp:tool-name :test #'equal)
                 arguments))

(test a-tool-result-becomes-text-and-iserror-becomes-a-tool-error
  (let ((fake (make-fake :tools (%tools "a" '("bad" :do :fail) '("s" :do :structured)))))
    (with-fake (client fake)
      (is (equal "echo {\"x\":\"y\"}" (%call client "a" (%obj "x" "y"))))
      (is (equal "{\"n\":3}" (%call client "s")))
      (handler-case (progn (%call client "bad") (fail "isError did not signal"))
        (mcp:tool-error (e)
          (is (equal "no such city" (cnd:tool-error-result-text e)))
          (is (eq :error (cnd:tool-error-result-outcome e))))))))

(test a-call-that-may-have-run-is-never-sent-again
  "After a timeout or a 5xx the tool may have run. The call is sent once, and the model is told
the outcome is unknown."
  (let ((fake (make-fake :tools (%tools '("slow" :do :slow) '("boom" :do :status-500)))))
    (with-fake (client fake :call-timeout 1)
      (dolist (name '("slow" "boom"))
        (setf (fake-calls fake) 0)
        (handler-case (progn (%call client name) (fail "~A did not fail" name))
          (mcp:request-failed (e)
            (is (eq :unknown (cnd:tool-error-result-outcome e)) "~A" name)
            (is-true (search "may have run" (cnd:tool-error-result-text e)))))
        (is (= 1 (fake-calls fake)) "~A was sent ~D times" name (fake-calls fake))))))

(test a-reply-stream-left-open-fails-at-the-timeout
  "A known limitation (#527, review item 11): aion/http-client reads a whole body, so a reply
stream the server leaves open after the reply is read until the read timeout. The call fails
then, with its outcome unknown, rather than waiting for the server to close the stream."
  (let ((fake (make-fake :tools (%tools "a"))))
    (with-fake (client fake :call-timeout 1)
      (let ((tool (first (mcp:list-tools client))))
        (setf (fake-reply fake) :sse-left-open)
        (let ((started (get-internal-real-time)))
          (handler-case (progn (mcp:call-tool client tool (%obj)) (fail "no failure"))
            (mcp:request-failed (e) (is (eq :unknown (cnd:tool-error-result-outcome e)))))
          (is (< (/ (- (get-internal-real-time) started) internal-time-units-per-second) 2.5)
              "the call gave up at its timeout, before the server closed the stream"))))))

(test input-required-and-header-mismatch-fail-without-running
  (let ((fake (make-fake :tools (%tools '("ask" :do :input)))))
    (with-fake (client fake)
      (handler-case (progn (%call client "ask") (fail "input_required did not fail"))
        (mcp:request-failed (e) (is (eq :not-run (cnd:tool-error-result-outcome e)))))))
  ;; A server that rejects the headers: the call fails, and the client does not list the
  ;; tools again (a departure from the specification's SHOULD; see client.lisp).
  (let ((fake (make-fake :tools (%tools "a"))))
    (with-fake (client fake)
      (let ((tool (first (mcp:list-tools client)))
            (before (length (requests))))
        (setf (fake-reject-headers fake) t)
        (handler-case (progn (mcp:call-tool client tool (%obj)) (fail "no failure"))
          (mcp:request-failed (e)
            (is (eql -32020 (mcp:request-failed-code e)))
            (is (eq :not-run (cnd:tool-error-result-outcome e)))))
        (is (equal '("tools/call") (%methods (nthcdr before (requests))))
            "no tools/list after a HeaderMismatch")))))

(test a-server-that-redirects-gets-no-token-forwarded
  (let ((target-hits 0))
    (th:with-server (target (lambda (r s) (declare (ignore r)) (incf target-hits)
                              (th:write-response s 200 '() "{}")))
      (th:with-server (redirector (lambda (r s) (declare (ignore r))
                                    (th:write-response s 307 (list (cons "Location" (th:server-url target "/mcp"))) "")))
        (let ((client (mcp:make-client
                       (mcp:make-connection :name "r" :url (th:server-url redirector "/mcp")
                                            :token-source (lambda (c p) (declare (ignore c p)) "secret")))))
          (signals mcp:request-failed (mcp:list-tools client))
          (is (= 0 target-hits)))))))

;;; --- header parameters (x-mcp-header) --------------------------------------------------

(test header-values-that-are-not-plain-ascii-go-out-in-base64
  (flet ((b64 (s) (format nil "=?base64?~A?=" (cl-base64:usb8-array-to-base64-string
                                                (sb-ext:string-to-octets s :external-format :utf-8)))))
    (is (equal "us-west1" (mcp::encode-header-value "us-west1")))
    (dolist (value (list (format nil "line1~Cline2" #\Newline)
                         (format nil "a~Cb" #\Return)
                         "Hello, 世界" " padded " "padded " " padded"
                         "=?base64?literal?="))
      (is (equal (b64 value) (mcp::encode-header-value value)) "~S" value))
    (is (equal (b64 "=?base64?literal?=") "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=")
        "the specification's own example")))

(defun %schema (&rest properties)
  (%obj "type" "object" "properties" (apply #'%obj properties)))

(test header-parameters-are-mirrored-and-bad-values-are-refused
  (let ((paths (mcp::x-mcp-header-paths
                (%schema "region" (%obj "type" "string" "x-mcp-header" "Region")
                         "n" (%obj "type" "integer" "x-mcp-header" "N")
                         "flag" (%obj "type" "boolean" "x-mcp-header" "Flag")
                         "nested" (%obj "type" "object"
                                        "properties" (%obj "z" (%obj "type" "string"
                                                                     "x-mcp-header" "Z")))))))
    (is (equal '(("Mcp-Param-Region" . "us-west1") ("Mcp-Param-N" . "42")
                 ("Mcp-Param-Flag" . "false") ("Mcp-Param-Z" . "deep"))
               (sort (mcp::header-params paths (%obj "region" "us-west1" "n" 42 "flag" nil
                                                     "nested" (%obj "z" "deep")))
                     #'< :key (lambda (h) (position (car h) '("Mcp-Param-Region" "Mcp-Param-N"
                                                              "Mcp-Param-Flag" "Mcp-Param-Z")
                                                    :test #'equal)))))
    (is (null (mcp::header-params paths (%obj))) "absent arguments have no header")
    (is (null (mcp::header-params paths (%obj "region" 'null))) "null has no header")
    (signals mcp::header-value-refused
      (mcp::header-params paths (%obj "n" (expt 2 53))))
    (is (equal '(("Mcp-Param-N" . "-9007199254740991"))
               (mcp::header-params paths (%obj "n" (- 1 (expt 2 53))))))))

(test an-invalid-header-annotation-drops-the-tool
  (dolist (schema
           (list (%schema "x" (%obj "type" "number" "x-mcp-header" "X"))
                 (%schema "x" (%obj "type" "array"
                                    "items" (%obj "type" "string" "x-mcp-header" "X")))
                 (%schema "x" (%obj "oneOf" (vector (%obj "type" "string" "x-mcp-header" "X"))))
                 (%obj "type" "object" "$defs" (%obj "d" (%obj "type" "string" "x-mcp-header" "X"))
                       "properties" (%obj "x" (%obj "$ref" "#/$defs/d")))
                 (%schema "a" (%obj "type" "string" "x-mcp-header" "Same")
                          "b" (%obj "type" "string" "x-mcp-header" "same"))
                 (%schema "x" (%obj "type" "string" "x-mcp-header" ""))
                 (%schema "x" (%obj "type" "string" "x-mcp-header" "Bad Name"))))
    (is (eq :invalid (mcp::x-mcp-header-paths schema)) "~S" (jzon:stringify schema)))
  (let ((fake (make-fake :tools (list (list "good")
                                      (list "bad" :schema (%schema "x" (%obj "type" "number"
                                                                             "x-mcp-header" "X")))))))
    (with-fake (client fake)
      (is (equal '("good") (mapcar #'mcp:tool-name (mcp:list-tools client)))))))

(test a-call-sends-its-header-parameters-to-a-current-revision-server
  (let ((fake (make-fake :tools (list (list "q" :schema (%schema "region"
                                                                  (%obj "type" "string"
                                                                        "x-mcp-header" "Region")))))))
    (with-fake (client fake)
      (%call client "q" (%obj "region" "eu west"))
      (let ((call (car (last (requests)))))
        (is (equal "eu west" (th:request-header call "Mcp-Param-Region")))
        (is (equal "q" (th:request-header call "Mcp-Name")))))))

;;; --- tokens, principals and sign-in ----------------------------------------------------

(test each-call-uses-the-token-of-its-turns-principal
  (let ((fake (make-fake :tools (%tools "a")))
        (seen '()))
    (with-fake (client fake :per-user t
                            :token-source (lambda (c principal) (declare (ignore c))
                                            (format nil "token-~A" principal)))
      (let ((agent (actor:make-agent)))
        (mcp:grant-tools agent client :tools (mcp:list-tools client :principal "u0") :only :all)
        (let ((fn (actor::means-entry-fn (gethash "docs__a" (actor:agent-means agent)))))
          (dolist (p '("u1" "u2"))
            (let ((actor:*principal* p)) (funcall fn (%obj))))))
      (setf seen (mapcar (lambda (r) (th:request-header r "Authorization")) (requests)))
      (is (equal '("Bearer token-u0" "Bearer token-u1" "Bearer token-u2") seen)))))

(test a-call-with-no-principal-is-refused-before-anything-is-sent
  (let ((fake (make-fake :tools (%tools "a"))))
    (with-fake (client fake :per-user t
                            :token-source (lambda (c p) (declare (ignore c)) (and p "t")))
      (let ((tool (first (mcp:list-tools client :principal "u0")))
            (before nil))
        (setf before (length (requests)))
        (handler-case (progn (mcp:call-tool client tool (%obj)) (fail "no refusal"))
          (mcp:sign-in-needed (e) (is (eq :not-run (cnd:tool-error-result-outcome e)))))
        (is (= before (length (requests))))))))

(defclass scripted (llm:provider)
  ((script :initarg :script :accessor scripted-script))
  (:documentation "A provider that hands back queued completions in order."))

(defmethod llm:complete ((p scripted) messages &key system tools max-tokens temperature tool-choice)
  (declare (ignore messages system tools max-tokens temperature tool-choice))
  (or (pop (scripted-script p)) (llm:make-completion :text "" :stop-reason :end)))

(defun %agent-calling (tool-means)
  "An agent whose model calls TOOL-MEANS once, then answers \"done\"."
  (let ((call (llm:make-tool-call :id "c1" :name tool-means
                                  :arguments (make-hash-table :test #'equal))))
    (actor:make-agent
     :provider (make-instance 'scripted
                              :script (list (llm:make-completion :tool-calls (list call)
                                                                 :stop-reason :tool-use)
                                            (llm:make-completion :text "done" :stop-reason :end))))))

(test a-401-reaches-the-app-and-the-model-learns-only-that-a-sign-in-is-needed
  (let ((fake (make-fake :tools (%tools "a") :require-token "good"))
        (token (list "good")) (seen '()) (events '()))
    (with-fake (client fake :token-source (lambda (c p) (declare (ignore c p)) (car token)))
      (let ((agent (%agent-calling "docs__a")))
        (mcp:grant-tools agent client :only '("a"))
        (setf (car token) "expired")
        (is (equal "done"
                   (handler-bind ((mcp:authorization-required
                                    (lambda (c) (push (mcp:authorization-required-challenge c) seen))))
                     (evt:with-observer ((lambda (e) (push e events)))
                       (actor:run-turn agent "go" :principal "u1")))))
        (is (= 1 (length seen)))
        (is-true (search "resource_metadata" (first seen)))
        (let ((result (find :tool-result events :key #'evt:event-type)))
          (is (eq t (getf result :is-error)))
          (is (eq :not-run (getf result :outcome)))
          (is (null (search "http" (getf result :content))) "no URL reaches the model")
          (is (equal '(:connection "docs" :tool "a" :per-user nil) (getf result :source)))
          (is (equal "u1" (getf result :principal)))
          (is (equal (actor:agent-name agent) (getf result :agent))))
        (is-true (find :sign-in-required events :key #'evt:event-type))))))

(test on-another-thread-the-app-gets-the-event-but-not-the-condition
  "Handler bindings stay on the thread that set them. A turn run on another thread with
AION/DYNAMIC:INHERITING keeps the observer and the principal, so the :SIGN-IN-REQUIRED event
reaches the app, while the app's handler on the first thread does not see the condition."
  (let ((fake (make-fake :tools (%tools "a") :require-token "good"))
        (events '()) (seen 0) (lock (sb-thread:make-mutex)))
    (with-fake (client fake :token-source (lambda (c p) (declare (ignore c p)) "expired"))
      (let ((agent (%agent-calling "docs__a")))
        (mcp:grant-tools agent client :only :all
                         :tools (list (praxeon/mcp::%make-tool :name "a")))
        (handler-bind ((mcp:authorization-required (lambda (c) (declare (ignore c)) (incf seen))))
          (evt:with-observer ((lambda (e) (sb-thread:with-mutex (lock) (push e events))))
            (let ((actor:*principal* "u2"))
              (is (equal "done"
                         (aion/test-threads:join
                          (sb-thread:make-thread
                           (aion/dynamic:inheriting (lambda () (actor:run-turn agent "go")))
                           :name "mcp turn elsewhere")))))))
        (is (= 0 seen))
        (let ((event (find :sign-in-required events :key #'evt:event-type)))
          (is-true event)
          (is (equal "u2" (getf event :principal))))))))

;;; --- granting --------------------------------------------------------------------------

(test granted-tools-are-prefixed-and-only-what-the-app-chose
  (let ((fake (make-fake :tools (%tools "search" "delete" "weird name!"))))
    (with-fake (client fake)
      (let ((agent (actor:make-agent)))
        (is (equal '("docs__search" "docs__weird_name_")
                   (mcp:grant-tools agent client :only '("search" "weird name!"))))
        (is-true (gethash "docs__search" (actor:agent-means agent)))
        (is (null (gethash "docs__delete" (actor:agent-means agent))) "not granted, not there")
        (is (equal '(:connection "docs" :tool "search" :per-user nil)
                   (actor:means-entry-source (gethash "docs__search" (actor:agent-means agent)))))
        (signals error (mcp:grant-tools (actor:make-agent) client))
        (is (= 2 (mcp:revoke-tools agent client)))
        (is (zerop (hash-table-count (actor:agent-means agent))))))))

(test a-name-clash-registers-nothing
  (let ((fake (make-fake :tools (%tools "search" "other"))))
    (with-fake (client fake)
      (let ((agent (actor:make-agent)))
        (actor:register-means agent "docs__search" "the app's own" (lambda (a) (declare (ignore a)) "mine"))
        (handler-case (progn (mcp:grant-tools agent client :only :all) (fail "no conflict signalled"))
          (mcp:tool-name-conflict (e)
            (is (equal '("docs__search") (mcp:tool-name-conflict-names e)))))
        (is (= 1 (hash-table-count (actor:agent-means agent))) "nothing was registered")
        (is (equal "mine" (funcall (actor::means-entry-fn (gethash "docs__search" (actor:agent-means agent)))
                                   nil)))))
    (is (equal "docs__x" (mcp:means-name (mcp:make-connection :name "docs") "x")))
    (is (= 64 (length (mcp:means-name (mcp:make-connection :name "docs")
                                      (make-string 100 :initial-element #\a)))))))

;;; --- the event stream ------------------------------------------------------------------

(test an-event-stream-is-split-into-its-events
  (is (equal (list "one" (format nil "two~%three") "four")
             (mcp::parse-event-stream
              (format nil ": comment~%data: one~%~%event: message~%data: two~%data:three~%~%id: 7~%~%data: four~%")))))

(test a-request-is-given-up-at-its-deadline-whatever-the-transport-does
  "The deadline does not depend on the transport's read timeout, which dexador's WinHTTP
backend did not honour on #530's Windows leg. Here the transport is given 30 seconds and the
deadline 1: the request is given up within about a second while the server takes 3."
  (th:with-server (s (lambda (r stream) (declare (ignore r))
                       (sleep 3) (th:write-response stream 200 '() "{}")))
    (let ((started (get-internal-real-time)))
      (signals aion/http-client:http-error
        (mcp::%send-within (mcp:make-client (mcp:make-connection :name "d" :url "x"))
                           (aion/http-client:make-request :url (th:server-url s "/mcp")
                                                          :read-timeout 30)
                           1 "tools/call"))
      (is (< (/ (- (get-internal-real-time) started) internal-time-units-per-second) 2)))))


;;; --- the review of #530 ----------------------------------------------------------------

(test one-bad-answer-does-not-leave-the-client-in-the-legacy-era
  "A current-revision server's one 404 from a proxy sends the client to the legacy handshake,
which the server answers with a current-revision error. That one call fails as not run, the era
stays unknown, and the next call probes again and works."
  (let ((fake (make-fake :era :modern :tools (%tools "a"))))
    (with-fake (client fake)
      (setf (fake-fail-next fake) t)
      (handler-case (progn (mcp:list-tools client) (fail "the 404 did not fail the call"))
        (mcp:request-failed (e) (is (eq :not-run (cnd:tool-error-result-outcome e)))))
      (is (null (mcp:client-era client)))
      (is (equal '("a") (mapcar #'mcp:tool-name (mcp:list-tools client))))
      (is (eq :modern (mcp:client-era client))))))

(test a-result-that-is-not-an-object-fails-the-call
  (let ((fake (make-fake :tools (%tools '("n" :do :null-result)))))
    (with-fake (client fake)
      (handler-case (progn (%call client "n") (fail "a null result did not fail the call"))
        (mcp:request-failed (e) (is (eq :unknown (cnd:tool-error-result-outcome e))))))))

(test a-tool-whose-schema-is-not-an-object-schema-or-too-large-is-dropped
  (let ((fake (make-fake :tools (list (list "good")
                                      (list "null-schema" :schema 'null)
                                      (list "string-schema" :schema (%obj "type" "string"))
                                      (list "huge" :schema (%schema "x" (%obj "type" "string"
                                                                              "description" (make-string 30000 :initial-element #\a))))))))
    (with-fake (client fake)
      (is (equal '("good") (mapcar #'mcp:tool-name (mcp:list-tools client)))))))

(test a-listing-that-does-not-end-fails-instead-of-granting-part-of-it
  (let ((fake (make-fake :tools (%tools "a"))))
    (setf (fake-endless fake) t)
    (with-fake (client fake)
      (let ((mcp::*max-list-pages* 5))
        (signals mcp:request-failed (mcp:list-tools client))))))

(test a-page-without-a-list-of-tools-fails-the-listing
  "A tools/list reply with no tools member, or a string there, is not an empty page."
  (dolist (bad '(:missing :string))
    (let ((fake (make-fake :tools (%tools "a"))))
      (setf (fake-bad-tools fake) bad)
      (with-fake (client fake)
        (handler-case (progn (mcp:list-tools client) (fail "~S was read as a page" bad))
          (mcp:request-failed (e)
            (is (eq :not-run (cnd:tool-error-result-outcome e)))))))))

(test an-event-stream-in-any-letter-case-is-read
  (let ((fake (make-fake :reply :sse-capitals :tools (%tools "a"))))
    (with-fake (client fake)
      (is (equal '("a") (mapcar #'mcp:tool-name (mcp:list-tools client)))))))

(test revoking-removes-exactly-what-the-grant-registered
  "Matched on each means' source, not on a name prefix: a connection named \"my docs\" grants
my_docs__ means and revokes them; an app's own means that starts with the prefix stays."
  (let ((fake (make-fake :tools (%tools "search"))))
    (th:with-server (s (%serve fake))
      (let* ((mine (mcp:make-client (mcp:make-connection :name "my docs" :url (th:server-url s "/mcp"))))
             (docs (mcp:make-client (mcp:make-connection :name "docs" :url (th:server-url s "/mcp"))))
             (agent (actor:make-agent)))
        (actor:register-means agent "docs__notes" "the app's own" (lambda (a) (declare (ignore a)) "n"))
        (is (equal '("my_docs__search") (mcp:grant-tools agent mine :only :all)))
        (is (equal '("docs__search") (mcp:grant-tools agent docs :only :all)))
        (actor:register-means agent "docs__look-alike" "the app's, with a grant-like source"
                              (lambda (a) (declare (ignore a)) "l")
                              :source '(:connection "docs" :tool "look-alike"))
        (actor:register-means agent "plain" "the app's, with a string source"
                              (lambda (a) (declare (ignore a)) "p") :source "not a plist")
        (is (= 1 (mcp:revoke-tools agent mine)))
        (is (null (gethash "my_docs__search" (actor:agent-means agent))))
        (is (= 1 (mcp:revoke-tools agent docs)))
        (is-true (gethash "docs__notes" (actor:agent-means agent)) "the app's means stays")
        (is-true (gethash "docs__look-alike" (actor:agent-means agent))
                 "a means whose :source names the connection, but which the grant did not register, stays")
        (is-true (gethash "plain" (actor:agent-means agent)))))))

(test a-keep-alive-stream-is-given-up-at-the-deadline-and-its-thread-is-counted
  "A server that sends a keep-alive comment every half second never lets a read timeout fire,
on any platform. The call is given up at its deadline; the thread that is still running is
counted, a second call past the limit is refused without being sent, and once the thread has
finished the count is back to zero."
  (let ((fake (make-fake :tools (%tools '("long" :do :keepalive) "a"))))
    (with-fake (client fake :call-timeout 2)
      (let* ((tools (mcp:list-tools client))
             (long (find "long" tools :key #'mcp:tool-name :test #'equal))
             (started (get-internal-real-time)))
        (handler-case (progn (mcp:call-tool client long (%obj)) (fail "the keep-alive call finished"))
          (mcp:request-failed (e)
            (is (eq :unknown (cnd:tool-error-result-outcome e)))
            (is-true (search "within 3 seconds" (cnd:tool-error-result-text e))
                     "the deadline, call-timeout plus one second, is the time given")))
        (is (< (/ (- (get-internal-real-time) started) internal-time-units-per-second) 4.5))
        (is (= 1 (mcp::client-abandoned client)))
        (let ((mcp::*max-abandoned-requests* 1))
          (handler-case (progn (mcp:call-tool client long (%obj)) (fail "past the limit, sent anyway"))
            (mcp:request-failed (e) (is (eq :not-run (cnd:tool-error-result-outcome e))))))
        (is (= 1 (fake-calls fake)) "the refused call was not sent")
        (is-true (wait-until-zero (lambda () (mcp::client-abandoned client)) 10)
                 "the given-up request's thread finished and was counted off")))))

(defun wait-until-zero (fn seconds)
  (let ((deadline (+ (get-internal-real-time) (* seconds internal-time-units-per-second))))
    (loop (when (zerop (funcall fn)) (return t))
          (when (> (get-internal-real-time) deadline) (return nil))
          (sleep 0.1))))

(test header-arguments-must-have-the-type-the-tool-declares
  (let ((paths (mcp::x-mcp-header-paths
                (%schema "n" (%obj "type" "integer" "x-mcp-header" "N")
                         "s" (%obj "type" "string" "x-mcp-header" "S")))))
    (signals mcp::header-value-refused (mcp::header-params paths (%obj "n" "12")))
    (signals mcp::header-value-refused (mcp::header-params paths (%obj "n" nil)))
    (signals mcp::header-value-refused (mcp::header-params paths (%obj "s" 12)))
    (is (equal '(("Mcp-Param-S" . "12")) (mcp::header-params paths (%obj "s" "12")))))
  (is (eq :invalid (mcp::x-mcp-header-paths (%schema "x" (%obj "type" "string" "x-mcp-header" "Région")))))
  (is (equal "=?base64?PT9iYXNlNjQ/PQ==?=" (mcp::encode-header-value "=?base64?="))))


(test a-failed-handshake-before-a-tool-call-is-not-a-tool-that-may-have-run
  "A legacy server answers initialize with 503 during a tool call on a new client. The tool
never ran, so the outcome is :ERROR, not :UNKNOWN, and the server processed no tools/call."
  (let ((fake (make-fake :era :legacy :tools (%tools "a"))))
    (setf (fake-initialize-status fake) 503)
    (with-fake (client fake)
      (handler-case (progn (mcp:call-tool client (praxeon/mcp::%make-tool :name "a") (%obj))
                           (fail "a 503 handshake did not fail the call"))
        (mcp:request-failed (e) (is (eq :error (cnd:tool-error-result-outcome e)))))
      (is (= 0 (fake-calls fake))))))

(test a-refusal-of-a-tool-call-is-not-run
  (let ((fake (make-fake :tools (%tools '("busy" :do :status-409)))))
    (with-fake (client fake)
      (handler-case (progn (%call client "busy") (fail "a 409 did not fail the call"))
        (mcp:request-failed (e) (is (eq :not-run (cnd:tool-error-result-outcome e))))))))

(test a-given-up-request-whose-thread-is-terminated-is-taken-off-the-count
  "However a given-up request's thread ends, here by TERMINATE-THREAD, it takes itself off the
client's count, so the client does not come to refuse every request with no thread alive."
  (let ((fake (make-fake :tools (%tools '("long" :do :keepalive)))))
    (with-fake (client fake :call-timeout 1)
      (let ((long (first (mcp:list-tools client))))
        (handler-case (mcp:call-tool client long (%obj)) (mcp:request-failed () nil))
        (is (= 1 (mcp::client-abandoned client)))
        (dolist (th (sb-thread:list-all-threads))
          (when (equal "praxeon/mcp request" (sb-thread:thread-name th))
            (ignore-errors (sb-thread:terminate-thread th))))
        (is-true (wait-until-zero (lambda () (mcp::client-abandoned client)) 5))))))

;;; --- OAuth: the whole path, with aion/oauth's test authorization server (#527 part 2) ---

(defvar *gate* nil
  "How the OAuth test server's gate in front of /mcp misbehaves: NIL, :REFUSE-INITIALIZE-ONCE
\(the next initialize gets a 401 whatever its token) or :INSUFFICIENT-SCOPE (every request gets
a 403 for insufficient scope).")

(defmacro with-oauth-mcp ((as fake url) (&rest as-options) (&rest fake-options) &body body)
  "One test server: /mcp is the MCP server FAKE, reached only with a token the authorization
server AS issued; every other path is AS. URL is the MCP endpoint."
  (let ((server (gensym)) (as-handler (gensym)) (mcp-handler (gensym)))
    `(let* ((,as (aion/oauth/tests::make-as ,@as-options))
            (,fake (make-fake ,@fake-options))
            (,as-handler (aion/oauth/tests::%serve ,as))
            (,mcp-handler (%serve ,fake)))
       (th:with-server (,server
                        (lambda (request stream)
                          (if (string= "/mcp" (aion/oauth/tests::%path-only (th:request-path request)))
                              (let* ((auth (th:request-header request "Authorization"))
                                     (token (and auth (> (length auth) 7) (subseq auth 7))))
                                (cond
                                  ((eq *gate* :insufficient-scope)
                                   (th:write-response
                                    stream 403
                                    '(("WWW-Authenticate" . "Bearer error=\"insufficient_scope\", scope=\"more\""))
                                    ""))
                                  ((and (eq *gate* :refuse-initialize-once)
                                        (search "\"initialize\"" (th:request-body-string request)))
                                   (setf *gate* nil)
                                   (th:write-response stream 401 '(("WWW-Authenticate" . "Bearer")) ""))
                                  ((and token (sb-thread:with-mutex ((aion/oauth/tests::as-lock ,as))
                                                (gethash token (aion/oauth/tests::as-access ,as))))
                                   (funcall ,mcp-handler request stream))
                                  (t
                                    (th:write-response
                                     stream 401
                                     (list (cons "WWW-Authenticate"
                                                 (format nil "Bearer resource_metadata=\"~A/prm\""
                                                         (aion/oauth/tests::as-base ,as))))
                                     ""))))
                              (funcall ,as-handler request stream))))
         (setf (aion/oauth/tests::as-base ,as) (format nil "http://127.0.0.1:~D" (th:server-port ,server)))
         (let ((,url (format nil "~A/mcp" (aion/oauth/tests::as-base ,as))))
           ,@body)))))

(test from-a-401-through-sign-in-and-refresh-to-tool-calls
  "The path the issue names: a 401, the app signs the user in from the challenge, the call
succeeds; the server refuses the token, the client refreshes once and retries without
running the tool twice; the refresh token is revoked, and the user is asked to sign in."
  #+os-windows (skip "aion/oauth needs a pinned connection, which Windows does not offer (#295)")
  #-os-windows
  (with-oauth-mcp (as fake url) (:rotate t) (:tools (%tools "a"))
    (let* ((broker (aion/oauth/tests::%broker))
           (client (mcp:make-client
                    (mcp:make-connection :name "docs" :url url :per-user t
                                         :token-source (mcp:oauth-token-source broker))))
           (challenge nil))
      ;; 1. No token yet: the app learns a sign-in is needed, and gets the challenge.
      (handler-bind ((mcp:authorization-required
                       (lambda (c) (setf challenge (mcp:authorization-required-challenge c)))))
        (signals mcp:sign-in-needed (mcp:list-tools client :principal "u1")))
      (is-true (search "resource_metadata" challenge))
      ;; 2. The app signs the user in, from an action the user took.
      (oauth-sign-in broker url challenge)
      (let ((tool (first (mcp:list-tools client :principal "u1"))))
        (is (equal "a" (mcp:tool-name tool)))
        ;; 3. The server stops accepting the token: one refresh, one retry, one tool run.
        (clrhash (aion/oauth/tests::as-access as))
        (setf (fake-calls fake) 0)
        (is (equal "echo {}" (mcp:call-tool client tool (%obj) :principal "u1")))
        (is (= 1 (aion/oauth/tests::as-refresh-requests as)))
        (is (= 1 (fake-calls fake)))
        ;; 4. The refresh token is revoked as well: the user must sign in again.
        (clrhash (aion/oauth/tests::as-access as))
        (push (aion/secret:reveal
               (aion/oauth:token-set-refresh
                (aion/oauth:get-token (aion/oauth:broker-store broker) "u1" "docs")))
              (aion/oauth/tests::as-revoked as))
        (signals mcp:sign-in-needed (mcp:call-tool client tool (%obj) :principal "u1"))
        (is (null (aion/oauth:get-token (aion/oauth:broker-store broker) "u1" "docs")))
        ;; Another user has no token at all.
        (signals mcp:sign-in-needed (mcp:call-tool client tool (%obj) :principal "u2"))))))

(defun oauth-sign-in (broker url challenge)
  (aion/oauth:finish-sign-in
   broker "u1"
   (aion/oauth/tests::%approve (aion/oauth:start-sign-in broker "u1" "docs" url :challenge challenge))))


;;; --- the review of #539 ----------------------------------------------------------------

(defun %signed-in-oauth-client (as url)
  (let ((broker (aion/oauth/tests::%broker)))
    (handler-case (mcp:list-tools (mcp:make-client (mcp:make-connection
                                                    :name "docs" :url url :per-user t
                                                    :token-source (mcp:oauth-token-source broker)))
                                  :principal "u1")
      (mcp:sign-in-needed () nil))
    (aion/oauth:finish-sign-in
     broker "u1"
     (aion/oauth/tests::%approve
      (aion/oauth:start-sign-in broker "u1" "docs" url
                                :challenge (format nil "Bearer resource_metadata=\"~A/prm\""
                                                   (aion/oauth/tests::as-base as)))))
    (values (mcp:make-client (mcp:make-connection :name "docs" :url url :per-user t
                                                  :token-source (mcp:oauth-token-source broker)))
            broker)))

(test a-legacy-handshake-refused-for-its-token-is-retried-after-a-refresh
  #+os-windows (skip "aion/oauth needs a pinned connection, which Windows does not offer (#295)")
  #-os-windows
  (with-oauth-mcp (as fake url) (:rotate t) (:era :legacy :tools (%tools "a"))
    (let ((client (%signed-in-oauth-client as url)))
      ;; The token is good, and only the legacy initialize is refused: the refusal is answered
      ;; by the one retry after a refresh, not by a sign-in.
      (setf *gate* :refuse-initialize-once)
      (unwind-protect
           (is (equal '("a") (mapcar #'mcp:tool-name (mcp:list-tools client :principal "u1"))))
        (setf *gate* nil))
      (is (= 1 (aion/oauth/tests::as-refresh-requests as))))))

(test insufficient-scope-asks-for-a-sign-in-without-a-refresh
  #+os-windows (skip "aion/oauth needs a pinned connection, which Windows does not offer (#295)")
  #-os-windows
  (with-oauth-mcp (as fake url) () (:tools (%tools "a"))
    (let ((client (%signed-in-oauth-client as url)))
      (setf *gate* :insufficient-scope)
      (unwind-protect
           (signals mcp:sign-in-needed (mcp:list-tools client :principal "u1"))
        (setf *gate* nil))
      (is (= 0 (aion/oauth/tests::as-refresh-requests as))))))

(defclass two-token-source () ()
  (:documentation "TOKEN-FOR always gives \"old\"; TOKEN-REFUSED gives \"new\", with no state
shared between them."))
(defmethod mcp:token-for ((s two-token-source) connection principal)
  (declare (ignore connection principal))
  "old")
(defmethod mcp:token-refused ((s two-token-source) connection principal token challenge)
  (declare (ignore connection principal token challenge))
  "new")

(defclass failing-refresh-source () ())
(defmethod mcp:token-for ((s failing-refresh-source) connection principal)
  (declare (ignore connection principal))
  "old")
(defmethod mcp:token-refused ((s failing-refresh-source) connection principal token challenge)
  (declare (ignore connection principal token challenge))
  (error "the authorization server could not be reached"))

(test the-retry-sends-the-token-token-refused-returned
  (let ((fake (make-fake :tools (%tools "a") :require-token "new")))
    (with-fake (client fake :token-source (make-instance 'two-token-source))
      (is (equal '("a") (mapcar #'mcp:tool-name (mcp:list-tools client)))))))

(test a-refresh-that-fails-is-not-a-reason-to-sign-in
  (let ((fake (make-fake :tools (%tools "a") :require-token "new")))
    (with-fake (client fake :token-source (make-instance 'failing-refresh-source))
      (handler-case (progn (mcp:list-tools client) (fail "no failure"))
        (mcp:sign-in-needed () (fail "a failed refresh asked for a sign-in"))
        (mcp:request-failed (e) (is (eq :not-run (cnd:tool-error-result-outcome e))))))))


(test the-retry-after-a-refused-token-checks-the-issuer-again
  "The server refuses the token, and the resource's metadata now names another authorization
server. The refreshed token is not sent: the call asks for a sign-in, and the tool does not run."
  #+os-windows (skip "aion/oauth needs a pinned connection, which Windows does not offer (#295)")
  #-os-windows
  (with-oauth-mcp (as fake url) (:rotate t) (:tools (%tools "a"))
    (let* ((client (%signed-in-oauth-client as url))
           (tool (first (mcp:list-tools client :principal "u1"))))
      (setf (aion/oauth/tests::as-other-issuer as) "https://other.example")
      (clrhash (aion/oauth/tests::as-access as))
      (setf (fake-calls fake) 0)
      (signals mcp:sign-in-needed (mcp:call-tool client tool (%obj) :principal "u1"))
      (is (= 0 (fake-calls fake))))))

(test the-retry-token-goes-only-to-the-client-that-was-refused
  "Client A's server refuses A's first token and answers the retry with a reply larger than A
accepts, so REQUEST-FAILED is signalled while the retry runs. A handler of it makes a request
with client B, to another server: B sends its own token, not the one A's retry carries."
  (let ((fake-a (make-fake :tools (%tools "a" "b" "c") :require-token "new"))
        (fake-b (make-fake :tools (%tools "z"))))
    (with-fake (client-a fake-a :token-source (make-instance 'two-token-source) :max-body-bytes 40)
      (th:with-server (server-b (%serve fake-b))
        (let ((client-b (mcp:make-client
                         (mcp:make-connection :name "other" :url (th:server-url server-b "/mcp")
                                              :token-source (lambda (connection principal)
                                                              (declare (ignore connection principal))
                                                              "token-of-b"))))
              (called nil))
          (signals mcp:request-failed
            (handler-bind ((mcp:request-failed
                             (lambda (c)
                               (declare (ignore c))
                               (unless called
                                 (setf called t)
                                 (mcp:list-tools client-b)))))
              (mcp:list-tools client-a)))
          (is-true called)
          (is (equal '("Bearer token-of-b")
                     (remove-duplicates
                      (mapcar (lambda (r) (th:request-header r "Authorization"))
                              (th:server-requests server-b))
                      :test #'equal))))))))


;;; --- Copilot's review of train 24 (#544) ------------------------------------------------

(test a-content-block-the-client-cannot-read-fails-the-call
  (let ((fake (make-fake :tools (%tools '("img" :do :bad-image)))))
    (with-fake (client fake)
      (handler-case (progn (%call client "img") (fail "no failure"))
        (mcp:request-failed (e) (is (eq :unknown (cnd:tool-error-result-outcome e))))))))

(test an-explicit-empty-tool-list-grants-nothing-and-sends-nothing
  (let ((fake (make-fake :tools (%tools "a"))))
    (with-fake (client fake :per-user t :token-source (lambda (c p) (declare (ignore c p)) "t"))
      (let ((agent (actor:make-agent)))
        (is (null (mcp:grant-tools agent client :tools '() :only :all)))
        (is (null (requests)) "nothing was sent")))))

(test events-separated-by-a-lone-cr-are-read
  (is (equal '("a" "b")
             (mcp::parse-event-stream (format nil "data: a~C~Cdata: b~C~C" #\Return #\Return #\Return #\Return))))
  (is (equal '("a" "b")
             (mcp::parse-event-stream (format nil "data: a~C~C~C~Cdata: b~C~C~C~C"
                                              #\Return #\Newline #\Return #\Newline
                                              #\Return #\Newline #\Return #\Newline)))))

;;; --- tools held for confirmation (#531) --------------------------------------------------

(test grant-tools-marks-the-tools-to-confirm
  (let ((fake (make-fake :tools (%tools "spend" "look"))))
    (with-fake (client fake)
      (let ((agent (actor:make-agent)))
        (mcp:grant-tools agent client :only :all :confirm '("spend"))
        (is (eq t (actor::means-entry-confirm (gethash "docs__spend" (actor:agent-means agent)))))
        (is (null (actor::means-entry-confirm (gethash "docs__look" (actor:agent-means agent)))))))))

(test a-confirm-list-that-is-not-a-list-of-granted-tools-registers-nothing
  "A :CONFIRM value grant-tools cannot read, or a name that is not granted, would let a tool run
without confirmation, so it is refused before anything is registered."
  (let ((fake (make-fake :tools (%tools "spend" "look"))))
    (with-fake (client fake)
      (dolist (confirm (list t :yes '(spend) '("spnd")))
        (let ((agent (actor:make-agent)))
          (signals error (mcp:grant-tools agent client :only :all :confirm confirm))
          (is (zerop (hash-table-count (actor:agent-means agent)))
              "nothing registered for ~S" confirm))))))

(test a-held-tool-is-not-sent-again-after-a-refused-token
  "A tool the app holds for confirmation may spend the user's credits, so after the server
refuses its token it is not sent again. The token is refreshed for the next call, and this one
fails as not run."
  #+os-windows (skip "aion/oauth needs a pinned connection, which Windows does not offer (#295)")
  #-os-windows
  (with-oauth-mcp (as fake url) (:rotate t) (:tools (%tools "a"))
    (let* ((client (%signed-in-oauth-client as url))
           (tool (first (mcp:list-tools client :principal "u1"))))
      (clrhash (aion/oauth/tests::as-access as))
      (setf (fake-calls fake) 0)
      (handler-case (progn (mcp:call-tool client tool (%obj) :principal "u1" :held t)
                           (fail "a held tool was sent again"))
        (mcp:request-failed (e)
          (is (eq :not-run (cnd:tool-error-result-outcome e)))
          (is-true (search "ask again" (cnd:tool-error-result-text e)))))
      (is (= 0 (fake-calls fake)))
      (is (= 1 (aion/oauth/tests::as-refresh-requests as)))
      (is (equal "echo {}" (mcp:call-tool client tool (%obj) :principal "u1" :held t))
          "the refreshed token is used by the next call")
      (is (= 1 (fake-calls fake))))))

;;; --- resources and prompts (#527, part 4) -----------------------------------------------

(defun %resource-json (uri name &rest more)
  (apply #'%obj "uri" uri "name" name more))

(defun %contents (&rest objects) (coerce objects 'vector))

(test resources-and-templates-are-listed-across-pages-in-both-eras
  "An entry without a string uri or name is left out."
  (dolist (era '(:modern :legacy))
    (let ((fake (make-fake :era era :page-size 2)))
      (setf (fake-resources fake)
            (list (%resource-json "file:///a" "a" "mimeType" "text/plain" "size" 12)
                  (%obj "name" "no uri")
                  (%resource-json "file:///b" "b" "title" "B")
                  (%resource-json "file:///c" "c"))
            (fake-templates fake)
            (list (%obj "uriTemplate" "file:///{path}" "name" "files")))
      (with-fake (client fake)
        (let ((resources (mcp:list-resources client)))
          (is (equal '("file:///a" "file:///b" "file:///c") (mapcar #'mcp:resource-uri resources))
              "~A" era)
          (is (equal "text/plain" (mcp:resource-mime-type (first resources))))
          (is (eql 12 (mcp:resource-size (first resources))))
          (is (equal "B" (mcp:resource-title (second resources)))))
        (is (equal '("file:///{path}")
                   (mapcar #'mcp:resource-template-uri-template (mcp:list-resource-templates client))))))))

(test a-listing-page-without-a-list-fails
  (let ((fake (make-fake)))
    (setf (fake-bad-page fake) t)
    (with-fake (client fake)
      (dolist (list (list #'mcp:list-resources #'mcp:list-resource-templates #'mcp:list-prompts))
        (handler-case (progn (funcall list client) (fail "a page without a list was read"))
          (mcp:request-failed (e) (is (eq :not-run (cnd:tool-error-result-outcome e)))))))))

(test reading-a-resource-gives-its-text-and-describes-binary-content
  "Several contents in one reply; a blob is kept only as its length. The fake server checks
that Mcp-Name carries the URI, and an https URI is read through the server."
  (dolist (era '(:modern :legacy))
    (let ((fake (make-fake :era era)))
      (setf (fake-contents fake)
            (list (cons "file:///dir"
                        (%contents (%obj "uri" "file:///dir/a.txt" "mimeType" "text/plain" "text" "hello")
                                   (%obj "uri" "file:///dir/b.png" "mimeType" "image/png" "blob" "AAAA")))
                  (cons "https://example.invalid/page" (%contents (%obj "uri" "https://example.invalid/page"
                                                                        "text" "via the server")))))
      (with-fake (client fake)
        (let ((contents (mcp:read-resource client "file:///dir")))
          (is (equal '("hello" nil) (mapcar #'mcp:resource-content-text contents)) "~A" era)
          (is (equal '(nil 4) (mapcar #'mcp:resource-content-blob-length contents))))
        (is (equal "via the server"
                   (mcp:resource-content-text (first (mcp:read-resource client "https://example.invalid/page")))))))))

(test a-missing-resource-is-resource-not-found-and-other-failures-are-request-failed
  (let ((fake (make-fake)))
    (with-fake (client fake)
      (dolist (uri '("file:///missing" "file:///old-missing"))
        (handler-case (progn (mcp:read-resource client uri) (fail "no error for ~A" uri))
          (mcp:resource-not-found (e) (is (equal uri (mcp:resource-not-found-uri e))))))
      (dolist (uri '("file:///ask" "file:///no-contents"))
        (handler-case (progn (mcp:read-resource client uri) (fail "no error for ~A" uri))
          (mcp:resource-not-found () (fail "~A is not a missing resource" uri))
          (mcp:request-failed (e) (is (eq :not-run (cnd:tool-error-result-outcome e)))))))))

(defun %context-items (agent) (praxeon/context:context-items (actor:agent-context agent)))

(test a-resource-added-to-an-agent-is-labelled-replaced-and-removed
  (let ((fake (make-fake)))
    (setf (fake-contents fake)
          (list (cons "file:///notes" (%contents (%obj "uri" "file:///notes" "text" "first")))))
    (with-fake (client fake)
      (let ((agent (actor:make-agent)))
        (let ((items (mcp:add-resource agent client "file:///notes" :value 3)))
          (is (= 1 (length items)))
          (let ((item (first items)))
            (is-true (search "file:///notes" (praxeon/context:ctx-item-content item)))
            (is-true (search "connection docs" (praxeon/context:ctx-item-content item)))
            (is-true (search "not instructions" (praxeon/context:ctx-item-content item)))
            (is-true (search "first" (praxeon/context:ctx-item-content item)))
            (is (eq :resource (praxeon/context:ctx-item-role item)))
            (is (= 3 (praxeon/context:ctx-item-value item)))
            (is (equal '(:mcp "docs" :uri "file:///notes") (praxeon/context:ctx-item-source item)))
            (is (= (praxeon/prompt:estimate-tokens (praxeon/context:ctx-item-content item))
                   (praxeon/context:ctx-item-tokens item))
                "the tokens are the estimate of the item's whole text")))
        ;; Added again after it changed: the earlier copy is replaced.
        (setf (fake-contents fake)
              (list (cons "file:///notes" (%contents (%obj "uri" "file:///notes" "text" "second")))))
        (mcp:add-resource agent client "file:///notes")
        (is (= 1 (length (%context-items agent))))
        (is-true (search "second" (praxeon/context:ctx-item-content (first (%context-items agent)))))
        (is (= 1 (mcp:remove-resource agent client "file:///notes")))
        (is (null (%context-items agent)))))))

(test a-resource-larger-than-the-context-budget-signals-and-adds-nothing
  (let ((fake (make-fake)))
    (setf (fake-contents fake)
          (list (cons "file:///big" (%contents (%obj "uri" "file:///big/1" "text" "small")
                                               (%obj "uri" "file:///big/2"
                                                     "text" (make-string 4000 :initial-element #\x)))))
          )
    (with-fake (client fake)
      (let ((agent (actor:make-agent)))
        (setf (praxeon/context:context-budget (actor:agent-context agent)) 200)
        (handler-case (progn (mcp:add-resource agent client "file:///big") (fail "no signal"))
          (mcp:resource-too-large (e)
            (is (equal "file:///big" (mcp:resource-too-large-uri e)))
            (is (= 200 (mcp:resource-too-large-budget e)))
            (is (> (mcp:resource-too-large-tokens e) 200))))
        (is (null (%context-items agent)) "nothing added, not even the small content")))))

(test uri-templates-expand-at-levels-1-and-2-and-refuse-the-rest
  (is (equal "file:///a%20b" (mcp:expand-uri-template "file:///{path}" '(("path" . "a b")))))
  (is (equal "file:///a%2Fb" (mcp:expand-uri-template "file:///{path}" '(("path" . "a/b")))))
  (is (equal "file:///a/b" (mcp:expand-uri-template "file:///{+path}" '(("path" . "a/b")))))
  (is (equal "page#sec%20one" (mcp:expand-uri-template "page{#frag}" '(("frag" . "sec one")))))
  (is (equal "file:///" (mcp:expand-uri-template "file:///{path}" '())) "no value, no text")
  (is (equal "x/%C3%A9" (mcp:expand-uri-template "x/{v}" '(("v" . "é")))))
  ;; Variable names as RFC 6570 section 2.3 defines them: dotted segments and pct-encoded octets.
  (is (equal "u/7" (mcp:expand-uri-template "u/{user.id}" '(("user.id" . "7")))))
  (is (equal "u/8" (mcp:expand-uri-template "u/{%41b}" '(("%41b" . "8")))))
  (is (equal "u/9" (mcp:expand-uri-template "u/{a.b.c}" '(("a.b.c" . "9")))))
  (dolist (bad '("{.a}" "{a.}" "{a..b}" "{é}" "{%4}" "{a-b}"))
    (signals error (mcp:expand-uri-template bad '(("a" . "1"))) "~A" bad))
  (dolist (template '("{a,b}" "{?q}" "{x*}" "{x:3}" "{/p}" "{open" "close}"))
    (signals error (mcp:expand-uri-template template '(("a" . "1") ("b" . "2") ("q" . "3")
                                                     ("x" . "4") ("p" . "5") ("open" . "6"))))))

(defun %prompt-json (name &rest arguments)
  (%obj "name" name "description" (format nil "the ~A prompt" name)
        "arguments" (map 'vector (lambda (a) (%obj "name" (first a) "required" (second a))) arguments)))

(test prompts-are-listed-and-got-with-their-arguments
  (dolist (era '(:modern :legacy))
    (let ((fake (make-fake :era era)))
      (setf (fake-prompts fake) (list (%prompt-json "review" '("code" t) '("style" nil)))
            (fake-prompt-messages fake)
            (list (cons "review"
                        (vector (%obj "role" "user" "content" (%obj "type" "text" "text" "Review this."))
                                (%obj "role" "user" "content" (%obj "type" "image" "data" "AAAA" "mimeType" "image/png"))
                                (%obj "role" "user" "content" (%obj "type" "resource_link" "uri" "file:///x" "name" "x"))
                                (%obj "role" "user" "content" (%obj "type" "resource"
                                                                    "resource" (%obj "uri" "file:///y" "text" "embedded")))
                                (%obj "role" "user" "content" (%obj "type" "resource"
                                                                    "resource" (%obj "uri" "file:///z" "blob" "AAAA")))))))
      (with-fake (client fake)
        (let ((prompt (first (mcp:list-prompts client))))
          (is (equal "review" (mcp:prompt-name prompt)) "~A" era)
          (is (equal '(("code" . t) ("style" . nil))
                     (mapcar (lambda (a) (cons (mcp:prompt-argument-name a) (mcp:prompt-argument-required a)))
                             (mcp:prompt-arguments prompt))))
          (multiple-value-bind (messages description)
              (mcp:get-prompt client prompt :arguments '(("code" . "(+ 1 2)")))
            (is (equal "a prompt" description))
            (is (equal "(+ 1 2)" (gethash "code" (fake-prompt-arguments fake))))
            (let ((texts (mapcar (lambda (m) (getf (first (llm:content m)) :text)) messages)))
              (is (equal "Review this." (first texts)))
              (is-true (search "image omitted" (second texts)))
              (is-true (search "file:///x" (third texts)))
              (is (equal "embedded" (fourth texts)))
              (is-true (search "binary" (fifth texts)) "a blob-only embedded resource is described"))
            (is (= 5 (length (mcp:prompt-input prompt messages))) "one part per user message")))))))

(test a-prompt-missing-a-required-argument-is-refused-before-anything-is-sent
  (let ((fake (make-fake)))
    (setf (fake-prompts fake) (list (%prompt-json "review" '("code" t))))
    (with-fake (client fake)
      (let* ((prompt (first (mcp:list-prompts client)))
             (sent (length (requests))))
        (handler-case (progn (mcp:get-prompt client prompt) (fail "no refusal"))
          (mcp:request-failed (e) (is (eq :not-run (cnd:tool-error-result-outcome e)))))
        (handler-case (progn (mcp:get-prompt client prompt :arguments '(("code" . 42))) (fail "no refusal"))
          (mcp:request-failed (e) (is (eq :not-run (cnd:tool-error-result-outcome e)))))
        (is (= sent (length (requests))) "nothing was sent")))))

(test a-prompt-with-assistant-messages-is-not-one-user-turn
  (let ((fake (make-fake)))
    (setf (fake-prompts fake) (list (%prompt-json "chat"))
          (fake-prompt-messages fake)
          (list (cons "chat" (vector (%obj "role" "user" "content" (%obj "type" "text" "text" "Hi"))
                                     (%obj "role" "assistant" "content" (%obj "type" "text" "text" "Hello"))))))
    (with-fake (client fake)
      (let* ((prompt (first (mcp:list-prompts client)))
             (messages (mcp:get-prompt client prompt)))
        (handler-case (progn (mcp:prompt-input prompt messages) (fail "no signal"))
          (mcp:prompt-has-assistant-messages (e)
            (is (eq prompt (mcp:prompt-has-assistant-messages-prompt e)))))))))

(test a-per-user-connection-lists-no-resources-without-a-principal
  (let ((fake (make-fake)))
    (setf (fake-resources fake) (list (%resource-json "file:///a" "a")))
    (with-fake (client fake :per-user t :token-source (lambda (c p) (declare (ignore c p)) "t"))
      (handler-case (progn (mcp:list-resources client) (fail "no signal"))
        (mcp:sign-in-needed (e)
          (is-true (search "its server" (cnd:tool-error-result-text e)))
          (is (null (search "tool" (cnd:tool-error-result-text e))) "the text does not call it a tool")))
      (is (null (requests)) "nothing was sent"))))

(test a-malformed-prompt-message-fails-the-reply
  "A message that is not an object, or whose content is not a content block, fails the reply
rather than being left out: leaving it out could make a scripted exchange look user-only."
  (dolist (messages (list (vector (%obj "role" "user" "content" (%obj "type" "text" "text" "Hi")) "assistant said hello")
                          (vector (%obj "role" "user" "content" "not a block"))
                          (vector (%obj "role" "user" "content" (vector (%obj "type" "text" "text" "a") 7)))))
    (let ((fake (make-fake)))
      (setf (fake-prompts fake) (list (%prompt-json "p"))
            (fake-prompt-messages fake) (list (cons "p" messages)))
      (with-fake (client fake)
        (handler-case (progn (mcp:get-prompt client (first (mcp:list-prompts client))) (fail "no failure"))
          (mcp:request-failed (e) (is (eq :not-run (cnd:tool-error-result-outcome e)))))))))

(test a-prompt-message-content-is-one-content-block-of-a-known-type-with-its-fields
  "Every schema revision defines a PromptMessage's content as one ContentBlock, so a list of blocks
fails the reply, as does a block whose type is unknown or whose required fields are missing or
not strings (#569). A resource link fails a 2025-03-26 reply, whose schema has no such block."
  (dolist (content (list (vector (%obj "type" "text" "text" "a"))
                         (%obj "type" "text" "text" 42)
                         (%obj "type" "text")
                         (%obj "type" "image" "data" 42 "mimeType" "image/png")
                         (%obj "type" "audio" "data" "AAAA")
                         (%obj "type" "resource_link" "uri" "file:///x")
                         (%obj "type" "resource" "resource" (%obj "uri" "file:///y"))
                         (%obj "type" "resource" "resource" "file:///y")
                         (%obj "type" "video" "data" "AAAA" "mimeType" "video/mp4")))
    (let ((fake (make-fake)))
      (setf (fake-prompts fake) (list (%prompt-json "p"))
            (fake-prompt-messages fake) (list (cons "p" (vector (%obj "role" "user" "content" content)))))
      (with-fake (client fake)
        (handler-case (progn (mcp:get-prompt client (first (mcp:list-prompts client)))
                             (fail "~S was accepted" (jzon:stringify content)))
          (mcp:request-failed (e)
            (is (eq :not-run (cnd:tool-error-result-outcome e)) "~S" (jzon:stringify content)))))))
  ;; resource_link was added in 2025-06-18: a 2025-03-26 session refuses it, a later one takes it.
  (loop for (version accepted) in '(("2025-03-26" nil) ("2025-06-18" t))
        do (let ((fake (make-fake :era :legacy :legacy-version version)))
             (setf (fake-prompts fake) (list (%prompt-json "p"))
                   (fake-prompt-messages fake)
                   (list (cons "p" (vector (%obj "role" "user"
                                                 "content" (%obj "type" "resource_link"
                                                                 "uri" "file:///x" "name" "x"))))))
             (with-fake (client fake)
               (is (eq accepted (handler-case (progn (mcp:get-prompt client (first (mcp:list-prompts client))) t)
                                  (mcp:request-failed () nil)))
                   "~A" version)
               (is (equal version (mcp:client-protocol-version client)))))))

(test a-malformed-resource-content-fails-the-reply-and-keeps-the-earlier-copy
  "A content that is not an object, has no string uri, or has neither a string text nor a string
blob fails the reply rather than being left out, so ADD-RESOURCE never installs part of a
resource, or replaces it with nothing."
  (let ((fake (make-fake)))
    (setf (fake-contents fake) (list (cons "file:///r" (%contents (%obj "uri" "file:///r" "text" "good")))))
    (with-fake (client fake)
      (let ((agent (actor:make-agent)))
        (mcp:add-resource agent client "file:///r")
        (dolist (contents (list (vector (%obj "uri" "file:///r" "text" "new") "junk")
                                (vector (%obj "text" "no uri"))
                                ;; The schema requires a text or a blob (#569).
                                (vector (%obj "uri" "file:///r"))
                                (vector (%obj "uri" "file:///r" "text" 42))))
          (setf (fake-contents fake) (list (cons "file:///r" contents)))
          (handler-case (progn (mcp:read-resource client "file:///r") (fail "no failure"))
            (mcp:request-failed (e)
              (is (eq :not-run (cnd:tool-error-result-outcome e)))
              (when (eql 42 (gethash "text" (aref contents 0)))
                ;; A text that is present but not a string is named as such (#581).
                (is (search "neither a string text nor a string blob" (princ-to-string e))
                    "~A" e))))
          (signals mcp:request-failed (mcp:add-resource agent client "file:///r"))
          (is (= 1 (length (%context-items agent))))
          (is-true (search "good" (praxeon/context:ctx-item-content (first (%context-items agent))))
                   "the earlier copy is kept"))))))

;;; --- tool calls that become tasks (#532) ---------------------------------------------------

(defun %by-method (requests method)
  (remove-if-not (lambda (r) (equal method (th:request-header r "Mcp-Method"))) requests))

(defun %request-params (request)
  (gethash "params" (jzon:parse (th:request-body-string request))))

(defun %only-task (client)
  "The one task in CLIENT's store, whatever its next poll."
  (let ((tasks (mcp:due-tasks (mcp:client-task-store client) "docs" most-positive-fixnum)))
    (is (= 1 (length tasks)))
    (first tasks)))

(defun %poll-when-due (client)
  "Poll CLIENT's tasks at the moment the one stored task is next due."
  (mcp:poll-tasks client :now (mcp:task-next-poll (%only-task client))))

(test a-call-that-becomes-a-task-reports-started-and-is-polled-to-its-result
  (let ((fake (make-fake :tools (%tools '("long" :do :task)) :task-script '(:working :completed)))
        (events '()))
    (with-fake (client fake :tasks t :per-user t
                            :token-source (lambda (c p) (declare (ignore c)) (format nil "token-~A" p)))
      (let ((agent (%agent-calling "docs__long")))
        (mcp:grant-tools agent client :only :all :tools (mcp:list-tools client :principal "u1"))
        (evt:with-observer ((lambda (e) (push e events)))
          (is (equal "done" (actor:run-turn agent "go" :principal "u1")))
          (let ((result (find :tool-result events :key #'evt:event-type))
                (started (find :task-started events :key #'evt:event-type))
                (task (%only-task client)))
            (is (eq :started (getf result :outcome)) "a started task is not a result")
            (is-true (search "background task" (getf result :content)))
            (is (null (search "task-1" (getf result :content))) "the task id does not reach the model")
            (is (null (search "task-1" (format nil "~S" started))) "nor an event")
            (is (equal "c1" (getf started :id)))
            (is (equal "c1" (mcp:task-call-id task)))
            (is (equal "docs__long" (mcp:task-means task)))
            (is (null (mcp:poll-tasks client :now (1- (mcp:task-next-poll task))))
                "nothing is polled before it is due")
            (is (null (%poll-when-due client)) "the first poll answers working")
            (let ((finished (%poll-when-due client)))
              (is (= 1 (length finished)))
              (is (eq :ok (mcp:finished-task-outcome (first finished))))
              (is (equal "finished work" (mcp:finished-task-text (first finished))))
              (is-true (search "not a message from the user" (mcp:task-report (first finished))))
              (is-true (search "docs__long" (mcp:task-report (first finished)))))
            (is (null (mcp:due-tasks (mcp:client-task-store client) "docs" most-positive-fixnum))
                "a finished task leaves the store")
            (let ((done (find :task-finished events :key #'evt:event-type)))
              (is (equal "c1" (getf done :id)) "the ledger joins it to the call by its id")
              (is (eq :ok (getf done :outcome)))
              (is (equal "u1" (getf done :principal)))
              (is (equal (actor:agent-name agent) (getf done :agent)))
              (is (equal '(:connection "docs" :tool "long" :per-user t) (getf done :source)))))))
      (let* ((rs (requests))
             (gets (%by-method rs "tasks/get"))
             (call (first (%by-method rs "tools/call"))))
        (is-true (%declares-tasks-p (%request-params call)))
        (is (= 2 (length gets)) "two polls, none before it was due")
        (is (every (lambda (r) (equal "task-1" (th:request-header r "Mcp-Name"))) gets))
        (is (every (lambda (r) (equal "Bearer token-u1" (th:request-header r "Authorization"))) gets))))))

(test each-poll-fetches-the-token-of-the-tasks-principal-at-that-moment
  (let ((fake (make-fake :tools (%tools '("long" :do :task)) :task-script '(:working :working :completed)))
        (n 0))
    (with-fake (client fake :tasks t :per-user t
                            :token-source (lambda (c p) (declare (ignore c))
                                            (format nil "token-~A-~D" p (incf n))))
      (let ((tool (first (mcp:list-tools client :principal "u1"))))
        (is (typep (mcp:call-tool client tool (%obj) :principal "u7") 'actor:started-result))
        (let ((actor:*principal* "someone-else"))
          (dotimes (i 3) (%poll-when-due client))))
      (is (equal '("Bearer token-u7-3" "Bearer token-u7-4" "Bearer token-u7-5")
                 (mapcar (lambda (r) (th:request-header r "Authorization"))
                         (%by-method (requests) "tasks/get")))))))

(test without-the-option-no-task-is-declared-and-an-unasked-task-is-not-a-result
  "A connection without :TASKS declares no extension, so a compliant server answers -32021. A
server that sends a task anyway gets an invalid answer: the work may have started, so the
outcome is unknown, and nothing is recorded."
  (let ((fake (make-fake :tools (%tools '("long" :do :task) '("rogue" :do :rogue-task)))))
    (with-fake (client fake)
      (let ((tools (mcp:list-tools client)))
        (handler-case (progn (mcp:call-tool client (find "long" tools :key #'mcp:tool-name :test #'equal) (%obj))
                             (fail "no error"))
          (mcp:request-failed (e) (is (eql -32021 (mcp:request-failed-code e)))))
        (handler-case (progn (mcp:call-tool client (find "rogue" tools :key #'mcp:tool-name :test #'equal) (%obj))
                             (fail "an unasked task was taken"))
          (mcp:request-failed (e) (is (eq :unknown (cnd:tool-error-result-outcome e))))))
      (is (null (%declares-tasks-p (%request-params (first (%by-method (requests) "tools/call"))))))
      (is (null (mcp:due-tasks (mcp:client-task-store client) "docs" most-positive-fixnum))))))

(test a-task-that-asks-for-input-is-cancelled-and-does-not-wait
  "The client declares no elicitation, sampling or roots, so under MRTR server requirement 7 a
server sends it no input request. A task that asks anyway is cancelled with tasks/cancel, which
is the one refusal the specification allows, and finishes as :CANCELLED, naming the kinds."
  (let ((fake (make-fake :tools (%tools '("long" :do :task)) :task-script '(:input)))
        (events '()))
    (with-fake (client fake :tasks t)
      (let ((tool (first (mcp:list-tools client))))
        (mcp:call-tool client tool (%obj))
        (let ((finished (evt:with-observer ((lambda (e) (push e events)))
                          (%poll-when-due client))))
          (is (= 1 (length finished)))
          (is (eq :cancelled (mcp:finished-task-outcome (first finished))))
          (is-true (search "sampling/createMessage" (mcp:finished-task-text (first finished))))
          (is-true (search "an unknown kind" (mcp:finished-task-text (first finished))))
          (is (null (search "made/up" (mcp:finished-task-text (first finished))))
              "a method the specification does not define is not repeated to the model"))
        (let ((refused (find :task-input-refused events :key #'evt:event-type)))
          (is (equal '("made/up" "sampling/createMessage")
                     (sort (copy-list (getf refused :methods)) #'string<))))
        (is (eq :cancelled (getf (find :task-finished events :key #'evt:event-type) :outcome)))
        (is (equal '("task-1") (fake-cancels fake)))
        (is (null (mcp:poll-tasks client :now most-positive-fixnum)) "nothing is left to poll")
        (is (= 1 (length (%by-method (requests) "tasks/get"))))))))

(test each-terminal-status-finishes-the-task-with-its-outcome
  (loop for (script outcome text) in '(((:error-result) :error "bad input")
                                       ((:failed) :error "(code -32603)")
                                       ((:cancelled) :cancelled "cancelled by the server")
                                       ((:gone) :expired "no longer has"))
        do (let ((fake (make-fake :tools (%tools '("long" :do :task)) :task-script script)))
             (with-fake (client fake :tasks t)
               (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
               (let ((finished (first (%poll-when-due client))))
                 (is (eq outcome (mcp:finished-task-outcome finished)) "~S" script)
                 (is-true (search text (mcp:finished-task-text finished)) "~S: ~A" script
                          (mcp:finished-task-text finished))
                 (is (null (search "boom" (mcp:finished-task-text finished)))
                     "the server's error message is not repeated"))))))

(test a-task-past-its-time-to-live-is-polled-once-more-then-finishes-as-expired
  "The deadline counts from when the client received the task, and the next poll is due no later
than the deadline, even when the server's poll interval is longer. A task that is still working
when polled at its deadline finishes as :EXPIRED."
  (let ((fake (make-fake :tools (%tools '("long" :do :task)) :task-script '(:working)
                         :task-ttl-ms 3000)))
    (setf (fake-task-poll-ms fake) 60000)
    (with-fake (client fake :tasks t)
      (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
      (let ((task (%only-task client)))
        (is (= (+ 3 (mcp:task-seen task)) (mcp:task-deadline task)))
        (is (= (mcp:task-deadline task) (mcp:task-next-poll task))
            "due at the deadline, not 60 seconds on")
        (let ((finished (mcp:poll-tasks client :now (mcp:task-deadline task))))
          (is (eq :expired (mcp:finished-task-outcome (first finished))))
          (is-true (search "did not finish" (mcp:finished-task-text (first finished)))))
        (is (= 1 (length (%by-method (requests) "tasks/get"))) "it was polled once more")))))

(test the-time-to-live-counts-from-when-the-task-arrived-and-zero-is-not-rounded-up
  "A tools/call can take a while before the server answers with a task, so the deadline counts
from the answer, not from the start of the call. A ttlMs of 0 is a deadline of that moment, and
the task is still polled once before it is given up, so one that finished is not lost."
  (let ((fake (make-fake :tools (%tools '("long" :do :slow-task)) :task-ttl-ms 1000)))
    (with-fake (client fake :tasks t)
      (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
      (let ((task (%only-task client)))
        (is (> (mcp:task-seen task) (mcp:task-started task)))
        (is (= (+ 1 (mcp:task-seen task)) (mcp:task-deadline task))))))
  (let ((fake (make-fake :tools (%tools '("long" :do :task)) :task-script '(:completed)
                         :task-ttl-ms 0)))
    (with-fake (client fake :tasks t)
      (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
      (let ((task (%only-task client)))
        (is (= (mcp:task-seen task) (mcp:task-deadline task)))
        (is (eq :ok (mcp:finished-task-outcome
                     (first (mcp:poll-tasks client :now (mcp:task-deadline task))))))))))

(test a-task-without-the-fields-the-specification-requires-fails-the-call-as-unknown
  "A task must have a known status, createdAt, lastUpdatedAt and a ttlMs that is a number or
null. One that does not is not polled forever: the call fails with outcome :UNKNOWN, because the
work may have started, and nothing is recorded."
  (loop for plist in '((:drop ("createdAt")) (:drop ("lastUpdatedAt")) (:drop ("ttlMs"))
                       (:drop ("status")) (:set ("status" "running")) (:set ("ttlMs" -5))
                       (:set ("pollIntervalMs" "soon")))
        do (let ((fake (make-fake :tools (list (list* "long" :do :bad-task plist)))))
             (with-fake (client fake :tasks t)
               (handler-case (progn (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
                                    (fail "~S was taken as a task" plist))
                 (mcp:request-failed (e)
                   (is (eq :unknown (cnd:tool-error-result-outcome e)) "~S" plist)))
               (is (null (mcp:due-tasks (mcp:client-task-store client) "docs" most-positive-fixnum))
                   "~S" plist))))
  (let ((fake (make-fake :tools (list (list "long" :do :bad-task :drop '("pollIntervalMs")
                                            :set '("ttlMs" null))))))
    (with-fake (client fake :tasks t)
      (is (typep (mcp:call-tool client (first (mcp:list-tools client)) (%obj)) 'actor:started-result)
          "pollIntervalMs is optional and ttlMs may be null"))))

(test a-task-of-another-connection-is-neither-polled-nor-cancelled
  "Its id and principal would go to a server that did not issue them, so nothing is sent."
  (let ((fake (make-fake :tools (%tools '("long" :do :task)) :task-script '(:working))))
    (with-fake (client fake :tasks t)
      (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
      (let ((task (%only-task client)))
        (setf (mcp:task-connection task) "other")
        (signals error (mcp:poll-task client task))
        (signals error (mcp:cancel-task client task))
        (is (null (%by-method (requests) "tasks/get")))
        (is (null (%by-method (requests) "tasks/cancel")))))))

(test an-observer-that-fails-on-task-finished-does-not-lose-the-result
  "The task is marked finished in the store before the event. When the observer signals, the
next POLL-TASKS returns the result without polling the server and without the event."
  (let ((fake (make-fake :tools (%tools '("long" :do :task)) :task-script '(:completed)))
        (events '()))
    (with-fake (client fake :tasks t)
      (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
      (let ((due (mcp:task-next-poll (%only-task client))))
        (signals simple-error
          (evt:with-observer ((lambda (e) (when (eq :task-finished (evt:event-type e))
                                            (error "observer failed"))))
            (mcp:poll-tasks client :now due)))
        (let ((finished (evt:with-observer ((lambda (e) (push e events)))
                          (mcp:poll-tasks client :now due))))
          (is (= 1 (length finished)))
          (is (eq :ok (mcp:finished-task-outcome (first finished))))
          (is (equal "finished work" (mcp:finished-task-text (first finished)))))
        (is (null events) "the event the observer failed on is not sent again")
        (is (= 1 (length (%by-method (requests) "tasks/get"))))
        (is (null (mcp:poll-tasks client :now most-positive-fixnum)) "it is reported once")))))

(test an-observer-that-fails-on-the-refusal-does-not-stop-the-cancel
  (let ((fake (make-fake :tools (%tools '("long" :do :task)) :task-script '(:input))))
    (with-fake (client fake :tasks t)
      (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
      (let ((due (mcp:task-next-poll (%only-task client))))
        (signals simple-error
          (evt:with-observer ((lambda (e) (when (eq :task-input-refused (evt:event-type e))
                                            (error "observer failed"))))
            (mcp:poll-tasks client :now due)))
        (is (equal '("task-1") (fake-cancels fake)) "tasks/cancel was sent before the event")
        (let* ((events '())
               (finished (evt:with-observer ((lambda (e) (push e events)))
                           (mcp:poll-tasks client :now due))))
          (is (eq :cancelled (mcp:finished-task-outcome (first finished))))
          (is (equal '(:task-finished) (mapcar #'evt:event-type events))
              ":task-finished is sent on the next poll, and the refusal is not sent again")
          (is (eq :cancelled (getf (first events) :outcome))))
        (is (= 1 (length (%by-method (requests) "tasks/get"))))))))

(test an-observer-that-fails-on-one-task-loses-no-other-tasks-result
  "Two tasks finish in one POLL-TASKS, and the observer signals on the second :TASK-FINISHED. The
call returns nothing, and both finished records stay in the store, so the next POLL-TASKS
returns both results, with neither event sent again (#565 review)."
  (let ((fake (make-fake :tools (%tools '("long" :do :task)) :task-script '(:completed)))
        (seen 0) (events '()))
    (with-fake (client fake :tasks t)
      (let ((tool (first (mcp:list-tools client))))
        (mcp:call-tool client tool (%obj))
        (mcp:call-tool client tool (%obj)))
      (let ((due (+ (get-universal-time) 60)))
        (signals simple-error
          (evt:with-observer ((lambda (e) (when (and (eq :task-finished (evt:event-type e))
                                                     (= 2 (incf seen)))
                                            (error "observer failed"))))
            (mcp:poll-tasks client :now due)))
        (is (= 2 seen) "the first task's event was sent before the second failed")
        (let ((finished (evt:with-observer ((lambda (e) (push e events)))
                          (mcp:poll-tasks client :now due))))
          (is (= 2 (length finished)) "neither result is lost")
          (is (every (lambda (f) (eq :ok (mcp:finished-task-outcome f))) finished))
          (is (equal '("task-1" "task-2")
                     (sort (mapcar (lambda (f) (praxeon/mcp::task-id (mcp:finished-task-task f))) finished)
                           #'string<))))
        (is (null events) "no :task-finished is sent twice")
        (is (= 2 (length (%by-method (requests) "tasks/get"))) "each task was polled once")
        (is (null (mcp:poll-tasks client :now most-positive-fixnum)) "each is returned once")))))

(test a-task-without-a-time-to-live-is-given-up-after-the-connections-task-lifetime
  "A server may give a task a ttlMs of null. The client then counts the connection's
TASK-LIFETIME, one day by default, from when it received the task, so a task whose polls keep
failing, as they do while a user has not signed in again, is not polled for ever (#565 review)."
  (is (= (* 24 60 60) (mcp:connection-task-lifetime (mcp:make-connection :name "x" :url "http://x/"))))
  (let ((fake (make-fake :tools (%tools '("long" :do :task)) :task-script '(:working))))
    (with-fake (client fake :tasks t :task-lifetime 60)
      (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
      (let ((task (%only-task client)))
        (is (= (+ 60 (mcp:task-seen task)) (mcp:task-deadline task)))
        (setf (fake-fail-next fake) t)
        (is (null (mcp:poll-tasks client :now (+ 10 (mcp:task-seen task)))) "a failed poll before the limit")
        (is (<= (mcp:task-next-poll (%only-task client)) (mcp:task-deadline task)))
        (setf (fake-fail-next fake) t)
        (let ((finished (mcp:poll-tasks client :now (mcp:task-deadline task))))
          (is (eq :expired (mcp:finished-task-outcome (first finished))) "a failed poll at the limit")
          (is-true (search "did not finish" (mcp:finished-task-text (first finished))))))))
  (let ((fake (make-fake :tools (%tools '("long" :do :task)) :task-script '(:working))))
    (with-fake (client fake :tasks t :task-lifetime 60)
      (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
      (let ((task (%only-task client)))
        (is (eq :expired (mcp:finished-task-outcome
                          (first (mcp:poll-tasks client :now (mcp:task-deadline task)))))
            "a task still working at the limit")))))

(test a-poll-that-read-a-task-before-another-finished-it-cannot-bring-it-back
  "Two pollers share the store. Once one has finished a task, the other's update, made from what
it read before, changes nothing, and its own finish is refused, so the task is reported once."
  (let* ((store (mcp:make-memory-task-store))
         (task (praxeon/mcp::%make-task :key "k" :connection "docs" :id "task-9" :next-poll 0)))
    (mcp:save-task store task)
    (destructuring-bind (a) (mcp:due-tasks store "docs" 0)
      (destructuring-bind (b) (mcp:due-tasks store "docs" 0)
        (setf (mcp:task-status b) "changed by b")
        (is (equal "working" (mcp:task-status (first (mcp:due-tasks store "docs" 0))))
            "a task from DUE-TASKS is a copy")
        (setf (mcp:task-outcome a) :ok (mcp:task-text a) "done")
        (is-true (mcp:finish-task store a))
        (is (null (mcp:update-task store b)) "a stale update is refused")
        (setf (mcp:task-outcome b) :ok)
        (is (null (mcp:finish-task store b)) "a second finish is refused")
        (is (eq :ok (mcp:task-outcome (first (mcp:due-tasks store "docs" 0)))))
        (is-true (mcp:remove-task store a))
        (is (null (mcp:update-task store b)) "nor does a removed task come back")
        (is (null (mcp:due-tasks store "docs" most-positive-fixnum)))))))

(test a-cancelled-task-is-told-to-the-server-and-leaves-the-store
  (let ((fake (make-fake :tools (%tools '("long" :do :task)) :task-script '(:working))))
    (with-fake (client fake :tasks t)
      (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
      (let ((finished (mcp:cancel-task client (%only-task client))))
        (is (eq :cancelled (mcp:finished-task-outcome finished)))
        (is (equal '("task-1") (fake-cancels fake)))
        (is (equal "task-1" (th:request-header (first (%by-method (requests) "tasks/cancel"))
                                                "Mcp-Name")))
        (is (null (mcp:due-tasks (mcp:client-task-store client) "docs" most-positive-fixnum)))))))

(test a-task-record-survives-json-and-a-store-removes-it-once
  (let* ((task (praxeon/mcp::%make-task :key "k" :connection "docs" :id "task-9" :principal "u1"
                                        :tool "long" :means "docs__long"
                                        :source '(:connection "docs" :tool "long" :per-user t)
                                        :agent "a" :conversation nil :call-id "c1" :started 100
                                        :seen 101 :deadline nil :interval 5 :next-poll 105
                                        :status "working" :outcome :cancelled :text "gone"
                                        :announced-at 106 :failures 3 :failure :sign-in))
         (back (mcp:task-from-json (mcp:task-to-json task)))
         (store (mcp:make-memory-task-store)))
    (is (equalp task back))
    (signals error (mcp:task-to-json (praxeon/mcp::%make-task :key "k" :principal :keyword)))
    (mcp:save-task store back)
    (is-true (mcp:remove-task store back))
    (is (null (mcp:remove-task store back)) "a second remover is told it was already gone")))

(test polls-that-keep-failing-wait-twice-as-long-each-time-up-to-the-cap
  "After each failed poll in a row the wait doubles, from the task's poll interval up to the
connection's TASK-BACKOFF-CAP, five minutes by default. A poll that succeeds goes back to the
interval (#565 review)."
  (is (= 300 (mcp:connection-task-backoff-cap (mcp:make-connection :name "x" :url "http://x/"))))
  (let ((fake (make-fake :tools (%tools '("long" :do :task)) :task-script '(:working))))
    (with-fake (client fake :tasks t :task-backoff-cap 8)
      (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
      (is (= 1 (mcp:task-interval (%only-task client))))
      (let ((waits '()))
        (dotimes (i 5)
          (let ((now (mcp:task-next-poll (%only-task client))))
            (setf (fake-get-status fake) 503)
            (is (null (mcp:poll-tasks client :now now)))
            (push (- (mcp:task-next-poll (%only-task client)) now) waits)))
        (is (equal '(1 2 4 8 8) (reverse waits)) "~S" (reverse waits))
        (is (= 5 (mcp:task-failures (%only-task client))))
        (let ((now (mcp:task-next-poll (%only-task client))))
          (setf (fake-get-status fake) nil)
          (mcp:poll-tasks client :now now)
          (is (= 1 (- (mcp:task-next-poll (%only-task client)) now)) "a success resets the wait")
          (is (= 0 (mcp:task-failures (%only-task client))))))))
  (is (= 20 (praxeon/mcp::%backoff 5 3 300)) "the third failure in a row waits four intervals")
  (is (= 300 (praxeon/mcp::%backoff 1 1000000 300)) "a long run of failures stops at the cap"))

(defun %poll-leaving (client exit now)
  "POLL-TASKS for CLIENT at NOW, where EXIT says how a sign-in failure leaves it: :OBSERVER, an
observer of :SIGN-IN-REQUIRED that signals, or :HANDLER, a HANDLER-CASE for
AUTHORIZATION-REQUIRED. Returns :LEFT when the poll was left that way."
  (ecase exit
    (:observer
     (handler-case (evt:with-observer ((lambda (e) (when (eq :sign-in-required (evt:event-type e))
                                                     (error "the observer failed"))))
                     (mcp:poll-tasks client :now now))
       (simple-error () :left)))
    (:handler
     (handler-case (mcp:poll-tasks client :now now)
       (mcp:authorization-required () :left)))))

(test a-poll-left-when-the-app-is-told-to-sign-in-is-recorded-and-the-task-still-expires
  "When an observer of :SIGN-IN-REQUIRED signals, or an app's handler of AUTHORIZATION-REQUIRED
exits, the poll is left before it can record its failure. It is recorded anyway: the task waits
before its next poll, later polls do not tell the app again, and the task expires at its deadline.
A poll left that way at the deadline marks the task expired, and the next poll reports it (#565
review)."
  (dolist (exit '(:observer :handler))
    (let ((fake (make-fake :tools (%tools '("long" :do :task)) :task-script '(:working)
                           :require-token "good" :task-ttl-ms 20000))
          (token "good"))
      (with-fake (client fake :tasks t :token-source (lambda (c p) (declare (ignore c p)) token))
        (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
        (setf token "expired")
        (let* ((now (mcp:task-next-poll (%only-task client)))
               (deadline (mcp:task-deadline (%only-task client))))
          (is (eq :left (%poll-leaving client exit now)) "~A" exit)
          (let ((task (%only-task client)))
            (is (= 1 (mcp:task-failures task)) "~A: the failure is recorded" exit)
            (is (eq :sign-in (mcp:task-failure task)) "~A" exit)
            (is (< now (mcp:task-next-poll task)) "~A: not due again at once" exit))
          (is (null (mcp:poll-tasks client :now now)) "~A: not polled again before its wait" exit)
          (loop for next = (mcp:task-next-poll (%only-task client))
                repeat 20
                while (< next deadline)
                do (is (null (%poll-leaving client exit next)) "~A: later polls are not left" exit))
          (let ((finished (%poll-leaving client exit deadline)))
            (is (eq :expired (and (consp finished) (mcp:finished-task-outcome (first finished))))
                "~A: expired at the deadline: ~S" exit finished)))))
    (let ((fake (make-fake :tools (%tools '("long" :do :task)) :task-script '(:working)
                           :require-token "good" :task-ttl-ms 20000))
          (token "good"))
      (with-fake (client fake :tasks t :token-source (lambda (c p) (declare (ignore c p)) token))
        (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
        (setf token "expired")
        (let ((deadline (mcp:task-deadline (%only-task client))))
          (is (eq :left (%poll-leaving client exit deadline)) "~A, at the deadline" exit)
          (is (eq :expired (mcp:task-outcome (%only-task client))) "~A: marked expired" exit)
          (let ((events '()))
            (let ((finished (evt:with-observer ((lambda (e) (push (evt:event-type e) events)))
                              (mcp:poll-tasks client :now deadline))))
              (is (eq :expired (mcp:finished-task-outcome (first finished))) "~A" exit)
              (is (equal '(:task-finished) events) "~A: announced, with no poll: ~S" exit events))))))))

(defclass %store-failing-updates (praxeon/mcp::memory-task-store)
  ((fail :initform nil :accessor %store-fails)
   (finishes :initform 0 :accessor %store-finishes))
  (:documentation "A memory task store whose UPDATE-TASK and FINISH-TASK signal while FAIL is
true. FINISHES counts the calls to FINISH-TASK, failed or not."))
(defmethod mcp:update-task :before ((store %store-failing-updates) task)
  (declare (ignore task))
  (when (%store-fails store) (error "the store failed")))
(defmethod mcp:finish-task :before ((store %store-failing-updates) task)
  (declare (ignore task))
  (incf (%store-finishes store))
  (when (%store-fails store) (error "the store failed")))

(test a-store-error-while-recording-a-left-poll-does-not-replace-the-callers-error
  "When a poll is left by an observer's error and the store then fails to record the failed poll,
the store's error is logged, and the caller gets the observer's error. The task keeps its last
record (#565 review)."
  (let ((fake (make-fake :tools (%tools '("long" :do :task)) :task-script '(:working)
                         :require-token "good"))
        (store (make-instance '%store-failing-updates))
        (token "good"))
    (with-fake (client fake :tasks t :token-source (lambda (c p) (declare (ignore c p)) token))
      (setf (mcp:client-task-store client) store)
      (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
      (setf token "expired" (%store-fails store) t)
      (let ((message (handler-case
                         (evt:with-observer ((lambda (e)
                                               (when (eq :sign-in-required (evt:event-type e))
                                                 (error "the observer failed"))))
                           (mcp:poll-tasks client :now (mcp:task-next-poll (%only-task client)))
                           nil)
                       (error (e) (princ-to-string e)))))
        (is (equal "the observer failed" message) "~S" message))
      (is (= 0 (mcp:task-failures (%only-task client))) "the record is unchanged"))))

(test a-refused-task-whose-cancel-is-left-for-sign-in-is-still-cancelled
  "A task that asks for input is cancelled. When tasks/cancel needs a sign-in, and an observer
of :SIGN-IN-REQUIRED signals or an app's handler of AUTHORIZATION-REQUIRED exits, the poll is
left before the task is marked cancelled. It is marked anyway, so the next poll announces it once
and does not send tasks/cancel again. When the store fails while marking it, the caller still
gets the condition that left the poll (#587)."
  (dolist (exit '(:observer :handler))
    (let ((fake (make-fake :tools (%tools '("long" :do :task)) :task-script '(:input))))
      (setf (fake-cancel-token fake) "for-cancel")
      (with-fake (client fake :tasks t)
        (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
        (let ((now (mcp:task-next-poll (%only-task client)))
              (events '()))
          (is (eq :left (%poll-leaving client exit now)) "~A" exit)
          (is (eq :cancelled (mcp:task-outcome (%only-task client)))
              "~A: finished after one poll" exit)
          (let ((finished (evt:with-observer ((lambda (e) (push (evt:event-type e) events)))
                            (mcp:poll-tasks client :now now))))
            (is (eq :cancelled (and finished (mcp:finished-task-outcome (first finished))))
                "~A: ~S" exit finished)
            (is (search "asked for input" (mcp:finished-task-text (first finished))) "~A" exit))
          (is (equal '(:task-finished) events) "~A: announced once: ~S" exit events)
          (is (null (mcp:poll-tasks client :now now)) "~A: nothing left to poll" exit)
          (is (= 1 (length (%by-method (requests) "tasks/cancel")))
              "~A: tasks/cancel was not sent again" exit)))))
  (let ((fake (make-fake :tools (%tools '("long" :do :task)) :task-script '(:input)))
        (store (make-instance '%store-failing-updates)))
    (setf (fake-cancel-token fake) "for-cancel")
    (with-fake (client fake :tasks t)
      (setf (mcp:client-task-store client) store)
      (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
      (setf (%store-fails store) t)
      (let ((message (handler-case
                         (evt:with-observer ((lambda (e)
                                               (when (eq :sign-in-required (evt:event-type e))
                                                 (error "the observer failed"))))
                           (mcp:poll-tasks client :now (mcp:task-next-poll (%only-task client)))
                           nil)
                       (error (e) (princ-to-string e)))))
        (is (equal "the observer failed" message) "the store's error does not replace it: ~S"
            message))
      (is (= 1 (%store-finishes store)) "the cleanup tried to mark the task cancelled")
      (is (null (mcp:task-outcome (%only-task client))) "the record is unchanged"))))

(defclass %store-without-announce () ()
  (:documentation "A task store with every task-store method but ANNOUNCE-TASK."))
(defmethod mcp:save-task ((store %store-without-announce) task) (declare (ignore task)) t)
(defmethod mcp:update-task ((store %store-without-announce) task) (declare (ignore task)) t)
(defmethod mcp:finish-task ((store %store-without-announce) task) (declare (ignore task)) t)
(defmethod mcp:due-tasks ((store %store-without-announce) name now) (declare (ignore name now)) '())
(defmethod mcp:remove-task ((store %store-without-announce) task) (declare (ignore task)) t)
(defclass %store-with-around-announce (%store-without-announce) ()
  (:documentation "A store whose only ANNOUNCE-TASK method is an :AROUND method."))
(defmethod mcp:announce-task :around ((store %store-with-around-announce) task)
  (declare (ignore task))
  (call-next-method))

(test settings-a-poll-would-fail-on-are-refused-when-the-connection-and-client-are-made
  "TASK-LIFETIME and TASK-BACKOFF-CAP must be positive integers, and a task store needs a method
for each task-store function. Otherwise a task could start and then fail on its first poll
(#565 review)."
  (dolist (args '((:task-lifetime nil) (:task-lifetime 0) (:task-lifetime 1.5)
                  (:task-backoff-cap nil) (:task-backoff-cap -1)))
    (signals type-error (apply #'mcp:make-connection :name "x" :url "http://x/" args)))
  (let ((connection (mcp:make-connection :name "x" :url "http://x/" :task-lifetime 60
                                         :task-backoff-cap 10)))
    (is (= 60 (mcp:connection-task-lifetime connection)))
    (is-true (mcp:make-client connection))
    (let ((message (handler-case (progn (mcp:make-client connection
                                                         :task-store (make-instance '%store-without-announce))
                                        nil)
                     (error (e) (princ-to-string e)))))
      (is (search "announce-task" message) "~S" message)
      (is (null (search "save-task" message)) "only the missing one is named: ~S" message))
    (let ((method (eval '(defmethod mcp:announce-task ((store t) task)
                          (declare (ignore store task))
                          nil))))
      (unwind-protect
           (signals error (mcp:make-client connection
                                           :task-store (make-instance '%store-without-announce)))
        (remove-method #'mcp:announce-task method)))
    (signals error (mcp:make-client connection
                                    :task-store (make-instance '%store-with-around-announce))
      "an :around method is not an implementation")
    (signals error (mcp:make-client connection :task-store nil))))

(test sign-in-required-is-emitted-once-for-each-run-of-failed-polls
  "While a task's principal has to sign in, each poll fails. The app is told once, with
:SIGN-IN-REQUIRED and AUTHORIZATION-REQUIRED, when the run of failures starts, not on every
poll. A poll that succeeds, or that fails for another reason, ends the run, and the next sign-in
failure tells the app again (#565 review)."
  (let* ((token "good")
         (fake (make-fake :tools (%tools '("long" :do :task)) :task-script '(:working)
                          :require-token "good"))
         (events 0) (signalled 0))
    (with-fake (client fake :tasks t :token-source (lambda (c p) (declare (ignore c p)) token))
      (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
      (flet ((poll (&key fail)
               (setf (fake-get-status fake) (and fail 503))
               (handler-bind ((mcp:authorization-required (lambda (c) (declare (ignore c)) (incf signalled))))
                 (evt:with-observer ((lambda (e) (when (eq :sign-in-required (evt:event-type e))
                                                   (incf events))))
                   (mcp:poll-tasks client :now (mcp:task-next-poll (%only-task client)))))))
        (setf token "expired")
        (poll) (poll) (poll)
        (is (= 1 events) "three failed polls, one event")
        (is (= 1 signalled))
        (is (eq :sign-in (mcp:task-failure (%only-task client))))
        (setf token "good")
        (poll)
        (is (null (mcp:task-failure (%only-task client))) "a success ends the run")
        (setf token "expired")
        (poll) (poll)
        (is (= 2 events) "a new run after a success")
        (setf token "good")
        (poll :fail t)
        (is (eq :error (mcp:task-failure (%only-task client))) "the server failed the poll")
        (setf token "expired")
        (poll)
        (is (= 3 events) "a new run after another kind of failure")
        (is (= 3 signalled))))))

(test a-store-announces-a-finished-task-only-on-the-first-call
  "ANNOUNCE-TASK marks a finished record as announced, and returns true only for the first call,
so :TASK-FINISHED is sent once. The calls here are made one after the other. A task not yet
finished, or no longer in the store, is not announced."
  (let* ((store (mcp:make-memory-task-store))
         (task (praxeon/mcp::%make-task :key "k" :connection "docs" :id "task-9" :next-poll 0)))
    (mcp:save-task store task)
    (setf (mcp:task-announced-at task) 5)
    (is (null (mcp:announce-task store task)) "not finished yet")
    (setf (mcp:task-outcome task) :ok (mcp:task-announced-at task) nil)
    (is-true (mcp:finish-task store task))
    (setf (mcp:task-announced-at task) 7)
    (is-true (mcp:announce-task store task))
    (is (null (mcp:announce-task store task)) "a second announcement is refused")
    (is (= 7 (mcp:task-announced-at (first (mcp:due-tasks store "docs" 0)))))
    (is-true (mcp:remove-task store task))
    (is (null (mcp:announce-task store task)) "nor is a removed task announced")))

(test a-ledger-written-for-ok-and-error-counts-a-started-call-only-when-it-finishes
  "A ledger an app wrote before #532 counts :OK and :ERROR results and puts anything else in
OTHER. It sees the started call's :STARTED outcome as other, not as a result, and the
:TASK-FINISHED event, joined by the call's id, gives it the result when the task ends."
  (let ((fake (make-fake :tools (%tools '("long" :do :task)) :task-script '(:completed)))
        (ledger (list :ok 0 :error 0 :other 0)) (started-ids '()))
    (flet ((record (event)
             (case (evt:event-type event)
               (:tool-result
                (case (getf event :outcome)
                  (:ok (incf (getf ledger :ok)))
                  (:error (incf (getf ledger :error)))
                  (t (incf (getf ledger :other))
                     (push (getf event :id) started-ids))))
               (:task-finished
                (when (member (getf event :id) started-ids :test #'equal)
                  (case (getf event :outcome)
                    (:ok (incf (getf ledger :ok)))
                    (:error (incf (getf ledger :error)))
                    (t (incf (getf ledger :other)))))))))
      (with-fake (client fake :tasks t)
        (let ((agent (%agent-calling "docs__long")))
          (mcp:grant-tools agent client :only :all)
          (evt:with-observer (#'record)
            (actor:run-turn agent "go")
            (is (equal '(:ok 0 :error 0 :other 1) ledger) "the start is not counted as a result")
            (%poll-when-due client)
            (is (equal '(:ok 1 :error 0 :other 1) ledger))))))))

;;; --- elicitation in tasks (#563) ------------------------------------------------------------

(defun %capabilities (request)
  "The client capabilities REQUEST's _meta declares."
  (gethash "io.modelcontextprotocol/clientCapabilities"
           (gethash "_meta" (%request-params request))))

(test the-elicitation-capability-is-declared-only-for-the-modes-given
  (dolist (case '((nil . nil) ((:form) . ("form")) ((:form :url) . ("form" "url"))))
    (let ((fake (make-fake :tools (%tools '("long" :do :task)))))
      (with-fake (client fake :tasks t :elicitation (car case))
        (mcp:list-tools client)
        (let* ((caps (%capabilities (first (%by-method (requests) "tools/list"))))
               (elicitation (gethash "elicitation" caps)))
          (if (cdr case)
              (is (equal (cdr case)
                         (sort (loop for k being the hash-keys of elicitation collect k) #'string<))
                  "~S declares ~S" (car case) elicitation)
              (is (null elicitation) "no :elicitation declares none"))
          (is (null (gethash "sampling" caps)) "sampling is never declared")
          (is (null (gethash "roots" caps)) "roots are never declared"))))))

(test make-connection-refuses-bad-elicitation-options
  (dolist (bad '((:elicitation (:sms)) (:elicitation (:form :form)) (:elicitation :form)
                 (:input-timeout 0) (:input-timeout "10")))
    (is (typep (nth-value 1 (ignore-errors (apply #'mcp:make-connection :name "x" :url "http://x" bad)))
               'error)
        "~S was accepted" bad))
  (is-true (mcp:make-connection :name "x" :url "http://x" :elicitation '(:url :form) :input-timeout 5)
           "the control: well-formed options are accepted"))

(test a-task-asking-a-declared-elicitation-tells-the-app-once-and-sends-its-answer
  (let ((fake (make-fake :tools (%tools '("long" :do :task))
                         :task-script '((:elicit ("k1" :form)) (:elicit ("k1" :form))
                                        (:elicit ("k1" :form)) :completed)))
        (events '()))
    (with-fake (client fake :tasks t :elicitation '(:form))
      (let ((tool (first (mcp:list-tools client))))
        (mcp:call-tool client tool (%obj))
        (evt:with-observer ((lambda (e) (push e events)))
          (is (null (%poll-when-due client)) "a task waiting for input is not finished")
          (is (null (%poll-when-due client)) "and still not, when the server asks the same key again"))
        (let ((asked (remove :task-input-required events :key #'evt:event-type :test-not #'eq)))
          (is (= 1 (length asked)) "the key is shown once across two polls: ~S" asked)
          (let ((e (first asked)))
            (is (equal "k1" (getf e :input-key)))
            (is (eq :form (getf e :mode)))
            (is (equal "Your name, for k1?" (getf e :message)))
            (is (hash-table-p (getf e :schema)))
            (is (null (fake-cancels fake)) "nothing was cancelled")
            (is-true (mcp:answer-task-input client (getf e :task) "k1" :accept
                                            :content (%obj "name" "Luca")))))
        (let ((update (first (fake-updates fake))))
          (is (equal "task-1" (car update)))
          (is (equal "accept" (gethash "action" (gethash "k1" (cdr update)))))
          (is (equal "Luca" (gethash "name" (gethash "content" (gethash "k1" (cdr update)))))))
        (is (= 1 (length (%by-method (requests) "tasks/update"))))
        (let ((finished (%poll-when-due client)))
          (is (eq :ok (mcp:finished-task-outcome (first finished)))))))))

(test answer-task-input-refuses-and-sends-nothing
  (let ((fake (make-fake :tools (%tools '("long" :do :task))
                         :task-script '((:elicit ("k1" :form)))))
        (events '()))
    (with-fake (client fake :tasks t :elicitation '(:form))
      (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
      (evt:with-observer ((lambda (e) (push e events)))
        (%poll-when-due client))
      (let ((task (getf (find :task-input-required events :key #'evt:event-type) :task)))
        (dolist (bad (list (list "no-such-key" :accept)
                           (list "k1" :maybe)
                           (list "k1" :decline :content (%obj "name" "x"))
                           (list "k1" :accept :content "not an object")))
          (is (typep (nth-value 1 (ignore-errors (apply #'mcp:answer-task-input client task bad)))
                     'error)
              "~S was accepted" bad))
        (is (null (fake-updates fake)) "nothing was sent")
        (is-true (mcp:answer-task-input client task "k1" :decline))
        (is (typep (nth-value 1 (ignore-errors (mcp:answer-task-input client task "k1" :accept)))
                   'error)
            "a key already answered is not answered again")
        (is (= 1 (length (fake-updates fake))))))))

(test an-unanswered-elicitation-is-answered-cancel-after-the-input-timeout
  (let ((fake (make-fake :tools (%tools '("long" :do :task))
                         :task-script '((:elicit ("k1" :form)))))
        (events '()))
    (with-fake (client fake :tasks t :elicitation '(:form) :input-timeout 60)
      (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
      (evt:with-observer ((lambda (e) (push e events)))
        (let ((first-poll (mcp:task-next-poll (%only-task client))))
          (mcp:poll-tasks client :now first-poll)
          (is (null (fake-updates fake)) "not before the time limit")
          (mcp:poll-tasks client :now (+ first-poll 61))
          (mcp:poll-tasks client :now (+ first-poll 122))))
      (is (= 1 (length (fake-updates fake))) "cancel is answered once: ~S" (fake-updates fake))
      (is (equal "cancel" (gethash "action" (gethash "k1" (cdr (first (fake-updates fake)))))))
      (is (= 1 (count :task-input-expired events :key #'evt:event-type)))
      (is (null (fake-cancels fake)) "the task itself is not cancelled"))))

(test an-input-request-the-connection-did-not-declare-still-cancels-the-task
  "A url elicitation on a connection that declared form only, or a sampling request beside a
form elicitation, is a request server requirement 7 forbids; the task is cancelled as before."
  (dolist (case '(((:elicit ("k1" :url)) . (:form))
                  ((:elicit ("k1" :form) ("k2" :sampling)) . (:form))
                  ((:elicit ("k1" :form)) . nil)
                  ;; Malformed (Copilot's review of #627): no schema, or no URL.
                  ((:elicit ("k1" :form-bare)) . (:form))
                  ((:elicit ("k1" :url-bare)) . (:url))))
    (let ((fake (make-fake :tools (%tools '("long" :do :task)) :task-script (list (car case))))
          (events '()))
      (with-fake (client fake :tasks t :elicitation (cdr case))
        (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
        (let ((finished (evt:with-observer ((lambda (e) (push e events)))
                          (%poll-when-due client))))
          (is (eq :cancelled (mcp:finished-task-outcome (first finished))) "~S" case)
          (is (equal '("task-1") (fake-cancels fake)) "~S" case)
          (is (null (find :task-input-required events :key #'evt:event-type))
              "~S: the app is not asked" case))))))

(test the-shown-input-keys-survive-the-task-record-in-json
  (let ((task (mcp::%make-task :key "k" :connection "docs" :id "t" :started 1 :seen 1
                               :inputs '(("a" 10 nil) ("b" 20 t)))))
    (is (equal '(("a" 10 nil) ("b" 20 t))
               (mcp:task-inputs (mcp:task-from-json (mcp:task-to-json task)))))
    (let ((old (jzon:parse (mcp:task-to-json task))))
      (remhash "inputs" old)
      (is (null (mcp:task-inputs (mcp:task-from-json (jzon:stringify old))))
          "a record written before #563 has no inputs"))))

(test an-observer-can-answer-from-inside-the-event
  "Copilot's review of #627: the key is recorded on the event's task before the event, so an app
that answers at once, from its observer, is not refused."
  (let ((fake (make-fake :tools (%tools '("long" :do :task))
                         :task-script '((:elicit ("k1" :form)))))
        (answered nil))
    (with-fake (client fake :tasks t :elicitation '(:form))
      (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
      (evt:with-observer ((lambda (e)
                            (when (eq :task-input-required (evt:event-type e))
                              (setf answered (mcp:answer-task-input client (getf e :task)
                                                                    (getf e :input-key) :decline)))))
        (%poll-when-due client))
      (is-true answered "the answer from inside the event was sent")
      (is (= 1 (length (fake-updates fake)))))))

(test an-answer-for-a-task-the-server-has-finished-is-not-sent
  "Copilot's review of #627: the event's task is a copy from when the key was shown. When the
server has since finished the task, the answer is refused and no tasks/update is sent."
  (let ((fake (make-fake :tools (%tools '("long" :do :task))
                         :task-script '((:elicit ("k1" :form)) :completed)))
        (events '()))
    (with-fake (client fake :tasks t :elicitation '(:form))
      (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
      (evt:with-observer ((lambda (e) (push e events)))
        (%poll-when-due client))
      (let ((task (getf (find :task-input-required events :key #'evt:event-type) :task)))
        (is (typep (nth-value 1 (ignore-errors
                                 (mcp:answer-task-input client task "k1" :accept
                                                        :content (%obj "name" "x"))))
                   'error))
        (is (null (fake-updates fake)) "nothing was sent")))))

(test an-answer-to-a-url-request-carries-no-content
  "Copilot's review of #627: an ElicitResult for a url-mode request omits content."
  (let ((fake (make-fake :tools (%tools '("long" :do :task))
                         :task-script '((:elicit ("k1" :url)))))
        (events '()))
    (with-fake (client fake :tasks t :elicitation '(:url))
      (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
      (evt:with-observer ((lambda (e) (push e events)))
        (%poll-when-due client))
      (let* ((e (find :task-input-required events :key #'evt:event-type))
             (task (getf e :task)))
        (is (eq :url (getf e :mode)))
        (is (equal "https://example.org/form" (getf e :url)))
        (is (typep (nth-value 1 (ignore-errors
                                 (mcp:answer-task-input client task "k1" :accept
                                                        :content (%obj "name" "x"))))
                   'error)
            "content for a url request is refused")
        (is (null (fake-updates fake)) "and nothing was sent")
        (is-true (mcp:answer-task-input client task "k1" :accept))
        (is (null (gethash "content" (gethash "k1" (cdr (first (fake-updates fake)))))))))))

(test answering-does-not-change-the-stored-task
  "Copilot's review of #627: the memory store's copies of a task share their input entries, so
answering must not change an entry in place. The stored record keeps the key as shown and not
answered; the server dropping the key is what ends it."
  (let ((fake (make-fake :tools (%tools '("long" :do :task))
                         :task-script '((:elicit ("k1" :form)))))
        (events '()))
    (with-fake (client fake :tasks t :elicitation '(:form))
      (mcp:call-tool client (first (mcp:list-tools client)) (%obj))
      (evt:with-observer ((lambda (e) (push e events)))
        (%poll-when-due client))
      (mcp:answer-task-input client (getf (find :task-input-required events :key #'evt:event-type) :task)
                             "k1" :decline)
      (is (equal '(nil) (mapcar #'third (mcp:task-inputs (%only-task client))))
          "the stored record is as the poll saved it: ~S" (mcp:task-inputs (%only-task client))))))
