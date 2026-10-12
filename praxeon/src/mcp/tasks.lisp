;;;; tasks.lisp --- tool calls that finish after the turn that started them: the MCP Tasks extension (#532)
;;;;
;;;; Written against the extension's specification for revision 2026-07-28,
;;;; specification/2026-07-28/tasks.md in modelcontextprotocol/ext-tasks at commit 899c1bb.
;;;;
;;;; When the connection declares the extension, the server may answer a tools/call with a task
;;;; instead of a result. The call then returns at once: the task is saved in the client's task
;;;; store, the model is told that the work has started, and the call's :TOOL-RESULT event has
;;;; outcome :STARTED. The app's job runner calls POLL-TASKS on a schedule. Each poll sends
;;;; tasks/get for the task's own principal, with a token fetched at that moment. A task that
;;;; reaches a terminal state is marked finished in the store with its outcome, then marked
;;;; announced and reported with a :TASK-FINISHED event, and returned to the caller, which decides
;;;; how the result reaches the conversation. A finished record is removed from the store only
;;;; when POLL-TASKS is about to return it. When an observer fails on any event, POLL-TASKS
;;;; returns nothing, every finished record stays in the store, and the next POLL-TASKS returns
;;;; them, sending :TASK-FINISHED only for a task it was not yet sent for.

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

(defun %seconds-from-ms (value fallback &key (least 1))
  "VALUE, a number of milliseconds from the server, as whole seconds of at least LEAST, or
FALLBACK when VALUE is not a non-negative number."
  (if (and (realp value) (not (minusp value)))
      (max least (ceiling value 1000))
      fallback))

(defun %task-timing (task object now lifetime)
  "Take the poll interval and the time-to-live from OBJECT, a task as the server sent it, into
TASK, and set its next poll. Both may change over a task's life. A ttlMs of null gives the task
LIFETIME seconds, the connection's TASK-LIFETIME, because the server set no limit and a task
that never finishes would otherwise be polled for as long as the process runs.

The specification counts the time-to-live from the server's createdAt. This client counts it
from TASK-SEEN, when it received the task, which is later, so the client never gives a task up
before the server may: createdAt is the server's clock, and comparing it with this one would
add their difference. A server that discarded the task earlier answers -32602, which finishes it
as :EXPIRED too. The next poll is due no later than the deadline, so a task past it is polled
once more and then given up."
  (setf (task-interval task) (%seconds-from-ms (gethash "pollIntervalMs" object)
                                               *default-poll-seconds*))
  (multiple-value-bind (ttl present) (gethash "ttlMs" object)
    (when present
      (setf (task-deadline task)
            (+ (task-seen task)
               (if (and (realp ttl) (not (minusp ttl)))
                   (%seconds-from-ms ttl 0 :least 0)
                   lifetime)))))
  (setf (task-next-poll task) (let ((next (+ now (task-interval task))))
                                (if (task-deadline task) (min next (task-deadline task)) next))))

(defun %task-shape-p (object)
  "Whether OBJECT has what the specification requires of a task: a known status, createdAt and
lastUpdatedAt, a ttlMs that is a non-negative number or null, and a pollIntervalMs, when given,
that is a non-negative number."
  (flet ((ms-p (v) (and (realp v) (not (minusp v)))))
    (multiple-value-bind (ttl ttl-p) (gethash "ttlMs" object)
      (multiple-value-bind (poll poll-p) (gethash "pollIntervalMs" object)
        (and (member (gethash "status" object)
                     '("working" "input_required" "completed" "cancelled" "failed")
                     :test #'equal)
             (stringp (gethash "createdAt" object))
             (stringp (gethash "lastUpdatedAt" object))
             ttl-p (or (eq ttl 'null) (ms-p ttl))
             (or (not poll-p) (ms-p poll)))))))

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
    (unless (and (stringp id) (plusp (length id)) (%task-shape-p result))
      (%request-failed client "it started a background task the client could not read. The tool may have run; its outcome is unknown. Do not call it again before checking with the user."
                       '() :outcome :unknown))
    (let* ((now (get-universal-time))
           (task (%make-task :key (%random-key) :connection name :id id :principal principal
                             :tool (tool-name tool) :means (getf origin :means)
                             :source (getf origin :source) :agent (getf origin :agent)
                             :conversation (getf origin :conversation)
                             :call-id actor:*tool-call-id* :started started :seen now
                             :status (gethash "status" result))))
      (%task-timing task result now (connection-task-lifetime connection))
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

(defun %own-task (client task operation)
  "Signal an error, before anything is sent, when TASK belongs to another connection than
CLIENT's: its id and principal would go to a server that did not issue them."
  (let ((name (connection-name (client-connection client))))
    (unless (string= name (task-connection task))
      (error "praxeon/mcp: ~A: the task ~A belongs to the connection ~A, not to this client's connection ~A; nothing was sent."
             operation (task-key task) (task-connection task) name))))

(defun %announce (client task now)
  "Emit :TASK-FINISHED for TASK, which FINISH-TASK has marked finished, unless it was emitted
already, and return TASK. The store records the announcement before the event, so when an
observer signals on it, the event is not sent again."
  (setf (task-announced-at task) now)
  (when (announce-task (client-task-store client) task)
    (log:info "praxeon/mcp: task finished" :connection (task-connection task)
                                           :key (task-key task) :outcome (task-outcome task))
    (%task-event :task-finished task :outcome (task-outcome task)
                                     :ms (* 1000 (max 0 (- now (task-started task))))))
  task)

(defun %deliver (client tasks)
  "Remove each of TASKS, finished and announced, from the store, and return a FINISHED-TASK for
each one this call removed. A task another poller removed first is left out, so each is returned
once. This is the last step before a result is returned, so a failure before it leaves every
finished task in the store for the next poll."
  (loop for task in tasks
        when (remove-task (client-task-store client) task)
          collect (%make-finished-task task (task-outcome task) (task-text task))))

(defun %claim (client task outcome text now)
  "Mark TASK finished with OUTCOME and TEXT in the store, and return true when this call did,
or NIL when another poller finished it first."
  (setf (task-outcome task) outcome (task-text task) text (task-next-poll task) now)
  (finish-task (client-task-store client) task))

(defun %finish (client task outcome text now)
  "Finish TASK and announce it, and return TASK, or NIL when another poller finished it first."
  (when (%claim client task outcome text now)
    (%announce client task now)))

(defun %refuse-input (client task object now)
  "Cancel TASK, which asks for input this client declared no capability for (see %META), and
report it finished as :CANCELLED. An input request is answered with a result of the request's
own kind, which has no error form, so cancelling is the one refusal the specification allows. It
is not left waiting for an answer nobody will send. tasks/cancel is sent and the task marked
finished before :TASK-INPUT-REFUSED and :TASK-FINISHED, so an observer that fails on either cannot
leave the task waiting. When the observer fails on :TASK-INPUT-REFUSED, the next poll sends
:TASK-FINISHED.

When something other than a tool error leaves tasks/cancel, such as an observer of
:SIGN-IN-REQUIRED that signals or an app's handler of AUTHORIZATION-REQUIRED that exits, the task
is still marked :CANCELLED, so the next poll announces it with :TASK-FINISHED instead of sending
tasks/cancel again. :TASK-INPUT-REFUSED is not sent in that case; the reason is in the task's
text and in the log. A store error while marking it is logged, and the condition that left the
request is the one the caller sees (#587)."
  (let* ((requests (gethash "inputRequests" object))
         (methods (and (hash-table-p requests)
                       (loop for request being the hash-values of requests
                             collect (let ((m (and (hash-table-p request)
                                                   (gethash "method" request))))
                                       (if (stringp m) (%clip-name m) "unknown")))))
         (text (format nil "The background task on the connection ~A was cancelled, because the server asked for input this client does not provide (~{~A~^, ~})."
                       (task-connection task)
                       (or (remove-duplicates
                            (mapcar (lambda (m) (if (member m +input-kinds+ :test #'string=)
                                                    m
                                                    "an unknown kind"))
                                    methods)
                            :test #'string=)
                           '("an unknown kind"))))
         (returned nil))
    (log:warn "praxeon/mcp: task asked for input, cancelled" :connection (task-connection task)
                                                            :key (task-key task)
                                                            :count (length methods))
    (unwind-protect
         (progn
           (handler-case (%request client "tasks/cancel" (%object "taskId" (task-id task))
                                   :principal (task-principal task))
             ;; The task is given up either way: nobody will answer it, and the server discards
             ;; it at its time-to-live.
             (cnd:tool-error-result ()
               (log:info "praxeon/mcp: cancelling a task failed" :connection (task-connection task)
                                                                 :key (task-key task))))
           (setf returned t))
      (unless returned
        (%record-while-unwinding task "marking a refused task cancelled"
                                 (lambda () (%claim client task :cancelled text now)))))
    (when (%claim client task :cancelled text now)
      (%task-event :task-input-refused task :methods methods)
      (%announce client task now))))

(defun %input-entries (object)
  "Each entry of the inputRequests in OBJECT, a task the server sent, as (KEY METHOD PARAMS), or
NIL when there are none. KEY, METHOD and PARAMS are as the server sent them, unchecked."
  (let ((requests (gethash "inputRequests" object)))
    (and (hash-table-p requests)
         (loop for key being the hash-keys of requests using (hash-value request)
               collect (list key
                             (and (hash-table-p request) (gethash "method" request))
                             (and (hash-table-p request) (gethash "params" request)))))))

(defun %elicitation-mode (params)
  "The mode of an elicitation/create request with PARAMS: :FORM, also when the mode is absent,
as the elicitation page requires of a client, :URL, or NIL for any other value."
  (let ((mode (and (hash-table-p params) (gethash "mode" params))))
    (cond ((or (null mode) (equal mode "form")) :form)
          ((equal mode "url") :url))))

(defun %answerable-p (connection entry)
  "Whether ENTRY, as %INPUT-ENTRIES gives it, is an input request the app can be asked: an
elicitation/create in a mode CONNECTION declared, under a string key, with a string message and
the field its mode requires: a requestedSchema object in form mode, a string url in url mode
(2026-07-28, \"Elicitation\"). A request without it is malformed, and is refused like a request
this client did not declare, rather than reaching the app with NIL (Copilot's review of #627)."
  (destructuring-bind (key method params) entry
    (and (stringp key) (plusp (length key))
         (equal method "elicitation/create")
         (hash-table-p params)
         (stringp (gethash "message" params))
         (let ((mode (%elicitation-mode params)))
           (and (member mode (connection-elicitation connection))
                (ecase mode
                  (:form (hash-table-p (gethash "requestedSchema" params)))
                  (:url (stringp (gethash "url" params))))))
         t)))

(defun %with-input-answered (inputs key)
  "INPUTS, a task's TASK-INPUTS, with KEY marked answered. A new list of new entries: the entries
are never changed in place, because the memory store's copies of a task share them (Copilot's
review of #627)."
  (mapcar (lambda (input)
            (if (equal (first input) key)
                (list (first input) (second input) t)
                input))
          inputs))

(defun %elicit-result (action content)
  "The ElicitResult for ACTION, :ACCEPT, :DECLINE or :CANCEL, with CONTENT, a JSON object, when
given."
  (let ((result (%object "action" (string-downcase (symbol-name action)))))
    (when content (setf (gethash "content" result) content))
    result))

(defun %send-input-responses (client task responses)
  "Send tasks/update for TASK with RESPONSES, an InputResponses object, for the task's own
principal. A tool error signals, as from a call."
  (%request client "tasks/update"
            (%object "taskId" (task-id task) "inputResponses" responses)
            :principal (task-principal task)))

(defun %take-input (client task object now)
  "TASK asks for input, as OBJECT, its tasks/get reply, says. When every request in it is one
the app can be asked (%ANSWERABLE-P), tell the app of each key not shown before with a
:TASK-INPUT-REQUIRED event, answer cancel to each key still asked that the app has not answered
within the connection's INPUT-TIMEOUT, with a :TASK-INPUT-EXPIRED event, and keep the task
waiting. Otherwise the request is one this client did not declare, and the task is cancelled
as before (%REFUSE-INPUT). A task past its deadline expires.

The events for new keys are sent before the record is saved, so an observer that signals leaves
the keys unrecorded and the next poll tells the app again: a question is shown at least once.
The message, schema and URL in the event come from the server and are untrusted (#563)."
  (let* ((connection (client-connection client))
         (entries (%input-entries object)))
    (cond
      ((%past-deadline-p task now)
       (%expire client task nil now))
      ((or (null entries)
           (notevery (lambda (entry) (%answerable-p connection entry)) entries))
       (%refuse-input client task object now))
      (t
       (let ((new (remove-if (lambda (entry)
                               (assoc (first entry) (task-inputs task) :test #'equal))
                             entries)))
         ;; Recorded on this copy of the task before the events, so an observer can answer a key
         ;; from inside the event; saved to the store only after them, so an observer that
         ;; signals leaves the keys unsaved and the next poll shows them again.
         (setf (task-inputs task)
               (append (task-inputs task)
                       (mapcar (lambda (entry) (list (first entry) now nil)) new)))
         (dolist (entry new)
           (destructuring-bind (key method params) entry
             (declare (ignore method))
             (let ((mode (%elicitation-mode params)))
               (%task-event :task-input-required task
                            :input-key key :mode mode :message (gethash "message" params)
                            :schema (and (eq mode :form) (gethash "requestedSchema" params))
                            :url (and (eq mode :url) (gethash "url" params))
                            :task task)))))
       (dolist (input (task-inputs task))
         (destructuring-bind (key seen answered) input
           (when (and (not answered)
                      (assoc key entries :test #'equal)
                      (>= (- now seen) (connection-input-timeout connection)))
             (handler-case
                 (progn
                   (%send-input-responses client task (%object key (%elicit-result :cancel nil)))
                   (setf (task-inputs task) (%with-input-answered (task-inputs task) key))
                   (log:info "praxeon/mcp: task input not answered in time, answered cancel"
                             :connection (task-connection task) :key (task-key task))
                   (%task-event :task-input-expired task :input-key key))
               (cnd:tool-error-result ()
                 (log:info "praxeon/mcp: answering an expired task input failed"
                           :connection (task-connection task) :key (task-key task)))))))
       (update-task (client-task-store client) task)
       nil))))

(defun %record-while-unwinding (task what record)
  "Call RECORD, a function that writes TASK to the store while the stack unwinds for another
reason. A store error would replace that reason, so it is logged, with WHAT, instead; the task
keeps its last record."
  (handler-case (funcall record)
    (error (e)
      (log:warn "praxeon/mcp: recording a task failed" :what what
                :connection (task-connection task) :key (task-key task)
                :condition (type-of e)))))

(defun %expiry-text (task gone)
  (if gone
      (format nil "The server of the connection ~A no longer has the background task; its outcome is unknown."
              (task-connection task))
      (format nil "The background task on the connection ~A did not finish in the time allowed for it; its outcome is unknown."
              (task-connection task))))

(defun %expire (client task gone now)
  "Finish TASK as :EXPIRED: GONE true when the server no longer has it, and NIL when it did not
finish by its deadline."
  (%finish client task :expired (%expiry-text task gone) now))

(defun %backoff (interval failures cap)
  "The seconds to wait after the FAILURESth failed poll in a row: INTERVAL, doubled for each
failure after the first, and no more than CAP, unless INTERVAL itself is more."
  (let ((wait interval))
    ;; Doubling stops at CAP, so a long run of failures does not compute a large power of two.
    (loop repeat (1- failures)
          while (and (plusp wait) (< wait cap))
          do (setf wait (* 2 wait)))
    (max interval (min cap wait))))

(defun %failed-poll (client task kind now)
  "Record a failed poll of TASK, of KIND :SIGN-IN or :ERROR, and set its next poll by %BACKOFF,
no later than its deadline. A failure of another kind than the last starts a new run for the
sign-in event: *SIGN-IN-TOLD* is true for the next poll only after a :SIGN-IN failure."
  (setf (task-failures task) (1+ (task-failures task))
        (task-failure task) kind
        (task-next-poll task)
        (let ((next (+ now (%backoff (task-interval task) (task-failures task)
                                     (connection-task-backoff-cap (client-connection client))))))
          (if (task-deadline task) (min next (task-deadline task)) next)))
  (update-task (client-task-store client) task))

(defun %past-deadline-p (task now)
  (and (task-deadline task) (>= now (task-deadline task))))

(defun %get-task (client task now)
  "Send tasks/get for TASK, as (values OBJECT NIL), or (values NIL CONDITION) when the request
failed with a tool error. When something else leaves the request, such as an observer of
:SIGN-IN-REQUIRED that signals or an app's handler of AUTHORIZATION-REQUIRED that exits, the poll
is still recorded as failed, so the task waits by %BACKOFF and is not polled again at once. A
task past its deadline is marked :EXPIRED instead, and the next poll announces it. Nothing is
emitted here, because the stack is already unwinding, and a store error while recording is logged
rather than signalled, so the caller sees the condition that left the request (#565 review)."
  (let ((returned nil)
        (kind :error))
    (unwind-protect
         (multiple-value-prog1
             (handler-bind ((authorization-required
                              (lambda (c) (declare (ignore c)) (setf kind :sign-in))))
               (handler-case (let ((*sign-in-told* (eq :sign-in (task-failure task))))
                               (values (%request client "tasks/get"
                                                 (%object "taskId" (task-id task))
                                                 :principal (task-principal task))
                                       nil))
                 (cnd:tool-error-result (e) (values nil e))))
           ;; An interrupt between the reply and this SETF drops the reply and records a failed
           ;; poll; the task is polled again later, so nothing is lost but one poll.
           (setf returned t))
      (unless returned
        (%record-while-unwinding task "recording a failed poll"
                                 (lambda ()
                                   (if (%past-deadline-p task now)
                                       (%claim client task :expired (%expiry-text task nil) now)
                                       (%failed-poll client task kind now))))))))

(defun %poll (client task now)
  "Poll TASK once and return it when it is finished and announced, or NIL. The record stays in
the store; %DELIVER removes it. A task already marked finished is announced, if it was not yet,
and returned without a poll."
  (when (task-outcome task)
    (return-from %poll (%announce client task now)))
  (multiple-value-bind (object e) (%get-task client task now)
    (when e
      (cond ((and (typep e 'request-failed) (eql -32602 (request-failed-code e)))
             (return-from %poll (%expire client task t now)))
            ((%past-deadline-p task now)
             (return-from %poll (%expire client task nil now))))
      (%failed-poll client task (if (typep e 'sign-in-needed) :sign-in :error) now)
      (return-from %poll nil))
    (let ((status (gethash "status" object))
          (connection (task-connection task)))
      (setf (task-failures task) 0 (task-failure task) nil)
      (when (stringp status) (setf (task-status task) status))
      (%task-timing task object now (connection-task-lifetime (client-connection client)))
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
        ((equal status "input_required") (%take-input client task object now))
        ((%past-deadline-p task now)
         (%expire client task nil now))
        (t
         ;; working, or a status this client does not know: poll again later.
         (update-task (client-task-store client) task)
         nil)))))

(defun poll-task (client task &key (now (get-universal-time)))
  "Poll TASK once with tasks/get, for its own principal, and return a FINISHED-TASK when it
reached a terminal state, or NIL. A task that is still not finished at its deadline, or one the
server no longer knows (-32602), finishes as :EXPIRED. A poll that fails leaves the task due
again later, by %BACKOFF, and tells the app that its principal must sign in only on the first
failed poll of a run. A task already marked finished is returned without a poll, with
:TASK-FINISHED only when it was not sent yet. TASK must belong to CLIENT's connection; otherwise
this signals an error and sends nothing."
  (%own-task client task "poll-task")
  (let ((done (%poll client task now)))
    (first (%deliver client (and done (list done))))))

(defun poll-tasks (client &key (now (get-universal-time)))
  "Poll each task of CLIENT's connection that is due in its task store, once, and return the
FINISHED-TASKs among them. The app's job runner calls this on a schedule; praxeon starts no
thread for it. A task is due TASK-INTERVAL seconds after its last poll, as the server's
pollIntervalMs sets it, and no later than its deadline. Finished tasks leave the store only as
this returns them, so when an observer or a request signals partway, no finished task is lost:
the next call returns each of them."
  (%deliver client
            (loop for task in (due-tasks (client-task-store client)
                                         (connection-name (client-connection client)) now)
                  for done = (%poll client task now)
                  when done collect done)))

(defun cancel-task (client task &key (now (get-universal-time)))
  "Ask the server to stop TASK with tasks/cancel, then report it finished as :CANCELLED. The
server may finish the work anyway. A request that fails signals as a call does, and the task is
kept. A task already marked finished is returned as it finished, with nothing sent to the server.
TASK must belong to CLIENT's connection; otherwise this signals an error and sends nothing."
  (%own-task client task "cancel-task")
  (when (task-outcome task)
    (return-from cancel-task (first (%deliver client (list (%announce client task now))))))
  (%request client "tasks/cancel" (%object "taskId" (task-id task)) :principal (task-principal task))
  (let ((done (%finish client task :cancelled
                       (format nil "The background task on the connection ~A was cancelled by the app."
                               (task-connection task))
                       now)))
    (first (%deliver client (and done (list done))))))

(defun answer-task-input (client task input-key action &key content)
  "Answer the input request INPUT-KEY of TASK, which a :TASK-INPUT-REQUIRED event named, with
ACTION: :ACCEPT, :DECLINE or :CANCEL (2026-07-28, \"Elicitation\", Response Actions). CONTENT is
the submitted data, a JSON object as a hash table, for :ACCEPT to a form-mode request only; an
answer to a url-mode request carries none. Returns T.

It asks the server first, with tasks/get, whether INPUT-KEY is still outstanding: the event's
TASK is a copy taken when the key was shown, and since then the task may have finished, or the
key been answered cancel by the connection's INPUT-TIMEOUT. Only when the server still lists
INPUT-KEY, in a task still input_required, is tasks/update sent with the ElicitResult, for the
task's own principal. The key is then marked answered on TASK, so the same object does not answer
it twice. The task store is not written: the server dropping the key is what ends the request,
and writing TASK, an older copy, could undo what later polls recorded (Copilot's review of #627).
A request that fails signals as a call does, and nothing more is sent.

TASK is the task object the event carried: the task store has no lookup by key, so the app keeps
it until it answers. AFTER AN APP RESTART an unanswered key is not asked again, because it is
recorded as shown; it is answered cancel when the connection's INPUT-TIMEOUT passes. Answering
across a restart would need a lookup by key, which an optional task-store generic whose default
method returns NIL could add later, so that stores written by apps keep working (#563).

Signals an error, and sends no answer, when TASK belongs to another connection, is finished, or
has no outstanding request INPUT-KEY, here or on the server, when ACTION is not one of the three,
or when CONTENT is not a hash table, is given with another action than :ACCEPT, or is given for a
url-mode request. The server checks CONTENT against its requestedSchema."
  (%own-task client task "answer-task-input")
  (flet ((refuse (control arguments)
           (error "praxeon/mcp: answer-task-input: ~?; no answer was sent." control arguments)))
    (let ((input (assoc input-key (task-inputs task) :test #'equal)))
      (when (task-outcome task)
        (refuse "the task ~A has finished" (list (task-key task))))
      (unless (and input (not (third input)))
        (refuse "~S is not an outstanding input request of the task ~A"
                (list input-key (task-key task))))
      (unless (member action '(:accept :decline :cancel))
        (refuse "the action is :accept, :decline or :cancel, not ~S" (list action)))
      (when (and content (not (eq action :accept)))
        (refuse "content is given only with :accept" '()))
      (unless (or (null content) (hash-table-p content))
        (refuse "content is a JSON object, as a hash table" '())))
    (let* ((current (%request client "tasks/get" (%object "taskId" (task-id task))
                              :principal (task-principal task)))
           (entry (and (hash-table-p current)
                       (equal "input_required" (gethash "status" current))
                       (assoc input-key (%input-entries current) :test #'equal))))
      (unless entry
        (refuse "~S is no longer outstanding on the server for the task ~A"
                (list input-key (task-key task))))
      (when (and content (eq :url (%elicitation-mode (third entry))))
        (refuse "an answer to the url-mode request ~S carries no content" (list input-key))))
    (%send-input-responses client task (%object input-key (%elicit-result action content)))
    (setf (task-inputs task) (%with-input-answered (task-inputs task) input-key))
    (log:info "praxeon/mcp: task input answered" :connection (task-connection task)
                                                 :key (task-key task) :action action)
    t))

(defun task-report (finished)
  "Text for a later turn that gives the model FINISHED's result. It names the tool and says that
what follows is the tool's output, not something the user said. The output comes from the server
and is untrusted, as a tool result is."
  (let ((task (finished-task-task finished)))
    (format nil "The background task that the tool ~A started has finished, with the outcome ~(~A~). What follows is the tool's output, not a message from the user.~%~%~A"
            (or (task-means task) (task-tool task)) (finished-task-outcome finished)
            (finished-task-text finished))))
