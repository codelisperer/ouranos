;;;; praxeon.asd --- system definitions for Praxeon
;;;;
;;;; Praxeon: a Common Lisp / Coalton framework for building industrial-strength
;;;; agentic systems, in the lineage of Norvig's PAIP. The name is deliberate:
;;;; von Mises' praxeology (the "science of human action") supplies the core
;;;; ontology -- actors apply *means* to attain *ends* through *action*, under
;;;; uncertainty, economizing a scarce resource (here, the context/token budget).

(defsystem "praxeon"
  :description "A praxeological framework for agentic AI in Common Lisp + Coalton."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.1"
  :depends-on ("aion/log"      ; neutral logging facade
               "aion/dynamic"  ; bindings that cross a thread (#158); used in workflow, event
               "aion/interceptor"  ; the typed pipeline a turn is threaded through (pre-publication issue 130)
               "aion/boundary"     ; RUN-TURN-THROUGH checks its CHAIN before it enters Coalton (#110)
               "aion/http-client"  ; the shared outbound client (pre-publication issue 202)
               "coalton"
               "alexandria"
               "cons"             ; config/env: the shared load-dotenv lives in cons
               "cons/env"         ; config.lisp calls cons/env:load-dotenv directly
               "dexador"          ; HTTP client for LLM providers
               "com.inuoe.jzon"   ; JSON reader/writer
               "ironclad"         ; Ed25519 verification of signed grants (pre-publication issue 172)
               "bordeaux-threads")  ; the session ledger is shared across a turn
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "config")       ; .env -> environment loader
                             (:file "event")        ; client<->framework progress contract
                             (:file "praxeology")   ; Coalton-typed core ontology
                             (:file "conditions")   ; recoverable-failure protocol
                             (:file "context")      ; budgeted context (Kairos seed)
                             (:file "memory")       ; observational memory (pre-publication issue 60)
                             (:file "llm")          ; provider protocol + Anthropic
                             (:file "embedding")    ; the embedding seam (#138, #150)
                             (:file "structured")   ; forced tool calls (pre-publication issue 416)
                             (:file "distil")       ; window -> observations (pre-publication issue 452)
                             (:file "prompt")       ; what is SENT: trim + placement (pre-publication issue 402)
                             (:file "turn")         ; a turn as a value (interceptor context)
                             (:file "ceiling")      ; cost/rate ceiling as pipeline stages
                             (:file "actor")        ; the deliberate/act loop
                             (:file "workflow")     ; deterministic multi-agent coordination
                             (:file "studio"))))    ; REPL introspection (studio DX)
  :in-order-to ((test-op (test-op "praxeon/tests"))))

;;; The first proof of concept: Elise -- a modern-psychology successor to
;;; Weizenbaum's ELIZA/DOCTOR, drawing on an LLM instead of hard-coded scripts.
;;; A reusable web-search Means (Tavily-backed) any agent can register. The effect
;;; does IO, so it lives in the CL shell; the Actor stays provider-neutral (it's
;;; just a registered means with a JSON schema).
(defsystem "praxeon/memory-db"
  :description "Observational memory persisted through mnemosyne, with similarity recall over pgvector (#138)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  ;; AN AUX SYSTEM, AND NOT BECAUSE OF THE DAG. mnemosyne is to praxeon's LEFT, so this
  ;; dependency is legal in the core system too. What keeps it out of core is the design
  ;; rule: pre-publication issue 258's deliverable 2 asks for the seam "without praxeon growing a datastore of
  ;; its own", and praxeon/CLAUDE.md says anything an agent stores externally reaches
  ;; praxeon as an injected seam, never a dependency. praxeon's core :depends-on is
  ;; ("aion/log") and nothing else.
  :depends-on ("praxeon" "mnemosyne" "bordeaux-threads")
  :components ((:file "src/memory-db")))

(defsystem "praxeon/memory-db/tests"
  :description "Observational memory in a real Postgres with pgvector (#138)."
  ;; praxeon and mnemosyne are named directly by the suite (praxeon/memory, praxeon/llm,
  ;; mnemosyne/conn, ...), so they are declared here rather than reached through
  ;; praxeon/memory-db (#166).
  :depends-on ("praxeon/memory-db" "praxeon" "mnemosyne" "fiveam")
  :components ((:module "tests"
                :components ((:file "memory-db-tests"))))
  :perform (test-op (o c) (symbol-call :praxeon/memory-db/tests '#:run-tests)))

(defsystem "praxeon/web-search"
  :description "A web-search Means (Tavily-backed) for Praxeon agents."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("praxeon" "dexador" "com.inuoe.jzon"
               "aion/http-client")   ; web-search.lisp calls http:send-request directly
  :serial t
  :components ((:file "src/web-search")))

;;; A general one-shot translation capability (any agent): translate text between
;;; languages via a possibly-different, translation-tuned model. Elise uses it to
;;; converse in the user's locale; provider-neutral, so it's just praxeon + llm.
(defsystem "praxeon/translate"
  :description "One-shot LLM translation for Praxeon agents (locale-aware)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("praxeon")
  :serial t
  :components ((:file "src/translate")))

;;; ChatRBT: the motivating example for Elenchon -- a conversational front to the
;;; RBT pipeline (English requirement -> Cause-Effect Graph -> functional test
;;; cases). Hosted here in Praxeon (beside Elise) so the dependency is acyclic:
;;; the example depends on both praxeon and elenchon; neither framework depends on
;;; it, and elenchon's repo never pulls praxeon/hyperion. Placeholder while
;;; Elenchon's CEG core/solver land. The popup web UX (praxeon/web) is pending.
(defsystem "praxeon/chat-rbt"
  :description "ChatRBT: English requirements -> Cause-Effect Graphs -> test cases (Elenchon's PoC)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("praxeon" "elenchon")   ; + praxeon/web for the popup UX (pending)
  :serial t
  :components ((:module "examples/chat-rbt"
                :serial t
                :components ((:file "chat-rbt")))))

(defsystem "praxeon/elise"
  :description "Elise: a reflective, psychologically-informed conversational actor."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("praxeon" "praxeon/web"      ; web enables `bin/elise --server`
               "aion/boundary"              ; RESPOND-TURN checks its chain (#110)
               "aion/interceptor"           ; the element type of that check
               "hyperion"                   ; elise.lisp calls i18n:translate directly
               "praxeon/web-search"         ; gives Elise the web-search means
               "praxeon/translate"          ; lets Elise converse in the user's locale
               ;; THE APP declares its HTTP backend, not the framework (pre-publication issue 139/pre-publication issue 218). Elise
               ;; is a real deployable with `bin/elise --server', so it is the layer where
               ;; this choice belongs. Hunchentoot rather than Woo because a supervisor
               ;; must be able to stop it: Woo does not answer SIGTERM (measured -- see
               ;; praxeon/web above and hyperion/docs/signals-and-shutdown.md).
               "clack-handler-hunchentoot")
  :serial t
  :components ((:module "examples/elise"
                :serial t
                :components ((:file "elise")))))

(defsystem "praxeon/tests"
  :description "Test suite for Praxeon."
  :depends-on ("praxeon" "praxeon/web-search" "aion/boundary" "fiveam")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "praxeon-tests"))))
  :perform (test-op (op c)
             (uiop:symbol-call :fiveam :run! (uiop:find-symbol* :praxeon :praxeon/tests))))

;;; praxeon/web's OWN suite, and the reason it is a separate system rather than another file
;;; in praxeon/tests: driving a real server needs a real Clack handler, and which handler is
;;; the APPLICATION's choice -- praxeon/web must keep declaring none (pre-publication issue 139/ADR-0011, pre-publication issue 218).
;;; A test system is an application for that purpose, so this one declares hunchentoot (the
;;; backend that answers SIGTERM, as praxeon/elise does) and the core suite stays free of an
;;; HTTP server it has no use for.
;;;
;;; IT EXISTS BECAUSE praxeon/web EXPORTED A SURFACE AND NOTHING LOADED IT (pre-publication issue 151). The two
;;; existing tests that mention it read its .asd rather than loading the system, so they pass
;;; with no handler in the image -- and a layer no suite loads cannot report that its
;;; consumers are working around it, which is how elise's hand-rolled sleep loop survived.
(defsystem "praxeon/web/tests"
  :description "Test suite for praxeon/web: the blocking entry, and the surface."
  :depends-on ("praxeon/web" "praxeon" "hyperion"   ; web-tests.lisp calls actor: and server:
               "clack-handler-hunchentoot" "fiveam" "aion/test-threads")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "web-tests"))))
  :perform (test-op (op c)
             (uiop:symbol-call :fiveam :run!
                               (uiop:find-symbol* :praxeon-web :praxeon/web/tests))))

;;; A Clack-based web + REST surface for Praxeon agents (HTMX UI). The server backend is
;;; the APPLICATION's choice and is declared by the application -- this system deliberately
;;; declares none (pre-publication issue 139/ADR-0011, applied here by pre-publication issue 218). See the :depends-on comment below.
(defsystem "praxeon/web"
  :description "A Clack-based web + REST surface for Praxeon agents (HTMX UI)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :depends-on ("praxeon" "hyperion"          ; server, hot-reload, request utils, JS
               "aion/dynamic"                ; web.lisp wraps the turn thread in INHERITING
               "hyperion/assets"             ; vendored htmx/Bulma, embedded (no CDN)
               "spinneret" "com.inuoe.jzon"  ; still used directly by the chat UI
               (:require "sb-concurrency")   ; thread-safe mailbox for the SSE channel
               ;; The HTTP backend is the APP's choice, not hyperion's (pre-publication issue 139) -- and it is
               ;; declared as the CLACK HANDLER system, not the bare server, because that
               ;; is what `clackup` resolves :woo / :hunchentoot through. Depending on the
               ;; raw server (as this did) left Clack to lazy-load the handler at runtime.
               ;; NO HTTP BACKEND HERE, deliberately -- the same decision hyperion took
               ;; at pre-publication issue 139 / ADR-0011, which this system was simply missed by. See the long
               ;; comment in hyperion.asd: a FRAMEWORK does not get to choose the
               ;; APPLICATION's HTTP server. praxeon/web is a framework aux system, so the
               ;; app declares the handler it wants and hyperion/server:default-server
               ;; picks from what the image actually loaded.
               ;;
               ;; It used to declare clack-handler-woo on Unix, which meant every praxeon
               ;; web app deployed on Linux or macOS ran on Woo without ever choosing it --
               ;; and WOO DOES NOT ANSWER SIGTERM (pre-publication issue 218). Measured 3x per cell on macOS,
               ;; and 21 runs on Linux before that; hunchentoot and the native :uv backend
               ;; both keep the signal, in both modes:
               ;;
               ;;   woo          toplevel/serve-forever   TIMEOUT
               ;;   hunchentoot  toplevel/serve-forever   FIRED
               ;;   uv           toplevel/serve-forever   FIRED
               ;;
               ;; So a supervisor's SIGTERM was ignored, SIGKILL arrived after the grace
               ;; period, in-flight requests were dropped and no shutdown hook ran -- for
               ;; an app that had never asked for Woo. hyperion/docs/signals-and-shutdown.md
               ;; already said "an app that a supervisor must be able to stop should not
               ;; declare Woo"; the defect was that praxeon declared it on the app's behalf.
               ;;
               ;; An image with no handler fails at DEFAULT-SERVER with NO-SERVER-BACKEND
               ;; -- loudly, at startup, naming the problem. That is the intended outcome
               ;; and is why nothing is substituted here.
               )
  :serial t
  :components ((:file "src/web"))
  ;; An unregistered suite, an unrun suite and a passing suite are identical at the exit
  ;; code, so the suite is wired to the system it tests rather than left to be remembered.
  :in-order-to ((test-op (test-op "praxeon/web/tests"))))
