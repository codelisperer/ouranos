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
  (fn nil)
  ;; SOURCE: NIL, or a plist naming where the means comes from, such as (:connection "docs"
  ;; :tool "search") for an MCP tool (#527). It travels on the :TOOL-CALL and :TOOL-RESULT
  ;; events, so a usage ledger can attribute each call.
  (source nil)
  ;; CONFIRM (#531): NIL runs the means as usual. T holds every call until the user decides.
  ;; A function of the arguments holds the call too, and returns an estimate plist of what the
  ;; call will cost, such as (:credits 40), or NIL. See hold.lisp.
  (confirm nil)
  ;; #827. UNTRUSTED: the means brings content from outside the conversation into it (a web
  ;; page, search results), so a call the model decides after it ran may have been steered by
  ;; that content. REQUIRES-USER-INTENT: the means spends, writes or sends for the user, so it
  ;; is refused in a turn once untrusted content has entered. ALLOW: NIL, or a function of the
  ;; arguments and the agent that must return true for a call to run. MAX-PER-TURN: NIL, or
  ;; how many calls may run in one turn. See %GUARD-REFUSAL in hold.lisp.
  (untrusted nil)
  (requires-user-intent nil)
  (allow nil)
  (max-per-turn nil))

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
  ;; #827: the current turn's TURN-GUARD, and the user messages that did not come from the
  ;; user (every task a coordinating agent delegated), which USER-TEXTS leaves out.
  ;; TAINT-SCOPE says how long untrusted content keeps a turn untrusted. :TURN (the default):
  ;; until the user's next message. :CONVERSATION: while the history sent to the model still
  ;; holds a call whose result may be untrusted (the whole history, whether or not a budget
  ;; trims what is sent), or the recorded CONVERSATION-TAINT is :UNTRUSTED or :DELEGATED
  ;; (#948), so a later turn starts untrusted too.
  (guard nil)
  (untrusted-inputs '() :type list)
  ;; The ids of the calls whose result was untrusted when it ran, by the means's registration or
  ;; because the call marked its turn untrusted, such as a delegated agent that read a page or was
  ;; given an untrusted memory item (#906's review). %UNTRUSTED-CALL-P reads it, so a judgement
  ;; made later from the history, such as an observer's, sees what was decided at run time.
  (untrusted-calls (make-hash-table :test #'equal))
  ;; A THREAD-MEMORY, or NIL (#317, step C): with one, the thread's observations go into the
  ;; prompt in place of the messages they were distilled from, once enough has been observed.
  (thread-memory nil)
  (taint-scope :turn)
  ;; #983: PRIVATE keeps the agent's content out of every log line and out of events, so an app
  ;; whose agent works over content it may not keep, such as a writer's manuscript, can rely on
  ;; that. RETAIN-CONTENT lets events carry content for a private agent again, for an app that
  ;; shows a trace and means to; logs stay without it either way. See %WITH-AGENT-PRIVACY.
  (private nil)
  (retain-content nil)
  ;; #948: whether untrusted content has entered this conversation, recorded as it happens, so
  ;; :CONVERSATION works for an app that rebuilds the history from text with no tool calls in
  ;; it. :UNTRUSTED when the agent read untrusted content; :DELEGATED when the only such
  ;; content is a task a coordinating agent gave it; :CLEAN when neither; NIL when not
  ;; recorded. The app stores it beside its transcript and passes it to MAKE-AGENT as
  ;; :CONVERSATION-TAINT. Setting it to :CLEAN starts over only when the history no longer
  ;; holds the untrusted calls either, since :CONVERSATION finds those in the history as well.
  ;; See %CONVERSATION-TAINTED-P.
  (conversation-taint nil)
  (history '() :type list))               ; list of praxeon/llm messages

(defvar *principal* nil
  "The user the current turn runs for, as the app identifies its users, or NIL (#527). RUN-TURN
binds it from its PRINCIPAL argument. A means that acts for a user reads it when it is called,
so each call uses that user's credentials. It does not separate conversations: an agent has one
history, from which every request is built, so each user needs an agent, or a history, of their own.")

;; Inheritable for the reason *OBSERVER* is: a thread that continues this turn acts for the
;; same user, and one that starts an independent lifetime must not (#158).
(aion/dynamic:register-inheritable '*principal*)

(defvar *on-hold* nil
  "What the current turn does when the model calls a means registered with :CONFIRM (#531): NIL,
a function, or :HOLD. RUN-TURN binds it from its ON-HOLD argument; see there.")

(defvar *hold-allowed* nil
  "True in a turn whose caller gave ON-HOLD, false in a delegated sub-turn that inherited it. A
call is held only where it is true, because a sub-agent's hold cannot end the coordinator's
turn (#531).")

;; Inheritable for the reason *PRINCIPAL* is: a thread that continues this turn acts under the
;; same policy (#158).
(aion/dynamic:register-inheritable '*on-hold*)
(aion/dynamic:register-inheritable '*hold-allowed*)

(defun register-means (agent name description fn &key schema capability source confirm
                                                       untrusted
                                                       (requires-user-intent nil requires-user-intent-p)
                                                       allow max-per-turn)
  "Register a means under NAME: a human DESCRIPTION, the FN performing it (a
function of one argument -- the tool arguments -- returning a string), an
optional argument SCHEMA (a jzon-serializable JSON-schema value), and an optional
CAPABILITY string a caller must hold to see or use it (#90). SOURCE is NIL or a plist that
names where the means comes from; the :TOOL-CALL and :TOOL-RESULT events carry it (#527).
CONFIRM is NIL, T or a function of the arguments returning an estimate plist: a means with one
is held until the user decides (#531, see RUN-TURN's :ON-HOLD).

The rest guard a turn against instructions written into content the agent reads (#827):

  UNTRUSTED             true for a means whose result comes from outside the conversation,
                        such as a web page or search results. Once one has run in a turn,
                        the turn counts as having read untrusted content.
  REQUIRES-USER-INTENT  true for a means that spends, writes or sends for the user. A call
                        the model makes after untrusted content entered the turn is refused,
                        as not run, for the rest of the turn. It defaults to true when
                        CONFIRM is given, because a means held for the user's confirmation is
                        one that spends or writes, and an app that forgets this key must not
                        leave a page able to ask for it. Pass NIL to have such a means held
                        for confirmation after untrusted content instead of refused.
  ALLOW                NIL, or a function of the call's arguments and the agent. A call runs
                        only when it returns true; otherwise, or when it signals, the call is
                        refused as not run.
  MAX-PER-TURN          NIL, or a positive integer: how many calls of this means may run in
                        one turn. Later calls are refused as not run.

Returns NAME."
  (unless (or (null allow) (functionp allow))
    (error "REGISTER-MEANS's :ALLOW must be NIL or a function of the arguments and the agent, not ~S." allow))
  (unless (or (null max-per-turn) (and (integerp max-per-turn) (plusp max-per-turn)))
    (error "REGISTER-MEANS's :MAX-PER-TURN must be NIL or a positive integer, not ~S." max-per-turn))
  (setf (gethash name (agent-means agent))
        (make-means-entry :name name :description description
                          :schema schema :capability capability :fn fn :source source
                          :confirm confirm :untrusted (and untrusted t)
                          :requires-user-intent (if requires-user-intent-p
                                                    (and requires-user-intent t)
                                                    (and confirm t))
                          :allow allow :max-per-turn max-per-turn))
  name)

;;; --- untrusted content in a turn (#827) --------------------------------------------------
;;; A turn's guard records whether untrusted content has entered the turn, how many calls of
;;; each means have run, and the URLs this turn's searches returned before any untrusted
;;; content entered. It is kept on the agent and keyed by the turn's user message, so a held
;;; turn continued later keeps it. When the key does not match (a held turn continued on an
;;; agent rebuilt from its history), the guard is rebuilt from the history in the safe
;;; direction: every reader call in the turn counts as having run, and no URL is allowed.

(defstruct (turn-guard (:constructor %make-turn-guard (key &optional untrusted agent)))
  key
  ;; NIL, T when the turn read untrusted content, or :DELEGATED when its only untrusted content
  ;; is a delegated task earlier in a :CONVERSATION (#948). Either true value makes the turn
  ;; untrusted; only T is passed on to a coordinator (REGISTER-AGENT-AS-MEANS).
  (untrusted nil)
  ;; The agent whose turn this is, so %TAINT-GUARD can record the conversation's taint (#948).
  (agent nil)
  (counts (make-hash-table :test #'equal))
  (urls '() :type list))

(defun %taint-guard (guard)
  "Mark GUARD's turn untrusted, and record that untrusted content has entered its agent's
conversation (#948). Every place that makes a turn untrusted calls this."
  (setf (turn-guard-untrusted guard) t)
  (when (turn-guard-agent guard)
    (setf (agent-conversation-taint (turn-guard-agent guard)) :untrusted))
  guard)

(defun %taint-guard-by-delegation (guard)
  "Mark GUARD's turn untrusted because a delegated task is earlier in its conversation, unless
it already read untrusted content (#948). Records nothing: the agent's taint says so already."
  (unless (eq (turn-guard-untrusted guard) t)
    (setf (turn-guard-untrusted guard) :delegated))
  guard)

(defun %taint-guard-from (guard taint)
  "Taint GUARD as TAINT, a value of %HISTORY-UNTRUSTED-P or *DECIDED-AFTER-UNTRUSTED*: T for
read content, :DELEGATED for a delegated task, NIL for nothing."
  (case taint
    ((nil))
    (:delegated (%taint-guard-by-delegation guard))
    (t (%taint-guard guard))))

(defvar *current-guard* nil
  "The guard of the turn whose call is running, or NIL outside a call.")
(defvar *call-taint* nil
  "A box, (NIL) or (T), for the call that is running: MARK-UNTRUSTED sets it, so the call's
result is recorded as untrusted (AGENT-UNTRUSTED-CALLS). NIL outside a call.")
(defvar *decided-after-untrusted* nil
  "True while a call runs that the model decided after untrusted content entered its turn: the
turn guard's UNTRUSTED value, T or :DELEGATED. A
sub-turn started inside such a call, such as a delegated agent's, starts with untrusted
content already present, and its task is not counted as the user's text.")
(defparameter *read-result-means* "read-result"
  "The name the result-reading means is registered under.")

(defparameter *read-observed-messages-means* "read-observed-messages"
  "The name of the means ATTACH-THREAD-MEMORY registers: it returns the messages an observation
was distilled from.")


(defvar *delegated* nil
  "True while REGISTER-AGENT-AS-MEANS runs a sub-agent's turn: the task that starts it was
written by the coordinating model, not the user, so USER-TEXTS never counts it.")
(defvar *outer-user-texts* '()
  "While a delegated turn runs, the coordinating agent's USER-TEXTS, which USER-TEXTS of the
sub-agent includes, so the sub-agent may open what the user asked the coordinator for.")
(aion/dynamic:register-inheritable '*current-guard*)
(aion/dynamic:register-inheritable '*decided-after-untrusted*)
(aion/dynamic:register-inheritable '*delegated*)
(aion/dynamic:register-inheritable '*outer-user-texts*)

(defun %user-message-p (message)
  "True for a message the user wrote: role user, content a string or text parts, no tool
results."
  (and (equal "user" (getf message :role))
       (let ((content (getf message :content)))
         (or (stringp content)
             (and (consp content)
                  (notany (lambda (p) (eq :tool-result (getf p :type))) content))))))

(defun %message-text (message)
  (let ((content (getf message :content)))
    (if (stringp content)
        content
        (format nil "~{~A~^~%~}"
                (loop for p in content
                      when (and (eq :text (getf p :type)) (stringp (getf p :text)))
                        collect (getf p :text))))))

(defun user-texts (agent)
  "The text of every message the user wrote in AGENT's history, oldest first. Tool results
are left out, and so is every task a coordinating agent delegated to AGENT, because a model
wrote it. While AGENT runs a delegated turn, the coordinator's own USER-TEXTS follow. An :ALLOW
predicate uses this to tell what the user asked for from what a page, a tool or a model said."
  (append (loop for m in (agent-history agent)
                when (and (%user-message-p m)
                          (not (member m (agent-untrusted-inputs agent) :test #'eq)))
                  collect (%message-text m))
          *outer-user-texts*))

(defun %current-turn-messages (agent)
  "The last user-written message in AGENT's history, and the messages after it."
  (let* ((history (agent-history agent))
         (start (position-if #'%user-message-p history :from-end t)))
    (if start (nthcdr start history) '())))

(defun %untrusted-call-p (agent part)
  "True when PART, a :TOOL-USE part in AGENT's history, called a means whose result may be
untrusted: one registered :UNTRUSTED, READ-RESULT, which can return any stored result, one no
longer registered, whose result cannot be judged, or one recorded as untrusted when it ran
(AGENT-UNTRUSTED-CALLS), such as a delegated agent whose turn read untrusted content."
  (let ((entry (gethash (getf part :name) (agent-means agent))))
    (or (null entry)
        (means-entry-untrusted entry)
        (equal (getf part :name) *read-result-means*)
        (and (equal (getf part :name) *read-observed-messages-means*)
             (%observed-messages-untrusted-p agent (let ((input (getf part :input)))
                                                     (and (hash-table-p input) (gethash "id" input)))))
        (and (getf part :id) (gethash (getf part :id) (agent-untrusted-calls agent)) t))))

(defun %tool-uses (messages)
  "The :TOOL-USE parts of the assistant messages in MESSAGES, oldest first."
  (loop for m in messages
        for content = (getf m :content)
        when (and (equal "assistant" (getf m :role)) (listp content))
          append (remove :tool-use content :key (lambda (p) (getf p :type)) :test-not #'eq)))

(defun %rebuild-guard (agent key messages)
  (let ((guard (%make-turn-guard key nil agent)))
    (%taint-guard-from guard (%history-untrusted-p agent))
    (dolist (p (%tool-uses (rest messages)))
      (when (gethash (getf p :name) (agent-means agent))
        (incf (gethash (getf p :name) (turn-guard-counts guard) 0)))
      (when (%untrusted-call-p agent p)
        (%taint-guard guard)))
    guard))

(define-condition conversation-taint-unrecorded (warning)
  ((agent :initarg :agent :reader conversation-taint-unrecorded-agent))
  (:report (lambda (c stream)
             (let ((agent (conversation-taint-unrecorded-agent c)))
               (format stream (concatenate
                               'string
                               "praxeon/actor: agent ~S (conversation ~S) has :taint-scope "
                               ":conversation and a history with earlier turns but no tool calls, "
                               "and its conversation-taint was not recorded, so whether untrusted "
                               "content entered the conversation cannot be told. The turn is "
                               "treated as untrusted. To fix it, store (agent-conversation-taint "
                               "agent) beside the transcript after each turn, and pass it to "
                               "make-agent as :conversation-taint when the agent is rebuilt.")
                       (agent-name agent) (agent-conversation agent)))))
  (:documentation "Signalled, as a warning, when an agent under :TAINT-SCOPE :CONVERSATION was
given a history whose earlier turns hold no tool calls, such as one rebuilt from a text
transcript, and no recorded CONVERSATION-TAINT (#948). The turn is treated as untrusted
whatever a handler does: muffling the warning does not make the turn trusted."))

(defun %check-conversation-taint (agent)
  (unless (member (agent-conversation-taint agent) '(nil :clean :delegated :untrusted))
    (error (concatenate 'string "praxeon/actor: :conversation-taint must be :untrusted, "
                        ":delegated, :clean or nil, not ~S")
           (agent-conversation-taint agent))))

(defun %conversation-tainted-p (agent earlier)
  "Under :CONVERSATION, whether untrusted content entered AGENT's conversation before the
current turn, whose earlier messages are EARLIER. T when the recorded CONVERSATION-TAINT is
:UNTRUSTED, or EARLIER holds a call whose result may be untrusted. :DELEGATED when the only
such content is a task a coordinating agent gave it (recorded :DELEGATED). When neither can tell,
because EARLIER holds turns but no tool calls and nothing was recorded, warns
CONVERSATION-TAINT-UNRECORDED, logs it, records :UNTRUSTED and returns true: the safe direction.
When nothing was recorded and EARLIER can be judged, records what it shows, so the app has a
value to store."
  (let* ((uses (%tool-uses earlier))
         (scanned (some (lambda (p) (%untrusted-call-p agent p)) uses)))
    (case (agent-conversation-taint agent)
      (:untrusted t)
      (:delegated (if scanned t :delegated))
      (:clean (and scanned t))
      (t (cond ((or uses (null earlier))
                (setf (agent-conversation-taint agent) (if scanned :untrusted :clean))
                (and scanned t))
               (t
                ;; Recorded before the warning, so the warning and the log line come once per
                ;; agent, and a handler that unwinds still leaves the conversation untrusted.
                (setf (agent-conversation-taint agent) :untrusted)
                (log:warn "praxeon/actor: conversation taint not recorded; treating it as untrusted"
                          :agent (agent-name agent) :conversation (agent-conversation agent)
                          :earlier-messages (length earlier))
                (warn 'conversation-taint-unrecorded :agent agent)
                t))))))

(defun %history-untrusted-p (agent &optional (before (first (%current-turn-messages agent))))
  "True when AGENT's taint scope is :CONVERSATION and untrusted content entered its conversation
before the message BEFORE: its history before BEFORE holds a call whose result may be untrusted,
or its recorded CONVERSATION-TAINT says so (#948). T or :DELEGATED, as %CONVERSATION-TAINTED-P
returns. Signals when the taint scope or the recorded taint is not a known value."
  (let ((scope (agent-taint-scope agent)))
    (unless (member scope '(:turn :conversation))
      (error "praxeon/actor: :taint-scope must be :turn or :conversation, not ~S" scope))
    (%check-conversation-taint agent)
    (and (eq scope :conversation)
         (%conversation-tainted-p agent (ldiff (agent-history agent)
                                               (member before (agent-history agent)
                                                       :test #'eq))))))

(defun untrusted-window-predicate (agent)
  "A function of a list of messages from AGENT's history, true when they hold content from
outside the conversation: a call to a means whose result may be untrusted (%UNTRUSTED-CALL-P),
or a user message a coordinator delegated rather than the user wrote; and, under the
:CONVERSATION taint scope, any untrusted call earlier in AGENT's history. A call counts as
untrusted by its means's registration or by what it did when it ran (AGENT-UNTRUSTED-CALLS). What
an app passes as a PRAXEON/OBSERVE observer's :UNTRUSTED-P, so a window's observations are marked
as AGENT would judge the window (#317's taint ruling).

AN OBSERVER OF A SUB-AGENT needs this predicate, built from the sub-agent: the observer's default
looks only for tool calls, and a delegated task message is the coordinating model's text, not
the user's, so the default takes it as trusted."
  (lambda (messages)
    (or (some (lambda (p) (%untrusted-call-p agent p)) (%tool-uses messages))
        (some (lambda (m) (member m (agent-untrusted-inputs agent) :test #'eq)) messages)
        ;; Under :CONVERSATION, untrusted content earlier in the history keeps every later turn
        ;; untrusted, so it keeps every later window untrusted too (#906's review).
        ;; The recorded taint counts too (#948), because a history rebuilt from text has no calls
        ;; to find. It does not say where in the history the content entered, so it marks every
        ;; window, the earlier ones included.
        (and (eq (agent-taint-scope agent) :conversation)
             (or (member (agent-conversation-taint agent) '(:untrusted :delegated))
                 (let ((at (member (first messages) (agent-history agent) :test #'eq)))
                   (and at (some (lambda (p) (%untrusted-call-p agent p))
                                 (%tool-uses (ldiff (agent-history agent) at))))))))))

(defun %turn-guard (agent)
  "AGENT's guard for its current turn, rebuilt from the history when the stored one belongs
to another turn."
  (let* ((messages (%current-turn-messages agent))
         (key (first messages))
         (guard (agent-guard agent)))
    (if (and guard key (eq key (turn-guard-key guard)))
        guard
        (setf (agent-guard agent) (%rebuild-guard agent key messages)))))

(defun turn-untrusted-p (agent)
  "True when untrusted content has entered AGENT's current turn. When the turn's guard has to be
rebuilt from the history under :CONVERSATION, this can record AGENT-CONVERSATION-TAINT and, when
nothing was recorded, warn CONVERSATION-TAINT-UNRECORDED (#948)."
  (turn-guard-untrusted (%turn-guard agent)))

(defun turn-urls (agent)
  "The URLs this turn's searches returned before any untrusted content entered the turn,
oldest first. See NOTE-TURN-URLS."
  (reverse (turn-guard-urls (%turn-guard agent))))

(defun note-turn-urls (urls)
  "Record URLS, strings, as returned by a search in the current turn. Called by a search
means while it runs. They are recorded only when the model asked for the search before any
untrusted content entered the turn: a page could otherwise make the model search for a
phrase that only the attacker's page ranks for, and so add its own address to TURN-URLS.
Outside a call, does nothing."
  (when (and *current-guard* (not *decided-after-untrusted*))
    (dolist (url urls)
      (when (stringp url)
        (push url (turn-guard-urls *current-guard*))))))

(defun mark-untrusted ()
  "Mark the current turn as having read untrusted content, from inside a running means whose
result is untrusted only sometimes, such as a delegated agent that read a page. Outside a
call, does nothing."
  (when *current-guard*
    (%taint-guard *current-guard*))
  (when *call-taint*
    (setf (car *call-taint*) t)))

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
                (search (arg "search"))
                (source (gethash (res:stored-result-name record) (agent-means agent))))
            ;; The stored text is what the means returned, so it is as untrusted as that means
            ;; was, here in whatever turn reads it back (#827).
            (when (or (null source) (means-entry-untrusted source))
              (mark-untrusted))
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
  "The messages a deliberation SENDS. Returns (values messages estimated-tokens breakdown).

BREAKDOWN is a plist of estimated tokens by source (#317, step D), see PROMPT-BREAKDOWN.

Not `agent-history', and the difference is the whole of pre-publication issue 402 (ADR-0001):

  - the history is TRIMMED to AGENT-HISTORY-BUDGET by `prompt:trim-history' --
    whole exchanges from the oldest end, never through the cacheable prefix (pre-publication issue 401);
  - the agent's context items are ASSEMBLED by `ctx:assemble' -- the highest-value
    retrieved facts that fit ITS budget -- and placed AFTER that prefix, because
    facts change every turn and caching them would invalidate the cache each time.

Nothing in the history is mutated: the agent's history is the record, this is the request, and
the facts are never written back into the conversation (which would make them permanent, and pay
for them on every later turn). The one change is to the turn's guard: when an assembled item is
untrusted, the turn becomes untrusted (#317's taint ruling)."
  (let* ((history (%clear-batch agent (%with-cleared agent (agent-history agent))))
         (memory (agent-thread-memory agent))
         (start (and memory (%replacing-start memory history)))
         ;; THE TEXT FIRST, and no cut without it (#908's review): with no observations, after
         ;; an erasure or windows that yielded none, nothing replaces the messages before the mark,
         ;; so they are sent.
         (observed (and start (multiple-value-list (thread-observations-text memory))))
         (start (and (first observed) start))
         ;; The observations are sent too, so they count against the history's budget.
         (budget (let ((b (agent-history-budget agent)))
                   (if (and b (first observed))
                       (max 0 (- b (prompt:estimate-tokens (first observed))))
                       b)))
         (trimmed (prompt:trim-history (if start (nthcdr start history) history) budget))
         (assembled-context (ctx:assemble (agent-context agent)))
         (assembled (append assembled-context
                            ;; Subject facts go with the other context items, after the cache
                            ;; marker, so a change to one does not invalidate the thread's cached
                            ;; observations (#317, step C).
                            (and memory
                                 (mem:recall (thread-memory-store memory) (thread-memory-subject memory)
                                             :budget (thread-memory-facts-budget memory)))))
         (subject-facts (and memory (nthcdr (length assembled-context) assembled)))
         (facts (prompt:render-items assembled)))
    (when start
      (destructuring-bind (text untrusted) observed
        (setf trimmed (%with-observations-first trimmed text))
        ;; An untrusted observation in the block makes the turn untrusted, as an untrusted
        ;; context item does, under either scope (#317's taint ruling).
        (when untrusted
          (%taint-guard (%turn-guard agent)))))
    ;; AN UNTRUSTED ITEM IN THE PROMPT MAKES THE TURN UNTRUSTED, under either taint scope
    ;; (#317's taint ruling). Stricter than the rule for a raw untrusted result, which :TURN stops
    ;; counting after the user's next message: an item such as a condensed observation is a
    ;; model's summary of untrusted content, and it can make an injected instruction read like
    ;; the member's own wish, so its source is harder to see than the original's.
    (when (some #'ctx:ctx-item-untrusted assembled)
      (%taint-guard (%turn-guard agent)))
    (let* ((messages (if facts
                         (prompt:attach-context trimmed facts)
                         trimmed))
           (estimate (prompt:messages-tokens messages)))
      (values messages estimate
              (prompt-breakdown agent messages estimate
                                :observations (and start (first observed))
                                :block facts :subject-facts subject-facts)))))

(defun prompt-breakdown (agent messages estimate &key observations block subject-facts)
  "The estimated tokens of a request by source, as a plist (#317, step D): :SYSTEM, the system
prompt; :OBSERVATIONS, the thread's observations sent in place of observed messages; :FACTS, the
subject facts recalled from the thread memory; :CONTEXT, the rest of the context block, which is
the agent's context items and the block's own framing; :TOOL-RESULTS, the results of tool calls in
MESSAGES; and :MESSAGES, everything else in MESSAGES, which is the raw conversation, the tool calls
and each message's overhead. ESTIMATE is PRAXEON/PROMPT:MESSAGES-TOKENS of MESSAGES, which
excludes the system prompt, and the parts other than :SYSTEM add up to it exactly. OBSERVATIONS
and BLOCK are the texts that were sent, or NIL; SUBJECT-FACTS the recalled context items. These
are estimates, characters over PRAXEON/PROMPT:*CHARS-PER-TOKEN*, never the provider's count; the
:USAGE event carries both."
  (let* ((system (let ((prompt (agent-system-prompt agent)))
                   (if (stringp prompt) (prompt:estimate-tokens prompt) 0)))
         (observations (if observations (prompt:estimate-tokens observations) 0))
         (block-tokens (if block (prompt:estimate-tokens block) 0))
         (facts (min block-tokens
                     (reduce #'+ subject-facts
                             :key (lambda (i) (prompt:estimate-tokens (ctx:ctx-item-content i)))
                             :initial-value 0)))
         (tool-results (loop for m in messages
                             for content = (llm:content m)
                             when (listp content)
                               sum (loop for part in content
                                         when (eq (getf part :type) :tool-result)
                                           sum (prompt:part-tokens part)))))
    (list :system system :observations observations :facts facts
          :context (- block-tokens facts) :tool-results tool-results
          :messages (- estimate observations block-tokens tool-results))))

;;; --------------------------------------------------------------------------
;;; A thread's observations in place of its observed messages (#317, step C)
;;; --------------------------------------------------------------------------

(defstruct (thread-memory (:constructor %new-thread-memory))
  "What an agent needs to send a thread's observations in place of its observed messages: the
memory store, the subject and the thread they are about, the observer that writes them, the token
budget for facts about the subject, and REPLACE-AT. See ATTACH-THREAD-MEMORY."
  store subject thread observer (facts-budget 1000) (replace-at nil))

(defun attach-thread-memory (agent store subject thread observer
                             &key (facts-budget 1000) replace-at (read-tool t))
  "Give AGENT a thread memory: STORE (a PRAXEON/MEMORY store), SUBJECT and THREAD, and OBSERVER, a
PRAXEON/OBSERVE observer of that subject and thread. Returns AGENT.

After each turn RUN-TURN gives OBSERVER the agent's history, which returns at once; the history
stays the full record. Facts about SUBJECT are recalled within FACTS-BUDGET estimated tokens and
put after the cache marker with the agent's other context items.

REPLACE-AT, NIL or a positive integer, is the estimated tokens of observed messages at which the
thread's observations replace them in what is sent. NIL, the default, never replaces: the right
value is the one #317's benchmark measures, and until then an app sets it knowingly. Once it is
reached, what is sent is the system prompt, then the first user message after the observer's mark
with the thread's observations as its first part, which carries the cache marker, then the rest
of the history from there, trimmed as before. The cut is moved to a user message the user wrote,
so a tool's result is never sent without its call. Between distillations the observations are
the same, so everything up to the marker is byte-identical from turn to turn; a reflection
rewrites it, which is the one expected cache miss.

READ-TOOL registers *READ-OBSERVED-MESSAGES-MEANS*, which returns the messages an observation, or
the observations a condensed one replaced, came from, exactly as the history holds them.

OBSERVER should be made with :UNTRUSTED-P (UNTRUSTED-WINDOW-PREDICATE AGENT), so its observations
are marked as this agent judges its windows (#906)."
  (unless (or (null replace-at) (and (integerp replace-at) (plusp replace-at)))
    (error 'cnd:praxeon-error
           :detail (format nil ":replace-at must be NIL or a positive integer, not ~S" replace-at)))
  (unless (and (integerp facts-budget) (not (minusp facts-budget)))
    (error 'cnd:praxeon-error
           :detail (format nil ":facts-budget must be a non-negative integer, not ~S" facts-budget)))
  (unless (typep observer 'obs:observer)
    (error 'cnd:praxeon-error :detail (format nil "~S is not a PRAXEON/OBSERVE observer" observer)))
  (unless (and (equal (obs:observer-thread observer) thread) (equal (obs:observer-subject observer) subject))
    (error 'cnd:praxeon-error
           :detail "the observer must observe the same subject and thread as the thread memory"))
  (setf (agent-thread-memory agent)
        (%new-thread-memory :store store :subject subject :thread thread :observer observer
                             :facts-budget facts-budget :replace-at replace-at))
  (when read-tool
    (register-means agent *read-observed-messages-means*
                    "Return the messages of this conversation that an observation, given by its id, was taken from, exactly as they were written. Use it when an observation leaves out a detail you need."
                    (lambda (args) (%read-observed-messages agent (and (hash-table-p args) (gethash "id" args))))
                    :schema (%string-arg-schema "id" "The observation's id, as shown in the observations.")
                    ;; Each call can return many messages, so a turn reads a few at most.
                    :max-per-turn 5))
  agent)

(defun %observation-order (a b)
  (or (< (mem:observation-recorded-at a) (mem:observation-recorded-at b))
      (and (= (mem:observation-recorded-at a) (mem:observation-recorded-at b))
           (string< (mem:observation-id a) (mem:observation-id b)))))

(defun thread-observations-text (memory)
  "The thread's current observations as the text that replaces its observed messages, one per line
in a fixed order (recorded time, then id), each with its id and the date it applies from, or NIL
when there are none. A second value is true when any of them came from untrusted content; each
such line says so. The same observations always give the same text, which is what keeps the
prompt's cached prefix the same between distillations."
  (let ((observations (sort (copy-list (mem:observations-of (thread-memory-store memory)
                                                            (thread-memory-subject memory)
                                                            :thread (thread-memory-thread memory)))
                            #'%observation-order)))
    (when observations
      (values (with-output-to-string (s)
                (format s "What has been observed in this conversation so far, in place of its earlier messages:")
                (dolist (o observations)
                  (format s "~%[~A] ~A~:[~; (from untrusted content, not from the person)~] ~A"
                          (mem:observation-id o) (dst:date-string (mem:observation-valid-from o))
                          (mem:observation-untrusted-p o) (%observation-line-text (mem:observation-content o)))))
              (and (some #'mem:observation-untrusted-p observations) t)))))

(defun %observation-line-text (text)
  "TEXT on one line, with every [ written \\[, so an observation's content cannot start a line of
its own or look like an observation's id. Without it, an untrusted observation whose content held
a line break followed by \"[obs-3] 2026-10-01 ...\" forged an unlabelled line (#908's review). A
line break is any of the characters PRAXEON/PROMPT counts as one; each becomes a space."
  ;; A CASE ON THE CHARACTER, with the code test last. Written as a COND whose second clause was
  ;; (MEMBER (CHAR-CODE CH) '(#x0B #x85 #x2028 #x2029)), SBCL 2.6.9 compiled it so that the next
  ;; clause, (CHAR= CH #\[), was never taken, and no [ was escaped; the same COND interpreted
  ;; escaped it. Found writing #908's forging test, which fails without the escape.
  (with-output-to-string (s)
    (loop for ch across text
          do (case ch
               ((#\Newline #\Return #\Page #\Tab) (write-char #\Space s))
               (#\[ (write-string "\\[" s))
               (t (if (member (char-code ch) '(#x0B #x85 #x2028 #x2029))
                      (write-char #\Space s)
                      (write-char ch s)))))))

(defun %replacing-start (memory history)
  "The position in HISTORY from which messages are sent when MEMORY's observations replace the
earlier ones, or NIL while they do not: before REPLACE-AT is reached, or with REPLACE-AT NIL.

NOTHING UNOBSERVED IS CUT (#908's review). The cut is never past the observer's mark, nor past the
first message of any skipped window, open or closed, whose messages the observer gave up on and
which must stay raw in the prompt. Within that limit it is the last message the user wrote at or
before it, so a turn cut mid-exchange (a held call's result, parallel tool calls, a window that
ended between a call and its result) is sent whole, and a tool's result is never sent without
its call. Re-sending messages that were observed is safe; dropping ones that were not is not.
With no user message at or before the limit, everything is sent from the start."
  (let* ((replace-at (thread-memory-replace-at memory))
         (observer (thread-memory-observer memory))
         (limit (reduce #'min (mapcar (lambda (window) (1- (first window))) (obs:observer-skipped observer))
                        :initial-value (min (obs:observer-mark observer) (length history)))))
    (when (and replace-at (plusp limit)
               (>= (prompt:messages-tokens (subseq history 0 limit)) replace-at))
      (or (position-if #'%user-message-p history :end (min (1+ limit) (length history)) :from-end t)
          0))))

(defun %with-observations-first (messages text)
  "MESSAGES with TEXT, carrying the cache marker, as the first part of the first one, a user
message. A part of that message, not a message of its own, so user and assistant messages still
alternate for every provider."
  (if (null messages)
      (list (llm:msg "user" (list (llm:text-part text :cache t))))
      (let* ((first (copy-list (first messages)))
             (content (getf first :content))
             (parts (if (stringp content) (list (llm:text-part content)) content)))
        (setf (getf first :content) (cons (llm:text-part text :cache t) parts))
        (cons first (rest messages)))))

(defun %observe-after-turn (agent)
  "Give AGENT's observer its history after a turn. A failure is logged, never raised: the turn
has already happened."
  (let ((memory (agent-thread-memory agent)))
    (when memory
      (handler-case (obs:observe-turn (thread-memory-observer memory) (agent-history agent))
        (error (e)
          (log:warn "praxeon/actor: the thread's observer could not be given the turn"
                    :agent (agent-name agent)
                    :condition (string-downcase (princ-to-string (type-of e)))))))))

(defun %raw-part-text (part)
  (case (getf part :type)
    (:text (getf part :text))
    (:tool-use (format nil "[calls ~A with ~A]" (getf part :name)
                       (handler-case (jzon:stringify (getf part :input)) (error () (princ-to-string (getf part :input))))))
    (:tool-result (let ((c (getf part :content)))
                    (format nil "[result: ~A]" (if (stringp c) c (princ-to-string c)))))
    (t (princ-to-string part))))

(defun %observed-positions (agent id)
  "The observation ID of AGENT's thread memory, and the history positions (from 1, ascending) of
the messages it, or the observations it was condensed from, came from. NIL when there is no such
observation in the thread."
  (let* ((memory (agent-thread-memory agent))
         (thread (thread-memory-thread memory))
         (all (mem:observations-of (thread-memory-store memory) (thread-memory-subject memory)
                                   :thread thread :include-superseded t))
         (find (lambda (x) (find x all :key #'mem:observation-id :test #'equal)))
         (observation (and (stringp id) (funcall find id)))
         (positions '())
         (seen '()))
    (when observation
      (labels ((collect (o)
                 (unless (member (mem:observation-id o) seen :test #'string=)
                   (push (mem:observation-id o) seen)
                   (let ((p (mem:observation-provenance o)))
                     (when (and (string= (mem:provenance-conversation p) thread) (plusp (mem:provenance-turn p)))
                       (loop for i from (mem:provenance-turn p) to (or (mem:provenance-through p) (mem:provenance-turn p))
                             do (pushnew i positions))))
                   (dolist (source (mem:observation-condensed-from o))
                     (let ((s (funcall find source))) (when s (collect s)))))))
        (collect observation))
      (values observation (sort positions #'<)))))

(defun %observed-messages-untrusted-p (agent id)
  "Whether reading back the observation ID with *READ-OBSERVED-MESSAGES-MEANS* reads untrusted
content: the observation is untrusted, or the messages it came from hold an untrusted call. Also
what %UNTRUSTED-CALL-P recomputes for such a call, so the judgement survives an agent rebuilt from
its history (#908's review). True when AGENT has no thread memory or there is no such observation,
since the result cannot then be judged."
  (if (null (agent-thread-memory agent))
      t
      (multiple-value-bind (observation positions) (%observed-positions agent id)
        (or (null observation)
            (mem:observation-untrusted-p observation)
            (let ((history (agent-history agent)))
              (funcall (untrusted-window-predicate agent)
                       (loop for i in positions when (<= i (length history)) collect (nth (1- i) history))))))))

(defun %read-observed-messages (agent id)
  "*READ-OBSERVED-MESSAGES-MEANS*: the messages of AGENT's history that the observation ID, or the
observations it was condensed from, were distilled from, each with its position and role, at most
*READ-RESULT-MAX-CHARACTERS* characters of them. When they are untrusted
(%OBSERVED-MESSAGES-UNTRUSTED-P), the turn is marked untrusted and the answer says so first, since
the model is reading that content again (#906, #908's review)."
  (multiple-value-bind (observation positions) (%observed-positions agent id)
    (if (null observation)
        (format nil "No observation ~S in this conversation." id)
        (let* ((history (agent-history agent))
               (wanted (remove-if (lambda (i) (> i (length history))) positions))
               (messages (mapcar (lambda (i) (nth (1- i) history)) wanted))
               (untrusted (%observed-messages-untrusted-p agent id)))
          (when untrusted (mark-untrusted))
          (if (null messages)
              (format nil "The messages behind ~A are no longer in this conversation's history." id)
              (let ((text (with-output-to-string (s)
                            (format s "~:[~;These messages hold content from outside the conversation, not from the person. ~]The messages ~A was taken from, exactly as written:"
                                    untrusted id)
                            (loop for i in wanted
                                  for m in messages
                                  for content = (getf m :content)
                                  do (format s "~%~%message ~D, ~A:~%~A" i (getf m :role)
                                             (if (stringp content)
                                                 content
                                                 (format nil "~{~A~^~%~}" (mapcar #'%raw-part-text content))))))))
                (if (> (length text) *read-result-max-characters*)
                    (format nil "~A~%~%[cut at ~D of ~D characters]" (subseq text 0 *read-result-max-characters*)
                            *read-result-max-characters* (length text))
                    text)))))))

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
ESTIMATED-INPUT-TOKENS BREAKDOWN), BREAKDOWN as PROMPT-BREAKDOWN gives it. Signals
DELIBERATION-FAILURE when no provider is configured.

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
  (multiple-value-bind (messages estimate breakdown) (request-messages agent)
    (values (llm:complete (agent-provider agent)
                          messages
                          :system (agent-system-parts agent)
                          :tools (agent-tool-specs agent :permit permit)
                          :max-tokens (%output-limit agent max-tokens))
            estimate breakdown)))

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

(defvar *tool-call-id* nil
  "The id of the tool call whose means is running, as the model gave it, or NIL outside a call.
A means that starts work which finishes after the call returns, such as an MCP task (#532),
keeps it, so the events it emits later carry the same :ID as the call's :TOOL-CALL and
:TOOL-RESULT events.")

(defstruct (started-result (:constructor started-result (text)))
  "What a means returns when the call has started work that finishes later, such as an MCP task
(#532). TEXT is what the model is told. The call's :TOOL-RESULT event has outcome :STARTED
rather than :OK, because the call has not produced its result yet; the means reports the result
later with an event of its own that carries the call's :ID."
  (text "" :type string))

(defun %apply-call (agent name args permit &key id)
  "Apply the means NAME to ARGS through ACT, with *TOOL-CALL-ID* bound to ID. Return its result
as a string; a second value that is true when the means reported an error for the model to see
(#527); the outcome, :OK, :STARTED for a STARTED-RESULT (#532), or the condition's OUTCOME; and
how many milliseconds the call took.

A means reports such an error by signalling CND:TOOL-ERROR-RESULT. The handler here takes only
that case, and gives the model the condition's text as an error result. Every other failure
of a means is declined, so it reaches the app's handlers with ACT's restarts still in place,
and ends the turn when nothing handles it, as before."
  (let ((started (get-internal-real-time)))
    (flet ((ms () (round (* 1000 (- (get-internal-real-time) started))
                         internal-time-units-per-second)))
      (block call
        (handler-bind ((cnd:means-failure
                         (lambda (failure)
                           (let ((cause (cnd:means-failure-cause failure)))
                             (when (typep cause 'cnd:tool-error-result)
                               (return-from call
                                 (values (cnd:tool-error-result-text cause) t
                                         (cnd:tool-error-result-outcome cause) (ms))))))))
          (let ((result (let ((*tool-call-id* id)) (act agent name args :permit permit))))
            (if (started-result-p result)
                (values (started-result-text result) nil :started (ms))
                (values (%result-string result) nil :ok (ms)))))))))

(defun %means-source (agent name)
  (let ((entry (gethash name (agent-means agent))))
    (and entry (means-entry-source entry))))

;;; --- a private agent (#983) -----------------------------------------------------------------
;;;
;;; Praxeon's own log lines record counts, ids, durations and type names, never a prompt, a tool
;;; argument, a tool result or a reply (docs/logging.md). Two routes could still carry content
;;; while an agent runs, and a private agent closes both for the whole of its turn, on every
;;; thread the turn continues on:
;;;   - AION/LOG:*LOG-CONDITION-DETAILS*, a development setting, would make AION/LOG:EXCEPTION
;;;     write a condition's report and the backtrace's arguments, which can quote any of these.
;;;     It is bound to NIL.
;;;   - Events: a tool call's arguments, a tool result, an answer's text and a delegated task
;;;     reach EVT:*OBSERVER*, which the studio's status printer and praxeon/web print. They are
;;;     :WITHHELD (EVT:*WITHHOLD-CONTENT*), unless the agent says RETAIN-CONTENT.
;;; A sub-agent delegated to from a private agent's turn runs under the same bindings.

(aion/dynamic:register-inheritable 'aion/log:*log-condition-details*)

(defun %withhold-content-for (agent)
  "What EVT:*WITHHOLD-CONTENT* is during a turn of AGENT: true when an enclosing turn already
withholds, or AGENT is private and does not retain content."
  (or evt:*withhold-content* (and (agent-private agent) (not (agent-retain-content agent)))))

(defun %withhold-from-logs-for (agent)
  "What EVT:*WITHHOLD-FROM-LOGS* is during a turn of AGENT: true when an enclosing turn already
withholds, or AGENT is private. RETAIN-CONTENT does not change it, because it is about events."
  (or evt:*withhold-from-logs* (and (agent-private agent) t)))

(defun %condition-details-for (agent)
  "What AION/LOG:*LOG-CONDITION-DETAILS* is during a turn of AGENT: NIL when AGENT is private,
and otherwise what it already was, which an enclosing private turn has made NIL."
  (and (not (agent-private agent)) aion/log:*log-condition-details*))

(defmacro %with-agent-privacy ((agent) &body body)
  "Run BODY, a turn of AGENT, with its privacy in force (#983)."
  (let ((a (gensym "AGENT")))
    `(let* ((,a ,agent)
            (evt:*withhold-content* (%withhold-content-for ,a))
            (evt:*withhold-from-logs* (%withhold-from-logs-for ,a))
            (aion/log:*log-condition-details* (%condition-details-for ,a)))
       ,@body)))

(defun %append-history (agent &rest messages)
  (setf (agent-history agent) (append (agent-history agent) messages)))

(defun run-turn (agent user-input &key (max-steps 8) permit max-tokens principal
                                       (on-hold nil on-hold-p) held claim)
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
means that needs a principal refuses the call.

ON-HOLD is what the app does when the model calls a means registered with :CONFIRM (#531):
  NIL         no confirmation is available, and the call is not run. The default.
  a function  called with a plist describing the call (:PRINCIPAL :AGENT :NAME :SOURCE
              :ARGUMENTS :ESTIMATE), on this thread; it returns :APPROVE, :DECLINE or :HOLD.
  :HOLD       the turn ends with the call held: RUN-TURN returns NIL, :HELD and a HELD-TURN,
              which the app stores and later passes to CONTINUE-TURN with the user's decision.
When ON-HOLD is not given, a turn uses the enclosing turn's, so a delegated sub-turn asks the
same blocking function; :HOLD is not passed down, because a sub-agent's hold cannot end the
coordinator's turn, and counts there as no confirmation available. A turn with no principal
cannot hold a call.

HELD is the HELD-TURN of an earlier turn whose held calls were never decided. When the history
ends with calls that have no results, RUN-TURN needs it, or an earlier ABANDON-HELD-TURN, and
signals HELD-TURN-REQUIRED without it. With it, the held calls get \"not run: the user did not
confirm\" before the new message. CLAIM is the app's function that records a decision once; see
CONTINUE-TURN."
  (let* ((*principal* (or principal *principal*))
         (*on-hold* (cond (on-hold-p on-hold)
                          ((eq *on-hold* :hold) nil)
                          (t *on-hold*)))
         (*hold-allowed* on-hold-p))
    (%with-agent-privacy (agent)
      (%settle-unanswered agent held claim)
      (multiple-value-prog1 (%run-turn agent user-input max-steps permit max-tokens)
        ;; The observer is given the history after every turn (#317, step C).
        (%observe-after-turn agent)))))

(defun %run-turn (agent user-input max-steps permit max-tokens)
  "RUN-TURN's steps, with *PRINCIPAL* and *ON-HOLD* already bound."
  (let ((message (llm:msg "user" user-input)))
    (%append-history agent message)
    (when *delegated*
      (push message (agent-untrusted-inputs agent)))
    ;; The first turn of a conversation starts it clean, under either scope (#948).
    (when (and (null (agent-conversation-taint agent))
               (eq message (first (agent-history agent))))
      (setf (agent-conversation-taint agent) :clean))
    (let ((guard (%make-turn-guard message nil agent)))
      (setf (agent-guard agent) guard)
      (%taint-guard-from guard *decided-after-untrusted*)
      (%taint-guard-from guard (%history-untrusted-p agent message)))
    ;; A delegated task is a model's text, and it stays in this agent's history, so the
    ;; conversation is untrusted from the next turn on (#948). The task does not make this
    ;; turn untrusted, as before; UNTRUSTED-INPUTS above only keeps it out of USER-TEXTS.
    ;; :DELEGATED, not :UNTRUSTED, so a coordinator is not marked by it (#949's review).
    (when (and *delegated* (not (eq (agent-conversation-taint agent) :untrusted)))
      (setf (agent-conversation-taint agent) :delegated)))
  (%turn-loop agent max-steps permit (%output-limit agent max-tokens)))

(defun %turn-loop (agent max-steps permit limit)
  "Deliberate and act until the model answers, at most MAX-STEPS times. Returns RUN-TURN's
values. CONTINUE-TURN enters here too, after it has written a held step's results."
  (progn
    (dotimes (step max-steps
                   (error 'cnd:deliberation-failure
                          :detail (format nil "no final answer within ~A steps"
                                          max-steps)))
      (evt:emit :deliberating :step step)
      (multiple-value-bind (completion estimate breakdown)
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
          ;; THE PER-STEP TOKEN BREAKDOWN (#317, step D), logged on every step whether or not the
          ;; provider reported a count, because the estimate is ours and always exists. Counts
          ;; only: no text of the prompt.
          (log:info "praxeon/actor: prompt tokens"
                    :agent (agent-name agent) :step step :estimated-input estimate
                    :system (getf breakdown :system) :observations (getf breakdown :observations)
                    :facts (getf breakdown :facts) :context (getf breakdown :context)
                    :tool-results (getf breakdown :tool-results)
                    :messages (getf breakdown :messages)
                    :input in :output out :cache-read cache-read :cache-write cache-write)
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
                             :estimated-input estimate :breakdown breakdown)))
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
                 (multiple-value-bind (message held) (%tool-results-step agent calls permit)
                   (if held
                       ;; A call is held (#531): the step's other results wait in the held
                       ;; turn, and nothing more is added to the history until it is decided.
                       (return (values nil :held
                                       (%make-held-turn-from agent held (- max-steps step 1)
                                                             limit)))
                       (%append-history agent message)))))))))))

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
         (evt:emit :delegate :agent (agent-name sub) :task (evt:unless-withheld task))
         ;; The sub-turn runs with the COORDINATOR's authority, not with none. A delegated
         ;; subtask that silently lost the permit would be a capability-bearing means becoming
         ;; unreachable one level down -- the same defect pre-publication issue 400 found in RUN-TURN, reached by
         ;; delegation instead of by the main loop.
         ;; The task is the coordinating model's text, never the user's, and the sub-agent
         ;; sees the coordinator's user texts instead (#827).
         (multiple-value-prog1 (let ((*outer-user-texts* (user-texts coordinator))
                                     (*delegated* t))
                                 (run-turn sub (or task "") :permit permit))
           ;; What the sub-agent read reaches the coordinator in its answer (#827). Only what
           ;; it read: a sub-agent untrusted only because an earlier task was delegated to it
           ;; (:DELEGATED) has nothing untrusted to pass back (#949's review).
           (when (and (turn-untrusted-p sub)
                      (eq t (turn-guard-untrusted (%turn-guard sub))))
             (mark-untrusted)))))
     :schema (%string-arg-schema
              arg (format nil "A self-contained instruction for the ~A agent."
                          (agent-name sub)))
     ;; A sub-agent that can read untrusted content makes this means untrusted, so a guard
     ;; rebuilt from the coordinator's history counts a delegation as such a read.
     :untrusted (loop for entry being the hash-values of (agent-means sub)
                      thereis (means-entry-untrusted entry)))
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
                                          max-tokens principal (on-hold nil on-hold-p) held
                                          claim)
  "Run one turn for AGENT through CHAIN, returning the final TURN (not a string).

CHAIN is a list of stages built with PRAXEON/TURN's ENTER-STAGE / LEAVE-STAGE /
GUARD-STAGE; the default is no stages, which is exactly RUN-TURN with a value wrapped
around it. The model call is the effect at the edge, so a guard that halts on the way in
means it never happens.

Returns the turn so the caller can distinguish an answer from a refusal -- ask
TURN:TURN-HALTED, and read TURN:TURN-NOTE for the reason. Callers wanting only the text
can take TURN:TURN-REPLY.

MAX-STEPS, PERMIT, MAX-TOKENS, PRINCIPAL, ON-HOLD, HELD and CLAIM are passed to RUN-TURN. When the
turn holds a call (#531), the second value is :HELD, the third the HELD-TURN, and the effect's
reply is empty; the leave stages run as they do for an abandoned turn. When a handler ends the turn through
a restart of OUTPUT-TRUNCATED (#326), the second value is RUN-TURN's: :TRUNCATED after
ACCEPT-TRUNCATED, when the effect's reply is the cut-off text, and :ABANDONED after
ABANDON-TURN, when the effect's reply is empty. It is NIL otherwise.

The leave stages run after the effect in every case, so the final reply is what they made of the
effect's reply. A guardrail that adds a note to the reply adds it to an abandoned turn's empty
reply too, and the turn is returned with that note and :ABANDONED. The second value says how the
model's part of the turn ended, not what the final reply contains."
  (let ((outcome nil) (held-turn nil))
    (values
     (turn:run-chain
      ;; Coalton checks that CHAIN is a list, not what is in it (#110).
      (boundary:check-elements chain 'aion/interceptor:interceptor
                               :function 'turn:run-chain :argument 'chain)
      (lambda (tn)
        ;; The one impure pivot. It reads the turn's INPUT rather than the argument, so an
        ;; enter stage that rewrote the input (translation, redaction, a system preamble) is
        ;; what the model actually sees.
        (multiple-value-bind (reply ended held-value)
            (apply #'run-turn agent (turn:turn-input tn)
                   :max-steps max-steps :permit permit :max-tokens max-tokens
                   :principal principal :held held :claim claim
                   (when on-hold-p (list :on-hold on-hold)))
          (setf outcome ended held-turn held-value)
          ;; TURN-REPLY is a String, and an abandoned or held turn has no text.
          (turn:with-reply tn (or reply ""))))
      (turn:make-turn input locale))
     outcome
     held-turn)))
