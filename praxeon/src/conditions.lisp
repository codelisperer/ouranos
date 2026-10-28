;;;; conditions.lisp --- the recoverable-failure protocol for Praxeon
;;;;
;;;; Long-running agentic systems fail partially and often: a tool times out, a
;;;; provider rate-limits, a plan step returns garbage. CL's condition system is
;;;; close to ideal here: the code that SIGNALS a failure need not decide how to
;;;; recover; policy is injected at the handler. The invoker of a means should
;;;; establish the restarts below so that a supervising handler (or a human at
;;;; the REPL) can choose retry / substitute / abandon.

(cl:in-package #:praxeon/conditions)

(define-condition praxeon-error (error)
  ((detail :initarg :detail :initform nil :reader praxeon-error-detail))
  (:report (lambda (c stream)
             (format stream "~(~A~)~@[: ~A~]" (type-of c) (praxeon-error-detail c))))
  (:documentation "Root of all Praxeon-signalled errors.

DETAIL is a string saying what went wrong, or NIL. The report prints the condition's type and
then DETAIL. A subclass with a :REPORT of its own replaces this one; DELIBERATION-FAILURE prints
DETAIL in its own words, and DELIBERATION-FAILURE-DETAIL reads the same slot. Before #505 this
condition had no slot, so a :DETAIL passed to it was dropped and the report named only the
type."))

(define-condition means-failure (praxeon-error)
  ((means :initarg :means :reader means-failure-means)
   (cause :initarg :cause :initform nil :reader means-failure-cause))
  (:report (lambda (c stream)
             (format stream "The means ~A failed~@[: ~A~]."
                     (means-failure-means c)
                     (means-failure-cause c))))
  (:documentation "Signalled when applying a means does not succeed."))

(define-condition tool-error-result (praxeon-error)
  ((text :initarg :text :reader tool-error-result-text)
   (outcome :initarg :outcome :initform :error :reader tool-error-result-outcome))
  (:report (lambda (c stream)
             (format stream "The tool reported an error: ~A" (tool-error-result-text c))))
  (:documentation "Signalled by a means to say that its call failed and that the model should
be told TEXT as an error result, while the turn goes on (#527).

RUN-TURN gives the model a tool result with :IS-ERROR set and TEXT as its content, and runs
the turn's next step. Any other error from a means still ends the turn, as it always has; a
means opts into this by signalling this condition, or a subclass of it. TEXT reaches the
model, so it must hold nothing the model should not see, such as a secret or a URL meant for
one user.

OUTCOME says what happened, for a usage ledger reading the :TOOL-RESULT event: :ERROR when the
tool ran and reported an error, :NOT-RUN when it was refused before it ran, and :UNKNOWN when
it may have run, such as after a timeout."))

(define-condition deliberation-failure (praxeon-error)
  ((detail :reader deliberation-failure-detail))
  (:report (lambda (c stream)
             (format stream "Deliberation failed~@[: ~A~]."
                     (deliberation-failure-detail c))))
  (:documentation "Signalled when the actor cannot decide on an action."))

(define-condition provider-request-failed (deliberation-failure)
  ((status :initarg :status :initform nil :reader provider-request-failed-status)
   (error-type :initarg :error-type :initform nil :reader provider-request-failed-error-type)
   (error-code :initarg :error-code :initform nil :reader provider-request-failed-error-code)
   (body :initarg :body :initform nil :reader provider-request-failed-body))
  (:documentation "A request to a model, embedding or rerank service failed (#719).

STATUS is the HTTP status, or NIL when the request failed before a response arrived.
ERROR-TYPE and ERROR-CODE are read from the service's error JSON when the body parses as one
and the value is 1 to 64 letters, digits, underscores, dots or hyphens, otherwise NIL (#727). BODY is the whole response body, where the service explains the failure; read
it here.

The report and DELIBERATION-FAILURE-DETAIL leave the body out and give its length instead,
because praxeon/llm logs the report of a failed request at warn and a log line never carries a
payload (docs/logging.md). A service's response body can repeat parts of the request, which
holds the prompt."))

(define-condition unknown-tool-choice (deliberation-failure)
  ((value :initarg :value :initform nil :reader unknown-tool-choice-value))
  (:documentation "A provider was given a tool-choice value it does not recognise (#727).

VALUE is the value as given; read it here. The report and DELIBERATION-FAILURE-DETAIL say only
what kind of value it was and its length, because praxeon/llm logs the report of a failed
request at warn, and a tool-choice value can hold a tool name taken from a prompt
(docs/logging.md)."))

(define-condition output-limit-reached (condition)
  ((max-tokens :initarg :max-tokens :reader output-limit-reached-max-tokens))
  (:documentation "A model's output stopped at the output limit (stop reason :MAX-TOKENS)
before the model had finished (#326, #338). MAX-TOKENS is the limit the call ran with.

A parent of every condition praxeon signals for a cut-off result: OUTPUT-TRUNCATED from
RUN-TURN, TRANSLATION-TRUNCATED from PRAXEON/TRANSLATE:TRANSLATE and
STRUCTURED-RESULT-TRUNCATED from PRAXEON/LLM:GENERATE-STRUCTURED. Each is signalled inside the
restarts RETRY-WITH-MAX-TOKENS and ACCEPT-TRUNCATED, so one handler on this type can raise the
limit, or accept the cut-off result, wherever it happens."))

(define-condition output-truncated (deliberation-failure output-limit-reached)
  ((step-number :initarg :step :reader output-truncated-step)
   (max-tokens :initarg :max-tokens :reader output-truncated-max-tokens)
   (text :initarg :text :initform "" :reader output-truncated-text)
   (tool-calls :initarg :tool-calls :initform '() :reader output-truncated-tool-calls))
  (:report
   (lambda (c s)
     (let ((calls (length (output-truncated-tool-calls c))))
       (format s "The model's output reached the output limit of ~D tokens before the model had finished, at step ~D of the turn (steps count from 0, as on the :deliberating event). Nothing from that step was used: its text was not returned as an answer"
               (output-truncated-max-tokens c) (output-truncated-step c))
       (cond ((= calls 1) (format s ", and its tool call was not run"))
             ((> calls 1) (format s ", and its ~D tool calls were not run" calls)))
       (format s " (#326).~%~%A handler can ask again with a larger limit (RETRY-WITH-MAX-TOKENS), end the turn with the cut-off text (ACCEPT-TRUNCATED), or end it with no answer (ABANDON-TURN). To raise the limit for every turn, pass :max-tokens to RUN-TURN or set the agent's MAX-TOKENS."))))
  (:documentation "Signalled by RUN-TURN when a step's completion stopped at the output limit
\(stop reason :MAX-TOKENS) instead of finishing (#326).

STEP is the step's number, the same number as its :DELIBERATING event. MAX-TOKENS is the limit
the step ran with. TEXT is the text the model produced before it was cut off, and TOOL-CALLS the
tool calls the provider parsed from the cut-off output; their arguments may be incomplete, which
is why none of them was run.

A subtype of DELIBERATION-FAILURE, so a handler an app already has for a turn that produced no
answer also receives this. Before #326 a cut-off tool call was attempted again until MAX-STEPS
ran out and the turn ended in a DELIBERATION-FAILURE, so that handler is the one such an app was
using.

RUN-TURN signals it with ERROR, inside three restarts: RETRY-WITH-MAX-TOKENS, ACCEPT-TRUNCATED
and ABANDON-TURN. The functions of the same names below invoke them."))

(define-condition translation-truncated (deliberation-failure output-limit-reached)
  ((text :initarg :text :initform "" :reader translation-truncated-text))
  (:report
   (lambda (c s)
     (format s "The translation reached the output limit of ~D tokens before the model had finished, so it is shorter than the text it translates (#338).~%~%A handler can ask again with a larger limit (RETRY-WITH-MAX-TOKENS) or take the cut-off translation (ACCEPT-TRUNCATED). TRANSLATE's :max-tokens sets the limit for one call."
             (output-limit-reached-max-tokens c))))
  (:documentation "Signalled by PRAXEON/TRANSLATE:TRANSLATE when the model's translation stopped
at the output limit (#338). TEXT is the cut-off translation. Signalled with ERROR inside the
restarts RETRY-WITH-MAX-TOKENS and ACCEPT-TRUNCATED; with ACCEPT-TRUNCATED, TRANSLATE returns
TEXT with a second value, :TRUNCATED."))

(define-condition missing-provenance (praxeon-error)
  ((operation :initarg :operation :initform nil :reader missing-provenance-operation)
   (subject :initarg :subject :initform nil :reader missing-provenance-subject))
  (:report
   (lambda (c s)
     (format s "~@[~A ~]refused: an observation~@[ about ~A~] must say where it came from.~%~%"
             (missing-provenance-operation c) (missing-provenance-subject c))
     (format s "Observational memory is personal data held indefinitely, and a remembered claim that cannot be traced to a conversation and a turn cannot be CORRECTED -- a member disputing it has nothing to point at, and a persona repeating it has nothing to check (#150).~%")
     (format s "Pass :provenance (praxeon/memory:make-provenance conversation turn). It is required rather than defaulted because a fabricated source is worse than an absent one: it reads as a citation.")))
  (:documentation "Signalled when a write to memory carries no provenance."))

(define-condition embedding-dimension-mismatch (praxeon-error)
  ((provider :initarg :provider :initform nil :reader embedding-dimension-mismatch-provider)
   (expected :initarg :expected :reader embedding-dimension-mismatch-expected)
   (actual :initarg :actual :reader embedding-dimension-mismatch-actual)
   (source :initarg :source :initform nil :reader embedding-dimension-mismatch-source))
  (:report
   (lambda (c s)
     (format s "Embedding width is ~D where ~D was expected~@[ (~A)~]~@[, from ~A~].~%~%"
             (embedding-dimension-mismatch-actual c)
             (embedding-dimension-mismatch-expected c)
             (embedding-dimension-mismatch-source c)
             (embedding-dimension-mismatch-provider c))
     (format s "The dimension is a property of the DEPLOYMENT, not of the code (#150): a schema declaring 1536 has declared OpenAI's text-embedding-3-small, and pointing the same schema at a 768-wide model is a configuration error rather than a bad row.~%")
     (format s "Signalled here so the message names the misconfiguration. mnemosyne refuses the wrong width again at cast time, but that error names a column, which is a long way from the variable that caused it.")))
  (:documentation "Signalled when an embedding's width is not the width that was declared."))

(define-condition no-embedding-provider (praxeon-error)
  ((role :initarg :role :initform nil :reader no-embedding-provider-role))
  (:report
   (lambda (c s)
     (let ((role (no-embedding-provider-role c)))
       (format s "No embedding provider is configured~@[ for role ~A~].~%~%" role)
       (format s "Set ~@[PRAXEON_~:@(~A~)_EMBED_IMPL or ~]PRAXEON_EMBED_IMPL to the name of an embedding backend. There is no default embedding provider (#290). An app that can work without embeddings handles this condition and uses exact search instead." role))))
  (:documentation "Signalled by MAKE-EMBEDDING-PROVIDER-FROM-ENV when no variable names an
embedding backend. It is signalled before any request is made."))

(define-condition no-reranker (praxeon-error)
  ((role :initarg :role :initform nil :reader no-reranker-role))
  (:report
   (lambda (c s)
     (let ((role (no-reranker-role c)))
       (format s "No reranker is configured~@[ for role ~A~].~%~%" role)
       (format s "Set ~@[PRAXEON_~:@(~A~)_RERANK_IMPL or ~]PRAXEON_RERANK_IMPL to the name of a reranker backend, for example voyage. There is no default reranker (#316). An app that can search without one handles this condition and passes no reranker." role))))
  (:documentation "Signalled by MAKE-RERANKER-FROM-ENV when no variable names a reranker
backend. It is signalled before any request is made."))

(define-condition vector-extension-missing (praxeon-error)
  ((database :initarg :database :initform nil :reader vector-extension-missing-database))
  (:report
   (lambda (c s)
     (format s "The pgvector extension is not installed in database ~A.~%~%praxeon does not create it. On a managed Postgres the application's role usually has no CREATE privilege on its database, so the cluster administrator installs the extension once per database, as a role that has that privilege:~%  CREATE EXTENSION vector;~%Then start the application again (#138)."
             (or (vector-extension-missing-database c) "(unknown)"))))
  (:documentation "Signalled by a store's ENSURE-SCHEMA when the `vector' extension is absent
from the connected database. The store checks pg_extension and never runs CREATE EXTENSION."))

(define-condition missing-provider-key (praxeon-error)
  ((impl :initarg :impl :reader missing-provider-key-impl)
   (role :initarg :role :initform nil :reader missing-provider-key-role)
   (variables :initarg :variables :reader missing-provider-key-variables))
  (:report
   (lambda (c s)
     (format s "The ~A backend~@[ selected for role ~A~] has no API key. Set one of: ~{~A~^, ~}. A backend reads only the settings configured for it (#290): PRAXEON_LLM_API_KEY applies only to the backend PRAXEON_LLM_IMPL names, and an embedding backend never reads a chat key."
             (missing-provider-key-impl c) (missing-provider-key-role c)
             (missing-provider-key-variables c))))
  (:documentation "Signalled when a provider is built from the environment for a backend that
needs a key and none of the variables that apply to it is set. VARIABLES lists them, most
specific first."))

(defun value-shape (value)
  "What kind of value VALUE is and how long, for a message that is logged: never VALUE itself.
PRAXEON/LLM uses it for the UNKNOWN-TOOL-CHOICE detail (#727)."
  (typecase value
    (keyword (format nil "a keyword of ~D characters" (length (symbol-name value))))
    (symbol (format nil "a symbol of ~D characters" (length (symbol-name value))))
    (string (format nil "a string of ~D characters" (length value)))
    (list (let ((n (ignore-errors (list-length value))))
            (if n (format nil "a list of ~D elements" n) "a list that is not proper")))
    (t (format nil "a value of class ~A" (class-name (class-of value))))))

(define-condition tool-choice-unsupported (praxeon-error)
  ((provider :initarg :provider :initform nil :reader tool-choice-unsupported-provider)
   (requested :initarg :requested :initform nil :reader tool-choice-unsupported-requested))
  (:report
   (lambda (c s)
     (format s "~A cannot honour the tool choice it was given, ~A; read the value from TOOL-CHOICE-UNSUPPORTED-REQUESTED.~%~%This is signalled rather than falling back to :auto on purpose. A caller that forced a tool is about to treat the reply as a record; letting the model answer freely instead returns prose, and nothing downstream can tell the difference until it is stored."
             (or (tool-choice-unsupported-provider c) "This provider")
             (value-shape (tool-choice-unsupported-requested c)))))
  (:documentation "Signalled when a forced TOOL-CHOICE reaches a provider that cannot do it.

REQUESTED is the tool choice as given. The report says only what kind of value it was and its
length, because COMPLETE signals this inside the handler that logs a failed request at warn,
and a forced tool's name can come from a prompt (#727)."))
(define-condition image-part-invalid (praxeon-error)
  ((limit :initarg :limit :initform nil :reader image-part-invalid-limit))
  (:report
   (lambda (c s)
     (format s "An image part was refused: ~A~@[ (the limit is ~A)~]."
             (praxeon-error-detail c) (image-part-invalid-limit c))))
  (:documentation "Signalled by PRAXEON/LLM:IMAGE-PART for an image it will not carry: a size
over *MAX-IMAGE-PART-BYTES*, bytes that are not PNG, JPEG, GIF or WebP, a media type that does
not match the bytes, or a URL that is not https (#995). LIMIT names the limit that was passed.
The report never includes the image or the URL."))

(define-condition image-input-unsupported (praxeon-error)
  ((provider :initarg :provider :initform nil :reader image-input-unsupported-provider)
   (model :initarg :model :initform nil :reader image-input-unsupported-model))
  (:report
   (lambda (c s)
     (format s "~A~@[ with model ~A~] cannot take an image, and the request carries one: ~A. Nothing was sent.~%~%An image is refused here rather than dropped, because a model shown a request about a picture without the picture answers about something it never saw."
             (or (image-input-unsupported-provider c) "This provider")
             (image-input-unsupported-model c)
             (praxeon-error-detail c))))
  (:documentation "Signalled before a request is sent when its messages carry an image part and
the provider or model has no vision input (PRAXEON/LLM:SUPPORTS-IMAGE-INPUT-P), or the image is
in a place no provider takes one: the system prompt, or an assistant message (#995)."))

(define-condition parallel-child-failure (praxeon-error)
  ((failures :initarg :failures :initform nil :reader parallel-child-failure-failures)
   (completed :initarg :completed :initform nil :reader parallel-child-failure-completed))
  (:report (lambda (c stream)
             (format stream "~D of ~D children of a PARALLEL group failed (~{~A~^, ~}); the ~D that succeeded are merged and on the blackboard."
                     (length (parallel-child-failure-failures c))
                     (+ (length (parallel-child-failure-failures c))
                        (length (parallel-child-failure-completed c)))
                     (mapcar #'car (parallel-child-failure-failures c))
                     (length (parallel-child-failure-completed c)))))
  (:documentation "Signalled when one or more children of a PARALLEL group signalled.

FAILURES is an alist of (child-name . condition). COMPLETED names the children that
succeeded and whose outputs WERE merged into the blackboard before this was signalled.

BOTH SLOTS EXIST BECAUSE A FAN-OUT HAS PARTIAL OUTCOMES and the sequential implementation
had no way to express one: a `dolist' unwound on the first error, so children after it never
ran and children before it were discarded along with the accumulated writes. One provider
hiccup cost every sibling's work, and nothing said so. Concurrency makes the partial outcome
unavoidable and therefore reportable -- every child runs to completion, what succeeded is
merged, and this names what did not (pre-publication issue 418)."))

(define-condition budget-exceeded (praxeon-error)
  ((requested :initarg :requested :reader budget-exceeded-requested)
   (available :initarg :available :reader budget-exceeded-available))
  (:report (lambda (c stream)
             (format stream "Context budget exceeded: needed ~A, ~A available."
                     (budget-exceeded-requested c)
                     (budget-exceeded-available c))))
  (:documentation "Signalled when context assembly cannot fit within budget."))

;;; Restart invokers. Establish these around the application of a means so a
;;; handler can select recovery without unwinding the whole agent loop.

(defun retry-action (&optional condition)
  "Invoke the RETRY-ACTION restart, re-attempting the failed means."
  (let ((r (find-restart 'retry-action condition)))
    (when r (invoke-restart r))))

(defun substitute-result (value &optional condition)
  "Invoke SUBSTITUTE-RESULT, supplying VALUE in place of the means' result."
  (let ((r (find-restart 'substitute-result condition)))
    (when r (invoke-restart r value))))

(defun abandon-action (&optional condition)
  "Invoke ABANDON-ACTION, giving up on the current action."
  (let ((r (find-restart 'abandon-action condition)))
    (when r (invoke-restart r))))

;;; Restart invokers for a step cut off by the output limit (#326). RUN-TURN establishes these
;;; around OUTPUT-TRUNCATED. They act on the whole turn rather than on one means, which is why
;;; they are not the three above.

(defun retry-with-max-tokens (max-tokens &optional condition)
  "Invoke RETRY-WITH-MAX-TOKENS: ask the model again with MAX-TOKENS (a positive integer) as the
output limit. In RUN-TURN the limit holds for the step that was cut off and every later step of
the turn, and the retry counts against MAX-STEPS. In TRANSLATE and GENERATE-STRUCTURED it holds
for the rest of that call; a retry is not one of GENERATE-STRUCTURED's ATTEMPTS."
  (let ((r (find-restart 'retry-with-max-tokens condition)))
    (when r (invoke-restart r max-tokens))))

(defun accept-truncated (&optional condition)
  "Invoke ACCEPT-TRUNCATED: take the cut-off result. RUN-TURN ends the turn with the cut-off
text as its answer, and TRANSLATE and GENERATE-STRUCTURED return the cut-off result; each
returns it with a second value, :TRUNCATED."
  (let ((r (find-restart 'accept-truncated condition)))
    (when r (invoke-restart r))))

(defun abandon-turn (&optional condition)
  "Invoke ABANDON-TURN: end the turn with no answer. RUN-TURN returns NIL with a second value,
:ABANDONED."
  (let ((r (find-restart 'abandon-turn condition)))
    (when r (invoke-restart r))))
