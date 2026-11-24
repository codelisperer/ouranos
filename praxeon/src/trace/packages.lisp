;;;; packages.lisp --- praxeon/trace: OpenTelemetry spans from a turn's events (#1225).

(defpackage #:praxeon/trace
  (:use #:cl)
  (:local-nicknames (#:evt #:praxeon/event)
                    (#:log #:aion/log)
                    (#:http #:aion/http-client)
                    (#:jzon #:com.inuoe.jzon))
  (:documentation
   "OpenTelemetry spans for an agent's turns, built from the events the actor loop already
emits (praxeon/event), and exporters that send them to a collector.

A TRACER holds an exporter and the spans that are open. WITH-TRACING binds an observer for
the tracer around a body, so every turn run inside it produces a span tree: one invoke_agent
span per turn, a chat span per model call and an execute_tool span per tool call, with a
sub-agent's turn as a child of the tool call that delegated to it. Spans carry names, ids,
counts and durations, and no prompt, tool argument, tool result or reply unless the tracer
is made with :CAPTURE-CONTENT T. EVT:*WITHHOLD-CONTENT* always wins over that setting.

Exporters: MEMORY-EXPORTER keeps finished spans in the image, for tests and the REPL.
OTLP-EXPORTER sends them as OTLP/HTTP JSON to a collector's /v1/traces, in batches, from a
thread of its own, so a slow or failing collector never delays or fails a turn.")
  (:export
   ;; attribute names (attributes.lisp)
   #:+operation-name+ #:+agent-name+ #:+request-model+ #:+provider-name+ #:+conversation-id+
   #:+usage-input-tokens+ #:+usage-output-tokens+ #:+usage-cache-read-tokens+
   #:+usage-cache-creation-tokens+ #:+response-finish-reasons+
   #:+tool-name+ #:+tool-type+ #:+tool-call-id+ #:+tool-call-arguments+ #:+tool-call-result+
   #:+output-messages+ #:+error-type+
   #:+step+ #:+turn-outcome+ #:+turn-max-steps+ #:+tool-outcome+ #:+tool-duration-ms+
   #:+usage-estimated-input-tokens+ #:+usage-cancelled+ #:+delegate-agent+ #:+delegate-task+
   #:+content-attributes+ #:correlation-attribute
   ;; spans
   #:span #:span-p #:span-trace-id #:span-span-id #:span-parent-id #:span-name #:span-kind
   #:span-start #:span-end #:span-attributes #:span-status #:span-attribute
   #:span-duration-ns
   ;; the tracer
   #:tracer #:make-tracer #:tracer-exporter #:tracer-capture-content #:tracer-failures
   #:tracer-observer #:with-tracing #:call-with-tracing #:*correlation-keys*
   ;; exporters
   #:export-spans #:flush-exporter #:shutdown-exporter
   #:memory-exporter #:make-memory-exporter #:exported-spans #:clear-exported
   #:otlp-exporter #:make-otlp-exporter #:make-otlp-exporter-from-env
   #:otlp-exporter-endpoint #:otlp-exporter-sent-spans #:otlp-exporter-failed-batches
   #:otlp-exporter-failed-spans #:otlp-exporter-dropped-spans
   #:otlp-json #:otlp-document))
