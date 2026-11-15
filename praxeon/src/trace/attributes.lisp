;;;; attributes.lisp --- every span attribute name praxeon/trace writes, in one place (#1225).
;;;;
;;;; The gen_ai.* names follow the OpenTelemetry semantic conventions for generative AI
;;;; (https://opentelemetry.io/docs/specs/semconv/gen-ai/). Those conventions are still marked
;;;; as in development, and names in them have been renamed before (gen_ai.system became
;;;; gen_ai.provider.name). When a name changes there, it changes here and nowhere else: the
;;;; rest of praxeon/trace and its tests refer to these variables, never to the strings.
;;;;
;;;; The praxeon.* names are praxeon's own, for facts the conventions have no name for.

(in-package #:praxeon/trace)

;;; --- OpenTelemetry GenAI semantic conventions ------------------------------------------------

(defparameter +operation-name+ "gen_ai.operation.name"
  "invoke_agent for a turn, chat for a model call, execute_tool for a tool call.")
(defparameter +agent-name+ "gen_ai.agent.name"
  "The agent's name, on a turn's span.")
(defparameter +request-model+ "gen_ai.request.model"
  "The model id the provider was asked for (PRAXEON/LLM:MODEL-OF), on turn and chat spans.")
(defparameter +provider-name+ "gen_ai.provider.name"
  "The provider's class name in lower case, such as anthropic or openai-compatible.")
(defparameter +conversation-id+ "gen_ai.conversation.id"
  "The agent's result-store conversation id, when it has one.")
(defparameter +usage-input-tokens+ "gen_ai.usage.input_tokens"
  "Input tokens the provider reported for a model call. Absent when it reported none.")
(defparameter +usage-output-tokens+ "gen_ai.usage.output_tokens"
  "Output tokens the provider reported for a model call. Absent when it reported none.")
(defparameter +usage-cache-read-tokens+ "gen_ai.usage.cache_read.input_tokens"
  "Input tokens served from the provider's prompt cache.")
(defparameter +usage-cache-creation-tokens+ "gen_ai.usage.cache_creation.input_tokens"
  "Input tokens written to the provider's prompt cache.")
(defparameter +response-finish-reasons+ "gen_ai.response.finish_reasons"
  "Why a model call stopped, as a list of one string: tool_calls, stop, length or cancelled.
Worked out from the event that follows the call, because no event carries the provider's stop
reason: a tool call means tool_calls, an answer stop, a :TRUNCATED event length, and a
cancelled turn cancelled.")
(defparameter +tool-name+ "gen_ai.tool.name"
  "The means' name, on an execute_tool span.")
(defparameter +tool-type+ "gen_ai.tool.type"
  "Always function: a means is called with arguments the model chose.")
(defparameter +tool-call-id+ "gen_ai.tool.call.id"
  "The tool call's id, as the model gave it.")
(defparameter +tool-call-arguments+ "gen_ai.tool.call.arguments"
  "CONTENT. The tool call's arguments as JSON. Only with :CAPTURE-CONTENT T.")
(defparameter +tool-call-result+ "gen_ai.tool.call.result"
  "CONTENT. The tool's result text. Only with :CAPTURE-CONTENT T.")
(defparameter +output-messages+ "gen_ai.output.messages"
  "CONTENT. The turn's answer, as the conventions' JSON message list. Only with
:CAPTURE-CONTENT T.")
(defparameter +error-type+ "error.type"
  "On a span with status ERROR: the tool's outcome, or the type of the condition that ended
the turn. A type name, never a condition's report.")

;;; --- praxeon's own ---------------------------------------------------------------------------

(defparameter +step+ "praxeon.step"
  "The step number of a model call within its turn, from 0.")
(defparameter +turn-outcome+ "praxeon.turn.outcome"
  "How a turn ended: answered, cancelled, held, abandoned (a truncated step no handler
accepted), failed (it signalled out of WITH-TRACING) or incomplete (no end event arrived, and
the cause is not known).")
(defparameter +turn-max-steps+ "praxeon.turn.max_steps"
  "The turn's MAX-STEPS.")
(defparameter +tool-outcome+ "praxeon.tool.outcome"
  "The :OUTCOME of the call's :TOOL-RESULT event in lower case (ok, error, not-run, unknown,
started), or held for a call the turn's policy held.")
(defparameter +tool-duration-ms+ "praxeon.tool.duration_ms"
  "The call's duration in milliseconds as the actor measured it (the event's :MS).")
(defparameter +usage-estimated-input-tokens+ "praxeon.usage.estimated_input_tokens"
  "praxeon's estimate of the prompt, the one the history budget was enforced against.")
(defparameter +usage-cancelled+ "praxeon.usage.cancelled"
  "True on a model call a cancel stopped.")
(defparameter +delegate-agent+ "praxeon.delegate.agent"
  "On an execute_tool span that delegated to a sub-agent: the sub-agent's name.")
(defparameter +delegate-task+ "praxeon.delegate.task"
  "CONTENT. The task text a coordinator gave its sub-agent. Only with :CAPTURE-CONTENT T.")

(defparameter +content-attributes+
  (list +tool-call-arguments+ +tool-call-result+ +output-messages+ +delegate-task+)
  "The attributes that hold content. A tracer made without :CAPTURE-CONTENT writes none of them,
and none is written while EVT:*WITHHOLD-CONTENT* is true.")

(defun correlation-attribute (key)
  "The attribute name for the aion/log context field KEY, such as :REQUEST-ID ->
\"praxeon.log.request_id\"."
  (format nil "praxeon.log.~A" (substitute #\_ #\- (string-downcase (symbol-name key)))))
