;;;; memory.lisp --- observational memory: remember, supersede, recall (pre-publication issue 60).
;;;;
;;;; What an agent has learned about someone, across turns and across sessions, held as
;;;; observations rather than as transcript.
;;;;
;;;; THE SURFACE IS remember / supersede / recall, NOT remember / recall. The consuming
;;;; app's first case is a member correcting the agent once -- "do not call them X" -- and a
;;;; correction REPLACES what was believed rather than adding to it. A store that only
;;;; accrues holds the original statement and the correction together and recalls whichever
;;;; the ranking happens to favour, which is non-deterministic and the worst version.
;;;;
;;;; WHY THE BITEMPORAL STAMPS ARE NOT ENOUGH ON THEIR OWN. `ctx-item' already carries
;;;; valid-time and tx-time, and those answer "what did it believe on Tuesday" exactly. They
;;;; do not answer "what does it believe now": two observations can both be valid now and
;;;; contradict each other, and nothing in a pair of timestamps says which one won. So
;;;; supersession is an explicit relation recorded at write time, and the resolution rule is
;;;; stated here rather than left to a ranking:
;;;;
;;;;   An observation is CURRENT when nothing supersedes it and it has not been erased.
;;;;
;;;; SUPERSESSION AND ERASURE ARE DIFFERENT OPERATIONS AND MUST STAY SO. Superseding keeps
;;;; the old observation so `recall ... :as-of' can still answer what was believed then.
;;;; Erasure destroys it, including from the historical view -- that is what makes it
;;;; erasure rather than a tombstone, and the maintainer's note on pre-publication issue 60 is that a store
;;;; without a defensible erasure story is something a consuming app cannot retrofit.
;;;;
;;;; MEMORY IS SCOPED BY SUBJECT, NOT BY AGENT. The app runs several personas with a
;;;; hand-off between them, and a member who explained their situation to one should not
;;;; explain it again to the next. Per-agent memory would not solve that; per-subject does.
;;;;
;;;; THE STORAGE SEAM IS NAMED AND NOT IMPLEMENTED. Every operation is a generic function on
;;;; a store, and this file ships one in-memory store. A Kairos or pgvector store implements
;;;; the same generics later without the callers changing. The first slice deliberately does
;;;; not need either: the app is blocked on a live member complaint, and making it wait for
;;;; a storage layer that does not exist yet would be a year of waiting for a feature that
;;;; fits in a list.

(cl:in-package #:praxeon/memory)

;;; --- where an observation came from -----------------------------------------

(defstruct (provenance (:constructor make-provenance (conversation turn &key at)))
  "Which conversation, which turn, and when -- the traceable source of an observation.

REQUIRED ON EVERY WRITE (#150). Observational memory is personal data held indefinitely, and
a remembered claim that cannot be traced cannot be CORRECTED: a member disputing it has
nothing to point at, and a persona repeating it has nothing to check. That is the
rectification half of the same argument that makes erasure a first-class operation here
rather than a tombstone.

NOT DEFAULTED, and that is the decision rather than an omission. A fabricated source is
worse than an absent one because it READS AS A CITATION -- the failure would be an agent
saying `you told me on turn 3' about a turn nobody had.

AT IS OPTIONAL AND NEVER INVENTED. It is when the SOURCE TURN happened, which is not when
the store learned it: a distillation pass reads a window from an hour ago, so the
observation's RECORDED-AT is the pass and AT is the conversation. Conflating them would make
`what did it believe on Tuesday' answer with the pass's schedule instead of the member's.
NIL means the source time was not recorded -- an absent measurement, not a zero one."
  (conversation "" :type string)
  (turn 0 :type integer)
  (at nil :type (or null integer)))

;;; --- what an observation is -------------------------------------------------

(defstruct (observation (:constructor %make-observation))
  "One thing an agent has observed about a SUBJECT.

ID is stable and is what supersession refers to. KIND records WHY this was written, which
the consuming app asked for specifically: an explicit correction is more reliable than
anything an LLM judged to be salient, and a recall that has to choose between them should be
able to tell them apart."
  (id "" :type string)
  (subject "" :type string)
  (content "" :type string)
  (kind :observation :type keyword)   ; :correction :preference :fact :observation
  (value 1 :type real)
  (tokens 0 :type fixnum)
  (valid-from 0 :type integer)        ; when it became true in the world
  (recorded-at 0 :type integer)       ; when this store learned it
  (supersedes nil)                    ; id of the observation this replaces, or NIL
  (superseded-by nil)                 ; id of the observation replacing this, or NIL
  (superseded-at nil)                 ; when that happened, or NIL
  ;; THE SOURCE, and it is not optional. See PROVENANCE above.
  (provenance (error "an observation must carry its provenance (#150)") :type provenance))

(defun observation-current-p (observation)
  "Is OBSERVATION what the store believes now?

The resolution rule, in one place: current means nothing supersedes it. Erased observations
are not here to ask -- erasure removes them."
  (null (observation-superseded-by observation)))

;;; --- the store: a named seam ------------------------------------------------

(defclass memory-store () ()
  (:documentation "Where observations live.

Named so a Kairos or pgvector store can implement these generics later without any caller
changing. The in-memory store below is the whole implementation today, and that is enough
for the first slice: nothing here needs semantic retrieval to answer `what did this member
tell us'."))

(defgeneric remember (store subject content &key provenance kind value tokens valid-from)
  (:documentation "Record CONTENT as an observation about SUBJECT. Returns the observation.

A DIRECT WRITE, not a distillation. The consuming app's point is that the reliable
observations are the ones where someone said something explicitly corrective, and putting an
LLM salience judgement in front of those is strictly worse than recording them because they
were corrections. The distillation pass is one caller of this, not the only one -- which is
also why the first slice is useful before any LLM pass exists."))

(defgeneric supersede (store observation content &key provenance kind value tokens valid-from)
  (:documentation "Replace OBSERVATION with a new one carrying CONTENT. Returns the new one.

The old observation stays, marked superseded, so a historical recall can still answer what
was believed before. It is no longer current, so an ordinary recall will not return it."))

(defgeneric recall (store subject &key budget kind as-of)
  (:documentation "The observations about SUBJECT worth putting in a prompt, budgeted.

Returns ctx-items, oldest first, chosen by `praxeon/context:assemble' -- the same budgeted
selection the rest of context assembly uses, so memory competes for space on the same terms
as everything else rather than on terms of its own.

AS-OF, when given, answers what the store believed at that time: observations recorded by
then, and superseded only if they were superseded by then. Without it, current beliefs."))

(defgeneric recall-similar (store subject embedding &key budget kind as-of limit)
  (:documentation "The observations about SUBJECT nearest to EMBEDDING, budgeted.

A SECOND GENERIC RATHER THAN A MODE ON `RECALL', and that is the whole point (#150). The
consuming app that asked for this deliberately did NOT use similarity for its reference
corpus -- that material is mostly figures, and the nearest neighbour to a payout is a
different payout, so a near-miss there is worse than no answer because an agent quotes it
confidently. Exact retrieval and similarity retrieval are different operations that happen
to share a store.

A `:query' parameter on RECALL would have made one function that sometimes ranks by recency
and sometimes by distance -- a mode parameter, and ADTs over booleans is the house rule. A
call site that passes the wrong mode is silently wrong; a call site that calls the wrong
function is visible in a grep.

EMBEDDING IS A VECTOR, NOT TEXT, so this path makes no provider call. Embedding the query is
the caller's, on the caller's thread, with the caller's provider -- which is also what keeps
#158 away from here.

NOT EVERY STORE HAS A METHOD. A store that cannot rank by distance does not answer this, and
that absence is structural: the caller gets no applicable method rather than a store quietly
falling back to recency and returning plausible rows."))

(defgeneric observations-of (store subject &key as-of include-superseded)
  (:documentation "The raw observations about SUBJECT. For tests, inspection, and the
access right -- a member is entitled to see what is held about them."))

(defgeneric forget-subject (store subject)
  (:documentation "Erase everything held about SUBJECT. Returns how many were removed.

ERASURE, NOT SUPERSESSION. The observations are gone, including from `:as-of' views. A
tombstone that keeps the content and marks it deleted is not erasure, and a store whose
history cannot be made to forget is one a consuming app cannot use for personal data."))

(defgeneric forget (store observation)
  (:documentation "Erase one observation. Returns true when it was there."))

;;; --- the in-memory store ----------------------------------------------------

(defclass in-memory-store (memory-store)
  ((observations :initform (make-hash-table :test #'equal) :reader store-observations)
   (counter :initform 0 :accessor store-counter))
  (:documentation "Observations in a hash-table, keyed by id. No persistence."))

(defun make-in-memory-store () (make-instance 'in-memory-store))

(defun %next-id (store)
  (format nil "obs-~D" (incf (store-counter store))))

(defun check-provenance (provenance operation &optional subject)
  "Signal MISSING-PROVENANCE unless PROVENANCE is one. Returns it.

One function so REMEMBER and SUPERSEDE refuse identically. A correction that cannot be
traced is worse than an observation that cannot be: it is the record of someone having
been put right, with no way to see who or when."
  (unless (provenance-p provenance)
    (error 'praxeon/conditions:missing-provenance :operation operation :subject subject))
  provenance)

(defun %estimate-tokens (content)
  "A rough token estimate, four characters to the token.

The same crude rule the rest of the context code uses. It is deliberately not exact: the
number feeds a budget comparison, and a caller that needs precision passes TOKENS itself."
  (max 1 (ceiling (length content) 4)))

(defmethod remember ((store in-memory-store) subject content
                     &key provenance (kind :observation) (value 1) tokens valid-from)
  (check-provenance provenance "remember" subject)
  (let* ((now (praxeon/context:now))
         (obs (%make-observation :id (%next-id store)
                                 :subject subject
                                 :content content
                                 :kind kind
                                 :value value
                                 :tokens (or tokens (%estimate-tokens content))
                                 :valid-from (or valid-from now)
                                 :recorded-at now
                                 :provenance provenance)))
    (setf (gethash (observation-id obs) (store-observations store)) obs)
    obs))

(defmethod supersede ((store in-memory-store) observation content
                      &key provenance kind value tokens valid-from)
  ;; THE CORRECTION HAS ITS OWN PROVENANCE, not the original's. A member putting an agent
  ;; right does so in a later turn, and inheriting the superseded observation's source would
  ;; attribute the correction to the conversation it corrects.
  (check-provenance provenance "supersede" (observation-subject observation))
  (let ((held (gethash (observation-id observation) (store-observations store))))
    (unless held
      (error 'praxeon/conditions:praxeon-error
             :detail (format nil "cannot supersede ~A: it is not in this store"
                             (observation-id observation))))
    (when (observation-superseded-by held)
      ;; Superseding something already superseded would fork the chain, and then "what does
      ;; it believe now" has two answers again -- which is the whole defect this exists to
      ;; remove. Refuse and name the replacement, so the caller can supersede that instead.
      (error 'praxeon/conditions:praxeon-error
             :detail (format nil "~A was already superseded by ~A"
                             (observation-id held) (observation-superseded-by held))))
    (let ((new (remember store (observation-subject held) content
                         :provenance provenance
                         :kind (or kind (observation-kind held))
                         :value (or value (observation-value held))
                         :tokens tokens
                         :valid-from valid-from)))
      (setf (observation-supersedes new) (observation-id held)
            (observation-superseded-by held) (observation-id new)
            (observation-superseded-at held) (observation-recorded-at new))
      new)))

(defun %visible-at (obs as-of)
  "Was OBS a current belief at AS-OF?"
  (and (<= (observation-recorded-at obs) as-of)
       (or (null (observation-superseded-at obs))
           (> (observation-superseded-at obs) as-of))))

(defmethod observations-of ((store in-memory-store) subject
                            &key as-of include-superseded)
  (let ((all '()))
    (maphash (lambda (id obs)
               (declare (ignore id))
               (when (string= (observation-subject obs) subject)
                 (push obs all)))
             (store-observations store))
    (let ((filtered (cond
                      (as-of (remove-if-not (lambda (o) (%visible-at o as-of)) all))
                      (include-superseded all)
                      (t (remove-if-not #'observation-current-p all)))))
      (sort filtered #'< :key #'observation-recorded-at))))

(defun observation->ctx-item (observation)
  "OBSERVATION as a budgeted context item carrying its citation.

THE ONLY ROUTE FROM AN OBSERVATION TO A CTX-ITEM, and that is what makes the citation
guaranteed rather than customary. Both stores went through their own inline construction
before this existed -- two copies of the same five fields, which is how the two come to
disagree about a sixth.

THE SOURCE IS THE OBSERVATION ITSELF, not just its provenance. #150 asks for items a
persona can cite AND that a member can correct, and correcting means superseding, which
needs the id. Provenance alone would answer `where did this come from' and leave `and how
do I fix it' unanswerable."
  (praxeon/context:make-ctx-item
   :content (observation-content observation)
   :tokens (observation-tokens observation)
   :role :note
   :value (observation-value observation)
   :valid-time (observation-valid-from observation)
   :tx-time (observation-recorded-at observation)
   :source observation))

(defmethod recall ((store in-memory-store) subject &key (budget 1000) kind as-of)
  (let* ((observations (observations-of store subject :as-of as-of))
         (wanted (if kind
                     (remove-if-not (lambda (o) (eq (observation-kind o) kind)) observations)
                     observations))
         (context (praxeon/context:make-context :budget budget)))
    (dolist (o wanted)
      (praxeon/context:add-item context (observation->ctx-item o)))
    (praxeon/context:assemble context)))

(defmethod forget ((store in-memory-store) observation)
  (let ((id (observation-id observation)))
    (when (gethash id (store-observations store))
      ;; Unlink the forward pointer, or a surviving predecessor would claim to be superseded
      ;; by something no longer there, and it would never be current again.
      (maphash (lambda (other-id other)
                 (declare (ignore other-id))
                 (when (equal (observation-superseded-by other) id)
                   (setf (observation-superseded-by other) nil
                         (observation-superseded-at other) nil)))
               (store-observations store))
      (remhash id (store-observations store))
      t)))

(defmethod forget-subject ((store in-memory-store) subject)
  (let ((doomed (observations-of store subject :include-superseded t)))
    (dolist (o doomed) (forget store o))
    (length doomed)))
