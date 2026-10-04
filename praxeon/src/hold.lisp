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
  "A turn that ended with calls held for the user's decision. The app stores it, as
HELD-TURN-TO-PLIST gives it, next to the agent's history, and gives it to CONTINUE-TURN.

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
  (apply #'evt:emit type :id held-id :principal *principal* :name (getf call :name)
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

(defun %tool-results-step (agent calls permit)
  "Apply a step's CALLS. Returns the tool-result message, or NIL and a description of the held
calls when the turn's policy holds any (#531). Calls to means without :CONFIRM run as they
always have; the others are decided by the policy, and their results come in the model's
order."
  (let ((parts '()) (held '()) (held-id nil))
    (dolist (call calls)
      (let* ((id (llm:tool-call-id call))
             (name (llm:tool-call-name call))
             (args (llm:tool-call-arguments call))
             (entry (gethash name (agent-means agent)))
             (confirm (and entry (means-entry-confirm entry))))
        (if (null confirm)
            (push (%run-part agent id name args permit) parts)
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
                          (push (%run-part agent id name args permit) parts))
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
                                parts))))))))))))
    (if held
        (values nil (list :id held-id :calls (nreverse held) :results (nreverse parts)
                          :order (mapcar #'llm:tool-call-id calls)))
        (values (llm:msg "user" (nreverse parts)) nil))))

(defun %make-held-turn-from (agent info steps limit)
  (%make-held-turn :id (getf info :id) :principal *principal* :agent (agent-name agent)
                   :calls (getf info :calls) :results (getf info :results)
                   :order (getf info :order) :steps steps :max-tokens limit
                   :created-at (get-universal-time) :expires-at nil))

;;; --- writing a held turn out and reading it back ---------------------------------------

(defun %plist-out (plist)
  "PLIST with keyword keys, as an alist of lower-case names and values."
  (loop for (k v) on plist by #'cddr collect (cons (string-downcase (symbol-name k)) v)))

(defun %plist-in (alist)
  (loop for (name . v) in alist append (list (intern (string-upcase name) :keyword) v)))

(defun held-turn-to-plist (held)
  "HELD as a plist of strings, numbers, booleans and lists of them, for the app to store. A
call's arguments are their JSON text. An estimate's or a source's keys are lower-case names;
their values are strings, integers, floats, T or NIL, and come back as they went."
  (list :id (held-turn-id held) :principal (held-turn-principal held)
        :agent (held-turn-agent held)
        :calls (mapcar (lambda (c)
                         (list :id (getf c :id) :name (getf c :name)
                               :source (%plist-out (getf c :source))
                               :arguments (and (getf c :arguments)
                                               (com.inuoe.jzon:stringify (getf c :arguments)))
                               :estimate (%plist-out (getf c :estimate))))
                       (held-turn-calls held))
        :results (mapcar (lambda (p) (list :id (getf p :tool-use-id) :content (getf p :content)
                                           :is-error (and (getf p :is-error) t)))
                         (held-turn-results held))
        :order (held-turn-order held) :steps (held-turn-steps held)
        :max-tokens (held-turn-max-tokens held) :created-at (held-turn-created-at held)
        :expires-at (held-turn-expires-at held)))

(defun held-turn-from-plist (plist)
  "The HELD-TURN that HELD-TURN-TO-PLIST gave PLIST for."
  (%make-held-turn
   :id (getf plist :id) :principal (getf plist :principal) :agent (getf plist :agent)
   :calls (mapcar (lambda (c)
                    (list :id (getf c :id) :name (getf c :name)
                          :source (%plist-in (getf c :source))
                          :arguments (let ((a (getf c :arguments)))
                                       (and a (com.inuoe.jzon:parse a)))
                          :estimate (%plist-in (getf c :estimate))))
                  (getf plist :calls))
   :results (mapcar (lambda (r) (llm:tool-result-part (getf r :id) (getf r :content)
                                                      (getf r :is-error)))
                    (getf plist :results))
   :order (getf plist :order) :steps (getf plist :steps)
   :max-tokens (getf plist :max-tokens) :created-at (getf plist :created-at)
   :expires-at (getf plist :expires-at)))

;;; --- deciding once ---------------------------------------------------------------------

(defvar *claims* (make-hash-table :test #'equal)
  "held-turn id -> the decision recorded for it, for the default claim, which covers one
process only.")

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
               (if (and (listp next)
                        (some (lambda (p) (and (eq :tool-result (getf p :type))
                                               (member (getf p :tool-use-id) ids :test #'equal)))
                              next))
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
    ;; The arguments that run are the ones the model wrote, in the history; the held turn's
    ;; copy is what the user was shown, so the two must agree.
    (dolist (c (held-turn-calls held))
      (let ((part (find (getf c :id) (%tool-use-parts message)
                        :key (lambda (p) (getf p :id)) :test #'equal)))
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
                (and entry (equal (means-entry-source entry) (getf call :source))))
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
and each held call's under DECISION."
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
                          (%held-part agent call d permit recorded))))
                  (held-turn-order held))))
    (%append-history agent (llm:msg "user" parts))))

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
only. When the claim is refused, the results the recorded decision calls for are written and
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
        (%turn-loop agent (max 1 (held-turn-steps held)) permit (held-turn-max-tokens held))))))

(defun abandon-held-turn (agent held &key principal claim)
  "Close HELD without a decision: its held calls get \"not run: the user did not confirm\", after
:UNANSWERED is recorded through CLAIM, so a later approval runs nothing. The step's other results
are written as they were. Returns true, or NIL and :ALREADY-DECIDED when the turn was decided
before. Checked as CONTINUE-TURN checks."
  (let* ((*principal* principal)
         (state (%check-held agent held principal)))
    (when (eq state :answered)
      (return-from abandon-held-turn (values nil :already-decided)))
    (multiple-value-bind (first recorded) (%claim claim (held-turn-id held) :unanswered)
      (if first
          (%write-held-results agent held :unanswered nil)
          (%write-held-results agent held recorded nil :recorded t)))
    t))

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
      (if held
          (abandon-held-turn agent held :principal *principal* :claim claim)
          (error 'held-turn-required :ids ids)))))
