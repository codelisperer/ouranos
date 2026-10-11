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
time the call began. DEADLINE is the universal time after which the task is given up, or NIL for
none. INTERVAL is the seconds between polls, and NEXT-POLL the universal time the next poll is
due. STATUS is the status the server last gave."
  (key "" :type string)
  (connection "" :type string)
  (id "" :type string)
  principal tool means source agent conversation call-id
  (started 0 :type integer)
  (deadline nil)
  (interval 5 :type integer)
  (next-poll 0 :type integer)
  (status "working" :type string))

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
              "next-poll" (task-next-poll task) "status" (task-status task)))))

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
                  :interval (val "interval") :next-poll (val "next-poll")
                  :status (val "status")))))

;;; --- the store protocol ----------------------------------------------------------------

(defgeneric save-task (store task)
  (:documentation "Keep TASK in STORE, replacing the record with the same TASK-KEY. Called when a
task starts and after each poll that changes it. An error here fails the call that started the
task, as one whose outcome is unknown."))

(defgeneric due-tasks (store connection-name now)
  (:documentation "The tasks in STORE for the connection named CONNECTION-NAME whose
TASK-NEXT-POLL is at or before NOW, a universal time."))

(defgeneric remove-task (store task)
  (:documentation "Remove TASK, by its TASK-KEY, from STORE. Return true only when this call
removed it, and NIL when it was already gone. A task finishes once: when two pollers see it
finish, only the one whose REMOVE-TASK returned true reports it. For a database this is
`DELETE ... WHERE key = ?' and a check that one row was deleted."))

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
    (setf (gethash (task-key task) (%memory-tasks store)) task)))

(defmethod due-tasks ((store memory-task-store) connection-name now)
  (sb-thread:with-mutex ((%memory-lock store))
    (loop for task being the hash-values of (%memory-tasks store)
          when (and (string= connection-name (task-connection task))
                    (<= (task-next-poll task) now))
            collect task)))

(defmethod remove-task ((store memory-task-store) task)
  (sb-thread:with-mutex ((%memory-lock store))
    (remhash (task-key task) (%memory-tasks store))))
