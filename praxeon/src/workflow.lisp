;;;; workflow.lisp --- deterministic multi-agent coordination (B)
;;;;
;;;; Where register-agent-as-means (praxeon/actor) is the *model-driven* half of
;;;; coordination -- one agent's model chooses to delegate -- a WORKFLOW is the
;;;; *code-driven* half: the program sequences several agents through ordered
;;;; STEPs (and PARALLEL fan-out groups) toward a shared END, threading their
;;;; outputs through a shared BLACKBOARD.
;;;;
;;;; This is the runtime for the ontology's Plan: praxeology.lisp types a `Plan`
;;;; as an ordered bundle of `Action`s over `Actor`s toward an `End`; here the CL
;;;; shell drives that Plan, performing the IO (each step runs an agent's turn).
;;;; Ontology in Coalton; effects in CL -- the house split.

(cl:in-package #:praxeon/workflow)

;;; --------------------------------------------------------------------------
;;; The blackboard: the shared context threaded through a run. Maps each step's
;;; name to that step's output, preserving completion order.
;;; --------------------------------------------------------------------------
(defstruct (blackboard (:constructor %make-blackboard) (:conc-name bb-))
  "The shared state of a workflow run: the END being pursued, an ORDER of the
step names as they complete, and the OUTPUTS map (step name -> answer string)."
  (end "" :type string)
  (outputs (make-hash-table :test 'equal))
  (order '() :type list))

(defun %name (x)
  "Coerce a step/workflow name (string, symbol, or keyword) to a string key."
  (etypecase x
    (string x)
    (symbol (string-downcase (symbol-name x)))))

(defun bb-result (bb name)
  "The output recorded under step NAME (string/symbol/keyword), or NIL."
  (gethash (%name name) (bb-outputs bb)))

(defun bb-final (bb)
  "The output of the last step that completed -- the workflow's answer."
  (let ((last (car (last (bb-order bb)))))
    (and last (gethash last (bb-outputs bb)))))

(defun %copy-ht (ht)
  (let ((new (make-hash-table :test 'equal)))
    (maphash (lambda (k v) (setf (gethash k new) v)) ht)
    new))

;;; --------------------------------------------------------------------------
;;; Nodes: a STEP binds an agent to a prompt; a GROUP fans steps out in parallel
;;; (parallel *semantics*: each child sees the blackboard as of the group's
;;; start, none sees the others; results merge after). Concurrency is no longer
;;; "a drop-in later": children run on threads as of #418. The isolation contract
;;; this comment described is what made that a small change rather than a
;;; redesign -- and it now covers the AGENT too, which is the piece it had missed.
;;; --------------------------------------------------------------------------
(defstruct (wstep (:conc-name wstep-))
  (name "" :type string)
  (agent nil)
  (prompt nil))   ; a string, or a function of the blackboard -> string

(defstruct (wgroup (:conc-name wgroup-))
  (steps '() :type list))

(defun step (name agent prompt)
  "A workflow step: run AGENT (a praxeon/actor:agent) with PROMPT, recording its
answer under NAME. PROMPT is either a string or a function of the blackboard
returning a string -- the latter lets a step consume prior steps' outputs, e.g.
 (lambda (bb) (format nil \"Summarize: ~A\" (bb-result bb :research)))."
  (make-wstep :name (%name name) :agent agent :prompt prompt))

(defun parallel (&rest steps)
  "A fan-out group of STEPs run CONCURRENTLY, one thread per child, with parallel
semantics: each child sees the blackboard as of the group's start (not each other's
output) and its own view of its agent, and all results merge into the blackboard
afterward in declaration order. Use for independent subtasks -- gather with a
following STEP whose prompt reads each child's result.

Two things a caller needs to know, both from `%run-group', where the reasoning is:

  A PROVIDER SHARED BY TWO CHILDREN OF ONE GROUP MUST BE SAFE TO CALL CONCURRENTLY.
  Each child gets its own agent view, so histories cannot interleave, but the
  provider inside that view is the same object.

  A CHILD THAT SIGNALS DOES NOT DISCARD ITS SIBLINGS' WORK. Every child runs to
  completion; what succeeded is merged; `cnd:parallel-child-failure' then names what
  failed and what did not.

Until #418 this ran its children sequentially -- the isolation was real, the
concurrency was not."
  (make-wgroup :steps steps))

;;; --------------------------------------------------------------------------
;;; The workflow and its driver.
;;; --------------------------------------------------------------------------
(defstruct (workflow (:constructor %make-workflow) (:conc-name workflow-))
  "A coordinated plan: ordered NODES (STEPs and PARALLEL groups) driving agents
toward a shared END (the praxeology End, as goal text)."
  (name "workflow" :type string)
  (end "" :type string)
  (nodes '() :type list))

(defun make-workflow (name end &rest nodes)
  "Build a workflow named NAME pursuing END, composed of NODES (results of STEP and
PARALLEL, run in order). Drive it with RUN-WORKFLOW."
  (%make-workflow :name (%name name) :end end :nodes nodes))

(defun %resolve-prompt (prompt bb)
  (etypecase prompt
    (string prompt)
    (function (funcall prompt bb))))

(defun %run-step (st bb)
  "Run one STEP against blackboard BB: resolve its prompt, run the agent's turn,
record the answer under the step name. Returns the answer."
  (let* ((name (wstep-name st))
         (agent (wstep-agent st))
         (prompt (%resolve-prompt (wstep-prompt st) bb)))
    (evt:emit :workflow-step :name name :agent (actor:agent-name agent))
    (let ((answer (actor:run-turn agent prompt)))
      (setf (gethash name (bb-outputs bb)) answer
            (bb-order bb) (append (bb-order bb) (list name)))
      answer)))

;;; --------------------------------------------------------------------------
;;; Fan-out, and the three kinds of sharing a `dolist' hid (#418).
;;;
;;; `%run-group' ran its children one after another. Its docstring described VISIBILITY
;;; ISOLATION -- children cannot see each other's writes -- and that was accurate and
;;; implemented. The NAME was a separate claim, about concurrency, and nothing in the tree
;;; made it true: a consuming app fanning out twenty content variants paid twenty sequential
;;; provider round-trips. Measured before the change, five children at 0.20 s of provider
;;; dwell each: 5 round-trips, ONE thread, ZERO overlapping call intervals, 1.02 s against a
;;; 1.00 s sequential ideal and a 0.20 s concurrent one.
;;;
;;; THE DECISION THIS TICKET IS ABOUT IS NOT THE THREADS. `actor:run-turn' MUTATES the agent
;;; it is handed -- it appends to `agent-history' up to three times per step -- so two children
;;; sharing one agent would interleave into a single history list. What a fanned-out child
;;; runs against is the real question, and the answer was already in this file:
;;;
;;;   THE GROUP ALREADY SNAPSHOTS THE BLACKBOARD SO CHILDREN CANNOT SEE EACH OTHER'S WRITES.
;;;   The agent's history is the OTHER piece of shared mutable state, and it had no snapshot
;;;   -- only because sequential execution made the omission invisible.
;;;
;;; So a child gets a VIEW OF ITS AGENT exactly as it already got a view of the blackboard: a
;;; `copy-structure' whose HISTORY its turn appends to. After the join each child's turn is
;;; merged back onto the agent it was derived from, IN DECLARATION ORDER rather than completion
;;; order, mirroring the blackboard merge. Two consequences, both wanted:
;;;
;;;   children with DISTINCT agents behave exactly as before -- each agent ends carrying its
;;;     own child's turn, which is what every existing caller and test observes;
;;;   children SHARING one agent now produce a DETERMINISTIC transcript -- both conversations,
;;;     in the order the group declared them -- rather than two turns interleaved by whichever
;;;     thread appended first.
;;;
;;; WHAT REMAINS SHARED, and what it asks of a caller. `copy-structure' is shallow, so the
;;; provider, the means table and the context object are shared by reference. The means table
;;; and the context are read-only during a turn -- `actor:request-messages' says so in as many
;;; words, and that is why it can be. THE PROVIDER IS NOT OURS: a child's turn calls
;;; `llm:complete' on it, so A PROVIDER SHARED BY TWO CHILDREN OF ONE GROUP MUST BE SAFE TO
;;; CALL CONCURRENTLY. Real HTTP providers are; a test double that pops from a script list is
;;; not, which is why the suite gives each child its own.
;;;
;;; DYNAMIC BINDINGS DO NOT CROSS THREADS, and this one would have been a silent loss.
;;; `evt:*observer*' is a `defvar' that `evt:with-observer' rebinds, so a child thread sees the
;;; GLOBAL value -- NIL -- and every event a fanned-out child emitted would have vanished: the
;;; step events, and `:usage', which IS the token ledger. Fan-out would have quietly stopped
;;; reporting what it cost, on the path whose whole purpose is to do more work at once. The
;;; caller's binding is therefore captured here and re-established inside each child.
;;;
;;; ON THE CACHEABLE PREFIX, because concurrency changes its arithmetic and not for the better.
;;; N children over one large shared prefix ideally cost one cache WRITE and N-1 READS. That
;;; holds when the calls are ordered: the first writes, the rest read. Run concurrently they
;;; all leave before any returns, so whether the provider records one write and N-1 reads or N
;;; writes is a race this code does not control. Measured here: with 5 children every call is
;;; in flight before the first completes, so the ordered guarantee is gone by construction. A
;;; caller who cares should warm the prefix with one turn before fanning out -- that is a
;;; CALLER's decision because only the caller knows whether the prefix is worth a serial
;;; round-trip, and it is recorded here rather than silently paid for. See #417 for the ledger
;;; that makes the difference visible.
;;; --------------------------------------------------------------------------

(defun %agent-view (agent)
  "A per-child view of AGENT whose HISTORY the child's turn may append to freely.

Shallow on purpose -- see the section comment. A turn writes only the history slot, and the
context is both the expensive object and the one a fan-out most wants to share rather than
duplicate N times."
  (when agent (copy-structure agent)))

(defun %run-child (child snapshot bb observer)
  "Run CHILD against its own blackboard view and its own agent view.
Returns (values NAME OUTPUT AGENT-VIEW BASE), where BASE is how long the agent's history was
when the view was taken. Signals whatever the child signalled."
  ;; OBSERVER is re-established here, inside the child's thread, because a dynamic binding
  ;; made by the caller is not visible to a thread it spawned (section comment).
  (let* ((evt:*observer* observer)
         (view-agent (%agent-view (wstep-agent child)))
         ;; CAPTURED BEFORE THE TURN RUNS. Computing this at merge time instead is wrong the
         ;; moment two children share one agent: the first merge grows the original, so the
         ;; second child's turn falls entirely inside the "already there" prefix and is
         ;; dropped. Measured -- the shared-agent test reported 2 messages where 4 were
         ;; expected, and this line is the difference.
         (base (if view-agent (length (actor:agent-history view-agent)) 0))
         (child-view (make-wstep :name (wstep-name child)
                                 :agent view-agent
                                 :prompt (wstep-prompt child)))
         (view (%make-blackboard :end (bb-end bb)
                                 :outputs (%copy-ht snapshot)
                                 :order (bb-order bb))))
    (%run-step child-view view)
    (values (wstep-name child)
            (gethash (wstep-name child) (bb-outputs view))
            view-agent
            base)))

(defun %merge-child-history (original view base)
  "Append to ORIGINAL's history the messages the child's turn added to VIEW.

BASE is how long the history was WHEN THE VIEW WAS TAKEN, so everything past it in VIEW is
the child's own turn. It is passed in rather than recomputed here precisely because ORIGINAL
may already have grown: with two children sharing one agent, the first merge lengthens it,
and a locally recomputed base would skip past the second child's turn entirely.

Done at the join rather than inside the thread, and in declaration order, which is what makes
the resulting transcript independent of how the threads were scheduled."
  (when (and original view)
    (setf (actor:agent-history original)
          (append (actor:agent-history original)
                  (nthcdr base (actor:agent-history view))))))

(defun %run-group (grp bb)
  "Run a GROUP's children CONCURRENTLY -- one thread each -- with parallel semantics: every
child sees a copy of BB as of the group's start and its own view of its agent, so no child
sees another's writes to either. Results merge into BB afterward in DECLARATION order, so the
blackboard and every agent's history read the same whatever order the threads finished in.

A CHILD THAT SIGNALS DOES NOT COST ITS SIBLINGS THEIR WORK. Every child runs to completion,
the ones that succeeded are merged, and `cnd:parallel-child-failure' is then signalled naming
the ones that did not and the ones that did. The sequential version unwound on the first
error, so children after it never ran and children before it were discarded with the
accumulated writes -- that is the behaviour this replaces, and it is why the condition carries
both lists."
  (let* ((children (wgroup-steps grp))
         (snapshot (%copy-ht (bb-outputs bb)))
         (observer evt:*observer*)
         (results (make-array (length children) :initial-element nil))
         (threads
           (loop for child in children
                 ;; THREAD-LIFETIME: continues the caller's unit of work. A child of a
                 ;; parallel group belongs to the request that spawned it, so it carries the
                 ;; registered dynamic bindings (#430). `observer' below is still passed
                 ;; explicitly and stays that way: `%run-child' rebinds it on the child, which
                 ;; shadows the inherited value rather than fighting it. The wrapper sits on
                 ;; the spawn because the capture is taken where it is called -- here, on this
                 ;; thread, inside the LOOP -- and not where the thunk later runs.
                 collect (let ((child child))
                           (bt:make-thread
                            (aion/dynamic:inheriting
                             (lambda ()
                               ;; EVERY outcome is recorded rather than propagated, so the join
                               ;; can merge what worked and report what did not. A condition
                               ;; escaping a thread here would be lost with the thread.
                               (handler-case
                                   (multiple-value-bind (name output agent base)
                                       (%run-child child snapshot bb observer)
                                     (list :ok name output agent base))
                                 (error (e) (list :error (wstep-name child) e)))))
                            :name (format nil "px-parallel-~A" (wstep-name child)))))))
    ;; JOIN EVERY THREAD BEFORE READING ANYTHING. Returning early would leave children
    ;; writing into views this function is about to read.
    (loop for th in threads
          for i from 0
          do (setf (aref results i) (bt:join-thread th)))
    (let ((failures '())
          (completed '()))
      (loop for child in children
            for i from 0
            for r = (aref results i)
            do (ecase (first r)
                 (:ok (destructuring-bind (name output agent base) (rest r)
                        (setf (gethash name (bb-outputs bb)) output
                              (bb-order bb) (append (bb-order bb) (list name)))
                        (%merge-child-history (wstep-agent child) agent base)
                        (push name completed)))
                 (:error (push (cons (second r) (third r)) failures))))
      (when failures
        (error 'cnd:parallel-child-failure
               :failures (nreverse failures)
               :completed (nreverse completed))))))

(defun run-workflow (workflow)
  "Run WORKFLOW to completion, threading a shared blackboard toward its END. STEP
nodes see all prior outputs; a PARALLEL group's children each see the blackboard as
of the group's start. Emits :workflow-start / :workflow-step / :workflow-end.
Returns the blackboard -- BB-FINAL is the answer, BB-RESULT reads any step."
  (let ((bb (%make-blackboard :end (workflow-end workflow))))
    (evt:emit :workflow-start :name (workflow-name workflow)
                              :end (workflow-end workflow))
    (dolist (node (workflow-nodes workflow))
      (etypecase node
        (wstep (%run-step node bb))
        (wgroup (%run-group node bb))))
    (evt:emit :workflow-end :name (workflow-name workflow))
    bb))
