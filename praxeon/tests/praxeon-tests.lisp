;;;; praxeon-tests.lisp --- test suite for Praxeon
;;;;
;;;; These cover the dynamic CL shell (no network required). The Coalton core is
;;;; checked by the type system at load time; add Coalton-level tests as the
;;;; ontology grows.

(cl:defpackage #:praxeon/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:ctx #:praxeon/context)
                    (#:cnd #:praxeon/conditions)
                    (#:llm #:praxeon/llm)
                    (#:prompt #:praxeon/prompt)
                    (#:jzon #:com.inuoe.jzon)
                    (#:evt #:praxeon/event)
                    (#:actor #:praxeon/actor)
                    (#:turn #:praxeon/turn)
                    (#:ceiling #:praxeon/ceiling)
                    (#:wf #:praxeon/workflow)
                    (#:bt #:bordeaux-threads)   ; pre-publication issue 418: fan-out is really concurrent now
                    (#:web-search #:praxeon/web-search)
                    (#:mem #:praxeon/memory)
                    (#:dst #:praxeon/distil))
  (:export #:praxeon))

(cl:in-package #:praxeon/tests)

;;; --- writing to memory in tests (#150) --------------------------------------
;;;
;;; Provenance is REQUIRED on every write, so every test that writes must supply one. These
;;; wrappers supply a fixed source so that the tests about supersession, budgets and erasure
;;; stay about those things rather than each acquiring a provenance argument that is noise
;;; to what they assert.
;;;
;;; THE REQUIREMENT ITSELF IS ASSERTED SEPARATELY, in the tests named for it. A helper that
;;; makes the common case easy would otherwise make the adversarial case easy too, and the
;;; adversarial case here is a write with no source at all -- which must stay refused.

(defun test-provenance (&optional (turn 1) (conversation "conv-test"))
  (mem:make-provenance conversation turn))

(defun remember* (store subject content &rest args)
  "MEM:REMEMBER with a test provenance."
  (apply #'mem:remember store subject content :provenance (test-provenance) args))

(defun apply-distillation* (store distillation &rest args)
  "DST:APPLY-DISTILLATION with a test provenance -- a wrapper rather than an inserted
argument because the distillation form spans lines at most call sites, and an edit that has
to find the end of a form is an edit that will eventually find the wrong one."
  (apply #'dst:apply-distillation store distillation :provenance (test-provenance) args))

(defun supersede* (store observation content &rest args)
  "MEM:SUPERSEDE with a test provenance, in a LATER turn than the observation it replaces --
a correction happens after the thing it corrects, and the store records that rather than
inheriting the original's source."
  (apply #'mem:supersede store observation content :provenance (test-provenance 2) args))

(def-suite praxeon
  :description "Praxeon dynamic-shell test suite.")
(in-suite praxeon)

;;; --------------------------------------------------------------------------
;;; Context assembly
;;; --------------------------------------------------------------------------
(test context-respects-budget
  "Assembly never exceeds the token budget."
  (let ((c (ctx:make-context :budget 100)))
    (ctx:add-item c (ctx:make-ctx-item :content "a" :tokens 60 :value 10 :valid-time 1))
    (ctx:add-item c (ctx:make-ctx-item :content "b" :tokens 60 :value 9  :valid-time 2))
    (ctx:add-item c (ctx:make-ctx-item :content "c" :tokens 30 :value 8  :valid-time 3))
    (let* ((chosen (ctx:assemble c))
           (total (reduce #'+ chosen :key #'ctx:ctx-item-tokens :initial-value 0)))
      (is (<= total 100))
      (is (plusp (length chosen))))))

(test context-chronological-order
  "Assembled items come back oldest-first by valid-time."
  (let ((c (ctx:make-context :budget 1000)))
    (ctx:add-item c (ctx:make-ctx-item :content "late" :tokens 1 :value 1 :valid-time 30))
    (ctx:add-item c (ctx:make-ctx-item :content "early" :tokens 1 :value 1 :valid-time 10))
    (let ((times (mapcar #'ctx:ctx-item-valid-time (ctx:assemble c))))
      (is (equal times (sort (copy-list times) #'<))))))

;;; --------------------------------------------------------------------------
;;; Means + condition-system recovery
;;; --------------------------------------------------------------------------
(test act-runs-registered-means
  "A registered means is applied to its argument."
  (let ((ag (actor:make-agent :name "t")))
    (actor:register-means ag "echo" "echoes input" (lambda (s) (concatenate 'string "echo:" s)))
    (is (string= "echo:hi" (actor:act ag "echo" "hi")))))

(test act-substitutes-on-failure
  "A handler may substitute a result for a failing means."
  (let ((ag (actor:make-agent :name "t")))
    (actor:register-means ag "boom" "always fails" (lambda (s) (declare (ignore s)) (error "nope")))
    (is (string=
         "recovered"
         (handler-bind ((cnd:means-failure
                          (lambda (c) (cnd:substitute-result "recovered" c))))
           (actor:act ag "boom" "x"))))))

(test act-unknown-means-signals
  "Applying an unregistered means signals means-failure."
  (let ((ag (actor:make-agent :name "t")))
    (signals cnd:means-failure (actor:act ag "does-not-exist" "x"))))

;;; --------------------------------------------------------------------------
;;; Provider abstraction + tool-use dispatch (network-free)
;;;
;;; A scripted provider returns pre-canned completions in order. It lets us
;;; drive the whole deliberate/act loop -- and demonstrates that the COMPLETE
;;; protocol admits any LLM, not just Anthropic -- without a network call.
;;; --------------------------------------------------------------------------
(defclass scripted (llm:provider)
  ((script :initarg :script :accessor scripted-script))
  (:documentation "A provider that hands back queued completions in order."))

(defmethod llm:complete ((p scripted) messages
                         &key system tools max-tokens temperature tool-choice)
  ;; TOOL-CHOICE is accepted and ignored here. Adding a &key to a generic function obliges
  ;; every method to accept it, which is a real compatibility cost of pre-publication issue 416 and the reason
  ;; the PR says so: any provider implemented outside this tree needs the same edit.
  (declare (ignore messages system tools max-tokens temperature tool-choice))
  (or (pop (scripted-script p))
      (llm:make-completion :text "" :stop-reason :end)))

(defmethod llm:supports-tool-choice-p ((p scripted)) t)

;;; A provider that records what it was asked and replies from a script, so a test can
;;; assert the REQUEST COUNT as well as the result -- which is how the repair loop is
;;; measured rather than assumed.
(defclass recording (llm:provider)
  ((script :initarg :script :accessor recording-script)
   (requests :initform '() :accessor recording-requests))
  (:documentation "Counts requests and returns queued completions in order."))

(defmethod llm:supports-tool-choice-p ((p recording)) t)

(defmethod llm:complete ((p recording) messages
                         &key system tools max-tokens temperature tool-choice)
  (declare (ignore system max-tokens temperature))
  (push (list :messages (length messages) :tools (length tools) :tool-choice tool-choice)
        (recording-requests p))
  (or (pop (recording-script p))
      (llm:make-completion :text "" :stop-reason :end)))

(defclass transcribing (llm:provider)
  ((script :initarg :script :accessor transcribing-script)
   (messages :initform '() :accessor transcribing-messages))
  (:documentation "Keeps the MESSAGES it was sent, not their shape.

Separate from `recording' on purpose. `recording' stores lengths and the tool-choice, which
answers how many times and with what forcing; it cannot answer what was in the prompt. A
test asserting that particular text reached the model has to read the text, and asserting
against a count instead passes or fails for reasons unrelated to the claim."))

(defmethod llm:supports-tool-choice-p ((p transcribing)) t)

(defmethod llm:complete ((p transcribing) messages
                         &key system tools max-tokens temperature tool-choice)
  (declare (ignore tools max-tokens temperature tool-choice))
  (setf (transcribing-messages p) (append (transcribing-messages p)
                                          (list (cons :system system))
                                          messages))
  (or (pop (transcribing-script p))
      (llm:make-completion :text "" :stop-reason :end)))

(defun %args (&rest kvs)
  "A string-keyed hash-table standing in for a model's parsed tool arguments."
  (let ((ht (make-hash-table :test #'equal)))
    (loop for (k v) on kvs by #'cddr do (setf (gethash k ht) v))
    ht))

(test tool-use-dispatch-runs-a-means
  "run-turn routes a model-chosen means through act and feeds the result back."
  (let* ((call (llm:make-tool-call :id "t1" :name "add"
                                   :arguments (%args "a" 2 "b" 3)))
         (script (list (llm:make-completion :tool-calls (list call)
                                            :stop-reason :tool-use)
                       (llm:make-completion :text "the sum is 5"
                                            :stop-reason :end)))
         (ag (actor:make-agent
              :name "calc"
              :provider (make-instance 'scripted :script script))))
    (actor:register-means
     ag "add" "adds a and b"
     (lambda (in) (format nil "~A" (+ (gethash "a" in) (gethash "b" in)))))
    (is (string= "the sum is 5" (actor:run-turn ag "add 2 and 3")))
    ;; history: user, assistant(tool_use), user(tool_result), assistant(text)
    (is (= 4 (length (actor:agent-history ag))))))

(test tool-use-dispatch-no-tools-returns-text
  "With no tool call, run-turn returns the model's text directly."
  (let* ((script (list (llm:make-completion :text "hello" :stop-reason :end)))
         (ag (actor:make-agent
              :provider (make-instance 'scripted :script script))))
    (is (string= "hello" (actor:run-turn ag "hi")))))

(test tool-use-dispatch-recovers-from-a-failing-means
  "A supervising handler can substitute a result for a failing means, and the
loop carries on to a final answer."
  (let* ((call (llm:make-tool-call :id "t1" :name "boom" :arguments (%args)))
         (script (list (llm:make-completion :tool-calls (list call)
                                            :stop-reason :tool-use)
                       (llm:make-completion :text "done" :stop-reason :end)))
         (ag (actor:make-agent
              :provider (make-instance 'scripted :script script))))
    (actor:register-means ag "boom" "always fails"
                          (lambda (in) (declare (ignore in)) (error "nope")))
    (is (string=
         "done"
         (handler-bind ((cnd:means-failure
                          (lambda (c) (cnd:substitute-result "recovered" c))))
           (actor:run-turn ag "go"))))))

(test agent-as-means-delegates-to-a-sub-agent
  "register-agent-as-means lets a coordinator delegate a subtask to a sub-agent:
the coordinator's model calls the sub by name, the sub runs its OWN turn (its own
scripted provider), and its answer returns as the tool result -- multi-agent
coordination (A) over the existing deliberate/act loop, network-free."
  (let* ((sub (actor:make-agent
               :name "mathematician"
               :provider (make-instance
                          'scripted
                          :script (list (llm:make-completion
                                         :text "42" :stop-reason :end)))))
         (call (llm:make-tool-call :id "d1" :name "mathematician"
                                   :arguments (%args "task" "what is 6 times 7?")))
         (coord (actor:make-agent
                 :name "coordinator"
                 :provider (make-instance
                            'scripted
                            :script (list (llm:make-completion
                                           :tool-calls (list call)
                                           :stop-reason :tool-use)
                                          (llm:make-completion
                                           :text "The answer is 42."
                                           :stop-reason :end))))))
    ;; the sub is advertised under its own name by default
    (is (string= "mathematician" (actor:register-agent-as-means coord sub)))
    (is (string= "The answer is 42." (actor:run-turn coord "delegate the math")))
    ;; the sub genuinely ran its own turn: user + assistant(text)
    (is (= 2 (length (actor:agent-history sub))))))

;;; --------------------------------------------------------------------------
;;; Workflow: deterministic multi-agent coordination (B), network-free.
;;; --------------------------------------------------------------------------
(defun %scripted-agent (name text)
  "An agent whose scripted provider answers once with TEXT (no tool call)."
  (actor:make-agent
   :name name
   :provider (make-instance
              'scripted
              :script (list (llm:make-completion :text text :stop-reason :end)))))

(test workflow-sequential-threads-outputs
  "A workflow drives agents in order, threading each output through the shared
blackboard so a later step's prompt consumes an earlier step's answer."
  (let* ((researcher (%scripted-agent "researcher" "sources: A, B"))
         (writer (%scripted-agent "writer" "report using A, B"))
         (captured nil)
         (flow (wf:make-workflow
                :report "Produce a report"
                (wf:step :research researcher "find sources")
                (wf:step :write writer
                         (lambda (bb)
                           (setf captured (wf:bb-result bb :research))
                           (format nil "Write from: ~A" (wf:bb-result bb :research))))))
         (bb (wf:run-workflow flow)))
    ;; the writer's prompt saw the researcher's output (threading)
    (is (string= "sources: A, B" captured))
    (is (string= "sources: A, B" (wf:bb-result bb :research)))
    (is (string= "report using A, B" (wf:bb-result bb :write)))
    (is (string= "report using A, B" (wf:bb-final bb)))))

(test workflow-parallel-fans-out-then-gathers
  "A PARALLEL group runs steps with fan-out semantics -- each child sees the
blackboard as of the group's start, not each other -- and a following step gathers
their results."
  (let* ((pro (%scripted-agent "pro" "pro: yes"))
         (con (%scripted-agent "con" "con: no"))
         (judge (%scripted-agent "judge" "verdict"))
         (seen nil)
         (flow (wf:make-workflow
                :debate "Decide the question"
                (wf:parallel
                 (wf:step :pro pro "argue for")
                 (wf:step :con con "argue against"))
                (wf:step :judge judge
                         (lambda (bb)
                           (setf seen (list (wf:bb-result bb :pro)
                                            (wf:bb-result bb :con)))
                           "decide"))))
         (bb (wf:run-workflow flow)))
    (is (string= "pro: yes" (wf:bb-result bb :pro)))
    (is (string= "con: no" (wf:bb-result bb :con)))
    ;; the gather step saw both parallel outputs on the blackboard
    (is (equal '("pro: yes" "con: no") seen))
    (is (string= "verdict" (wf:bb-final bb)))))

;;; --------------------------------------------------------------------------
;;; OpenAI-compatible provider (translation, network-free)
;;;
;;; The OpenAI chat schema differs from Anthropic's -- tool_calls with a
;;; JSON-*string* `arguments` field and a `finish_reason` -- so we check the
;;; response parser against canned bodies. White-box: reaches internal symbols.
;;; --------------------------------------------------------------------------
(test openai-parse-text-response
  "A plain OpenAI chat response parses to text with an :end stop reason."
  (let ((c (praxeon/llm::%parse-openai
            (jzon:parse "{\"choices\":[{\"message\":{\"content\":\"hi\"},
                          \"finish_reason\":\"stop\"}]}"))))
    (is (string= "hi" (llm:completion-text c)))
    (is (eq :end (llm:completion-stop-reason c)))
    (is (null (llm:completion-tool-calls c)))))

(test openai-parse-tool-call-response
  "A tool_calls response parses to a tool-call with JSON-string args decoded."
  (let ((c (praxeon/llm::%parse-openai
            (jzon:parse "{\"choices\":[{\"message\":{\"content\":null,
                          \"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",
                          \"function\":{\"name\":\"add\",
                          \"arguments\":\"{\\\"a\\\":2,\\\"b\\\":3}\"}}]},
                          \"finish_reason\":\"tool_calls\"}]}"))))
    (is (eq :tool-use (llm:completion-stop-reason c)))
    (is (string= "" (llm:completion-text c)))       ; null content -> ""
    (is (= 1 (length (llm:completion-tool-calls c))))
    (let ((call (first (llm:completion-tool-calls c))))
      (is (string= "add" (llm:tool-call-name call)))
      (is (string= "call_1" (llm:tool-call-id call)))
      (is (= 2 (gethash "a" (llm:tool-call-arguments call))))
      (is (= 3 (gethash "b" (llm:tool-call-arguments call)))))))

(test provider-factory-selects-impl
  "PRAXEON_LLM_IMPL selects the matching provider class."
  (let ((saved (uiop:getenv "PRAXEON_LLM_IMPL")))
    (unwind-protect
         (progn
           (setf (uiop:getenv "PRAXEON_LLM_IMPL") "ollama")
           (is (typep (llm:make-provider-from-env) 'llm:openai-compatible))
           (setf (uiop:getenv "PRAXEON_LLM_IMPL") "anthropic")
           (is (typep (llm:make-provider-from-env) 'llm:anthropic)))
      (setf (uiop:getenv "PRAXEON_LLM_IMPL") (or saved "anthropic")))))

(test per-provider-vars-override-shared
  "A PRAXEON_<IMPL>_* var wins over the shared PRAXEON_LLM_* for that impl."
  (let ((s-impl (uiop:getenv "PRAXEON_LLM_IMPL"))
        (s-model (uiop:getenv "PRAXEON_LLM_MODEL"))
        (s-amodel (uiop:getenv "PRAXEON_ANTHROPIC_MODEL")))
    (unwind-protect
         (progn
           (setf (uiop:getenv "PRAXEON_LLM_IMPL") "anthropic"
                 (uiop:getenv "PRAXEON_LLM_MODEL") "shared-model"
                 (uiop:getenv "PRAXEON_ANTHROPIC_MODEL") "claude-opus-4-8")
           ;; the anthropic-specific model must beat the shared one
           (is (string= "claude-opus-4-8"
                        (llm:anthropic-model (llm:make-provider-from-env)))))
      (setf (uiop:getenv "PRAXEON_LLM_IMPL") (or s-impl "anthropic")
            (uiop:getenv "PRAXEON_LLM_MODEL") (or s-model "")
            (uiop:getenv "PRAXEON_ANTHROPIC_MODEL") (or s-amodel "")))))

;;; .env parsing moved to cons/env (cons/tests:dotenv-*); praxeon/config delegates.

;;; --------------------------------------------------------------------------
;;; Studio DX (introspection, network-free)
;;; --------------------------------------------------------------------------
(test studio-describe-lists-means
  "describe-agent reports the agent name and its registered means."
  (let ((ag (actor:make-agent :name "calc")))
    (actor:register-means ag "add" "adds a and b" (lambda (in) (declare (ignore in)) ""))
    (let ((desc (with-output-to-string (s) (praxeon/studio:describe-agent ag s))))
      (is (search "calc" desc))
      (is (search "add" desc))
      (is (search "adds a and b" desc)))))

(test studio-trace-turn-shows-steps
  "trace-turn returns the final reply and renders the tool call + result."
  (let* ((call (llm:make-tool-call :id "t1" :name "add"
                                   :arguments (%args "a" 2 "b" 3)))
         (script (list (llm:make-completion :tool-calls (list call)
                                            :stop-reason :tool-use)
                       (llm:make-completion :text "sum is 5" :stop-reason :end)))
         (ag (actor:make-agent
              :name "calc"
              :provider (make-instance 'scripted :script script))))
    (actor:register-means
     ag "add" "adds a and b"
     (lambda (in) (format nil "~A" (+ (gethash "a" in) (gethash "b" in)))))
    ;; describe-agent must not choke on a provider lacking a model-of method
    (let ((desc (with-output-to-string (s) (praxeon/studio:describe-agent ag s))))
      (is (search "SCRIPTED" (string-upcase desc))))
    (let* ((out (make-string-output-stream))
           (reply (praxeon/studio:trace-turn ag "add 2 and 3" out))
           (trace (get-output-stream-string out)))
      (is (string= "sum is 5" reply))
      (is (search "call" trace))     ; the tool_use step rendered
      (is (search "result" trace))   ; the tool_result step rendered
      (is (search "sum is 5" trace)))))

;;; --------------------------------------------------------------------------
;;; Progress events -- the client<->framework contract (network-free)
;;; --------------------------------------------------------------------------
(test observer-receives-turn-events
  "run-turn emits :deliberating/:tool-call/:tool-result/:answer, in order and
with payloads, to a bound observer."
  (let* ((call (llm:make-tool-call :id "t1" :name "add"
                                   :arguments (%args "a" 2 "b" 3)))
         (script (list (llm:make-completion :tool-calls (list call)
                                            :stop-reason :tool-use)
                       (llm:make-completion :text "sum is 5" :stop-reason :end)))
         (ag (actor:make-agent
              :provider (make-instance 'scripted :script script)))
         (events '()))
    (actor:register-means
     ag "add" "adds a and b"
     (lambda (in) (format nil "~A" (+ (gethash "a" in) (gethash "b" in)))))
    (evt:with-observer ((lambda (e) (push e events)))
      (actor:run-turn ag "add 2 and 3"))
    (setf events (nreverse events))
    (is (equal '(:deliberating :tool-call :tool-result :deliberating :answer)
               (mapcar #'evt:event-type events)))
    (let ((tc (find :tool-call events :key #'evt:event-type)))
      (is (string= "add" (evt:event-get tc :name)))
      (is (= 2 (gethash "a" (evt:event-get tc :arguments)))))
    (let ((ans (find :answer events :key #'evt:event-type)))
      (is (string= "sum is 5" (evt:event-get ans :text))))))

(test observer-nil-is-noop
  "With no observer bound, run-turn still works (emitting is a no-op)."
  (let* ((script (list (llm:make-completion :text "hi" :stop-reason :end)))
         (ag (actor:make-agent
              :provider (make-instance 'scripted :script script))))
    (is (string= "hi" (actor:run-turn ag "hello")))))

;;; --- web-search means (network-free: no Tavily call) ----------------------

(test web-search-formats-results
  "Tavily's parsed JSON renders to a compact answer + sources summary."
  (let ((parsed (make-hash-table :test 'equal))
        (r1 (make-hash-table :test 'equal)))
    (setf (gethash "title" r1) "PAIP"
          (gethash "url" r1) "https://en.wikipedia.org/wiki/PAIP"
          (gethash "content" r1) "Paradigms of AI Programming, by Peter Norvig.")
    (setf (gethash "answer" parsed) "PAIP was written by Peter Norvig."
          (gethash "results" parsed) (vector r1))
    (let ((out (web-search::%format-results parsed)))
      (is (search "Peter Norvig" out))
      (is (search "wikipedia.org/wiki/PAIP" out))
      (is (search "Sources:" out)))))

(test web-search-registers-means
  "REGISTER adds a 'web-search' means advertising a JSON schema."
  (let ((ag (actor:make-agent)))
    (web-search:register ag)
    (let ((spec (find "web-search" (actor:agent-tool-specs ag)
                      :key #'llm:tool-spec-name :test #'string=)))
      (is (not (null spec)))
      (is (not (null (llm:tool-spec-schema spec)))))))

;;; --- a turn as a value, and a pipeline over it (pre-publication issue 130) ----------------------
;;;
;;; The point of these is that a turn's SHAPE is now testable without a model. Before
;;; this, the composition lived in a `let*` inside the flagship example, so the only way
;;; to exercise "does the guardrail replace the reply" was to call an LLM.
;;;
;;; The effect is an ordinary CL closure here, exactly as it is in production -- the
;;; difference between this and a real turn is what the closure does, not how it is wired.

(def-suite turn :description "The turn context and its interceptor pipeline." :in praxeon)
(in-suite turn)

(defun %echo-effect (&optional (record nil))
  "An effect standing in for the model: replies with the input it was actually given.
When RECORD is a cons, its CAR is incremented on each call, so a test can prove the
effect did or did not happen."
  (lambda (tn)
    (when record (incf (car record)))
    (turn:with-reply tn (format nil "answered: ~A" (turn:turn-input tn)))))

(test a-turn-carries-its-own-data
  (let ((tn (turn:make-turn "hello" "en")))
    (is (string= "hello" (turn:turn-input tn)))
    (is (string= "en" (turn:turn-locale tn)))
    (is (string= "" (turn:turn-reply tn)) "no reply until the effect runs")
    (is (not (turn:turn-halted tn)))))

(test updates-are-pure-and-leave-the-original-alone
  ;; Stages thread a context; if an update mutated in place, a stage could not be re-run
  ;; or reasoned about independently.
  (let* ((a (turn:make-turn "in" "en"))
         (b (turn:with-reply a "out")))
    (is (string= "" (turn:turn-reply a)) "the original must be untouched")
    (is (string= "out" (turn:turn-reply b)))
    (is (string= "in" (turn:turn-input b)) "and everything else carried over")))

(test an-empty-chain-is-just-the-effect
  (let ((tn (turn:run-chain nil (%echo-effect) (turn:make-turn "hi" "en"))))
    (is (string= "answered: hi" (turn:turn-reply tn)))))

(test an-enter-stage-rewrites-what-the-model-sees
  ;; The translation case, reduced: a stage that rewrites INPUT must change what the
  ;; effect deliberates over -- not merely annotate the context.
  (let* ((upcase (turn:enter-stage "shout" (lambda (tn)
                                             (turn:with-input tn (string-upcase (turn:turn-input tn))))))
         (tn (turn:run-chain (list upcase) (%echo-effect) (turn:make-turn "hi" "en"))))
    (is (string= "answered: HI" (turn:turn-reply tn)))))

(test a-leave-stage-can-replace-the-reply
  ;; THE defect pre-publication issue 130 names: Elise's crisis guardrail is an `if` at the bottom that appends
  ;; a note to whatever the model already said. A safety guardrail wants to REPLACE.
  (let* ((guardrail (turn:leave-stage "crisis"
                                      (lambda (tn) (turn:with-reply tn "please call 988"))))
         (tn (turn:run-chain (list guardrail) (%echo-effect) (turn:make-turn "hi" "en"))))
    (is (string= "please call 988" (turn:turn-reply tn))
        "the guardrail's reply must stand in place of the model's, not after it")))

(test leave-stages-run-in-reverse-so-the-outermost-wraps-everything
  (let* ((mark (lambda (s) (turn:leave-stage s (lambda (tn)
                                                 (turn:with-reply tn (concatenate 'string (turn:turn-reply tn) s))))))
         (tn (turn:run-chain (list (funcall mark "<a") (funcall mark "<b"))
                             (%echo-effect) (turn:make-turn "x" "en"))))
    (is (string= "answered: x<b<a" (turn:turn-reply tn))
        "inner stage leaves first; got ~S" (turn:turn-reply tn))))

;;; --- refusal, which is the property pre-publication issue 172 is built on -----------------------

(test a-guard-can-refuse-and-the-model-is-never-called
  ;; A budget or safety refusal must cost nothing. If this regresses, a refusal still
  ;; spends the tokens it was refusing to spend.
  (let* ((calls (list 0))
         (deny (turn:guard-stage "deny" (lambda (tn) (turn:halt-with tn "over budget"))))
         (tn (turn:run-chain (list deny) (%echo-effect calls) (turn:make-turn "hi" "en"))))
    (is (turn:turn-halted tn) "the turn must report itself refused")
    (is (string= "over budget" (turn:turn-note tn)) "with a legible reason")
    (is (zerop (car calls)) "THE EFFECT MUST NOT HAVE RUN")
    (is (string= "" (turn:turn-reply tn)) "and no reply was invented")))

(test a-guard-that-permits-does-not-disturb-the-turn
  (let* ((calls (list 0))
         (allow (turn:guard-stage "allow" (lambda (tn) tn)))
         (tn (turn:run-chain (list allow) (%echo-effect calls) (turn:make-turn "hi" "en"))))
    (is (not (turn:turn-halted tn)))
    (is (= 1 (car calls)) "the effect runs exactly once")
    (is (string= "answered: hi" (turn:turn-reply tn)))))

(test a-refusal-is-distinguishable-from-an-answer
  ;; Requirement 3 of pre-publication issue 172: a hard, legible refusal, never silent degradation. A caller
  ;; must be able to tell "refused" from "answered" without parsing the reply text.
  (let* ((deny (turn:guard-stage "deny" (lambda (tn) (turn:halt-with tn "quota exhausted"))))
         (refused (turn:run-chain (list deny) (%echo-effect) (turn:make-turn "hi" "en")))
         (answered (turn:run-chain nil (%echo-effect) (turn:make-turn "hi" "en"))))
    (is (turn:turn-halted refused))
    (is (not (turn:turn-halted answered)))
    (is (string/= (turn:turn-note refused) (turn:turn-note answered)))))

(test a-later-guard-still-refuses-after-an-earlier-stage-ran
  ;; Ordering is explicit now, so a guard placed after a rewrite still governs the effect.
  (let* ((calls (list 0))
         (rewrite (turn:enter-stage "prefix" (lambda (tn)
                                               (turn:with-input tn (concatenate 'string ">" (turn:turn-input tn))))))
         (deny (turn:guard-stage "deny" (lambda (tn) (turn:halt-with tn "nope"))))
         (tn (turn:run-chain (list rewrite deny) (%echo-effect calls) (turn:make-turn "hi" "en"))))
    (is (turn:turn-halted tn))
    (is (zerop (car calls)))
    (is (string= ">hi" (turn:turn-input tn)) "the earlier stage's work is still visible")))

;;; --- the cost ceiling (pre-publication issue 172) -----------------------------------------------
;;;
;;; Two kinds of property here, and the second kind is why this file is long.
;;;
;;; The ARITHMETIC is ordinary and would be boring to get wrong. The SECURITY properties
;;; are not: that a tampered payload is rejected, that an expired grant is rejected, that
;;; the signature is checked BEFORE anything in the payload is believed, and above all
;;; that a refusal SKIPS THE MODEL CALL. That last one is the difference between a ceiling
;;; and a receipt.

(def-suite ceiling :description "Signed grants, the session ledger, and refusal." :in praxeon)
(in-suite ceiling)

(defun %grant-json (&key (principal "u1") (group "g1") (capabilities '("search"))
                         (token-cap 10000) (call-cap 5) (expires-in 3600)
                         (audience "elise"))
  (let ((o (make-hash-table :test 'equal)))
    (setf (gethash "principal" o) principal
          (gethash "group" o) group
          (gethash "capabilities" o) (coerce capabilities 'vector)
          (gethash "token_cap" o) token-cap
          (gethash "call_cap" o) call-cap
          (gethash "expires_at" o) (+ (get-universal-time) expires-in)
          (gethash "audience" o) audience)
    (com.inuoe.jzon:stringify o)))

(defmacro with-keys ((priv pub) &body body)
  `(multiple-value-bind (,priv ,pub) (ironclad:generate-key-pair :ed25519)
     (declare (ignorable ,priv ,pub))
     ,@body))

(defun %sign (priv payload)
  (ironclad:sign-message priv (sb-ext:string-to-octets payload :external-format :utf-8)))

;;; --- verification ----------------------------------------------------------

(test a-validly-signed-grant-verifies-and-carries-its-claims
  (with-keys (priv pub)
    (let* ((payload (%grant-json))
           (g (ceiling:verify-grant (ceiling:make-ed25519-verifier pub :audience "elise")
                                    payload (%sign priv payload))))
      (is (string= "u1" (ceiling:grant-principal g)))
      (is (string= "g1" (ceiling:grant-group g)) "attribution is the (user, group) PAIR")
      (is (= 10000 (ceiling:grant-token-cap g)))
      (is (ceiling:grant-permits-p g "search")))))

(test a-tampered-payload-is-rejected
  ;; The point of signing. Raising your own ceiling must not be a matter of editing JSON.
  (with-keys (priv pub)
    (let* ((payload (%grant-json :token-cap 10000))
           (sig (%sign priv payload))
           (forged (%grant-json :token-cap 999999999)))
      (signals ceiling:grant-invalid
        (ceiling:verify-grant (ceiling:make-ed25519-verifier pub) forged sig)))))

(test a-grant-signed-by-the-wrong-key-is-rejected
  ;; The property a shared secret would NOT have given us: this side can verify and cannot
  ;; mint, so compromising it yields no usable grants.
  (with-keys (priv pub)
    (declare (ignore pub))
    (with-keys (other-priv other-pub)
      (declare (ignore other-priv))
      (let ((payload (%grant-json)))
        (signals ceiling:grant-invalid
          (ceiling:verify-grant (ceiling:make-ed25519-verifier other-pub)
                                payload (%sign priv payload)))))))

(test an-expired-grant-is-rejected
  (with-keys (priv pub)
    (let ((payload (%grant-json :expires-in -1)))
      (signals ceiling:grant-invalid
        (ceiling:verify-grant (ceiling:make-ed25519-verifier pub) payload (%sign priv payload))))))

(test a-grant-for-another-audience-is-rejected
  ;; Otherwise a grant minted for one service is spendable at another.
  (with-keys (priv pub)
    (let ((payload (%grant-json :audience "some-other-service")))
      (signals ceiling:grant-invalid
        (ceiling:verify-grant (ceiling:make-ed25519-verifier pub :audience "elise")
                              payload (%sign priv payload))))))

(test the-signature-is-checked-before-the-payload-is-believed
  ;; Ordering, not politeness: an unverified payload's expiry is not evidence of anything,
  ;; so a forged-but-expired grant must fail on the SIGNATURE.
  (with-keys (priv pub)
    (declare (ignore priv))
    (with-keys (other-priv other-pub)
      (declare (ignore other-pub))
      (let* ((payload (%grant-json :expires-in -1))
             (sig (%sign other-priv payload)))
        (handler-case
            (progn (ceiling:verify-grant (ceiling:make-ed25519-verifier pub) payload sig)
                   (fail "should have been rejected"))
          (ceiling:grant-invalid (c)
            (is (search "signature" (ceiling:grant-invalid-reason c))
                "must fail on the signature, not the expiry: got ~S"
                (ceiling:grant-invalid-reason c))))))))

;;; --- the ledger ------------------------------------------------------------

(defun %ledger (&key (token-cap 1000) (call-cap 3) (capabilities '("search")))
  (ceiling:make-ledger
   (with-keys (priv pub)
     (let ((payload (%grant-json :token-cap token-cap :call-cap call-cap
                                 :capabilities capabilities)))
       (ceiling:verify-grant (ceiling:make-ed25519-verifier pub) payload (%sign priv payload))))))

(test remaining-budget-is-readable-before-any-call
  ;; Requirement 4: the UI renders "you have N left this month" from this, rather than
  ;; discovering the ceiling by hitting it.
  (let ((l (%ledger :token-cap 1000 :call-cap 3)))
    (is (= 1000 (ceiling:remaining-tokens l)))
    (is (= 3 (ceiling:remaining-calls l)))
    (is (ceiling:affordable-p l 500))
    (is (not (ceiling:affordable-p l 1500)) "an unaffordable turn is knowable in advance")))

(test usage-is-recorded-per-model-and-attributed-to-the-user-and-group
  ;; Requirement 2: break-even arithmetic needs tokens in/out per model per user, not a
  ;; single org-level counter that can answer neither pricing question.
  (let ((l (%ledger :token-cap 1000)))
    (ceiling:record-usage l :input 100 :output 50 :model "claude-x" :means "search")
    (let ((line (first (ceiling:usage-report l))))
      (is (string= "u1" (getf line :principal)))
      (is (string= "g1" (getf line :group)))
      (is (string= "claude-x" (getf line :model)))
      (is (string= "search" (getf line :means)) "which capability was expensive")
      (is (= 100 (getf line :input)))
      (is (= 50 (getf line :output))))
    (is (= 850 (ceiling:remaining-tokens l)) "and it is charged against the cap")))

(test usage-report-is-oldest-first-so-it-can-be-appended-to-a-ledger
  (let ((l (%ledger)))
    (ceiling:record-usage l :input 1 :model "a")
    (ceiling:record-usage l :input 2 :model "b")
    (is (equal '("a" "b") (mapcar (lambda (x) (getf x :model)) (ceiling:usage-report l))))))

;;; --- refusal, which is the whole point -------------------------------------

(defun %counting-effect (calls)
  (lambda (tn) (incf (car calls)) (turn:with-reply tn "answered")))

(test a-turn-within-budget-proceeds
  (let* ((l (%ledger :token-cap 1000 :call-cap 3))
         (calls (list 0))
         (tn (turn:run-chain (list (ceiling:budget-guard l :estimate 100))
                             (%counting-effect calls) (turn:make-turn "hi" "en"))))
    (is (not (turn:turn-halted tn)))
    (is (= 1 (car calls)))))

(test an-unaffordable-turn-is-refused-AND-THE-MODEL-IS-NEVER-CALLED
  ;; THE test. A ceiling that refuses after spending is a receipt, not a ceiling. Verified
  ;; by counting invocations rather than by inspecting a reply.
  (let* ((l (%ledger :token-cap 100 :call-cap 3))
         (calls (list 0))
         (tn (turn:run-chain (list (ceiling:budget-guard l :estimate 5000))
                             (%counting-effect calls) (turn:make-turn "hi" "en"))))
    (is (turn:turn-halted tn))
    (is (zerop (car calls)) "THE MODEL CALL MUST NOT HAVE HAPPENED")
    (is (search "insufficient budget" (turn:turn-note tn)) "and the refusal says why")))

(test the-call-cap-stops-a-loop-even-when-each-call-is-small
  ;; "One person with curl and a loop" -- the case the issue was actually filed about.
  ;; Each turn is affordable; the SESSION is not.
  (let* ((l (%ledger :token-cap 1000000 :call-cap 2))
         (calls (list 0))
         (chain (list (ceiling:budget-guard l :estimate 1)
                      (ceiling:meter l :model "m" :input-fn (lambda () 1)))))
    (dotimes (i 4)
      (turn:run-chain chain (%counting-effect calls) (turn:make-turn "hi" "en")))
    (is (= 2 (car calls)) "only the permitted calls reached the model; got ~A" (car calls))
    (is (zerop (ceiling:remaining-calls l)))))

(test a-refusal-is-legible-and-never-a-silent-downgrade
  ;; Requirement 3. The panel says so in the user's language while the rest of the page
  ;; keeps working; it does NOT quietly answer with a cheaper model.
  (let* ((l (%ledger :token-cap 10 :call-cap 3))
         (tn (turn:run-chain (list (ceiling:budget-guard l :estimate 5000))
                             (%counting-effect (list 0)) (turn:make-turn "hi" "en"))))
    (is (turn:turn-halted tn) "a caller can tell refusal from answer without parsing text")
    (is (plusp (length (turn:turn-note tn))) "with a reason")
    (is (string= "" (turn:turn-reply tn)) "and no answer was invented to fill the gap")))

(test a-capability-the-grant-lacks-is-refused-before-the-call
  (let* ((l (%ledger :capabilities '("search")))
         (calls (list 0))
         (tn (turn:run-chain (list (ceiling:capability-guard l "payments"))
                             (%counting-effect calls) (turn:make-turn "hi" "en"))))
    (is (turn:turn-halted tn))
    (is (zerop (car calls)))
    (is (search "payments" (turn:turn-note tn)))))

(test the-meter-does-not-charge-for-a-turn-that-was-refused
  ;; Otherwise a refusal consumes the budget it was protecting, and a caller refused once
  ;; is refused forever.
  (let* ((l (%ledger :token-cap 100 :call-cap 3))
         (before (ceiling:remaining-tokens l)))
    (turn:run-chain (list (ceiling:budget-guard l :estimate 5000)
                          (ceiling:meter l :model "m" :input-fn (lambda () 50)))
                    (%counting-effect (list 0)) (turn:make-turn "hi" "en"))
    (is (= before (ceiling:remaining-tokens l))
        "a refused turn must not be billed")))

;;; --- what a cached prefix costs the guard (pre-publication issue 417) -----------------------------
;;;
;;; pre-publication issue 401 made four counts visible on a COMPLETION; the ledger received two. Measured on
;;; f725afd, before the fix: a turn reporting input 10 / output 40 / cache-read 5000 charged
;;; FIFTY, and ten such turns against a 1000-token cap left the guard still permitting more
;;; after the session had reported 50500 -- 101x under, in the direction that reads as
;;; headroom. The tests below are that control, closed.

(defun %cache-completion (&key (input 10) (output 40) (read 5000) (write 0))
  (llm:make-completion :text "ok" :stop-reason :end
                       :input-tokens input :output-tokens output
                       :cache-read-tokens read :cache-write-tokens write))

(defun %meter-for (ledger completion &key (model "m"))
  "The meter stage wired to COMPLETION's four counts -- the four accessors pre-publication issue 401 added."
  (ceiling:meter ledger :model model
                        :input-fn (lambda () (llm:completion-input-tokens completion))
                        :output-fn (lambda () (llm:completion-output-tokens completion))
                        :cache-read-fn (lambda () (llm:completion-cache-read-tokens completion))
                        :cache-write-fn (lambda () (llm:completion-cache-write-tokens completion))))

(test a-turn-served-from-cache-is-charged-for-what-it-read
  "The control, closed. 5050 tokens were reported and 50 were charged; parity charges 5050."
  (let* ((l (%ledger :token-cap 100000 :call-cap 10))
         (completion (%cache-completion)))
    (turn:run-chain (list (ceiling:budget-guard l :estimate 1)
                          (%meter-for l completion))
                    (%counting-effect (list 0)) (turn:make-turn "hi" "en"))
    (is (= 5050 (- 100000 (ceiling:remaining-tokens l)))
        "input 10 + output 40 + cache-read 5000, at parity")
    (is (= 5050 (getf (first (ceiling:usage-report l)) :charged))
        "and the line says what was charged, so the cap can be reconciled against it")))

(test all-four-counts-are-recorded-separately
  "Not folded into `input'. A report that added a cache read into the base input could still
bound a runaway and could not explain a bill."
  (let ((l (%ledger :token-cap 100000)))
    (ceiling:record-usage l :input 10 :output 40 :cache-read 5000 :cache-write 120
                            :model "claude-x" :means "search")
    (let ((line (first (ceiling:usage-report l))))
      (is (= 10 (getf line :input)))
      (is (= 40 (getf line :output)))
      (is (= 5000 (getf line :cache-read)))
      (is (= 120 (getf line :cache-write)))
      (is (= 5170 (getf line :charged)))
      (is (string= "search" (getf line :means)) "and the old fields are untouched"))))

(test a-provider-that-reports-no-cache-is-not-recorded-as-reporting-zero
  "pre-publication issue 401 paid for this distinction and the boundary is where it would be lost: NIL means the
provider said nothing, 0 means it reported a miss. Both charge nothing; only one is a
measurement."
  (let ((l (%ledger :token-cap 100000)))
    (ceiling:record-usage l :input 10 :model "silent")
    (ceiling:record-usage l :input 10 :cache-read 0 :model "reported-a-miss")
    (destructuring-bind (silent reported) (ceiling:usage-report l)
      (is (null (getf silent :cache-read))
          "a caller that did not know is recorded as not knowing")
      (is (eql 0 (getf reported :cache-read))
          "and one that was told zero is recorded as told zero")
      (is (= (getf silent :charged) (getf reported :charged))
          "the two charge the same, which is why the RECORD is the only place the
difference can survive"))))

(test ten-cache-served-turns-now-exhaust-the-cap-they-used-to-evade
  (let* ((l (%ledger :token-cap 1000 :call-cap 100))
         (completion (%cache-completion))
         (calls (list 0))
         (chain (list (ceiling:budget-guard l :estimate 1) (%meter-for l completion))))
    (dotimes (i 10)
      (turn:run-chain chain (%counting-effect calls) (turn:make-turn "hi" "en")))
    (is (= 1 (car calls))
        "the first turn spends 5050 against a 1000 cap, so the second is refused; got ~A
turns through" (car calls))
    (is-false (ceiling:affordable-p l 1) "and the session is closed rather than open"))
  ;; THE CONTROL, and it is also the compatibility promise: the same ten turns with the two
  ;; cache readers omitted are charged exactly what they were charged before this change, so
  ;; the assertion above is about the counts being read and not about some other change.
  (let* ((l (%ledger :token-cap 1000 :call-cap 100))
         (completion (%cache-completion))
         (calls (list 0))
         (chain (list (ceiling:budget-guard l :estimate 1)
                      (ceiling:meter l :model "m"
                                       :input-fn (lambda () (llm:completion-input-tokens completion))
                                       :output-fn (lambda () (llm:completion-output-tokens completion))))))
    (dotimes (i 10)
      (turn:run-chain chain (%counting-effect calls) (turn:make-turn "hi" "en")))
    (is (= 10 (car calls)) "unmetered cache reads: ten turns, 500 charged, cap never reached")
    (is (= 500 (- 1000 (ceiling:remaining-tokens l))))))

(test the-weights-are-one-named-place-and-default-to-parity
  "Parity is the decision (see the commentary in ceiling.lisp): the cap is denominated in
tokens, and a guard should over-count a cheap token rather than under-count it. A host that
wants cost-shaped accounting binds the weights, and that is the only place to do it."
  (is (equal '((:input . 1) (:output . 1) (:cache-read . 1) (:cache-write . 1))
             ceiling:*token-weights*)
      "the default is parity, stated as data rather than implied by the arithmetic")
  (is (= 5050 (ceiling:chargeable-tokens :input 10 :output 40 :cache-read 5000)))
  ;; Anthropic's price ratios as recorded in *TOKEN-WEIGHTS*' docstring, with their date.
  (let ((ceiling:*token-weights* '((:input . 1) (:output . 1)
                                   (:cache-read . 1/10) (:cache-write . 5/4))))
    (is (= 550 (ceiling:chargeable-tokens :input 10 :output 40 :cache-read 5000))
        "a cache read at a tenth: 10 + 40 + 500")
    (is (= 51 (ceiling:chargeable-tokens :input 10 :cache-write 33))
        "and a cache write at 1.25x, rounded: 10 + 41"))
  (let ((l (%ledger :token-cap 100000))
        (ceiling:*token-weights* '((:input . 1) (:output . 1)
                                   (:cache-read . 1/10) (:cache-write . 5/4))))
    (ceiling:record-usage l :input 10 :output 40 :cache-read 5000)
    (is (= 550 (getf (first (ceiling:usage-report l)) :charged))
        "the ledger charges through the same function, so the guard and the report cannot
disagree about what a token cost")))

(test chargeable-tokens-treats-a-missing-count-as-nothing
  "NIL and 0 and absent all contribute nothing to a SUM -- which is the one place they are
allowed to be the same, because a sum has to be a number."
  (is (= 0 (ceiling:chargeable-tokens)))
  (is (= 10 (ceiling:chargeable-tokens :input 10 :cache-read nil :cache-write nil)))
  (is (= 10 (ceiling:chargeable-tokens :input 10 :cache-read 0 :cache-write 0))))

;;; --- pre-publication issue 218: a framework does not choose the application's HTTP server ---------
;;;
;;; pre-publication issue 139 / ADR-0011 decided this and hyperion implemented it -- but only for itself.
;;; praxeon/web went on declaring clack-handler-woo on Unix, so every praxeon web app
;;; deployed on Linux or macOS ran on Woo without ever choosing it, and Woo does not
;;; answer SIGTERM (measured 3x per cell on macOS, 21 runs on Linux). A supervisor's
;;; stop request was ignored and the process was SIGKILLed with requests in flight.
;;;
;;; The rule was decided, documented, and undefended -- which is exactly how one system
;;; kept violating it for months while the tree stayed green. So it is asserted here.

(defun %asd-dep-name (d seen)
  "Record dependency form D (and recurse), whatever shape ASDF gives it.

A dependency is not always a string. `(:feature <f> <dep>)', `(:version <dep> \"x\")' and
`(:require <module>)' are all legal, and the FIRST of those is how the Woo declaration was
written -- so a walk that handled only strings and symbols could not see the very thing
this test exists to catch. It did not: the control run reinstated Woo and the suite stayed
green, which is why this function is shaped like this.

A `:feature'-guarded dependency counts REGARDLESS of whether the feature holds in this
image. The question is what the system DECLARES, not what today's platform resolves to --
the original defect was invisible on Windows for exactly that reason."
  (cond
    ((stringp d) (%asd-deps d seen))
    ((symbolp d) (%asd-deps (string-downcase (symbol-name d)) seen))
    ((consp d)
     (case (first d)
       (:feature (%asd-dep-name (third d) seen))
       (:version (%asd-dep-name (second d) seen))
       (:require nil)                    ; an SBCL contrib, never a tree system
       (t (dolist (x (rest d)) (%asd-dep-name x seen)))))))

(defun %asd-deps (system &optional (seen (make-hash-table :test #'equal)))
  "SYSTEM's transitive dependency names, lowercased. FIND-SYSTEM only reads the .asd --
nothing is loaded, so this cannot drag a handler into the test image and answer its own
question."
  (let ((sys (asdf:find-system system nil)))
    (when sys
      (let ((name (string-downcase (asdf:component-name sys))))
        (unless (gethash name seen)
          (setf (gethash name seen) t)
          (dolist (d (asdf:system-depends-on sys))
            (%asd-dep-name d seen))))))
  seen)

(defun %handlers-among (deps)
  (loop for k being the hash-keys of deps
        when (search "clack-handler-" k) collect k))

(test praxeon-web-declares-no-http-backend
  ;; The framework system must not choose for the app.
  (let ((deps (%asd-deps "praxeon/web")))
    (is (null (%handlers-among deps))
        "praxeon/web pulls an HTTP handler again: ~S -- see pre-publication issue 139/pre-publication issue 218"
        (%handlers-among deps))
    ;; The walk must still be ASKING something. Without this the assertion above passes
    ;; forever if find-system starts returning NIL (a renamed system, a broken registry).
    (is-true (gethash "hyperion" deps)
             "the dependency walk found nothing -- this test has stopped testing anything")))

(test the-elise-app-declares-its-own-backend-and-it-is-not-woo
  ;; The other half: moving the choice up must actually leave it somewhere. An app with
  ;; no handler at all fails at DEFAULT-SERVER, which is loud but is not what we want here.
  (let ((deps (%asd-deps "praxeon/elise")))
    (is-true (gethash "clack-handler-hunchentoot" deps)
             "praxeon/elise no longer declares an HTTP backend -- it will not start")
    (is-false (gethash "clack-handler-woo" deps)
              "praxeon/elise declares Woo, which does not answer SIGTERM (pre-publication issue 218)")))
;;; --- #90: an agent's tools are ASSEMBLED from capabilities ------------------
;;;
;;; The property: a means the caller may not use is ABSENT from the tool table, not
;;; refused at call time. Nothing downstream -- no prompt, no model output, no injected
;;; instruction -- can reach a means that was never advertised, because refusing it is not
;;; a decision anything makes; it is a table that does not contain it.
;;;
;;; praxeon/ceiling has claimed this since pre-publication issue 172. Nothing implemented it: AGENT-TOOL-SPECS
;;; advertised every registered means, and CAPABILITY-GUARD gated a whole TURN rather than
;;; a means. These tests are what make the claim true rather than stated.

(defun %caps-agent ()
  (let ((a (actor:make-agent :name "caps")))
    (actor:register-means a "search" "Search the web" (lambda (x) (declare (ignore x)) "ok"))
    (actor:register-means a "refund" "Issue a refund" (lambda (x) (declare (ignore x)) "refunded")
                          :capability "billing.refund")
    a))

(defun %names (specs) (sort (mapcar #'llm:tool-spec-name specs) #'string<))

(test a-capability-bearing-means-is-absent-without-authority
  ;; Fail closed. A means naming a capability is not available to a caller who presented no
  ;; authority at all -- the alternative makes the property depend on every call site
  ;; remembering to pass something.
  (is (equal '("search") (%names (actor:agent-tool-specs (%caps-agent))))))

(test it-is-present-for-a-grant-that-carries-the-capability
  ;; The control: without this the test above passes against an assembly that drops
  ;; capability-bearing means unconditionally, which would be a different bug.
  (let ((permit (lambda (c) (equal c "billing.refund"))))
    (is (equal '("refund" "search")
               (%names (actor:agent-tool-specs (%caps-agent) :permit permit))))))

(test it-is-absent-for-a-grant-that-does-not
  (let ((permit (lambda (c) (equal c "something.else"))))
    (is (equal '("search") (%names (actor:agent-tool-specs (%caps-agent) :permit permit))))))

(test an-unrestricted-means-is-unaffected-by-any-of-this
  ;; Every means registered before capabilities existed has none, and must stay visible
  ;; whatever authority is or is not supplied.
  (dolist (permit (list nil (lambda (c) (declare (ignore c)) nil)
                        (lambda (c) (declare (ignore c)) t)))
    (is (member "search" (%names (actor:agent-tool-specs (%caps-agent) :permit permit))
                :test #'string=))))

(test the-means-cannot-be-invoked-by-naming-it-either
  ;; Defence in depth, and not belt-and-braces: a model can name a tool it was never
  ;; offered -- from training, from an injected instruction, from a stale history -- and an
  ;; agent can be handed to a workflow that advertises a different table than it invokes
  ;; through. The question must be answerable at the moment of USE.
  (let ((a (%caps-agent)))
    (signals cnd:means-failure (actor:act a "refund" "{}"))
    ;; ...and it IS invokable with authority, or the test above proves only that the means
    ;; is broken.
    (is (string= "refunded"
                 (actor:act a "refund" "{}" :permit (lambda (c) (equal c "billing.refund")))))))

(defun %elide (text name)
  "TEXT with NAME replaced by a placeholder, so two refusals can be compared for anything
OTHER than the name the caller themselves supplied."
  (let ((pos (search name text)))
    (if pos
        (concatenate 'string (subseq text 0 pos) "<NAME>" (subseq text (+ pos (length name))))
        text)))

(test the-refusal-does-not-reveal-that-the-means-exists
  ;; A caller who may not use a means must learn nothing they could not learn by guessing a
  ;; name, or the refusal becomes an enumeration oracle for the tool catalogue: "you may not
  ;; use X" has told an attacker that X exists, which is half of what they wanted.
  ;;
  ;; Asserted on the WHOLE report, not just the cause, and with only the caller's own name
  ;; elided -- so a later, friendlier error message reopens this loudly instead of quietly.
  (let ((a (%caps-agent)))
    (flet ((refusal (name)
             (handler-case (progn (actor:act a name "{}") nil)
               (cnd:means-failure (e)
                 (list :type (type-of e)
                       :cause (princ-to-string (cnd:means-failure-cause e))
                       :report (%elide (princ-to-string e) name))))))
      (let ((forbidden (refusal "refund"))
            (absent    (refusal "no-such-means-at-all")))
        (is (equal forbidden absent)
            "a forbidden means and an absent one must be indistinguishable~%  forbidden: ~S~%  absent:    ~S"
            forbidden absent)
        ;; And the control for the comparison itself: if BOTH were somehow empty the EQUAL
        ;; above would pass while asserting nothing.
        (is (plusp (length (getf forbidden :cause))))
        ;; Nothing may name the capability, or the mechanism, either.
        (is (null (search "billing" (getf forbidden :report))))
        (is (null (search "capab" (string-downcase (getf forbidden :report)))))))))

(test a-grant-becomes-a-permit-predicate
  ;; The bridge: praxeon/ceiling knows grants, praxeon/actor knows means, and a closure is
  ;; all that crosses between them.
  (let* ((grant (ceiling::%make-grant :principal "u1" :capabilities '("billing.refund")
                                      :expires-at 0 :audience "test"))
         (permit (ceiling:grant-permit-fn grant)))
    (is-true (funcall permit "billing.refund"))
    (is-false (funcall permit "billing.void"))
    (is (equal '("refund" "search")
               (%names (actor:agent-tool-specs (%caps-agent) :permit permit))))))

;;; --------------------------------------------------------------------------
;;; Prompt caching: the marker reaches the wire, and the counts come back (pre-publication issue 401)
;;;
;;; NO LIVE CALLS. These verify the two translations against the documented wire shapes --
;;; request (neutral marker -> cache_control) and response (usage -> the two counts) -- which
;;; is everything that can be established without spending the maintainer's API credits.
;;;
;;; WHAT THESE DO NOT PROVE, stated because it is the interesting half: that Anthropic
;;; HONOURS the block we emit. These tests assert the request matches the documented shape;
;;; a provider that changed that shape would leave them green. That is a provider/consumer
;;; disagreement no self-contained test can see, and the way it gets caught is a real call
;;; reporting a nonzero cache_creation_input_tokens -- which needs a key this environment
;;; does not have (pre-publication issue 401 records it as designed-and-translated, not proven end to end).
;;; --------------------------------------------------------------------------
(test a-marked-part-emits-cache-control
  "The neutral :cache marker becomes Anthropic's cache_control on that block, and only that."
  (let* ((plain (praxeon/llm::%part->json (llm:text-part "no marker")))
         (marked (praxeon/llm::%part->json (llm:text-part "prefix ends here" :cache t))))
    (is (null (gethash "cache_control" plain))
        "an unmarked part must carry no cache_control -- a breakpoint on every block is four
breakpoints wasted and, past the provider's limit, an error")
    (let ((cc (gethash "cache_control" marked)))
      (is-true (hash-table-p cc) "a marked part must carry a cache_control object")
      (is (equal "ephemeral" (and (hash-table-p cc) (gethash "type" cc)))))))

(test the-marker-survives-on-a-tool-result-not-only-on-prose
  "A conversation's cacheable prefix commonly ends on a tool_result, so the marker cannot be
a property of text parts alone."
  (let ((ht (praxeon/llm::%part->json
             (append (llm:tool-result-part "call_1" "42") '(:cache t)))))
    (is (equal "tool_result" (gethash "type" ht)))
    (is-true (hash-table-p (gethash "cache_control" ht)))))

(test a-marked-tool-spec-emits-cache-control
  "Tools sit before the system prompt in the prefix, so a large stable tool set is its own
breakpoint."
  (let ((off (praxeon/llm::%tool-spec->json
              (llm:make-tool-spec :name "a" :description "d")))
        (on (praxeon/llm::%tool-spec->json
             (llm:make-tool-spec :name "a" :description "d" :cache t))))
    (is (null (gethash "cache_control" off)))
    (is-true (hash-table-p (gethash "cache_control" on)))))

(test anthropic-usage-distinguishes-a-cache-miss-from-no-cache-reporting
  "0 and NIL are different answers. A provider reporting a miss and a provider reporting
nothing must not look alike, because that is the difference between a misplaced breakpoint
and a backend without a cache."
  (let ((missed (praxeon/llm::%parse-completion
                 (jzon:parse "{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],
                              \"stop_reason\":\"end_turn\",
                              \"usage\":{\"input_tokens\":10,\"output_tokens\":2,
                                         \"cache_read_input_tokens\":0,
                                         \"cache_creation_input_tokens\":0}}")))
        (silent (praxeon/llm::%parse-completion
                 (jzon:parse "{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],
                              \"stop_reason\":\"end_turn\",
                              \"usage\":{\"input_tokens\":10,\"output_tokens\":2}}"))))
    (is (eql 0 (llm:completion-cache-read-tokens missed)) "a reported miss is 0")
    (is (null (llm:completion-cache-read-tokens silent)) "an unreported count is NIL")
    (is (eql 0 (llm:completion-cache-write-tokens missed)))
    (is (null (llm:completion-cache-write-tokens silent)))))

(test anthropic-usage-carries-a-cache-write-and-a-cache-read
  "The two numbers the caller tunes against: one turn pays to write the prefix, the next
reads it."
  (let ((wrote (praxeon/llm::%parse-completion
                (jzon:parse "{\"content\":[],\"stop_reason\":\"end_turn\",
                             \"usage\":{\"input_tokens\":7,\"output_tokens\":1,
                                        \"cache_creation_input_tokens\":1024,
                                        \"cache_read_input_tokens\":0}}")))
        (read (praxeon/llm::%parse-completion
               (jzon:parse "{\"content\":[],\"stop_reason\":\"end_turn\",
                            \"usage\":{\"input_tokens\":7,\"output_tokens\":1,
                                       \"cache_creation_input_tokens\":0,
                                       \"cache_read_input_tokens\":1024}}"))))
    (is (eql 1024 (llm:completion-cache-write-tokens wrote)))
    (is (eql 0 (llm:completion-cache-read-tokens wrote)))
    (is (eql 1024 (llm:completion-cache-read-tokens read)))
    (is (eql 0 (llm:completion-cache-write-tokens read)))))

(test a-system-prompt-of-parts-becomes-blocks-and-a-string-stays-a-string
  "Caching the system prompt is the largest single win -- the measured case was 574 input
tokens against an empty history -- and Anthropic can only cache it when it arrives as blocks.
A plain string must still go out as a plain string, or every existing caller changes shape."
  (let ((as-string (praxeon/llm::%anthropic-system-json "just prose"))
        (as-parts (praxeon/llm::%anthropic-system-json
                   (list (llm:text-part "cache me" :cache t)))))
    (is (stringp as-string) "a string system prompt must not become an array")
    (is-true (vectorp as-parts) "a parts system prompt must become a block array")
    (is-true (hash-table-p (gethash "cache_control" (elt as-parts 0))))))

(test openai-drops-the-marker-and-flattens-a-parts-system-prompt
  "Requirement 3: fail quiet. An OpenAI-compatible server has no caller-controlled
breakpoint, so the marker is dropped rather than translated or rejected -- and a parts system
prompt still has to arrive as the string that API takes."
  (let* ((msgs (praxeon/llm::%messages->openai
                (list (llm:msg "user" (list (llm:text-part "hello" :cache t))))
                (list (llm:text-part "sys prose" :cache t))))
         (json (com.inuoe.jzon:stringify msgs)))
    (is (null (search "cache_control" json))
        "no cache_control may reach an OpenAI-compatible body: it is not in that schema")
    (is (null (search "\"cache\"" json)) "and the neutral key must not leak either")
    (is-true (search "sys prose" json) "the system prompt still has to arrive")))

(test openai-reports-a-cached-read-and-never-invents-a-write
  "OpenAI reports automatic caching as prompt_tokens_details.cached_tokens and has no write
count. NIL is the honest answer for the one it does not report."
  (let ((c (praxeon/llm::%parse-openai
            (jzon:parse "{\"choices\":[{\"message\":{\"content\":\"hi\"},
                          \"finish_reason\":\"stop\"}],
                          \"usage\":{\"prompt_tokens\":100,\"completion_tokens\":5,
                                     \"prompt_tokens_details\":{\"cached_tokens\":64}}}"))))
    (is (eql 64 (llm:completion-cache-read-tokens c)))
    (is (null (llm:completion-cache-write-tokens c))
        "OpenAI reports no cache-write count, so claiming 0 would be inventing a measurement"))
  (let ((bare (praxeon/llm::%parse-openai
               (jzon:parse "{\"choices\":[{\"message\":{\"content\":\"hi\"},
                             \"finish_reason\":\"stop\"}],
                             \"usage\":{\"prompt_tokens\":100,\"completion_tokens\":5}}"))))
    (is (null (llm:completion-cache-read-tokens bare))
        "a server reporting no details leaves the count NIL, not 0")))

;;; --------------------------------------------------------------------------
;;; What is SENT, as distinct from what is remembered (pre-publication issue 402, ADR-0001)
;;;
;;; Two budgets over two kinds of data: retrieved facts are RANKED by
;;; ctx:assemble, conversation history is TRIMMED by prompt:trim-history. The
;;; properties worth asserting are the three the trim exists to keep -- a
;;; tool_use is never orphaned, the cacheable prefix (pre-publication issue 401) never moves, and the
;;; live question is never dropped -- plus the two wirings, since an exported
;;; function with a budget and no caller is what pre-publication issue 402 was filed about.
;;; --------------------------------------------------------------------------

(defun %u (text &key cache)
  "A user message of one text part, optionally the end of the cacheable prefix."
  (llm:msg "user" (list (llm:text-part text :cache cache))))

(defun %a (text)
  "An assistant message of one text part."
  (llm:msg "assistant" (list (llm:text-part text))))

(defun %tool-round (id name result)
  "The two messages of one tool round: the assistant's call and its result."
  (list (llm:msg "assistant" (list (llm:tool-use-part id name (%args))))
        (llm:msg "user" (list (llm:tool-result-part id result)))))

(defun %parts-of (message)
  (let ((c (llm:content message)))
    (if (listp c) c '())))

(test prompt-exchanges-keep-a-tool-round-with-its-caller
  "An exchange is a user turn and everything answering it: a tool-result message
has role user but does not start a new one, or a tool_use could be trimmed away
from its tool_result."
  (let* ((history (append (list (%u "do it"))
                          (%tool-round "t1" "work" "done")
                          (list (%a "finished"))
                          (list (%u "again"))))
         (groups (prompt:exchanges history)))
    (is (= 2 (length groups)) "one exchange per genuine user turn, not per user message")
    (is (= 4 (length (first groups))) "the tool round belongs to the turn that caused it")
    (is-true (prompt:tool-result-message-p (third (first groups))))
    (is-false (prompt:tool-result-message-p (first (first groups))))))

(test prompt-trim-respects-a-token-budget
  "The trim keeps a contiguous tail that fits the estimated budget."
  (let* ((history (loop for i from 1 to 8
                        append (list (%u (format nil "question ~A ~A" i (make-string 200 :initial-element #\q)))
                                     (%a (format nil "answer ~A" i)))))
         (budget 300)
         (kept (prompt:trim-history history budget)))
    (is (<= (prompt:messages-tokens kept) budget)
        "what is sent must fit the budget it was trimmed to")
    (is (< (length kept) (length history)) "and something must actually have been dropped")
    (is (equal (last history 2) (last kept 2))
        "the tail is what survives -- the newest exchange is always sent")
    (is-false (member (first history) kept) "the oldest exchange is what goes")))

(test prompt-trim-is-a-token-budget-not-a-message-count
  "Two histories of the SAME message count, one an order of magnitude longer,
trim differently. A message cap makes the typical case fine and the worst case
unbounded; this is the property that distinguishes the two."
  (let* ((short (loop for i from 1 to 10
                      append (list (%u (format nil "q~A" i)) (%a (format nil "a~A" i)))))
         (long (loop for i from 1 to 10
                     append (list (%u (format nil "q~A ~A" i (make-string 400 :initial-element #\x)))
                                  (%a (format nil "a~A" i)))))
         (budget 400))
    (is (= (length short) (length long)) "the control: identical message counts")
    (is (= (length short) (length (prompt:trim-history short budget)))
        "the short history fits whole")
    (is (< (length (prompt:trim-history long budget)) (length long))
        "the long one does not, at the same budget and the same message count")))

(test prompt-trim-never-orphans-a-tool-result
  "Every tool_result that is sent has its tool_use, and every tool_use its
tool_result. llm::%part->json validates nothing, so an orphan is a malformed
request rather than a worse prompt."
  (let* ((history (loop for i from 1 to 6
                        append (append (list (%u (format nil "task ~A ~A" i
                                                         (make-string 120 :initial-element #\t))))
                                       (%tool-round (format nil "t~A" i) "work"
                                                    (make-string 120 :initial-element #\r))
                                       (list (%a (format nil "done ~A" i))))))
         (kept (prompt:trim-history history 400))
         (uses (loop for m in kept append
                     (loop for p in (%parts-of m)
                           when (eq (getf p :type) :tool-use) collect (getf p :id))))
         (results (loop for m in kept append
                        (loop for p in (%parts-of m)
                              when (eq (getf p :type) :tool-result)
                                collect (getf p :tool-use-id)))))
    (is (< (length kept) (length history))
        "the control: this budget must force a drop, or the assertion below is vacuous")
    (is (null (set-difference results uses :test #'equal))
        "no tool_result may be sent without the call it answers")
    (is (null (set-difference uses results :test #'equal))
        "and no tool_use may be sent without its result")))

(test prompt-trim-pins-the-cacheable-prefix
  "The marked prefix (pre-publication issue 401) survives every trim. Trimming from the front would
write a new cache entry at 1.25x every turn and read none -- and dropping the
marked part leaves no breakpoint at all."
  (let* ((pinned (%u (format nil "system context ~A" (make-string 400 :initial-element #\s))
                     :cache t))
         (history (cons pinned
                        (loop for i from 1 to 6
                              append (list (%u (format nil "q~A ~A" i
                                                       (make-string 200 :initial-element #\q)))
                                           (%a (format nil "a~A" i))))))
         (kept (prompt:trim-history history 300))
         (squeezed (prompt:trim-history history 10)))
    (is (eq pinned (first kept))
        "the pinned message is still there, first, and is the same object")
    (is-true (prompt:cache-boundary-message-p (first kept))
        "and still carries the breakpoint, so there is still a cacheable prefix")
    (is (< (length kept) (length history)) "the control: exchanges after it were dropped")
    (is (<= (prompt:messages-tokens kept) 300) "and what was kept fits the budget")
    (is (eq pinned (first squeezed))
        "at a budget smaller than the prefix itself the prefix still survives")
    (is (> (prompt:messages-tokens squeezed) 10)
        "over budget is the honest outcome there: the prefix is pinned and the live
exchange is never dropped")))

(test prompt-trim-keeps-the-newest-exchange-and-reports-the-overflow
  "A budget too small for the live question does not truncate the question. It
sends it and emits :context-overflow, because obeying our own estimate in
preference to the request would be the wrong way round."
  (let* ((history (loop for i from 1 to 4
                        append (list (%u (format nil "q~A ~A" i
                                                 (make-string 200 :initial-element #\q)))
                                     (%a (format nil "a~A" i)))))
         (events '())
         (kept (evt:with-observer ((lambda (e) (push e events)))
                 (prompt:trim-history history 1)))
         (overflow (find :context-overflow events :key #'evt:event-type))
         (trimmed (find :context-trimmed events :key #'evt:event-type)))
    (is (equal (last history 2) kept) "exactly the newest exchange is sent")
    (is-true overflow ":context-overflow must fire -- an invisible overflow is a silent one")
    (is (> (evt:event-get overflow :estimated-tokens) (evt:event-get overflow :budget))
        "and it carries both numbers, so the reader can see by how much")
    (is-true trimmed ":context-trimmed reports what was dropped")
    (is (= 3 (evt:event-get trimmed :dropped-exchanges)))))

(test prompt-trim-nil-budget-sends-everything
  "NIL means send everything -- the opt-out for a caller that bounds its own
context."
  (let ((history (list (%u "one") (%a "two") (%u "three"))))
    (is (equal history (prompt:trim-history history nil)))))

;;; A provider that records what it was actually sent. The point of pre-publication issue 402 is that
;;; this list is not the agent's history, so nothing but a capture can show it.
(defclass capturing (llm:provider)
  ((seen :initform '() :accessor capturing-seen)
   (script :initarg :script :initform '() :accessor capturing-script))
  (:documentation "Records each MESSAGES list it is handed, newest first."))

(defmethod llm:complete ((p capturing) messages &key system tools max-tokens temperature
                                                 tool-choice)
  (declare (ignore system tools max-tokens temperature tool-choice))
  (push (copy-list messages) (capturing-seen p))
  (or (pop (capturing-script p))
      (llm:make-completion :text "ok" :stop-reason :end :input-tokens 700)))

(defun %sent (provider)
  "The messages PROVIDER was handed on its first (and here only) call."
  (first (last (capturing-seen provider))))

(defun %text-of (messages)
  "All text parts of MESSAGES concatenated -- what the model would read."
  (with-output-to-string (s)
    (dolist (m messages)
      (let ((c (llm:content m)))
        (if (stringp c)
            (write-string c s)
            (dolist (p c)
              (when (eq (getf p :type) :text)
                (write-string (getf p :text) s))))))))

(test deliberate-sends-the-trimmed-history-and-keeps-the-record
  "The trim chooses what is SENT. The agent's history is the record and is not
destroyed by it -- a client rendering agent-history still shows the conversation."
  (let* ((provider (make-instance 'capturing))
         (ag (actor:make-agent :provider provider :history-budget 300)))
    (setf (actor:agent-history ag)
          (loop for i from 1 to 8
                append (list (%u (format nil "q~A ~A" i (make-string 200 :initial-element #\q)))
                             (%a (format nil "a~A" i)))))
    (let ((before (length (actor:agent-history ag))))
      (actor:run-turn ag "the live question")
      (is (< (length (%sent provider)) before)
          "less was sent than the agent remembers")
      (is (= (+ 2 before) (length (actor:agent-history ag)))
          "and the record GREW -- by the live question and the reply -- rather than
shrinking to what was sent"))))

(test deliberate-unbudgeted-agent-sends-everything
  "The control for the test above: with no history budget, the whole history goes,
so the difference measured there is the trim and not something else."
  (let* ((provider (make-instance 'capturing))
         (ag (actor:make-agent :provider provider :history-budget nil)))
    (setf (actor:agent-history ag)
          (loop for i from 1 to 8
                append (list (%u (format nil "q~A ~A" i (make-string 200 :initial-element #\q)))
                             (%a (format nil "a~A" i)))))
    (actor:run-turn ag "the live question")
    (is (= 17 (length (%sent provider))) "16 remembered messages plus the live one")))

(test context-items-reach-the-provider-and-stay-out-of-the-record
  "ctx:assemble now has a caller: the assembled facts are placed in the request.
They are not written into the history, which would make them permanent and pay
for them again on every later turn."
  (let* ((provider (make-instance 'capturing))
         (ag (actor:make-agent :provider provider)))
    (ctx:add-item (actor:agent-context ag)
                  (ctx:make-ctx-item :content "the policy expires in March"
                                     :tokens 10 :value 100 :role :note))
    (actor:run-turn ag "when does it expire")
    (is-true (search "the policy expires in March" (%text-of (%sent provider)))
             "an assembled item must reach the model, or the budget governs nothing")
    (is-false (search "the policy expires in March"
                      (%text-of (actor:agent-history ag)))
              "and must not be written back into the conversation record")))

(test context-items-honour-the-budget-they-are-assembled-under
  "The context budget is the one that governs facts: an item that does not fit is
not sent. The control is the same item under a budget that fits."
  (let* ((provider (make-instance 'capturing))
         (ag (actor:make-agent :provider provider
                               :context (ctx:make-context :budget 5))))
    (ctx:add-item (actor:agent-context ag)
                  (ctx:make-ctx-item :content "too expensive to include"
                                     :tokens 500 :value 1 :role :note))
    (actor:run-turn ag "hello")
    (is-false (search "too expensive" (%text-of (%sent provider)))
              "an item over the context budget is not sent"))
  (let* ((provider (make-instance 'capturing))
         (ag (actor:make-agent :provider provider
                               :context (ctx:make-context :budget 5000))))
    (ctx:add-item (actor:agent-context ag)
                  (ctx:make-ctx-item :content "too expensive to include"
                                     :tokens 500 :value 1 :role :note))
    (actor:run-turn ag "hello")
    (is-true (search "too expensive" (%text-of (%sent provider)))
             "the same item under a budget that fits is sent -- so the assertion above
was about the budget and not about the wiring")))

(test context-items-are-placed-after-the-cacheable-prefix
  "Retrieved facts change every turn, so putting them inside the cached region
would invalidate the cache on every request -- the same mistake as trimming
through the prefix, from the other side."
  (let* ((provider (make-instance 'capturing))
         (ag (actor:make-agent :provider provider)))
    (setf (actor:agent-history ag) (list (%u "stable system context" :cache t)))
    (ctx:add-item (actor:agent-context ag)
                  (ctx:make-ctx-item :content "a fact retrieved this turn"
                                     :tokens 10 :value 100 :role :note))
    (actor:run-turn ag "the live question")
    (let* ((sent (%sent provider))
           (boundary (position-if #'prompt:cache-boundary-message-p sent))
           (fact (position-if (lambda (m)
                                (search "a fact retrieved this turn" (%text-of (list m))))
                              sent)))
      (is-true boundary "the breakpoint is still in what was sent")
      (is-true fact "and so is the fact")
      (is (> fact boundary) "the fact comes after the breakpoint, never inside it"))))

(test usage-event-carries-the-estimate-beside-the-measurement
  "Our estimate is a claim; the provider's count is the measurement. Both travel
on one event so they can be made to meet -- a budget enforced against an estimate
nobody compares is how a bound silently stops bounding."
  (let* ((provider (make-instance 'capturing))
         (ag (actor:make-agent :provider provider))
         (events '()))
    (evt:with-observer ((lambda (e) (push e events)))
      (actor:run-turn ag "hello"))
    (let ((usage (find :usage events :key #'evt:event-type)))
      (is-true usage)
      (is (= 700 (evt:event-get usage :input)) "what the provider charged")
      (is (plusp (evt:event-get usage :estimated-input))
          "and what we estimated when we enforced the budget"))))

(test studio-reports-both-budgets
  "describe-agent used to print the context budget as the agent's one budget,
for an agent whose context was not budgeted in any respect. Two budgets, two keys."
  (let* ((ag (actor:make-agent :history-budget 4242
                               :context (ctx:make-context :budget 99)))
         (s (praxeon/studio:agent-summary ag)))
    (is (= 99 (getf s :context-budget)))
    (is (= 4242 (getf s :history-budget)))
    (is (null (getf s :budget))
        "the single :budget key was the false claim and must be gone")
    (let ((printed (with-output-to-string (out)
                     (praxeon/studio:describe-agent ag out))))
      (is-true (search "4242" printed) "the history budget is what the reader needs to see"))))

;;; --------------------------------------------------------------------------
;;; Forced tool choice and structured results (pre-publication issue 416)
;;; --------------------------------------------------------------------------

(in-suite praxeon)
;;;
;;; Every assertion here reads the request body the backend BUILDS, not the arguments
;;; passed to it. Asserting the arguments would pass whether or not the translation
;;; happened, which is the whole thing under test.

(defun %json-of (body) (jzon:stringify body))

(defun %spec ()
  "A tool-spec whose schema requires a string headline and an integer length."
  (let ((schema (make-hash-table :test #'equal))
        (props (make-hash-table :test #'equal))
        (headline (make-hash-table :test #'equal))
        (chars (make-hash-table :test #'equal)))
    (setf (gethash "type" headline) "string"
          (gethash "type" chars) "integer"
          (gethash "headline" props) headline
          (gethash "characters" props) chars
          (gethash "type" schema) "object"
          (gethash "properties" schema) props
          (gethash "required" schema) (vector "headline" "characters"))
    (llm:make-tool-spec :name "draft_copy" :description "Draft one piece of copy."
                        :schema schema)))

;;; --- the request JSON, both providers ---------------------------------------

(test anthropic-forced-choice-reaches-the-request-body
  (let* ((p (make-instance 'llm:anthropic :api-key "k" :model "m"))
         (body (llm:anthropic-request-body p '((:role :user :content "hi"))
                                           :tools (list (%spec))
                                           :tool-choice '(:tool "draft_copy")))
         (json (%json-of body)))
    (is (search "\"tool_choice\"" json))
    (is (search "\"type\":\"tool\"" json))
    (is (search "\"name\":\"draft_copy\"" json))))

(test openai-forced-choice-reaches-the-request-body
  "The same neutral value, a different wire shape: OpenAI names a FUNCTION and takes a bare
string for the other cases. That difference is what the neutral value exists to hide."
  (let* ((p (make-instance 'llm:openai-compatible :base-url "http://x" :model "m"))
         (body (llm:openai-request-body p '((:role :user :content "hi"))
                                        :tools (list (%spec))
                                        :tool-choice '(:tool "draft_copy")))
         (json (%json-of body)))
    (is (search "\"tool_choice\"" json))
    (is (search "\"type\":\"function\"" json))
    (is (search "\"name\":\"draft_copy\"" json))))

(test none-reaches-both-request-bodies-in-each-provider-s-own-shape
  (let ((a (%json-of (llm:anthropic-request-body
                      (make-instance 'llm:anthropic :api-key "k" :model "m")
                      '((:role :user :content "hi")) :tools (list (%spec))
                      :tool-choice :none)))
        (o (%json-of (llm:openai-request-body
                      (make-instance 'llm:openai-compatible :base-url "http://x" :model "m")
                      '((:role :user :content "hi")) :tools (list (%spec))
                      :tool-choice :none))))
    (is (search "\"type\":\"none\"" a) "Anthropic takes an object")
    (is (search "\"tool_choice\":\"none\"" o) "OpenAI takes a bare string")))

;;; --- :auto changes nothing --------------------------------------------------

(test auto-adds-nothing-to-either-request-body
  "The property that makes every existing agent provably unaffected: asking for :auto
produces the same bytes as not asking at all, and neither carries a tool_choice key."
  (let* ((a (make-instance 'llm:anthropic :api-key "k" :model "m"))
         (o (make-instance 'llm:openai-compatible :base-url "http://x" :model "m"))
         (msgs '((:role :user :content "hi")))
         (tools (list (%spec))))
    (let ((without (%json-of (llm:anthropic-request-body a msgs :tools tools)))
          (with-auto (%json-of (llm:anthropic-request-body a msgs :tools tools
                                                                  :tool-choice :auto))))
      (is (string= without with-auto) "anthropic: :auto is byte-identical to omitting it")
      (is-false (search "tool_choice" without)))
    (let ((without (%json-of (llm:openai-request-body o msgs :tools tools)))
          (with-auto (%json-of (llm:openai-request-body o msgs :tools tools
                                                               :tool-choice :auto))))
      (is (string= without with-auto) "openai: :auto is byte-identical to omitting it")
      (is-false (search "tool_choice" without)))))

;;; --- a provider that cannot honour it must signal ---------------------------

(defclass %no-choice-provider (llm:provider) ())

(test a-provider-that-cannot-force-a-tool-signals-rather-than-downgrading
  "A silent fall back to :auto returns prose to a caller about to treat it as a record, and
nothing downstream can tell until it is stored."
  (let ((p (make-instance '%no-choice-provider)))
    (is-false (llm:supports-tool-choice-p p) "the default is no, not yes")
    (signals cnd:tool-choice-unsupported (llm:check-tool-choice p '(:tool "draft_copy")))
    (signals cnd:tool-choice-unsupported (llm:check-tool-choice p :none))))

(test the-same-provider-accepts-auto
  "The other direction: refusing everything would pass the test above while breaking every
existing caller."
  (let ((p (make-instance '%no-choice-provider)))
    (finishes (llm:check-tool-choice p :auto))
    (finishes (llm:check-tool-choice p nil))))

(test both-real-providers-declare-they-can-force-a-tool
  (is-true (llm:supports-tool-choice-p (make-instance 'llm:anthropic :api-key "k" :model "m")))
  (is-true (llm:supports-tool-choice-p
            (make-instance 'llm:openai-compatible :base-url "http://x" :model "m"))))

;;; --- generate-structured: validation and repair -----------------------------

(defun %call-completion (name args)
  (llm:make-completion :text "" :stop-reason :tool-use
                       :tool-calls (list (llm:make-tool-call :id "c1" :name name
                                                             :arguments args))))

(test a-valid-call-is-returned-as-arguments
  (let* ((p (make-instance 'recording
                           :script (list (%call-completion
                                          "draft_copy"
                                          (%args "headline" "Ship it" "characters" 7)))))
         (result (llm:generate-structured p '((:role :user :content "brief")) (%spec))))
    (is (string= "Ship it" (gethash "headline" result)))
    (is (= 1 (length (recording-requests p))) "one request when the first reply is good")))

(test the-forced-choice-is-what-generate-structured-sends
  (let ((p (make-instance 'recording
                          :script (list (%call-completion
                                         "draft_copy"
                                         (%args "headline" "x" "characters" 1))))))
    (llm:generate-structured p '((:role :user :content "brief")) (%spec))
    (is (equal '(:tool "draft_copy")
               (getf (first (recording-requests p)) :tool-choice)))))

(test a-missing-required-property-is-rejected
  "GENUINELY MALFORMED: `characters' is required by the schema and absent. A helper that
supplied valid arguments would test nothing here."
  (let ((p (make-instance 'recording
                          :script (list (%call-completion "draft_copy"
                                                          (%args "headline" "Ship it"))))))
    (signals llm:structured-result-invalid
      (llm:generate-structured p '((:role :user :content "brief")) (%spec) :attempts 1))))

(test a-property-of-the-wrong-type-is-rejected
  "The second failure mode prose-parsing cannot catch: the right name with the wrong type."
  (let ((p (make-instance 'recording
                          :script (list (%call-completion
                                         "draft_copy"
                                         (%args "headline" "Ship it" "characters" "seven"))))))
    (signals llm:structured-result-invalid
      (llm:generate-structured p '((:role :user :content "brief")) (%spec) :attempts 1))))

(test the-condition-names-every-problem-not-the-first
  "The repair prompt is built from these, so reporting one at a time turns one re-ask into
several."
  (let ((p (make-instance 'recording
                          :script (list (%call-completion "draft_copy" (%args))))))
    (handler-case
        (progn (llm:generate-structured p '((:role :user :content "b")) (%spec) :attempts 1)
               (fail "expected STRUCTURED-RESULT-INVALID"))
      (llm:structured-result-invalid (c)
        (is (= 2 (length (llm:structured-result-invalid-problems c)))
            "both required properties are missing, so both are reported")))))

(test the-repair-restart-re-asks-and-the-second-reply-is-accepted
  "The measurement is the REQUEST COUNT: two requests, not one, proves the re-ask happened
rather than the first reply having been accepted after all."
  (let* ((p (make-instance 'recording
                           :script (list (%call-completion "draft_copy"
                                                           (%args "headline" "Ship it"))
                                         (%call-completion "draft_copy"
                                                           (%args "headline" "Ship it"
                                                                  "characters" 7)))))
         (result (llm:generate-structured p '((:role :user :content "brief")) (%spec)
                                          :attempts 3)))
    (is (string= "Ship it" (gethash "headline" result)))
    (is (= 7 (gethash "characters" result)))
    (is (= 2 (length (recording-requests p))) "exactly one repair")))

(test the-repair-loop-is-bounded
  "An unbounded repair against a metered API is a bill rather than a retry."
  (let ((p (make-instance 'recording
                          :script (loop repeat 5
                                        collect (%call-completion "draft_copy"
                                                                  (%args "headline" "x"))))))
    (signals llm:structured-result-invalid
      (llm:generate-structured p '((:role :user :content "b")) (%spec) :attempts 3))
    (is (= 3 (length (recording-requests p))) "three attempts, then it stops")))

(test a-caller-can-handle-the-condition-instead-of-the-default-repair
  "The restart exists so the decision belongs to the caller. Declining to re-ask stops after
one request."
  (let ((p (make-instance 'recording
                          :script (loop repeat 3
                                        collect (%call-completion "draft_copy"
                                                                  (%args "headline" "x"))))))
    (handler-case
        (llm:generate-structured p '((:role :user :content "b")) (%spec) :attempts 3)
      ;; The caller watches REJECTIONS and stops on the first one. A different type from the
      ;; final failure, so watching rejections does not mean catching the error.
      (llm:structured-result-rejected () nil))
    (is (= 1 (length (recording-requests p)))
        "the caller took control on the first rejection, so no repair was attempted")))

(test a-reply-that-calls-nothing-is-a-different-failure
  "Not the same as bad arguments: the provider accepted a forced choice and returned
something else. Returning its prose would hand a caller expecting a record a paragraph."
  (let ((p (make-instance 'recording
                          :script (list (llm:make-completion :text "Here is some copy."
                                                             :stop-reason :end)))))
    (signals llm:structured-result-not-called
      (llm:generate-structured p '((:role :user :content "b")) (%spec)))))

;;; --- caller-supplied constraints --------------------------------------------

(test a-caller-s-validator-runs-and-its-message-reaches-the-condition
  "Length limits are facts about someone else's platform. The framework runs the predicate;
the caller supplies the number, because a table of limits here would be stale and
unoverridable."
  (let* ((spec (%spec))
         (limited (llm:make-tool-spec
                   :name (llm:tool-spec-name spec)
                   :description (llm:tool-spec-description spec)
                   :schema (llm:tool-spec-schema spec)
                   :validators
                   (list (lambda (args)
                           (let ((h (gethash "headline" args)))
                             (when (and h (> (length h) 10))
                               "headline is longer than 10 characters"))))))
         (p (make-instance 'recording
                           :script (list (%call-completion
                                          "draft_copy"
                                          (%args "headline" "A headline that is far too long"
                                                 "characters" 31))))))
    (handler-case
        (progn (llm:generate-structured p '((:role :user :content "b")) limited :attempts 1)
               (fail "expected the caller's validator to reject this"))
      (llm:structured-result-invalid (c)
        (is (search "longer than 10"
                    (first (llm:structured-result-invalid-problems c))))))))

(test a-schema-valid-result-passes-the-caller-s-validator-when-it-should
  "The other direction, so the validator is not simply rejecting everything."
  (let* ((spec (%spec))
         (limited (llm:make-tool-spec
                   :name (llm:tool-spec-name spec) :description "d"
                   :schema (llm:tool-spec-schema spec)
                   :validators (list (lambda (args)
                                       (let ((h (gethash "headline" args)))
                                         (when (and h (> (length h) 10))
                                           "too long"))))))
         (p (make-instance 'recording
                           :script (list (%call-completion "draft_copy"
                                                           (%args "headline" "Ship it"
                                                                  "characters" 7))))))
    (is (string= "Ship it"
                 (gethash "headline"
                          (llm:generate-structured p '((:role :user :content "b")) limited))))))
;;; pre-publication issue 418: PARALLEL actually runs its children at the same time.
;;;
;;; The claim under test is about CONCURRENCY, so the assertions are about overlap rather
;;; than about elapsed time. A duration is a number about this machine's load: on a loaded
;;; runner a concurrent implementation can take longer than a sequential one did on an idle
;;; laptop, and a threshold tuned to make that pass is a test that has stopped testing.
;;;
;;; So the provider BLOCKS UNTIL EVERY CHILD HAS ARRIVED. Run concurrently, all N reach the
;;; barrier and it opens. Run sequentially, the first child waits for siblings that cannot
;;; start until it returns, the wait times out, and the barrier is never reached. The outcome
;;; is a boolean about what happened, not a stopwatch reading -- and on the sequential
;;; implementation it is FALSE rather than slow.
;;; --------------------------------------------------------------------------

(defclass barrier (llm:provider)
  ((n :initarg :n :reader barrier-n)
   (timeout :initarg :timeout :initform 3.0 :reader barrier-timeout)
   (lock :initform (bt:make-lock "px-barrier") :reader barrier-lock)
   (arrived :initform 0 :accessor barrier-arrived)
   (in-flight :initform 0 :accessor barrier-in-flight)
   (peak :initform 0 :accessor barrier-peak)
   (reached :initform nil :accessor barrier-reached)
   (systems :initform '() :accessor barrier-systems))
  (:documentation "A provider that does not answer until N calls are in flight at once.

Shared by every child of the group on purpose: it is the counting point, and it demonstrates
the contract `parallel' documents -- a provider two children share must be safe to call
concurrently. This one is, by a lock. A test double that popped from a script list would not
be, which is why the other workflow tests give each child its own."))

;;; TOOL-CHOICE is accepted and ignored: pre-publication PR 420 added it to the generic, which obliges every
;;; method to take it. A stub that omits it errors at call time rather than at compile time,
;;; so the omission survives a build and fails in the suite it was written for.
(defmethod llm:complete ((p barrier) messages
                         &key system tools max-tokens temperature tool-choice)
  (declare (ignore messages tools max-tokens temperature tool-choice))
  (bt:with-lock-held ((barrier-lock p))
    (incf (barrier-arrived p))
    (incf (barrier-in-flight p))
    (setf (barrier-peak p) (max (barrier-peak p) (barrier-in-flight p)))
    ;; What each call SENT, so the shared-prefix question can be asked of the same run.
    (push (or system "") (barrier-systems p)))
  ;; IN-FLIGHT, NOT CUMULATIVE ARRIVALS, and the control is why. The first version of this
  ;; waited for `arrived >= n' -- a total that keeps climbing -- so on the SEQUENTIAL
  ;; implementation the fifth child still pushed the count to 5, set `reached', and the
  ;; assertion went green on the very thing it existed to refuse. Only the `peak' check caught
  ;; it. Simultaneity is what "parallel" claims, so simultaneity is what is waited on.
  (let ((deadline (+ (get-internal-real-time)
                     (* (barrier-timeout p) internal-time-units-per-second))))
    (loop for together = (bt:with-lock-held ((barrier-lock p))
                           (>= (barrier-in-flight p) (barrier-n p)))
          when together do (setf (barrier-reached p) t) (return)
          when (> (get-internal-real-time) deadline) do (return)
          do (sleep 0.005)))
  (bt:with-lock-held ((barrier-lock p)) (decf (barrier-in-flight p)))
  (llm:make-completion :text "answered" :stop-reason :end))

(defun %barrier-flow (provider n &key (system ""))
  "A workflow whose single PARALLEL group has N children, all sharing PROVIDER."
  (apply #'wf:make-workflow :fan "fan out"
         (list (apply #'wf:parallel
                      (loop for i from 1 to n
                            collect (wf:step (format nil "child~D" i)
                                             (actor:make-agent
                                              :name (format nil "child~D" i)
                                              :system-prompt system
                                              :provider provider)
                                             "do the thing"))))))

(test parallel-children-are-in-flight-at-the-same-time
  "The children of a PARALLEL group overlap. The provider does not answer until all of them
have arrived, so a sequential implementation cannot get past the first one."
  (let* ((n 5)
         (p (make-instance 'barrier :n n :timeout 3.0))
         (bb (wf:run-workflow (%barrier-flow p n))))
    (is-true (barrier-reached p)
             "the barrier was never reached -- the children did not overlap, so this ran sequentially")
    (is (= n (barrier-peak p))
        "peak concurrent provider calls was ~D, not ~D" (barrier-peak p) n)
    (is (= n (barrier-arrived p)))
    ;; And the group still did its actual job.
    (is (string= "answered" (wf:bb-result bb :child1)))
    (is (string= "answered" (wf:bb-result bb :child5)))
    (is (= n (length (wf:bb-order bb))))))

(test parallel-merges-in-declaration-order-not-completion-order
  "Whatever order the threads finish in, the blackboard's ORDER is the order the group
declared its children -- so a run is reproducible and BB-FINAL is not a race."
  (let* ((n 4)
         (p (make-instance 'barrier :n n :timeout 3.0)))
    (wf:run-workflow (%barrier-flow p n))
    (dotimes (i 3)
      ;; IGNORABLE, not IGNORE. DOTIMES's expansion references its own index variable, so
      ;; declaring it IGNORE tells the compiler the body must not use a variable the macro
      ;; does use, and SBCL reports it.
      (declare (ignorable i))
      (let* ((p2 (make-instance 'barrier :n n :timeout 3.0))
             (bb (wf:run-workflow (%barrier-flow p2 n))))
        (is (equal '("child1" "child2" "child3" "child4") (wf:bb-order bb))
            "declaration order was not preserved: ~S" (wf:bb-order bb))))))

(test a-fanned-out-childs-events-still-reach-the-observer
  "A dynamic binding made by the caller is NOT visible to a thread it spawned, so a naive
fan-out drops every event its children emit -- including :usage, which is the token ledger.
The observer's binding is captured and re-established inside each child."
  (let* ((n 3)
         (p (make-instance 'barrier :n n :timeout 3.0))
         (lock (bt:make-lock "px-obs"))
         (seen '()))
    (evt:with-observer ((lambda (e)
                          (bt:with-lock-held (lock) (push (getf e :type) seen))))
      (wf:run-workflow (%barrier-flow p n)))
    (let ((steps (count :workflow-step seen)))
      (is (= n steps)
          "the observer saw ~D :workflow-step events from ~D fanned-out children" steps n))
    ;; The children really did deliberate on their own threads -- not a sequential fallback
    ;; that happened to keep the binding.
    (is-true (barrier-reached p))
    (is (find :answer seen)
        "no :answer event from any child reached the observer")))

(test one-child-signalling-does-not-discard-its-siblings-work
  "The sequential version unwound on the first error: children after it never ran and
children before it were discarded with the accumulated writes. Every child now runs to
completion, what succeeded is merged, and the condition names both sides."
  (let* ((ok1 (%scripted-agent "ok1" "first"))
         (ok2 (%scripted-agent "ok2" "second"))
         ;; No provider at all: `deliberate' signals DELIBERATION-FAILURE.
         (boom (actor:make-agent :name "boom" :provider nil))
         (flow (wf:make-workflow
                :fan "fan out"
                (wf:parallel
                 (wf:step :ok1 ok1 "a")
                 (wf:step :boom boom "b")
                 (wf:step :ok2 ok2 "c")))))
    (handler-case
        (progn (wf:run-workflow flow)
               (fail "a failing child did not signal"))
      (cnd:parallel-child-failure (e)
        (is (equal '("boom") (mapcar #'car (cnd:parallel-child-failure-failures e)))
            "the condition named ~S as failing" (mapcar #'car (cnd:parallel-child-failure-failures e)))
        (is (equal '("ok1" "ok2") (cnd:parallel-child-failure-completed e))
            "the condition reported ~S as completed" (cnd:parallel-child-failure-completed e))
        (is (typep (cdr (first (cnd:parallel-child-failure-failures e))) 'error)
            "the failing child's own condition was not carried")))
    ;; NOT MERELY REPORTED AS COMPLETED -- the siblings' work survives where the caller can
    ;; see it. The agents belong to the caller, so their histories are the evidence that the
    ;; turns actually happened and were not rolled back.
    (is (plusp (length (actor:agent-history ok1)))
        "ok1 ran but its turn was discarded")
    (is (plusp (length (actor:agent-history ok2)))
        "ok2 ran but its turn was discarded")))

(test two-children-sharing-one-agent-get-a-deterministic-transcript
  "`run-turn' appends to the agent it is given, so two children sharing one agent would
interleave into one history list. Each child runs against its own VIEW of the agent -- the
same isolation the blackboard already had -- and the views merge at the join in declaration
order, so the transcript is the same on every run."
  (let* ((n 2)
         (p (make-instance 'barrier :n n :timeout 3.0))
         (shared (actor:make-agent :name "shared" :provider p))
         (flow (wf:make-workflow
                :fan "fan out"
                (wf:parallel
                 (wf:step :a shared "prompt A")
                 (wf:step :b shared "prompt B")))))
    (wf:run-workflow flow)
    (is-true (barrier-reached p) "the two children did not overlap")
    ;; Two turns, each `user' then `assistant', appended WHOLE rather than interleaved.
    ;; Asserted on roles and on the user prompts: an assistant message's content is a list of
    ;; parts rather than a string, and this test is about ORDERING, not about part encoding.
    (let* ((history (actor:agent-history shared))
           (roles (mapcar #'llm:role history))
           (prompts (loop for m in history
                          when (string= "user" (llm:role m)) collect (llm:content m))))
      (is (= 4 (length history)) "expected 4 messages, got ~D" (length history))
      (is (equal '("user" "assistant" "user" "assistant") roles)
          "the turns interleaved rather than appending whole: ~S" roles)
      (is (equal '("prompt A" "prompt B") prompts)
          "the shared agent's turns are not in declaration order: ~S" prompts))))

(test the-shared-prefix-is-in-flight-n-times-under-fan-out
  "MEASURED, and it is a cost rather than a win. N children over one large shared prefix
ideally cost one cache WRITE and N-1 READS, which holds only while the calls are ORDERED.
Concurrently every call leaves before any returns, so all N send the same prefix with nothing
yet cached and whether the provider records 1 write or N is a race this code does not
control. A caller who cares should warm the prefix with one turn before fanning out; that is
the caller's decision because only the caller knows whether the prefix is worth a serial
round-trip. See pre-publication issue 417 for the ledger that makes the difference visible."
  (let* ((n 5)
         (prefix (make-string 4000 :initial-element #\x))
         (p (make-instance 'barrier :n n :timeout 3.0)))
    (wf:run-workflow (%barrier-flow p n :system prefix))
    (is (= n (barrier-peak p))
        "peak in-flight was ~D of ~D" (barrier-peak p) n)
    (is (= n (length (barrier-systems p))))
    (is (= n (count prefix (barrier-systems p) :test #'string=))
        "~D of ~D calls carried the identical prefix -- all of them were in flight together"
        (count prefix (barrier-systems p) :test #'string=) n)))

;;; --- the first producer of a marked prefix (pre-publication issue 437) ----------------------------
;;;
;;; pre-publication issue 401 built the marker, pre-publication issue 402 built the pinning that protects it, pre-publication issue 417 built the ledger that
;;; prices it -- and nothing produced one. Four consumers, a constructor, and no caller outside
;;; this suite. The cause was a TYPE: `agent-system-prompt' is declared a STRING, so the one
;;; thing an agent has that is large, stable and byte-identical every turn could not carry a
;;; marked part. Every test built parts by hand, exercising the marker on a path no agent could
;;; take.
;;;
;;; These assert the PRODUCER at its seam -- what DELIBERATE hands the provider as :SYSTEM. That
;;; a request body reaching the wire carries `cache_control' is pre-publication issue 437's own harness, on the
;;; Windows lane, deliberately not duplicated here: a producer verifying its own output cannot
;;; see a producer/consumer disagreement.

(defclass system-capturing (llm:provider)
  ((seen :initform :none :accessor system-capturing-seen))
  (:documentation "Records the :SYSTEM it was handed, and nothing else."))

(defmethod llm:complete ((p system-capturing) messages &key system tools max-tokens temperature
                                                        tool-choice)
  ;; TOOL-CHOICE is in the lambda list because the GENERIC grew it (pre-publication issue 416) -- a method that
  ;; omits a keyword the generic declares is not congruent, and SBCL refuses to add it. Main
  ;; moving under a branch shows up here rather than anywhere subtle.
  (declare (ignore messages tools max-tokens temperature tool-choice))
  (setf (system-capturing-seen p) system)
  (llm:make-completion :text "ok" :stop-reason :end))

(defun %system-seen (&key cache-system (prompt "a large stable brief"))
  "The :SYSTEM one turn hands the provider, for an agent configured this way."
  (let* ((provider (make-instance 'system-capturing))
         (agent (actor:make-agent :provider provider :system-prompt prompt
                                  :cache-system cache-system)))
    (actor:run-turn agent "a short question")
    (system-capturing-seen provider)))

(test an-agent-that-asks-for-it-sends-a-marked-system-prompt
  (let ((system (%system-seen :cache-system t)))
    (is (listp system) "a list of parts rather than a string, which is what carries a marker")
    (is (= 1 (length system)))
    (is-true (llm:cache-boundary-p (first (last system)))
             "and the LAST part is the marked one -- `:cache t' means the prefix ends HERE,
inclusive, so a boundary one part early silently caches less while looking identical in a count")
    (is (string= "a large stable brief" (getf (first system) :text))
        "the prompt itself is unchanged")))

(test an-agent-that-does-not-ask-gets-no-marker
  "The control, and the property that makes the opt-in an opt-in: a prefix cache is a billing
behaviour, and one that arrived without being asked for would be a surprise in a line item."
  (let ((system (%system-seen)))
    (is (stringp system) "a plain string, exactly as before pre-publication issue 437")
    (is (string= "a large stable brief" system))))

(test an-empty-system-prompt-is-not-marked
  "Marking nothing is not a prefix, and it would put a cache_control block on an empty string."
  (let ((system (%system-seen :cache-system t :prompt "")))
    (is (stringp system) "left as the string it was")
    (is (string= "" system))))

(test the-message-pinning-has-nothing-to-do-under-this-producer
  "Recorded as a test rather than a comment because it corrects an argument made when this
shape was chosen. The marker lives on the SYSTEM prompt; `pinned-exchange-count' scans MESSAGES.
So the pinning pre-publication issue 402 built is inert on the actor path -- which is fine, and it means the two
features do not meet until a second producer marks a boundary inside the conversation. When one
arrives, this test fails and says so."
  (let* ((provider (make-instance 'system-capturing))
         (agent (actor:make-agent :provider provider :system-prompt "brief" :cache-system t)))
    (actor:run-turn agent "q")
    (let ((sent (actor:request-messages agent)))
      (is (zerop (prompt:pinned-exchange-count (prompt:exchanges sent)))
          "no message carries a boundary, so nothing is pinned against trimming")
      (is-true (llm:cache-boundary-p (first (actor:agent-system-parts agent)))
               "while the system prompt does carry one -- the control, so the zero above is
about WHERE the marker is and not about there being none"))))

;;; --- data through parameterised means (pre-publication issue 400, ADR-0002) -----------------------
;;;
;;; The pattern: a means per query, parameterised; the model SELECTS a question and supplies
;;; arguments, and never composes the query. ADR-0002 makes four claims, and three of them are
;;; praxeon's -- asserted here, because a pattern document with no exercised example is #94 and
;;; #161 one level up: a mandated path nothing walks.
;;;
;;; The fourth claim -- that a value travels as a BIND PARAMETER rather than interpolated SQL --
;;; is mnemosyne's guarantee and is asserted in mnemosyne's own suite, which reads back the
;;; parameter list. A praxeon test of it would be measuring this file's own fake: a producer
;;; checking its own output, for an invariant this framework does not own. Cited, not re-measured.

(defparameter +contacts+
  '(("acme" "ada@acme.example" :public)
    ("acme" "ceo@acme.example" :restricted)
    ("globex" "gil@globex.example" :public))
  "A stand-in data layer. Rows are (company address visibility).")

(defun %contacts-for (&key asker company)
  "The rows ASKER may see at COMPANY. A FIXED query shape -- the arguments narrow it, they do not
widen it -- which is the whole of what the pattern buys at this layer."
  (loop for (co address visibility) in +contacts+
        when (and (string= co company)
                  (or (eq visibility :public) (string= asker "auditor")))
          collect address))

(defun %one-required-string (name description)
  "A JSON schema for a single required string property -- the same shape ADR-0002's example
builds. NOT `%args': that makes a string-keyed table of ARGUMENT VALUES, and passing one as a
schema is how the first draft of this test asserted `properties' of NIL."
  (let ((prop (make-hash-table :test 'equal))
        (props (make-hash-table :test 'equal))
        (schema (make-hash-table :test 'equal)))
    (setf (gethash "type" prop) "string"
          (gethash "description" prop) description)
    (setf (gethash name props) prop)
    (setf (gethash "type" schema) "object"
          (gethash "properties" schema) props
          (gethash "required" schema) (vector name))
    schema))

(defun %register-contacts-means (agent asker)
  "ONE registration, serving every caller. ASKER is closed over by the HOST and is not in the
schema, so the model cannot choose it."
  (actor:register-means
   agent "contacts-at-company"
   "Find contacts at a company, limited to what the asker may see."
   (lambda (args)
     (format nil "~{~A~^,~}"
             (%contacts-for :asker asker :company (gethash "company" args))))
   :schema (%one-required-string "company" "The company name to search for.")
   :capability "read:contacts"))

(defun %ask-for-company (company)
  "A scripted turn in which the model calls the data means with COMPANY."
  (list (llm:make-completion
         :tool-calls (list (llm:make-tool-call :id "t1" :name "contacts-at-company"
                                              :arguments (%args "company" company)))
         :stop-reason :tool-use)
        (llm:make-completion :text "answered" :stop-reason :end)))

(defun %contacts-permit ()
  "A permit granting exactly the data capability -- what a host derives from a signed grant with
`ceiling:grant-permit-fn'."
  (lambda (capability) (string= capability "read:contacts")))

(test the-pattern-runs-through-the-turn-loop-only-with-authority
  "The path an app actually uses. Until pre-publication issue 400 `run-turn' took no PERMIT, so every
capability-bearing means -- which is what ADR-0002 recommends -- was invisible and uninvocable
through the framework's main entry point. Found by writing the ADR's own example and watching the
turn loop refuse the means the ADR recommends."
  (let ((agent (actor:make-agent
                :name "data"
                :provider (make-instance 'scripted :script (%ask-for-company "globex")))))
    (%register-contacts-means agent "reader")
    (is (string= "answered"
                 (actor:run-turn agent "who works at globex?" :permit (%contacts-permit)))
        "with authority, the turn completes and the means ran"))
  ;; THE CONTROL, and it is the fail-closed rule rather than an accident: the same turn with no
  ;; permit must not reach the data.
  (let* ((agent (actor:make-agent
                 :name "data"
                 :provider (make-instance 'scripted :script (%ask-for-company "globex"))))
         (events '()))
    (%register-contacts-means agent "reader")
    (is (null (actor:agent-tool-specs agent))
        "the means is not even described to the model without authority")
    (evt:with-observer ((lambda (e) (push e events)))
      (handler-case (actor:run-turn agent "who works at globex?")
        (cnd:means-failure () nil)))
    (let ((result (find :tool-result (reverse events) :key #'evt:event-type)))
      (is-false (and result (search "globex.example" (or (evt:event-get result :content) "")))
                "and no address reaches the event stream, so a model naming a tool it was never
offered gets nothing"))))

(test the-asker-is-an-argument-of-the-means-not-a-remembered-discipline
  "ADR-0002's load-bearing claim, and the only one that stays true if every reader forgets the
ADR exists: one registration answers differently per caller, because the asker is supplied by the
HOST at registration and is absent from the schema the model fills in. A model cannot widen its
own authority by choosing arguments."
  (let* ((reader (actor:make-agent
                  :name "reader"
                  :provider (make-instance 'scripted :script (%ask-for-company "acme"))))
         (auditor (actor:make-agent
                   :name "auditor"
                   :provider (make-instance 'scripted :script (%ask-for-company "acme")))))
    (%register-contacts-means reader "reader")
    (%register-contacts-means auditor "auditor")
    (let ((for-reader (actor:act reader "contacts-at-company" (%args "company" "acme")
                                 :permit (%contacts-permit)))
          (for-auditor (actor:act auditor "contacts-at-company" (%args "company" "acme")
                                  :permit (%contacts-permit))))
      (is (string= "ada@acme.example" for-reader)
          "the ordinary caller sees the public row only")
      (is (string= "ada@acme.example,ceo@acme.example" for-auditor)
          "and the auditor sees both -- same means, same arguments, different answer")
      (is-false (search "ceo@" for-reader)
                "the restricted row is not reachable by any argument the model can supply"))
    ;; The schema is the model's whole vocabulary here, so this is the assertion that the asker
    ;; is NOT in it -- without it, the three above would also pass for a means that took the
    ;; asker as an argument and trusted it.
    (let* ((entry (first (actor:agent-means-for reader :permit (%contacts-permit))))
           (schema (llm:tool-spec-schema
                    (first (actor:agent-tool-specs reader :permit (%contacts-permit)))))
           (props (gethash "properties" schema)))
      (declare (ignore entry))
      (is (= 1 (hash-table-count props)) "exactly one argument is offered to the model")
      (is-true (gethash "company" props))
      (is-false (gethash "asker" props)
                "and it is not the asker -- which is what makes authorization a property of the
registration rather than of every call site remembering to pass something"))))

(test the-runnable-set-is-enumerable-rather-than-whatever-the-model-emits
  "The knowable-blast-radius claim, as a measurement. With generated SQL the set of queries that
can run is not a set anybody can review; here it is a list."
  (let ((agent (actor:make-agent :name "data")))
    (%register-contacts-means agent "reader")
    (actor:register-means agent "companies" "List companies." (lambda (args)
                                                                (declare (ignore args))
                                                                "acme,globex")
                          :capability "read:contacts")
    (let ((names (sort (mapcar #'actor:means-entry-name
                               (actor:agent-means-for agent :permit (constantly t)))
                       #'string<)))
      (is (equal '("companies" "contacts-at-company") names)
          "every query this agent can run, by name, read off the registry"))
    (is (null (actor:agent-means-for agent))
        "and with no authority presented, the set is EMPTY rather than defaulting open -- the
fail-closed property, which is what makes the enumeration meaningful")))

(test a-data-call-is-audited-with-its-name-and-arguments
  "The audit claim. A log of generated SQL says what ran; this says what was INTENDED."
  (let* ((agent (actor:make-agent
                 :name "data"
                 :provider (make-instance 'scripted :script (%ask-for-company "globex"))))
         (events '()))
    (%register-contacts-means agent "reader")
    (evt:with-observer ((lambda (e) (push e events)))
      (actor:run-turn agent "who works at globex?" :permit (%contacts-permit)))
    (let ((call (find :tool-call (reverse events) :key #'evt:event-type)))
      (is-true call "a data means call is on the event stream")
      (is (string= "contacts-at-company" (evt:event-get call :name)))
      (is (string= "globex" (gethash "company" (evt:event-get call :arguments)))
          "with the arguments, which is the difference between an audit trail and a log")
      (let ((result (find :tool-result (reverse events) :key #'evt:event-type)))
        (is (string= "gil@globex.example" (evt:event-get result :content))
            "and the result, so the pair says what was asked and what came back")))))

;;; --------------------------------------------------------------------------
;;; Observational memory (pre-publication issue 60)
;;; --------------------------------------------------------------------------

(in-suite praxeon)

(defun %contents (items)
  (mapcar #'ctx:ctx-item-content items))

(test what-was-remembered-is-recalled
  (let ((s (mem:make-in-memory-store)))
    (remember* s "member-1" "Works in Quebec, not France." :kind :fact)
    (is (equal '("Works in Quebec, not France.") (%contents (mem:recall s "member-1"))))))

(test memory-is-scoped-to-its-subject
  "The app runs several personas over the same members. Scoping by subject is what lets a
second persona know what the first was told; it is also what stops one member's
observations reaching another."
  (let ((s (mem:make-in-memory-store)))
    (remember* s "member-1" "Prefers short copy.")
    (remember* s "member-2" "Prefers long copy.")
    (is (equal '("Prefers short copy.") (%contents (mem:recall s "member-1"))))
    (is (equal '("Prefers long copy.") (%contents (mem:recall s "member-2"))))))

;;; --- the case the consuming app is blocked on -------------------------------

(test a-correction-replaces-rather-than-accrues
  "THE PRIMARY CASE. A member says once: do not call them that. A store that only accrues
holds both statements and recalls whichever the ranking favours, which is non-deterministic
and the worst version."
  (let* ((s (mem:make-in-memory-store))
         (first (remember* s "member-1" "Call members distributors." :kind :fact)))
    (supersede* s first "Do not call members distributors; call them partners."
                   :kind :correction)
    (let ((recalled (%contents (mem:recall s "member-1"))))
      (is (= 1 (length recalled)) "exactly one belief, not two")
      (is (search "partners" (first recalled)))
      (is-false (find-if (lambda (c) (string= c "Call members distributors.")) recalled)
                "the superseded statement must not be recalled"))))

(test the-superseded-observation-is-kept-and-linked-both-ways
  "Kept so a historical recall can answer, and linked both ways so `what does it believe
now' is a lookup rather than a search."
  (let* ((s (mem:make-in-memory-store))
         (first (remember* s "member-1" "Old rule."))
         (second (supersede* s first "New rule.")))
    (is (equal (mem:observation-id second) (mem:observation-superseded-by first)))
    (is (equal (mem:observation-id first) (mem:observation-supersedes second)))
    (is-false (mem:observation-current-p first))
    (is-true (mem:observation-current-p second))
    (is (= 2 (length (mem:observations-of s "member-1" :include-superseded t)))
        "both are still held")))

(test superseding-something-already-superseded-is-refused
  "Forking the chain would give `what does it believe now' two answers again, which is the
defect this exists to remove. The refusal names the replacement so the caller can supersede
that instead."
  (let* ((s (mem:make-in-memory-store))
         (first (remember* s "member-1" "One."))
         (second (supersede* s first "Two.")))
    (declare (ignore second))
    (signals cnd:praxeon-error (supersede* s first "Three."))))

;;; --- the historical view ----------------------------------------------------

(test as-of-answers-what-was-believed-then
  "The bitemporal half. `what did it believe on Tuesday' is a different question from `what
does it believe now', and both have to be answerable."
  (let* ((s (mem:make-in-memory-store))
         (first (remember* s "member-1" "Old rule."))
         (before (mem:observation-recorded-at first)))
    (sleep 1)                           ; the clock has one-second resolution
    (supersede* s first "New rule.")
    (is (equal '("New rule.") (%contents (mem:recall s "member-1")))
        "now: the correction")
    (is (equal '("Old rule.") (%contents (mem:recall s "member-1" :as-of before)))
        "then: what was believed at the time")))

(test as-of-before-anything-was-recorded-returns-nothing
  (let* ((s (mem:make-in-memory-store))
         (t0 (ctx:now)))
    (sleep 1)
    (remember* s "member-1" "Later.")
    (is (null (mem:recall s "member-1" :as-of t0)))))

;;; --- budget and kind ---------------------------------------------------------

(test recall-is-budgeted-like-any-other-context
  "Memory competes for prompt space on the same terms as everything else rather than on
terms of its own."
  (let ((s (mem:make-in-memory-store)))
    (remember* s "member-1" "aaaa" :tokens 10 :value 1)
    (remember* s "member-1" "bbbb" :tokens 10 :value 100)
    (let ((recalled (%contents (mem:recall s "member-1" :budget 10))))
      (is (= 1 (length recalled)) "only one fits")
      (is (string= "bbbb" (first recalled)) "and it is the valuable one"))))

(test recall-can-ask-for-one-kind
  "An explicit correction is more reliable than anything an LLM judged salient, so a caller
that wants only corrections must be able to say so."
  (let ((s (mem:make-in-memory-store)))
    (remember* s "member-1" "A guess." :kind :observation)
    (remember* s "member-1" "A correction." :kind :correction)
    (is (equal '("A correction.") (%contents (mem:recall s "member-1" :kind :correction))))
    (is (= 2 (length (mem:recall s "member-1"))) "and without the filter, both")))

;;; --- erasure, which is not supersession --------------------------------------

(test forgetting-a-subject-removes-everything-including-the-history
  "Erasure, not a tombstone. A store whose history cannot be made to forget is one a
consuming app cannot use for personal data."
  (let* ((s (mem:make-in-memory-store))
         (first (remember* s "member-1" "Old."))
         (t0 (mem:observation-recorded-at first)))
    (supersede* s first "New.")
    (remember* s "member-2" "Someone else's.")
    (is (= 2 (mem:forget-subject s "member-1")) "both the current and the superseded")
    (is (null (mem:recall s "member-1")))
    (is (null (mem:recall s "member-1" :as-of t0))
        "and the historical view is empty too -- that is what makes it erasure")
    (is (null (mem:observations-of s "member-1" :include-superseded t)))
    (is (equal '("Someone else's.") (%contents (mem:recall s "member-2")))
        "another subject is untouched")))

(test erasing-a-superseding-observation-makes-its-predecessor-current-again
  "Otherwise the survivor points at something that is gone and can never be current, so the
subject would have a belief the store refuses to recall and cannot explain."
  (let* ((s (mem:make-in-memory-store))
         (first (remember* s "member-1" "Original."))
         (second (supersede* s first "Replacement.")))
    (mem:forget s second)
    (is-true (mem:observation-current-p first))
    (is (equal '("Original.") (%contents (mem:recall s "member-1"))))))

;;; --------------------------------------------------------------------------
;;; Distilling a window into observations (pre-publication issue 452)
;;; --------------------------------------------------------------------------

(in-suite praxeon)

(defun %ob (content kind &key replaces because)
  "One observation object as the model would return it."
  (let ((ht (make-hash-table :test #'equal)))
    (setf (gethash "content" ht) content
          (gethash "kind" ht) kind)
    (when replaces (setf (gethash "replaces" ht) replaces))
    (when because (setf (gethash "because" ht) because))
    ht))

(defun %call-with (&rest observations)
  "A completion whose forced tool call carries OBSERVATIONS."
  (llm:make-completion
   :stop-reason :tool-use
   :tool-calls (list (llm:make-tool-call
                      :id "c1" :name "record_observations"
                      :arguments (%args "observations" (coerce observations 'vector))))))

(defun %provider-returning (&rest completions)
  (make-instance 'scripted :script (copy-list completions)))

(defparameter +window+ (list (llm:msg "user" "I moved to Lisbon last month."))
  "Stands in for a transcript window. Its content does not matter: the scripted provider
decides what comes back, and what is under test is what this pass does with that.")

(test a-window-that-distils-is-written-through-remember
  "The happy path, and it asserts the STORE rather than the return value. A pass that
returned the right list and wrote nothing would satisfy a weaker assertion."
  (let* ((store (mem:make-in-memory-store))
         (provider (%provider-returning
                    (%call-with (%ob "Lives in Lisbon." "fact")
                                (%ob "Prefers morning appointments." "preference")))))
    (multiple-value-bind (d condition) (dst:distil provider "member-1" +window+)
      (is (null condition) "a valid result must not report a failure; got ~S" condition)
      (apply-distillation* store d))
    (let ((held (mem:observations-of store "member-1")))
      (is (= 2 (length held)) "both observations reached the store; found ~D" (length held))
      (is (every (lambda (o) (plusp (mem:observation-tokens o))) held)
          "each observation carries a token count, so recall can budget it")
      (is (equal '(:fact :preference)
                 (sort (mapcar #'mem:observation-kind held) #'string< :key #'symbol-name))
          "the kinds survive extraction rather than defaulting"))))

(test a-window-that-never-validates-writes-nothing
  "The refusal, and the reason this pass exists in the shape it does. An output the model
could not fit to the schema still reads plausibly, and the doubt is gone once it is a row."
  (let* ((store (mem:make-in-memory-store))
         (before (remember* store "member-1" "Recorded by hand."))
         ;; Every attempt returns an observation with no content, which the validator
         ;; refuses. Three of them, because the repair loop gets three attempts.
         (provider (%provider-returning
                    (%call-with (%ob nil "fact"))
                    (%call-with (%ob nil "fact"))
                    (%call-with (%ob nil "fact")))))
    (multiple-value-bind (d condition) (dst:distil provider "member-1" +window+)
      (is (null d) "a window that cannot be distilled yields no distillation")
      (is (typep condition 'llm:structured-result-invalid)
          "and reports the real condition generate-structured signals, not an error value; got ~S"
          condition))
    (let ((held (mem:observations-of store "member-1")))
      (is (= 1 (length held))
          "the store is UNCHANGED -- still only the hand-written one; found ~D" (length held))
      (is (equal (mem:observation-id before) (mem:observation-id (first held)))
          "and it is the same observation, not a replacement that happens to count one"))))

(test a-provider-that-ignores-the-forced-tool-is-skipped-too
  "The second failure, which is a different condition. `structured-result-not-called' is the
provider accepting a forced tool choice and returning prose anyway. A handler for
`structured-result-invalid' alone would let this one reach a caller as an unhandled error
from a pass documented to skip."
  (let* ((store (mem:make-in-memory-store))
         (provider (%provider-returning
                    (llm:make-completion :text "Sure, here is what I noticed."
                                         :stop-reason :end))))
    (multiple-value-bind (d condition) (dst:distil provider "member-1" +window+)
      (is (null d) "prose instead of a tool call yields no distillation")
      (is (typep condition 'llm:structured-result-not-called)
          "and it is reported as the not-called condition, which is not the schema failure; got ~S"
          condition))
    (is (null (mem:observations-of store "member-1"))
        "and nothing was written")))

(test a-proposed-replacement-is-not-applied-unless-the-caller-accepts
  "The whole point of proposing rather than superseding. The default refuses, so a caller
that has not thought about supersession gets the safe behaviour and not the convenient one."
  (let* ((store (mem:make-in-memory-store))
         (old (remember* store "member-1" "Lives in Porto."))
         (provider (%provider-returning
                    (%call-with (%ob "Lives in Lisbon." "correction"
                                     :replaces (mem:observation-id old)
                                     :because "both are where this person lives")))))
    (apply-distillation* store (dst:distil provider "member-1" +window+))
    (is-true (mem:observation-current-p old)
             "the old observation is still current, because nobody accepted the replacement")
    (is (= 2 (length (mem:observations-of store "member-1")))
        "and the new content is recorded anyway -- only the identity claim was dropped")))

(test an-accepted-replacement-supersedes
  "The other direction. Without this, the test above would pass against a pass that could
not supersede at all."
  (let* ((store (mem:make-in-memory-store))
         (old (remember* store "member-1" "Lives in Porto."))
         (provider (%provider-returning
                    (%call-with (%ob "Lives in Lisbon." "correction"
                                     :replaces (mem:observation-id old)
                                     :because "both are where this person lives")))))
    (apply-distillation* store (dst:distil provider "member-1" +window+)
                            :accept (lambda (proposal target)
                                      (declare (ignore proposal target))
                                      t))
    (is-false (mem:observation-current-p old)
              "the accepted replacement supersedes the old observation")
    (is (equal '("Lives in Lisbon.")
               (mapcar #'mem:observation-content
                       (remove-if-not #'mem:observation-current-p
                                      (mem:observations-of store "member-1"))))
        "and the current belief is the new one alone")))

(test the-proposal-handed-to-accept-carries-its-basis
  "A proposal is reviewable only if the reviewer can see what the pairing rests on. A bare
pair of ids is rubber-stampable, which is applying it automatically with extra steps."
  (let* ((store (mem:make-in-memory-store))
         (old (remember* store "member-1" "Lives in Porto."))
         (seen '())
         (provider (%provider-returning
                    (%call-with (%ob "Lives in Lisbon." "correction"
                                     :replaces (mem:observation-id old)
                                     :because "both are where this person lives")))))
    (apply-distillation* store (dst:distil provider "member-1" +window+)
                            :accept (lambda (proposal target)
                                      (push (list (dst:proposal-because proposal)
                                                  (mem:observation-content target))
                                            seen)
                                      nil))
    (is (equal '(("both are where this person lives" "Lives in Porto.")) seen)
        "accept sees the model's stated reason and the observation it would replace; saw ~S"
        seen)))

(test a-replacement-with-no-reason-is-refused-before-it-is-proposed
  "The validator refuses it so the model is told and can repair it, rather than the pass
dropping the claim quietly. A dropped claim is one the model actually made and nobody saw."
  (let* ((old-id "obs-1")
         (provider (%provider-returning
                    (%call-with (%ob "Lives in Lisbon." "correction" :replaces old-id))
                    (%call-with (%ob "Lives in Lisbon." "correction" :replaces old-id))
                    (%call-with (%ob "Lives in Lisbon." "correction" :replaces old-id)))))
    (multiple-value-bind (d condition) (dst:distil provider "member-1" +window+)
      (is (null d) "a replacement with no `because' is not distilled")
      (is (search "because" (format nil "~A" condition))
          "and the problem reported names the missing field, so a repair can act on it: ~A"
          condition))))

(test a-replacement-naming-an-unknown-observation-is-recorded-as-an-ordinary-one
  "There is nothing to review and nothing to replace, so the content claim stands alone."
  (let* ((store (mem:make-in-memory-store))
         (asked 0)
         (provider (%provider-returning
                    (%call-with (%ob "Lives in Lisbon." "correction"
                                     :replaces "no-such-id"
                                     :because "I believe these are the same")))))
    (apply-distillation* store (dst:distil provider "member-1" +window+)
                            :accept (lambda (p target) (declare (ignore p target))
                                      (incf asked) t))
    (is (zerop asked)
        "accept is not consulted about an id the store cannot show anyone; asked ~D times" asked)
    (is (equal '("Lives in Lisbon.")
               (mapcar #'mem:observation-content (mem:observations-of store "member-1")))
        "and the observation is recorded as an ordinary one")))

(test the-pass-is-not-a-gate-in-front-of-direct-writes
  "Distillation is ONE caller of remember. The reliable observations are the ones someone
stated outright, and putting a salience judgement ahead of those is worse than recording
them as corrections."
  (let* ((store (mem:make-in-memory-store))
         (provider (%provider-returning
                    (%call-with (%ob "Lives in Lisbon." "fact")))))
    (apply-distillation* store (dst:distil provider "member-1" +window+))
    (remember* store "member-1" "Told us directly." :kind :correction)
    (let ((held (mem:observations-of store "member-1")))
      (is (= 2 (length held))
          "a direct remember still works with the pass present; found ~D" (length held))
      (is (find :correction held :key #'mem:observation-kind)
          "and the hand-written correction is there as itself"))))

(test what-is-already-believed-is-offered-to-the-model
  "A supersession is a claim about identity, and the model cannot make it against
observations it was never shown. Asserts the prompt the provider actually received."
  (let* ((store (mem:make-in-memory-store))
         (old (remember* store "member-1" "Lives in Porto."))
         (provider (make-instance 'transcribing
                                  :script (list (%call-with (%ob "Lives in Lisbon." "fact"))))))
    (dst:distil provider "member-1" +window+
                :known (mem:observations-of store "member-1"))
    ;; The MESSAGES, not their count. `recording' would answer how many were sent, which is
    ;; a different question from whether this text was in them.
    (let ((sent (format nil "~S" (transcribing-messages provider))))
      (is (search "Lives in Porto." sent)
          "the known observation's content reaches the provider")
      (is (search (mem:observation-id old) sent)
          "and its id, which is what a replacement has to name"))))

(test without-known-observations-nothing-claims-to-replace-anything
  "The control for the test above: the same window with nothing offered produces a plain
observation, so the presence of a replacement is attributable to what was shown."
  (let* ((provider (%provider-returning
                    (%call-with (%ob "Lives in Lisbon." "fact")))))
    (let ((d (dst:distil provider "member-1" +window+)))
      (is (null (dst:distillation-replacements d))
          "no replacement is proposed when nothing was offered to replace"))))

;;; --------------------------------------------------------------------------
;;; A schema may not declare what nothing checks (pre-publication issue 454)
;;; --------------------------------------------------------------------------

(in-suite praxeon)

(defun %schema-with (&rest property-pairs)
  (let ((props (make-hash-table :test #'equal)))
    (loop for (name spec) on property-pairs by #'cddr
          do (setf (gethash name props) spec))
    (%args "type" "object" "properties" props "required" (vector "company"))))

(test a-flat-schema-declares-nothing-it-cannot-enforce
  "The control, and the reason this check can ship. Every tool-spec already in the tree uses
required properties and top-level types, which is exactly what the validator reads. A rule
that refused those would be refusing the codebase."
  (is (null (llm:unenforced-declarations
             (%schema-with "company" (%args "type" "string" "description" "the name"))))
      "a schema of required properties and top-level types has no unenforced declaration"))

(test a-declaration-the-validator-never-reads-is-named-with-its-path
  "ENUM and ITEMS both reach the provider and neither is read on the way back."
  (let ((found (llm:unenforced-declarations
                (%schema-with "company" (%args "type" "string")
                              "kind" (%args "type" "string" "enum" (vector "a" "b"))
                              "rows" (%args "type" "array" "items" (%args "type" "object"))))))
    (is (equal '("kind.enum" "rows.items") found)
        "both are reported, by path so the author can find them; got ~S" found)))

(test a-spec-declaring-what-nothing-checks-is-refused
  "Refusing rather than documenting. The declaration is not inert -- it is sent to the
provider, so a model shown an enum usually honours it, and a caller watching that work
concludes the constraint is enforced. It is the model's compliance doing the work."
  (let ((spec (llm:make-tool-spec
               :name "record"
               :schema (%schema-with "kind" (%args "type" "string" "enum" (vector "a" "b"))))))
    (signals llm:unenforceable-schema (llm:check-schema-enforceable spec))))

(test the-refusal-names-the-declarations-and-what-to-do-instead
  "A refusal that does not say what to do instead gets worked around rather than fixed."
  (let* ((spec (llm:make-tool-spec
                :name "record"
                :schema (%schema-with "kind" (%args "type" "string" "enum" (vector "a" "b")))))
         (text (handler-case (progn (llm:check-schema-enforceable spec) "")
                 (llm:unenforceable-schema (c) (format nil "~A" c)))))
    (is (search "kind.enum" text) "the report names the declaration; got ~S" text)
    (is (search "TOOL-SPEC-VALIDATORS" text)
        "and names the field that is the way out, rather than only refusing")))

(test a-validator-takes-responsibility-for-the-gap
  "The other direction, and the whole point of the rule. Declaring an enum is useful -- the
model reads it -- so the rule is not `do not declare it' but `declare it and check it'."
  (let ((spec (llm:make-tool-spec
               :name "record"
               :schema (%schema-with "kind" (%args "type" "string" "enum" (vector "a" "b")))
               :validators (list (lambda (args) (declare (ignore args)) nil)))))
    (finishes (llm:check-schema-enforceable spec))))

(test generate-structured-refuses-before-it-spends-a-request
  "The check runs before the first call, so a bad spec costs no tokens and the error points
at the spec rather than at the model's answer. Asserts the provider was never asked."
  (let* ((provider (make-instance 'recording :script '()))
         (spec (llm:make-tool-spec
                :name "record"
                :schema (%schema-with "kind" (%args "type" "string" "enum" (vector "a" "b"))))))
    (signals llm:unenforceable-schema
      (llm:generate-structured provider (list (llm:msg "user" "go")) spec))
    (is (null (recording-requests provider))
        "the provider was never asked; it recorded ~D request(s)"
        (length (recording-requests provider)))))

(test a-nested-object-property-is-unenforced-too
  "Not only arrays. A property of type object with its own properties declares structure one
level down, and the validator reads only the top."
  (let ((found (llm:unenforced-declarations
                (%schema-with "company" (%args "type" "string")
                              "address" (%args "type" "object"
                                               "properties" (%args "city" (%args "type" "string")))))))
    (is (equal '("address.properties") found)
        "the nested properties block is reported; got ~S" found)))

;;; --- the embedding seam (#138, #150) ---------------------------------------

(def-suite embedding
  :description "Turning text into a vector, as a provider call." :in praxeon)
(in-suite embedding)

;;; Writing the environment without a read-time dependency on sb-posix. Same reasoning as
;;; hermes/tests/hermes.lisp: a literal `sb-posix:setenv' is resolved by the READER, so on a
;;; build lacking the symbol this file dies with a package error and takes the suite with
;;; it. Looked up at runtime, the blast radius is the tests that need it.
(defun %emb-env-fn (name)
  (let* ((package (find-package "SB-POSIX"))
         (symbol (and package (find-symbol name package))))
    (and symbol (fboundp symbol) symbol)))

(defun %emb-env-writable-p () (and (%emb-env-fn "SETENV") (%emb-env-fn "UNSETENV") t))

(defmacro with-emb-env (bindings &body body)
  "Set env vars for BODY and restore after. NIL unsets. Skips where the env is not writable."
  (let ((saves (gensym)))
    `(if (not (%emb-env-writable-p))
         (skip "this build cannot write the C environment uiop:getenv reads")
         (let ((,saves (mapcar (lambda (b) (cons (first b) (uiop:getenv (first b))))
                               ',bindings)))
           (unwind-protect
                (progn ,@(mapcar (lambda (b)
                                   `(if ,(second b)
                                        (funcall (%emb-env-fn "SETENV") ,(first b) ,(second b) 1)
                                        (funcall (%emb-env-fn "UNSETENV") ,(first b))))
                                 bindings)
                       ,@body)
             (dolist (s ,saves)
               (if (cdr s)
                   (funcall (%emb-env-fn "SETENV") (car s) (cdr s) 1)
                   (funcall (%emb-env-fn "UNSETENV") (car s)))))))))

;;; A provider that answers without a network. The transport is the double; the protocol,
;;; the width guard and the ordering below are the real code.
(defclass fake-embeddings (llm:embedding-provider)
  ((width :initarg :width :initform 4 :reader fake-width)
   (emit  :initarg :emit  :initform 4 :reader fake-emit)))
(defmethod llm:embedding-dimensions ((p fake-embeddings)) (fake-width p))
(defmethod llm:embedding-model-of ((p fake-embeddings)) "fake")
(defmethod llm:embed ((p fake-embeddings) text)
  (declare (ignore text))
  (make-array (fake-emit p) :element-type 'double-float :initial-element 1.0d0))

(test an-anthropic-is-not-an-embedding-provider
  "THE ABSENCE IS STRUCTURAL, AND THAT IS THE WHOLE DESIGN (#138).

Anthropic has no embeddings endpoint. Had `embed' been a generic on PROVIDER with a
capability predicate beside it, an `anthropic' would carry a method whose only job is to
signal -- total in the signature, partial in fact, which is ADR-0001's complaint one
framework over. Instead it is not of the type, so a call site that needs one cannot be
handed it, and there is no method to reach.

Asserting BOTH: not the type, and no applicable method. The first alone would pass against
a design that kept the method and merely rearranged the classes."
  (let ((a (make-instance 'llm:anthropic :model "claude-x" :api-key "k")))
    (is-false (typep a 'llm:embedding-provider))
    (is-false (compute-applicable-methods #'llm:embed (list a "text"))
              "there must be no EMBED method for a provider that cannot embed")
    (is-true (typep (make-instance 'fake-embeddings) 'llm:embedding-provider))))

(test a-width-that-is-not-the-declared-width-is-refused
  "The provider's dimension is a CLAIM; the length that came back is the MEASUREMENT.

Both directions: the right width passes through untouched, the wrong one signals. Without
the control, a guard that refused everything would pass the refusal test."
  (let ((ok (make-instance 'fake-embeddings :width 4 :emit 4))
        (bad (make-instance 'fake-embeddings :width 1536 :emit 768)))
    (is (= 4 (length (llm:embed ok "hello"))))
    (signals cnd:embedding-dimension-mismatch (llm:embed bad "hello"))
    (handler-case (progn (llm:embed bad "hello") (fail "expected a mismatch"))
      (cnd:embedding-dimension-mismatch (c)
        (is (= 1536 (cnd:embedding-dimension-mismatch-expected c)))
        (is (= 768 (cnd:embedding-dimension-mismatch-actual c)))))))

(test a-declared-dimension-is-checked-against-the-provider-at-startup
  "#150: a schema hard-coding 1536 has hard-coded OpenAI's text-embedding-3-small.

This is the OUTER guard. mnemosyne refuses the wrong width again at cast time and keeps
doing so, but that error names a column; this one names the misconfiguration while the
words for it are still available."
  (let ((p (make-instance 'fake-embeddings :width 1536)))
    (is (= 1536 (llm:check-embedding-dimensions p 1536)))
    (signals cnd:embedding-dimension-mismatch (llm:check-embedding-dimensions p 768))))

(test a-batch-is-paired-back-by-index-not-by-arrival
  "THE `index' FIELD EXISTS BECAUSE THE ARRAY ORDER IS NOT PROMISED.

A batch that came back permuted would attach every embedding to the wrong text -- silently,
and into a store that is then queried by similarity, which is the one place a wrong answer
looks like a plausible one. The fixture is a reply whose rows are OUT of order, which is the
only arrangement that can tell a sort from a pass-through."
  (let* ((reply (jzon:parse "{\"data\":[
                              {\"index\":2,\"embedding\":[3,3]},
                              {\"index\":0,\"embedding\":[1,1]},
                              {\"index\":1,\"embedding\":[2,2]}]}"))
         (vectors (llm::%embedding-vectors reply)))
    (is (= 3 (length vectors)))
    (is (= 1.0d0 (aref (first vectors) 0)) "index 0 must come first")
    (is (= 2.0d0 (aref (second vectors) 0)) "then index 1")
    (is (= 3.0d0 (aref (third vectors) 0)) "then index 2")
    (is (every (lambda (v) (typep v '(simple-array double-float (*)))) vectors)
        "and every one is a double-float vector, not a list of integers")))

(test an-embedding-reply-with-no-data-is-refused-rather-than-returning-nothing
  "An empty reply and a reply that failed are the same at the call site otherwise."
  (signals cnd:deliberation-failure (llm::%embedding-vectors (jzon:parse "{\"data\":[]}")))
  (signals cnd:deliberation-failure (llm::%embedding-vectors (jzon:parse "{}"))))

(test the-embedding-provider-inherits-the-endpoint-it-does-not-restate
  "THE MEASUREMENT BEHIND THE DESIGN (#138).

The objection to a separate embedding hierarchy was that an app would configure the same
endpoint twice. It does not: `%env-for' resolves PRAXEON_<ROLE>_* > PRAXEON_<IMPL>_* >
PRAXEON_LLM_*, so BASE_URL and API_KEY fall through from whatever the completion side
already has. The marginal configuration is the MODEL -- and that is not duplication,
because an embedding model and a chat model are necessarily different values.

Asserted rather than argued, because the whole ruling rested on it."
  (with-emb-env (("PRAXEON_LLM_BASE_URL" "https://shared.example/v1")
                 ("PRAXEON_LLM_API_KEY" "shared-key")
                 ("PRAXEON_OPENAI_BASE_URL" nil)
                 ("PRAXEON_OPENAI_API_KEY" nil)
                 ("PRAXEON_OPENAI_EMBED_MODEL" "text-embedding-3-large")
                 ("PRAXEON_OPENAI_EMBED_DIMENSIONS" "3072")
                 ("PRAXEON_EMBED_IMPL" "openai"))
    (let ((p (llm:make-embedding-provider-from-env)))
      (is (string= "https://shared.example/v1" (llm:oai-embed-base-url p))
          "the endpoint is inherited, not restated")
      (is (string= "shared-key" (llm:oai-embed-api-key p))
          "and so is the key")
      (is (string= "text-embedding-3-large" (llm:embedding-model-of p))
          "the model is this provider's own -- the one thing that must differ")
      (is (= 3072 (llm:embedding-dimensions p))
          "and the width is a deployment fact, read from the environment"))))

(test an-unregistered-embedding-impl-is-refused-by-name
  "A missing impl and a misspelt one are the same mistake, and neither may fall back to a
default that embeds with the wrong model."
  (with-emb-env (("PRAXEON_EMBED_IMPL" "no-such-embedder"))
    (signals cnd:deliberation-failure (llm:make-embedding-provider-from-env))))

(test the-usage-event-does-not-report-a-count-the-provider-never-gave
  "A PARTIAL report is the case the gate does not cover (pre-publication issue 444).

The emit gate is `(when (or in out))', which is the pre-publication issue 401 rule at the level it was written
for: no counts at all, no event. But a provider that reports OUTPUT and not INPUT passes the
gate, and `:input (or in 0)' then claimed a measurement nobody made -- on the event whose own
comment fourteen lines up forbids exactly that.

Why 0 is worse than absent here rather than merely inaccurate: a renderer summing
input+output gets a number that is SHORT BY AN UNKNOWN AMOUNT, and short-by-unknown is
indistinguishable from a real total. NIL cannot be summed by accident.

Both directions. A partial report carries NIL for the half that was not reported; a full one
still carries both numbers, or the fix would have been to stop reporting counts at all."
  (let* ((partial (make-instance 'capturing
                                 :script (list (llm:make-completion
                                                :text "ok" :stop-reason :end
                                                :output-tokens 12))))
         (events '()))
    (evt:with-observer ((lambda (e) (push e events)))
      (actor:run-turn (actor:make-agent :provider partial) "hello"))
    (let ((usage (find :usage events :key #'evt:event-type)))
      (is-true usage "output was reported, so the event must still be emitted")
      (is (null (evt:event-get usage :input))
          "input was NOT reported, so it must be NIL rather than 0 -- got ~S"
          (evt:event-get usage :input))
      (is (= 12 (evt:event-get usage :output)) "and the half that WAS reported survives")))
  (let* ((full (make-instance 'capturing
                              :script (list (llm:make-completion
                                             :text "ok" :stop-reason :end
                                             :input-tokens 700 :output-tokens 12))))
         (events '()))
    (evt:with-observer ((lambda (e) (push e events)))
      (actor:run-turn (actor:make-agent :provider full) "hello"))
    (let ((usage (find :usage events :key #'evt:event-type)))
      (is (= 700 (evt:event-get usage :input)) "the control: a full report is unchanged")
      (is (= 12 (evt:event-get usage :output))))))
;;; --- provenance is required on every write (#150) ---------------------------

(test a-write-with-no-provenance-is-refused
  "MANDATORY, NOT DEFAULTED, and the reason is the difference between the two.

Observational memory is personal data held indefinitely. A remembered claim that cannot be
traced to a conversation and a turn cannot be CORRECTED -- the member disputing it has
nothing to point at, the persona repeating it has nothing to check. That is the
rectification half of the argument that already makes erasure first-class here.

A default would be worse than the absence it replaced, because a fabricated source READS AS
A CITATION: the failure is an agent saying `you told me on turn 3' about a turn nobody had.

Both writes, because a correction that cannot be traced is worse than an observation that
cannot be -- it is the record of someone having been put right, with no way to see when."
  (let ((s (mem:make-in-memory-store)))
    (signals cnd:missing-provenance (mem:remember s "member-1" "no source"))
    (let ((held (remember* s "member-1" "has a source")))
      (signals cnd:missing-provenance (mem:supersede s held "still no source"))
      (is (string= "has a source" (mem:observation-content held))
          "the control: a write WITH provenance is unaffected"))))

(test a-correction-carries-its-own-source-not-the-one-it-corrects
  "A member puts an agent right in a LATER turn. Inheriting the superseded observation's
provenance would attribute the correction to the conversation it corrects -- and then `when
did they tell us this' answers with the thing that was wrong."
  (let* ((s (mem:make-in-memory-store))
         (original (mem:remember s "member-1" "prefers mornings"
                                 :provenance (mem:make-provenance "conv-a" 1)))
         (correction (mem:supersede s original "prefers afternoons"
                                    :provenance (mem:make-provenance "conv-b" 9))))
    (is (string= "conv-a" (mem:provenance-conversation (mem:observation-provenance original))))
    (is (= 1 (mem:provenance-turn (mem:observation-provenance original))))
    (is (string= "conv-b" (mem:provenance-conversation (mem:observation-provenance correction)))
        "the correction's source is its own conversation")
    (is (= 9 (mem:provenance-turn (mem:observation-provenance correction))))))

(test a-source-time-is-never-invented
  "AT is when the SOURCE TURN happened, which is not when the store learned it: a
distillation pass reads a window from an hour ago, so RECORDED-AT is the pass and AT is the
conversation. Conflating them makes `what did it believe on Tuesday' answer with the pass's
schedule instead of the member's.

NIL when it was not recorded -- an absent measurement, not a zero one. Same distinction as
pre-publication issue 444's unreported token count and pre-publication issue 489's absent column, which is three instances of it now."
  (let ((without (mem:make-provenance "conv-a" 1))
        (with (mem:make-provenance "conv-a" 1 :at 12345)))
    (is (null (mem:provenance-at without))
        "an unrecorded source time is NIL, not 0 -- 0 is a time")
    (is (= 12345 (mem:provenance-at with)))))

(test a-distillation-writes-the-window-s-source-not-the-pass-s
  "APPLY-DISTILLATION takes its provenance rather than manufacturing one, because the caller
is the only party that knows which window this was. A pass that invented a source would
produce observations citing a turn nobody had."
  (let* ((store (mem:make-in-memory-store))
         (provider (%provider-returning
                    (%call-with (%ob "Lives in Lisbon." "fact"))))
         (written (dst:apply-distillation
                   store (dst:distil provider "member-1" +window+)
                   :provenance (mem:make-provenance "the-window" 7))))
    (is (plusp (length written)) "the pass must have written something")
    (dolist (o written)
      (is (string= "the-window"
                   (mem:provenance-conversation (mem:observation-provenance o)))
          "every observation the pass wrote cites the window it read")
      (is (= 7 (mem:provenance-turn (mem:observation-provenance o)))))))

;;; --- a recalled memory can be cited (#150) ----------------------------------

(test a-recalled-item-carries-the-observation-it-came-from
  "#150's read path: a persona must be able to say where a remembered thing came from, or
it cannot be corrected.

THE SOURCE IS THE OBSERVATION, not just its provenance, because correcting means
superseding and that needs the id. Provenance alone answers `where did this come from' and
leaves `and how do I fix it' unanswerable."
  (let* ((s (mem:make-in-memory-store))
         (written (mem:remember s "member-1" "prefers mornings"
                                :provenance (mem:make-provenance "conv-a" 3 :at 555)))
         (items (mem:recall s "member-1" :budget 1000)))
    (is (= 1 (length items)))
    (let ((source (ctx:ctx-item-source (first items))))
      (is-true source "a recalled item must carry its source")
      (is (string= (mem:observation-id written) (mem:observation-id source))
          "and it is the observation itself, so the item can be superseded")
      (let ((p (mem:observation-provenance source)))
        (is (string= "conv-a" (mem:provenance-conversation p)))
        (is (= 3 (mem:provenance-turn p)))
        (is (= 555 (mem:provenance-at p)))))))

(test a-citation-survives-the-budgeted-assembly
  "THE CITATION HAS TO REACH THE PROMPT, which is the whole reason the slot is on CTX-ITEM
rather than in a wrapper. `ctx:assemble' ranks and selects; if it rebuilt items the source
would be lost at exactly the point it is needed, and nothing before render time would
notice.

Asserted through ASSEMBLE rather than on a freshly built item, because a test that only
checks the constructor would pass against an assembly that drops the slot."
  (let* ((s (mem:make-in-memory-store)))
    (dotimes (i 3)
      (mem:remember s "member-2" (format nil "fact ~D" i)
                    :provenance (mem:make-provenance "conv-b" (1+ i))))
    (let ((items (mem:recall s "member-2" :budget 1000)))
      (is (= 3 (length items)))
      (is (every (lambda (i) (ctx:ctx-item-source i)) items)
          "every assembled item must still carry its source")
      (is (equal '(1 2 3)
                 (sort (mapcar (lambda (i)
                                 (mem:provenance-turn
                                  (mem:observation-provenance (ctx:ctx-item-source i))))
                               items)
                       #'<))
          "and the citations are the three distinct turns, not one repeated"))))

(test a-nil-source-means-not-from-memory-and-cannot-mean-anything-else
  "NIL IS UNAMBIGUOUS, and that is a property of the write path rather than of this slot.

Provenance is mandatory on every write (#150) and `observation->ctx-item' is the only route
from an observation to an item, so `from memory, source unknown' is unconstructible. A NIL
source therefore means one thing. Without that guarantee this slot would be the
absent-versus-NULL defect rebuilt in a struct, which this tree spent a day removing from
three other places.

Both directions: an item built outside memory has NIL, and no memory path produces one."
  (is (null (ctx:ctx-item-source (ctx:make-ctx-item :content "hand-built" :tokens 1)))
      "a non-memory item has no source")
  (let ((s (mem:make-in-memory-store)))
    (mem:remember s "member-3" "a" :provenance (mem:make-provenance "c" 1))
    (mem:remember s "member-3" "b" :provenance (mem:make-provenance "c" 2))
    (is (notany (lambda (i) (null (ctx:ctx-item-source i)))
                (mem:recall s "member-3" :budget 1000))
        "and no recalled item ever lacks one")))

;;; --------------------------------------------------------------------------
;;; #161: the :usage event carries what the ledger can accept.
;;;
;;; `ceiling:meter' has taken four counts since pre-publication PR 419. This event is the ONLY
;;; programmatic route by which usage escapes a turn -- `run-turn' returns text, and the
;;; completion is appended to history as messages and then dropped -- so until it carried
;;; four, a caller wiring the spend guard had no source at all for two of them.
;;;
;;; Driven through the REAL path, as #161 asks: a provider returning a real completion with
;;; counts on it, `run-turn' doing the turn, and an observer reading the event. The ceiling's
;;; own tests use a lambda returning a constant instead, which is correct for what they test
;;; and is why nothing discovered the seam.
;;; --------------------------------------------------------------------------

(defclass counted (llm:provider)
  ((completion :initarg :completion :reader counted-completion))
  (:documentation "A provider that answers once with a completion the test built, counts and all."))

(defmethod llm:complete ((p counted) messages
                         &key system tools max-tokens temperature tool-choice)
  (declare (ignore messages system tools max-tokens temperature tool-choice))
  (counted-completion p))

(defun %usage-event-for (completion)
  "Run a real turn whose provider answers with COMPLETION; return the :usage event, or NIL."
  (let ((seen nil))
    (evt:with-observer ((lambda (e) (when (eq (getf e :type) :usage) (setf seen e))))
      (actor:run-turn (actor:make-agent :name "u" :provider
                                        (make-instance 'counted :completion completion))
                      "go"))
    seen))

(test the-usage-event-carries-all-four-counts
  "What the provider reported arrives on the event -- including the two the ledger gained in
pre-publication PR 419 and this seam did not carry."
  (let ((e (%usage-event-for
            (llm:make-completion :text "ok" :stop-reason :end
                                 :input-tokens 100 :output-tokens 20
                                 :cache-read-tokens 900 :cache-write-tokens 7))))
    (is-true e "no :usage event was emitted at all")
    (is (= 100 (evt:event-get e :input)))
    (is (= 20 (evt:event-get e :output)))
    (is (= 900 (evt:event-get e :cache-read))
        "the cache-read count did not reach the event: ~S" e)
    (is (= 7 (evt:event-get e :cache-write))
        "the cache-write count did not reach the event: ~S" e)))

(test a-provider-that-reports-no-cache-counts-sends-nil-not-zero
  "THE CONTROL, and it is the pre-publication issue 401 distinction rather than a formality.
NIL means the provider did not report; 0 means it reported a miss. Collapsing them would make
a cache breakpoint one message too late indistinguishable from a provider with no cache at
all -- and a reader summing the event would see a cached turn as a free one either way, which
is the failure `completion's own docstring exists to prevent."
  (let ((e (%usage-event-for
            (llm:make-completion :text "ok" :stop-reason :end
                                 :input-tokens 100 :output-tokens 20))))
    (is-true e)
    (is (= 100 (evt:event-get e :input)))
    (is (null (evt:event-get e :cache-read))
        "an unreported cache-read arrived as ~S rather than NIL" (evt:event-get e :cache-read))
    (is (null (evt:event-get e :cache-write))
        "an unreported cache-write arrived as ~S rather than NIL" (evt:event-get e :cache-write))))

(test a-provider-reporting-only-cache-counts-still-emits
  "The gate widened with the payload. Before, `(when (or in out))' meant a provider that
reported cache counts and nothing else emitted NOTHING -- the same silence the clause exists to
avoid, reached from the side nobody had needed yet."
  (let ((e (%usage-event-for
            (llm:make-completion :text "ok" :stop-reason :end
                                 :cache-read-tokens 512))))
    (is-true e "a completion carrying only cache counts emitted no :usage event")
    (is (= 512 (evt:event-get e :cache-read)))
    ;; Widening the gate is what makes this case reachable at all: before, an event fired only
    ;; when input or output was reported. Input and output were not reported here, so they must
    ;; arrive as NIL. `:input 0' would be a measurement nobody made, which the emit site stopped
    ;; producing for partial reports before this change (pre-publication issue 444).
    (is (null (evt:event-get e :input))
        "an unreported input arrived as ~S rather than NIL" (evt:event-get e :input))
    (is (null (evt:event-get e :output))
        "an unreported output arrived as ~S rather than NIL" (evt:event-get e :output))))

(test a-provider-reporting-nothing-still-emits-nothing
  "The other end of the gate, unchanged by #161 and asserted because widening a condition is
exactly where an existing refusal gets lost. A provider with no usage at all must still emit no
:usage event -- otherwise a renderer summing input+output shows a running total of zero as
though it were the cost."
  (is (null (%usage-event-for (llm:make-completion :text "ok" :stop-reason :end)))
      "a completion with no counts at all emitted a :usage event"))

(test run-turn-through-checks-its-chain-before-it-enters-coalton
  ;; #110: CHAIN comes from the caller, and Coalton checks that it is a list but not what is in
  ;; it. The check runs before the model is called, so no agent is needed.
  (let ((e (handler-case
               (progn (praxeon/actor:run-turn-through
                       nil "hi" :chain (list (praxeon/turn:guard-stage "g" (lambda (tn) tn))
                                             :not-a-stage))
                      nil)
             (aion/boundary:boundary-type-error (e) e))))
    (is (typep e 'aion/boundary:boundary-type-error) "run-turn-through did not signal")
    (is (eql 1 (and e (aion/boundary:boundary-type-error-index e))))
    (is (eq :not-a-stage (and e (type-error-datum e))))))

;;; --- a parallel group logs with the caller's context (#160) ------------------

(in-suite praxeon)

(defclass %failing-provider (llm:provider) ()
  (:documentation "A provider whose every request fails, so each child logs the failure."))

(defmethod llm:complete ((p %failing-provider) messages
                         &key system tools max-tokens temperature tool-choice)
  (declare (ignore messages system tools max-tokens temperature tool-choice))
  (error "the provider is unavailable"))

(test a-parallel-group-logs-with-the-caller-s-context
  ;; Each child of WF:PARALLEL runs on its own thread (`%run-group'), and a LET binding does
  ;; not cross a thread. Both children fail at the provider, so each logs "llm request
  ;; failed" from its own thread; both lines must carry the context the caller bound.
  (let ((out (make-string-output-stream))
        (flow (wf:make-workflow
               :fan "fan out"
               (wf:parallel
                (wf:step :a (actor:make-agent :name "a" :provider (make-instance '%failing-provider)) "x")
                (wf:step :b (actor:make-agent :name "b" :provider (make-instance '%failing-provider)) "y")))))
    (unwind-protect
         (progn
           (aion/log:setup :env :dev :level :warn :stream out)
           (aion/log:with-context (:request-id "req-160" :workflow "fan-160")
             (handler-case (wf:run-workflow flow)
               (cnd:parallel-child-failure () nil)))
           (let ((lines (remove-if-not (lambda (line) (search "llm request failed" line))
                                       (uiop:split-string (get-output-stream-string out)
                                                          :separator '(#\Newline)))))
             (is (= 2 (length lines))
                 "each of the two children should log its provider failure, got ~S" lines)
             (is (every (lambda (l) (search "request-id=req-160" l)) lines)
                 "every child thread's line must carry the request id: ~S" lines)
             (is (every (lambda (l) (search "workflow=fan-160" l)) lines)
                 "and the rest of the caller's context: ~S" lines)))
      (aion/log:setup :env :dev :level :warn :stream *standard-output*))))
