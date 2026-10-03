;;;; client.lisp --- connections, the two protocol eras, tools, and granting them to agents

(cl:in-package #:praxeon/mcp)

(defparameter +protocol-version+ "2026-07-28"
  "The revision of the MCP specification this client targets, read at modelcontextprotocol.io
on 2026-10-03. Requests in this revision carry their version and the client's identity in
`_meta', with no handshake.")

(defparameter +legacy-protocol-versions+ '("2025-11-25" "2025-06-18" "2025-03-26")
  "The earlier revisions this client speaks when a server does not understand the current one.
They open a session with `initialize'. The first is the one the client offers.")

(defparameter +modern-error-codes+ '(-32020 -32021 -32022)
  "The JSON-RPC error codes the 2026-07-28 revision defines: HeaderMismatch,
MissingRequiredClientCapability and UnsupportedProtocolVersion. A 400 carrying one of these
comes from a server that speaks the current revision.")

(defparameter *client-name* "praxeon"
  "The name this client gives servers in clientInfo.")

(defparameter *client-version* "0.1"
  "The version this client gives servers in clientInfo.")

(defparameter *max-description-characters* 2000
  "The most characters of a tool's description that are registered with a means. A server's
description is untrusted and reaches the model on every turn, so its length is bounded.")

;;; --- conditions ------------------------------------------------------------------------

(define-condition mcp-error (error) ()
  (:documentation "The root of the errors praxeon/mcp signals that are not reported to the
model as a tool's error."))

(define-condition request-failed (cnd:tool-error-result)
  ((connection :initarg :connection :reader request-failed-connection)
   (code :initarg :code :initform nil :reader request-failed-code))
  (:documentation "A request to an MCP server failed: it timed out, the connection failed, or
the server answered with a JSON-RPC error (CODE) or an HTTP status it should not have. Inside a
turn the model is told TEXT, which names the connection and the code and never repeats what
the server said, and the turn goes on."))

(define-condition tool-error (cnd:tool-error-result)
  ((connection :initarg :connection :reader tool-error-connection)
   (tool :initarg :tool :reader tool-error-tool))
  (:documentation "A tool answered with a result whose isError is set. TEXT is the result's
text, which the model sees as an error result so that it can try again."))

(define-condition authorization-required (condition)
  ((connection :initarg :connection :reader authorization-required-connection)
   (principal :initarg :principal :reader authorization-required-principal)
   (challenge :initarg :challenge :initform nil :reader authorization-required-challenge))
  (:documentation "Signalled, with SIGNAL, when a call needs a user to sign in: the server
answered 401, or a connection whose tokens are per user was called with no principal.
CHALLENGE is the 401's WWW-Authenticate value, when there was one.

Not an error, so ACT's handler does not catch it and an app's HANDLER-BIND around RUN-TURN
sees it. An app handler can record it, or leave the turn. When nothing leaves, the call fails
with SIGN-IN-NEEDED."))

(define-condition sign-in-needed (cnd:tool-error-result)
  ((connection :initarg :connection :reader sign-in-needed-connection))
  (:documentation "The call failed because a user has to sign in to the connection first. The
model's text names the connection and asks it to tell the user; it carries no URL."))

(define-condition %current-revision-after-all (error) ()
  (:documentation "Internal: the legacy handshake was answered with a current-revision error, so
the server speaks the current revision and the legacy fallback was wrong."))

(define-condition tool-name-conflict (mcp-error)
  ((names :initarg :names :reader tool-name-conflict-names))
  (:report (lambda (c s)
             (format s "praxeon/mcp: these means names are already taken or repeated: ~{~A~^, ~}"
                     (tool-name-conflict-names c))))
  (:documentation "GRANT-TOOLS would have registered a means under a name the agent already
has, or two tools under one name. Nothing was registered."))

;;; --- connections and clients -----------------------------------------------------------

(defstruct (connection (:constructor make-connection
                           (&key name url token-source per-user (timeout 30) (call-timeout 120)
                                 (max-body-bytes (* 8 1024 1024)))))
  "An MCP server the app connects to, as data.

NAME is a short identifier: it prefixes the tool names an agent sees, and it appears in logs.
URL is the server's MCP endpoint. TOKEN-SOURCE is NIL, or a function of (CONNECTION PRINCIPAL)
returning a bearer token string or NIL. PER-USER is true when the token belongs to a user: a
call with no principal is then refused before anything is sent. TIMEOUT is the most seconds a
request may take, and CALL-TIMEOUT the most a tool call may take. MAX-BODY-BYTES bounds a
reply."
  (name "" :type string)
  (url "" :type string)
  (token-source nil)
  (per-user nil)
  (timeout 30)
  (call-timeout 120)
  (max-body-bytes (* 8 1024 1024)))

(defstruct (client (:constructor %make-client (connection)))
  "One connection's protocol state. ERA is NIL until the first request finds out, then :MODERN
or :LEGACY. PROTOCOL-VERSION is the version in use. SESSIONS maps a principal to its legacy
session: (SESSION-ID . VERSION)."
  connection
  (era nil)
  (protocol-version nil)
  (sessions (make-hash-table :test #'equal))
  (lock (sb-thread:make-mutex :name "praxeon/mcp client"))
  (next-id 0 :type sb-ext:word)
  ;; Requests given up at their deadline whose threads are still running (%SEND-WITHIN).
  (abandoned 0 :type sb-ext:word))

(defun make-client (connection)
  "A client for CONNECTION. It sends nothing until it is first used."
  (check-type connection connection)
  (%make-client connection))

;;; --- one HTTP exchange -----------------------------------------------------------------

(defun %next-id (client)
  (sb-ext:atomic-incf (client-next-id client)))

(defvar *call-may-run* nil
  "True while a tools/call is in flight. A failure then may have come after the tool ran, so
the model is told the outcome is unknown, and nothing retries the call (#527).")

(defun %request-failed (client control arguments &key code (outcome :error))
  "Fail the request with REQUEST-FAILED, telling the model CONTROL formatted with ARGUMENTS."
  (let ((name (connection-name (client-connection client))))
    (log:info "praxeon/mcp: request failed" :connection name :code code :outcome outcome)
    (error 'request-failed
           :connection name :code code :outcome outcome
           :text (format nil "The MCP connection ~A failed: ~?" name control arguments))))

(defvar *in-flight-method* nil
  "The method of the POST being sent or read, so that only a failure of the tools/call POST
itself, not of a handshake before it, counts as a tool that may have run.")

(defun %failed-in-flight (client control arguments)
  "Fail a request that may have reached the server. For a tool call this means the tool may
have run, so the model is told the outcome is unknown and is asked not to call it again before
checking with the user."
  (if (and *call-may-run* (equal *in-flight-method* "tools/call"))
      (%request-failed client "~?~%The tool may have run; its outcome is unknown. Do not call it again before checking with the user."
                       (list control arguments) :outcome :unknown)
      (%request-failed client control arguments)))

(defun %require-sign-in (client principal challenge)
  "Let the app know that PRINCIPAL must sign in, then fail the call."
  (let ((name (connection-name (client-connection client))))
    (signal 'authorization-required :connection name :principal principal :challenge challenge)
    (evt:emit :sign-in-required :connection name :principal principal)
    (log:info "praxeon/mcp: sign-in required" :connection name)
    (error 'sign-in-needed
           :connection name :outcome :not-run
           :text (format nil "The connection ~A needs the user to sign in before this tool can be used. Ask the user to sign in."
                         name))))

(defun %token (client principal)
  (let* ((connection (client-connection client))
         (source (connection-token-source connection)))
    (when (and (connection-per-user connection) (null principal))
      (%require-sign-in client nil nil))
    (and source (funcall source connection principal))))

(defun %post (client body headers principal timeout)
  "POST BODY, a JSON-RPC message as a hash table, with HEADERS and the token for PRINCIPAL.
Returns the response. A failed connection or a timeout fails the call."
  (let* ((connection (client-connection client))
         (token (%token client principal))
         (method (setf *in-flight-method* (gethash "method" body)))
         (request (http:make-request
                   :method :post :url (connection-url connection)
                   :headers (append (list (cons "Content-Type" "application/json")
                                          (cons "Accept" "application/json, text/event-stream"))
                                    (when token (list (cons "Authorization"
                                                            (format nil "Bearer ~A" token))))
                                    headers)
                   :content (jzon:stringify body)
                   :connect-timeout (min timeout 10)
                   :read-timeout timeout
                   ;; A request that carries a token is never forwarded to another host.
                   :follow-redirects nil
                   :max-body-bytes (connection-max-body-bytes connection))))
    (handler-case (%send-within client request (1+ timeout) method)
      (http:response-too-large ()
        (%failed-in-flight client "its reply was larger than ~D bytes."
                           (list (connection-max-body-bytes connection))))
      (http:http-error ()
        (%failed-in-flight client "it did not answer within ~D seconds, or the connection failed."
                           (list (1+ timeout)))))))

(defparameter *max-abandoned-requests* 8
  "The most requests on one client that may be given up at their deadline and still be running.
Past it, the client refuses new requests until some of them finish, so a server that keeps
streaming past every timeout cannot make the client hold one thread per call without bound.")

(defun %send-within (client request seconds method)
  "Send REQUEST and return its response, or signal HTTP-ERROR when it has not finished within
SECONDS.

The transport's own read timeout is not relied on alone. On Windows, dexador's WinHTTP
backend let a request to a server that answered after 3 seconds succeed under a 1-second read
timeout (#530's Windows leg, #537), and on every platform a server that sends a keep-alive line
every so often keeps a read timeout from firing. The request runs on its own thread, and this
gives up on it at the deadline.

A request given up this way keeps running on its thread, with its connection open, until the
server finishes or the transport ends it. Nothing sends it again. CLIENT counts such threads,
each one logs when it finishes, and past *MAX-ABANDONED-REQUESTS* still running the client
refuses new requests.

The thread sees the global values of special variables, not the caller's bindings. That holds
for aion/http-client, which reads none, but dexador's own variables, such as
DEX:*DEFAULT-PROXY*, apply here only when they are set globally."
  (let ((name (connection-name (client-connection client))))
    (when (>= (client-abandoned client) *max-abandoned-requests*)
      (%request-failed client "~D earlier requests to it are still running after their deadline, so no new request was sent."
                       (list (client-abandoned client)) :outcome :not-run))
    (let* ((none '#:none)
           (state (list :waiting))
           (started (get-internal-real-time))
           (thread (sb-thread:make-thread
                    ;; THREAD-LIFETIME: independent -- it performs the request and returns the
                    ;; outcome as a value; it reads no binding of the caller's (see above).
                    (lambda ()
                      (let ((outcome (handler-case (list :ok (http:send-request request '()))
                                       (error (e) (list :error e)))))
                        (unless (eq :waiting (sb-ext:compare-and-swap (car state) :waiting :done))
                          ;; Given up at the deadline: this thread is the only one left to say
                          ;; how the request ended.
                          (sb-ext:atomic-decf (client-abandoned client))
                          (log:info "praxeon/mcp: a request given up at its deadline finished"
                                    :connection name :method method
                                    :status (if (eq (first outcome) :ok)
                                                (http:response-status (second outcome))
                                                :failed)
                                    :ms (round (* 1000 (- (get-internal-real-time) started))
                                               internal-time-units-per-second)))
                        outcome))
                    :name "praxeon/mcp request"))
           (outcome (sb-thread:join-thread thread :timeout seconds :default none)))
      ;; Counted before the mark, and the count taken back when the mark fails, so the
      ;; thread's decrement can never come before this increment.
      (when (eq outcome none) (sb-ext:atomic-incf (client-abandoned client)))
      (cond ((and (eq outcome none)
                  (eq :waiting (sb-ext:compare-and-swap (car state) :waiting :abandoned)))
             (log:warn "praxeon/mcp: request given up at its deadline"
                       :connection name :method method :seconds seconds)
             (error 'http:http-error :detail "the request did not finish before its deadline"))
            ((eq outcome none)
             ;; It finished in the moment between the deadline and the mark.
             (sb-ext:atomic-decf (client-abandoned client))
             (let ((late (sb-thread:join-thread thread :default none)))
               (if (eq (first late) :ok) (second late) (error (second late)))))
            ((eq (first outcome) :ok) (second outcome))
            (t (error (second outcome)))))))

(defun %messages (client response)
  "The JSON-RPC messages in RESPONSE: one for a JSON reply, each event's for an event stream."
  (let* ((type (or (http:header-value (http:response-headers response) "content-type") ""))
         (body (http:response-body response)))
    (handler-case
        (if (search "text/event-stream" type :test #'char-equal)
            (mapcar #'jzon:parse (parse-event-stream body))
            (let ((parsed (jzon:parse body)))
              (if (vectorp parsed) (coerce parsed 'list) (list parsed))))
      (error ()
        (%failed-in-flight client "its reply was not JSON-RPC." '())))))

(defun %reply-for (client response id)
  "The JSON-RPC reply to the request ID in RESPONSE. Notifications sent before it are counted
in the log and dropped. A 4xx reply's error may carry no id, because the server rejected the
request before reading it; it is the reply all the same, and the request was not processed."
  (let* ((client-error-p (<= 400 (http:response-status response) 499))
         (messages (if client-error-p
                       (or (ignore-errors (%messages client response))
                           (%request-failed client "it answered with HTTP status ~D."
                                            (list (http:response-status response))
                                            :outcome :not-run))
                       (%messages client response)))
         (reply (or (find-if (lambda (m) (and (hash-table-p m) (equal id (gethash "id" m))
                                              (or (nth-value 1 (gethash "result" m))
                                                  (nth-value 1 (gethash "error" m)))))
                             messages)
                    (and client-error-p
                         (find-if (lambda (m) (and (hash-table-p m)
                                                   (nth-value 1 (gethash "error" m))))
                                  messages)))))
    (when (> (length messages) 1)
      (log:info "praxeon/mcp: messages before the reply"
                :connection (connection-name (client-connection client))
                :count (1- (length messages))))
    (or reply (%failed-in-flight client "its reply ended without answering the request." '()))))

(defun %error-code (message)
  (let ((code (%get message "error" "code")))
    (and (integerp code) code)))

(defun %modern-error-p (response)
  "Whether RESPONSE's body is a JSON-RPC error that only a server speaking the current
revision sends: one of +MODERN-ERROR-CODES+, or a 404 with -32601 (Method not found), which the
current revision uses to tell an unknown method apart from a server without the endpoint."
  (let ((message (ignore-errors (jzon:parse (http:response-body response)))))
    (and (hash-table-p message)
         (let ((code (%error-code message)))
           (or (member code +modern-error-codes+)
               (and (eql code -32601) (= 404 (http:response-status response))))))))

;;; --- the current revision: no handshake ------------------------------------------------

(defun %meta ()
  (%object "io.modelcontextprotocol/protocolVersion" +protocol-version+
           "io.modelcontextprotocol/clientInfo" (%object "name" *client-name*
                                                         "version" *client-version*)
           "io.modelcontextprotocol/clientCapabilities" (%object)))

(defun %modern-request (client method params principal timeout extra-headers)
  "Send METHOD in the 2026-07-28 form. Returns the response and the request's id."
  (let* ((id (%next-id client))
         (params (or params (%object)))
         (name (or (gethash "name" params) (gethash "uri" params))))
    (setf (gethash "_meta" params) (%meta))
    (values (%post client (%object "jsonrpc" "2.0" "id" id "method" method "params" params)
                   (append (list (cons "MCP-Protocol-Version" +protocol-version+)
                                 (cons "Mcp-Method" method))
                           (when (and name (member method '("tools/call" "resources/read"
                                                            "prompts/get")
                                                   :test #'string=))
                             (list (cons "Mcp-Name" (encode-header-value name))))
                           extra-headers)
                   principal timeout)
            id)))

;;; --- the legacy revisions: initialize and a session ------------------------------------

(defun %session-headers (session)
  (destructuring-bind (session-id . version) session
    (append (when session-id (list (cons "Mcp-Session-Id" session-id)))
            ;; 2025-03-26 defined no version header.
            (unless (string= version "2025-03-26")
              (list (cons "MCP-Protocol-Version" version))))))

(defun %open-session (client principal)
  "Send `initialize' and `notifications/initialized' for PRINCIPAL, and return the session."
  (let* ((connection (client-connection client))
         (id (%next-id client))
         (response (%post client
                          (%object "jsonrpc" "2.0" "id" id "method" "initialize"
                                   "params" (%object "protocolVersion"
                                                     (first +legacy-protocol-versions+)
                                                     "capabilities" (%object)
                                                     "clientInfo" (%object "name" *client-name*
                                                                           "version" *client-version*)))
                          '() principal (connection-timeout connection))))
    (when (%modern-error-p response)
      (error '%current-revision-after-all))
    (%check-status client response principal)
    (let* ((reply (%reply-for client response id))
           (version (%get reply "result" "protocolVersion")))
      (when (member (%error-code reply) +modern-error-codes+)
        (error '%current-revision-after-all))
      (when (gethash "error" reply)
        (%request-failed client "it refused to start a session (code ~A)."
                         (list (%error-code reply)) :code (%error-code reply)))
      (unless (member version +legacy-protocol-versions+ :test #'equal)
        (%request-failed client "it offered protocol version ~A, which this client does not speak."
                         (list version)))
      (let ((session (cons (http:header-value (http:response-headers response) "mcp-session-id")
                           version)))
        (%post client (%object "jsonrpc" "2.0" "method" "notifications/initialized")
               (%session-headers session) principal (connection-timeout connection))
        (sb-thread:with-mutex ((client-lock client))
          (setf (gethash principal (client-sessions client)) session
                (client-protocol-version client) version))
        (log:info "praxeon/mcp: session opened" :connection (connection-name connection)
                                                :version version)
        session))))

(defun %legacy-request (client method params principal timeout &optional retried)
  (let* ((session (or (sb-thread:with-mutex ((client-lock client))
                        (gethash principal (client-sessions client)))
                      (%open-session client principal)))
         (id (%next-id client))
         (response (%post client (%object "jsonrpc" "2.0" "id" id "method" method
                                          "params" (or params (%object)))
                          (%session-headers session) principal timeout)))
    (if (and (= 404 (http:response-status response)) (car session) (not retried))
        ;; The server ended the session. Start another and try once more.
        (progn
          (sb-thread:with-mutex ((client-lock client))
            (remhash principal (client-sessions client)))
          (%legacy-request client method params principal timeout t))
        (values response id))))

;;; --- one request, in whichever era the server speaks -----------------------------------

(defun %check-status (client response principal)
  "Fail the call for a status that carries no JSON-RPC reply. A 401 means the user must sign
in."
  (let ((status (http:response-status response)))
    (cond ((member status '(401 403))
           ;; 403 is a token without enough scope. Neither says anything about the era.
           (%require-sign-in client principal
                             (http:header-value (http:response-headers response)
                                                "www-authenticate")))
          ((or (<= 200 status 299) (member status '(400 404 405))))
          ((<= 500 status 599)
           (%failed-in-flight client "it answered with HTTP status ~D." (list status)))
          (t (%request-failed client "it answered with HTTP status ~D." (list status))))))

(defun %legacy-signal-p (response)
  "Whether RESPONSE says the server does not understand a current-revision request: a 400, 404
or 405 whose body is not one of the current revision's JSON-RPC errors (2026-07-28,
\"Versioning\" and \"Streamable HTTP\", Backward Compatibility)."
  (and (member (http:response-status response) '(400 404 405))
       (not (%modern-error-p response))))

(defun %send (client method params principal timeout extra-headers &optional reprobed)
  "Send METHOD in the era CLIENT's server speaks, finding it out when it is not known yet, and
return the response and the request's id.

Each fallback and retry here happens only on a reply that shows the request was not processed:
a current-revision request a legacy server could not read, a legacy request a current server
answered with a current-revision error, or the legacy 404 for an ended session. A request that
may have been processed is never sent twice."
  (flet ((probe ()
           (multiple-value-bind (response id)
               (%modern-request client method (and params (%copy params)) principal timeout
                                extra-headers)
             (cond ((%legacy-signal-p response)
                    ;; The era is set only once the legacy request has gone through. A server
                    ;; on the current revision that answered this one request badly, through
                    ;; a proxy's 404 or a header it would not take, answers the legacy
                    ;; handshake with a current-revision error: this request then fails as not
                    ;; run, and the next one probes again.
                    (handler-case
                        (multiple-value-prog1
                            (%legacy-request client method params principal timeout)
                          (setf (client-era client) :legacy)
                          (log:info "praxeon/mcp: legacy server"
                                    :connection (connection-name (client-connection client))))
                      (%current-revision-after-all ()
                        (values response id))))
                   ((member (http:response-status response) '(401 403))
                    ;; Says nothing about the era; the next request probes again.
                    (values response id))
                   (t
                    (setf (client-era client) :modern
                          (client-protocol-version client) +protocol-version+)
                    (values response id))))))
    (ecase (client-era client)
      ((nil) (probe))
      (:modern
       (multiple-value-bind (response id)
           (%modern-request client method (and params (%copy params)) principal timeout
                            extra-headers)
         (if (and (not reprobed) (%legacy-signal-p response))
             ;; The server stopped understanding the current revision: find out again.
             (progn (setf (client-era client) nil)
                    (%send client method params principal timeout extra-headers t))
             (values response id))))
      (:legacy
       (multiple-value-bind (response id)
           (handler-case (%legacy-request client method params principal timeout)
             (%current-revision-after-all ()
               ;; The server moved to the current revision: find out again, once.
               (setf (client-era client) nil)
               (if reprobed
                   (%request-failed client "it answered the legacy handshake with a current-revision error." '()
                                    :outcome :not-run)
                   (return-from %send
                     (%send client method params principal timeout extra-headers t)))))
         (if (and (not reprobed) (= 400 (http:response-status response))
                  (%modern-error-p response))
             ;; The server now speaks the current revision and rejected the legacy form.
             (progn (setf (client-era client) nil)
                    (sb-thread:with-mutex ((client-lock client))
                      (clrhash (client-sessions client)))
                    (%send client method params principal timeout extra-headers t))
             (values response id)))))))

(defun %request (client method params &key principal timeout extra-headers)
  "Send METHOD with PARAMS for PRINCIPAL and return the result object."
  (let* ((*in-flight-method* nil)
         (connection (client-connection client))
         (timeout (or timeout (connection-timeout connection)))
         (started (get-internal-real-time)))
    (multiple-value-bind (response id)
        (%send client method params principal timeout extra-headers)
      (%check-status client response principal)
      (let ((reply (%reply-for client response id)))
        (log:info "praxeon/mcp: request" :connection (connection-name connection)
                                         :method method
                                         :status (http:response-status response)
                                         :ms (round (* 1000 (- (get-internal-real-time) started))
                                                    internal-time-units-per-second))
        (when (nth-value 1 (gethash "error" reply))
          (let ((code (%error-code reply)))
            (case code
              (-32022
               (%request-failed client "it does not support protocol version ~A; it supports ~{~A~^, ~}."
                                (list +protocol-version+
                                      (coerce (or (%get reply "error" "data" "supported") #())
                                              'list))
                                :code code :outcome :not-run))
              (-32020
               ;; The specification says a client SHOULD list the tools again and retry. This
               ;; client does not: a new listing could change the tool's schema without the app
               ;; granting it again. The call fails, and the app calls REVOKE-TOOLS and GRANT-TOOLS again.
               (%request-failed client "it rejected the request's headers (HeaderMismatch). The tool's definition may have changed on the server; it has to be granted again."
                                '() :code code :outcome :not-run))
              (t
               (%request-failed client "it answered ~A with an error (code ~A)."
                                (list method code) :code code)))))
        (let ((result (gethash "result" reply)))
          (unless (hash-table-p result)
            (%failed-in-flight client "its result was not a JSON object." '()))
          (when (equal "input_required" (%get result "resultType"))
            (%request-failed client "the tool asked for input this client cannot provide."
                             '() :outcome :not-run))
          result)))))

(defun %copy (table)
  (let ((copy (make-hash-table :test #'equal)))
    (maphash (lambda (k v) (setf (gethash k copy) v)) table)
    copy))

;;; --- tools -----------------------------------------------------------------------------

(defstruct (tool (:constructor %make-tool))
  "A tool a server offers. HEADER-PATHS are its x-mcp-header annotations."
  (name "" :type string)
  (title nil)
  (description nil)
  (input-schema nil)
  (annotations nil)
  (header-paths '()))

(defparameter *max-schema-characters* 20000
  "The most characters a tool's inputSchema may take as JSON. The schema is sent to the model
provider with every request, like the description, so its size is bounded too.")

(defun %clip-name (value)
  (let ((s (princ-to-string value))) (subseq s 0 (min 100 (length s)))))

(defun %schema-problem (schema)
  "Why SCHEMA, a tool's inputSchema, cannot be passed to a model provider, or NIL. Providers take
a JSON Schema object, and MCP requires one whose type is \"object\"."
  (cond ((not (and (hash-table-p schema) (equal "object" (gethash "type" schema))))
         "its inputSchema is not an object schema")
        ((> (length (jzon:stringify schema)) *max-schema-characters*)
         "its inputSchema is too large")))

(defun %tool-from-json (object)
  (let ((paths (x-mcp-header-paths (gethash "inputSchema" object)))
        (problem (%schema-problem (gethash "inputSchema" object))))
    (cond
      (problem
       (log:warn "praxeon/mcp: tool dropped" :tool (%clip-name (gethash "name" object))
                                             :reason problem)
       nil)
      ((eq paths :invalid)
       (log:warn "praxeon/mcp: tool dropped, invalid x-mcp-header"
                 :tool (%clip-name (gethash "name" object)))
       nil)
      (t
        (let ((name (gethash "name" object)))
          (and (stringp name)
               (%make-tool :name name
                           :title (let ((v (gethash "title" object))) (and (stringp v) v))
                           :description (let ((v (gethash "description" object)))
                                          (and (stringp v) v))
                           :input-schema (gethash "inputSchema" object)
                           :annotations (gethash "annotations" object)
                           :header-paths paths)))))))

(defparameter *max-list-pages* 1000
  "The most pages LIST-TOOLS reads before it decides the listing does not end.")

(defun list-tools (client &key principal)
  "The tools CLIENT's server offers, following each page's nextCursor. Gives them to no agent.
A tool whose x-mcp-header annotation is invalid is left out, as the specification requires."
  (let ((tools '()) (cursor nil) (pages 0))
    (loop
      (let* ((result (%request client "tools/list"
                               (if cursor (%object "cursor" cursor) (%object))
                               :principal principal))
             (page (gethash "tools" result)))
        (incf pages)
        (when (vectorp page)
          (loop for object across page
                for tool = (and (hash-table-p object) (%tool-from-json object))
                when tool do (push tool tools)))
        (setf cursor (gethash "nextCursor" result))
        (when (or (not (stringp cursor)) (zerop (length cursor)))
          (return))
        (when (>= pages *max-list-pages*)
          ;; A partial listing would let `:only :all' grant part of the server's tools without
          ;; saying so.
          (%request-failed client "its tool listing went past ~D pages without ending." (list pages)
                           :outcome :not-run))))
    (log:info "praxeon/mcp: tools listed"
              :connection (connection-name (client-connection client))
              :count (length tools) :pages pages)
    (nreverse tools)))

(defun %content-text (block)
  "BLOCK, one content block of a tool result, as text for the model. Binary data is described,
never included."
  (let ((type (gethash "type" block)))
    (cond ((equal type "text") (or (gethash "text" block) ""))
          ((member type '("image" "audio") :test #'equal)
           (format nil "[~A omitted: ~A, ~D characters of base64]" type
                   (or (gethash "mimeType" block) "unknown type")
                   (length (or (gethash "data" block) ""))))
          ((equal type "resource_link")
           (format nil "[resource ~A~@[: ~A~]]" (gethash "uri" block) (gethash "name" block)))
          ((equal type "resource")
           (let ((resource (gethash "resource" block)))
             (if (stringp (%get resource "text"))
                 (%get resource "text")
                 (format nil "[resource ~A omitted: binary]" (%get resource "uri")))))
          (t (format nil "[content of type ~A omitted]" type)))))

(defun result-text (result)
  "The text the model gets for RESULT, a tools/call result."
  (let* ((content (gethash "content" result))
         (texts (and (vectorp content)
                     (loop for block across content
                           when (hash-table-p block) collect (%content-text block)))))
    (cond (texts (format nil "~{~A~^~%~%~}" texts))
          ((nth-value 1 (gethash "structuredContent" result))
           (jzon:stringify (gethash "structuredContent" result)))
          (t ""))))

(defun call-tool (client tool arguments &key principal)
  "Call TOOL, a TOOL from LIST-TOOLS, with ARGUMENTS (a hash table, or NIL), for PRINCIPAL.
Returns the result's text. A result with isError set signals TOOL-ERROR; a failed request
signals REQUEST-FAILED; both are TOOL-ERROR-RESULTs, which a turn reports to the model."
  (let* ((connection (client-connection client))
         (arguments (if (hash-table-p arguments) arguments (%object)))
         (headers (handler-case (header-params (tool-header-paths tool) arguments)
                    (header-value-refused (e)
                      (%request-failed client "the argument for one of the tool's header parameters is ~A, so the call was not sent."
                                       (list (header-value-refused-reason e)) :outcome :not-run))))
         (result (let ((*call-may-run* t))
                   (%request client "tools/call"
                             (%object "name" (tool-name tool) "arguments" arguments)
                             :principal principal
                             :timeout (connection-call-timeout connection)
                             :extra-headers headers)))
         (text (result-text result)))
    (when (eq t (gethash "isError" result))
      (log:info "praxeon/mcp: tool reported an error" :connection (connection-name connection)
                                                       :tool (tool-name tool))
      (error 'tool-error :connection (connection-name connection) :tool (tool-name tool)
                         :text text))
    text))

;;; --- granting tools to agents ----------------------------------------------------------

(defun means-name (connection tool-name)
  "The means name under which TOOL-NAME from CONNECTION is registered: the connection's name,
two underscores, and the tool's name, with any character outside A-Z, a-z, 0-9, _ and -
replaced by _, cut to 64 characters, which every supported provider accepts."
  (let ((name (map 'string (lambda (c) (if (or (alphanumericp c) (find c "_-"))
                                           (if (< (char-code c) 128) c #\_)
                                           #\_))
                   (format nil "~A__~A" (connection-name connection) tool-name))))
    (subseq name 0 (min 64 (length name)))))

(defun %clip (string limit)
  (if (> (length string) limit) (subseq string 0 limit) string))

(defun grant-tools (agent client &key tools (only (error "grant-tools: :only is required: a list of tool names, or :all")) capability)
  "Register the tools of CLIENT's server that the app chooses as means of AGENT, and return the
means names.

TOOLS is a list from LIST-TOOLS; when it is NIL the server is asked, with no principal. ONLY is
required: a list of the server's tool names to grant, or :ALL. There is no default that grants
every tool, so a grant is always a decision the app wrote down. CAPABILITY is passed to
REGISTER-MEANS, so a caller without it does not see the tools.

Each means calls its tool for the principal of the turn it runs in, ACTOR:*PRINCIPAL*. A name
that clashes with a means AGENT already has, or with another tool in the grant, signals
TOOL-NAME-CONFLICT and registers nothing. Nothing a server sends later changes the grant."
  (let* ((connection (client-connection client))
         (tools (or tools (list-tools client)))
         (chosen (if (eq only :all)
                     tools
                     (remove-if-not (lambda (tool) (member (tool-name tool) only :test #'string=))
                                    tools)))
         (names (mapcar (lambda (tool) (means-name connection (tool-name tool))) chosen))
         (taken (remove-duplicates
                 (append (remove-if-not (lambda (n) (nth-value 1 (gethash n (actor:agent-means agent))))
                                        names)
                         (loop for (n . rest) on names when (member n rest :test #'string=)
                               collect n))
                 :test #'string=)))
    (when taken (error 'tool-name-conflict :names taken))
    (loop for tool in chosen
          for name in names
          do (let ((tool tool))
               (actor:register-means
                agent name
                (%clip (or (tool-description tool) (tool-title tool) (tool-name tool))
                       *max-description-characters*)
                (lambda (arguments)
                  (call-tool client tool arguments :principal actor:*principal*))
                :schema (tool-input-schema tool)
                :capability capability
                :source (list :connection (connection-name connection)
                              :tool (tool-name tool)
                              :per-user (and (connection-per-user connection) t)))))
    (log:info "praxeon/mcp: tools granted" :connection (connection-name connection)
                                           :count (length names))
    names))

(defun revoke-tools (agent client)
  "Remove every means GRANT-TOOLS registered on AGENT for CLIENT's connection, found by the
connection named in each means' :SOURCE, and return how many were removed. A means the app
registered itself, whatever its name, is left alone."
  (let ((name (connection-name (client-connection client)))
        (removed '()))
    (maphash (lambda (means entry)
               (when (equal name (getf (actor:means-entry-source entry) :connection))
                 (push means removed)))
             (actor:agent-means agent))
    (dolist (means removed) (remhash means (actor:agent-means agent)))
    (length removed)))
