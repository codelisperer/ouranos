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
  (fail-next nil) (endless nil) (initialize-status nil) (bad-tools nil)
  (sessions '()) (end-session nil) (calls 0) (initializes 0)
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

(defun %result (fake method params)
  "The result for METHOD, or (:ERROR code text), or (:STATUS n)."
  (cond
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
