;;;; task-store.lisp --- the record of an MCP task, and where it is kept between polls (#532)
;;;;
;;;; A tool call that becomes a task finishes after the turn that started it. Its record has to
;;;; outlive the turn, and after a restart that means the app's own storage, so the record is
;;;; plain data that converts to and from JSON text, and the place it is kept is a protocol: an
;;;; app supplies a store backed by its database, and MAKE-MEMORY-TASK-STORE is the default,
;;;; which is lost when the process ends.

(cl:in-package #:praxeon/mcp)

(defstruct (task (:constructor %make-task))
  "One task an MCP server started for a tool call (#532).

KEY is this client's own id for the record, which events and logs carry. ID is the server's
task id. It is sent only to the server and never to the model, events or logs, because the
specification lets a server use it as the bearer of the task's state. CONNECTION is the
connection's name, PRINCIPAL the user the call ran for, TOOL the server's tool name, MEANS the
means name, SOURCE the means' source plist, AGENT the agent's name and CONVERSATION its
conversation id. CALL-ID is the model's id for the call that started it. STARTED is the universal
time the call began, which :TASK-FINISHED's :MS counts from. SEEN is the universal time the
client received the task, which the time-to-live counts from. DEADLINE is the universal time
after which a task that has not finished is given up, or NIL for none. INTERVAL is the seconds
between polls, and NEXT-POLL the universal time the next poll is due. STATUS is the status the
server last gave. OUTCOME and TEXT are NIL until the task finishes; then they are what POLL-TASKS
returns for it, kept in the record until POLL-TASKS has returned it. ANNOUNCED-AT is NIL until
:TASK-FINISHED is sent for the finished task, and then the universal time it was sent. FAILURES
is how many polls in a row have failed, which sets how long the next one waits, and FAILURE the
kind of the last of them: :SIGN-IN when its principal had to sign in, :ERROR for any other
failure, or NIL after a poll that succeeded. INPUTS lists the input requests the server has
asked of the task that the app was told of (#563), each a list (KEY SEEN ANSWERED): the
server's key for the request, the universal time it was first seen, and true once it was
answered. It is kept with the record so that a key is shown once, also after a restart.
PRIVATE is true when the turn that started the task withheld content, because its agent was
private (#983); the task's events withhold content by it, whichever thread or turn polls the
task."
  (key "" :type string)
  (connection "" :type string)
  (id "" :type string)
  principal tool means source agent conversation call-id
  (started 0 :type integer)
  (seen 0 :type integer)
  (deadline nil)
  (interval 5 :type integer)
  (next-poll 0 :type integer)
  (status "working" :type string)
  (outcome nil)
  (text nil)
  (announced-at nil)
  (failures 0 :type integer)
  (failure nil)
  (inputs '() :type list)
  (private nil))

(defparameter +task-outcomes+ '(("ok" . :ok) ("error" . :error) ("cancelled" . :cancelled)
                                ("expired" . :expired) ("unknown" . :unknown))
  "A finished task's outcomes, by the name TASK-TO-JSON writes.")

(defparameter +task-failures+ '(("sign-in" . :sign-in) ("error" . :error))
  "The kinds of failed poll, by the name TASK-TO-JSON writes.")

;;; --- JSON ------------------------------------------------------------------------------

(defun %source-to-json (source)
  (%object "connection" (getf source :connection) "tool" (getf source :tool)
           "per-user" (and (getf source :per-user) t)))

(defun %source-from-json (object)
  (and (hash-table-p object)
       (list :connection (gethash "connection" object) :tool (gethash "tool" object)
             :per-user (and (gethash "per-user" object) t))))

(defun task-to-json (task)
  "TASK as JSON text, for an app's task store. The principal must be a string or an integer, as
for a held turn (#531)."
  (unless (or (null (task-principal task)) (stringp (task-principal task))
              (integerp (task-principal task)))
    (error "task-to-json: the principal must be a string or an integer, not ~S"
           (task-principal task)))
  (flet ((orn (v) (if (null v) 'null v)))
    (jzon:stringify
     (%object "key" (task-key task) "connection" (task-connection task) "id" (task-id task)
              "principal" (orn (task-principal task)) "tool" (orn (task-tool task))
              "means" (orn (task-means task)) "source" (%source-to-json (task-source task))
              "agent" (orn (task-agent task)) "conversation" (orn (task-conversation task))
              "call-id" (orn (task-call-id task)) "started" (task-started task)
              "deadline" (orn (task-deadline task)) "interval" (task-interval task)
              "seen" (task-seen task) "next-poll" (task-next-poll task)
              "status" (task-status task)
              "outcome" (orn (car (rassoc (task-outcome task) +task-outcomes+)))
              "text" (orn (task-text task)) "announced-at" (orn (task-announced-at task))
              "failures" (task-failures task)
              "failure" (orn (car (rassoc (task-failure task) +task-failures+)))
              "private" (and (task-private task) t)
              "inputs" (coerce (mapcar (lambda (input)
                                         (destructuring-bind (key seen answered) input
                                           (%object "key" key "seen" seen
                                                    "answered" (and answered t))))
                                       (task-inputs task))
                               'vector)))))

(defun task-from-json (text)
  "The task TASK-TO-JSON wrote as TEXT. The text is parsed as JSON, never read by the Lisp
reader."
  (let ((o (jzon:parse text)))
    (flet ((val (key) (let ((v (gethash key o))) (if (eq v 'null) nil v))))
      (%make-task :key (val "key") :connection (val "connection") :id (val "id")
                  :principal (val "principal") :tool (val "tool") :means (val "means")
                  :source (%source-from-json (val "source")) :agent (val "agent")
                  :conversation (val "conversation") :call-id (val "call-id")
                  :started (val "started") :deadline (val "deadline")
                  :seen (val "seen") :interval (val "interval") :next-poll (val "next-poll")
                  :status (val "status")
                  :outcome (cdr (assoc (val "outcome") +task-outcomes+ :test #'equal))
                  :text (val "text") :announced-at (val "announced-at")
                  :failures (or (val "failures") 0)
                  :failure (cdr (assoc (val "failure") +task-failures+ :test #'equal))
                  ;; A record written before #983 has no private flag.
                  :private (eq t (val "private"))
                  ;; A record written before #563 has no inputs.
                  :inputs (map 'list (lambda (input)
                                       (list (gethash "key" input) (gethash "seen" input)
                                             (eq t (gethash "answered" input))))
                               (or (val "inputs") #()))))))

;;; --- the store protocol ----------------------------------------------------------------
;;;
;;; Several pollers may share a store. A record is written by SAVE-TASK once, when the task
;;; starts; after that only UPDATE-TASK, FINISH-TASK and ANNOUNCE-TASK change it. UPDATE-TASK and
;;; FINISH-TASK change only a record that is still there and not finished, so a poll that read
;;; the task before another poller finished it cannot write it back. ANNOUNCE-TASK changes only a
;;; finished record not yet announced, so :TASK-FINISHED is sent once. A finished record stays in
;;; the store until POLL-TASKS, POLL-TASK or CANCEL-TASK has returned it, and REMOVE-TASK is
;;; called just before that return.

(defgeneric save-task (store task)
  (:documentation "Keep TASK in STORE as a new record. Called once, when a task starts. An error
here fails the call that started the task, as one whose outcome is unknown."))

(defgeneric update-task (store task)
  (:documentation "Replace the record with TASK's TASK-KEY by TASK, when the record is still in
STORE and has no TASK-OUTCOME. Return true when it was replaced. Called after a poll that did not
finish the task. For a database this is `UPDATE ... WHERE key = ? AND outcome IS NULL'."))

(defgeneric finish-task (store task)
  (:documentation "Replace the record with TASK's TASK-KEY by TASK, which has a TASK-OUTCOME, when
the record is still in STORE and has none. Return true only for the call that replaced it. A task
finishes once: when two pollers see it finish, only the one whose FINISH-TASK returned true
reports it. For a database this is `UPDATE ... WHERE key = ? AND outcome IS NULL' and a check
that one row changed."))

(defgeneric announce-task (store task)
  (:documentation "Set the TASK-ANNOUNCED-AT of the record with TASK's TASK-KEY to TASK's, when the
record is still in STORE, has a TASK-OUTCOME and has no TASK-ANNOUNCED-AT. Return true only for
the call that set it; that call sends :TASK-FINISHED. For a database this is `UPDATE ... WHERE
key = ? AND outcome IS NOT NULL AND announced_at IS NULL' and a check that one row changed."))

(defgeneric due-tasks (store connection-name now)
  (:documentation "The tasks in STORE for the connection named CONNECTION-NAME whose
TASK-NEXT-POLL is at or before NOW, a universal time. A finished task that was not yet reported
is due at once. The tasks returned are copies: changing one does not change the store."))

(defgeneric remove-task (store task)
  (:documentation "Remove TASK, by its TASK-KEY, from STORE. Return true only when this call
removed it, and NIL when it was already gone. For a database this is `DELETE ... WHERE key = ?'
and a check that one row was deleted."))

(defclass memory-task-store ()
  ((tasks :initform (make-hash-table :test #'equal) :reader %memory-tasks)
   (lock :initform (sb-thread:make-mutex :name "praxeon/mcp task store") :reader %memory-lock))
  (:documentation "A task store in this process. Its tasks are lost when the process ends, so an
app whose tasks must survive a restart supplies a store backed by its own storage."))

(defun make-memory-task-store ()
  "A task store held in this process (see MEMORY-TASK-STORE)."
  (make-instance 'memory-task-store))

(defmethod save-task ((store memory-task-store) task)
  (sb-thread:with-mutex ((%memory-lock store))
    (setf (gethash (task-key task) (%memory-tasks store)) (copy-task task))))

(defun %replace-unfinished (store task)
  (sb-thread:with-mutex ((%memory-lock store))
    (let ((stored (gethash (task-key task) (%memory-tasks store))))
      (when (and stored (null (task-outcome stored)))
        (setf (gethash (task-key task) (%memory-tasks store)) (copy-task task))
        t))))

(defmethod update-task ((store memory-task-store) task)
  (%replace-unfinished store task))

(defmethod finish-task ((store memory-task-store) task)
  (%replace-unfinished store task))

(defmethod announce-task ((store memory-task-store) task)
  (sb-thread:with-mutex ((%memory-lock store))
    (let ((stored (gethash (task-key task) (%memory-tasks store))))
      (when (and stored (task-outcome stored) (null (task-announced-at stored)))
        (setf (task-announced-at stored) (task-announced-at task))
        t))))

(defmethod due-tasks ((store memory-task-store) connection-name now)
  (sb-thread:with-mutex ((%memory-lock store))
    (loop for task being the hash-values of (%memory-tasks store)
          when (and (string= connection-name (task-connection task))
                    (<= (task-next-poll task) now))
            collect (copy-task task))))

(defmethod remove-task ((store memory-task-store) task)
  (sb-thread:with-mutex ((%memory-lock store))
    (remhash (task-key task) (%memory-tasks store))))
