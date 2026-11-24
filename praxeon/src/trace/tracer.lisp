;;;; tracer.lisp --- spans built from the actor loop's events (#1225).
;;;;
;;;; HOW EVENTS BECOME SPANS. The observer keeps, for each thread, a stack of the spans that
;;;; are open on it, innermost first. The actor loop runs a turn's steps and tool calls on
;;;; the thread that called RUN-TURN, so the events of one turn arrive in order on one
;;;; thread:
;;;;
;;;;   :TURN-STARTED   opens an invoke_agent span. When the innermost open span is an
;;;;                   execute_tool span, the turn is a sub-agent's, and becomes its child.
;;;;                   Otherwise any spans still open on the thread belong to an earlier turn
;;;;                   that ended with no end event (a held turn, an abandoned truncation, or
;;;;                   an error under an observer bound without WITH-TRACING), and are closed
;;;;                   first, at the time of the last event they saw.
;;;;   :DELIBERATING   opens a chat span under the turn.
;;;;   :USAGE          puts the token counts on the chat span and closes it.
;;;;   :TOOL-CALL      closes the chat span if it is still open and opens an execute_tool span
;;;;                   under the turn.
;;;;   :DELEGATE       names the sub-agent on the execute_tool span.
;;;;   :TOOL-RESULT    puts the outcome and duration on the execute_tool span and closes it.
;;;;   :TOOL-HELD      closes the execute_tool span as held, and marks the turn held.
;;;;   :TRUNCATED      marks the chat span's finish reason length, and the turn truncated.
;;;;   :ANSWER         closes the turn as answered.
;;;;   :TURN-ENDED     closes the turn as cancelled.
;;;;
;;;; A chat span's finish reason is set by the event after the model call, because no event
;;;; carries the provider's stop reason (see +RESPONSE-FINISH-REASONS+).
;;;;
;;;; Spans are handed to the exporter when the turn at the root of their trace closes, all of
;;;; that trace's spans at once. Until then a span can still be given an attribute, which is
;;;; what lets a chat span's finish reason be set after the span has ended.
;;;;
;;;; A TURN CONTINUED ON ANOTHER THREAD starts a trace of its own there: a span's parent is
;;;; found on the stack of the thread the event arrives on, and the observer cannot carry a
;;;; parent across a thread, because it is called after the thread has started. praxeon's
;;;; workflow runs parallel steps this way.

(in-package #:praxeon/trace)

;;; --- spans -----------------------------------------------------------------------------------

(defstruct (span (:constructor %make-span))
  "One finished or open span. TRACE-ID is 32 lower-case hex digits, SPAN-ID and PARENT-ID 16;
PARENT-ID is NIL for a root. KIND is :INTERNAL or :CLIENT. START and END are Unix times in
nanoseconds; END is NIL while the span is open. ATTRIBUTES is an alist of (name . value), the
names from attributes.lisp, each value a string, an integer, T or a list of strings. STATUS is
:UNSET, :OK or :ERROR."
  (trace-id "" :type string)
  (span-id "" :type string)
  (parent-id nil)
  (name "" :type string)
  (kind :internal)
  (start 0 :type integer)
  (end nil)
  (attributes '() :type list)
  (status :unset))

(defun span-attribute (span name)
  "The value of the attribute NAME on SPAN, or NIL."
  (cdr (assoc name (span-attributes span) :test #'string=)))

(defun span-duration-ns (span)
  "SPAN's duration in nanoseconds, or NIL while it is open."
  (and (span-end span) (- (span-end span) (span-start span))))

(defun %set-attribute (span name value)
  "Set NAME to VALUE on SPAN, replacing an earlier value. A NIL VALUE sets nothing, because
an attribute that is not known is left out rather than sent empty."
  (when value
    (let ((cell (assoc name (span-attributes span) :test #'string=)))
      (if cell
          (setf (cdr cell) value)
          (setf (span-attributes span) (append (span-attributes span) (list (cons name value)))))))
  span)

(defun %now-ns ()
  "The current Unix time in nanoseconds, to the microsecond."
  (multiple-value-bind (seconds microseconds) (sb-ext:get-time-of-day)
    (+ (* seconds 1000000000) (* microseconds 1000))))

(defun %trace-id ()
  "128 bits from the OS random source, as OTLP wants a trace id. All zeros is not a valid id."
  (loop for id = (aion/random:random-hex 128)
        unless (every (lambda (c) (char= c #\0)) id) return id))

(defun %span-id ()
  "64 bits from the OS random source, as OTLP wants a span id."
  (loop for id = (aion/random:random-hex 64)
        unless (every (lambda (c) (char= c #\0)) id) return id))

;;; --- frames: what the observer knows about an open span --------------------------------------

(defstruct (trace-buffer (:constructor %make-trace-buffer))
  "The spans of one trace that have ended, newest first, until its root turn ends."
  (spans '()))

(defstruct (frame (:constructor %make-frame))
  "An open span on a thread's stack. ROLE is :TURN, :CHAT or :TOOL. BUFFER is the trace's.
LAST-SEEN is the time of the last event that arrived while the frame was open, and is the end
time of a frame closed without its own end event. The rest is for a turn: its MODEL and
PROVIDER, whether a call was HELD or a step TRUNCATED, the open CHAT frame, and the LAST-CHAT
span, whose finish reason the next event sets. ID is a tool call's id."
  span role buffer (last-seen 0) id
  model provider held truncated chat last-chat)

(defstruct (thread-state (:constructor %make-thread-state))
  (stack '()))

;;; --- the tracer ------------------------------------------------------------------------------

(defvar *correlation-keys* '(:request-id :job-id :conversation-id)
  "The aion/log context fields (AION/LOG:*CONTEXT*) a turn's span records, each under
CORRELATION-ATTRIBUTE's name, so a log line and a trace can be joined. hyperion binds
:REQUEST-ID for every HTTP request.")

(defstruct (tracer (:constructor %make-tracer))
  "Turns a thread's events into spans and hands each finished trace to EXPORTER. Make one with
MAKE-TRACER and use it with WITH-TRACING or TRACER-OBSERVER. FAILURES counts events the
tracer could not record; each is logged, and none reaches the turn."
  exporter
  (capture-content nil)
  (correlation-keys *correlation-keys*)
  (states (make-hash-table :test 'eq :weakness :key :synchronized t))
  (failures 0))

(defun make-tracer (&key (exporter (make-memory-exporter)) capture-content
                         (correlation-keys *correlation-keys*))
  "A tracer that hands finished traces to EXPORTER, a MEMORY-EXPORTER unless given.

CAPTURE-CONTENT true puts content on the spans: a tool call's arguments and result, a delegated
task and the turn's answer (+CONTENT-ATTRIBUTES+). It is NIL by default, and while
EVT:*WITHHOLD-CONTENT* is true, as it is in a private agent's turn, no content is recorded
whatever it says. CORRELATION-KEYS are the aion/log context fields a turn's span records."
  (%make-tracer :exporter exporter :capture-content capture-content
                :correlation-keys correlation-keys))

(defun %state (tracer)
  (let ((states (tracer-states tracer))
        (thread (bt:current-thread)))
    (or (gethash thread states)
        (setf (gethash thread states) (%make-thread-state)))))

(defun %content (tracer value)
  "VALUE when the tracer may record content and the event carried it, else NIL."
  (and (tracer-capture-content tracer)
       (not evt:*withhold-content*)
       value
       (not (eq value :withheld))
       value))

(defun %json-text (value)
  "VALUE as a string for an attribute: itself when it is a string, else as JSON."
  (if (stringp value)
      value
      (handler-case (jzon:stringify value)
        (error () (princ-to-string value)))))

(defun %open (state role name kind parent now &key id)
  "Open a span of ROLE under the frame PARENT, or as a new root when PARENT is NIL, push its
frame on STATE's stack and return the frame."
  (let* ((span (%make-span :trace-id (if parent (span-trace-id (frame-span parent)) (%trace-id))
                           :span-id (%span-id)
                           :parent-id (and parent (span-span-id (frame-span parent)))
                           :name name :kind kind :start now))
         (frame (%make-frame :span span :role role :id id :last-seen now
                             :buffer (if parent (frame-buffer parent) (%make-trace-buffer)))))
    (push frame (thread-state-stack state))
    frame))

(defun %deliver (tracer spans)
  "Hand SPANS to the tracer's exporter. A failure is logged, counted, and goes no further."
  (handler-case (export-spans (tracer-exporter tracer) spans)
    (error (e)
      (log:warn "praxeon/trace: the exporter failed" :spans (length spans)
                                                     :condition (log:condition-type e)))))

(defun %close (tracer state frame end)
  "End FRAME's span at END and take it off STATE's stack, with every frame above it, which
end at the time of the last event they saw. When FRAME is a root, its trace goes to the
exporter."
  (loop for top = (first (thread-state-stack state))
        while (and top (not (eq top frame)))
        do (%close-unended tracer state top :incomplete nil))
  (pop (thread-state-stack state))
  (let ((span (frame-span frame)))
    (setf (span-end span) (max end (span-start span)))
    (push span (trace-buffer-spans (frame-buffer frame)))
    (when (null (span-parent-id span))
      (%deliver tracer (reverse (trace-buffer-spans (frame-buffer frame))))
      (setf (trace-buffer-spans (frame-buffer frame)) '()))))

(defun %end-turn (tracer state frame end outcome &key (status :unset) error-type)
  "Close the turn FRAME, which ended with OUTCOME, and its open chat span."
  (let ((span (frame-span frame)))
    (%set-attribute span +turn-outcome+ outcome)
    (setf (span-status span) status)
    (%set-attribute span +error-type+ error-type)
    (%close tracer state frame end)))

(defun %close-unended (tracer state frame reason error-type)
  "Close FRAME, which got no end event of its own, at its LAST-SEEN time. REASON is :FAILED
when the code that ran it signalled out of WITH-TRACING, and otherwise :INCOMPLETE. A turn's
outcome is held or abandoned when its events said so."
  (let ((end (frame-last-seen frame)))
    (case (frame-role frame)
      (:turn
       (cond ((eq reason :failed)
              (%end-turn tracer state frame end "failed" :status :error
                                                         :error-type (or error-type "_OTHER")))
             ((frame-held frame) (%end-turn tracer state frame end "held"))
             ((frame-truncated frame) (%end-turn tracer state frame end "abandoned"))
             (t (%end-turn tracer state frame end "incomplete"))))
      (t
       (when (eq reason :failed)
         (setf (span-status (frame-span frame)) :error)
         (%set-attribute (frame-span frame) +error-type+ (or error-type "_OTHER")))
       (%close tracer state frame end)))))

(defun %close-all (tracer state reason &optional error-type)
  "Close every frame on STATE's stack, innermost first."
  (loop for top = (first (thread-state-stack state))
        while top
        do (%close-unended tracer state top reason error-type)))

(defun %turn (state)
  "The innermost open turn frame on STATE's stack, or NIL."
  (find :turn (thread-state-stack state) :key #'frame-role))

(defun %finish-reason (turn reason)
  "Set the finish reason of TURN's last model call to REASON, unless one is set."
  (let ((chat (frame-last-chat turn)))
    (when (and reason chat (null (span-attribute chat +response-finish-reasons+)))
      (%set-attribute chat +response-finish-reasons+ (list reason)))))

(defun %settle-chat (tracer state turn now reason)
  "The model call before this event is over: close TURN's chat span if it is still open, and
give it REASON as its finish reason."
  (let ((chat (frame-chat turn)))
    (when chat
      (setf (frame-chat turn) nil)
      (when (member chat (thread-state-stack state))
        (%close tracer state chat now))))
  (%finish-reason turn reason))

;;; --- one handler per event type --------------------------------------------------------------

(defun %on-turn-started (tracer state event now)
  (let* ((top (first (thread-state-stack state)))
         (parent (and top (eq (frame-role top) :tool) top)))
    (unless parent
      (%close-all tracer state :incomplete))
    (let* ((agent (evt:event-get event :agent))
           (frame (%open state :turn (format nil "invoke_agent~@[ ~A~]" agent) :internal parent
                         now))
           (span (frame-span frame)))
      (setf (frame-model frame) (evt:event-get event :model)
            (frame-provider frame) (evt:event-get event :provider))
      (%set-attribute span +operation-name+ "invoke_agent")
      (%set-attribute span +agent-name+ agent)
      (%set-attribute span +request-model+ (frame-model frame))
      (%set-attribute span +provider-name+ (frame-provider frame))
      (%set-attribute span +conversation-id+ (let ((c (evt:event-get event :conversation)))
                                              (and c (princ-to-string c))))
      (%set-attribute span +turn-max-steps+ (evt:event-get event :max-steps))
      ;; The aion/log correlation id, read here because the observer runs in the turn's own
      ;; dynamic environment.
      (dolist (key (tracer-correlation-keys tracer))
        (let ((value (getf log:*context* key)))
          (when value
            (%set-attribute span (correlation-attribute key) (princ-to-string value))))))))

(defun %on-deliberating (tracer state event now)
  (let ((turn (%turn state)))
    (when turn
      (%settle-chat tracer state turn now nil)
      (let* ((model (frame-model turn))
             (chat (%open state :chat (format nil "chat~@[ ~A~]" model) :client turn now))
             (span (frame-span chat)))
        (setf (frame-chat turn) chat
              (frame-last-chat turn) span)
        (%set-attribute span +operation-name+ "chat")
        (%set-attribute span +request-model+ model)
        (%set-attribute span +provider-name+ (frame-provider turn))
        (%set-attribute span +step+ (evt:event-get event :step))))))

(defun %on-usage (tracer state event now)
  (let ((turn (%turn state)))
    (when turn
      (let ((span (or (and (frame-chat turn) (frame-span (frame-chat turn)))
                      (frame-last-chat turn))))
        (when span
          (%set-attribute span +usage-input-tokens+ (evt:event-get event :input))
          (%set-attribute span +usage-output-tokens+ (evt:event-get event :output))
          (%set-attribute span +usage-cache-read-tokens+ (evt:event-get event :cache-read))
          (%set-attribute span +usage-cache-creation-tokens+ (evt:event-get event :cache-write))
          (%set-attribute span +usage-estimated-input-tokens+
                          (evt:event-get event :estimated-input))
          (when (evt:event-get event :cancelled)
            (%set-attribute span +usage-cancelled+ t)
            (%finish-reason turn "cancelled"))))
      (%settle-chat tracer state turn now nil))))

(defun %on-tool-call (tracer state event now)
  (let ((turn (%turn state)))
    (when turn
      (%settle-chat tracer state turn now "tool_calls")
      (let* ((name (evt:event-get event :name))
             (tool (%open state :tool (format nil "execute_tool~@[ ~A~]" name) :internal turn now
                          :id (evt:event-get event :id)))
             (span (frame-span tool)))
        (%set-attribute span +operation-name+ "execute_tool")
        (%set-attribute span +tool-name+ name)
        (%set-attribute span +tool-type+ "function")
        (%set-attribute span +tool-call-id+ (evt:event-get event :id))
        (let ((arguments (%content tracer (evt:event-get event :arguments))))
          (when arguments
            (%set-attribute span +tool-call-arguments+ (%json-text arguments))))))))

(defun %tool-frame (state id)
  (find-if (lambda (f) (and (eq (frame-role f) :tool) (equal (frame-id f) id)))
           (thread-state-stack state)))

(defun %on-tool-result (tracer state event now)
  (let* ((id (evt:event-get event :id))
         (frame (%tool-frame state id))
         (turn (%turn state)))
    ;; A result with no open call, as for a call whose :TOOL-CALL was sent before a cleanup
    ;; closed its span, still gets a span of its own, of no length.
    (when (and (null frame) turn)
      (%on-tool-call tracer state (list* :type :tool-call :arguments nil event) now)
      (setf frame (%tool-frame state id)))
    (when frame
      (let* ((span (frame-span frame))
             (outcome (evt:event-get event :outcome))
             (failed (or (evt:event-get event :is-error) (member outcome '(:error :unknown)))))
        (%set-attribute span +tool-outcome+ (and outcome (string-downcase (symbol-name outcome))))
        (%set-attribute span +tool-duration-ms+ (evt:event-get event :ms))
        (let ((result (%content tracer (evt:event-get event :content))))
          (when result
            (%set-attribute span +tool-call-result+ (%json-text result))))
        (when failed
          (setf (span-status span) :error)
          (%set-attribute span +error-type+
                          (if outcome (string-downcase (symbol-name outcome)) "error")))
        (%close tracer state frame now)))))

(defun %on-tool-held (tracer state event now)
  (let ((turn (%turn state))
        (frame (%tool-frame state (evt:event-get event :id))))
    (when turn (setf (frame-held turn) t))
    (when frame
      (%set-attribute (frame-span frame) +tool-outcome+ "held")
      (%close tracer state frame now))))

(defun %on-delegate (tracer state event now)
  (declare (ignore now))
  (let ((top (first (thread-state-stack state))))
    (when (and top (eq (frame-role top) :tool))
      (%set-attribute (frame-span top) +delegate-agent+ (evt:event-get event :agent))
      (let ((task (%content tracer (evt:event-get event :task))))
        (when task
          (%set-attribute (frame-span top) +delegate-task+ (%json-text task)))))))

(defun %on-truncated (tracer state event now)
  (declare (ignore event))
  (let ((turn (%turn state)))
    (when turn
      (setf (frame-truncated turn) t)
      (%settle-chat tracer state turn now "length"))))

(defun %answer-messages (text)
  "TEXT as the GenAI conventions' output message list, in JSON."
  (let ((part (make-hash-table :test 'equal))
        (message (make-hash-table :test 'equal)))
    (setf (gethash "type" part) "text"
          (gethash "content" part) text
          (gethash "role" message) "assistant"
          (gethash "parts" message) (vector part))
    (jzon:stringify (vector message))))

(defun %on-answer (tracer state event now)
  (let ((turn (%turn state)))
    (when turn
      (%settle-chat tracer state turn now (if (evt:event-get event :truncated) "length" "stop"))
      (let ((text (%content tracer (evt:event-get event :text))))
        (when text
          (%set-attribute (frame-span turn) +output-messages+ (%answer-messages text))))
      (%end-turn tracer state turn now "answered"))))

(defun %on-turn-ended (tracer state event now)
  (declare (ignore event))
  (let ((turn (%turn state)))
    (when turn
      (%settle-chat tracer state turn now "cancelled")
      (%end-turn tracer state turn now "cancelled"))))

(defun %record (tracer event)
  "Update TRACER's spans on this thread for EVENT."
  (let ((state (%state tracer))
        (now (%now-ns)))
    (dolist (frame (thread-state-stack state))
      (setf (frame-last-seen frame) now))
    (case (evt:event-type event)
      (:turn-started (%on-turn-started tracer state event now))
      (:deliberating (%on-deliberating tracer state event now))
      (:usage (%on-usage tracer state event now))
      (:tool-call (%on-tool-call tracer state event now))
      (:tool-result (%on-tool-result tracer state event now))
      (:tool-held (%on-tool-held tracer state event now))
      (:delegate (%on-delegate tracer state event now))
      (:truncated (%on-truncated tracer state event now))
      (:answer (%on-answer tracer state event now))
      (:turn-ended (%on-turn-ended tracer state event now)))))

;;; --- the observer ----------------------------------------------------------------------------

(defun tracer-observer (tracer &optional next)
  "An observer (a function of one event, for EVT:*OBSERVER*) that records spans for TRACER and
then passes the event to NEXT, the observer it is composed with, when there is one.

A failure while recording is logged with the event's type and the tracer's count of failures,
and goes no further: tracing never fails a turn. A failure in NEXT reaches the turn as it would
without tracing."
  (lambda (event)
    (handler-case (%record tracer event)
      (error (e)
        (log:warn "praxeon/trace: an event could not be recorded"
                  :event-type (evt:event-type event)
                  :failures (incf (tracer-failures tracer))
                  :condition (log:condition-type e))))
    (when next (funcall next event))))

(defvar *active-tracers* '()
  "The tracers WITH-TRACING has bound on this thread, so a nested WITH-TRACING for the same
tracer does not record every event twice.")

(defun call-with-tracing (tracer function)
  "Call FUNCTION with TRACER recording the turns it runs, on top of any observer already bound.
When FUNCTION returns or exits, the spans still open on this thread are closed: as failed, with
status ERROR and the condition's type, when it exited after an error was signalled, and
otherwise as the events left them (held, abandoned or incomplete)."
  (if (member tracer *active-tracers*)
      (funcall function)
      (let ((returned nil)
            (error-type nil)
            (*active-tracers* (cons tracer *active-tracers*)))
        (unwind-protect
             (handler-bind ((error (lambda (c) (setf error-type (log:condition-type c)))))
               (multiple-value-prog1
                   (evt:with-observer ((tracer-observer tracer evt:*observer*))
                     (funcall function))
                 (setf returned t)))
          (handler-case
              (%close-all tracer (%state tracer) (if returned :incomplete :failed) error-type)
            (error (e)
              (log:warn "praxeon/trace: open spans could not be closed"
                        :failures (incf (tracer-failures tracer))
                        :condition (log:condition-type e))))))))

(defmacro with-tracing ((tracer) &body body)
  "Run BODY with TRACER recording a span tree for every turn run in it. See CALL-WITH-TRACING."
  `(call-with-tracing ,tracer (lambda () ,@body)))
