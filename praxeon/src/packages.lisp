;;;; packages.lisp --- package definitions for Praxeon
;;;;
;;;; Layering:
;;;;   praxeon/praxeology  -- the *typed* core ontology, written in Coalton.
;;;;                         Describes what agents ARE (ends, means, actions).
;;;;   praxeon/conditions  -- the recoverable-failure protocol (CL condition system).
;;;;   praxeon/context     -- budgeted, bitemporal context assembly (seed of Kairos).
;;;;   praxeon/llm         -- LLM provider protocol + an Anthropic implementation.
;;;;   praxeon/prompt      -- what is SENT: history trimmed to a budget, facts placed (#402).
;;;;   praxeon/actor       -- the dynamic shell: deliberate -> select -> act loop.
;;;;   praxeon             -- umbrella package re-exporting the common surface.

(cl:in-package #:cl-user)

;;; ----------------------------------------------------------------------------
;;; The typed core. Coalton packages use Coalton's own prelude, not CL's.
;;; ----------------------------------------------------------------------------
(defpackage #:praxeon/praxeology
  (:use #:coalton #:coalton-prelude)
  (:export
   ;; types
   #:End #:Means #:Action #:Plan #:Actor
   ;; accessors / helpers
   #:end-description
   #:means-name #:means-description
   #:action-means #:action-end #:action-argument
   #:plan-actions #:plan-length
   #:actor-name #:actor-means
   ;; preference
   #:Valued #:value))

;;; ----------------------------------------------------------------------------
;;; The dynamic shell. Ordinary CL packages.
;;; ----------------------------------------------------------------------------
(defpackage #:praxeon/config
  (:use #:cl)
  (:export #:load-dotenv))

;;; The client<->framework progress contract: the actor loop emits neutral
;;; EVENTS (plain plists -- data, not behavior) that any UX layer renders. The
;;; same events drive a CLI status line or a web SSE stream, unchanged.
(defpackage #:praxeon/event
  (:use #:cl)
  (:export #:*observer* #:emit #:with-observer
           #:event-type #:event-get #:event-plist))

(defpackage #:praxeon/conditions
  (:use #:cl)
  (:export
   #:praxeon-error
   #:means-failure #:means-failure-means #:means-failure-cause
   #:deliberation-failure
   #:tool-choice-unsupported #:tool-choice-unsupported-provider
   #:tool-choice-unsupported-requested
   #:missing-provenance #:missing-provenance-operation #:missing-provenance-subject
   #:embedding-dimension-mismatch #:embedding-dimension-mismatch-provider
   #:embedding-dimension-mismatch-expected #:embedding-dimension-mismatch-actual
   #:embedding-dimension-mismatch-source
   #:parallel-child-failure #:parallel-child-failure-failures
   #:parallel-child-failure-completed
   #:budget-exceeded #:budget-exceeded-requested #:budget-exceeded-available
   ;; restarts (as function-style invokers)
   #:retry-action #:substitute-result #:abandon-action))

(defpackage #:praxeon/context
  (:use #:cl)
  (:local-nicknames (#:a #:alexandria))
  (:export
   #:ctx-item #:make-ctx-item #:ctx-item-source #:ctx-item-content #:ctx-item-tokens
   #:ctx-item-valid-time #:ctx-item-tx-time #:ctx-item-role #:ctx-item-value
   #:context #:make-context #:context-budget #:context-items
   #:add-item #:assemble #:context-tokens #:now))

(defpackage #:praxeon/memory
  (:use #:cl)
  (:documentation
   "Observational memory: what an agent has learned about someone, across sessions.

    The surface is remember / supersede / recall. A correction replaces what was believed
    rather than adding to it, so supersession is an explicit relation rather than something
    a ranking is left to infer from timestamps. Scoped by subject rather than by agent, so
    several personas share what one of them was told. The storage seam is a set of generics
    with one in-memory implementation; Kairos or pgvector implement the same generics later.")
  (:export #:memory-store #:in-memory-store #:make-in-memory-store
           #:provenance #:make-provenance #:provenance-conversation #:provenance-turn
           #:provenance-at #:observation-provenance #:check-provenance #:provenance-p
           #:observation #:observation-id #:observation-subject #:observation-content
           #:observation-kind #:observation-value #:observation-tokens
           #:observation-valid-from #:observation-recorded-at
           #:observation-supersedes #:observation-superseded-by #:observation-superseded-at
           #:observation-current-p
           #:remember #:supersede #:recall #:recall-similar #:observation->ctx-item
   #:observations-of #:forget #:forget-subject))

(defpackage #:praxeon/llm
  (:use #:cl)
  (:local-nicknames (#:http #:aion/http-client)
                    (#:jzon #:com.inuoe.jzon)
                    (#:a #:alexandria)
                    (#:log #:aion/log))
  (:export
   ;; protocol
   #:provider #:complete
   ;; the embedding seam (#372, #415) -- a SEPARATE hierarchy, not a capability on PROVIDER
   #:embedding-provider #:embed #:embed-batch
   #:embedding-dimensions #:embedding-model-of
   #:openai-compatible-embeddings #:oai-embed-model #:oai-embed-base-url
   #:oai-embed-api-key
   #:register-embedding-impl #:make-embedding-provider-from-env
   #:check-embedding-dimensions
   ;; neutral messages + content parts
   #:msg #:role #:content
   #:text-part #:tool-use-part #:tool-result-part
   ;; neutral tools + completions
   #:tool-choice #:supports-tool-choice-p #:check-tool-choice
   #:anthropic-request-body #:openai-request-body
   #:generate-structured #:validate-arguments #:validate-against-schema
   #:unenforced-declarations #:check-schema-enforceable
   #:unenforceable-schema #:unenforceable-schema-tool
   #:unenforceable-schema-declarations
   #:*default-structured-attempts*
   #:structured-result-rejected #:structured-result-rejected-tool
   #:structured-result-rejected-problems #:structured-result-rejected-attempt
   #:structured-result-invalid #:structured-result-invalid-tool
   #:structured-result-invalid-problems #:structured-result-invalid-attempt
   #:structured-result-not-called #:structured-result-not-called-tool
   #:tool-spec #:make-tool-spec #:tool-spec-validators
   #:tool-spec-name #:tool-spec-description #:tool-spec-schema #:tool-spec-cache
   #:tool-call #:make-tool-call
   #:tool-call-id #:tool-call-name #:tool-call-arguments
   #:completion #:make-completion
   #:completion-text #:completion-tool-calls #:completion-stop-reason
   #:completion-input-tokens #:completion-output-tokens
   #:completion-cache-read-tokens #:completion-cache-write-tokens
   #:cache-boundary-p
   ;; providers
   #:anthropic #:anthropic-model #:anthropic-api-key
   #:openai-compatible #:model-of
   #:*default-model* #:*default-max-tokens*
   #:*connect-timeout* #:*read-timeout*
   ;; environment-driven provider selection
   #:make-provider-from-env #:register-provider-impl))

(defpackage #:praxeon/distil
  (:use #:cl)
  (:local-nicknames (#:llm #:praxeon/llm)
                    (#:mem #:praxeon/memory))
  (:documentation
   "Turning a window of a transcript into observations.

    praxeon/memory answers where an observation lives; this answers where one comes from
    when nobody wrote it by hand. It is ONE CALLER of `remember', never a gate in front of
    it -- the reliable observations are the ones someone stated outright, and putting a
    salience judgement ahead of those is worse than recording them as corrections.

    Extraction is applied; supersession is only PROPOSED. Reading a window is a claim about
    content the window can be checked against. Saying a new observation replaces an existing
    one is a claim about identity, and the existing one is not in the window. A wrong
    `remember' adds a bad fact; a wrong `supersede' also removes a good one, which is the
    half nobody sees.")
  (:export #:distil #:apply-distillation
           #:distillation #:distillation-subject #:distillation-proposals
           #:distillation-replacements
           #:proposal #:proposal-content #:proposal-kind #:proposal-replaces
           #:proposal-because
           #:observation-tool #:*system-prompt*))

(defpackage #:praxeon/prompt
  (:use #:cl)
  (:documentation
   "What is SENT, as distinct from what is remembered (#402, ADR-0001). History is
    TRIMMED -- whole exchanges, oldest first, never through the cacheable prefix (#401);
    retrieved facts are RANKED by praxeon/context and placed after it. Nothing here
    mutates an agent.")
  (:local-nicknames (#:ctx #:praxeon/context)
                    (#:llm #:praxeon/llm)
                    (#:evt #:praxeon/event))
  (:export
   ;; estimating -- a claim about tokens, not a measurement of them
   #:estimate-tokens #:part-tokens #:message-tokens #:messages-tokens
   #:*chars-per-token* #:*message-overhead-tokens*
   ;; the unit of trimming
   #:exchanges #:tool-result-message-p #:cache-boundary-message-p
   #:pinned-exchange-count
   ;; the two operations the turn loop calls
   #:trim-history #:render-items #:attach-context
   #:*context-open* #:*context-close*))

(defpackage #:praxeon/turn
  (:use #:coalton #:coalton-prelude)
  (:documentation
   "One agent turn as a VALUE a pipeline can operate on (#130). aion/interceptor threads
    a context :c through enter/leave stages; praxeon had no :c, so the flagship example
    hand-composed translate -> turn -> guardrail in a let* and said so in its docstring --
    stages that cannot be reordered, inspected, or short-circuited. TURN is that context:
    input, locale, reply, note, halted, all promised representations so the CL shell can
    read them through accessors without touching a define-type's insides. RUN-CHAIN is the
    monomorphic runner; the LLM round trip is the single effect at the edge.")
  (:export #:Turn #:make-turn
           #:turn-input #:turn-locale #:turn-reply #:turn-note #:turn-halted
           #:with-input #:with-reply #:with-note #:halt-with
           #:enter-stage #:leave-stage #:guard-stage
           #:run-chain))

(defpackage #:praxeon/ceiling
  (:use #:cl)
  (:local-nicknames (#:cnd #:praxeon/conditions)
                    (#:turn #:praxeon/turn)
                    (#:jzon #:com.inuoe.jzon)
                    (#:bt #:bordeaux-threads))
  (:documentation
   "What a caller may spend, and refusing before it is spent (#172). Two ceilings, not
    one: this is the per-session RUNAWAY cap -- the `curl` in a loop -- carried as a claim
    in a grant the application signs. The monthly billing quota stays with the application,
    at mint time, where the ledger already lives; separating them dissolves the trade
    between a budget that can go stale and one that needs a database credential.

    The grant is Ed25519-signed: this side holds a PUBLIC key and can verify but not mint,
    so compromising the agent host does not yield unlimited-budget grants. Usage is
    returned IN-BAND for the application to write, which is what actually keeps the agent
    free of a credential. Enforcement is an ENTER stage over a turn, so a refusal skips the
    model call rather than being appended to an answer already paid for.")
  (:export #:grant #:grant-p #:grant-principal #:grant-group #:grant-capabilities
           #:grant-token-cap #:grant-call-cap #:grant-expires-at #:grant-audience
           #:grant-permits-p #:grant-permit-fn
           #:verify-grant #:ed25519-verifier #:make-ed25519-verifier
           #:grant-invalid #:grant-invalid-reason
           #:budget-exhausted #:budget-exhausted-principal
           #:budget-exhausted-requested #:budget-exhausted-remaining
           #:ledger #:make-ledger #:ledger-grant #:ledger-tokens #:ledger-calls
           #:remaining-tokens #:remaining-calls #:affordable-p
           #:record-usage #:usage-report
           #:chargeable-tokens #:*token-weights*
           #:budget-guard #:capability-guard #:meter))

(defpackage #:praxeon/actor
  (:use #:cl)
  (:local-nicknames (#:px #:praxeon/praxeology)
                    (#:cnd #:praxeon/conditions)
                    (#:ctx #:praxeon/context)
                    (#:llm #:praxeon/llm)
                    (#:prompt #:praxeon/prompt)
                    (#:evt #:praxeon/event)
                    (#:turn #:praxeon/turn)
                    (#:a #:alexandria))
  (:export
   #:agent #:make-agent #:agent-name #:agent-provider #:agent-means
   #:agent-context #:agent-history #:agent-history-budget #:agent-system-prompt
   #:agent-cache-system #:agent-system-parts
   #:request-messages
   #:means-entry #:register-means #:means-permitted-p #:agent-means-for
   ;; The accessors of what AGENT-MEANS-FOR returns. NAME and DESCRIPTION were missing, so an
   ;; app could enumerate the means it may use and not read them -- which is the
   ;; knowable-blast-radius property of ADR-0002 being exported in a form nobody can consume.
   #:means-entry-name #:means-entry-description #:means-entry-capability #:agent-tool-specs #:register-agent-as-means
   #:deliberate #:act #:run-turn #:converse-repl
   #:run-turn-through))

;;; ----------------------------------------------------------------------------
;;; Workflow: deterministic multi-agent coordination (the code-driven counterpart
;;; to praxeon/actor:register-agent-as-means). Drives the ontology's Plan.
;;; ----------------------------------------------------------------------------
(defpackage #:praxeon/workflow
  (:use #:cl)
  (:local-nicknames (#:actor #:praxeon/actor)
                    (#:evt #:praxeon/event)
                    (#:cnd #:praxeon/conditions)
                    (#:bt #:bordeaux-threads)   ; fan-out really fans out (#418)
                    (#:px #:praxeon/praxeology))
  (:shadow #:step)                         ; STEP is our step-builder here
  (:export
   #:workflow #:make-workflow #:step #:parallel #:run-workflow
   #:blackboard #:bb-result #:bb-final #:bb-end #:bb-outputs #:bb-order))

;;; ----------------------------------------------------------------------------
;;; Studio: REPL introspection over the live agent (all provider-neutral).
;;; ----------------------------------------------------------------------------
(defpackage #:praxeon/studio
  (:use #:cl)
  (:local-nicknames (#:actor #:praxeon/actor)
                    (#:llm #:praxeon/llm)
                    (#:ctx #:praxeon/context)
                    (#:prompt #:praxeon/prompt)
                    (#:evt #:praxeon/event))
  (:export #:agent-summary #:describe-agent
           #:show-transcript #:render-message #:trace-turn
           #:status-observer))

;;; ----------------------------------------------------------------------------
;;; Umbrella.
;;; ----------------------------------------------------------------------------
(defpackage #:praxeon
  (:use #:cl)
  (:import-from #:praxeon/actor
                #:agent #:make-agent #:register-means #:register-agent-as-means
                #:run-turn #:converse-repl)
  (:import-from #:praxeon/llm
                #:anthropic #:*default-model*)
  (:export
   #:agent #:make-agent #:register-means #:register-agent-as-means
   #:run-turn #:converse-repl
   #:anthropic #:*default-model*))
