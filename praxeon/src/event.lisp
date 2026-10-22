;;;; event.lisp --- the client<->framework progress contract
;;;;
;;;; Between a request and its response, the actor loop knows what it is doing:
;;;; deliberating, applying a means, deliberating again, answering. This module
;;;; lets it *say so*, without deciding how that is shown. The loop EMITs neutral
;;;; EVENTS to a registered *OBSERVER*; a UX layer renders them however it likes.
;;;;
;;;; An event is a plain plist tagged by :type -- **data, not behavior** -- so the
;;;; same stream drives a CLI status line, a REPL log, or a web SSE/WebSocket feed
;;;; unchanged (the plist serializes straight to JSON). This is deliberately the
;;;; transport-neutral seam that lets praxeon/* UX libraries (CLI today, web
;;;; later) attach high-quality progress reporting to any client in one line.
;;;;
;;;; The event vocabulary the actor loop emits:
;;;;   (:type :deliberating :step N)                       -- about to call the model
;;;;   (:type :tool-call    :id .. :name .. :arguments .. :source .. :principal .. :agent ..
;;;;                        :conversation ..)
;;;;                        -- the model chose a means
;;;;   (:type :tool-result  :id .. :name .. :content .. :source .. :principal .. :agent ..
;;;;                        :conversation .. :outcome .. :ms .. [:is-error t])
;;;;                        -- the means ran. SOURCE is the plist the means was registered
;;;;                           with, or NIL; PRINCIPAL the user the turn runs for; AGENT the
;;;;                           agent's name; CONVERSATION its result-store conversation id, or
;;;;                           NIL; OUTCOME :OK,
;;;;                           :ERROR, :NOT-RUN or :UNKNOWN (see TOOL-ERROR-RESULT), or
;;;;                           :STARTED for a call whose work finishes later (#532); MS the
;;;;                           call's duration. Enough for a usage ledger to record the call
;;;;                           (#527, until #493 settles the usage interface).
;;;;   (:type :sign-in-required :connection .. :principal ..)
;;;;                        -- an MCP tool needs the user to sign in (#527)
;;;;   (:type :task-started :id .. :key .. :connection .. :tool .. :source .. :principal ..
;;;;                        :agent .. :conversation ..)
;;;;                        -- an MCP tool call became a task (#532); ID is the tool call's id
;;;;   (:type :task-input-refused .. :methods (..))
;;;;                        -- a task asked for input this client does not provide, and is
;;;;                           cancelled (#532)
;;;;   (:type :task-input-required .. :input-key .. :mode .. :message .. :schema .. :url ..
;;;;                        :task ..)
;;;;                        -- a task asks the user for input through an elicitation the
;;;;                           connection declared (#563): MODE :FORM with SCHEMA, or :URL with
;;;;                           URL. MESSAGE, SCHEMA and URL come from the server and are
;;;;                           untrusted. Answer with MCP:ANSWER-TASK-INPUT and TASK
;;;;   (:type :task-input-expired .. :input-key ..)
;;;;                        -- the app did not answer INPUT-KEY within the connection's
;;;;                           INPUT-TIMEOUT, and the client answered cancel (#563)
;;;;   (:type :task-finished .. :outcome .. :ms ..)
;;;;                        -- a task ended: :OK, :ERROR, :CANCELLED, :EXPIRED or :UNKNOWN
;;;;   (:type :usage        :input .. :output .. :cache-read .. :cache-write ..
;;;;                        :estimated-input ..)
;;;;                        -- the token counts the provider reported for a step (#161). Each
;;;;                           count is as reported: NIL means the provider did not report it,
;;;;                           0 that it reported none. ESTIMATED-INPUT is the estimate the
;;;;                           history budget was enforced against. Not emitted when the
;;;;                           provider reported no counts at all
;;;;   (:type :image-usage  :id .. :principal .. :agent .. :provider .. :model .. :count ..
;;;;                        :size .. :quality .. [:input-tokens ..] [:output-tokens ..] [:cost ..]
;;;;                        [:estimated t])
;;;;                        -- an image request succeeded (praxeon/image, #758). ID is the tool
;;;;                           call's, the same as on its :TOOL-RESULT, and PRINCIPAL and AGENT
;;;;                           are as there; each is NIL outside a turn. PROVIDER and
;;;;                           MODEL are strings, COUNT the number of images returned, SIZE and
;;;;                           QUALITY as the provider reported them, or as requested when it
;;;;                           did not. The token counts are present only when the provider
;;;;                           reported them. COST is in US dollars, as a rational, and is
;;;;                           present when the provider reported it or praxeon computed it from
;;;;                           a price table, in which case :ESTIMATED is T (praxeon/image's
;;;;                           *OPENAI-IMAGE-PRICES*). A COST that is absent is not known, and is
;;;;                           never sent as 0. A refused or failed request emits none,
;;;;                           because the provider reports no usage with an error. Named apart
;;;;                           from :USAGE, which carries a model step's token counts, until #493
;;;;                           settles one usage interface
;;;;   (:type :tool-held    :id .. :held .. :principal .. :name .. :source .. :estimate ..
;;;;                        :at .. :agent .. :conversation ..)
;;;;                        -- a call to a means registered with :CONFIRM is held, and the turn
;;;;                           ends with it held (#531). HELD is the held turn's id, AT a
;;;;                           universal time, ESTIMATE the means' cost estimate or NIL
;;;;   (:type :tool-decided :id .. :held .. :principal .. :name .. :source .. :estimate ..
;;;;                        :at .. :decision .. :agent .. :conversation ..)
;;;;                        -- a call to a means registered with :CONFIRM was decided. HELD is
;;;;                           NIL for a call decided during the turn. DECISION is :APPROVE or
;;;;                           :DECLINE; :NO-CONFIRMATION when nobody could be asked; for a held
;;;;                           call, :EXPIRED or :UNANSWERED (#531), :TURN-FAILED when an
;;;;                           approved call before it failed (#546), or :MAY-HAVE-RUN when an
;;;;                           approval was recorded first by another continuation of the same
;;;;                           held turn, so the call may have run there
;;;;   (:type :result-stored :id .. :name .. :handle .. :tokens .. :offloaded ..)
;;;;                        -- a tool result was put in the agent's result store; OFFLOADED is
;;;;                           true when the history carries a stand-in instead of the result
;;;;   (:type :results-cleared :count .. :estimated-tokens .. :budget .. :target ..)
;;;;                        -- COUNT stored tool results in the history were replaced by
;;;;                           stand-ins to bring it under BUDGET
;;;;   (:type :context-trimmed :dropped-exchanges .. :kept-exchanges .. :pinned-exchanges ..
;;;;                        :estimated-tokens .. :budget ..)
;;;;                        -- the oldest exchanges of the history were left out of the request
;;;;                           to fit BUDGET (praxeon/prompt)
;;;;   (:type :context-overflow :estimated-tokens .. :budget .. :kept-exchanges ..)
;;;;                        -- the pinned exchanges and the newest one do not fit BUDGET; the
;;;;                           request is sent anyway (praxeon/prompt)
;;;;   (:type :delegate     :agent .. :task ..)
;;;;                        -- a sub-agent registered as a means was called; AGENT is its name,
;;;;                           TASK the subtask the model gave it
;;;;   (:type :workflow-start :name .. :end ..)
;;;;   (:type :workflow-step  :name .. :agent ..)
;;;;   (:type :workflow-end   :name ..)
;;;;                        -- a workflow began, ran the step NAME on AGENT, and finished
;;;;                           (praxeon/workflow)
;;;;   (:type :truncated    :step N :max-tokens M :tool-calls (name ..))
;;;;                        -- step N stopped at the output limit M before the model had
;;;;                           finished; its text is not the answer and the named tool calls
;;;;                           were not run. OUTPUT-TRUNCATED is signalled next (#326).
;;;;   (:type :answer       :text ..)                      -- the model's final reply
;;;;   (:type :answer       :text .. :truncated t)         -- cut-off text a handler accepted
;;;;                                                          as the answer (ACCEPT-TRUNCATED)
;;;; Additional event types may appear over time; a renderer should ignore any it
;;;; does not recognize.

(cl:in-package #:praxeon/event)

(defvar *observer* nil
  "A function of one argument -- a progress EVENT (a plist) -- or NIL. When bound,
the actor loop calls it as a turn unfolds so a client can report what the agent is
doing. Bind it with WITH-OBSERVER; NIL disables reporting (zero overhead).

BOUND WITH LET, SO IT IS PER-THREAD, and the failure is quiet in the same way the logging
one is: work fanned out to another thread reads the global NIL, reports nothing, and a
client watching progress simply sees that part of the turn produce no events.")

;; Declared inheritable for the same reason as aion/log:*context* (#158). A thread that
;; continues the current turn should still report progress; one that begins an independent
;; lifetime should not inherit an observer belonging to somebody else's turn.
(aion/dynamic:register-inheritable '*observer*)

(defun emit (type &rest payload)
  "Send an event of TYPE (a keyword) with PAYLOAD (a plist) to *OBSERVER*, if one
is bound. A no-op otherwise. Returns NIL."
  (when *observer*
    (funcall *observer* (list* :type type payload)))
  nil)

(defmacro with-observer ((observer) &body body)
  "Evaluate BODY with OBSERVER (a function of one event, or NIL) receiving every
progress event emitted during it."
  `(let ((*observer* ,observer))
     ,@body))

(defun event-type (event)
  "The keyword type of EVENT."
  (getf event :type))

(defun event-get (event key &optional default)
  "The value of KEY in EVENT, or DEFAULT."
  (getf event key default))

(defun event-plist (event)
  "EVENT as a plist (identity today; a stable accessor for renderers/serializers
in case the representation grows)."
  event)
