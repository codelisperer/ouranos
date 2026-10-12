;;;; stdio.lisp --- local MCP servers over stdio (#527, part 5)
;;;;
;;;; A connection made with :COMMAND is a server this process starts as a child and talks to
;;;; over the child's stdin and stdout, one JSON-RPC message per line (2026-07-28, "stdio").
;;;; %REQUEST hands such a connection's requests to %STDIO-REQUEST, and everything above it
;;;; (tools, resources, prompts, tasks) is shared with Streamable HTTP.

(cl:in-package #:praxeon/mcp)

(defparameter +restart-limit+ 3
  "How many times a local server is started again after exiting, in any +RESTART-WINDOW+
seconds, before requests fail instead.")

(defparameter +restart-window+ 60
  "The seconds over which +RESTART-LIMIT+ counts restarts.")

(defparameter *stdio-close-seconds* 5
  "How long CLOSE-CLIENT waits for a local server to exit after its stdin is closed, before it
sends SIGTERM.")

(defparameter *stdio-term-seconds* 2
  "How long CLOSE-CLIENT waits after SIGTERM before it sends SIGKILL.")

(defvar *live-clients* (make-hash-table :test #'eq :synchronized t)
  "The clients whose local server may be running, so that the image's exit ends them. A client
is here from its server's first start until CLOSE-CLIENT, so one the app drops without closing
it is not collected.")

(defconstant +sigterm+ 15)
(defconstant +sigkill+ 9)

;;; --- one child process ------------------------------------------------------------------

(defstruct (waiter (:constructor %make-waiter ()))
  "One request waiting for its reply. WRITTEN is set when the writer thread takes its line from
the queue, so a request that may have reached the server is told apart from one that cannot
have. ABANDONED is set when its caller gave up before that; the writer then skips its line.
Both are set only under the child's lock, so exactly one of them can be. REPLY is the reply, or
:EXITED when the server's output ended first."
  (written nil)
  (abandoned nil)
  (reply nil)
  (semaphore (sb-thread:make-semaphore :name "praxeon/mcp stdio reply")))

(defstruct (child (:constructor %make-child (process)))
  "A running local server. ERA is NIL until found, then :MODERN, :LEGACY, or (:UNSUPPORTED .
VERSIONS) for a server that speaks no revision this client does. EXITED is set when its
stdout ends. WAITERS maps a request id to its WAITER. QUEUE holds the lines for the writer
thread, and :CLOSE, which closes the server's stdin."
  process
  (lock (sb-thread:make-mutex :name "praxeon/mcp child"))
  (ready (sb-thread:make-waitqueue))
  (waiters (make-hash-table :test #'eql))
  (queue '())
  (era nil)
  (exited nil)
  (finished nil)
  ;; The process's streams are closed by whichever of the reader and %FINISH-CHILD is done
  ;; last, so a reader still blocked on a stdout a grandchild holds never reads from a
  ;; descriptor number that a later server's pipe has taken.
  (reader-done nil)
  (close-on-end nil)
  reader
  writer
  ;; Counted rather than logged one by one; logged when the server's output ends. A dropped
  ;; line is counted by why it was dropped: not a JSON object, longer than the limit, or a
  ;; request this client cannot answer.
  (notifications 0 :type sb-ext:word)
  (not-json 0 :type sb-ext:word)
  (too-long 0 :type sb-ext:word)
  (requests 0 :type sb-ext:word)
  (late 0 :type sb-ext:word))

(defun %child-pid (child) (sb-ext:process-pid (child-process child)))

(defun %enqueue (child item)
  (sb-thread:with-mutex ((child-lock child))
    (setf (child-queue child) (append (child-queue child) (list item)))
    (sb-thread:condition-notify (child-ready child))))

(defun %next-item (child)
  "The next item for the writer: :CLOSE, or a line and its WAITER, or a line and NIL. A
request's line is taken and marked written in one step under the lock, and a request whose
caller has given up is skipped, so a request reported as not run is never sent."
  (sb-thread:with-mutex ((child-lock child))
    (loop
      (loop until (child-queue child)
            do (sb-thread:condition-wait (child-ready child) (child-lock child)))
      (let* ((item (pop (child-queue child)))
             (waiter (and (consp item) (cdr item))))
        (cond ((null waiter) (return item))
              ((waiter-abandoned waiter))
              (t (setf (waiter-written waiter) t)
                 (return item)))))))

(defun %writer-loop (child)
  "Write each queued line to the server's stdin, until :CLOSE, which closes it, or a write
fails because the server is gone."
  (let ((in (sb-ext:process-input (child-process child))))
    (loop
      (let ((item (%next-item child)))
        (when (eq item :close)
          (ignore-errors (close in))
          (return))
        (handler-case (progn (write-string (car item) in)
                             (write-char #\Newline in)
                             (finish-output in))
          (error ()
            (ignore-errors (close in :abort t))
            (return)))))))

(defun %read-line-within (stream limit)
  "The next line of STREAM, without its newline or a carriage return before it, and :LINE; NIL
and :TOO-LONG for a line of more than LIMIT octets, which is read to its end and dropped; NIL
and :EOF at the end. The octets are counted as they arrive, as MAX-BODY-BYTES is over HTTP, and
then decoded as UTF-8, with a byte that is not UTF-8 read as `?', so a malformed sequence
cannot make a line longer than LIMIT octets look shorter (#610)."
  (let ((buffer (make-array 256 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
        (over nil))
    (flet ((line ()
             (let ((end (fill-pointer buffer)))
               (when (and (plusp end) (= (aref buffer (1- end)) 13))
                 (decf end))
               (sb-ext:octets-to-string buffer :end end
                                               :external-format '(:utf-8 :replacement #\?)))))
      (loop
        (let ((b (read-byte stream nil :eof)))
          (cond ((eq b :eof)
                 (return (cond (over (values nil :too-long))
                               ((zerop (fill-pointer buffer)) (values nil :eof))
                               (t (values (line) :line)))))
                ((= b 10)
                 (return (if over (values nil :too-long) (values (line) :line))))
                (over)
                ((>= (fill-pointer buffer) limit) (setf over t))
                (t (vector-push-extend b buffer))))))))

(defun %answer-server-request (child message)
  "A request from the server. The current revision has none, so one is dropped. A legacy
session's `ping' gets the empty result those revisions require, and any other request -32601,
because this client declares no capabilities."
  (let ((id (gethash "id" message)))
    (if (eq (child-era child) :legacy)
        (%enqueue child (cons (jzon:stringify
                               (if (equal "ping" (gethash "method" message))
                                   (%object "jsonrpc" "2.0" "id" id "result" (%object))
                                   (%object "jsonrpc" "2.0" "id" id
                                            "error" (%object "code" -32601
                                                             "message" "Method not found"))))
                              nil))
        (sb-ext:atomic-incf (child-requests child)))))

(defun %dispatch (child line)
  "Hand LINE, one message from the server, to whoever waits for it."
  (let ((message (ignore-errors (jzon:parse line))))
    (cond ((not (hash-table-p message))
           (sb-ext:atomic-incf (child-not-json child)))
          ((nth-value 1 (gethash "method" message))
           (if (nth-value 1 (gethash "id" message))
               (%answer-server-request child message)
               (sb-ext:atomic-incf (child-notifications child))))
          (t
           (let* ((id (gethash "id" message))
                  (waiter (sb-thread:with-mutex ((child-lock child))
                            (let ((w (and (integerp id) (gethash id (child-waiters child)))))
                              (when w (remhash id (child-waiters child)))
                              w))))
             (cond (waiter
                    (setf (waiter-reply waiter) message)
                    (sb-thread:signal-semaphore (waiter-semaphore waiter)))
                   (t (sb-ext:atomic-incf (child-late child)))))))))

(defun %reader-loop (name limit child)
  "Read the server's stdout until it ends, then wake every request still waiting."
  (handler-case
      (let ((out (sb-ext:process-output (child-process child))))
        (loop (multiple-value-bind (line status) (%read-line-within out limit)
                (case status
                  (:eof (return))
                  (:too-long (sb-ext:atomic-incf (child-too-long child)))
                  (t (%dispatch child line))))))
    (error () nil))
  (let ((waiting (sb-thread:with-mutex ((child-lock child))
                   (setf (child-exited child) t)
                   (prog1 (loop for w being the hash-values of (child-waiters child) collect w)
                     (clrhash (child-waiters child))))))
    (dolist (w waiting)
      (setf (waiter-reply w) :exited)
      (sb-thread:signal-semaphore (waiter-semaphore w)))
    (log:info "praxeon/mcp: local server's output ended"
              :connection name :pid (%child-pid child) :waiting (length waiting)
              :notifications (child-notifications child) :not-json (child-not-json child)
              :too-long (child-too-long child) :requests (child-requests child)
              :late (child-late child))
    (when (sb-thread:with-mutex ((child-lock child))
            (setf (child-reader-done child) t)
            (child-close-on-end child))
      (ignore-errors (sb-ext:process-close (child-process child))))))

;;; --- starting and stopping ----------------------------------------------------------------

(defun %child-environment (connection)
  "The environment a local server's process gets: +STDIO-ENVIRONMENT+ from this process, then
the connection's ENVIRONMENT, which wins for a name in both; or this process's whole
environment for :INHERIT."
  (let ((extra (connection-environment connection)))
    (if (eq extra :inherit)
        (sb-ext:posix-environ)
        (append (loop for name in +stdio-environment+
                      for value = (sb-ext:posix-getenv name)
                      ;; A value that starts with "()" is an exported bash function, which the
                      ;; SDK also leaves out.
                      when (and value
                                (not (uiop:string-prefix-p "()" value))
                                (not (find name extra :key #'car
                                                      :test #+win32 #'string-equal
                                                            #-win32 #'string=)))
                        collect (format nil "~A=~A" name value))
                (mapcar (lambda (e) (format nil "~A=~A" (car e) (cdr e))) extra)))))

(defun %spawn (client)
  "Start CLIENT's server and its reader and writer threads, and return the CHILD."
  (let* ((connection (client-connection client))
         (command (connection-command connection))
         (stderr (connection-stderr connection))
         (directory (connection-directory connection))
         (process (handler-case
                      (sb-ext:run-program (first command) (rest command)
                                          :search t :wait nil
                                          :input :stream :output :stream
                                          :error (and stderr (pathname stderr))
                                          :if-error-exists :append
                                          :directory (and directory
                                                          (uiop:native-namestring directory))
                                          :environment (%child-environment connection)
                                          ;; The reader reads octets and decodes each line
                                          ;; itself; this is for what is written to stdin.
                                          :external-format '(:utf-8 :replacement #\?))
                    (error (e)
                      ;; The condition's type only: its text can carry the command line.
                      (log:warn "praxeon/mcp: local server could not be started"
                                :connection (connection-name connection) :error (type-of e))
                      (%request-failed client "its server process could not be started." '()
                                       :outcome :not-run))))
         (child (%make-child process))
         (name (connection-name connection))
         (limit (connection-max-body-bytes connection)))
    (setf (child-reader child)
          ;; THREAD-LIFETIME: scoped -- it reads this child's stdout until the stream ends,
          ;; needs none of the caller's bindings, and %FINISH-CHILD joins it.
          (sb-thread:make-thread (lambda () (%reader-loop name limit child))
                                 :name "praxeon/mcp stdio reader")
          (child-writer child)
          ;; THREAD-LIFETIME: scoped -- it writes this child's queued lines until :CLOSE, needs
          ;; none of the caller's bindings, and %FINISH-CHILD joins it.
          (sb-thread:make-thread (lambda () (%writer-loop child))
                                 :name "praxeon/mcp stdio writer"))
    (setf (gethash client *live-clients*) t)
    (log:info "praxeon/mcp: local server started" :connection name :pid (%child-pid child))
    child))

(defun %getpgid (pid)
  #-win32 (sb-alien:alien-funcall
           (sb-alien:extern-alien "getpgid" (function sb-alien:int sb-alien:int)) pid)
  #+win32 (progn pid -1))

(defun %signal-child (child signal)
  "Send SIGNAL to CHILD's process group, or to CHILD alone when it does not lead its own group.
run-program makes the child the leader of a new group, so the group is the server and what it
started, and nothing else of this process's. On Windows the child alone is ended with
TerminateProcess, whatever SIGNAL is; a process it started can outlive it there."
  (let* ((process (child-process child))
         (pid (sb-ext:process-pid process)))
    #-win32 (ignore-errors
             (if (eql pid (%getpgid pid))
                 (sb-ext:process-kill process signal :process-group)
                 (sb-ext:process-kill process signal)))
    #+win32 (progn signal (ignore-errors (sb-ext:process-kill process +sigkill+)))))

(defun %wait-for-exit (child seconds)
  "Whether CHILD's process has exited within SECONDS."
  (loop with deadline = (+ (get-internal-real-time) (* seconds internal-time-units-per-second))
        while (sb-ext:process-alive-p (child-process child))
        do (when (> (get-internal-real-time) deadline) (return nil))
           (sleep 0.02)
        finally (return t)))

(defun %finish-child (client child)
  "Join CHILD's threads and release its process, once, after it has exited or been ended, and
log how it ended."
  (unless (child-finished child)
    (setf (child-finished child) t)
    (unless (%wait-for-exit child 2)
      ;; Its output ended but it has not exited: it is not a server any more.
      (%signal-child child +sigkill+)
      (%wait-for-exit child 2))
    (%enqueue child :close)
    (sb-thread:join-thread (child-writer child) :default nil :timeout 2)
    (sb-thread:join-thread (child-reader child) :default nil :timeout 2)
    (let ((process (child-process child)))
      (log:info "praxeon/mcp: local server ended"
                :connection (connection-name (client-connection client))
                :pid (sb-ext:process-pid process)
                :status (sb-ext:process-status process)
                :code (sb-ext:process-exit-code process))
      (when (sb-thread:with-mutex ((child-lock child))
              (or (child-reader-done child)
                  (progn (setf (child-close-on-end child) t) nil)))
        (ignore-errors (sb-ext:process-close process))))))

(defun %stop-child (client child &key (close-seconds *stdio-close-seconds*)
                                      (term-seconds *stdio-term-seconds*))
  "End CHILD as the specification says: close its stdin and wait, then SIGTERM and wait, then
SIGKILL. Returns :EXITED, :TERMINATED or :KILLED."
  (%enqueue child :close)
  (prog1 (cond ((%wait-for-exit child close-seconds) :exited)
               ((progn (%signal-child child +sigterm+)
                       (%wait-for-exit child term-seconds))
                :terminated)
               (t (%signal-child child +sigkill+)
                  (%wait-for-exit child 2)
                  :killed))
    (%finish-child client child)))

(defun close-client (client)
  "End CLIENT's use of its server. For a local server over stdio, close the server's stdin,
wait up to *STDIO-CLOSE-SECONDS* for it to exit, then send SIGTERM and wait up to
*STDIO-TERM-SECONDS*, then SIGKILL, as the specification's \"Shutdown\" says. On Windows the
server is ended with TerminateProcess instead of the two signals. Requests the client makes
after this fail as not run. For a server over HTTP it does nothing. Returns NIL."
  (sb-thread:with-mutex ((client-lock client))
    (setf (client-closed client) t)
    (let ((child (client-child client)))
      (when child
        ;; Stopped before the log line, not inside it: aion/log evaluates its fields while it
        ;; holds the appender's lock, and the reader thread logs as the server's output ends.
        (let ((how (%stop-child client child)))
          (log:info "praxeon/mcp: local server stopped"
                    :connection (connection-name (client-connection client))
                    :pid (%child-pid child) :how how)))))
  (remhash client *live-clients*)
  nil)

(defun %close-live-clients ()
  "End every local server still running when the image exits, with shorter waits."
  (loop for client being the hash-keys of *live-clients*
        do (ignore-errors
            (let ((child (client-child client)))
              (when child (%stop-child client child :close-seconds 1 :term-seconds 1))))))

(pushnew '%close-live-clients sb-ext:*exit-hooks*)

;;; --- requests -----------------------------------------------------------------------------

(defun %stdio-exchange (client child message timeout &key (cancel t))
  "Send MESSAGE, a request as a hash table without its id, to CHILD and return the reply. When
TIMEOUT seconds pass first, send `notifications/cancelled' for it when CANCEL is true and it was
written, and fail the call."
  (let ((id (%next-id client))
        (method (gethash "method" message))
        (waiter (%make-waiter)))
    (setf (gethash "jsonrpc" message) "2.0"
          (gethash "id" message) id)
    (unless (sb-thread:with-mutex ((child-lock child))
              (unless (child-exited child)
                (setf (gethash id (child-waiters child)) waiter)))
      (%request-failed client "its server process had exited." '() :outcome :not-run))
    (setf *in-flight-method* method)
    (%enqueue child (cons (jzon:stringify message) waiter))
    (labels ((written-p ()
               ;; Whether the writer took the request; if it has not, it never will.
               (sb-thread:with-mutex ((child-lock child))
                 (or (waiter-written waiter)
                     (progn (setf (waiter-abandoned waiter) t) nil))))
             (answered ()
               (let ((reply (waiter-reply waiter)))
                 (cond ((hash-table-p reply) reply)
                       ((written-p)
                        (%failed-in-flight client "its server process exited before answering." '()))
                       (t (%request-failed client "its server process exited before the request was sent."
                                           '() :outcome :not-run))))))
      (if (sb-thread:wait-on-semaphore (waiter-semaphore waiter) :timeout timeout)
          (answered)
          (let ((still-waiting (sb-thread:with-mutex ((child-lock child))
                                 (remhash id (child-waiters child)))))
            (cond ((not still-waiting)
                   ;; The reply, or the end of the output, came as the deadline passed.
                   (sb-thread:wait-on-semaphore (waiter-semaphore waiter))
                   (answered))
                  ((written-p)
                   (when cancel
                     (%enqueue child (cons (jzon:stringify
                                            (%object "jsonrpc" "2.0"
                                                     "method" "notifications/cancelled"
                                                     "params" (%object "requestId" id
                                                                       "reason" "timeout")))
                                           nil)))
                   (%failed-in-flight client "it did not answer within ~D seconds." (list timeout)))
                  (t
                   (%request-failed client "its server process did not take the request within ~D seconds."
                                    (list timeout) :outcome :not-run))))))))

(defun %find-era (client child)
  "Probe CHILD with `server/discover', as the stdio binding's \"Backward Compatibility\" says, and
fall back to the `initialize' handshake for a legacy server."
  (let* ((connection (client-connection client))
         (timeout (connection-timeout connection))
         (reply (handler-case
                    (%stdio-exchange client child
                                     (%object "method" "server/discover"
                                              "params" (%object "_meta" (%meta client)))
                                     timeout :cancel nil)
                  (request-failed (e)
                    ;; No answer in time means a legacy server; a server that exited does not.
                    (if (child-exited child) (error e) nil))))
         (result (and reply (gethash "result" reply)))
         (versions (and (hash-table-p result) (%get result "supportedVersions"))))
    (block decide
     (flet ((unsupported (offered)
             ;; OFFERED is what the server sent; only a vector's strings are kept.
             (setf (child-era child)
                   (cons :unsupported (and (vectorp offered)
                                           (remove-if-not #'stringp (coerce offered 'list)))))
             (return-from decide)))
      (cond ((and (vectorp versions) (find +protocol-version+ versions :test #'equal))
             (setf (child-era child) :modern
                   (client-era client) :modern
                   (client-protocol-version client) +protocol-version+))
            ((hash-table-p result)
             ;; A DiscoverResult means the current era, even when its list is missing or does
             ;; not hold 2026-07-28.
             (unsupported versions))
            ((and reply (member (%error-code reply) +modern-error-codes+))
             (unsupported (%get reply "error" "data" "supported")))
            (t
             ;; Any other error, or none: a legacy server. The fallback is not keyed to one code.
             ;; Set before `initialize', so that a ping the server sends meanwhile is answered.
             ;; %STDIO-CHILD clears it again if the handshake does not finish.
             (setf (child-era child) :legacy)
             (let* ((init (%stdio-exchange
                           client child
                           (%object "method" "initialize"
                                    "params" (%object "protocolVersion" (first +legacy-protocol-versions+)
                                                      "capabilities" (%object)
                                                      "clientInfo" (%object "name" *client-name*
                                                                            "version" *client-version*)))
                           timeout :cancel nil))
                    (version (%get init "result" "protocolVersion")))
               (unless (member version +legacy-protocol-versions+ :test #'equal)
                 (unsupported (and (stringp version) (vector version))))
               (%enqueue child (cons (jzon:stringify
                                      (%object "jsonrpc" "2.0" "method" "notifications/initialized"))
                                     nil))
               (setf (client-era client) :legacy
                     (client-protocol-version client) version))))))
    (log:info "praxeon/mcp: local server's era"
              :connection (connection-name connection) :pid (%child-pid child)
              :era (let ((era (child-era child))) (if (consp era) :unsupported era)))))

(defun %stdio-child (client)
  "CLIENT's running server, started, and its era found, when there is none. A server that
exited is started again when the connection allows it and +RESTART-LIMIT+ has not been reached
in the last +RESTART-WINDOW+ seconds. A request made while another starts the server waits for
it, which can take up to twice the connection's TIMEOUT."
  (let ((connection (client-connection client)))
    (sb-thread:with-mutex ((client-lock client))
      (when (client-closed client)
        (%request-failed client "the app has closed it." '() :outcome :not-run))
      (let ((child (client-child client)))
        (when (and child (not (child-exited child)) (child-era child)
                   ;; Its stdout can stay open after it exits, held by a process it started.
                   (sb-ext:process-alive-p (child-process child)))
          (return-from %stdio-child child))
        ;; CLIENT-ERA and CLIENT-PROTOCOL-VERSION describe the running server only, so they are
        ;; cleared before either refusal below; %FIND-ERA sets them again when a new server's
        ;; handshake succeeds (#610).
        (setf (client-era client) nil
              (client-protocol-version client) nil)
        (when child
          (when (child-exited child)
            (%finish-child client child))
          (unless (connection-restart connection)
            (%request-failed client "its server process exited, or did not finish starting, and the connection does not start it again. The app has to close the client and make another."
                             '() :outcome :not-run))
          (let* ((now (get-universal-time))
                 (recent (remove-if (lambda (time) (>= (- now time) +restart-window+))
                                    (client-restarts client))))
            (when (>= (length recent) +restart-limit+)
              (setf (client-restarts client) recent)
              (%request-failed client "its server process exited ~D times in the last ~D seconds, so it was not started again."
                               (list (1+ (length recent)) +restart-window+) :outcome :not-run))
            (setf (client-restarts client) (cons now recent))
            (unless (child-exited child)
              ;; Exited with its stdout still held open, or started without its era found.
              (%stop-child client child :close-seconds 0 :term-seconds 1))
            (setf (client-child client) nil)))
        (let ((new (%spawn client)))
          (setf (client-child client) new)
          (let ((found nil))
            (unwind-protect (progn (%find-era client new) (setf found t))
              ;; A handshake that failed leaves no era, so the next request starts it again
              ;; rather than sending to a server that was never initialized. The half-started
              ;; server is stopped now, so with :RESTART NIL it does not run until CLOSE-CLIENT.
              (unless found
                (setf (child-era new) nil)
                (%stop-child client new :close-seconds 1 :term-seconds 1))))
          new)))))

(defun %stdio-request (client method params timeout)
  "Send METHOD with PARAMS to CLIENT's local server and return the JSON-RPC reply."
  (let* ((connection (client-connection client))
         (started (get-internal-real-time))
         (child (%stdio-child client))
         (era (child-era child))
         (params (if params (%copy params) (%object))))
    (when (consp era)
      (%request-failed client "its server does not speak a protocol version this client does (it offers ~:[none~;~:*~{~A~^, ~}~])."
                       (list (cdr era)) :outcome :not-run))
    (when (eq era :modern)
      (setf (gethash "_meta" params) (%meta client)))
    (let ((reply (%stdio-exchange client child (%object "method" method "params" params) timeout)))
      (log:info "praxeon/mcp: request" :connection (connection-name connection)
                                       :method method :pid (%child-pid child)
                                       :ms (round (* 1000 (- (get-internal-real-time) started))
                                                  internal-time-units-per-second))
      reply)))
