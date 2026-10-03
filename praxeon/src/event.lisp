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
;;;;                           :ERROR, :NOT-RUN or :UNKNOWN (see TOOL-ERROR-RESULT); MS the
;;;;                           call's duration. Enough for a usage ledger to record the call
;;;;                           (#527, until #493 settles the usage interface).
;;;;   (:type :sign-in-required :connection .. :principal ..)
;;;;                        -- an MCP tool needs the user to sign in (#527)
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
