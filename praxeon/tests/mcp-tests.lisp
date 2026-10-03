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
                           require-token (legacy-version "2025-11-25"))))
  "What the test server does. ERA is :MODERN, :LEGACY or :DUAL. REPLY is :JSON or :SSE (an
event stream with a notification before the reply). TOOLS is a list of (NAME . PLIST): the
plist's :SCHEMA is the inputSchema, and :DO is :ECHO, :FAIL, :SLOW, :STATUS-500, :INPUT or
:STRUCTURED. REQUIRE-TOKEN is NIL or the bearer token every request must carry."
  era reply page-size tools require-token legacy-version
  (reject-headers nil)
  (sessions '()) (end-session nil) (calls 0) (initializes 0)
  (lock (sb-thread:make-mutex)))

(defun %obj (&rest kv)
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on kv by #'cddr do (setf (gethash k h) v))
    h))

(defun %reply (stream fake status message &key headers)
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
        "inputSchema" (or (getf plist :schema) (%obj "type" "object"))))

(defun %result (fake method params)
  "The result for METHOD, or (:ERROR code text), or (:STATUS n)."
  (cond
    ((string= method "tools/list")
     (let* ((all (fake-tools fake))
            (start (let ((c (gethash "cursor" params))) (if (stringp c) (parse-integer c) 0)))
            (end (min (length all) (+ start (fake-page-size fake))))
            (page (subseq all start end)))
       (%obj "tools" (map 'vector (lambda (e) (%tool-json (car e) (cdr e))) page)
             "nextCursor" (if (< end (length all)) (princ-to-string end) 'null))))
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
         (:slow (sleep 3) (%obj "content" #()))
         (:status-500 (list :status 500))
         (:input (%obj "resultType" "input_required" "inputRequests" (%obj)))
         (t (list :error -32602 "unknown tool")))))
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
             (equal (th:request-header request "Mcp-Name") (gethash "name" params))))))

(defun %serve (fake)
  (lambda (request stream)
    (let* ((message (ignore-errors (jzon:parse (th:request-body-string request))))
           (id (and (hash-table-p message) (gethash "id" message)))
           (method (and (hash-table-p message) (gethash "method" message)))
           (params (or (and (hash-table-p message) (gethash "params" message)) (%obj)))
           (auth (th:request-header request "Authorization")))
      (flet ((answer (result)
               (cond ((and (consp result) (eq (first result) :status))
                      (th:write-response stream (second result) '() "server error"))
                     ((consp result)
                      (%reply stream fake 200 (%error-message id (second result) (third result))))
                     (t (%reply stream fake 200 (%obj "jsonrpc" "2.0" "id" id "result" result))))))
        (cond
          ((and (fake-require-token fake)
                (not (equal auth (format nil "Bearer ~A" (fake-require-token fake)))))
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
