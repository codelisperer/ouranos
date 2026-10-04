;;;; hold.lisp --- holding a call until the user decides (#531)
;;;;
;;;; A means registered with :CONFIRM is not run when the model calls it. The turn's ON-HOLD
;;;; policy decides: a blocking function asks the user there and then; :HOLD ends the turn with
;;;; the call held, and the app stores the HELD-TURN and continues the turn later with the
;;;; user's decision, from another request, another thread or after a restart. This follows the
;;;; shape of the OpenAI Agents SDK (needs_approval, interruptions, a RunState that is stored
;;;; and resumed). LangGraph's interrupt() re-runs the interrupted node when it resumes, which a
;;;; turn here must never do: a call that may have run is never run again (#527).

(cl:in-package #:praxeon/actor)

;;; --- what the model is told -----------------------------------------------------------

(defparameter +no-confirmation+ "Not run: no confirmation was available.")
(defparameter +declined+ "Not run: the user declined.")
(defparameter +unanswered+ "Not run: the user did not confirm.")
(defparameter +expired+ "Not run: the user did not confirm in time.")
(defparameter +estimate-failed+ "Not run: the cost of this call could not be estimated.")
(defparameter +unavailable+ "Not run: the tool is no longer available.")
(defparameter +no-such-tool+ "Not run: no such tool is available.")
(defparameter +turn-ended+ "Not run: the turn ended before this call was run.")
(defparameter +may-have-run+
  "The tool may have run; its outcome is unknown. Do not call it again before checking with the user.")

;;; --- conditions -----------------------------------------------------------------------

(define-condition wrong-principal (cnd:praxeon-error) ()
  (:report "This held turn belongs to another principal; nothing was changed.")
  (:documentation "CONTINUE-TURN or ABANDON-HELD-TURN was called for a principal other than the
one the call was held for. Nothing is recorded and nothing runs."))

(define-condition held-turn-mismatch (cnd:praxeon-error)
  ((reason :initarg :reason :reader held-turn-mismatch-reason))
  (:report (lambda (c s) (format s "The held turn does not match the agent: ~A."
                                 (held-turn-mismatch-reason c))))
  (:documentation "The held turn and the agent's history do not belong together: another agent,
no model message holding these calls, or arguments that differ from the ones the model wrote.
The app saved one without the other. Nothing runs."))

(define-condition held-turn-required (cnd:praxeon-error)
  ((ids :initarg :ids :reader held-turn-required-ids))
  (:report (lambda (c s) (format s "The history ends with calls that have no results (~{~A~^, ~}); pass the held turn as :HELD, or call ABANDON-HELD-TURN first."
                                 (held-turn-required-ids c))))
  (:documentation "RUN-TURN was called on an agent whose history ends with held calls that were
never decided, without the held turn. The other calls' results exist only in the held turn, so
the turn cannot go on without it. Nothing is written."))

;;; --- the held turn --------------------------------------------------------------------

(defstruct (held-turn (:constructor %make-held-turn))
  "A turn that ended with calls held for the user's decision. The app stores it, as the JSON
text HELD-TURN-TO-JSON gives, next to the agent's history, and gives it to CONTINUE-TURN.

ID identifies it for the app's claim. CALLS is one plist per held call: :ID (the tool-call id),
:NAME, :SOURCE, :ARGUMENTS and :ESTIMATE. RESULTS are the tool-result parts of the step's other
calls, which ran before the hold. ORDER is every call id of the step, in the model's order.
STEPS is how many steps the turn has left, MAX-TOKENS its output limit. EXPIRES-AT is a
universal time or NIL; the app sets it, and a held turn past it is declined."
  id principal agent calls results order steps max-tokens created-at expires-at)

(defun %new-id ()
  (format nil "~(~{~2,'0x~}~)" (coerce (aion/random:random-octets 16) 'list)))

(defun %estimate-plist-p (value)
  "Whether VALUE is an estimate a held turn can write out: a plist with keyword keys, and
strings, integers, floats or booleans as values."
  (and (listp value) (evenp (length value))
       (loop for (k v) on value by #'cddr
             always (and (keywordp k)
                         (or (stringp v) (integerp v) (floatp v) (eq v t) (null v))))))

(defun %estimate (confirm arguments)
  "The estimate for a call held by CONFIRM, and whether it could be made. An estimate function
runs on arguments the model wrote, so one that signals, or returns something that is not an
estimate plist (a ratio included), means the call is not run."
  (if (functionp confirm)
      (handler-case
          (let ((estimate (funcall confirm arguments)))
            (if (%estimate-plist-p estimate) (values estimate t) (values nil nil)))
        (error () (values nil nil)))
      (values nil t)))

(defun %held-event (type held-id call &rest more)
  "Emit TYPE for CALL. :ID is the tool-call id, as in :TOOL-CALL and :TOOL-RESULT, and :HELD
the held turn's id, NIL for a call decided on the spot."
  (apply #'evt:emit type :id (getf call :id) :held held-id :principal *principal*
         :name (getf call :name)
         :source (getf call :source) :estimate (getf call :estimate)
         :at (get-universal-time) more))

(defun %part-event (agent id name args)
  (evt:emit :tool-call :id id :name name :arguments args
                       :source (%means-source agent name) :principal *principal*
                       :agent (agent-name agent) :conversation (agent-conversation agent)))

(defun %run-part (agent id name args permit)
  "Run the call as RUN-TURN always has, and return its tool-result part."
  (%part-event agent id name args)
  (multiple-value-bind (result error-p outcome ms) (%apply-call agent name args permit)
    (apply #'evt:emit :tool-result :id id :name name :content result
           :source (%means-source agent name) :principal *principal*
           :agent (agent-name agent) :conversation (agent-conversation agent)
           :outcome outcome :ms ms (when error-p (list :is-error t)))
    (llm:tool-result-part id (%store-result agent id name args result) error-p)))

(defun %not-run-part (agent id name args text &key (outcome :not-run) (announce t))
  "A tool-result part for a call that was not run, telling the model TEXT."
  (when announce (%part-event agent id name args))
  (evt:emit :tool-result :id id :name name :content text
                         :source (%means-source agent name) :principal *principal*
                         :agent (agent-name agent) :conversation (agent-conversation agent)
                         :outcome outcome :ms 0 :is-error t)
  (llm:tool-result-part id (%store-result agent id name args text) t))

(defun %callable-p (agent name permit)
  "Whether ACT would call the means NAME rather than refuse it before it runs."
  (let ((entry (gethash name (agent-means agent))))
    (and entry (means-permitted-p entry permit))))

(defun %write-interrupted-step (agent calls done held held-id current)
  "Append a result for every call of a step that a non-local exit is leaving (#546), in the
model's order, so the history never ends with calls that have no results. DONE are the
tool-result parts of the calls that finished, HELD the calls held so far, and CURRENT the call
being worked on, as (ID . PHASE): :RUNNING inside its means, :REFUSED by ACT before it ran, or
:DECIDING while the turn's ON-HOLD function was deciding it."
  (let ((parts
          (mapcar
           (lambda (call)
             (let ((id (llm:tool-call-id call))
                   (name (llm:tool-call-name call))
                   (args (llm:tool-call-arguments call)))
               (or (find id done :key (lambda (p) (getf p :tool-use-id)) :test #'equal)
                   (let ((h (find id held :key (lambda (c) (getf c :id)) :test #'equal)))
                     (when h
                       (%held-event :tool-decided held-id h :decision :turn-failed
                                    :agent (agent-name agent)
                                    :conversation (agent-conversation agent))
                       (%not-run-part agent id name args +turn-ended+ :announce nil)))
                   (when (equal id (car current))
                     (ecase (cdr current)
                       (:running (%not-run-part agent id name args +may-have-run+
                                                :outcome :unknown :announce nil))
                       (:refused (%not-run-part agent id name args +no-such-tool+ :announce nil))
                       (:deciding (%not-run-part agent id name args +turn-ended+))))
                   (%not-run-part agent id name args +turn-ended+))))
           calls)))
    (%append-history agent (llm:msg "user" parts))))

(defun %tool-results-step (agent calls permit)
  "Apply a step's CALLS. Returns the tool-result message, or NIL and a description of the held
calls when the turn's policy holds any (#531). Calls to means without :CONFIRM run as they
always have; the others are decided by the policy, and their results come in the model's
order.

When a failure, or any other non-local exit, leaves the step before every call is done, the
step's results are appended first, with %WRITE-INTERRUPTED-STEP (#546), and the exit goes on. A
handler still sees the failure with ACT's restarts in place, because this happens only as the
stack unwinds. The failure wins over a hold in the same step: no held turn is returned, and the
calls held so far are written as not run."
  (let ((parts '()) (held '()) (held-id nil) (current nil) (finished nil))
    (flet ((run (id name args)
             (setf current (cons id (if (%callable-p agent name permit) :running :refused)))
             (push (%run-part agent id name args permit) parts)))
      (unwind-protect
           (progn
             (dolist (call calls)
               (let* ((id (llm:tool-call-id call))
                      (name (llm:tool-call-name call))
                      (args (llm:tool-call-arguments call))
                      (entry (gethash name (agent-means agent)))
                      (confirm (and entry (means-entry-confirm entry))))
                 (if (null confirm)
                     (run id name args)
                     (multiple-value-bind (estimate ok) (%estimate confirm args)
                       (let ((description (list :id id :name name :source (means-entry-source entry)
                                                :arguments args :estimate estimate)))
                         (flet ((decided (decision)
                                  (%held-event :tool-decided nil description :decision decision
                                               :agent (agent-name agent)
                                               :conversation (agent-conversation agent))))
                           (cond
                             ((not ok)
                              (push (%not-run-part agent id name args +estimate-failed+) parts))
                             ((null *principal*)
                              ;; There is no user to ask.
                              (decided :no-confirmation)
                              (push (%not-run-part agent id name args +no-confirmation+) parts))
                             (t
                              (setf current (cons id :deciding))
                              (let ((policy (if (functionp *on-hold*)
                                                (funcall *on-hold*
                                                         (list :principal *principal*
                                                               :agent (agent-name agent) :name name
                                                               :source (means-entry-source entry)
                                                               :arguments args :estimate estimate))
                                                *on-hold*)))
                                (case policy
                                  (:approve
                                   (decided :approve)
                                   (run id name args))
                                  (:decline
                                   (decided :decline)
                                   (push (%not-run-part agent id name args +declined+) parts))
                                  (:hold
                                   (if *hold-allowed*
                                       (progn
                                         (setf held-id (or held-id (%new-id)))
                                         (%part-event agent id name args)
                                         (%held-event :tool-held held-id description
                                                      :agent (agent-name agent)
                                                      :conversation (agent-conversation agent))
                                         (push description held))
                                       (progn
                                         (decided :no-confirmation)
                                         (push (%not-run-part agent id name args +no-confirmation+)
                                               parts))))
                                  (t
                                   (decided :no-confirmation)
                                   (push (%not-run-part agent id name args +no-confirmation+)
                                         parts))))))))))
                   (setf current nil)))
             (setf finished t)
             (if held
                 (values nil (list :id held-id :calls (reverse held) :results (reverse parts)
                                   :order (mapcar #'llm:tool-call-id calls)))
                 (values (llm:msg "user" (reverse parts)) nil)))
        (unless finished
          (%write-interrupted-step agent calls parts held held-id current))))))

(defun %make-held-turn-from (agent info steps limit)
  (%make-held-turn :id (getf info :id) :principal *principal* :agent (agent-name agent)
                   :calls (getf info :calls) :results (getf info :results)
                   :order (getf info :order) :steps steps :max-tokens limit
                   :created-at (get-universal-time) :expires-at nil))

;;; --- writing a held turn out and reading it back ---------------------------------------

(defun %held-object (&rest kv)
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on kv by #'cddr do (setf (gethash k h) v))
    h))

(defun %or-null (value) (if (null value) 'null value))
(defun %from-null (value) (if (eq value 'null) nil value))

(defun %names-out (plist)
  "PLIST with keyword keys as a JSON object of lower-case names. NIL is written as false and T as
true, so an estimate's booleans come back as they went."
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on plist by #'cddr
          do (setf (gethash (string-downcase (symbol-name k)) h) v))
    h))

(defun %names-in (object)
  (and (hash-table-p object)
       (loop for name being the hash-keys of object using (hash-value v)
             append (list (intern (string-upcase name) :keyword) v))))

(defun held-turn-to-json (held)
  "HELD as JSON text, for the app to store next to the agent's history. HELD-TURN-FROM-JSON reads
it back. Each call's arguments are written as the JSON object the model sent. An estimate's and
a source's keys are written as lower-case names. A value that is an integer or a float is a JSON
number, and comes back as an integer or a double-float; T is true and NIL is false. The
principal must be a string or an integer."
  (let ((principal (held-turn-principal held)))
    (unless (or (stringp principal) (integerp principal))
      (error "held-turn-to-json: the principal ~S is not a string or an integer" principal))
    (com.inuoe.jzon:stringify
     (%held-object
      "id" (held-turn-id held) "principal" principal "agent" (%or-null (held-turn-agent held))
      "calls" (map 'vector (lambda (c)
                             (%held-object "id" (getf c :id) "name" (getf c :name)
                                           "source" (%names-out (getf c :source))
                                           "arguments" (%or-null (getf c :arguments))
                                           "estimate" (%names-out (getf c :estimate))))
                   (held-turn-calls held))
      "results" (map 'vector (lambda (p) (%held-object "id" (getf p :tool-use-id)
                                                       "content" (getf p :content)
                                                       "is_error" (and (getf p :is-error) t)))
                     (held-turn-results held))
      "order" (coerce (held-turn-order held) 'vector)
      "steps" (%or-null (held-turn-steps held))
      "max_tokens" (%or-null (held-turn-max-tokens held))
      "created_at" (%or-null (held-turn-created-at held))
      "expires_at" (%or-null (held-turn-expires-at held))))))

(defun held-turn-from-json (text)
  "The HELD-TURN that HELD-TURN-TO-JSON wrote as TEXT. Signals an error when TEXT is not such an
object."
  (let ((o (com.inuoe.jzon:parse text)))
    (unless (and (hash-table-p o) (stringp (gethash "id" o)) (vectorp (gethash "calls" o)))
      (error "held-turn-from-json: the text is not a held turn"))
    (flet ((field (name) (%from-null (gethash name o))))
      (%make-held-turn
       :id (field "id") :principal (field "principal") :agent (field "agent")
       :calls (map 'list (lambda (c)
                           (list :id (gethash "id" c) :name (gethash "name" c)
                                 :source (%names-in (gethash "source" c))
                                 :arguments (%from-null (gethash "arguments" c))
                                 :estimate (%names-in (gethash "estimate" c))))
                   (field "calls"))
       :results (map 'list (lambda (r) (llm:tool-result-part (gethash "id" r) (gethash "content" r)
                                                             (gethash "is_error" r)))
                     (field "results"))
       :order (coerce (field "order") 'list) :steps (field "steps")
       :max-tokens (field "max_tokens") :created-at (field "created_at")
       :expires-at (field "expires_at")))))

;;; --- deciding once ---------------------------------------------------------------------

(defvar *claims* (make-hash-table :test #'equal)
  "held-turn id -> the decision recorded for it, for the default claim, which covers one
process only. Entries are never removed, so a long-running server supplies its own :CLAIM.")

(defvar *claims-lock* (sb-thread:make-mutex :name "praxeon held-turn claims"))

(defun %default-claim (id decision)
  (sb-thread:with-mutex (*claims-lock*)
    (multiple-value-bind (recorded present) (gethash id *claims*)
      (if present
          (values nil recorded)
          (progn (setf (gethash id *claims*) decision) (values t decision))))))

(defun %claim (claim id decision)
  "Record DECISION for ID through CLAIM, the app's function, or the default. Returns true when
this is the first decision, and otherwise NIL and the decision recorded first."
  (if claim (funcall claim id decision) (%default-claim id decision)))

;;; --- checking a held turn against the agent -------------------------------------------

(defun %held-ids (held) (mapcar (lambda (c) (getf c :id)) (held-turn-calls held)))

(defun %tool-use-parts (message)
  (let ((content (llm:content message)))
    (and (listp content)
         (remove-if-not (lambda (p) (eq :tool-use (getf p :type))) content))))

(defun %json-equal (a b)
  (cond ((and (hash-table-p a) (hash-table-p b))
         (and (= (hash-table-count a) (hash-table-count b))
              (loop for k being the hash-keys of a using (hash-value v)
                    always (multiple-value-bind (w present) (gethash k b)
                             (and present (%json-equal v w))))))
        ((and (vectorp a) (vectorp b) (not (stringp a)) (not (stringp b)))
         (and (= (length a) (length b)) (every #'%json-equal a b)))
        (t (equal a b))))

(defun %source-as-json (source)
  "SOURCE as HELD-TURN-TO-JSON writes it and JSON reads it back: a keyword becomes its name and a
list a vector. Signals when SOURCE has a value JSON cannot hold."
  (com.inuoe.jzon:parse (com.inuoe.jzon:stringify (%names-out source))))

(defun %same-source-p (a b)
  "Whether the means sources A and B are the same, compared in the form a stored held turn keeps:
a held call's source has been through JSON when the held turn was stored, and the registered
means's has not, so a keyword or a list in it would otherwise never compare equal."
  (or (equal a b)
      (handler-case (%json-equal (%source-as-json a) (%source-as-json b))
        (error () nil))))

(defun %held-state (agent held)
  "Where the agent's history stands with HELD: :PENDING when its last message is the model
message holding the held calls, :ANSWERED when that message is followed by their results, and
:MISSING otherwise. The second value is that model message."
  (let* ((ids (%held-ids held))
         (history (agent-history agent))
         (tail (loop for rest on history
                     when (and (equal "assistant" (llm:role (car rest)))
                               (subsetp ids (mapcar (lambda (p) (getf p :id))
                                                    (%tool-use-parts (car rest)))
                                        :test #'equal))
                       return rest)))
    (cond ((null tail) (values :missing nil))
          ((null (cdr tail)) (values :pending (car tail)))
          (t (let ((next (llm:content (cadr tail))))
               ;; Answered only when a result follows for every held call; a message with some of
               ;; them is not one this framework wrote, so it does not match.
               (if (and (listp next)
                        (every (lambda (id)
                                 (some (lambda (p) (and (eq :tool-result (getf p :type))
                                                        (equal id (getf p :tool-use-id))))
                                       next))
                               ids))
                   (values :answered (car tail))
                   (values :missing (car tail))))))))

(defun %check-held (agent held principal)
  "The checks CONTINUE-TURN and ABANDON-HELD-TURN make before anything is recorded. Returns the
state of the history, :PENDING or :ANSWERED."
  (unless (and principal (equal principal (held-turn-principal held)))
    (error 'wrong-principal))
  (unless (equal (agent-name agent) (held-turn-agent held))
    (error 'held-turn-mismatch :reason "it was held for another agent"))
  (multiple-value-bind (state message) (%held-state agent held)
    (when (eq state :missing)
      (error 'held-turn-mismatch
             :reason "the history has no model message holding these calls"))
    ;; The held turn says which means runs and in what order the results are written, so it
    ;; must say what the model message says: the same call ids, in order, once each (#547).
    (unless (equal (held-turn-order held)
                   (mapcar (lambda (p) (getf p :id)) (%tool-use-parts message)))
      (error 'held-turn-mismatch
             :reason "its calls are not the model message's calls, in the model's order"))
    ;; The arguments that run are the ones the model wrote, in the history; the held turn's
    ;; copy is what the user was shown, so the two must agree, as must the means named.
    (dolist (c (held-turn-calls held))
      (let ((part (find (getf c :id) (%tool-use-parts message)
                        :key (lambda (p) (getf p :id)) :test #'equal)))
        (unless (equal (getf part :name) (getf c :name))
          (error 'held-turn-mismatch
                 :reason (format nil "the means of ~A differs from the history's" (getf c :id))))
        (unless (%json-equal (getf part :input) (getf c :arguments))
          (error 'held-turn-mismatch
                 :reason (format nil "the arguments of ~A differ from the history's" (getf c :id))))))
    state))

;;; --- writing the results of a held step ------------------------------------------------

(defun %decision-of (decision id)
  (if (listp decision) (cdr (assoc id decision :test #'equal)) decision))

(defun %held-part (agent call decision permit recorded)
  "The tool-result part for the held CALL under DECISION. RECORDED is true when the decision was
recorded by an earlier attempt: an approval then may have run, and nothing runs now."
  (let ((id (getf call :id)) (name (getf call :name)) (args (getf call :arguments)))
    (case decision
      (:approve
       (cond (recorded
              (%not-run-part agent id name args +may-have-run+ :outcome :unknown :announce nil))
             ((let ((entry (gethash name (agent-means agent))))
                (and entry (%same-source-p (means-entry-source entry) (getf call :source))))
              ;; Its :TOOL-CALL event was emitted when it was held.
              (multiple-value-bind (result error-p outcome ms) (%apply-call agent name args permit)
                (apply #'evt:emit :tool-result :id id :name name :content result
                       :source (%means-source agent name) :principal *principal*
                       :agent (agent-name agent) :conversation (agent-conversation agent)
                       :outcome outcome :ms ms (when error-p (list :is-error t)))
                (llm:tool-result-part id (%store-result agent id name args result) error-p)))
             (t (%not-run-part agent id name args +unavailable+ :announce nil))))
      (:decline (%not-run-part agent id name args +declined+ :announce nil))
      (:expired (%not-run-part agent id name args +expired+ :announce nil))
      (t (%not-run-part agent id name args +unanswered+ :announce nil)))))

(defun %write-held-results (agent held decision permit &key recorded)
  "Append the held step's results in the model's order: the stored results of the other calls,
and each held call's under DECISION. When an approved call fails inside its means and the
failure leaves, the results are appended first (#546): that call may have run, and the held
calls after it were not run."
  (let ((done '()) (current nil) (finished nil))
    (unwind-protect
         (let ((parts
                 (mapcar (lambda (id)
                           (or (find id (held-turn-results held) :key (lambda (p) (getf p :tool-use-id))
                                     :test #'equal)
                               (let ((call (find id (held-turn-calls held)
                                                 :key (lambda (c) (getf c :id)) :test #'equal))
                                     (d (%decision-of decision id)))
                                 (%held-event :tool-decided (held-turn-id held) call
                                              :decision (if (and recorded (eq d :approve)) :may-have-run d)
                                              :agent (agent-name agent)
                                              :conversation (agent-conversation agent))
                                 (setf current id)
                                 (let ((part (%held-part agent call d permit recorded)))
                                   (push part done)
                                   (setf current nil)
                                   part))))
                         (held-turn-order held))))
           (setf finished t)
           (%append-history agent (llm:msg "user" parts)))
      (unless finished
        (%append-history
         agent
         (llm:msg "user"
                  (mapcar (lambda (id)
                            (or (find id (held-turn-results held) :key (lambda (p) (getf p :tool-use-id))
                                      :test #'equal)
                                (find id done :key (lambda (p) (getf p :tool-use-id)) :test #'equal)
                                (let ((call (find id (held-turn-calls held)
                                                  :key (lambda (c) (getf c :id)) :test #'equal)))
                                  (%not-run-part agent id (getf call :name) (getf call :arguments)
                                                 (if (equal id current) +may-have-run+ +turn-ended+)
                                                 :outcome (if (equal id current) :unknown :not-run)
                                                 :announce nil))))
                          (held-turn-order held))))))))

(defun %valid-decision-p (decision held)
  (or (member decision '(:approve :decline))
      (and (listp decision)
           (null (set-difference (%held-ids held) (mapcar #'car decision) :test #'equal))
           (every (lambda (pair) (member (cdr pair) '(:approve :decline))) decision))))

;;; --- continuing, and moving on ---------------------------------------------------------

(defun continue-turn (agent held decision &key principal permit (on-hold nil on-hold-p) claim)
  "Continue the turn HELD ended, with the user's DECISION: :APPROVE or :DECLINE for every held
call, or an alist of (tool-call-id . decision) with one entry per held call. PRINCIPAL must be
the one the calls were held for. PERMIT and ON-HOLD are the turn's, given again because
functions cannot be stored. Returns RUN-TURN's values, or NIL, :ALREADY-DECIDED and the decision
recorded first.

Checked first: the principal (WRONG-PRINCIPAL), the agent, and that the agent's history ends
with the model message that holds these calls, with the same arguments (HELD-TURN-MISMATCH).
When that message is already followed by the calls' results, the turn was decided before, and
:ALREADY-DECIDED is returned.

Then the decision is recorded through CLAIM, a function of the held turn's id and the decision
that the app supplies. It must record the decision as one step, return true the first time,
and after that return NIL and the decision recorded first (for a database, UPDATE ... WHERE
decision IS NULL). Without CLAIM, a table in this process is used, which covers one process
only and keeps one entry per held turn for the life of the process, so a long-running server
supplies CLAIM. When the claim is refused, the results the recorded decision calls for are written and
nothing runs; a recorded approval whose result is missing may have run, so the model is told
the outcome is unknown and the call is never run again.

A held turn past its EXPIRES-AT is declined, as \"not run: the user did not confirm in time\". An
approved call whose means is no longer registered with the same :SOURCE is not run."
  (let* ((*principal* principal)
         (*on-hold* (if on-hold-p on-hold nil))
         (*hold-allowed* on-hold-p)
         (state (%check-held agent held principal)))
    (unless (%valid-decision-p decision held)
      (error 'held-turn-mismatch :reason "the decision does not cover every held call"))
    (when (eq state :answered)
      (multiple-value-bind (first recorded) (%claim claim (held-turn-id held) decision)
        (return-from continue-turn (values nil :already-decided (if first decision recorded)))))
    (let ((decision (if (and (held-turn-expires-at held)
                             (> (get-universal-time) (held-turn-expires-at held)))
                        :expired
                        decision)))
      (multiple-value-bind (first recorded) (%claim claim (held-turn-id held) decision)
        (unless first
          (%write-held-results agent held recorded permit :recorded t)
          (return-from continue-turn (values nil :already-decided recorded)))
        (%write-held-results agent held decision permit)
        ;; The steps left after the step that held. With none left the turn ends as an ordinary
        ;; turn does after its last step's calls, rather than asking the model once more.
        (let ((steps (held-turn-steps held)))
          (if (and (integerp steps) (plusp steps))
              (%turn-loop agent steps permit (held-turn-max-tokens held))
              (error 'cnd:deliberation-failure
                     :detail "no final answer within the turn's steps: the decided calls were on its last step")))))))

(defun abandon-held-turn (agent held &key principal claim)
  "Close HELD without a decision: its held calls get \"not run: the user did not confirm\", after
:UNANSWERED is recorded through CLAIM, so a later approval runs nothing. The step's other results
are written as they were. Returns true, or NIL, :ALREADY-DECIDED and the decision recorded
first when the turn was decided before; when that decision has no results in the history yet,
the results it calls for are written, and nothing runs. Checked as CONTINUE-TURN checks."
  (let* ((*principal* principal)
         (state (%check-held agent held principal)))
    (when (eq state :answered)
      ;; Decided before: the decision recorded first comes from the claim, as in CONTINUE-TURN.
      (multiple-value-bind (first recorded) (%claim claim (held-turn-id held) :unanswered)
        (return-from abandon-held-turn
          (values nil :already-decided (if first :unanswered recorded)))))
    (multiple-value-bind (first recorded) (%claim claim (held-turn-id held) :unanswered)
      (cond (first (%write-held-results agent held :unanswered nil) t)
            (t (%write-held-results agent held recorded nil :recorded t)
               (values nil :already-decided recorded))))))

(defun %unanswered-ids (agent)
  "The ids of the tool calls in the history's last message, when it is a model message whose
calls have no results yet."
  (let ((last (car (last (agent-history agent)))))
    (and last (equal "assistant" (llm:role last))
         (mapcar (lambda (p) (getf p :id)) (%tool-use-parts last)))))

(defun %settle-unanswered (agent held claim)
  "Before a new turn: when the history ends with calls that have no results, close them through
HELD, or signal HELD-TURN-REQUIRED."
  (let ((ids (%unanswered-ids agent)))
    (when ids
      (unless held (error 'held-turn-required :ids ids))
      (abandon-held-turn agent held :principal *principal* :claim claim)
      ;; HELD may be an older held turn, already answered, while the history ends with a newer
      ;; one: then nothing was written, and the calls still have no results.
      (let ((left (%unanswered-ids agent)))
        (when left (error 'held-turn-required :ids left))))))
