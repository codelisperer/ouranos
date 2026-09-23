;;;; actor.lisp --- the dynamic shell: the deliberate / act loop
;;;;
;;;; The Coalton `Actor` (see praxeology.lisp) describes what an agent *is*; the
;;;; CL `agent` here is the runtime. It owns effects, the provider connection,
;;;; the growing conversation history, and the means registry mapping a means'
;;;; name to the CL function that performs it.
;;;;
;;;; One turn now closes the loop: perceive -> deliberate (ask the provider,
;;;; advertising the registered means as tools) -> if the model chose one or more
;;;; means, ACT on each (under recovery restarts) and feed the results back ->
;;;; deliberate again -> repeat until the model answers with no further tool
;;;; call. Deliberation and application both speak the provider-neutral
;;;; vocabulary in praxeon/llm, so any provider drives the same loop.

(cl:in-package #:praxeon/actor)

(defstruct (means-entry (:constructor make-means-entry))
  "A registered means: its NAME, human DESCRIPTION, argument SCHEMA (a
jzon-serializable JSON-schema value or NIL), the FN that performs it, and the CAPABILITY a
caller must hold to see it at all.

CAPABILITY is a string or NIL (#90). NIL means unrestricted -- every means registered
before this existed is unrestricted, and stays so. A means that names a capability is
ABSENT from the tool table unless something permits it: see AGENT-TOOL-SPECS."
  (name "" :type string)
  (description "" :type string)
  (schema nil)
  (capability nil)
  (fn nil))

(defstruct (agent (:constructor make-agent))
  "A runtime agent.

TWO BUDGETS, over two kinds of data (pre-publication issue 402, ADR-0001). CONTEXT budgets RETRIEVED
FACTS -- independent items, ranked by value density and chosen by `ctx:assemble'.
HISTORY-BUDGET bounds what the CONVERSATION costs to resend: an estimated token
ceiling on the messages a deliberation sends, applied by
`prompt:trim-history' at send time. The two numbers are not comparable, which is
why there are two of them: one bounds a cost that grows with conversation length,
the other how much retrieved material one turn is worth paying for.

HISTORY is the RECORD and is never trimmed -- trimming decides what is SENT. A
client rendering `agent-history' still shows the whole conversation."
  (name "agent" :type string)
  (provider nil)                          ; a praxeon/llm:provider
  (system-prompt "" :type string)
  ;; CACHE-SYSTEM (pre-publication issue 437): send the system prompt as a marked part, so the provider caches the
  ;; prefix it sits in. NIL by default, and the default is the decision -- a prefix cache is a
  ;; billing behaviour, and one that arrived without being asked for would be a surprise in a
  ;; line item. See DELIBERATE for what it does and what it deliberately does not reach.
  (cache-system nil)
  (means (make-hash-table :test #'equal)) ; name(string) -> means-entry
  (context (ctx:make-context) :type ctx:context)
  ;; 120000 ESTIMATED tokens, not NIL, and the default is the decision. An opt-in bound
  ;; that no existing agent opts into leaves every consumer resending its whole history
  ;; every turn -- the quadratic cost pre-publication issue 402 was filed about -- and leaves the trim with no
  ;; caller in practice. Sized for a 200k-token window with room for the system prompt,
  ;; the tool table, the retrieved facts and the model's own output; an estimate can read
  ;; LOW (see `prompt:*chars-per-token*'), so the headroom is deliberate. NIL means send
  ;; everything, for a caller that bounds its context some other way.
  (history-budget 120000)
  (history '() :type list))               ; list of praxeon/llm messages

(defun register-means (agent name description fn &key schema capability)
  "Register a means under NAME: a human DESCRIPTION, the FN performing it (a
function of one argument -- the tool arguments -- returning a string), an
optional argument SCHEMA (a jzon-serializable JSON-schema value), and an optional
CAPABILITY string a caller must hold to see or use it (#90). Returns NAME."
  (setf (gethash name (agent-means agent))
        (make-means-entry :name name :description description
                          :schema schema :capability capability :fn fn))
  name)

(defun means-permitted-p (entry permit)
  "May a caller described by PERMIT use ENTRY?

PERMIT is a function of one capability string returning a boolean, or NIL for \"no
authority supplied\". The three cases, and the middle one is the security decision:

  entry has no capability   -> yes. Unrestricted means stay unrestricted.
  entry HAS one, PERMIT NIL -> NO. A means that names a capability is not available to a
                               caller who presented no authority at all. Fail closed: the
                               alternative makes the property depend on every call site
                               remembering to pass something.
  otherwise                 -> ask PERMIT.

A PREDICATE rather than a grant, deliberately. praxeon/ceiling knows what a grant is and
how to verify one; this module knows what a means is. Passing the question in as a function
keeps the tool catalogue free of any notion of tokens, signatures or principals, and lets a
host that authorises some other way use the same machinery."
  (let ((capability (means-entry-capability entry)))
    (cond ((null capability) t)
          ((null permit) nil)
          (t (and (funcall permit capability) t)))))

(defun agent-means-for (agent &key permit)
  "The MEANS-ENTRYs a caller described by PERMIT may use -- the tool table, ASSEMBLED.

This is the property #90 asks for and the one praxeon/ceiling's docstring already claimed:
a means the caller may not use is ABSENT, not filtered later. Nothing downstream -- no
prompt, no model output, no injected instruction -- can reach a means that was never
advertised, because refusing it is not a decision anything makes at call time. It is a
table that does not contain it."
  (loop for e being the hash-values of (agent-means agent)
        when (means-permitted-p e permit) collect e))

(defun agent-tool-specs (agent &key permit)
  "The means a caller described by PERMIT may use, as provider-neutral tool specs.

With no PERMIT this is every UNRESTRICTED means -- which is every means registered before
capabilities existed, so existing agents are unchanged."
  (loop for e in (agent-means-for agent :permit permit)
        collect (llm:make-tool-spec :name (means-entry-name e)
                                    :description (means-entry-description e)
                                    :schema (means-entry-schema e))))

(defun request-messages (agent)
  "The messages a deliberation SENDS. Returns (values messages estimated-tokens).

Not `agent-history', and the difference is the whole of pre-publication issue 402 (ADR-0001):

  - the history is TRIMMED to AGENT-HISTORY-BUDGET by `prompt:trim-history' --
    whole exchanges from the oldest end, never through the cacheable prefix (pre-publication issue 401);
  - the agent's context items are ASSEMBLED by `ctx:assemble' -- the highest-value
    retrieved facts that fit ITS budget -- and placed AFTER that prefix, because
    facts change every turn and caching them would invalidate the cache each time.

Nothing is mutated: the agent's history is the record, this is the request, and the
facts are never written back into the conversation (which would make them
permanent, and pay for them on every later turn)."
  (let* ((trimmed (prompt:trim-history (agent-history agent)
                                       (agent-history-budget agent)))
         (facts (prompt:render-items (ctx:assemble (agent-context agent))))
         (messages (if facts
                       (prompt:attach-context trimmed facts)
                       trimmed)))
    (values messages (prompt:messages-tokens messages))))

(defun agent-system-parts (agent)
  "The agent's system prompt as PRAXEON/LLM wants it: a plain string, or -- when
AGENT-CACHE-SYSTEM is set -- a one-part list whose part is marked as the end of the cacheable
prefix (pre-publication issue 401, pre-publication issue 437).

THE FIRST PRODUCER OF A MARKED PREFIX IN THIS TREE, and pre-publication issue 437 is the finding that there was
none: `:cache t' had four consumers (the pinning in praxeon/prompt, the Anthropic translation,
the OpenAI drop, the counts on the completion), a constructor in `llm:text-part', and no caller
anywhere outside the suite. The cause was a TYPE: this slot was read straight out of
`agent-system-prompt', which is declared a STRING, so the one thing an agent has that is large,
stable and byte-identical every turn could not carry a marker. A surface can be complete,
tested, documented as load-bearing and unreachable.

WHAT THIS CACHES, exactly, because the answer is smaller than it looks. A provider renders its
prefix as TOOLS, then SYSTEM, then MESSAGES, so a boundary at the end of the system prompt
caches the tools and the system prompt and NOTHING ELSE. That is the right first producer,
because it is the shape a consuming app is starting with -- one large shared brief and many
short completions -- and it is where the measurement that opened pre-publication issue 401 came from (574 input
tokens for a one-line question against an EMPTY history, essentially all prefix).

WHAT IT DOES NOT DO, said here so nobody reads more into it: the conversation is not cached.
A long history is still resent and still charged in full every turn, because nothing marks a
boundary inside MESSAGES. That is a second producer and a separate decision -- and it is the
one where `prompt:pinned-exchange-count' becomes load-bearing, which corrects an argument I
made when this shape was chosen: I said the boundary interacts with history trimming, and under
THIS producer it does not. The pinning scans messages; the marker is not in them, so
PINNED-EXCHANGE-COUNT returns 0 on the actor path. Asserted in the suite so that when a message
breakpoint does arrive, the test says what changed rather than passing quietly.

AN EMPTY PROMPT IS NOT MARKED. Marking nothing is not a prefix, and it would put a
`cache_control' block on an empty string for a provider to reject or ignore.

A SHORT PROMPT MAY NOT CACHE AT ALL, and that is the provider's rule rather than this
function's: Anthropic has a minimum cacheable prefix (model-dependent, of the order of a
thousand tokens) and silently does not cache below it. Nothing here can detect that, and
nothing should pretend to -- what tells you is COMPLETION-CACHE-READ-TOKENS coming back 0
rather than NIL, which is the distinction pre-publication issue 401 paid for and pre-publication issue 417 carried into the ledger."
  (let ((prompt (agent-system-prompt agent)))
    (if (and (agent-cache-system agent) (plusp (length prompt)))
        (list (llm:text-part prompt :cache t))
        prompt)))

(defun deliberate (agent &key permit)
  "Ask the provider for the agent's next move given its current history,
advertising the means PERMIT allows as tools. Returns (values COMPLETION
ESTIMATED-INPUT-TOKENS). Signals DELIBERATION-FAILURE when no provider is configured.

What is sent is REQUEST-MESSAGES, not the raw history -- trimmed to the agent's
history budget with its retrieved facts placed after the cacheable prefix (pre-publication issue 402).
The estimate comes back as a second value so the caller can put it beside the
provider's reported input tokens: ours is a claim, the provider's is the measurement,
and a budget enforced against an estimate nobody compares is how a bound silently
stops bounding.

PERMIT is passed to AGENT-TOOL-SPECS, so a means the caller may not use is never described
to the model at all (#90)."
  (unless (agent-provider agent)
    (error 'cnd:deliberation-failure :detail "no provider configured"))
  (multiple-value-bind (messages estimate) (request-messages agent)
    (values (llm:complete (agent-provider agent)
                          messages
                          :system (agent-system-parts agent)
                          :tools (agent-tool-specs agent :permit permit))
            estimate)))

(defun act (agent means-name argument &key permit)
  "Apply a registered means by name to ARGUMENT, establishing recovery restarts.
Returns the means' result, or a substituted / abandoned value.

PERMIT is re-checked HERE as well as at advertisement time, and that is defence in depth
rather than belt-and-braces (#90). A model can name a tool it was never offered -- from
its training, from an injected instruction, from a stale history -- and an agent can be
handed to a workflow that advertises a different table than the one it invokes through. The
question `may this caller use this means' has to be answerable at the moment of use, not
only at the moment of listing."
  (let ((entry (gethash means-name (agent-means agent))))
    (unless entry
      (error 'cnd:means-failure :means means-name
                                :cause "no such means registered"))
    (unless (means-permitted-p entry permit)
      ;; Deliberately the same shape of failure as an unknown means. A caller who may not
      ;; use a means learns nothing from the refusal that they could not learn by guessing
      ;; a name -- so the reply cannot be used to enumerate what exists.
      (error 'cnd:means-failure :means means-name
                                :cause "no such means registered"))
    (let ((fn (means-entry-fn entry)))
      ;; Restart names must be the *exported* condition symbols so the invokers
      ;; in praxeon/conditions (which FIND-RESTART on those symbols) can locate
      ;; them -- a bare RETRY-ACTION here would be praxeon/actor::retry-action, a
      ;; different symbol, and recovery would silently never fire.
      (restart-case
          (handler-case (funcall fn argument)
            (error (e)
              (error 'cnd:means-failure :means means-name :cause e)))
        (cnd:retry-action ()
          :report "Re-attempt this means."
          ;; PERMIT travels with the retry. Without it a recovery restart would re-enter
          ;; with no authority and be refused -- or, had the default been permissive,
          ;; would have re-entered with MORE authority than the original call.
          (act agent means-name argument :permit permit))
        (cnd:substitute-result (value)
          :report "Supply a replacement result."
          :interactive (lambda () (list (read-line)))
          value)
        (cnd:abandon-action ()
          :report "Give up on this action."
          nil)))))

(defun %assistant-message (completion)
  "Render COMPLETION as a neutral assistant message: any text, then one tool-use
part per requested call."
  (let ((parts '()))
    (when (plusp (length (llm:completion-text completion)))
      (push (llm:text-part (llm:completion-text completion)) parts))
    (dolist (call (llm:completion-tool-calls completion))
      (push (llm:tool-use-part (llm:tool-call-id call)
                               (llm:tool-call-name call)
                               (llm:tool-call-arguments call))
            parts))
    (llm:msg "assistant" (nreverse parts))))

(defun %result-string (result)
  "Coerce a means result to the string a tool-result part carries."
  (cond ((stringp result) result)
        (result (princ-to-string result))
        (t "(no result)")))

(defun %tool-results-message (agent calls &key permit)
  "Apply each requested CALL via ACT and gather the results into a neutral user
message of tool-result parts, emitting a :tool-call / :tool-result event around
each so a client can report progress."
  (llm:msg "user"
           (mapcar
            (lambda (call)
              (let ((id (llm:tool-call-id call))
                    (name (llm:tool-call-name call))
                    (args (llm:tool-call-arguments call)))
                (evt:emit :tool-call :id id :name name :arguments args)
                (let ((result (%result-string (act agent name args :permit permit))))
                  (evt:emit :tool-result :id id :name name :content result)
                  (llm:tool-result-part id result))))
            calls)))

(defun %append-history (agent &rest messages)
  (setf (agent-history agent) (append (agent-history agent) messages)))

(defun run-turn (agent user-input &key (max-steps 8) permit)
  "Run one full turn: record USER-INPUT, then deliberate and act until the model
replies with no further tool call. Returns the model's final text. MAX-STEPS
bounds the deliberate/act cycle so a misbehaving loop stays finite.

PERMIT IS THE CALLER'S AUTHORITY and it travels to both halves of the loop -- the tool table
the model is shown (DELIBERATE) and the check at the moment of use (ACT). Without it, a means
that names a capability is invisible and uninvocable, which is the fail-closed rule of #90
working as designed.

IT WAS MISSING UNTIL pre-publication issue 400, and the consequence was not a missing convenience: `run-turn' is the
framework's main entry point, so EVERY capability-bearing means was unreachable through it. An
app could register one, see it refused as `no such means registered\', and have no way to pass
the authority that would permit it short of driving DELIBERATE and ACT by hand. Found by writing
ADR-0002's own example and watching the turn loop refuse the means the ADR recommends -- the
pattern was unexecutable through the path every reader would use."
  (%append-history agent (llm:msg "user" user-input))
  (dotimes (step max-steps
                 (error 'cnd:deliberation-failure
                        :detail (format nil "no final answer within ~A steps"
                                        max-steps)))
    (evt:emit :deliberating :step step)
    (multiple-value-bind (completion estimate) (deliberate agent :permit permit)
      ;; Economic calculation: report what this step cost so the scarce resource
      ;; (the token budget) is visible. :ESTIMATED-INPUT is what the history budget was
      ;; enforced against and :INPUT is what the provider actually charged -- two numbers
      ;; computed different ways, on one event, so they can be made to meet (pre-publication issue 402).
      ;;
      ;; Still only when the provider reported something, which is the pre-publication issue 401 rule applied
      ;; to the event stream: emitting :usage with :input 0 for a provider that reports
      ;; no usage would claim a measurement nobody made, and a renderer summing input+output
      ;; would show a running total of zero as though it were the cost. When there is no
      ;; measurement, the estimate travels on :context-trimmed / :context-overflow instead,
      ;; which is where it matters -- beside the budget it was enforced against.
      ;;
      ;; ALL FOUR COUNTS, not two (#161). `ceiling:meter' has accepted four since
      ;; pre-publication PR 419 -- input, output, cache-read, cache-write -- and this event is
      ;; the ONLY programmatic route by which usage escapes a turn: `run-turn' returns text and
      ;; the completion is appended to history as messages and then dropped. So a caller wiring
      ;; the spend guard could supply `input-fn' and `output-fn' from here and had NO SOURCE AT
      ;; ALL for the other two. The provider had them, `llm.lisp' logged all four, and the seam
      ;; between producer and consumer carried half. `praxeon/web' reads (+ :input :output) off
      ;; this event for its own counter, so the one real consumer in the tree was
      ;; under-reporting a cached turn for the same reason.
      ;;
      ;; The cache fields are passed through as reported, like :input and :output below: NIL
      ;; means the provider did not report the count, 0 means it reported a miss.
      ;; Collapsing them would make a misplaced cache breakpoint indistinguishable from a
      ;; provider with no cache, which is what pre-publication issue 401 built the distinction
      ;; to prevent, and `ceiling:record-usage' already passes them through without an `or'.
      ;;
      ;; The gate widens with the payload: a provider reporting only cache counts would
      ;; otherwise emit nothing, which is the same silence this clause exists to avoid.
      (let ((in (llm:completion-input-tokens completion))
            (out (llm:completion-output-tokens completion))
            (cache-read (llm:completion-cache-read-tokens completion))
            (cache-write (llm:completion-cache-write-tokens completion)))
        (when (or in out cache-read cache-write)
          ;; NO `(or in 0)'. NIL and 0 ARE DIFFERENT ANSWERS and the distinction is the
          ;; whole point -- `completion's own docstring says so, and `ceiling:record-usage'
          ;; already honours it for the cache fields, which it passes with no `or'. NIL
          ;; means the provider did not report it; 0 means it reported a miss.
          ;;
          ;; The gate above is the pre-publication issue 401 rule at the level it was written for: no counts at
          ;; all, no event. It does not cover a PARTIAL report, and that is what this line
          ;; got wrong -- a provider reporting output and not input emitted `:input 0',
          ;; which is the thing the comment fourteen lines up forbids, one field down. A
          ;; renderer summing input+output then shows a total that is short by an unknown
          ;; amount rather than absent, and short-by-unknown reads as a real number (pre-publication issue 444).
          (evt:emit :usage :input in :output out
                           :cache-read cache-read :cache-write cache-write
                           :estimated-input estimate)))
      (%append-history agent (%assistant-message completion))
      (let ((calls (llm:completion-tool-calls completion)))
        (if (null calls)
            (progn
              (evt:emit :answer :text (llm:completion-text completion))
              (return (llm:completion-text completion)))
            (%append-history agent (%tool-results-message agent calls :permit permit)))))))

;;; --------------------------------------------------------------------------
;;; Delegation: an agent as another agent's means (multi-agent coordination, A).
;;;
;;; The praxeology reading: a sub-agent is a MEANS whose effect is "another Actor
;;; acts." Registering SUB as a means of COORDINATOR lets the coordinator's model
;;; delegate a subtask -- the sub runs its *own* full turn (its own provider, so
;;; its own vendor/model; its own history, means, and context) and returns its
;;; answer as the tool result. This reuses the entire deliberate/act loop, the
;;; restart protocol, and the event stream; no new control structure. It is the
;;; model-driven half of coordination (the deterministic half is praxeon/workflow).
;;; --------------------------------------------------------------------------

(defun %string-arg-schema (arg-name description)
  "A JSON schema (jzon-serializable) for a single required string property
ARG-NAME with DESCRIPTION -- the argument shape a delegated means advertises."
  (let ((prop (make-hash-table :test 'equal))
        (props (make-hash-table :test 'equal))
        (schema (make-hash-table :test 'equal)))
    (setf (gethash "type" prop) "string"
          (gethash "description" prop) description)
    (setf (gethash arg-name props) prop)
    (setf (gethash "type" schema) "object"
          (gethash "properties" schema) props
          (gethash "required" schema) (vector arg-name))
    schema))

(defun register-agent-as-means (coordinator sub &key name description (arg "task") permit)
  "Expose the SUB agent as a Means of COORDINATOR. When COORDINATOR's model calls
it, SUB runs its own RUN-TURN on the ARG string and its final answer becomes the
tool result -- genuine delegation to a specialist that keeps its own provider
\(model/vendor\), history, means, and context. NAME defaults to SUB's name;
DESCRIPTION is what the coordinator's model sees when deciding to delegate. Emits a
:delegate event around the sub-turn. Returns NAME.

Note: SUB retains history across calls (a persistent specialist). Delegation can
nest; each turn is bounded by its own MAX-STEPS, so keep the delegation graph
acyclic to stay finite."
  (let ((mname (or name (agent-name sub))))
    (register-means
     coordinator mname
     (or description
         (format nil "Delegate a self-contained subtask to the ~A agent; returns that agent's answer." (agent-name sub)))
     (lambda (args)
       (let ((task (cond ((hash-table-p args) (gethash arg args))
                         ((stringp args) args)
                         (t nil))))
         (evt:emit :delegate :agent (agent-name sub) :task task)
         ;; The sub-turn runs with the COORDINATOR's authority, not with none. A delegated
         ;; subtask that silently lost the permit would be a capability-bearing means becoming
         ;; unreachable one level down -- the same defect pre-publication issue 400 found in RUN-TURN, reached by
         ;; delegation instead of by the main loop.
         (run-turn sub (or task "") :permit permit)))
     :schema (%string-arg-schema
              arg (format nil "A self-contained instruction for the ~A agent."
                          (agent-name sub))))
    mname))

(defun converse-repl (agent &key (stream *query-io*))
  "A minimal interactive loop for talking to AGENT. Type :quit to stop."
  (format stream "~&[~A] ready. Type :quit to exit.~%" (agent-name agent))
  (loop
    (format stream "~&> ")
    (finish-output stream)
    (let ((line (read-line stream nil :quit)))
      (when (or (eq line :quit) (string-equal line ":quit"))
        (return))
      (handler-case
          (format stream "~&~A~%" (run-turn agent line))
        (cnd:praxeon-error (e)
          (format stream "~&[error] ~A~%" e))))))

;;; --------------------------------------------------------------------------
;;; A turn as a pipeline (pre-publication issue 130)
;;;
;;; RUN-TURN above is the deliberate/act loop -- the thing that talks to a model. It is
;;; also, from a pipeline's point of view, THE EFFECT: the single impure pivot that a
;;; chain of pure stages wraps. RUN-TURN-THROUGH is that wrapping.
;;;
;;; What this buys over composing the same steps in a `let*`, which is what the flagship
;;; example did and admitted to in its own docstring:
;;;
;;;   - stages are values, so they can be reordered, inspected, reused and TESTED without
;;;     a model;
;;;   - an enter-side guard can REFUSE, and the refusal skips the model call rather than
;;;     being appended to whatever it already said;
;;;   - a leave stage sees the reply and may replace it, which is what a safety guardrail
;;;     actually wants;
;;;   - the ordering is explicit rather than positional, so a stage that must run before
;;;     another (Elise's crisis check depends on the text having been translated first)
;;;     is a fact about the chain rather than a comment.
;;; --------------------------------------------------------------------------

(defun run-turn-through (agent input &key (locale "en") chain (max-steps 8) permit)
  "Run one turn for AGENT through CHAIN, returning the final TURN (not a string).

CHAIN is a list of stages built with PRAXEON/TURN's ENTER-STAGE / LEAVE-STAGE /
GUARD-STAGE; the default is no stages, which is exactly RUN-TURN with a value wrapped
around it. The model call is the effect at the edge, so a guard that halts on the way in
means it never happens.

Returns the turn so the caller can distinguish an answer from a refusal -- ask
TURN:TURN-HALTED, and read TURN:TURN-NOTE for the reason. Callers wanting only the text
can take TURN:TURN-REPLY."
  (turn:run-chain
   chain
   (lambda (tn)
     ;; The one impure pivot. It reads the turn's INPUT rather than the argument, so an
     ;; enter stage that rewrote the input (translation, redaction, a system preamble) is
     ;; what the model actually sees.
     (turn:with-reply tn (run-turn agent (turn:turn-input tn)
                                   :max-steps max-steps :permit permit)))
   (turn:make-turn input locale)))
