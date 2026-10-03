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
  ;; MAX-TOKENS (#326): the output-token limit for each model call this agent makes. RUN-TURN's
  ;; :max-tokens overrides it. NIL, the default, means `llm:*default-max-tokens*' as it is when
  ;; a turn starts, rather than the value it had when the agent was made: an app that
  ;; binds that variable around RUN-TURN (the workaround #326 was filed with) keeps getting
  ;; its value until it moves the number here.
  (max-tokens nil)
  ;; TOOL RESULTS OUTSIDE THE PROMPT (#319), all NIL until OFFLOAD-TOOL-RESULTS sets them, so an
  ;; agent that has not asked keeps every result in its history as before. RESULT-STORE is a
  ;; PRAXEON/RESULTS:RESULT-STORE and CONVERSATION the id its results are kept under. A result of
  ;; more than OFFLOAD-THRESHOLD estimated tokens goes into the history as a stand-in. When the
  ;; messages a deliberation sends pass CLEAR-BUDGET estimated tokens, older results already in
  ;; the history are replaced by stand-ins in what is sent, oldest first, until it is at most
  ;; CLEAR-TARGET (half the budget when NIL); the last KEEP-RECENT results and those of the
  ;; means named in NEVER-CLEAR stay whole. RESULT-INDEX maps a tool call's id to what the
  ;; stand-in describes, and CLEARED holds the ids of the results replaced so far.
  (result-store nil)
  (conversation nil)
  (offload-threshold nil)
  (clear-budget nil)
  (clear-target nil)
  (keep-recent 3)
  (never-clear '() :type list)
  (result-index (make-hash-table :test #'equal))
  (cleared (make-hash-table :test #'equal))
  (history '() :type list))               ; list of praxeon/llm messages

(defvar *principal* nil
  "The user the current turn runs for, as the app identifies its users, or NIL (#527). RUN-TURN
binds it from its PRINCIPAL argument. A means that acts for a user reads it when it is called,
so one agent can serve several users without one user's call using another's credentials.")

;; Inheritable for the reason *OBSERVER* is: a thread that continues this turn acts for the
;; same user, and one that starts an independent lifetime must not (#158).
(aion/dynamic:register-inheritable '*principal*)

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

;;; --- tool results outside the prompt (#319) ---------------------------------
;;;
;;; A tool result can be large, and it stays in the prompt for every later step of the
;;; conversation. With OFFLOAD-TOOL-RESULTS an agent keeps each result in a result store, and
;;; the conversation carries a stand-in wherever the result itself would cost too much: at
;;; once, for a result over the offload threshold, and later, in a batch, for older results
;;; once the prompt passes the clearing budget. The agent reads back what it needs through the
;;; `read-result' means, which returns the stored text exactly.
;;;
;;; CLEARING HAPPENS IN BATCHES, AND ONLY IN WHAT IS SENT. The history stays the record, as for
;;; history trimming (ADR-0001): a result cleared from the prompt is still in AGENT-HISTORY for a
;;; client to show. The ids of the cleared results are kept on the agent, so the prompt sent at
;;; each later step has the same stand-ins in the same places, and the part of the prompt
;;; before the newest messages stays byte-identical from one step to the next, which is what a
;;; provider's prefix cache needs. It changes only when a new batch is cleared, and a batch takes
;;; the prompt well below the budget, to CLEAR-TARGET, so the next one is far away.

(defparameter *read-result-max-characters* 16000
  "The most characters one `read-result' call returns. A larger range is refused with the
number of characters it holds, so the agent asks for less; it is never cut, since what comes
back must be the stored text exactly.")

(defparameter *read-result-means* "read-result"
  "The name the result-reading means is registered under.")

(defparameter *stand-in-preview-lines* 5
  "How many first lines of a result its stand-in shows, within *STAND-IN-PREVIEW-CHARACTERS*.")

(defparameter *stand-in-preview-characters* 400
  "The most characters of a result its stand-in shows. Without it a result of one long line
would get a stand-in as large as itself, and clearing it would save nothing.")

(defun %clip (string n)
  (if (> (length string) n) (concatenate 'string (subseq string 0 n) "...") string))

(defun %arguments-text (arguments)
  (%clip (handler-case (if arguments (jzon:stringify arguments) "{}")
           (error () (princ-to-string arguments)))
         300))

(defun %result-entry (handle name arguments text)
  (list :handle handle :name name :arguments arguments
        :lines (res:line-count text) :characters (length text)
        :tokens (prompt:estimate-tokens text)
        :preview (%clip (or (res:lines-of text 1 *stand-in-preview-lines*) "")
                        *stand-in-preview-characters*)))

(defun %stand-in (entry how)
  "The text that takes a stored result's place in the conversation. HOW is :OFFLOADED for a
result kept out from the start, whose stand-in shows its first lines, since the model has not
seen it; or :CLEARED for one removed later, which the model has already read, so its stand-in
names it and says where it is, and nothing more. Every cleared result stays in the prompt as
one of these, so a short one is what lets a batch take the prompt well below the budget."
  (if (eq how :cleared)
      (format nil "[Earlier result of ~A ~A, cleared to save space; stored as ~A: ~D line~:P, ~D character~:P. Read it with ~A.]"
              (getf entry :name) (%clip (%arguments-text (getf entry :arguments)) 80)
              (getf entry :handle) (getf entry :lines) (getf entry :characters) *read-result-means*)
      (format nil "[Result of ~A ~A, kept outside the conversation as ~A: ~D line~:P, ~D character~:P, about ~D tokens. Call ~A with this handle to read a range of lines or characters, or the lines that contain a string. First lines:~%~A]"
              (getf entry :name) (%arguments-text (getf entry :arguments))
              (getf entry :handle) (getf entry :lines) (getf entry :characters)
              (getf entry :tokens) *read-result-means* (getf entry :preview))))

(defun %store-result (agent id name arguments text)
  "Keep TEXT in AGENT's result store when it has one, and return what the conversation gets:
TEXT itself, or its stand-in when TEXT is over the offload threshold."
  (let ((store (agent-result-store agent)))
    (if (or (null store) (equal name *read-result-means*))
        text
        (let* ((handle (res:put-result store (agent-conversation agent) name arguments text))
               (entry (%result-entry handle name arguments text))
               (threshold (agent-offload-threshold agent))
               (offloaded (and threshold (> (getf entry :tokens) threshold))))
          (setf (gethash id (agent-result-index agent)) (list* :offloaded offloaded entry))
          (evt:emit :result-stored :id id :name name :handle handle
                                   :tokens (getf entry :tokens) :offloaded offloaded)
          (if offloaded (%stand-in entry :offloaded) text)))))

(defun %map-tool-results (messages function)
  "MESSAGES with each tool-result part replaced by FUNCTION's value for it, or kept when that
is NIL. Messages and parts that do not change are the same objects."
  (mapcar (lambda (m)
            (let ((content (llm:content m)))
              (if (and (listp content)
                       (some (lambda (p) (eq (getf p :type) :tool-result)) content))
                  (let* ((changed nil)
                         (parts (mapcar (lambda (p)
                                          (let ((new (and (eq (getf p :type) :tool-result)
                                                          (funcall function p))))
                                            (if new (progn (setf changed t) new) p)))
                                        content)))
                    (if changed (llm:msg (llm:role m) parts) m))
                  m)))
          messages))

(defun %with-cleared (agent messages)
  "MESSAGES with the stand-in in place of every result AGENT has cleared."
  (if (zerop (hash-table-count (agent-cleared agent)))
      messages
      (%map-tool-results
       messages
       (lambda (part)
         (let ((id (getf part :tool-use-id)))
           (when (gethash id (agent-cleared agent))
             (llm:tool-result-part id (%stand-in (gethash id (agent-result-index agent)) :cleared)
                                   (getf part :is-error))))))))

(defun %clear-batch (agent messages)
  "When MESSAGES are over AGENT's clearing budget, clear the oldest results that may be cleared
until they are at most the clearing target, and return MESSAGES with every cleared result's
stand-in in place. Otherwise return MESSAGES unchanged."
  (let ((budget (agent-clear-budget agent)))
    (if (or (null budget) (<= (prompt:messages-tokens messages) budget))
        messages
        (let* ((target (or (agent-clear-target agent) (floor budget 2)))
               (index (agent-result-index agent))
               (stored (loop for m in messages
                             append (loop for p in (let ((c (llm:content m))) (and (listp c) c))
                                          when (and (eq (getf p :type) :tool-result)
                                                    (gethash (getf p :tool-use-id) index))
                                            collect p)))
               (recent (last stored (agent-keep-recent agent)))
               (tokens (prompt:messages-tokens messages))
               (count 0))
          (dolist (part stored)
            (when (<= tokens target) (return))
            (let* ((id (getf part :tool-use-id))
                   (entry (gethash id index)))
              (unless (or (member part recent :test #'eq)
                          (getf entry :offloaded)
                          (gethash id (agent-cleared agent))
                          (member (getf entry :name) (agent-never-clear agent) :test #'equal))
                (setf (gethash id (agent-cleared agent)) t)
                (incf count)
                (decf tokens (- (prompt:part-tokens part)
                                (prompt:estimate-tokens (%stand-in entry :cleared)))))))
          (let ((result (%with-cleared agent messages)))
            (when (plusp count)
              (evt:emit :results-cleared :count count
                                         :estimated-tokens (prompt:messages-tokens result)
                                         :budget budget :target target))
            result)))))

(defun %read-result-schema ()
  (let ((props (make-hash-table :test 'equal))
        (schema (make-hash-table :test 'equal)))
    (flet ((prop (name type description)
             (let ((h (make-hash-table :test 'equal)))
               (setf (gethash "type" h) type (gethash "description" h) description)
               (setf (gethash name props) h))))
      (prop "handle" "string" "The handle a stored result's stand-in names, for example res-0a1b2c3d4e5f6a7b.")
      (prop "first_line" "integer" "The first line to read, counted from 1.")
      (prop "last_line" "integer" "The last line to read, inclusive. Defaults to 50 lines from first_line.")
      (prop "start" "integer" "The first character to read, counted from 0, when reading characters instead of lines.")
      (prop "end" "integer" "The character after the last one to read.")
      (prop "search" "string" "Return the lines that contain this string, with their line numbers, instead of a range.")
      (prop "case_sensitive" "boolean" "Whether search distinguishes upper and lower case. Default false."))
    (setf (gethash "type" schema) "object"
          (gethash "properties" schema) props
          (gethash "required" schema) (vector "handle"))
    schema))

(defun %read-result (agent args)
  "The `read-result' means: part of a stored result of AGENT's conversation, exactly as stored."
  (flet ((arg (name) (and (hash-table-p args) (gethash name args)))
         (too-long (what n)
           (format nil "~A holds ~D characters, more than ~A returns at once (~D). Ask for a smaller range."
                   what n *read-result-means* *read-result-max-characters*)))
    (let* ((handle (arg "handle"))
           (record (and (stringp handle)
                        (res:find-result (agent-result-store agent) (agent-conversation agent)
                                         handle))))
      (if (null record)
          (format nil "No stored result has the handle ~S in this conversation." handle)
          (let ((text (res:stored-result-text record))
                (search (arg "search")))
            (cond
              ((and (stringp search) (plusp (length search)))
               (multiple-value-bind (found total)
                   (res:search-lines text search
                                     :case-sensitive (eq (arg "case_sensitive") t))
                 (format nil "~D line~:P of ~A contain~:[s~;~] ~S~:[.~;; the first ~D:~]~{~%~A~}"
                         total handle (/= total 1) search (plusp total) (length found)
                         (mapcar (lambda (e) (format nil "line ~D: ~A" (car e) (cdr e))) found))))
              ((integerp (arg "start"))
               (let* ((start (arg "start"))
                      (end (if (integerp (arg "end")) (arg "end") (+ start 4000)))
                      (part (res:characters-of text start (max start end))))
                 (if (> (length part) *read-result-max-characters*)
                     (too-long (format nil "Characters ~D to ~D" start end) (length part))
                     (format nil "Characters ~D to ~D of ~D in ~A, exactly as stored:~%~A"
                             (min start (length text)) (+ (min start (length text)) (length part))
                             (length text) handle part))))
              (t
               (let* ((first (if (integerp (arg "first_line")) (max 1 (arg "first_line")) 1))
                      (last (if (integerp (arg "last_line"))
                                (max first (arg "last_line"))
                                (+ first 49))))
                 (multiple-value-bind (part range) (res:lines-of text first last)
                   (cond ((null part)
                          (format nil "~A has ~D line~:P; line ~D is past the end."
                                  handle (res:line-count text) first))
                         ((> (length part) *read-result-max-characters*)
                          (too-long (format nil "Lines ~D to ~D" first last) (length part)))
                         (t (format nil "Lines ~D to ~D of ~D in ~A, exactly as stored:~%~A"
                                    (first range) (second range) (res:line-count text)
                                    handle part))))))))))))

(defun offload-tool-results (agent store &key conversation (threshold 2000) clear-budget
                                             clear-target (keep-recent 3) never-clear)
  "Keep AGENT's tool results in STORE, a PRAXEON/RESULTS:RESULT-STORE, and let it read them back
(#319). Returns AGENT.

CONVERSATION is the id the results are kept and erased under (FORGET-AGENT-RESULTS); an app
that keeps conversations passes its own, and NIL makes a new one. A result of more than
THRESHOLD estimated tokens is kept out of the history from the start, which gets a stand-in
naming the tool, its arguments, the result's size, its first lines and a handle. CLEAR-BUDGET,
when set, clears older results from what is sent once the messages pass it, down to
CLEAR-TARGET (half the budget when NIL), keeping the last KEEP-RECENT results and those of the
means named in NEVER-CLEAR whole; see the commentary above REQUEST-MESSAGES.

Registers the means `read-result', which returns part of a stored result by its handle: a
range of lines, a range of characters, or the lines that contain a string, exactly as stored.

Nothing here is a default: every setting is the app's until a measurement with a real model
shows which values keep the task succeeding (#319, and the maintainer's rule on #316)."
  (check-type store res:result-store)
  (unless (or (null threshold) (typep threshold '(integer 1)))
    (error "praxeon/actor: :threshold must be a positive integer or NIL, not ~S" threshold))
  (unless (or (null clear-budget) (typep clear-budget '(integer 1)))
    (error "praxeon/actor: :clear-budget must be a positive integer or NIL, not ~S" clear-budget))
  (unless (typep keep-recent '(integer 0))
    (error "praxeon/actor: :keep-recent must be a non-negative integer, not ~S" keep-recent))
  (setf (agent-result-store agent) store
        (agent-conversation agent) (or conversation (format nil "conv-~A" (res:new-handle)))
        (agent-offload-threshold agent) threshold
        (agent-clear-budget agent) clear-budget
        (agent-clear-target agent) clear-target
        (agent-keep-recent agent) keep-recent
        (agent-never-clear agent) never-clear)
  (register-means agent *read-result-means*
                  "Read part of a tool result that is kept outside the conversation, by the handle its stand-in names: a range of lines, a range of characters, or the lines that contain a string. What it returns is the stored text exactly."
                  (lambda (args) (%read-result agent args))
                  :schema (%read-result-schema))
  agent)

(defun forget-agent-results (agent)
  "Erase every result AGENT's conversation has in its store (#150), and forget which were
cleared. Returns how many were erased. A stand-in that names one of them then reads nothing."
  (let ((store (agent-result-store agent)))
    (clrhash (agent-result-index agent))
    (clrhash (agent-cleared agent))
    (if store (res:forget-conversation-results store (agent-conversation agent)) 0)))

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
  (let* ((history (%clear-batch agent (%with-cleared agent (agent-history agent))))
         (trimmed (prompt:trim-history history (agent-history-budget agent)))
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

(defun %output-limit (agent max-tokens)
  "The output-token limit for a model call AGENT makes: MAX-TOKENS when it is given, else the
agent's MAX-TOKENS slot, else `llm:*default-max-tokens*' as it is now (#326)."
  (or max-tokens (agent-max-tokens agent) llm:*default-max-tokens*))

(defun deliberate (agent &key permit max-tokens)
  "Ask the provider for the agent's next move given its current history,
advertising the means PERMIT allows as tools. Returns (values COMPLETION
ESTIMATED-INPUT-TOKENS). Signals DELIBERATION-FAILURE when no provider is configured.

MAX-TOKENS is the output-token limit for this call. When it is NIL the agent's MAX-TOKENS slot
applies, and when that is NIL too, `llm:*default-max-tokens*' (#326). Before #326 no limit was
passed, so every call took the provider's default, which is that variable, and an app could
change the limit only by rebinding it.

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
                          :tools (agent-tool-specs agent :permit permit)
                          :max-tokens (%output-limit agent max-tokens))
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

(defun %apply-call (agent name args permit)
  "Apply the means NAME to ARGS through ACT. Return its result as a string, and a second value
that is true when the means reported an error for the model to see (#527).

A means reports such an error by signalling CND:TOOL-ERROR-RESULT. The handler here takes only
that case, and gives the model the condition's text as an error result. Every other failure
of a means is declined, so it reaches the app's handlers with ACT's restarts still in place,
and ends the turn when nothing handles it, as before."
  (block call
    (handler-bind ((cnd:means-failure
                     (lambda (failure)
                       (let ((cause (cnd:means-failure-cause failure)))
                         (when (typep cause 'cnd:tool-error-result)
                           (return-from call
                             (values (cnd:tool-error-result-text cause) t)))))))
      (values (%result-string (act agent name args :permit permit)) nil))))

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
                (multiple-value-bind (result error-p) (%apply-call agent name args permit)
                  (if error-p
                      (evt:emit :tool-result :id id :name name :content result :is-error t)
                      (evt:emit :tool-result :id id :name name :content result))
                  ;; What the history carries: the result, or its stand-in when it is kept
                  ;; outside the conversation (#319).
                  (llm:tool-result-part id (%store-result agent id name args result) error-p))))
            calls)))

(defun %append-history (agent &rest messages)
  (setf (agent-history agent) (append (agent-history agent) messages)))

(defun run-turn (agent user-input &key (max-steps 8) permit max-tokens principal)
  "Run one full turn: record USER-INPUT, then deliberate and act until the model
replies with no further tool call. Returns the model's final text. MAX-STEPS
bounds the deliberate/act cycle so a misbehaving loop stays finite.

MAX-TOKENS is the output-token limit for each model call of the turn. It overrides the agent's
MAX-TOKENS slot, and with neither, `llm:*default-max-tokens*' applies (#326).

A STEP CUT OFF BY THE OUTPUT LIMIT IS NOT USED (#326). When a completion stops with the stop
reason :MAX-TOKENS, the model had not finished: its text ends mid-sentence, and a tool call in
it can be missing arguments. So RUN-TURN does not run the step's tool calls, does not return its
text as the answer, and adds nothing from the step to the history. It emits a :TRUNCATED event
and signals OUTPUT-TRUNCATED, an error, inside three restarts. The functions of the same names in
praxeon/conditions invoke them:

  RETRY-WITH-MAX-TOKENS n  ask the model again with the limit N, for that step and every later
                           step of the turn. The retry is another step, so it counts against
                           MAX-STEPS, and a handler that always retries still stops.
  ACCEPT-TRUNCATED         end the turn with the cut-off text. RUN-TURN returns it with a second
                           value, :TRUNCATED, and records the text in the history without the
                           step's tool calls, which never ran.
  ABANDON-TURN             end the turn with no answer. RUN-TURN returns NIL and :ABANDONED.

With no handler, the error ends the turn at the first cut-off step. Before #326 a cut-off reply
was returned as though it were complete, and the tool calls parsed from a cut-off step were run
and the model asked again, until MAX-STEPS ran out.

PERMIT IS THE CALLER'S AUTHORITY and it travels to both halves of the loop -- the tool table
the model is shown (DELIBERATE) and the check at the moment of use (ACT). Without it, a means
that names a capability is invisible and uninvocable, which is the fail-closed rule of #90
working as designed.

IT WAS MISSING UNTIL pre-publication issue 400, and the consequence was not a missing convenience: `run-turn' is the
framework's main entry point, so EVERY capability-bearing means was unreachable through it. An
app could register one, see it refused as `no such means registered\', and have no way to pass
the authority that would permit it short of driving DELIBERATE and ACT by hand. Found by writing
ADR-0002's own example and watching the turn loop refuse the means the ADR recommends -- the
pattern was unexecutable through the path every reader would use.

PRINCIPAL is whatever the app uses to tell its users apart, and is the user this turn runs for
(#527). It is bound as *PRINCIPAL* for the turn, so a means that acts for a user, such as an
MCP tool that needs that user's token, reads it at call time. NIL keeps the principal of an
enclosing turn, which is how a delegated sub-turn runs for the same user; with neither, a
means that needs a principal refuses the call."
  (let ((*principal* (or principal *principal*)))
    (%run-turn agent user-input max-steps permit max-tokens)))

(defun %run-turn (agent user-input max-steps permit max-tokens)
  "RUN-TURN's steps, with *PRINCIPAL* already bound."
  (%append-history agent (llm:msg "user" user-input))
  (let ((limit (%output-limit agent max-tokens)))
    (dotimes (step max-steps
                   (error 'cnd:deliberation-failure
                          :detail (format nil "no final answer within ~A steps"
                                          max-steps)))
      (evt:emit :deliberating :step step)
      (multiple-value-bind (completion estimate)
          (deliberate agent :permit permit :max-tokens limit)
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
        (let ((text (llm:completion-text completion))
              (calls (llm:completion-tool-calls completion)))
          (cond
            ((eq (llm:completion-stop-reason completion) :max-tokens)
             ;; Nothing from the cut-off step goes into the history unless ACCEPT-TRUNCATED
             ;; puts its text there. A tool-use part with no tool result after it makes the
             ;; next request invalid, and a retry has to ask again from the history as it was
             ;; before this step.
             (evt:emit :truncated :step step :max-tokens limit
                                  :tool-calls (mapcar #'llm:tool-call-name calls))
             (restart-case (error 'cnd:output-truncated
                                  :step step :max-tokens limit :text text :tool-calls calls)
               (cnd:retry-with-max-tokens (new-limit)
                 :report "Ask the model again with a larger output limit."
                 :interactive (lambda ()
                                (format *query-io* "~&New output limit, in tokens: ")
                                (finish-output *query-io*)
                                (list (parse-integer (read-line *query-io*))))
                 (check-type new-limit (integer 1))
                 ;; The loop goes on to the next step, which sends the same history with the
                 ;; new limit.
                 (setf limit new-limit))
               (cnd:accept-truncated ()
                 :report "End the turn with the cut-off text, marked as truncated."
                 (when (plusp (length text))
                   (%append-history agent (llm:msg "assistant" (list (llm:text-part text)))))
                 (evt:emit :answer :text text :truncated t)
                 (return (values text :truncated)))
               (cnd:abandon-turn ()
                 :report "End the turn with no answer."
                 (return (values nil :abandoned)))))
            (t
             (%append-history agent (%assistant-message completion))
             (if (null calls)
                 (progn
                   (evt:emit :answer :text text)
                   (return text))
                 (%append-history agent (%tool-results-message agent calls
                                                               :permit permit))))))))))

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

(defun run-turn-through (agent input &key (locale "en") chain (max-steps 8) permit
                                          max-tokens principal)
  "Run one turn for AGENT through CHAIN, returning the final TURN (not a string).

CHAIN is a list of stages built with PRAXEON/TURN's ENTER-STAGE / LEAVE-STAGE /
GUARD-STAGE; the default is no stages, which is exactly RUN-TURN with a value wrapped
around it. The model call is the effect at the edge, so a guard that halts on the way in
means it never happens.

Returns the turn so the caller can distinguish an answer from a refusal -- ask
TURN:TURN-HALTED, and read TURN:TURN-NOTE for the reason. Callers wanting only the text
can take TURN:TURN-REPLY.

MAX-STEPS, PERMIT, MAX-TOKENS and PRINCIPAL are passed to RUN-TURN. When a handler ends the turn through
a restart of OUTPUT-TRUNCATED (#326), the second value is RUN-TURN's: :TRUNCATED after
ACCEPT-TRUNCATED, when the effect's reply is the cut-off text, and :ABANDONED after
ABANDON-TURN, when the effect's reply is empty. It is NIL otherwise.

The leave stages run after the effect in every case, so the final reply is what they made of the
effect's reply. A guardrail that adds a note to the reply adds it to an abandoned turn's empty
reply too, and the turn is returned with that note and :ABANDONED. The second value says how the
model's part of the turn ended, not what the final reply contains."
  (let ((outcome nil))
    (values
     (turn:run-chain
      ;; Coalton checks that CHAIN is a list, not what is in it (#110).
      (boundary:check-elements chain 'aion/interceptor:interceptor
                               :function 'turn:run-chain :argument 'chain)
      (lambda (tn)
        ;; The one impure pivot. It reads the turn's INPUT rather than the argument, so an
        ;; enter stage that rewrote the input (translation, redaction, a system preamble) is
        ;; what the model actually sees.
        (multiple-value-bind (reply ended)
            (run-turn agent (turn:turn-input tn)
                      :max-steps max-steps :permit permit :max-tokens max-tokens
                      :principal principal)
          (setf outcome ended)
          ;; TURN-REPLY is a String, and an abandoned turn has no text.
          (turn:with-reply tn (or reply ""))))
      (turn:make-turn input locale))
     outcome)))
