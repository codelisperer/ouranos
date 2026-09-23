;;;; llm.lisp --- LLM provider protocol and an Anthropic implementation
;;;;
;;;; A provider is anything that can COMPLETE a conversation. The protocol is a
;;;; single generic function, COMPLETE, so additional providers -- other vendors,
;;;; a local model, or a future model grown inside Praxeon itself -- slot in
;;;; without touching the actor loop.
;;;;
;;;; The protocol speaks a *provider-neutral* vocabulary. A request carries
;;;; neutral MESSAGES and TOOL-SPECs; the answer comes back as a neutral
;;;; COMPLETION (text + requested TOOL-CALLs + a stop reason). Anthropic-specific
;;;; JSON lives only in the ANTHROPIC method below; the deliberate/act loop never
;;;; sees a vendor wire format, and neither will the next provider.

(cl:in-package #:praxeon/llm)

(defparameter *default-model* "claude-sonnet-5"
  "Default model id. Confirmed a valid Claude API model string; for heavy
agentic tool-use loops prefer a more capable model such as \"claude-opus-4-8\".")

(defparameter *default-max-tokens* 1024
  "Default output-token budget for a completion when the caller passes no
:max-tokens. A reasoning model may need a larger budget to finish thinking and
still answer -- bind this higher for such models, or when a deliberate/act step
truncates (stop-reason :max-tokens).")

(defparameter *connect-timeout* 10
  "Seconds to wait for the provider TCP/TLS connect before failing. A short bound:
a connect that doesn't complete quickly won't complete.")

(defparameter *read-timeout* 120
  "Seconds to wait for the provider *response* before failing. Turns a stalled or
half-open connection into a surfaced error (caught by the loop and shown to the
user) instead of an infinite hang that leaves the agent 'thinking' forever. Bind
higher for slow reasoning models if a legitimate long turn ever trips it.")

;;; --------------------------------------------------------------------------
;;; Neutral messages and content parts
;;;
;;; A message is a plist (:role R :content C). CONTENT is either a plain string
;;; or a list of PARTs. A part is a plist tagged by :type -- :text, :tool-use,
;;; or :tool-result -- so one message shape carries ordinary turns, an
;;; assistant's tool requests, and the tool results fed back to it.
;;; --------------------------------------------------------------------------
(defun msg (role content)
  "A message plist. ROLE is \"user\" or \"assistant\"; CONTENT is a string or a
list of content parts."
  (list :role role :content content))

(defun role (m) (getf m :role))
(defun content (m) (getf m :content))

(defun text-part (text &key cache)
  "A neutral text content part. CACHE marks this part as the END of a cacheable
prefix -- see `cache-boundary-p' and the commentary below."
  (if cache
      (list :type :text :text text :cache t)
      (list :type :text :text text)))

;;; --- the cacheable prefix (#401) ------------------------------------------
;;;
;;; A chat turn resends the whole conversation, so an N-turn conversation costs O(N^2) in
;;; input tokens, and the repeating part -- system prompt, per-user context, every turn but
;;; the last -- is byte-identical every time. Providers that cache a prefix charge roughly a
;;; tenth for a cache read. Measured in a consuming app: a trivial one-line question cost 574
;;; input tokens against an EMPTY history, essentially all of it prefix.
;;;
;;; THE MARKER IS A PROPERTY OF A PART, NOT AN INDEX, and that is the load-bearing choice.
;;; `:cache t' on a part means "the cacheable prefix ends here, inclusive" -- the same
;;; semantics Anthropic's cache_control block carries, so the translation is 1:1 rather than
;;; an interpretation.
;;;
;;; An index or a message count would have been simpler and is wrong for one reason: history
;;; trimming (#402). A budget that drops an early message SILENTLY MOVES what an index points
;;; at, so a breakpoint meant for the end of the system context ends up mid-conversation and
;;; costs full price on every turn while looking exactly like one that works. A marker
;;; attached to the data cannot be relocated by trimming: either the marked part is still
;;; there, or it was dropped and there is no breakpoint at all -- which the cache counts on
;;; the completion make visible.
;;;
;;; WHICH CONSTRAINS #402 RATHER THAN THE REVERSE. A cached prefix is only a saving while its
;;; bytes do not change, so a budget that trims from the FRONT defeats caching completely:
;;; every turn writes a new cache entry at 1.25x and reads none. The two features are the
;;; same decision from opposite ends. Whatever #402 does, the marked prefix has to be PINNED
;;; -- trimming happens after it, never through it.
;;;
;;; FAILING QUIET is requirement 3 and it is the reason this is a hint rather than a request
;;; parameter: a provider with no prefix cache ignores `:cache' entirely and the call still
;;; succeeds. What tells you whether it worked is not an error but
;;; COMPLETION-CACHE-READ-TOKENS, which is NIL on a provider that does not report it and 0 on
;;; one that does and missed.

(defun cache-boundary-p (part)
  "True when PART marks the end of a cacheable prefix (#401)."
  (and (getf part :cache) t))

(defun tool-use-part (id name input)
  "A neutral part recording that the assistant invoked NAME (call id ID) with
INPUT, the structured arguments."
  (list :type :tool-use :id id :name name :input input))

(defun tool-result-part (tool-use-id content &optional is-error)
  "A neutral part carrying the RESULT of the call TOOL-USE-ID back to the model.
CONTENT is a string; IS-ERROR marks a failed application."
  (list :type :tool-result :tool-use-id tool-use-id :content content
        :is-error is-error))

;;; --------------------------------------------------------------------------
;;; Neutral tools and completions
;;; --------------------------------------------------------------------------
(defstruct (tool-spec (:constructor make-tool-spec))
  "A tool advertised to a provider: NAME, human DESCRIPTION, and a JSON-schema
value (a jzon-serializable hash-table, or NIL) describing its arguments."
  (name "" :type string)
  (description "" :type string)
  (schema nil)
  ;; CACHE marks this spec as the end of a cacheable prefix (#401). Tools sit before the
  ;; system prompt in a provider's prefix ordering, so a breakpoint here caches the tool
  ;; definitions alone -- worth it when the tool set is large and stable and the system
  ;; prompt is not.
  (cache nil)
  ;; VALIDATORS are functions of the returned arguments, each returning NIL when the
  ;; arguments are acceptable or a string describing what is wrong (#416).
  ;;
  ;; THE FRAMEWORK HOLDS THE MECHANISM AND THE CALLER HOLDS THE VALUES. Length limits and
  ;; required wording are facts about someone else's platform: they differ by destination
  ;; and they change without telling us. A table of those limits in praxeon would be stale
  ;; the week after it was written, and wrong in a way the caller cannot override. So the
  ;; caller passes the predicate and praxeon runs it before returning a result.
  (validators nil :type list))

(defstruct (tool-call (:constructor make-tool-call))
  "A tool invocation the model requested: a call ID, the tool NAME, and the
parsed ARGUMENTS."
  (id "" :type string)
  (name "" :type string)
  (arguments nil))

(defstruct (completion (:constructor make-completion))
  "The neutral result of a completion: any TEXT the model emitted, the
TOOL-CALLS it requested, a STOP-REASON keyword
\(:end :tool-use :max-tokens :refusal :stop :other), and optional token usage
(INPUT-TOKENS / OUTPUT-TOKENS, NIL when the provider didn't report it -- a neutral
concept: Anthropic input/output_tokens, OpenAI prompt/completion_tokens)."
  (text "" :type string)
  (tool-calls '() :type list)
  (stop-reason :end :type keyword)
  (input-tokens nil)
  (output-tokens nil)
  ;; Prefix-cache accounting (#401). NIL and 0 are DIFFERENT ANSWERS and the distinction is
  ;; the whole point: NIL means the provider did not report it, 0 means it reported a miss.
  ;; Collapsing them would make a misplaced breakpoint indistinguishable from a provider
  ;; that has no cache -- and a breakpoint one message too late costs full price on every
  ;; turn while looking exactly like one that works. Without these two numbers the feature
  ;; is unfalsifiable from the caller's side: the bill changes and nothing says why.
  (cache-read-tokens nil)
  (cache-write-tokens nil))

;;; --------------------------------------------------------------------------
;;; Protocol
;;; --------------------------------------------------------------------------
(defclass provider () ()
  (:documentation "Abstract base for anything that can complete a conversation."))

(defgeneric complete (provider messages &key system tools max-tokens temperature tool-choice)
  (:documentation "Return a COMPLETION for MESSAGES. SYSTEM is an optional system
prompt; TOOLS is a list of TOOL-SPECs the model may call. Implementations should
signal PRAXEON/CONDITIONS:DELIBERATION-FAILURE (or a subtype) on unrecoverable
error.

TOOL-CHOICE says how the model may use TOOLS, in neutral terms each backend
translates:

  :auto          the model decides. The default, and today's behaviour.
  :none          the model must not call a tool.
  (:tool NAME)   the model must call the tool called NAME.

A provider that cannot honour a forced choice must SIGNAL rather than fall back to
:auto. A silent downgrade returns prose to a caller that is about to treat it as a
record, and nothing downstream can tell the difference until the data is stored."))

(defgeneric supports-tool-choice-p (provider)
  (:documentation "True when PROVIDER can honour a TOOL-CHOICE other than :auto.

Defaults to NIL so a provider that has not said it can do this is refused rather than
silently downgraded. A new backend opts in by defining this, which is a decision someone
makes rather than a default they inherit.")
  (:method ((p provider)) nil))

(defun check-tool-choice (provider tool-choice)
  "Signal unless PROVIDER can honour TOOL-CHOICE. Returns the choice."
  (unless (or (null tool-choice) (eq tool-choice :auto)
              (supports-tool-choice-p provider))
    (error 'praxeon/conditions:tool-choice-unsupported
           :provider (string (type-of provider))
           :requested tool-choice))
  tool-choice)

(defun %valid-tool-choice-p (tool-choice)
  (or (null tool-choice)
      (member tool-choice '(:auto :none))
      (and (consp tool-choice) (eq (first tool-choice) :tool)
           (stringp (second tool-choice)))))

;;; Observability for every provider, present and future: an :around on the protocol
;;; itself rather than a log call inside each backend, so a new provider is instrumented
;;; the moment it specializes COMPLETE and nobody has to remember to add logging.
;;;
;;; What is logged is deliberately COUNTS AND METADATA ONLY -- never the messages, the
;;; system prompt, or the completion text. Prompts carry whatever the user typed and
;;; whatever context was retrieved for them; that is exactly the data that must not be
;;; copied into a log aggregator. Sizes, model, stop reason, token usage and latency are
;;; what you need to diagnose a slow or expensive call, and none of them leak content.
(defmethod complete :around ((p provider) messages
                             &key system tools max-tokens temperature tool-choice)
  (declare (ignorable system))
  (let ((start (get-internal-real-time))
        (model (model-of p)))
    (log:debug "llm request" :provider (string (type-of p)) :model model
                             :messages (length messages) :tools (length tools)
                             :system (if system t nil)      ; presence, never the prompt
                             :max-tokens max-tokens :temperature temperature
                             ;; the SHAPE of the choice, never a tool name a prompt may have
                             ;; put there -- this log line is metadata only.
                             :tool-choice (cond ((null tool-choice) "auto")
                                                ((keywordp tool-choice) (string-downcase tool-choice))
                                                (t "forced")))
    (handler-bind
        ((cl:error (lambda (c)
                     ;; :warn, not :error -- a provider failure is often retried or falls
                     ;; back to another provider, so it is not by itself an app error. The
                     ;; caller decides; we just make sure it is never silent.
                     (log:warn "llm request failed" :provider (string (type-of p))
                                                    :model model :error (princ-to-string c)
                                                    :ms (%ms-since start)))))
      (let ((completion (call-next-method)))
        (log:debug "llm response" :model model
                                  :stop-reason (completion-stop-reason completion)
                                  :input-tokens (completion-input-tokens completion)
                                  :output-tokens (completion-output-tokens completion)
                                  ;; Cache counts on every provider present and future
                                  ;; (#401), for the same reason the rest is here: a new
                                  ;; backend is instrumented the moment it specializes
                                  ;; COMPLETE. These are counts, so they leak nothing.
                                  :cache-read-tokens (completion-cache-read-tokens completion)
                                  :cache-write-tokens (completion-cache-write-tokens completion)
                                  :tool-calls (length (completion-tool-calls completion))
                                  :text-length (length (completion-text completion))
                                  :ms (%ms-since start))
        completion))))

(defun %ms-since (start)
  "Milliseconds since START (an internal-real-time reading), rounded."
  (round (* 1000 (- (get-internal-real-time) start)) internal-time-units-per-second))

(defun %http-error-detail (label e)
  "A detail string for a failed HTTP request E. Includes the status and response body when
there is one -- the body is where a provider explains a 400, so surfacing it turns an opaque
failure into an actionable one.

Reads AION/HTTP-CLIENT:HTTP-ERROR rather than decoding dexador conditions directly (#202).
praxeon used to hand-roll that decoding in this function precisely because the shared client
was not reachable; now the client carries status and body and this only has to phrase them."
  (typecase e
    (http:http-error
     (if (http:http-error-status e)
         (format nil "~A: HTTP ~A -- ~A" label (http:http-error-status e)
                 (or (http:http-error-body e) ""))
         (format nil "~A: ~A" label (or (http:http-error-detail e) e))))
    (t (format nil "~A: ~A" label e))))

(defun %post-json (url headers payload)
  "One JSON POST through the shared interceptor client, returning the response body.

A non-2xx signals HTTP-ERROR carrying the provider's body, which is what the callers below
turn into a DELIBERATION-FAILURE. Timeouts are the module's own, as before."
  (http:response-body
   (http:send-request
    (http:make-request :method :post :url url :headers headers :content payload
                       :connect-timeout *connect-timeout*
                       :read-timeout *read-timeout*)
    (list (http:ensure-2xx url)))))

;;; --------------------------------------------------------------------------
;;; Anthropic
;;; --------------------------------------------------------------------------
(defclass anthropic (provider)
  ((model :initarg :model
          :initform (or (uiop:getenv "PRAXEON_LLM_MODEL") *default-model*)
          :reader anthropic-model)
   (api-key :initarg :api-key
            :initform (uiop:getenv "PRAXEON_LLM_API_KEY")
            :reader anthropic-api-key)
   (endpoint :initarg :endpoint
             :initform "https://api.anthropic.com/v1/messages"
             :reader anthropic-endpoint)
   (version :initarg :version :initform "2023-06-01" :reader anthropic-version))
  (:documentation "The Anthropic Messages API as a Praxeon provider. Authenticates
with an x-api-key from PRAXEON_LLM_API_KEY, billed to that key's API credits. (A
Pro/Max subscription funds Claude.ai and Claude Code, not the raw Messages API, so
there is no subscription-billed path here.)"))

(defun %auth-headers (p)
  "Request headers for provider P: an x-api-key plus the API version."
  `(("x-api-key" . ,(anthropic-api-key p))
    ("anthropic-version" . ,(anthropic-version p))
    ("content-type" . "application/json")))

(defun %anthropic-tool-choice-json (tool-choice)
  "Anthropic's tool_choice object for a neutral TOOL-CHOICE, or NIL to send nothing.

:AUTO SENDS NOTHING. Anthropic's default already is auto, so omitting the key keeps the
request byte-identical to what this backend built before tool-choice existed -- which is the
property that makes every existing agent provably unaffected."
  (cond
    ((or (null tool-choice) (eq tool-choice :auto)) nil)
    ((eq tool-choice :none)
     (let ((ht (make-hash-table :test #'equal)))
       (setf (gethash "type" ht) "none")
       ht))
    ((and (consp tool-choice) (eq (first tool-choice) :tool))
     (let ((ht (make-hash-table :test #'equal)))
       (setf (gethash "type" ht) "tool"
             (gethash "name" ht) (second tool-choice))
       ht))
    (t (error 'praxeon/conditions:deliberation-failure
              :detail (format nil "unknown tool-choice ~S" tool-choice)))))

(defun anthropic-request-body (p messages &key system tools
                                            (max-tokens *default-max-tokens*)
                                            temperature tool-choice)
  "The request body this backend sends, as a hash-table.

SEPARATE FROM THE POST so a test can read the JSON that is actually built rather than the
arguments that were passed in. Asserting the arguments would pass whether or not the
translation happened."
  (let ((body (make-hash-table :test #'equal)))
    (setf (gethash "model" body) (anthropic-model p)
          (gethash "max_tokens" body) max-tokens
          (gethash "messages" body)
          (coerce (mapcar #'%message->json messages) 'vector))
    ;; system, tools, and temperature are optional. Only send temperature when
    ;; explicitly asked: current models reject a non-default sampling
    ;; temperature (400), so omitting it is the portable default.
    ;; SYSTEM is a string or a list of neutral parts (#401). It has to accept parts because
    ;; caching the system prompt is the single largest win available -- the measured case was
    ;; 574 input tokens against an empty history, essentially all of it system and context --
    ;; and Anthropic can only cache it when it is sent as BLOCKS carrying cache_control. A
    ;; plain string stays a plain string, so every existing caller is unaffected.
    (when (and system (plusp (length system)))
      (setf (gethash "system" body) (%anthropic-system-json system)))
    (when tools
      (setf (gethash "tools" body)
            (coerce (mapcar #'%tool-spec->json tools) 'vector)))
    (when temperature
      (setf (gethash "temperature" body) temperature))
    (let ((choice (%anthropic-tool-choice-json tool-choice)))
      (when choice (setf (gethash "tool_choice" body) choice)))
    body))

(defmethod supports-tool-choice-p ((p anthropic)) t)

(defmethod complete ((p anthropic) messages
                     &key system tools (max-tokens *default-max-tokens*) temperature
                          tool-choice)
  (check-tool-choice p tool-choice)
  (let ((body (anthropic-request-body p messages :system system :tools tools
                                                 :max-tokens max-tokens
                                                 :temperature temperature
                                                 :tool-choice tool-choice)))
    (let* ((payload (jzon:stringify body))
           (response
             (handler-case
                 (%post-json (anthropic-endpoint p) (%auth-headers p) payload)
               (error (e)
                 (error 'praxeon/conditions:deliberation-failure
                        :detail (%http-error-detail "Anthropic request failed" e))))))
      (%parse-completion (jzon:parse response)))))

;;; --- request translation: neutral -> Anthropic JSON ---------------------
(defun %anthropic-system-json (system)
  "SYSTEM as Anthropic wants it: a plain string stays a string, a list of neutral parts
becomes a block array (#401).

Its own function rather than three lines inside COMPLETE, because logic inside COMPLETE can
only be exercised by making a request -- which for this file means spending API credits to
learn whether a `mapcar' ran."
  (if (stringp system)
      system
      (coerce (mapcar #'%part->json system) 'vector)))

(defun %message->json (m)
  (let ((ht (make-hash-table :test #'equal))
        (content (content m)))
    (setf (gethash "role" ht) (role m)
          (gethash "content" ht)
          (if (stringp content)
              content
              (coerce (mapcar #'%part->json content) 'vector)))
    ht))

(defun %part->json (part)
  (let ((ht (make-hash-table :test #'equal)))
    (ecase (getf part :type)
      (:text
       (setf (gethash "type" ht) "text"
             (gethash "text" ht) (getf part :text)))
      (:tool-use
       (setf (gethash "type" ht) "tool_use"
             (gethash "id" ht) (getf part :id)
             (gethash "name" ht) (getf part :name)
             (gethash "input" ht) (or (getf part :input)
                                      (make-hash-table :test #'equal))))
      (:tool-result
       (setf (gethash "type" ht) "tool_result"
             (gethash "tool_use_id" ht) (getf part :tool-use-id)
             (gethash "content" ht) (getf part :content))
       (when (getf part :is-error)
         (setf (gethash "is_error" ht) t))))
    ;; The prefix breakpoint (#401). Attached to the block the caller marked, because
    ;; Anthropic's cache_control means "cache through this block inclusive" -- which is
    ;; exactly what `:cache t' was defined to mean, so this is a translation and not an
    ;; interpretation. Emitted for ANY part type: a conversation's cacheable prefix commonly
    ;; ends on a tool_result, not on prose.
    (when (cache-boundary-p part)
      (setf (gethash "cache_control" ht) (%ephemeral)))
    ht))

(defun %ephemeral ()
  "Anthropic's cache_control value. Its own object rather than a literal at each site, so
the one place that knows the vendor's spelling of \"cache this\" is one place."
  (let ((ht (make-hash-table :test #'equal)))
    (setf (gethash "type" ht) "ephemeral")
    ht))

(defun %tool-spec->json (spec)
  (let ((ht (make-hash-table :test #'equal)))
    (setf (gethash "name" ht) (tool-spec-name spec)
          (gethash "description" ht) (tool-spec-description spec)
          (gethash "input_schema" ht) (or (tool-spec-schema spec)
                                          (%empty-object-schema)))
    (when (tool-spec-cache spec)
      (setf (gethash "cache_control" ht) (%ephemeral)))
    ht))

(defun %empty-object-schema ()
  "A permissive object schema, for a means registered without one."
  (let ((ht (make-hash-table :test #'equal)))
    (setf (gethash "type" ht) "object"
          (gethash "properties" ht) (make-hash-table :test #'equal))
    ht))

;;; --- response translation: Anthropic JSON -> neutral --------------------
(defun %parse-completion (parsed)
  "Pull neutral text and tool-calls out of an Anthropic Messages response.
PARSED is the jzon hash-table form of the JSON body."
  (let ((content (gethash "content" parsed))
        (text (make-string-output-stream))
        (calls '()))
    (when content
      (map nil
           (lambda (block)
             (let ((type (gethash "type" block)))
               (cond ((equal type "text")
                      (write-string (gethash "text" block) text))
                     ((equal type "tool_use")
                      (push (make-tool-call
                             :id (gethash "id" block)
                             :name (gethash "name" block)
                             :arguments (gethash "input" block))
                            calls)))))
           content))
    (let ((usage (gethash "usage" parsed)))
      (make-completion :text (get-output-stream-string text)
                       :tool-calls (nreverse calls)
                       :stop-reason (%stop-reason (gethash "stop_reason" parsed))
                       :input-tokens (and usage (gethash "input_tokens" usage))
                       :output-tokens (and usage (gethash "output_tokens" usage))
                       ;; `and usage' rather than `or ... 0': a field Anthropic omits stays
                       ;; NIL, and a field it reports as 0 stays 0. Defaulting a missing
                       ;; count to zero would claim the provider said "no cache read" when
                       ;; it said nothing at all, which is the one distinction these two
                       ;; numbers exist to preserve.
                       :cache-read-tokens
                       (and usage (gethash "cache_read_input_tokens" usage))
                       :cache-write-tokens
                       (and usage (gethash "cache_creation_input_tokens" usage))))))

(defun %stop-reason (s)
  (cond ((null s) :end)
        ((equal s "end_turn") :end)
        ((equal s "tool_use") :tool-use)
        ((equal s "max_tokens") :max-tokens)
        ((equal s "refusal") :refusal)
        ((equal s "stop_sequence") :stop)
        (t :other)))

;;; --------------------------------------------------------------------------
;;; OpenAI-compatible provider
;;;
;;; One class for every server that speaks OpenAI's /v1/chat/completions -- a
;;; local runtime (Ollama, LM Studio, llama.cpp) or a hosted aggregator
;;; (OpenRouter). Only the base URL and key differ; the neutral vocabulary is
;;; translated to/from OpenAI's schema here (tool_calls with JSON-string
;;; arguments, role:"tool" result messages, finish_reason).
;;; --------------------------------------------------------------------------
(defclass openai-compatible (provider)
  ((model :initarg :model
          :initform (or (uiop:getenv "PRAXEON_LLM_MODEL") "qwen2.5")
          :reader oai-model)
   (base-url :initarg :base-url
             :initform (or (uiop:getenv "PRAXEON_LLM_BASE_URL")
                           "http://localhost:11434/v1")
             :reader oai-base-url)
   (api-key :initarg :api-key
            :initform (uiop:getenv "PRAXEON_LLM_API_KEY")
            :reader oai-api-key))
  (:documentation "Any OpenAI-compatible chat endpoint as a Praxeon provider.
BASE-URL selects the target (Ollama http://localhost:11434/v1, OpenRouter
https://openrouter.ai/api/v1, ...); API-KEY is sent as a Bearer token when set
\(local servers usually ignore it, hosted ones require it)."))

(defun %oai-tool-choice-json (tool-choice)
  "OpenAI's tool_choice value for a neutral TOOL-CHOICE, or NIL to send nothing.

:AUTO SENDS NOTHING, for the same reason as the Anthropic side: the request stays
byte-identical to what this backend built before. Note the shapes differ -- OpenAI takes a
bare string for auto and none and an object naming a FUNCTION, where Anthropic takes an
object in every case. That difference is exactly what the neutral value exists to hide."
  (cond
    ((or (null tool-choice) (eq tool-choice :auto)) nil)
    ((eq tool-choice :none) "none")
    ((and (consp tool-choice) (eq (first tool-choice) :tool))
     (let ((ht (make-hash-table :test #'equal))
           (fn (make-hash-table :test #'equal)))
       (setf (gethash "name" fn) (second tool-choice)
             (gethash "type" ht) "function"
             (gethash "function" ht) fn)
       ht))
    (t (error 'praxeon/conditions:deliberation-failure
              :detail (format nil "unknown tool-choice ~S" tool-choice)))))

(defun openai-request-body (p messages &key system tools
                                         (max-tokens *default-max-tokens*)
                                         temperature tool-choice)
  "The request body this backend sends, as a hash-table. Separate from the POST for the
same reason as the Anthropic one."
  (let ((body (make-hash-table :test #'equal)))
    (setf (gethash "model" body) (oai-model p)
          (gethash "max_tokens" body) max-tokens
          (gethash "messages" body) (%messages->openai messages system))
    (when tools
      (setf (gethash "tools" body)
            (coerce (mapcar #'%oai-tool-spec tools) 'vector)))
    (when temperature
      (setf (gethash "temperature" body) temperature))
    (let ((choice (%oai-tool-choice-json tool-choice)))
      (when choice (setf (gethash "tool_choice" body) choice)))
    body))

(defmethod supports-tool-choice-p ((p openai-compatible)) t)

(defmethod complete ((p openai-compatible) messages
                     &key system tools (max-tokens *default-max-tokens*) temperature
                          tool-choice)
  (check-tool-choice p tool-choice)
  (let ((body (openai-request-body p messages :system system :tools tools
                                              :max-tokens max-tokens
                                              :temperature temperature
                                              :tool-choice tool-choice)))
    (let* ((payload (jzon:stringify body))
           (url (concatenate 'string (oai-base-url p) "/chat/completions"))
           (headers (append '(("content-type" . "application/json"))
                            (when (oai-api-key p)
                              (list (cons "authorization"
                                          (format nil "Bearer ~A" (oai-api-key p)))))))
           (response
             (handler-case
                 (%post-json url headers payload)
               (error (e)
                 (error 'praxeon/conditions:deliberation-failure
                        :detail (%http-error-detail
                                 (format nil "OpenAI-compatible request to ~A failed" url)
                                 e))))))
      (%parse-openai (jzon:parse response)))))

;;; --- request translation: neutral -> OpenAI JSON ------------------------
(defun %system-text (system)
  "SYSTEM as a plain string, whether it arrived as one or as a list of neutral parts (#401).
Non-text parts are skipped: a system prompt is prose, and silently stringifying a tool_use
block into it would put vendor shapes in front of a model that did not ask for them."
  (if (stringp system)
      system
      (with-output-to-string (s)
        (dolist (part system)
          (when (eq (getf part :type) :text)
            (write-string (getf part :text) s))))))

(defun %oai-msg (role content)
  (let ((ht (make-hash-table :test #'equal)))
    (setf (gethash "role" ht) role (gethash "content" ht) content)
    ht))

(defun %oai-tool-call (id name input)
  "An assistant tool_calls entry. OpenAI carries arguments as a JSON *string*."
  (let ((ht (make-hash-table :test #'equal))
        (fn (make-hash-table :test #'equal)))
    (setf (gethash "name" fn) name
          (gethash "arguments" fn)
          (jzon:stringify (or input (make-hash-table :test #'equal))))
    (setf (gethash "id" ht) id
          (gethash "type" ht) "function"
          (gethash "function" ht) fn)
    ht))

(defun %oai-tool-result (tool-call-id content)
  (let ((ht (make-hash-table :test #'equal)))
    (setf (gethash "role" ht) "tool"
          (gethash "tool_call_id" ht) tool-call-id
          (gethash "content" ht) content)
    ht))

(defun %message->openai (m)
  "Translate one neutral message into a LIST of OpenAI messages (tool results
expand into one role:\"tool\" message each)."
  (let ((role (role m)) (content (content m)))
    (if (stringp content)
        (list (%oai-msg role content))
        (let ((texts '()) (tool-calls '()) (tool-msgs '()))
          (dolist (part content)
            (ecase (getf part :type)
              (:text (push (getf part :text) texts))
              (:tool-use
               (push (%oai-tool-call (getf part :id) (getf part :name)
                                     (getf part :input))
                     tool-calls))
              (:tool-result
               (push (%oai-tool-result (getf part :tool-use-id)
                                       (getf part :content))
                     tool-msgs))))
          (if tool-msgs
              (nreverse tool-msgs)
              (let ((ht (make-hash-table :test #'equal)))
                (setf (gethash "role" ht) role
                      (gethash "content" ht)
                      (if texts (format nil "~{~A~}" (nreverse texts)) ""))
                (when tool-calls
                  (setf (gethash "tool_calls" ht)
                        (coerce (nreverse tool-calls) 'vector)))
                (list ht)))))))

(defun %messages->openai (messages system)
  ;; FAILING QUIET on the prefix marker (#401, requirement 3). OpenAI-compatible servers
  ;; have no caller-controlled breakpoint -- caching, where it exists, is automatic and
  ;; server-side -- so `:cache t' is DROPPED here rather than translated or rejected. The
  ;; call succeeds and costs what it costs; what tells a caller the hint went nowhere is
  ;; COMPLETION-CACHE-WRITE-TOKENS coming back NIL, not an error.
  ;;
  ;; A system prompt given as PARTS is flattened to text, because this API takes a string.
  ;; Flattening loses only the marker, which had no destination here anyway.
  (let ((out '()))
    (when (and system (plusp (length system)))
      (push (%oai-msg "system" (%system-text system)) out))
    (dolist (m messages)
      (dolist (om (%message->openai m))
        (push om out)))
    (coerce (nreverse out) 'vector)))

(defun %oai-tool-spec (spec)
  (let ((ht (make-hash-table :test #'equal))
        (fn (make-hash-table :test #'equal)))
    (setf (gethash "name" fn) (tool-spec-name spec)
          (gethash "description" fn) (tool-spec-description spec)
          (gethash "parameters" fn) (or (tool-spec-schema spec)
                                        (%empty-object-schema)))
    (setf (gethash "type" ht) "function"
          (gethash "function" ht) fn)
    ht))

;;; --- response translation: OpenAI JSON -> neutral -----------------------
(defun %parse-json-args (s)
  "Parse an OpenAI tool-call arguments JSON string into a hash-table."
  (if (and (stringp s) (plusp (length s)))
      (handler-case (jzon:parse s)
        (error () (make-hash-table :test #'equal)))
      (make-hash-table :test #'equal)))

(defun %parse-openai (parsed)
  (let* ((choices (gethash "choices" parsed))
         (choice (when (and choices (plusp (length choices))) (elt choices 0)))
         (message (when choice (gethash "message" choice)))
         (raw-text (when message (gethash "content" message)))
         (tool-calls (when message (gethash "tool_calls" message)))
         (calls '()))
    (when tool-calls
      (map nil
           (lambda (tc)
             (let ((fn (gethash "function" tc)))
               (push (make-tool-call
                      :id (or (gethash "id" tc) "")
                      :name (gethash "name" fn)
                      :arguments (%parse-json-args (gethash "arguments" fn)))
                     calls)))
           tool-calls))
    (let ((usage (gethash "usage" parsed)))
      (make-completion :text (if (stringp raw-text) raw-text "")
                       :tool-calls (nreverse calls)
                       :stop-reason (%openai-stop-reason
                                     (when choice (gethash "finish_reason" choice)))
                       :input-tokens (and usage (gethash "prompt_tokens" usage))
                       :output-tokens (and usage (gethash "completion_tokens" usage))
                       ;; Cache accounting, where the server offers any (#401). OpenAI
                       ;; reports automatic caching as prompt_tokens_details.cached_tokens
                       ;; and has no write count at all, so CACHE-WRITE-TOKENS stays NIL
                       ;; here -- which is the honest answer rather than a zero. A local
                       ;; runtime reporting neither leaves both NIL and nothing pretends
                       ;; otherwise.
                       :cache-read-tokens
                       (let ((details (and usage (gethash "prompt_tokens_details" usage))))
                         (and details (gethash "cached_tokens" details)))
                       :cache-write-tokens nil))))

(defun %openai-stop-reason (s)
  (cond ((null s) :end)
        ((equal s "stop") :end)
        ((equal s "tool_calls") :tool-use)
        ((equal s "length") :max-tokens)
        ((equal s "content_filter") :refusal)
        (t :other)))

(defvar *provider-role* nil
  "The agent ROLE currently being resolved from the environment (a string like
\"translate\" or \"scribe\"), or NIL for the global default. Bound by
MAKE-PROVIDER-FROM-ENV so per-agent env vars win -- see %ENV-FOR. This is how one
process runs several agents, each on its own model.")

(defun %env-for (impl suffix)
  "The value of PRAXEON_<SUFFIX>, most specific first: PRAXEON_<ROLE>_<SUFFIX> (the
per-agent role, when resolving one) > PRAXEON_<IMPL>_<SUFFIX> > the shared
PRAXEON_LLM_<SUFFIX>. So each agent-role carries its own model/key/auth, each impl
its own, and the shared vars still cover the simple single-provider case."
  (or (and *provider-role*
           (uiop:getenv (format nil "PRAXEON_~:@(~A~)_~A" *provider-role* suffix)))
      (uiop:getenv (format nil "PRAXEON_~:@(~A~)_~A" impl suffix))
      (uiop:getenv (format nil "PRAXEON_LLM_~A" suffix))))

(defun make-openai-from-env (impl &optional default-base-url)
  "An OPENAI-COMPATIBLE provider configured for IMPL (a name like \"openrouter\").
Reads PRAXEON_<IMPL>_{MODEL,API_KEY,BASE_URL}, falling back to the shared
PRAXEON_LLM_* vars, then DEFAULT-BASE-URL / Ollama's local URL."
  (make-instance 'openai-compatible
                 :model (or (%env-for impl "MODEL") "qwen2.5")
                 :base-url (or (%env-for impl "BASE_URL")
                               default-base-url
                               "http://localhost:11434/v1")
                 :api-key (%env-for impl "API_KEY")))

;;; --------------------------------------------------------------------------
;;; Provider selection from the environment
;;;
;;; PRAXEON_LLM_IMPL   picks the implementation (default "anthropic").
;;; PRAXEON_LLM_MODEL  the vendor model id (per-impl; falls back to *default-model*).
;;; PRAXEON_LLM_API_KEY the key (Anthropic x-api-key / OpenAI Bearer).
;;;
;;; A new vendor is a new PROVIDER class plus a constructor registered here --
;;; the whole selection layer stays provider-neutral.
;;; --------------------------------------------------------------------------
(defvar *provider-impls* '()
  "Alist of lowercased impl name -> a thunk returning a fresh PROVIDER.")

(defun register-provider-impl (name constructor)
  "Register CONSTRUCTOR (a function of no arguments returning a PROVIDER) under
NAME, for PRAXEON_LLM_IMPL selection. Returns NAME."
  (let ((key (string-downcase name)))
    (setf *provider-impls*
          (acons key constructor
                 (remove key *provider-impls* :key #'car :test #'string=))))
  name)

(defun make-provider-from-env (&key role)
  "Construct the provider for an agent ROLE (a string/keyword/symbol naming the agent,
e.g. :translate or \"scribe\"), or the global default when ROLE is NIL. Resolution is
per-role first: the impl comes from PRAXEON_<ROLE>_IMPL else PRAXEON_LLM_IMPL, and the
chosen constructor then reads PRAXEON_<ROLE>_{MODEL,API_KEY,AUTH,BASE_URL} before the
shared PRAXEON_LLM_* (see %ENV-FOR). So one process can run several agents, each on its
own model/vendor; NIL role reproduces the old single-provider behavior."
  (let* ((*provider-role* (and role (string role)))
         (impl (or (and *provider-role*
                        (uiop:getenv (format nil "PRAXEON_~:@(~A~)_IMPL" *provider-role*)))
                   (uiop:getenv "PRAXEON_LLM_IMPL")
                   "anthropic"))
         (ctor (cdr (assoc (string-downcase impl) *provider-impls*
                           :test #'string=))))
    (unless ctor
      (error 'praxeon/conditions:deliberation-failure
             :detail (format nil "no LLM impl registered for impl=~A~@[ (role ~A)~]"
                             impl role)))
    (funcall ctor)))

(defun make-anthropic-from-env ()
  "An ANTHROPIC provider from the environment. Reads PRAXEON_ANTHROPIC_{MODEL,
API_KEY} (falling back to the shared PRAXEON_LLM_* vars)."
  (make-instance 'anthropic
                 :model (or (%env-for "anthropic" "MODEL") *default-model*)
                 :api-key (%env-for "anthropic" "API_KEY")))

(register-provider-impl "anthropic" #'make-anthropic-from-env)
(register-provider-impl "openai"
                        (lambda () (make-openai-from-env "openai")))
(register-provider-impl "ollama"
                        (lambda () (make-openai-from-env "ollama" "http://localhost:11434/v1")))
(register-provider-impl "openrouter"
                        (lambda () (make-openai-from-env "openrouter" "https://openrouter.ai/api/v1")))

;;; --------------------------------------------------------------------------
;;; Introspection (provider-neutral)
;;; --------------------------------------------------------------------------
(defgeneric model-of (provider)
  (:documentation "The model id string PROVIDER will use for a completion, or NIL
if it does not advertise one."))
(defmethod model-of ((p provider)) nil)   ; graceful fallback for any provider
(defmethod model-of ((p anthropic)) (anthropic-model p))
(defmethod model-of ((p openai-compatible)) (oai-model p))
