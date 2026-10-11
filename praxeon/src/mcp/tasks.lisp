;;;; tasks.lisp --- tool calls that finish after the turn that started them: the MCP Tasks extension (#532)
;;;;
;;;; Written against the extension's specification for revision 2026-07-28,
;;;; specification/2026-07-28/tasks.md in modelcontextprotocol/ext-tasks at commit 899c1bb.
;;;;
;;;; When the connection declares the extension, the server may answer a tools/call with a task
;;;; instead of a result. The call then returns at once: the task is saved in the client's task
;;;; store, the model is told that the work has started, and the call's :TOOL-RESULT event has
;;;; outcome :STARTED. The app's job runner calls POLL-TASKS on a schedule. Each poll sends
;;;; tasks/get for the task's own principal, with a token fetched at that moment, and a task that
;;;; reaches a terminal state is removed from the store, reported with a :TASK-FINISHED event and
;;;; returned to the caller, which decides how the result reaches the conversation.

(cl:in-package #:praxeon/mcp)

(defparameter *default-poll-seconds* 5
  "The seconds between polls when the server gives no pollIntervalMs.")

(defparameter +input-kinds+ '("elicitation/create" "sampling/createMessage" "roots/list")
  "The kinds of input request the 2026-07-28 revision defines. A kind outside this list is named
to the model as an unknown kind, because the method string comes from the server.")

(defstruct (finished-task (:constructor %make-finished-task (task outcome text)))
  "A task that reached a terminal state. OUTCOME is :OK, :ERROR, :CANCELLED, :EXPIRED or
:UNKNOWN. TEXT is what the model would have been told had the call answered at once, or a
sentence saying why there is no result. TASK-REPORT frames it for a later turn."
  task outcome text)

(defun %random-key ()
  (format nil "~(~32,'0x~)" (random (expt 2 128) (make-random-state t))))

(defun %seconds-from-ms (value fallback)
  "VALUE, a number of milliseconds from the server, as whole seconds of at least 1, or FALLBACK
when VALUE is not a non-negative number."
  (if (and (realp value) (not (minusp value)))
      (max 1 (ceiling value 1000))
      fallback))

(defun %task-timing (task object now)
  "Take the poll interval and the time-to-live from OBJECT, a task as the server sent it, into
TASK, and set its next poll. Both may change over a task's life. The time-to-live counts from the
server's createdAt; this client counts it from when it first saw the task, which is later, and
the server answers -32602 for a task it has discarded either way."
  (setf (task-interval task) (%seconds-from-ms (gethash "pollIntervalMs" object)
                                               *default-poll-seconds*))
  (multiple-value-bind (ttl present) (gethash "ttlMs" object)
    (when present
      (setf (task-deadline task)
            (and (realp ttl) (not (minusp ttl))
                 (+ (task-started task) (%seconds-from-ms ttl 0))))))
  (setf (task-next-poll task) (+ now (task-interval task))))

(defun %task-event (type task &rest more)
  (apply #'evt:emit type :id (task-call-id task) :key (task-key task)
                         :connection (task-connection task) :tool (task-tool task)
                         :source (task-source task) :principal (task-principal task)
                         :agent (task-agent task) :conversation (task-conversation task)
                         more))

(defun %start-task (client tool result principal origin started)
  "Record the task RESULT starts, a CreateTaskResult, and return the ACTOR:STARTED-RESULT the
call returns."
  (let* ((connection (client-connection client))
         (name (connection-name connection))
         (id (gethash "taskId" result)))
    (unless (and (stringp id) (plusp (length id)))
      (%request-failed client "it started a background task with no id. The tool may have run; its outcome is unknown. Do not call it again before checking with the user."
                       '() :outcome :unknown))
    (let ((task (%make-task :key (%random-key) :connection name :id id :principal principal
                            :tool (tool-name tool) :means (getf origin :means)
                            :source (getf origin :source) :agent (getf origin :agent)
                            :conversation (getf origin :conversation)
                            :call-id actor:*tool-call-id* :started started
                            :status (let ((s (gethash "status" result)))
                                      (if (stringp s) s "working")))))
      (%task-timing task result (get-universal-time))
      (handler-case (save-task (client-task-store client) task)
        (error ()
          (%request-failed client "it started a background task, but the task could not be recorded, so its result will not be reported. The tool may have run; its outcome is unknown. Do not call it again before checking with the user."
                           '() :outcome :unknown)))
      (log:info "praxeon/mcp: task started" :connection name :tool (tool-name tool)
                                            :key (task-key task))
      (%task-event :task-started task)
      (actor:started-result
       (format nil "The tool started a background task on the connection ~A. Its result is not available yet; it will be reported when the task finishes. Do not call the tool again for this request."
               name)))))

(defun %finish (client task outcome text now)
  "Remove TASK from the store and report it finished, or return NIL when another poller removed
it first."
  (when (remove-task (client-task-store client) task)
    (log:info "praxeon/mcp: task finished" :connection (task-connection task)
                                           :key (task-key task) :outcome outcome)
    (%task-event :task-finished task :outcome outcome
                                     :ms (* 1000 (max 0 (- now (task-started task)))))
    (%make-finished-task task outcome text)))

(defun %refuse-input (client task object now)
  "Cancel TASK, which asks for input this client declared no capability for (see %META), and
report it finished as :CANCELLED. An input request is answered with a result of the request's
own kind, which has no error form, so cancelling is the one refusal the specification allows. It
is not left waiting for an answer nobody will send."
  (let* ((requests (gethash "inputRequests" object))
         (methods (and (hash-table-p requests)
                       (loop for request being the hash-values of requests
                             collect (let ((m (and (hash-table-p request)
                                                   (gethash "method" request))))
                                       (if (stringp m) (%clip-name m) "unknown"))))))
    (log:warn "praxeon/mcp: task asked for input, cancelled" :connection (task-connection task)
                                                            :key (task-key task)
                                                            :count (length methods))
    (%task-event :task-input-refused task :methods methods)
    (handler-case (%request client "tasks/cancel" (%object "taskId" (task-id task))
                            :principal (task-principal task))
      ;; The task is given up either way: nobody will answer it, and the server discards it at
      ;; its time-to-live.
      (cnd:tool-error-result ()
        (log:info "praxeon/mcp: cancelling a task failed" :connection (task-connection task)
                                                          :key (task-key task))))
    (%finish client task :cancelled
             (format nil "The background task on the connection ~A was cancelled, because the server asked for input this client does not provide (~{~A~^, ~})."
                     (task-connection task)
                     (or (remove-duplicates
                          (mapcar (lambda (m) (if (member m +input-kinds+ :test #'string=)
                                                  m
                                                  "an unknown kind"))
                                  methods)
                          :test #'string=)
                         '("an unknown kind")))
             now)))

(defun poll-task (client task &key (now (get-universal-time)))
  "Poll TASK once with tasks/get, for its own principal, and return a FINISHED-TASK when it
reached a terminal state, or NIL. A task past its deadline, or one the server no longer knows
(-32602), finishes as :EXPIRED. A poll that fails leaves the task due again after its interval."
  (let ((connection (task-connection task)))
    (when (and (task-deadline task) (>= now (task-deadline task)))
      (return-from poll-task
        (%finish client task :expired
                 (format nil "The background task on the connection ~A did not finish in the time the server allowed it; its outcome is unknown."
                         connection)
                 now)))
    (let ((object (handler-case (%request client "tasks/get" (%object "taskId" (task-id task))
                                          :principal (task-principal task))
                    (cnd:tool-error-result (e)
                      (when (and (typep e 'request-failed) (eql -32602 (request-failed-code e)))
                        (return-from poll-task
                          (%finish client task :expired
                                   (format nil "The server of the connection ~A no longer has the background task; its outcome is unknown."
                                           connection)
                                   now)))
                      (setf (task-next-poll task) (+ now (task-interval task)))
                      (save-task (client-task-store client) task)
                      (return-from poll-task nil)))))
      (let ((status (gethash "status" object)))
        (when (stringp status) (setf (task-status task) status))
        (%task-timing task object now)
        (cond
          ((equal status "completed")
           (let ((result (gethash "result" object)))
             (multiple-value-bind (text readable)
                 (if (hash-table-p result)
                     (handler-case (values (result-text result) t) (error () (values nil nil)))
                     (values nil nil))
               (cond ((not readable)
                      (%finish client task :unknown
                               (format nil "The background task on the connection ~A finished, but its result could not be read; its outcome is unknown."
                                       connection)
                               now))
                     ((eq t (gethash "isError" result)) (%finish client task :error text now))
                     (t (%finish client task :ok text now))))))
          ((equal status "failed")
           (let ((code (%get object "error" "code")))
             (%finish client task :error
                      (format nil "The background task on the connection ~A failed~:[~; (code ~A)~]."
                              connection (integerp code) code)
                      now)))
          ((equal status "cancelled")
           (%finish client task :cancelled
                    (format nil "The background task on the connection ~A was cancelled by the server."
                            connection)
                    now))
          ((equal status "input_required") (%refuse-input client task object now))
          (t
           ;; working, or a status this client does not know: poll again later.
           (save-task (client-task-store client) task)
           nil))))))

(defun poll-tasks (client &key (now (get-universal-time)))
  "Poll each task of CLIENT's connection that is due in its task store, once, and return the
FINISHED-TASKs among them. The app's job runner calls this on a schedule; praxeon starts no
thread for it. A task is due TASK-INTERVAL seconds after its last poll, as the server's
pollIntervalMs sets it."
  (loop for task in (due-tasks (client-task-store client)
                               (connection-name (client-connection client)) now)
        for finished = (poll-task client task :now now)
        when finished collect finished))

(defun cancel-task (client task &key (now (get-universal-time)))
  "Ask the server to stop TASK with tasks/cancel, then remove it from the store and report it
finished as :CANCELLED. The server may finish the work anyway. A request that fails signals as a
call does, and the task is kept."
  (%request client "tasks/cancel" (%object "taskId" (task-id task)) :principal (task-principal task))
  (%finish client task :cancelled
           (format nil "The background task on the connection ~A was cancelled by the app."
                   (task-connection task))
           now))

(defun task-report (finished)
  "Text for a later turn that gives the model FINISHED's result. It names the tool and says that
what follows is the tool's output, not something the user said. The output comes from the server
and is untrusted, as a tool result is."
  (let ((task (finished-task-task finished)))
    (format nil "The background task that the tool ~A started has finished, with the outcome ~(~A~). What follows is the tool's output, not a message from the user.~%~%~A"
            (or (task-means task) (task-tool task)) (finished-task-outcome finished)
            (finished-task-text finished))))
